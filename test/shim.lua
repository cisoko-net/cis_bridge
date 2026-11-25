-- The `lib.*` shims: ox_lib's surface, so a resource written against ox_lib runs.
--
-- This is the "drop-in ergonomics" layer, and it exists for a specific person:
-- somebody who installed a resource written for ox_lib, did not read our
-- documentation, and expects `lib.callback.await` and `lib.zones.box` to be
-- there. For them it simply is.
--
-- The rule that matters
--
--   Translate the shape, not the meaning. ox_lib's `lib.callback.await` is
--   `(name, delay, target, cb)`. `Cis.callback.await` is `(name, ...)` with no
--   target -- the server-side caller is the target, taken from context. So the
--   shim must drop delay and target, not forward them. Forwarding `target`
--   is the single most common mistake this shim could make and it produces a
--   call that looks right and answers the wrong question.
--
-- Zones are client-only in cis_libs, so every zone call on the server answers
-- `false` and a reason (section 7).
--
-- Mutation C (a disconnected player source) lives in this file, because it is a
-- shim-translation failure.

local passed, failed = 0, 0
local failures = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
end

-- The shim is built against an injected engine, for the same reason the
-- framework detector is: a fake captures what crossed the boundary without
-- FiveM being involved, which is the only way the dropped arguments are
-- testable at all.
local Shim = require 'shared.lib.shim'

-- Every engine call any stub sees, so the raising-export check can look at all of
-- them rather than at the one that happens to notice.
_G.__engineCalls = {}

