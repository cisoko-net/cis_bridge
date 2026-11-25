-- Adversarial payloads against the one surface a player can reach.
--
-- The conformance results are one of the two net events in this resource a
-- connected player may fire (the appearance reply is tested in test/v1.lua), and the security checklist says to treat it as if a cheat
-- menu were firing it as fast as it liked with any payload it liked. That is
-- what this file does -- not a sample of payloads, but the categories that have
-- actually broken things:
--
--   - a type that is not a table at all
--   - an enormous table (10,000 rows, and a row that is itself enormous)
--   - deep nesting, which is a stack-overflow primitive rather than a memory one
--   - rows whose shape is wrong: no `name`, a non-string `name`, a boolean
--   - strings carrying terminal escape sequences, so the console is rewritten
--   - strings carrying format specifiers, so a later `:format` misbehaves
--   - a flood, which is the one that matters: the handler prints
--
-- And the assertion is not "it did not raise". A handler that raises is a
-- finding, but a handler that quietly prints a megabyte of attacker-chosen text
-- into an operator's console is a worse one, so the checks here are on what
-- Reached the output.

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

-- ====================================================== the stub engine

local now = 0
local clock = function() return now end
local printed = {}
local realPrint = print

_G.GetGameTimer = clock
-- `Wait` advances the clock. It has to: the client suite's entity probe is
--
--     while not HasModelLoaded(hash) and GetGameTimer() < timeout do
--         RequestModel(hash); Wait(0)
--     end
--
-- and a `Wait` that does nothing leaves `GetGameTimer()` constant, so the
-- comparison never becomes false and the loop is infinite. The first version of
-- this stub did exactly that, and the suite spent its time in a VM spin rather
-- than reporting anything. A stub that hangs is worse than a missing stub: it
-- looks like a slow test.
-- A real frame advances the clock even when it waits zero milliseconds, which
-- is the whole contract of `GetGameTimer`: it is uptime. A stub that adds
-- exactly the requested amount makes `Wait(0)` a no-op, and the client suite's
-- model probe --
--
--     while not HasModelLoaded(hash) and GetGameTimer() < timeout do
--         RequestModel(hash); Wait(0)
--     end
--
-- never terminates. Advancing by at least one millisecond per call is what a
-- frame actually does, and it is the difference between a suite that runs and
-- a suite that spins.
_G.Wait = function(ms)
    now = now + math.max(tonumber(ms) or 0, 1)
end
-- A player picks their own name, so a test may hand one a hostile name.
local names = {}
_G.GetPlayerName = function(src) return names[src] or ('PLAYER_' .. tostring(src)) end
-- Who requestClient asks: the results handler only takes an answer it asked
-- for, so every case that expects output asks first (`ask` below).
local connected = {}
_G.GetPlayers = function() return connected end
_G.TriggerClientEvent = function() end
_G.GetResourceState = function() return 'missing' end
_G.GetCurrentResourceName = function() return 'cis_bridge' end
_G.GetResourceMetadata = function() return '1.0.0' end

