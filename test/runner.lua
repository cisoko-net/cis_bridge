-- The conformance runner itself, headless.
--
-- The v1 API has its own suite (test/v1.lua), but the thing an operator
-- actually runs -- `cis_bridge test` -- is a separate piece of code, and a bug
-- in its tally is worse than a bug in a check: it reports the wrong answer
-- confidently and nothing downstream can tell.
--
-- What is asserted here is the runner, against a fake v1 API that holds its own
-- money and item counts:
--
--   - PASS, FAIL and SKIP are counted separately and the tally adds up;
--   - a missing v1 API, a missing framework and a contract that raises are each
--     reported, and none of them takes the runner down;
--   - a server with no door resource or no player SKIPs, it does not fail;
--   - `cis_bridge test` writes nothing: no money and no item moves unless the
--     operator names a player with `cis_bridge test write <id>`;
--   - the write round trip puts back exactly what it took;
--   - the console command parses its arguments and refuses a player caller.

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

local printed = {}
local realPrint = print
_G.print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
end

local function capture(fn, ...)
    local mark = #printed
    local ok, a, b = pcall(fn, ...)
    local out = {}
    for i = mark + 1, #printed do out[#out + 1] = printed[i] end
    return ok, table.concat(out, '\n'), a, b
end

local now = 0
local players = {}
local clientAsked = 0
_G.GetGameTimer = function() return now end
_G.Wait = function(ms) now = now + (tonumber(ms) or 0) end
_G.GetPlayers = function() return players end
_G.TriggerClientEvent = function() clientAsked = clientAsked + 1 end
_G.GetPlayerName = function() return 'PLAYER' end
_G.GetCurrentResourceName = function() return 'cis_bridge' end
_G.RegisterNetEvent = function() end
_G.AddEventHandler = function() end

local commands = {}
_G.RegisterCommand = function(name, fn, restricted)
    commands[name] = { handler = fn, restricted = restricted }
end
local declared = {}
_G.exports = setmetatable({}, {
    __call = function(_, name, fn) declared[name] = fn end,
})

-- ====================================================== the fake v1 API
--
-- Stateful, so a round trip can be checked by reading the balance back -- the
-- same way the real runner checks it. Every write is logged, which is how the
-- "reads only" promise is checked rather than assumed.

local function fakeV1(opts)
    opts = opts or {}
    local st = { cash = opts.cash or 10, bank = 5, items = { water = 0 }, writes = 0 }
    local function bad(src)
        return type(src) ~= 'number' or src < 1 or src % 1 ~= 0
    end
    local V = {}
    V.state = st
    V.redetect = function()
        if opts.detectRaises then error('detection exploded') end
        if opts.busy then return false, 'busy' end
        return true
    end
    V.summary = function()
        return {
            api = 1,
            framework = not opts.noFramework and 'qbox' or nil,
            inventory = not opts.noInventory and 'ox_inventory' or nil,
            doors = opts.doors,
        }
    end
    local function guard(fn)
        return function(...)
            if opts.raises then error('the adapter exploded') end
            return fn(...)
        end
    end
    V.getPlayer = guard(function(src)
        if bad(src) then return false, 'bad_source' end
        if opts.notLoaded then return false, 'not_loaded' end
        return { source = src }
    end)
    V.getJob = guard(function(src)
        if bad(src) then return false, 'bad_source' end
        return { name = 'unemployed', grade = 0 }
    end)
    V.getMoney = guard(function(src, acc)
        if bad(src) then return false, 'bad_source' end
        if opts.fractional then return st[acc] + 0.5 end
        return st[acc]
    end)
    V.getItemCount = guard(function(src, item)
        if bad(src) then return false, 'bad_source' end
        return st.items[item] or 0
    end)
    V.canCarry = guard(function(src)
        if bad(src) then return false, 'bad_source' end
        return true
    end)
    V.addMoney = guard(function(src, acc, n)
        if bad(src) and not opts.acceptsConsole then return false, 'bad_source' end
        st.writes = st.writes + 1
        st[acc] = st[acc] + n
        return true
    end)
    V.removeMoney = guard(function(src, acc, n)
        if bad(src) then return false, 'bad_source' end
        st.writes = st.writes + 1
        st[acc] = st[acc] - n
        return true
    end)
    V.addItem = guard(function(src, item, n)
        if bad(src) then return false, 'bad_source' end
        if opts.unknownItem then return false, 'unknown_item' end
        st.writes = st.writes + 1
        st.items[item] = (st.items[item] or 0) + n
        return true
    end)
    V.removeItem = guard(function(src, item, n)
        if bad(src) then return false, 'bad_source' end
        st.writes = st.writes + 1
        st.items[item] = (st.items[item] or 0) - n
        return true
    end)
    V.purchase = guard(function(src, order)
        if bad(src) then return false, 'bad_source' end
        if opts.unknownItem then return false, 'unknown_item' end
        st.writes = st.writes + 1
        st.cash = st.cash - order.price
        st.items[order.item] = (st.items[order.item] or 0) + order.count
        return true
    end)
    V.setJobLocked = guard(function(src)
        if bad(src) then return false, 'bad_source' end
        st.writes = st.writes + 1
        return true
    end)
    V.getDoorLock = guard(function(door)
        if type(door) ~= 'number' and type(door) ~= 'string' then return false, 'bad_door' end
        return false, 'no_doors'
    end)
    return V
