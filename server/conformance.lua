-- Conformance for the v1 product API: what `cis_bridge test` runs.
--
-- Why this exists
--
-- Third-party resources change under us, and every one of those changes
-- arrived here as a bug report that looked like a bug in somebody's server.
-- The unit suites run every contract against fakes that follow each
-- framework's source; this runs the same contracts against the framework and
-- inventory this server really has, so a fake that drifted from upstream shows
-- up as a FAIL here and not as a customer's lost money.
--
-- What a check is pointed at
--
-- At the v1 contracts themselves (server/v1.lua), the functions the exports
-- bind.
--
-- Nothing is written by default. `cis_bridge test` reads: detection, the
-- refusals every contract owes a bad argument, and each loaded player's job,
-- balances and one item count. The write round trip changes a real player's
-- money and items, so it runs only when the operator names the player:
--
--      cis_bridge test                      -- detection, refusals, reads
--      cis_bridge test write <id> [item]    -- also +1/-1 cash and item, and a
--                                              1-cash purchase that is undone
--      cis_bridge report                    -- what was detected, and the fix
--
-- Every write in the round trip is paired with its reverse, so a passing run
-- leaves the player as it found them. A failing one says which step failed and
-- what is left to put back by hand.

-- Published by server/ratelimit.lua, which fxmanifest loads before this file.
-- FiveM scripts have no `require`, so it is a global.
local Cooldown = CisBridgeRateLimit

CisBridgeConformance = {}

local results = {}

local function record(target, name, ok, detail)
    results[#results + 1] = {
        target = target, name = name, ok = ok and true or false, detail = detail,
    }
    print(('  [%s] %-46s %s%s'):format(
        target, name,
        ok and 'PASS' or 'FAIL',
        (not ok and detail) and (' -- ' .. tostring(detail)) or ''))
    return ok
end

-- SKIP is not FAIL. A check that cannot run on this server (no player online,
-- no door resource) is not a broken contract. Recorded as ok so a skip never
-- turns a green run red, and flagged so the tally can say how many checks did
-- not actually execute.
local function skip(target, name, detail)
    results[#results + 1] = {
        target = target, name = name, ok = true, skipped = true, detail = detail,
    }
    print(('  [%s] %-46s %s%s'):format(
        target, name, 'SKIP', detail and (' -- ' .. tostring(detail)) or ''))
    return true
end

local function api()
    return CisBridgeV1
end

-- `false, reason` from a contract, as one detail string.
local function said(a, b)
    return ('answered %s, %s'):format(tostring(a), tostring(b))
end

-- ===========================================================================
--  Detection
-- ===========================================================================

local FRAMEWORKS = 'qbx_core, es_extended, qb-core or cis_core'
local INVENTORIES = 'cis_inventory, ox_inventory, qs-inventory, codem-inventory, qb-inventory or the framework\'s own'

local function detection(summary)
    if summary.framework then
        record('detect', 'finds the framework (' .. summary.framework .. ')', true)
    else
        record('detect', 'finds the framework', false,
            'none of ' .. FRAMEWORKS .. ' is started before cis_bridge')
    end
    if summary.inventory then
        record('detect', 'finds the inventory (' .. summary.inventory .. ')', true)
    else
        record('detect', 'finds the inventory', false, 'none of ' .. INVENTORIES .. ' answered')
    end
    if summary.doors then
        record('detect', 'finds the door resource (' .. summary.doors .. ')', true)
    else
        skip('detect', 'finds the door resource', 'no ox_doorlock or qb-doorlock is started')
    end
end

-- ===========================================================================
--  Refusals: every contract owes a bad argument `false, reason`, never a raise
--  and never a write. Source 0 is the console, which is not a player.
-- ===========================================================================

local function refusals(V)
    local function expect(name, want, ok, why)
        record('refuse', name, ok == false and why == want, said(ok, why) .. ', expected false, ' .. want)
    end
    expect('GetPlayer(0) is bad_source', 'bad_source', V.getPlayer(0))
    expect('GetMoney(0) is bad_source', 'bad_source', V.getMoney(0, 'cash'))
    expect('AddMoney(0) is bad_source', 'bad_source', V.addMoney(0, 'cash', 1))
    expect('RemoveMoney(0) is bad_source', 'bad_source', V.removeMoney(0, 'cash', 1))
    expect('AddItem(0) is bad_source', 'bad_source', V.addItem(0, 'water', 1))
    expect('Purchase(0) is bad_source', 'bad_source', V.purchase(0, { item = 'water', count = 1, price = 1 }))
    expect('SetJob(0) is bad_source', 'bad_source', V.setJobLocked(0, 'unemployed', 0))
    expect('GetDoorLock({}) is bad_door', 'bad_door', V.getDoorLock({}))
end

-- ===========================================================================
--  Reads, for every connected player. Nothing here writes.
-- ===========================================================================