-- `print` is recorded, not suppressed. The handler's whole job is to print, so
-- a suite that cannot see what it printed proves nothing about the only thing
-- that matters. The real one is restored before this file's own report.
_G.print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    printed[#printed + 1] = table.concat(parts, ' ')
end

local registeredEvents = {}
local registeredCommands = {}
_G.RegisterNetEvent = function(name, fn)
    registeredEvents[name] = registeredEvents[name] or {}
    table.insert(registeredEvents[name], fn)
end
local engineHandlers = {}
_G.AddEventHandler = function(name, fn)
    engineHandlers[name] = engineHandlers[name] or {}
    table.insert(engineHandlers[name], fn)
end
_G.RegisterCommand = function(name, fn, restricted)
    registeredCommands[name] = { handler = fn, restricted = restricted }
end
_G.exports = setmetatable({
    cis_libs = {
        WaitReady = function() return true end,
        GetConfigSummary = function() return nil end,
    },
}, {
    __call = function() end,
})

pcall(dofile, 'server/ratelimit.lua')

-- ====================================================== load the handler

local loaded, loadErr = pcall(dofile, 'server/conformance.lua')
check(loaded, 'server/conformance.lua loads against a stub engine'
    .. (loaded and '' or (': ' .. tostring(loadErr))))

local handlers = registeredEvents['cis_bridge:server:conformanceResults']
check(type(handlers) == 'table' and #handlers >= 1,
    'it registers a handler for cis_bridge:server:conformanceResults')

local fire = handlers and handlers[1]
if type(fire) ~= 'function' then
    fire = function() end
    check(false, 'no handler to test; the rest of this file would be vacuous')
end

-- `source` is FiveM's global and the handler reads it. Setting it is the only
-- way to drive the handler, and it is also the exact capability a cheat menu
-- has -- which is why the cases below treat `source` as an attacker choice and
-- check that a chosen value of 0 buys nothing.
local function fireUnasked(src, payload)
    _G.source = src
    local ok, err = pcall(fire, payload)
    return ok, err
end

-- requestClient opens one answer slot per asked player. Its own "asked N
-- client(s)" line is taken back out of the record, so the checks below count
-- only what the answer printed.
local function ask(src)
    connected = { tostring(src) }
    local before = #printed
    if CisBridgeConformance and CisBridgeConformance.requestClient then CisBridgeConformance.requestClient() end
    for i = #printed, before + 1, -1 do printed[i] = nil end
    connected = {}
end

-- The usual case: the server asked this player, and this is the answer.
local function fireAs(src, payload)
    ask(src)
    return fireUnasked(src, payload)
end

local function outputSince(mark)
    local n = #printed - mark
    return n, table.concat(printed, '\n', mark + 1, #printed)
end

-- ============================================== 1. Not a table
--
-- The cheapest thing a player can send and the one most often handled by
-- trusting. Each must be refused without printing and without raising.
for _, case in ipairs({
    { 'nil', nil },
    { 'a string', 'cis_bridge: please' },
    { 'a number', 42 },
    { 'a boolean', true },
    { 'a function', function() return 1 end },
    { 'a zero-length string', '' },
}) do
    local mark = #printed
    local ok, err = fireAs(7, case[2])
    check(ok, ('a payload that is %s does not raise'):format(case[1]))
    check(ok and select(1, outputSince(mark)) == 0,
        ('and prints nothing for a payload that is %s'):format(case[1]))
    if not ok then
        realPrint('  (raised: ' .. tostring(err) .. ')')
    end
end

-- ============================================== 2. src == 0 buys nothing
--
-- `source` is the identity the engine supplies, and a client cannot set it to
-- 0 -- but a handler that skips its checks on 0 is a handler whose checks are
-- only as good as the assumption that nobody can reach them.
do
    local mark = #printed
    fireAs(0, { { name = 'forged', ok = true } })
    check(select(1, outputSince(mark)) == 0,
        'a payload claiming source 0 prints nothing')
end

-- ============================================== 3. Malformed rows
--
-- A row is expected to be a table with a string `name`. Every other shape must
-- be skipped rather than printed, and skipped rows must not consume the row
-- budget -- otherwise 10,000 junk rows displace the one real result.
local mark = #printed
fireAs(8, {
    'not a table',
    42,
    true,
    {},
    { ok = true },
    { name = 42, ok = true },
    { name = {}, ok = true },
    { name = 'a real row', ok = true, detail = 'fine' },
})
local rows, text = outputSince(mark)
check(rows > 0, 'a well-formed row is still reported')
check(text:find('a real row', 1, true) ~= nil, 'and it is the one that appears')
check(text:find('forged', 1, true) == nil, 'nothing invented is printed')

-- ============================================== 4. An enormous table
--
-- 10,000 rows. The handler must print at most MAX_CLIENT_RESULTS and must say
-- so rather than truncating silently -- a silent truncation reads as "that is
-- all of them", which is a lie about the state of the platform.
local big = {}
for i = 1, 10000 do
    big[i] = { name = ('row %d'):format(i), ok = true }
end
mark = #printed
local okBig, errBig = fireAs(9, big)
check(okBig, 'a ten-thousand-row payload does not raise')
if not okBig then realPrint('  (raised: ' .. tostring(errBig) .. ')') end
rows, text = outputSince(mark)
-- One line per printed row, plus a blank, the header and the summary.
check(rows <= 70, ('printing is bounded at 70 lines for a ten-thousand-row payload (got %d)')
    :format(rows))
check(text:find('row 1,') ~= nil or text:find('row 1') ~= nil,
    'and it starts at the first row rather than the last')

-- One enormous row. A single row carrying a megabyte of text must be truncated
-- to the same length as any other.
local huge = { { name = string.rep('A', 1000000), ok = true, detail = string.rep('B', 1000000) } }
mark = #printed
local okHuge = fireAs(10, huge)
check(okHuge, 'a row carrying a megabyte of text does not raise')
rows, text = outputSince(mark)
check(#text < 5000, ('that row is truncated before printing (output was %d bytes)'):format(#text))

-- ============================================== 5. Deep nesting
--
-- A deeply nested table is a stack-overflow primitive in a serialiser, and the
-- engine's own deserialisation is not this handler's problem -- but a handler
-- that walks a client table has to survive being handed one. Ten thousand
-- levels is far past what any renderer can display and far past what a
-- `table.concat` can walk.
local deep = {}
local node = deep
for _ = 1, 10000 do
    node.next = {}
    node = node.next
end
mark = #printed
local okDeep, errDeep = fireAs(11, deep)
check(okDeep, 'a ten-thousand-deep nested payload does not raise')
if not okDeep then realPrint('  (raised: ' .. tostring(errDeep) .. ')') end
check(select(1, outputSince(mark)) == 0,
    'and prints nothing, because no row in it has a name')

-- ============================================== 6. Strings that attack the console
--
-- The output of this handler goes to an operator. A row that carries terminal
-- escape sequences can rewrite the console above the line the operator is
-- reading, and a very long `detail` is the same attack in one dimension.
local ESC = string.char(27)
mark = #printed
fireAs(12, {
    {
        name = 'evil',
        ok = false,
        detail = ESC .. '[2J' .. ESC .. '[H' .. string.rep('x', 5000),
    },
})
rows, text = outputSince(mark)
check(#text < 5000, ('an escape-sequence payload is truncated (%d bytes of output)'):format(#text))

-- A format specifier. The handler builds lines with `:format`, and a row
-- carrying `%s` in a field that is not passed to format is harmless -- but if
-- any future edit passes a row's text into `:format`, this is the payload that
-- turns it into an argument error. It is asserted here so that edit fails a
-- test rather than a customer's console.
mark = #printed
local okFmt = fireAs(13, {
    { name = '%s%d%s%s%s%s', ok = false, detail = '%s %s %s' },
})
check(okFmt, 'a row carrying format specifiers does not raise')
rows = select(1, outputSince(mark))
check(rows > 0, 'and is still reported, truncated rather than dropped')

-- ============================================== 7. The flood
--
-- The one that is not about payload shape. A cheat menu can fire this event
-- thousands of times a second, and each accepted call prints. So: one accepted
-- call, then refusals that print nothing.
now = 100000
mark = #printed
for _ = 1, 5000 do
    fireAs(14, { { name = 'flood', ok = true } })
end
rows = select(1, outputSince(mark))
check(rows > 0 and rows < 20,
    ('five thousand calls in one instant produce one report, not five thousand (got %d lines)')
        :format(rows))

-- A different source is unaffected. A global guard would let one player lock
-- every other player out of the report.
mark = #printed
fireAs(15, { { name = 'someone else', ok = true } })
check(select(1, outputSince(mark)) > 0, 'another player is not locked out by the first one')

-- And the window expires.
now = 100000 + 6000
mark = #printed
fireAs(14, { { name = 'after the window', ok = true } })
check(select(1, outputSince(mark)) > 0, 'the same player may report again once the window closes')

-- ============================================== 7b. Only asked-for answers
--
-- requestClient opens one slot per asked player, for 30 s. An answer nobody
-- asked for, a second answer, a late one, and one from a player who left are
-- all dropped before anything is printed.
now = 200000
mark = #printed
fireUnasked(20, { { name = 'nobody asked', ok = true } })
check(select(1, outputSince(mark)) == 0, 'an answer nobody asked for prints nothing')

mark = #printed
fireAs(21, { { name = 'asked once', ok = true } })
check(select(1, outputSince(mark)) > 0, 'an asked-for answer is printed')
now = now + 6000 -- past the cooldown, so only the slot can refuse it
mark = #printed
fireUnasked(21, { { name = 'second answer', ok = true } })
check(select(1, outputSince(mark)) == 0, 'a second answer to one request prints nothing')

ask(22)
now = now + 30001
mark = #printed
fireUnasked(22, { { name = 'too late', ok = true } })
check(select(1, outputSince(mark)) == 0, 'an answer after the 30 s slot closed prints nothing')

ask(23)
_G.source = 23
for _, h in ipairs(engineHandlers.playerDropped or {}) do h('Exiting') end
mark = #printed
fireUnasked(23, { { name = 'after leaving', ok = true } })
check(select(1, outputSince(mark)) == 0, 'playerDropped closes the slot')

-- ============================================== 7c. What a row prints
--
-- Label, status and, for a FAIL or a SKIP, the detail. The format once had
-- three slots for four arguments, so the label printed as 'client' and a FAIL
-- never said why.
now = now + 6000
mark = #printed
fireAs(24, {
    { name = 'row that passed', ok = true, detail = 'quiet' },
    { name = 'row that failed', ok = false, detail = 'the reason it failed' },
    { name = 'row that skipped', ok = true, skipped = true, detail = 'why it skipped' },
})
rows, text = outputSince(mark)
check(text:find('row that failed', 1, true) ~= nil and text:find('row that passed', 1, true) ~= nil,
    'each row prints its own label')
check(text:find('FAIL -- the reason it failed', 1, true) ~= nil, 'a FAIL prints its status and detail')
check(text:find('SKIP -- why it skipped', 1, true) ~= nil, 'a SKIP prints its status and detail')
check(text:find('PASS', 1, true) ~= nil and text:find('quiet', 1, true) == nil, 'a PASS prints no detail')

-- Control characters and FiveM colour codes are stripped from everything a
-- client chose: the row and the player's own name.
names[25] = '^1ADMIN' .. ESC .. '[2J'
mark = #printed
fireAs(25, { { name = 'evil^2' .. ESC .. '[H', ok = false, detail = '^3x' .. ESC .. '[1A' } })
rows, text = outputSince(mark)
check(rows > 0 and text:find(ESC, 1, true) == nil, 'no control character from a client reaches the console')
check(rows > 0 and text:find('^', 1, true) == nil, 'no colour code from a client reaches the console')

-- The walk stops at the bound: a payload far past MAX_CLIENT_RESULTS is not
-- visited row by row. Counted through __index, which ipairs reads.
local reads = 0
local counted = setmetatable({}, {
    __index = function(_, i)
        reads = reads + 1
        if type(i) == 'number' and i >= 1 and i <= 10000 then return { name = 'r' .. i, ok = true } end
        return nil
    end,
    __len = function() return 10000 end,
})
now = now + 6000
mark = #printed
fireAs(26, counted)
rows, text = outputSince(mark)
check(reads <= 66, ('the handler stops reading at the bound (read %d rows)'):format(reads))
check(text:find('9936 skipped', 1, true) ~= nil, 'and still counts the rows it dropped')

-- ============================================== 8. The command
--
-- `cis_bridge` is the one restricted command. It is refused for any player, and
-- the refusal says console only: the handler refuses every src ~= 0 on top of
-- `restricted`, so no add_ace line could open it, and none is offered.
local cmd = registeredCommands['cis_bridge']
check(type(cmd) == 'table' and type(cmd.handler) == 'function', 'the cis_bridge command exists')
check(cmd and cmd.restricted == true, 'and is registered as restricted')
if cmd then
    mark = #printed
    cmd.handler(0, {})            -- console: the allowed path
    cmd.handler(3, {})            -- a player: must be refused
    local _, out = outputSince(mark)
    check(out:find('server console command', 1, true) ~= nil,
        'a player is told it is a console command')
    check(out:find('cannot be run in game', 1, true) ~= nil,
        'and is told it cannot be run in game')
    -- The handler refuses every src ~= 0, so an ACE line could never open it.
    check(out:find('add_ace', 1, true) == nil,
        'and is not offered an add_ace line that could never work')
end

-- The client-side command is deliberately not restricted -- a developer testing
-- a target adapter should not have to be a server admin -- so its allocation is
-- bounded by a cooldown instead. It lives in the client file, so the client
-- file is loaded here too; checking for it without loading the file would be an
-- assertion that passes by never finding the command, which is the first version
-- of this line and is a test that cannot fail.
-- Enough of a client for the suite to actually run, which the first version of
-- this did not and the result was a test that could not fail.
--
-- With no target provider the client half printed "skipping client conformance"
-- four times and the cooldown assertion counted a string it never saw, so it
-- passed whether or not the cooldown existed. A guard assertion against code
-- that never reaches its subject is not a weak assertion; it is an absent one.
-- The v1 client API, answering yes to everything, so `run()` reaches every
-- check instead of stopping at the no-target skip.
_G.CisBridgeClientV1 = {
    getPlayerData = function() return {} end,
    isLoaded = function() return true end,
    notify = function() return false, 'bad_message' end,
    addTargetZone = function() return true end,
    addTargetEntity = function() return true end,
    removeTarget = function() return true end,
}
-- FiveM builds a vector3 with `vector3()`, not with a table constructor, and the
-- client suite calls both. Stubbing only `vec3` left `vector3` nil, so the first
-- run of the client command raised inside its own zone creation -- a failure in
-- the test, and worth surfacing rather than swallowing, because a stub that is
-- missing is invisible until it is the thing being measured.
_G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
_G.vector3 = _G.vec3
-- The entity probe. Returning false from the model request short-circuits the
-- client suite's one spawn, so the check that matters -- how often the command
-- may be run -- is not entangled with whether a ped could be created in a VM
-- with no game.
_G.GetHashKey = function() return 0 end
_G.HasModelLoaded = function() return false end
_G.RequestModel = function() end
_G.CreatePed = function() return 0 end
_G.DoesEntityExist = function() return false end
_G.DeleteEntity = function() end
_G.SetModelAsNoLongerNeeded = function() end
_G.SetEntityAsMissionEntity = function() end

local clientLoaded, clientErr = pcall(dofile, 'client/conformance.lua')
check(clientLoaded, 'client/conformance.lua loads against a stub engine'
    .. (clientLoaded and '' or (': ' .. tostring(clientErr))))

local clientCmd = registeredCommands['cis_bridge_client']
check(type(clientCmd) == 'table', 'the client command is registered')
check(clientCmd and clientCmd.restricted == false,
    'and is deliberately NOT restricted, so a developer can run it')
if clientCmd and type(clientCmd.handler) == 'function' then
    -- The command creates and removes a target and spawns a ped on every run,
    -- so an unthrottled one is a client-side allocation loop any player can
    -- start. Firing it four times must produce one report.
    mark = #printed
    for attempt = 1, 4 do
        local okc, errc = pcall(clientCmd.handler)
        check(okc, 'the client command does not raise')
        if not okc then
            realPrint('  (run ' .. attempt .. ' raised: ' .. tostring(errc) .. ')')
        end
    end
    local _, clientText = outputSince(mark)
    local reports = 0
    -- The exact header the client half prints. Keyed on the full string rather
    -- than a distinctive fragment, so a rename shows up as a failure rather than
    -- as a silently-zero count -- which is the failure this whole block was
    -- written to fix.
    for _ in clientText:gmatch('cis_bridge client conformance %-%-') do
        reports = reports + 1
    end
    check(reports >= 1,
        'and the client actually ran at least once, so the count below means something')
    check(reports <= 1,
        ('four runs of the client command produce at most one report (got %d)'):format(reports))
end

-- ------------------------------------------------------------------ report
_G.print = realPrint
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(handler): ' .. failures[i] .. '\n')
end
io.write(('handler passed=%d failed=%d\n'):format(passed, failed))