end

local function tally(text)
    local p, f, s = text:match('cis_bridge: (%d+) passed, (%d+) failed, (%d+) skipped')
    return tonumber(p), tonumber(f), tonumber(s)
end

-- ------------------------------------------------------ load the runner

dofile('server/ratelimit.lua')
_G.CisBridgeV1 = nil
dofile('server/conformance.lua')

check(type(CisBridgeConformance) == 'table' and type(CisBridgeConformance.run) == 'function',
    'server/conformance.lua publishes CisBridgeConformance.run')
check(type(declared.RunConformance) == 'function', 'and exports RunConformance')
check(type(declared.GetConformanceResults) == 'function', 'and exports GetConformanceResults')
check(type(commands.cis_bridge) == 'table', 'and registers the cis_bridge command')
check(commands.cis_bridge and commands.cis_bridge.restricted == true,
    'which is restricted, so only the console or an ACE-granted admin runs it')

-- =====================================================================
--  1. No v1 API at all
-- =====================================================================
do
    _G.CisBridgeV1 = nil
    local ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok, 'a run with no v1 API does not raise')
    check(verdict == false, 'and fails, because nothing could be checked')
    check(text:find('the v1 API is loaded', 1, true) ~= nil and text:find('FAIL', 1, true) ~= nil,
        'and names the missing API as the failure')
    local p, f = tally(text)
    check(p == 0 and f == 1, ('and the tally is 0 passed, 1 failed (got %s, %s)'):format(tostring(p), tostring(f)))
end

-- =====================================================================
--  2. Healthy, no door resource, nobody online
-- =====================================================================
do
    players = {}
    clientAsked = 0
    _G.CisBridgeV1 = fakeV1()
    local ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok, 'a healthy run does not raise')
    check(verdict == true, 'and passes')
    check(text:find('reads only, nothing is written', 1, true) ~= nil,
        'and says in its header that it writes nothing')
    check(text:find('finds the framework (qbox)', 1, true) ~= nil, 'and names the framework it found')
    check(text:find('finds the inventory (ox_inventory)', 1, true) ~= nil, 'and the inventory')
    check(text:find('finds the door resource%s+SKIP') ~= nil,
        'no door resource is a SKIP, not a failure: plenty of servers have none')
    check(text:find('per%-player reads%s+SKIP') ~= nil,
        'nobody online is a SKIP that tells the operator to join')
    local p, f, s = tally(text)
    check(f == 0 and s == 2 and p == 10,
        ('the tally is 10 passed, 0 failed, 2 skipped (got %s, %s, %s)'):format(tostring(p), tostring(f), tostring(s)))
    check(clientAsked == 0, 'with nobody online, no client is asked to run its half')
    check(_G.CisBridgeV1.state.writes == 0, 'and nothing was written')
end

-- =====================================================================
--  3. The tally adds up against the results export
-- =====================================================================
do
    local rows = declared.GetConformanceResults()
    check(type(rows) == 'table' and #rows == 12, ('the results export holds every check (got %s)')
        :format(type(rows) == 'table' and #rows or type(rows)))
    local skipped = 0
    for _, r in ipairs(rows or {}) do
        if r.skipped then skipped = skipped + 1 end
    end
    check(skipped == 2, 'and marks the two skips as skipped')
end

-- =====================================================================
--  4. Players online: reads for every one, and still no write
-- =====================================================================
do
    players = { '1', '2' }
    clientAsked = 0
    _G.CisBridgeV1 = fakeV1()
    local ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok and verdict == true, 'a run with two players online passes')
    check(text:find('[player 1]', 1, true) ~= nil and text:find('[player 2]', 1, true) ~= nil,
        'and reads both players')
    check(text:find('GetMoney bank is a whole number', 1, true) ~= nil, 'including both money accounts')
    check(clientAsked == 2, ('and asks each client once to run its half (got %d)'):format(clientAsked))
    check(_G.CisBridgeV1.state.writes == 0, '`cis_bridge test` writes nothing to an online player')
end

-- =====================================================================
--  5. Contract breaches are FAILs with the answer in the line
-- =====================================================================
do
    players = { '1' }
    _G.CisBridgeV1 = fakeV1({ fractional = true, acceptsConsole = true })
    local ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok and verdict == false, 'a broken contract fails the run')
    check(text:find('AddMoney%(0%) is bad_source%s+FAIL') ~= nil,
        'an AddMoney that accepts the console as a player is a FAIL')
    check(text:find('GetMoney cash is a whole number%s+FAIL') ~= nil,
        'a fractional balance is a FAIL')
    check(text:find('answered %d+%.5') ~= nil, 'and the line says what the contract answered')
    local _, f = tally(text)
    check(f == 3, ('the tally counts each failure once (got %s)'):format(tostring(f)))
