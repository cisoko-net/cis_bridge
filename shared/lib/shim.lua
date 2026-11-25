-- The `lib.*` shim: ox_lib's surface, over cis_libs.
--
-- Who this is for
--
-- A server resource written against part of ox_lib's `lib.callback`, which
-- reaches it through `exports['cis_bridge']:GetLibShim()`. It is not a drop-in
-- ox_lib: it covers the calls below and no others, and `lib.zones` answers
-- `false, reason` on the server, because cis_libs zones are client-only.
--
-- It is a translation layer and nothing else. No player table is stored, no
-- entity is tracked, no state is duplicated. Every call is forwarded and the
-- answer comes back untouched -- including a refusal, because a consumer
-- branching on `reason` is the whole reason a refusal carries one.
--
-- The translation that is easy to get wrong
--
-- Callback await. The shim takes `(name, delay, target, cb, ...)`, the
-- positional preamble of ox_lib's client await; ox_lib's server await is
-- `(event, playerId, ...)`, which this does not take. cis_libs is
-- `(name, ...)` with no target. So the shim drops delay and target rather
-- than forwarding them.
-- Forwarding `target` hands a value to a function that has no such parameter,
-- where it arrives as the first real argument -- a call that looks right and
-- answers the wrong question. `test/shim.lua` asserts the dropped arguments
-- did not survive, which is the only way that mistake gets caught.

local Shim = {}

--- A function, or the funcref table FiveM hands over for a function that
--- crossed an export (`type()` 'table', with `__call`).
local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and mt.__call ~= nil
end