local PROBE_ITEM = 'water'

local function reads(V, src)
    local who = 'player ' .. src
    local p, why = V.getPlayer(src)
    if p == false then
        -- not_loaded is a SKIP only while the framework itself has no player
        -- either. When it holds one, a bridge read is broken (the ESX funcref
        -- bug answered not_loaded for every player), and that must not pass.
        if why == 'not_loaded' and V.frameworkHasPlayer and V.frameworkHasPlayer(src) == true then
            record(who, 'is loaded', false,
                'the framework holds this player, but GetPlayer answered not_loaded: a bridge read is broken')
            return
        end
        skip(who, 'is loaded', 'GetPlayer ' .. tostring(why))
        return
    end
    record(who, 'GetPlayer answers a table', type(p) == 'table', said(p, why))
    local job, jwhy = V.getJob(src)
    record(who, 'GetJob answers name and grade',
        type(job) == 'table' and type(job.name) == 'string' and type(job.grade) == 'number', said(job, jwhy))
    for _, acc in ipairs({ 'cash', 'bank' }) do
        local bal, bwhy = V.getMoney(src, acc)
        record(who, 'GetMoney ' .. acc .. ' is a whole number',
            type(bal) == 'number' and bal % 1 == 0, said(bal, bwhy))
    end
    local n, nwhy = V.getItemCount(src, PROBE_ITEM)
    record(who, 'GetItemCount ' .. PROBE_ITEM .. ' is a count', type(n) == 'number' and n >= 0, said(n, nwhy))
    local c, cwhy = V.canCarry(src, PROBE_ITEM, 1)
    record(who, 'CanCarry ' .. PROBE_ITEM .. ' answers', c == true or (c == false and type(cwhy) == 'string'),
        said(c, cwhy))
end

-- ===========================================================================
--  The write round trip: named player only
-- ===========================================================================

local function writes(V, src, item)
    local who = 'write ' .. src
    local p, why = V.getPlayer(src)
    if p == false then
        record(who, 'the named player is loaded', false, 'GetPlayer ' .. tostring(why))
        return
    end

    local before = V.getMoney(src, 'cash')
    local ok, w = V.addMoney(src, 'cash', 1, 'cis_bridge test')
    local after = V.getMoney(src, 'cash')
    record(who, 'AddMoney cash 1 moves the balance by 1',
        ok == true and type(before) == 'number' and after == before + 1,
        said(ok, w) .. (' (%s -> %s)'):format(tostring(before), tostring(after)))
    if ok == true then
        local back, bw = V.removeMoney(src, 'cash', 1, 'cis_bridge test')
        local final = V.getMoney(src, 'cash')
        record(who, 'RemoveMoney cash 1 puts it back', back == true and final == before,
            said(back, bw) .. (' (now %s, started %s)'):format(tostring(final), tostring(before)))
    end

    local c0 = V.getItemCount(src, item)
    local added, aw = V.addItem(src, item, 1)
    local c1 = V.getItemCount(src, item)
    if added == false and (aw == 'unknown_item' or aw == 'cannot_carry') then
        skip(who, 'AddItem ' .. item .. ' 1', 'answered ' .. aw .. '; name an item this server has, or free a slot')
    else
        record(who, 'AddItem ' .. item .. ' 1 moves the count by 1',
            added == true and type(c0) == 'number' and c1 == c0 + 1,
            said(added, aw) .. (' (%s -> %s)'):format(tostring(c0), tostring(c1)))
        if added == true then
            local gone, gw = V.removeItem(src, item, 1)
            local c2 = V.getItemCount(src, item)
            record(who, 'RemoveItem ' .. item .. ' 1 puts it back', gone == true and c2 == c0,
                said(gone, gw) .. (' (now %s, started %s)'):format(tostring(c2), tostring(c0)))
        end
    end

    -- A 1-cash purchase, then its reverse by hand: proves the order path takes
    -- the money once and gives the item once on this framework.
    local m0, i0 = V.getMoney(src, 'cash'), V.getItemCount(src, item)
    if type(m0) ~= 'number' or m0 < 1 then
        skip(who, 'Purchase ' .. item .. ' x1 for 1 cash', 'the player has no cash to spend')
        return
    end
    local bought, pw = V.purchase(src, { item = item, count = 1, price = 1, reason = 'cis_bridge test' })
    local m1, i1 = V.getMoney(src, 'cash'), V.getItemCount(src, item)
    if bought == false and (pw == 'unknown_item' or pw == 'cannot_carry') then
        skip(who, 'Purchase ' .. item .. ' x1 for 1 cash', 'answered ' .. pw)
        return
    end
    record(who, 'Purchase takes 1 cash and gives 1 item',
        bought == true and m1 == m0 - 1 and i1 == i0 + 1,
        said(bought, pw) .. (' (cash %s -> %s, item %s -> %s)')
            :format(tostring(m0), tostring(m1), tostring(i0), tostring(i1)))
    if bought == true then
        local r1 = V.removeItem(src, item, 1)
        local r2 = V.addMoney(src, 'cash', 1, 'cis_bridge test')
        record(who, 'the purchase is undone', r1 == true and r2 == true
            and V.getMoney(src, 'cash') == m0 and V.getItemCount(src, item) == i0,
            ('RemoveItem %s, AddMoney %s; put back by hand what is left'):format(tostring(r1), tostring(r2)))
    end
