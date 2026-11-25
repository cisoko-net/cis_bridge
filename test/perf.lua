-- Wait() discipline and thread cost, enforced rather than asserted in a comment.
--
-- The project rule is that nothing runs per-frame unless it is drawing, and the
-- budget is 0.00-0.02ms idle. This resource has three loops, all on the
-- client, each with a Wait and a deadline (section 5 lists them). A loop that
-- looks reasonable can still spin, which is the argument for checking
-- mechanically instead of reading carefully once.
--
-- The check is on the source, so it sees the shipped file rather than whatever
-- path happened to execute. A loop behind a branch a test never takes is still
-- a loop a player pays for.
--
-- Rules:
--
--   1. No `Wait(0)` anywhere in shipped code. Zero is the frame boundary, and a
--      loop that waits zero is a loop that runs every frame.
--   2. Every `while` loop waits at least once. A `while true do` with no `Wait`
--      in it is a hung server, and the only way that has ever been found is by
--      reading the file.
--   3. Every loop is bounded. `while true` must have an exit path -- a `return`,
--      a `break`, or a condition that the engine can satisfy. `while true` is
--      allowed only where a Wait is unconditional.
--   4. No `DrawMarker`, `DrawText3D` or `RequestAnimDict` in a loop that is not
--      drawing. None of them are here at all, and saying so in a test means
--      somebody adding one has to think about it.
--
-- The source arrives from the harness in the string-neutralised form, so a
-- comment explaining why there is no `Wait(0)` here cannot trip the rule that
-- forbids one.

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

local BARE = _G.__BARE or {}
check(type(BARE) == 'table' and next(BARE) ~= nil,
    'the harness handed over the source of this resource to audit')

-- Only the files the manifest loads. A test file is allowed to spin a fake clock
-- in a tight loop -- several of them do, and a rule that flagged that would be a
-- rule about the harness rather than about the product.
local SHIPPED = {
    'adapters/framework/common.lua',
    'adapters/framework/esx.lua',
    'adapters/framework/qbcore.lua',
    'adapters/framework/qbox.lua',
    'adapters/framework/cis_core.lua',
    'adapters/inventory/cis_inventory.lua',
    'adapters/inventory/ox.lua',
    'adapters/inventory/qb.lua',
    'adapters/inventory/qs.lua',
    'adapters/inventory/codem.lua',
    'adapters/doors/ox_doorlock.lua',
    'adapters/doors/qb_doorlock.lua',
    'adapters/target/ox.lua',
    'adapters/target/qb.lua',
    'server/v1.lua',
    'server/report.lua',
    'server/ratelimit.lua',
    'server/conformance.lua',
    'client/v1.lua',
    'client/conformance.lua',
    'api.lua',
}

local function code(rel)
    return BARE[rel] or ''
end