local function engine(overrides)
    -- `e` is declared first and assigned after, because the table constructor's
    -- own methods close over `e`. `local e = { RegisterCallback = function() e.callbacks
    -- ... end }` captures an e that does not exist yet, so every call raises
    -- "attempt to index a nil value (global 'e')" -- and it says global, because
    -- the reference falls out of the enclosing scope entirely.
    local e
    e = {
        awaited = {},
        callbacks = {},
        RegisterCallback = function(_, name, handler)
            e.callbacks[name] = handler
            return true
        end,
        -- Modelled on cis_libs exactly. `AwaitCallback` raises on a refusal --
        -- read out of cis_libs/server/callback.lua, which calls error() on
        -- purpose -- and returns the handler's values unwrapped. `TryAwaitCallback`
        -- is the non-raising form and answers `ok, ...results` or `false, reason`.
        --
        -- Raising here rather than returning is deliberate: it makes "the shim
        -- called the raising export" a loud failure instead of a value that
        -- happens to look right.
        AwaitCallback = function(_, name, ...)
            local args = table.pack(...)
            e.awaited[#e.awaited + 1] = { name = name, args = args, n = args.n, via = 'AwaitCallback' }
            -- Records rather than raises. Raising here would take the whole
            -- suite down on any test that reaches it, so a shim routed through
            -- the raising export produced a crash instead of the FAIL that
            -- names the mistake. The flag is asserted at the end of the file,
            -- which reports it as an assertion and leaves the rest of the suite
            -- readable.
            _G.__engineCalls[#_G.__engineCalls + 1] = 'AwaitCallback:' .. tostring(name)
            if name == 'no-such-callback' then
                error(('callback %q: unknown'):format(name), 0)
            end
            return 42
        end,
        TryAwaitCallback = function(_, name, ...)
            local args = table.pack(...)
            e.awaited[#e.awaited + 1] = { name = name, args = args, n = args.n, via = 'TryAwaitCallback' }
            _G.__engineCalls[#_G.__engineCalls + 1] = 'TryAwaitCallback:' .. tostring(name)
            if name == 'no-such-callback' then
                return false, 'no handler'
            end
            return true, 42
        end,
        CallCallback = function(_, name, cb, ...)
            local args = table.pack(...)
            e.awaited[#e.awaited + 1] = { name = name, args = args, n = args.n }
            if cb then cb(...) end
            return true
        end,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

local function vec3(x, y, z)
    -- CfxLua's vector3 is userdata: `type(v) == 'table'` is false. The shim must
    -- read `.x`, and the harness models it as a table so a Lua-only run can see
    -- the property access happen.
    return { x = x or 0.0, y = y or 0.0, z = z or 0.0 }
end

-- ============================================== 1. lib.callback await
--
-- ox_lib:  lib.callback.await(name, delay, target, cb)
-- cis_libs: Cis.callback.await(name, ...)      -- no target argument
do
    local e = engine()
    local lib = Shim.build(e)
    -- With a continuation, ox_lib's form returns nothing and runs the callback,
    -- so there is no value to read here. The value-returning form is the one
    -- with no continuation, and it is asserted below; the first version asked
    -- this call for a value it never promised and reported the shim for it.
    local ran, got = false, nil
    local result, delay, target, cb =
        lib.callback.await('get:health', 100, 3, function(v) ran, got = true, v end)

    check(ran, 'a continuation is called')
    check(got == 42, 'with the value the callback answered')
    check(result == nil, 'and the awaiting form returns nothing of its own')
    check(delay == nil and target == nil,
        'and the second value is nil -- a consumer reading one gets one')

    local call = e.awaited[1]
    check(call ~= nil, 'the call reached cis_libs')
    check(call.name == 'get:health', 'under the same name')
    check(call.via == 'TryAwaitCallback', 'through the NON-RAISING export')
    -- The two dropped arguments, asserted one at a time because they fail
    -- differently: a forwarded delay is harmless-looking and shifts nothing; a
    -- forwarded target is handed to a function that has no target parameter and
    -- arrives as the callback's first real argument.
    check(call.n == 0,
        ('delay and target are DROPPED, not forwarded (got %d argument(s))'):format(call.n))
    check(call.args[1] ~= 3, 'and the target did not survive as an argument')
end

-- The real arguments survive. A shim that drops everything "to be safe" is
-- broken in the other direction and just as silently.
do
    local e = engine()
    local lib = Shim.build(e)
    lib.callback.await('get:thing', 0, nil, nil, 'a', 'b')
    local call = e.awaited[1]
    check(call.n == 2 and call.args[1] == 'a' and call.args[2] == 'b',
        'arguments after the ox_lib preamble are forwarded intact')
end

-- ---- mutation C: a disconnected player source
--
-- cis_libs answers `false, 'player not connected'` at once rather than waiting
-- out a ten-second timeout. The shim's job is to PASS that through. The failure
-- it guards against is a shim that treats `false` as "no answer" and retries, or
-- that swallows the reason -- either turns an instant, named answer into a
-- ten-second stall with nothing to show for it.
do
    local seen
    local e = engine({
        AwaitCallback = function(_, name)
            _G.__engineCalls[#_G.__engineCalls + 1] = 'AwaitCallback:' .. tostring(name)
            error(('callback %q: unknown'):format(tostring(name)), 0)
        end,
        TryAwaitCallback = function(_, name, ...)
            local a = table.pack(...)
            seen = { name = name, n = a.n }
            _G.__engineCalls[#_G.__engineCalls + 1] = 'TryAwaitCallback:' .. tostring(name)
            if name == 'gone:player' then
                return false, 'player not connected'
            end
            return true, 42
        end,
    })
    local lib = Shim.build(e)
    -- Wrapped, because this suite must survive a shim that reaches for the
    -- Raising export. Without the pcall that mistake crashed the whole suite with
    -- "callback \"gone:player\": unknown" and every other result was lost with
    -- it -- a red build, but one that reports the crash rather than the mistake.
    local called, result, reason = pcall(lib.callback.await,
        'gone:player', 0, 99, function() end)
    check(called, 'a disconnected source does not raise through the shim')

    check(result == false, 'a disconnected source answers false')
    check(reason == 'player not connected',
        ('and the reason arrives UNCHANGED, immediately (%s)'):format(tostring(reason)))

    -- And the source that was refused was the one passed: the shim dropped the
    -- target, so cis_libs had to decide, and the fixture proves it decided.
    check(seen and seen.n == 0,
        'and it was cis_libs that refused it -- the shim forwarded no target at all')
end

-- A no-handler refusal is passed through the same way, because a consumer
-- branches on the string.
do
    local e = engine()
    local lib = Shim.build(e)
    local ok, result, reason = pcall(lib.callback.await, 'no-such-callback')
    check(ok, 'an unknown callback does NOT raise through the shim')
    check(result == false, 'it answers false')
    check(type(reason) == 'string' and reason ~= '', 'with a reason attached')
end

-- The raising export is never used, anywhere.
--
-- Asserted once at the end over a list every engine stub appends to, rather than
-- beside the one call that would notice. A shim routed through
-- `AwaitCallback` instead of `TryAwaitCallback` makes cis_libs `error()` on a
-- missing callback -- turning a typo on a server the customer is running into an
-- exception inside a resource that never expected one.
--
-- The flag version of this check did not fire. A global set inside a stub is one
-- more thing that can silently not happen, and the whole point of the check is
-- to catch a mistake that is silent.
local raising = {}
for _, call in ipairs(_G.__engineCalls or {}) do
    if tostring(call):find('^AwaitCallback:') then
        raising[#raising + 1] = call
    end
end
check(#raising == 0,
    ("nothing in this suite went through cis_libs' raising AwaitCallback export: %s")
        :format(table.concat(raising, ', ')))

-- ============================================== 2. lib.callback.register
do
    local e = engine()
    local lib = Shim.build(e)
    lib.callback.register('get:health', function() return 7 end)
    check(e.callbacks['get:health'] ~= nil, 'register reaches cis_libs')
    check(type(e.callbacks['get:health']) == 'function', 'as a function')
end

-- ============================================== 3. lib.callback.await awaits a cb
--
-- ox_lib's legacy form takes a continuation and returns nothing. A resource
-- written that way calls `lib.callback.await(name, delay, target, cb)` and
-- expects `cb` to run. If the shim ignores the callback the resource hangs at
-- that line for the rest of its life, and nothing errors.
do
    local e = engine()
    local lib = Shim.build(e)
    local ran, got = false, nil
    local result = lib.callback.await('get:health', 0, nil, function(v)
        ran, got = true, v
    end)
    check(ran, 'a continuation passed to await IS called')
    check(got == 42, 'with the callback result')
    check(result == nil or result == 42,
        'and await itself does not also hand the value to a caller expecting none')
end

-- ============================================== 4. lib.callback.call
do
    local e = engine()
    local lib = Shim.build(e)
    local ran = false
    lib.callback.call('ping:it', function() ran = true end, 'arg')
    check(ran, 'lib.callback.call runs the continuation')
    local call = e.awaited[1]
    check(call ~= nil and call.name == 'ping:it', 'under the right name')
    check(call.args[1] == 'arg', 'with its arguments')
end

-- CallCallback's answer comes back untouched, a refusal included. A call that
-- always answered true would hide the reason a consumer branches on.
do
    local e = engine({
        CallCallback = function() return false, 'reason' end,
    })
    local lib = Shim.build(e)
    local ok, why = lib.callback.call('ping:it', function() end)
    check(ok == false and why == 'reason',
        ('lib.callback.call passes a refusal through (got %s, %s)'):format(tostring(ok), tostring(why)))
end

-- ============================================== 5. The fire-and-forget form
--
-- ox_lib's is `lib.callback(name, delay, target, cb)`, a different method from
-- `lib.callback.await`. The first version of this suite asserted that an await
-- with no continuation should not await, on the reasoning that returning nothing
-- is wasted work -- and it was wrong. A caller who writes `await` and gets
-- nothing back is waiting on a value that never arrives, and nothing anywhere
-- reports it.
do
    local recorded
    local e = engine({
        AwaitCallback = function() error('await was not called') end,
        CallCallback = function(_, name, cb, ...)
            local args = table.pack(...)
            recorded = { name = name, args = args, n = args.n }
            if cb then cb(...) end
            return true
        end,
    })
    -- The override closes over `recorded`, a local declared before the call,
    -- because an override passed into `engine()` cannot see `e`: by then `e` is
    -- still being built. The first version reached for `e` and every call raised
    -- "attempt to index a nil value (global 'e')".
    local lib = Shim.build(e)
    local ran = false
    lib.callback.send('ping:it', 0, nil, function() ran = true end)
    check(ran, 'lib.callback runs the continuation without awaiting')
    check(recorded and recorded.name == 'ping:it', 'under the right name')

    -- ox_lib's fire-and-forget form is `lib.callback(...)` on the table itself.
    -- GetLibShim crosses the export boundary as a msgpack copy, which drops
    -- metatables, so a `__call` would work here and raise in a consumer. The
    -- shim offers none; `lib.callback.send` is the form.
    check(getmetatable(lib.callback) == nil, 'lib.callback carries no metatable a copy would drop')
end

-- send with no continuation still sends its arguments. cis_libs' CallCallback
-- refuses a missing continuation, so the shim hands it one that does nothing.
do
    local recorded
    local e = engine({
        CallCallback = function(_, name, cb, ...)
            local args = table.pack(...)
            recorded = { name = name, cb = cb, args = args, n = args.n }
            return true
        end,
    })
    local lib = Shim.build(e)
    lib.callback.send('fire:it', nil, nil, nil, 'a', nil, 3)
    check(recorded and recorded.name == 'fire:it' and type(recorded.cb) == 'function'
        and recorded.n == 3 and recorded.args[1] == 'a' and recorded.args[3] == 3,
        'lib.callback.send with no cb forwards every argument and a continuation')
end

-- And an await with no continuation still awaits, because that is what the word
-- means and what a caller reading it expects.
do
    local e = engine()
    local lib = Shim.build(e)
    local result = lib.callback.await('get:health')
    check(result == 42, 'an await with no continuation still awaits and returns the value')
    check(e.awaited[1] and e.awaited[1].via == 'TryAwaitCallback',
        'and it went through the non-raising export')
end

-- The shim reaches a product through the GetLibShim export, so a handler or a
-- continuation the product passes in arrives as a funcref: a table with
-- __call, whose `type()` is 'table'.
do
    local function funcref(fn)
        return setmetatable({ __cfx_functionReference = 'ref' }, { __call = function(_, ...) return fn(...) end })
    end
    local e = engine()
    local lib = Shim.build(e)
    check(lib.callback.register('fr:reg', funcref(function() return 1 end)) == true,
        'lib.callback.register takes a funcref handler')
    check(lib.callback.call('fr:call', funcref(function() end)) == true,
        'lib.callback.call takes a funcref continuation')
    local got
    lib.callback.await('fr:await', funcref(function(v) got = v end))
    check(got == 42, 'lib.callback.await runs a funcref continuation in the delay slot')
    got = nil
    lib.callback.await('fr:await', 100, funcref(function(v) got = v end))
    check(got == 42, 'and in the target slot')
    local sent = false
    lib.callback.send('fr:send', nil, nil, funcref(function() sent = true end), 'a')
    check(sent and e.awaited[#e.awaited].args[1] == 'a', 'lib.callback.send takes a funcref continuation')
end

-- A truthy fourth argument that is not callable is not a continuation: await
-- answers the value instead of calling it.
do
    local lib = Shim.build(engine())
    local okc, v = pcall(lib.callback.await, 'get:health', 100, 3, 'not-a-function')
    check(okc and v == 42, 'await does not call a non-callable fourth argument: ' .. tostring(v))
end

-- ============================================== 6. No database proxy
--
-- The proxy forwarded to cis_libs' Db* exports, which answer only when a
-- resource registers the `database` capability, and none we ship does.
-- GetDbProxy answers false and a reason instead (test/contract.lua).
check(Shim.proxy == nil, 'the shim has no database proxy')

-- ============================================== 7. Zones on the server
--
-- cis_libs registers CreateZone, RemoveZone and ZoneContains on the client
-- only (client/zones.lua), so from the server each one would raise "No such
-- export". The shim has no zone builders: every zone call answers false and a
-- reason, and nothing reaches the engine.
do
    local e = engine()
    local lib = Shim.build(e)
    local okb, a, ar = pcall(lib.zones.box, { name = 'b', coords = vec3(0, 0, 0), size = vec3(4, 4, 4) })
    check(okb and a == false and type(ar) == 'string' and ar:find('client', 1, true) ~= nil,
        'a server box zone answers false and says zones are client-only: ' .. tostring(ar))
    local oks, b, br = pcall(lib.zones.sphere, { name = 's', coords = vec3(0, 0, 0), radius = 2.0 })
    local okp, c, cr = pcall(lib.zones.poly, { name = 'p', points = { vec3(0, 0, 0), vec3(1, 0, 0), vec3(1, 1, 0) } })
    check(oks and okp and b == false and c == false and br == ar and cr == ar, 'so do sphere and poly')
    local h = lib.zone('x')
    check(type(h) == 'table', 'lib.zone wraps a string id in a handle')
    local okr, r1, r1why = pcall(h.remove, h)
    local okc, r2, r2why = pcall(h.contains, h, vec3(0, 0, 0))
    check(okr and okc and r1 == false and r1why == ar and r2 == false and r2why == ar,
        'a zone handle on the server answers false and the same reason, not a raise')
    local z5, z5why = lib.zone(5)
    check(z5 == false and z5why == ar, 'lib.zone takes only a string id, and answers false and the reason')
    local z0, z0why = lib.zone()
    check(z0 == false and z0why == ar, 'and the same for no id, never a bare nil')
    check(not e.awaited[1], 'and no zone call reached the engine')
end

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(shim): ' .. failures[i] .. '\n')
end
io.write(('shim passed=%d failed=%d\n'):format(passed, failed))