end

-- ===========================================================================
--  The runner
-- ===========================================================================

--- Run the suite. `writeSrc` names the one player the write round trip may
--- touch; without it nothing is written.
function CisBridgeConformance.run(writeSrc, item)
    results = {}
    print('')
    print(writeSrc and ('cis_bridge conformance -- writes to player %d, and undoes them'):format(writeSrc)
        or 'cis_bridge conformance -- reads only, nothing is written to a player')
    print('')

    local V = api()
    if type(V) ~= 'table' then
        record('detect', 'the v1 API is loaded', false, 'server/v1.lua did not load; read the boot log')
        V = nil
    end

    if V then
        local okDetect, ran, derr = pcall(V.redetect)
        if okDetect and ran == false then
            okDetect, derr = false, ('a write is in flight (%s); run conformance again'):format(tostring(derr))
        elseif not okDetect then
            derr = ran
        end
        local okSummary, summary = pcall(V.summary)
        if not okDetect or not okSummary or type(summary) ~= 'table' then
            record('detect', 'detection ran', false, tostring(not okDetect and derr or summary))
        else
            detection(summary)
        end
        local okRefuse, err = pcall(refusals, V)
        if not okRefuse then record('refuse', 'the refusal checks ran to completion', false, tostring(err)) end

        local players = 0
        for _, id in ipairs(GetPlayers()) do
            local src = tonumber(id)
            if src then
                players = players + 1
                local okRead, rerr = pcall(reads, V, src)
                if not okRead then
                    record('player ' .. src, 'the read checks ran to completion', false, tostring(rerr))
                end
            end
        end
        if players == 0 then
            skip('player', 'per-player reads', 'no player is connected; join and run it again')
        end

        if writeSrc then
            local okWrite, werr = pcall(writes, V, writeSrc, item or PROBE_ITEM)
            if not okWrite then
                record('write ' .. writeSrc, 'the round trip ran to completion', false, tostring(werr))
            end
        end
    end

    local notRun, failed, passed = 0, 0, 0
    for _, r in ipairs(results) do
        if r.skipped then
            notRun = notRun + 1
        elseif not r.ok then
            failed = failed + 1
        else
            passed = passed + 1
        end
    end

    print('')
    print(('cis_bridge: %d passed, %d failed, %d skipped'):format(passed, failed, notRun))
    if CisBridgeConformance.requestClient then
        CisBridgeConformance.requestClient()
    end
    return failed == 0
end

--- Run the read-only suite from another resource. It writes nothing to a
--- player: a write run needs the console, where the operator names the player.
--- It also sends `cis_bridge:client:conformance` to every connected player,
--- whose client spawns a test ped and creates and removes one target zone.
--- Answers true when no server check failed.
exports('RunConformance', function()
    return CisBridgeConformance.run()
end)