end

-- =====================================================================
--  6. A contract that raises everywhere
-- =====================================================================
do
    players = { '1' }
    _G.CisBridgeV1 = fakeV1({ raises = true })
    local ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok, 'an API that raises everywhere does not take the runner down')
    check(verdict == false, 'and the run fails')
    check(text:find('the refusal checks ran to completion%s+FAIL') ~= nil,
        'the refusal block reports that it stopped')
    check(text:find('the read checks ran to completion%s+FAIL') ~= nil,
        'and so does the per-player block')
    check(text:find('the adapter exploded', 1, true) ~= nil, 'with the error in the line')
    local p, f = tally(text)
    check(f == 2, ('one raise is one failure per block, not one per check (got %s)'):format(tostring(f)))
    check(p ~= nil, 'and the tally still prints')
end

-- =====================================================================
--  7. Detection that finds nothing, or raises
-- =====================================================================
do
    players = {}
    _G.CisBridgeV1 = fakeV1({ noFramework = true, noInventory = true })
    local ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok and verdict == false, 'no framework and no inventory fails the run')
    check(text:find('es_extended', 1, true) ~= nil, 'and names the frameworks it looked for')
    check(text:find('ox_inventory', 1, true) ~= nil, 'and the inventories')

    _G.CisBridgeV1 = fakeV1({ detectRaises = true })
    ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok, 'detection that raises does not take the runner down')
    check(verdict == false and text:find('detection ran%s+FAIL') ~= nil, 'and is one named FAIL')
    check(text:find('detection exploded', 1, true) ~= nil, 'with the error in the line')

    _G.CisBridgeV1 = fakeV1({ busy = true })
    ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok and verdict == false and text:find('detection ran%s+FAIL') ~= nil, 'a run during a write is one named FAIL')
    check(text:find('a write is in flight', 1, true) ~= nil, 'and says to run it again')
end

-- =====================================================================
--  8. The write round trip, on the named player only
-- =====================================================================
do
    players = { '1', '2' }
    local V = fakeV1({ cash = 10 })
    _G.CisBridgeV1 = V
    local ok, text, verdict = capture(CisBridgeConformance.run, 2, 'water')
    check(ok and verdict == true, 'the write round trip passes on a healthy API')
    check(text:find('writes to player 2, and undoes them', 1, true) ~= nil,
        'and its header names the one player it writes to')
    check(text:find('[write 2]', 1, true) ~= nil and text:find('[write 1]', 1, true) == nil,
        'and it writes to that player only')
    check(text:find('Purchase takes 1 cash and gives 1 item%s+PASS') ~= nil, 'the purchase is checked')
    check(text:find('the purchase is undone%s+PASS') ~= nil, 'and undone')
    check(V.state.cash == 10 and V.state.items.water == 0,
        ('and the player ends where they started (cash %s, water %s)')
            :format(tostring(V.state.cash), tostring(V.state.items.water)))
    check(V.state.writes > 0, 'and it really wrote, so the check above means something')

    V = fakeV1({ cash = 0, unknownItem = true })
    _G.CisBridgeV1 = V
    ok, text, verdict = capture(CisBridgeConformance.run, 1, 'nope')
    check(ok and verdict == true, 'an unknown item and no cash are SKIPs, not failures')
    check(text:find('AddItem nope 1%s+SKIP') ~= nil, 'the item SKIP names the item')
    check(text:find('has no cash to spend', 1, true) ~= nil, 'and the purchase SKIP says why')
    check(V.state.cash == 0, 'and the balance is back where it started')

    V = fakeV1({ notLoaded = true })
    _G.CisBridgeV1 = V
    ok, text, verdict = capture(CisBridgeConformance.run, 1)
    check(ok and verdict == false, 'naming a player who is not loaded is a FAIL')
    check(text:find('the named player is loaded%s+FAIL') ~= nil, 'with that as the line')
    check(V.state.writes == 0, 'and nothing is written to them')

    -- A player still on the character screen is a SKIP. A player the framework
    -- itself holds, while GetPlayer answers not_loaded, is a broken bridge read
    -- (the ESX funcref bug read every player that way): a FAIL.
    players = { '1' }
    V = fakeV1({ notLoaded = true })
    V.frameworkHasPlayer = function() return false end
    _G.CisBridgeV1 = V
    ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok and verdict == true, 'a player with no character loaded is not a failure')
    check(text:find('player 1%] is loaded%s+SKIP') ~= nil, 'it is a SKIP: ' .. tostring(text))

    V = fakeV1({ notLoaded = true })
    V.frameworkHasPlayer = function() return true end
    _G.CisBridgeV1 = V
    ok, text, verdict = capture(CisBridgeConformance.run)
    check(ok and verdict == false, 'not_loaded for a player the framework holds is a FAIL')
    check(text:find('player 1%] is loaded%s+FAIL') ~= nil, 'with that as the line: ' .. tostring(text))
    check(text:find('the framework holds this player', 1, true) ~= nil, 'and it says why')