--- Build the `lib` table over an injected engine.
---
--- Injected so `test/shim.lua` can capture exactly what crossed the boundary --
--- which is the only way the dropped-argument rule above is testable at all.
---
--- Every zone call answers `false, NO_ZONES`. cis_libs registers CreateZone,
--- RemoveZone and ZoneContains on the client only (client/zones.lua), so from
--- the server each one would raise "No such export"; answering false and a
--- reason instead keeps a consumer that branches on the first value from
--- raising.
function Shim.build(engine)
    local NO_ZONES = 'lib.zones is client-only: cis_libs registers its zone exports on the client, '
        .. 'so create zones from a client script with Cis.zones'
    -- Every engine call below is a colon call, and the fake in test/shim.lua is
    -- written to match.
    --
    -- The real thing is `exports['cis_libs']:Name(...)`, which passes the exports
    -- table as self. A shim that called `engine.Name(...)` instead would lose that
    -- argument, every stub would receive its first real parameter one slot left,
    -- and the failure would read as "the framework is broken" on a live server.
    -- Mirroring the call shape here means getting it wrong fails in a unit suite
    -- instead.

    local lib = { callback = {}, zones = {} }

    -- ------------------------------------------------------------------
    --  lib.callback
    -- ------------------------------------------------------------------

    --- `lib.callback.register(name, handler)`
    function lib.callback.register(name, handler)
        if type(name) ~= 'string' or name == '' then
            return false, 'a callback name must be a non-empty string'
        end
        if not callable(handler) then
            return false, ('callback %q needs a function'):format(name)
        end
        return engine:RegisterCallback(name, handler) ~= false
    end

    --- `lib.callback.await(name, delay, target, cb)` -> whatever the handler returned
    ---
    --- Or `false, reason` from cis_libs, passed through unchanged. A shim that
    --- treated `false` as "no answer" and retried would turn an instant, named
    --- refusal into a ten-second stall with nothing to show for it.
    function lib.callback.await(name, delay, target, cb, ...)
        if type(name) ~= 'string' or name == '' then
            return false, 'a callback name must be a non-empty string'
        end

        -- Where is the continuation?
        --
        -- ox_lib's positional preamble means its position is not fixed. It is
        -- found by type in the delay, target or cb slot, and the arguments for
        -- the handler come after the cb slot. A caller who wants to pass a
        -- function as a real argument is the rarer mistake to make.
        local args = table.pack(...)
        if callable(delay) then
            cb = delay
        elseif callable(target) then
            cb = target
        end

        -- `TryAwaitCallback`, never `AwaitCallback`.
        --
        -- Read out of cis_libs/server/callback.lua: `AwaitCallback` calls
        -- `error('callback %q: %s')` on a refusal, deliberately and loudly,
        -- because its result has one slot and a `false` would be
        -- indistinguishable from a handler that legitimately returned false.
        --
        -- That is the right decision for cis_libs and the wrong one here. This
        -- shim exists so a resource written against ox_lib keeps working, and
        -- ox_lib's `lib.callback.await` answers `false` on a missing handler
        -- rather than raising. Routing it through the raising form would take a
        -- missing callback -- a typo, on a server the customer is running -- and
        -- turn it into an exception inside a resource that never expected one.
        --
        -- `TryAwaitCallback` is the non-raising form and answers `ok, ...results`
        -- on success, `false, reason` on a refusal.
        local results = table.pack(engine:TryAwaitCallback(name, table.unpack(args, 1, args.n)))
        local ok = results[1]
        if not ok then
            -- Handed back exactly as received. A shim that reworded this would
            -- break every consumer branching on the string, and the string is
            -- the part that tells them what to do.
            return false, results[2]
        end
        local value = results[2]
        if callable(cb) then
            -- The legacy form answers nothing and runs the continuation. Calling
            -- it with every value is what ox_lib does, and a resource written
            -- that way calls `await` and waits -- so if this is dropped the
            -- resource hangs on that line for the rest of its life, silently.
            cb(value)
            return nil
        end
        return value
    end

    --- `lib.callback.send(name, delay, target, cb)` -- ox_lib's fire-and-forget form.
    ---
    --- This form does not wait, and it is a separate method, not a mode of
    --- `await`. `lib.callback.await('x')` always waits and returns the value,
    --- because a caller who writes `await` reads the next line as the answer.
    --- `lib.callback.send('x')` sends and returns nothing.
    ---
    --- ox_lib also lets a caller write `lib.callback(...)` on the table itself.
    --- The shim does not: GetLibShim crosses the export boundary as a msgpack
    --- copy, which drops metatables, so a `__call` would raise "attempt to call
    --- a table value" in the consumer.
    function lib.callback.send(name, _delay, _target, cb, ...)
        -- Read by fixed position, as ox_lib does, not by counting the varargs:
        -- delay and target may be nil, and a count would then forward the
        -- delay as the continuation.
        -- cis_libs' CallCallback refuses a missing continuation and drops the
        -- call, so a send without one gets one that does nothing.
        if not callable(cb) then
            cb = function() end
        end
        return engine:CallCallback(name, cb, ...)
    end


    --- `lib.callback.call(name, cb, ...)`
    function lib.callback.call(name, cb, ...)
        if not callable(cb) then
            return false, 'lib.callback.call needs a continuation'
        end
        return engine:CallCallback(name, cb, ...)
    end

    -- ------------------------------------------------------------------
    --  lib.zones
    -- ------------------------------------------------------------------

    --- `lib.zones.box`, `.sphere` and `.poly` answer `false, NO_ZONES`.
    function lib.zones.box() return false, NO_ZONES end
    function lib.zones.sphere() return false, NO_ZONES end
    function lib.zones.poly() return false, NO_ZONES end

    -- ------------------------------------------------------------------
    --  The `.remove()` style, which a string does not have
    -- ------------------------------------------------------------------

    --- Wrap a zone id in an object with `:remove()`, which is what every ox_lib
    --- resource calls. A bare string has no methods, and a resource that calls
    --- `zone:remove()` on one raises "attempt to index a string". Both methods
    --- answer `false, NO_ZONES` for the reason above.
    function lib.zone(id)
        if type(id) ~= 'string' then return false, NO_ZONES end
        -- Called as `zone:remove()`, so the first argument is the handle and is
        -- not read.
        local function refuse() return false, NO_ZONES end
        return { id = id, remove = refuse, contains = refuse }
    end

    return lib
end

CisBridgeLibShim = Shim

return Shim