--- The last run's results, for a support thread. No data is sent anywhere --
--- this is an export the operator calls deliberately.
exports('GetConformanceResults', function()
    local out = {}
    for _, r in ipairs(results) do
        out[#out + 1] = r
    end
    return out
end)

--- Ask every connected client to run its half, and print what comes back.
---
--- The answer arrives as a table of results. An untrusted client can send
--- anything, so this prints and counts, and never treats a client's PASS as
--- proof of anything the server did not check itself.
---
--- Each asked player gets one answer slot, open for PENDING_MS. The results
--- handler below takes an answer only into an open slot and closes it, so a
--- player nobody asked has nothing to fill, and an asked one answers once.
local PENDING_MS = 30000
local pending = {}

function CisBridgeConformance.requestClient()
    local asked = 0
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then
            pending[src] = GetGameTimer() + PENDING_MS
            TriggerClientEvent('cis_bridge:client:conformance', src)
            asked = asked + 1
        end
    end
    print(('cis_bridge: asked %d client(s) to run their half of the conformance suite'):format(asked))
    return asked
end

-- A client answers with a table of rows. Bounded, because the sender is any
-- connected player and this handler prints whatever it is given.
local MAX_CLIENT_RESULTS = 64

-- Every connected player can fire the results event below, and each accepted
-- call prints. A per-source cooldown stops one player from filling the
-- console. An operator asks for a report a few times at most, so five seconds
-- never refuses a real answer.
local CLIENT_COOLDOWN_MS = 5000
local clientCooldown = Cooldown.new({ intervalMs = CLIENT_COOLDOWN_MS })

--- Drop a player's cooldown and answer slot when they disconnect, so neither
--- table keeps one entry for every player who ever joined.
AddEventHandler('playerDropped', function()
    local src = source
    if src then
        clientCooldown:forget(src)
        pending[src] = nil
    end
end)

-- Everything a client sends is printed through this. `%c` takes the control
-- characters, ESC among them, so an answer cannot rewrite the console with
-- terminal escapes; `^` takes FiveM's own colour codes, so it cannot dress a
-- line up as the server's.
local function printable(s, max)
    return (s:sub(1, max):gsub('[%c^]', ''))
end

RegisterNetEvent('cis_bridge:server:conformanceResults', function(payload)
    local src = source
    if src == 0 or type(payload) ~= 'table' then
        return
    end

    -- Only an answer that was asked for. requestClient opened a slot for this
    -- player; an unasked player, a late answer and a second answer all find
    -- none and are dropped before anything is read or printed.
    local due = pending[src]
    if due == nil or GetGameTimer() > due then
        pending[src] = nil
        return
    end
    pending[src] = nil

    -- Cooldown before any work, and before printing the player's name. The name
    -- is the one thing here that goes to the console unconditionally.
    if not clientCooldown:take(src) then
        return
    end

    -- Validate before printing anything. The rows are filtered first, and
    -- when none survives nothing is printed: no header, no summary, no name.
    -- A payload of junk rows must not print a block that looks like a real
    -- report.
    local rows, shown, notRun, failed = {}, 0, 0, 0
    for i, r in ipairs(payload) do
        -- Stop at the bound. The rows past it are counted with one length
        -- operation, not visited, and the summary reports them as not run.
        if shown >= MAX_CLIENT_RESULTS then
            notRun = notRun + (#payload - i + 1)
            break
        elseif type(r) == 'table' and type(r.name) == 'string' then
            shown = shown + 1
            if r.skipped == true then
                notRun = notRun + 1
            elseif r.ok ~= true then
                failed = failed + 1
            end
            rows[#rows + 1] = r
        end
    end

    if shown == 0 then
        return
    end

    -- The player name is chosen by the player, so it is cleaned like the rows.
    local who = printable(tostring(GetPlayerName(src) or ('id %d'):format(src)), 64)
    print('')
    print(('cis_bridge: client results from %s'):format(who))
    for _, r in ipairs(rows) do
        local label = printable(r.name, 46)
        local detail = type(r.detail) == 'string' and printable(r.detail, 120) or nil
        local status = r.skipped == true and 'SKIP' or (r.ok == true and 'PASS' or 'FAIL')
        -- A PASS needs no detail; a SKIP and a FAIL say why.
        local why = (status ~= 'PASS' and detail) and (' -- ' .. detail) or ''
        print(('  [client] %-46s %s%s'):format(label, status, why))
    end
    print(('cis_bridge: client %s reported %d failure(s) across %d check(s), %d skipped')
        :format(who, failed, shown, notRun))
end)

-- Console only, and it says why rather than failing silently.
--
-- FiveM's own `restricted` flag is the last argument below, and the handler
-- refuses every caller but the console (src 0) on top of it, because
-- `test write` moves real money and items on a named player. So no ACE can
-- open it in game: an `add_ace` that gets past `restricted` still meets
-- `src ~= 0`. The refusal says so instead of suggesting one.
RegisterCommand('cis_bridge', function(src, args)
    if src ~= 0 then
        print('cis_bridge: this is a server console command. Run it from the txAdmin '
            .. 'console or the server terminal; it cannot be run in game.')
        return
    end
    local first, second = args and args[1], args and args[2]
    if first == 'report' then
        if CisBridgeReport and CisBridgeReport.render then
            CisBridgeReport.render()
        else
            print('cis_bridge: the report module is not loaded')
        end
        return
    end
    if first == 'test' and second == 'write' then
        -- A server id is a whole number from 1 to 65535. math.tointeger refuses
        -- a fraction, NaN and infinity, and the bound refuses 1e300, which
        -- `%d` cannot format.
        local target = math.tointeger(tonumber(args[3]))
        local item = args[4]
        if not target or target < 1 or target > 65535 then
            print('cis_bridge: usage: cis_bridge test write <server id> [item]')
            return
        end
        if item ~= nil and not item:match('^[%w_%-%.]+$') then
            print('cis_bridge: the item name has characters no inventory uses')
            return
        end
        CisBridgeConformance.run(target, item)
        return
    end
    if first == nil or first == 'test' then
        CisBridgeConformance.run()
        return
    end
    print('cis_bridge: usage: cis_bridge test | cis_bridge test write <server id> [item] | cis_bridge report')
end, true)