end

-- =====================================================================
--  9. The console command
-- =====================================================================
do
    local handler = commands.cis_bridge and commands.cis_bridge.handler
    players = { '1' }
    local V = fakeV1()
    _G.CisBridgeV1 = V
    local rendered = 0
    _G.CisBridgeReport = { render = function() rendered = rendered + 1 end }

    local ok, text = capture(handler, 0, { 'test' })
    check(ok and text:find('reads only', 1, true) ~= nil, '`cis_bridge test` runs the read-only suite')
    check(V.state.writes == 0, 'and writes nothing')

    ok, text = capture(handler, 0, {})
    check(ok and text:find('reads only', 1, true) ~= nil, 'bare `cis_bridge` runs it too')

    ok, text = capture(handler, 0, { 'test', 'write', '1', 'water' })
    check(ok and text:find('writes to player 1', 1, true) ~= nil, '`cis_bridge test write 1 water` writes')
    check(V.state.cash == 10 and V.state.items.water == 0, 'and puts everything back')
    ok, text = capture(handler, 0, { 'test', 'write', '65535' })
    check(ok and text:find('writes to player 65535', 1, true) ~= nil, 'the largest server id writes')

    local before = V.state.writes
    ok, text = capture(handler, 0, { 'test', 'write', 'abc' })
    check(ok and text:find('usage: cis_bridge test write', 1, true) ~= nil, 'a non-numeric id prints usage')
    ok, text = capture(handler, 0, { 'test', 'write', '1.5' })
    check(ok and text:find('usage: cis_bridge test write', 1, true) ~= nil, 'a fractional id prints usage')
    -- 1e300 is a whole number to `% 1`, and `%d` cannot format it.
    for _, id in ipairs({ '1e300', '65536', 'inf', 'nan', '0' }) do
        ok, text = capture(handler, 0, { 'test', 'write', id })
        check(ok and text:find('usage: cis_bridge test write', 1, true) ~= nil,
            ('an id of %s prints usage (got %s)'):format(id, tostring(text)))
    end
    ok, text = capture(handler, 0, { 'test', 'write', '1', 'water;drop' })
    check(ok and text:find('characters no inventory uses', 1, true) ~= nil, 'an item with odd characters is refused')
    check(V.state.writes == before, 'and none of the refused forms wrote anything')

    ok = capture(handler, 0, { 'report' })
    check(ok and rendered == 1, '`cis_bridge report` renders the report')

    ok, text = capture(handler, 0, { 'bogus' })
    check(ok and text:find('usage: cis_bridge test |', 1, true) ~= nil, 'an unknown argument prints usage')

    ok, text = capture(handler, 5, { 'test', 'write', '5' })
    check(ok and text:find('server console command', 1, true) ~= nil, 'a player caller is told to use the console')
    -- No ACE can open it (the handler refuses every src ~= 0), so none is offered.
    check(text:find('add_ace', 1, true) == nil,
        'and is not offered an ACE line that could never open it')
    check(V.state.writes == before, 'and a player caller writes nothing')
    _G.CisBridgeReport = nil
end

-- ------------------------------------------------------------------ report
_G.print = realPrint
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(runner): ' .. failures[i] .. '\n')
end
io.write(('runner passed=%d failed=%d\n'):format(passed, failed))