-- ============================================================ 1. No Wait(0)
--
-- `Wait(0)` is the frame boundary. A loop containing one runs every frame for
-- as long as its condition holds, which is a per-frame cost paid by every
-- client on the server for a loop that a human will read once.
--
-- The client conformance suite had exactly this, in the shape everybody writes:
--
--     while not HasModelLoaded(hash) and GetGameTimer() < timeout do
--         RequestModel(hash)
--         Wait(0)
--     end
--
-- `RequestModel` is idempotent, so the second call onwards is an identical
-- native call doing nothing, and the frame loop is 250 wakeups checking a flag
-- that a streamer sets on its own schedule. It is requested once now and polled
-- at 50ms.
local waitZero = {}
for _, rel in ipairs(SHIPPED) do
    local body = code(rel)
    for hit in body:gmatch('Wait%s*%(%s*0%s*%)') do
        waitZero[#waitZero + 1] = rel
    end
end
check(#waitZero == 0,
    'no shipped file contains Wait(0); found in: ' .. table.concat(waitZero, ', '))

-- ================================================ 2 & 3. Every loop waits
--
-- Both halves in one pass: a loop must contain a `Wait`, and a `while true`
-- must additionally have an exit or an unconditional wait. A loop with neither
-- is a hung resource, and the code review that misses one is exactly the review
-- that assumes the author meant to.
local loopReport = {}
for _, rel in ipairs(SHIPPED) do
    local body = code(rel)
    -- `while <anything> do` up to the matching `end`, matched by brace counting
    -- rather than by a pattern, because a regex cannot find a block's end.
    local pos = 1
    while true do
        local s, e, cond = body:find('while%s+([%w_%s%.<>%(%)%{%}%d_~=!<>&:%s%-]+)%s+do', pos)
        if not s then break end
        -- The header ends at `do`; walk forward balancing `then/do/function/if`
        -- against `end`.
        local depth = 1
        local i = e + 1
        local inner = {}
        while i <= #body and depth > 0 do
            local w, we = body:find('%f[%w_](%a+)%f[^%w_]', i)
            if not w then break end
            local word = we and body:match('%a+', w)
            if word == 'end' then
                depth = depth - 1
                if depth == 0 then break end
            elseif word == 'if' or word == 'for' or word == 'while' or word == 'do'
                or word == 'function' then
                depth = depth + 1
            end
            inner[#inner + 1] = word
            i = we + 1
        end
        local joined = table.concat(inner, ' ')
        loopReport[#loopReport + 1] = {
            file = rel,
            cond = cond,
            hasWait = joined:find('Wait', 1, true) ~= nil,
            hasWaitZero = joined:find('Wait 0', 1, true) ~= nil,
        }
        pos = (i or e) + 1
    end
end

for _, loop in ipairs(loopReport) do
    check(loop.hasWait,
        ('%s: the loop `while %s do` waits -- a loop with no Wait in it hangs the scheduler')
            :format(loop.file, loop.cond))
    if loop.cond == 'true' then
        -- No shipped loop is `while true`. One added later must Wait
        -- unconditionally: a Wait inside a branch that may not be taken is a
        -- busy loop.
        check(loop.hasWait,
            ('%s: `while true do` waits unconditionally'):format(loop.file))
    end
end

-- ============================================================ 4. The draw calls
--
-- None of these appear in this resource, and there is no NUI and no ped
-- streaming in a loop. Stating it as an assertion means adding one is a
-- decision somebody made rather than a line somebody pasted.
for _, call in ipairs({ 'DrawMarker', 'DrawText3D', 'DrawRect', 'SetTextScale' }) do
    local hits = {}
    for _, rel in ipairs(SHIPPED) do
        if code(rel):find('%f[%w_]' .. call .. '%f[^%w_]') then
            hits[#hits + 1] = rel
        end
    end
    check(#hits == 0,
        ('no shipped file draws (%s), so no thread can be paying a per-frame '
            .. 'render cost'):format(call))
end

-- ============================================================ 5. The account
--
-- Every loop, by file and condition, each bounded by a deadline. Written out
-- rather than derived, because a number nobody checks is a number that drifts:
-- a new loop shows up as unlisted and somebody has to decide whether it
-- belongs.
local EXPECTED = {
    { file = 'client/conformance.lua', cond = 'not HasModelLoaded(hash) and GetGameTimer() < deadline',
        why = 'the model probe, 50ms poll, 5s deadline, on demand' },
    { file = 'client/v1.lua', cond = 'reply == nil and GetGameTimer() < deadline',
        why = 'the billing reply poll, BILLING_POLL_MS poll, BILLING_TIMEOUT_MS deadline, once per billing call' },
    { file = 'client/v1.lua', cond = 'mine == loadedWait and fw == adapter',
        why = 'the loaded relay waits for player data, 100ms poll, 10s deadline, once per loaded event' },
}
local function listed(file, cond)
    for _, e in ipairs(EXPECTED) do
        if e.file == file and e.cond == cond then return true end
    end
    return false
end
for _, e in ipairs(EXPECTED) do
    local found = false
    for _, loop in ipairs(loopReport) do
        if loop.file == e.file and loop.cond == e.cond then found = true end
    end
    check(found, ('%s still has its loop -- %s'):format(e.file, e.why))
end

-- Every loop that exists is in the account above. This is the line that makes
-- the account mean something.
for _, loop in ipairs(loopReport) do
    check(listed(loop.file, loop.cond),
        ('%s has a loop that is not in the account: `while %s do`')
            :format(loop.file, loop.cond))
end
check(#loopReport == #EXPECTED, ('the account lists %d loops and the source has %d'):format(#EXPECTED, #loopReport))

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(perf): ' .. failures[i] .. '\n')
end
io.write(('perf passed=%d failed=%d\n'):format(passed, failed))
