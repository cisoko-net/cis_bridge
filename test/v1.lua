-- The v1 product API, server half (server/v1.lua, docs/V1.md).
--
-- Every contract runs on every framework fake in test/lib/v1world.lua, with
-- the inventory each one ships with or is usually paired with. The fakes keep
-- one store, so a contract's answer is checked against what really moved:
-- a balance, a count, a job. A contract that answers true and moved nothing,
-- or moved something and answered false, fails here.
--
-- The second half drives the failure paths a real server only shows under
-- load: an inventory that lands part of an add and still answers true, an
-- add-back that does not land, a refund that fails, an adapter that raises,
-- a write that meets another write for the same player.

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

local W = dofile('test/lib/v1world.lua')
W.install()

for _, f in ipairs({
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
    'adapters/appearance/common.lua',
    'adapters/appearance/illenium.lua',
    'adapters/appearance/fivem_appearance.lua',
    'adapters/appearance/qb_clothing.lua',
    'adapters/appearance/skinchanger.lua',
    'adapters/custom.lua',
    'server/v1.lua',
}) do
    dofile(f)
end

local V1 = CisBridgeV1
local bridge = exports.cis_bridge

local function boot(started)
    W.reset(started)
    V1.detect()
end

local function money(src, acc)
    return W.players[src].money[acc]
end

-- ===========================================================================
--  1. The exports surface
-- ===========================================================================

local EXPORT_NAMES = {
    'GetPlayer', 'IsLoaded', 'GetMoney', 'AddMoney', 'RemoveMoney', 'GetItemCount',
    'CanCarry', 'AddItem', 'RemoveItem', 'GetJob', 'SetJob', 'Notify', 'Purchase',
    'GetDoorLock', 'SetDoorLock', 'GetSummary', 'GetOwnedVehicleId', 'SaveAppearance',
    'GetGang', 'GetPlayerState', 'UseItem', 'GetSourceByCharId',
}
for _, name in ipairs(EXPORT_NAMES) do
    check(type(W.declared.cis_bridge[name]) == 'function', 'export registered: ' .. name)
end
local count = 0
for _ in pairs(W.declared.cis_bridge) do count = count + 1 end
check(count == #EXPORT_NAMES, ('exactly %d exports, got %d'):format(#EXPORT_NAMES, count))

-- Server framework events are local events: a client must not be able to fire
-- them, so the server half never registers one as a net event. The one net
-- event it has is the appearance reply, taken only when the server asked.
local netNames = {}
for name in pairs(W.netEvents) do netNames[#netNames + 1] = name end
check(#netNames == 1 and netNames[1] == 'cis_bridge:appearance:reply',
    'server half registers one net event, the appearance reply: ' .. table.concat(netNames, ', '))

-- ===========================================================================
--  2. Every contract on every framework
-- ===========================================================================

local MATRIX = {
    { fw = 'esx', inv = 'ox', invName = 'ox_inventory', unknown = 'unknown_item' },
    { fw = 'esx', inv = nil, invName = 'esx', unknown = 'unknown_item' },
    { fw = 'qbcore', inv = 'qb', invName = 'qb-inventory', unknown = 'unknown_item' },
    { fw = 'qbcore', inv = 'qs', invName = 'qs-inventory', unknown = 'cannot_carry', noCheck = false },
    { fw = 'qbcore', inv = 'codem', invName = 'codem-inventory', unknown = 'refused', noCheck = true },
    { fw = 'qbox', inv = 'ox', invName = 'ox_inventory', unknown = 'unknown_item' },
    { fw = 'cis_core', inv = 'ox', invName = 'ox_inventory', unknown = 'unknown_item' },
    { fw = 'esx', inv = 'cis', invName = 'cis_inventory', unknown = 'unknown_item' },
    { fw = 'qbcore', inv = 'cis', invName = 'cis_inventory', unknown = 'unknown_item' },
    { fw = 'qbox', inv = 'cis', invName = 'cis_inventory', unknown = 'unknown_item' },
    { fw = 'cis_core', inv = 'cis', invName = 'cis_inventory', unknown = 'unknown_item' },
}

local DIRTY = { esx = true }
local CRYPTO = { qbcore = true, qbox = true }
local PHONE = { qbcore = true, qbox = true }

for _, row in ipairs(MATRIX) do
    local tag = row.fw .. '+' .. row.invName
    local function t(msg) return tag .. ': ' .. msg end
    local started = { row.fw }
    if row.inv then started[#started + 1] = row.inv end
    boot(started)

    -- Summary and player
    local s = bridge:GetSummary()
    check(s.api == 1 and s.framework == row.fw and s.inventory == row.invName,
        t(('summary %s/%s'):format(tostring(s.framework), tostring(s.inventory))))
    check(s.version == '1.0.0', t('summary version'))

    local p = bridge:GetPlayer(1)
    check(type(p) == 'table' and p.source == 1 and p.id == 'CID001', t('GetPlayer id'))
    check(type(p) == 'table' and p.name == 'Alice Doe', t('GetPlayer is the character name: ' .. tostring(p and p.name)))
    check(type(p) == 'table' and type(p.job) == 'table' and p.job.name == 'unemployed', t('GetPlayer job'))
    -- QBCore and Qbox keep the character's number in charinfo.phone. The other
    -- adapters have none to give, and a character stored without one answers
    -- no phone, never an empty string.
    if PHONE[row.fw] then
        check(type(p) == 'table' and p.phone == '5550000001',
            t('GetPlayer phone is charinfo.phone: ' .. tostring(p and p.phone)))
        W.players[1].phone = 5550000009
        local n, nwhy = bridge:GetPlayer(1)
        check(type(n) == 'table' and n.phone == '5550000009',
            t('GetPlayer phone stored as a number is its string: ' .. tostring(n and n.phone) .. ' ' .. tostring(nwhy)))
        W.players[1].phone = '5550000001'
    else
        check(type(p) == 'table' and p.phone == nil, t('GetPlayer phone absent: ' .. tostring(p and p.phone)))
    end
    local carol = bridge:GetPlayer(3)
    check(type(carol) == 'table' and carol.phone == nil,
        t('GetPlayer phone absent without charinfo.phone: ' .. tostring(carol and carol.phone)))
    local ok, why = bridge:GetPlayer(2)
    check(ok == false and why == 'not_loaded', t('GetPlayer unloaded: ' .. tostring(why)))
    ok, why = bridge:GetPlayer(99)
    check(ok == false and why == 'bad_source', t('GetPlayer no such player'))
    ok, why = bridge:GetPlayer(1.5)
    check(ok == false and why == 'bad_source', t('GetPlayer fractional source'))
    ok, why = bridge:GetPlayer(0)
    check(ok == false and why == 'bad_source', t('GetPlayer source 0 is the server'))
    check(bridge:IsLoaded(1) == true and bridge:IsLoaded(2) == false, t('IsLoaded'))
    -- The conformance cross-check asks the framework itself, past every
    -- bridge shape check, whether it holds the player.
    check(V1.frameworkHasPlayer(1) == true, t('the framework holds a loaded player'))
    check(V1.frameworkHasPlayer(2) == false, t('the framework does not hold an unloaded one'))
    check(V1.frameworkHasPlayer(99) == false, t('nor an id with no player'))

    -- Money
    check(bridge:GetMoney(1, 'cash') == 1000, t('GetMoney cash'))
    check(bridge:GetMoney(1) == 1000, t('GetMoney defaults to cash'))
    check(bridge:GetMoney(1, 'bank') == 5000, t('GetMoney bank'))
    ok, why = bridge:GetMoney(1, 'gold')
    check(ok == false and why == 'bad_account', t('GetMoney unknown account'))
    ok, why = bridge:GetMoney(1, 'dirty')
    if DIRTY[row.fw] then
        check(ok == 0, t('GetMoney dirty'))
    else
        check(ok == false and why == 'bad_account', t('dirty is not an account here: ' .. tostring(why)))
    end
    ok, why = bridge:GetMoney(1, 'crypto')
    if CRYPTO[row.fw] then
        check(ok == 0, t('GetMoney crypto'))
    else
        check(ok == false and why == 'bad_account', t('crypto is not an account here'))
    end
    ok, why = bridge:GetMoney(2, 'cash')
    check(ok == false and why == 'not_loaded', t('GetMoney unloaded'))

    check(bridge:AddMoney(1, 'cash', 250, 'test') == true and money(1, 'cash') == 1250, t('AddMoney moved 250'))
    check(bridge:RemoveMoney(1, 'cash', 250) == true and money(1, 'cash') == 1000, t('RemoveMoney moved 250'))
    ok, why = bridge:RemoveMoney(1, 'cash', 5000)
    check(ok == false and why == 'insufficient_funds' and money(1, 'cash') == 1000, t('RemoveMoney over balance'))
    ok, why = bridge:RemoveMoney(1, 'bank', 1000)
    check(ok == true and money(1, 'bank') == 4000, t('RemoveMoney bank'))
    for _, bad in ipairs({ 0, -5, 1.5, 0 / 0, 2e9, 1 / 0, '10' }) do
        ok, why = bridge:AddMoney(1, 'cash', bad)
        check(ok == false and why == 'bad_amount', t('AddMoney rejects ' .. tostring(bad)))
        ok, why = bridge:RemoveMoney(1, 'cash', bad)
        check(ok == false and why == 'bad_amount', t('RemoveMoney rejects ' .. tostring(bad)))
    end
    check(money(1, 'cash') == 1000, t('no rejected amount moved money'))
    ok, why = bridge:AddMoney(1, 'cash', 10, ('x'):rep(129))
    check(ok == false and why == 'bad_order', t('AddMoney reason too long'))
    ok, why = bridge:AddMoney(2, 'cash', 10)
    check(ok == false and why == 'not_loaded', t('AddMoney unloaded'))

    -- Items
    check(bridge:GetItemCount(1, 'water') == 0, t('GetItemCount 0'))
    check(bridge:AddItem(1, 'water', 3) == true and W.count(1, 'water') == 3, t('AddItem 3'))
    check(bridge:GetItemCount(1, 'WATER') == 3, t('item names are lowercased'))
    check(bridge:RemoveItem(1, 'water', 2) == true and W.count(1, 'water') == 1, t('RemoveItem 2'))
    ok, why = bridge:RemoveItem(1, 'water', 5)
    check(ok == false and why == 'insufficient_items' and W.count(1, 'water') == 1, t('RemoveItem too many'))
    ok, why = bridge:AddItem(1, 'unobtainium', 1)
    check(ok == false and why == row.unknown, t('AddItem unknown item: ' .. tostring(why)))
    ok, why = bridge:AddItem(1, 'water', 60)
    check(ok == false and W.count(1, 'water') == 1, t('AddItem over capacity moved nothing'))
    check(why == (row.noCheck and 'refused' or 'cannot_carry'), t('AddItem over capacity reason: ' .. tostring(why)))
    for _, bad in ipairs({ 'wa ter', '', ('w'):rep(65), 5, "water'; drop" }) do
        ok, why = bridge:AddItem(1, bad, 1)
        check(ok == false and why == 'bad_item', t('AddItem rejects item ' .. tostring(bad)))
    end
    for _, bad in ipairs({ 0, -1, 1.5, 2e6, 0 / 0 }) do
        ok, why = bridge:AddItem(1, 'water', bad)
        check(ok == false and why == 'bad_count', t('AddItem rejects count ' .. tostring(bad)))
    end
    ok, why = bridge:AddItem(1, 'water', 1, 'meta')
    check(ok == false and why == 'bad_metadata', t('AddItem rejects string metadata'))
    check(bridge:CanCarry(1, 'water', 1) == true, t('CanCarry 1'))
    ok, why = bridge:CanCarry(1, 'water', 1000)
    if row.noCheck then
        check(ok == true, t('CanCarry cannot check here, so it passes'))
    else
        check(ok == false and why == 'cannot_carry', t('CanCarry over capacity'))
    end

    -- Jobs
    local job = bridge:GetJob(1)
    check(type(job) == 'table' and job.name == 'unemployed' and job.grade == 0, t('GetJob'))
    W.fired = {}
    check(bridge:SetJob(1, 'police', 1) == true, t('SetJob police 1'))
    check(W.players[1].job.name == 'police' and W.players[1].job.grade == 1, t('SetJob moved the job'))
    job = bridge:GetJob(1)
    check(type(job) == 'table' and job.name == 'police' and job.grade == 1 and job.label == 'Police', t('GetJob after'))
    local changed = W.firedNamed('cis_bridge:jobChanged')
    check(#changed == 1, t(('jobChanged once, got %d'):format(#changed)))
    check(changed[1] and changed[1][1] == 1 and type(changed[1][2]) == 'table' and changed[1][2].name == 'police',
        t('jobChanged carries src and the normalised job'))
    ok, why = bridge:SetJob(1, 'police', 9)
    check(ok == false and W.players[1].job.grade == 1, t('SetJob unknown grade moved nothing'))
    check(why == (row.fw == 'cis_core' and 'refused' or 'unknown_grade'), t('SetJob unknown grade: ' .. tostring(why)))
    ok, why = bridge:SetJob(1, 'nojob', 0)
    check(ok == false and why == (row.fw == 'cis_core' and 'refused' or 'unknown_job'), t('SetJob unknown job'))
    ok, why = bridge:SetJob(1, 'po lice', 0)
    check(ok == false and why == 'bad_job', t('SetJob bad job name'))
    ok, why = bridge:SetJob(1, 'police', -1)
    check(ok == false and why == 'bad_grade', t('SetJob bad grade'))
    -- A whole float grade (msgpack and JSON carry 0 as 0.0) is the same grade.
    ok, why = bridge:SetJob(1, 'police', 0.0)
    check(ok == true and W.players[1].job.grade == 0, t('SetJob whole float grade: ' .. tostring(why)))

    -- Notify
    check(bridge:Notify(1, 'hello', 'success') == true, t('Notify'))
    ok, why = bridge:Notify(1, '')
    check(ok == false and why == 'bad_message', t('Notify empty'))
    ok, why = bridge:Notify(1, 'hi', 'loud')
    check(ok == false and why == 'bad_message', t('Notify unknown kind'))
    ok, why = bridge:Notify(1, ('x'):rep(513))
    check(ok == false and why == 'bad_message', t('Notify too long'))

    -- Purchase
    W.players[1].items = {}
    check(bridge:Purchase(1, { item = 'water', count = 2, price = 10 }) == true, t('Purchase one line'))
    check(money(1, 'cash') == 980 and W.count(1, 'water') == 2, t('Purchase took 20 and gave 2'))
    ok, why = bridge:Purchase(1, { item = 'water', count = 1, price = 1000000 })
    check(ok == false and why == 'insufficient_funds' and money(1, 'cash') == 980, t('Purchase over balance'))
    ok, why = bridge:Purchase(1, { item = 'water', count = 100, price = 1 })
    check(ok == false and money(1, 'cash') == 980 and W.count(1, 'water') == 2,
        t('Purchase that does not fit moved nothing: ' .. tostring(why)))
    check(bridge:Purchase(1, { lines = {
        { item = 'water', count = 1, price = 5 },
        { item = 'bread', count = 2, price = 3 },
    } }) == true, t('Purchase two lines'))
    check(money(1, 'cash') == 969 and W.count(1, 'water') == 3 and W.count(1, 'bread') == 2, t('two lines moved'))
    ok, why = bridge:Purchase(1, { lines = {
        { item = 'bread', count = 1, price = 3 },
        { item = 'unobtainium', count = 1, price = 3 },
    } })
    check(ok == false and money(1, 'cash') == 969 and W.count(1, 'bread') == 2,
        t('Purchase with one bad line moved nothing: ' .. tostring(why)))
    check(bridge:Purchase(1, { item = 'water', price = 4, account = 'bank' }) == true
        and money(1, 'bank') == 3996, t('Purchase from bank, count defaults to 1'))
    check(bridge:Purchase(1, { item = 'water', count = 1, price = 0 }) == true and money(1, 'cash') == 969,
        t('a free line moves no money'))
    ok, why = bridge:Purchase(3, { item = 'water', count = 1, price = 1 })
    check(ok == false and why == 'insufficient_funds' and W.count(3, 'water') == 0, t('Purchase with no cash'))
end

-- ===========================================================================
--  3. Purchase validation
-- ===========================================================================

boot({ 'esx', 'ox' })
local ok, why
local function lines(n)
    local out = {}
    for i = 1, n do out[i] = { item = 'water', count = 1, price = 1 } end
    return { lines = out }
end
for _, case in ipairs({
    { nil, 'bad_order' },
    { 'water', 'bad_order' },
    { lines(0), 'bad_order' },
    { lines(21), 'bad_order' },
    { { item = 'wa ter', price = 1 }, 'bad_item' },
    { { item = 'water', price = -1 }, 'bad_amount' },
    { { item = 'water', price = 1.5 }, 'bad_amount' },
    { { item = 'water' }, 'bad_amount' },
    { { item = 'water', count = 2e6, price = 1 }, 'bad_count' },
    { { item = 'water', count = 2, price = 600000000 }, 'bad_amount' },
    { { item = 'water', price = 1, metadata = 'x' }, 'bad_metadata' },
    { { item = 'water', price = 1, reason = ('r'):rep(129) }, 'bad_order' },
    { { item = 'water', price = 1, account = 'gold' }, 'bad_account' },
}) do
    ok, why = bridge:Purchase(1, case[1])
    check(ok == false and why == case[2], ('Purchase rejects %s: got %s'):format(case[2], tostring(why)))
end
check(money(1, 'cash') == 1000 and next(W.players[1].items) == nil, 'no rejected order moved anything')
check(bridge:Purchase(1, lines(20)) == true and W.count(1, 'water') == 20, 'Purchase takes 20 lines')

-- Metadata is bounded: 8 levels deep and 256 keys counted at every level.
local function nest(n) local t = { leaf = 1 } for _ = 2, n do t = { t } end return t end
local function wide(n) local t = {} for i = 1, n do t['k' .. i] = i end return t end
local function wideNested(n) local t = wide(n - 1) t.sub = {} return t end
check(bridge:AddItem(1, 'bread', 1, nest(8)) == true, 'metadata 8 deep is accepted')
check(bridge:AddItem(1, 'bread', 1, wide(256)) == true, 'metadata with 256 keys is accepted')
ok, why = bridge:AddItem(1, 'bread', 1, nest(9))
check(ok == false and why == 'bad_metadata', 'metadata 9 deep is bad_metadata: ' .. tostring(why))
ok, why = bridge:AddItem(1, 'bread', 1, wide(257))
check(ok == false and why == 'bad_metadata', 'metadata with 257 keys is bad_metadata: ' .. tostring(why))
ok, why = bridge:AddItem(1, 'bread', 1, { a = wideNested(256) })
check(ok == false and why == 'bad_metadata', 'nested keys count toward the 256: ' .. tostring(why))
ok, why = bridge:Purchase(1, { item = 'bread', price = 1, metadata = nest(9) })
check(ok == false and why == 'bad_metadata', 'Purchase line metadata 9 deep is bad_metadata: ' .. tostring(why))

-- ===========================================================================
--  4. Detection
-- ===========================================================================

boot({ 'qbcore', 'qbox' })
check(V1.summary().framework == 'qbox', 'qbx_core beside qb-core is Qbox')

-- A started qbx_core that does not answer is not a reason to fall through to
-- the qb-core it provides.
local saved = W.declared.qbx_core
W.declared.qbx_core = {}
boot({ 'qbcore', 'qbox' })
check(V1.summary().framework == nil, 'qbx_core that does not answer: no framework, never qb-core')
ok, why = bridge:GetPlayer(1)
check(ok == false and why == 'no_framework', 'no framework answers no_framework')
W.declared.qbx_core = saved

W.reset({ 'qbcore', 'qbox', 'qb' })
W.convars['cis_bridge:framework'] = 'qbcore'
V1.detect()
check(V1.summary().framework == 'qbcore', 'the framework convar wins over Qbox')

boot({ 'esx', 'cis_core', 'ox' })
check(V1.summary().framework == 'esx', 'ESX beside cis_core is ESX: cis_core is a wrapper')
boot({ 'cis_core', 'ox' })
check(V1.summary().framework == 'cis_core', 'cis_core alone is cis_core')

boot({ 'qbcore', 'qb', 'ox' })
check(V1.summary().inventory == 'ox_inventory', 'ox_inventory before qb-inventory')

-- cis_inventory ships faces that answer to the ox_inventory and qb-inventory
-- names, so on its server those look started too: it is checked first.
boot({ 'qbox', 'cis', 'ox', 'qb' })
check(V1.summary().inventory == 'cis_inventory', 'cis_inventory before its ox and qb faces')
boot({ 'esx', 'cis' })
check(V1.summary().inventory == 'cis_inventory', 'cis_inventory before the ESX native inventory')
local savedCis = W.declared.cis_inventory
W.declared.cis_inventory = {}
boot({ 'qbox', 'cis', 'ox' })
check(V1.summary().inventory == 'ox_inventory', 'a started cis_inventory with no GetVersion is passed over')
W.declared.cis_inventory = savedCis
boot({ 'cis_core', 'cis' })
check(V1.summary().inventory == 'cis_inventory', 'cis_core with cis_inventory')
W.state.cis_inventory = 'stopped'
W.fire('onResourceStop', nil, 'cis_inventory')
check(V1.summary().inventory == nil, 'cis_inventory stopped: re-detected, none left')
W.state.cis_inventory = 'started'
W.fire('onResourceStart', nil, 'cis_inventory')
check(V1.summary().inventory == 'cis_inventory', 'cis_inventory started again')
W.reset({ 'qbcore', 'qb', 'ox' })
W.convars['cis_bridge:inventory'] = 'qb-inventory'
V1.detect()
check(V1.summary().inventory == 'qb-inventory', 'the inventory convar wins')

-- A forced name that is not an adapter, or names an adapter whose resource is
-- not started, picks nothing and says so in plain words, once per cause.
local function printed(text)
    local n = 0
    for _, line in ipairs(W.prints) do
        if line:find(text, 1, true) then n = n + 1 end
    end
    return n
end
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:framework'] = 'qbcor'
V1.detect()
check(V1.summary().framework == nil, 'a mistyped framework convar picks nothing, never the detected one')
check(printed("cis_bridge:framework is 'qbcor', which is not an adapter. Use one of: cis_core, esx, qbcore, qbox") == 1,
    'and prints the names it takes')
check(((V1.summary().config or {}).framework or ''):find("'qbcor'", 1, true) ~= nil, 'and the summary carries the line for the report')
V1.detect()
check(printed("cis_bridge:framework is 'qbcor'") == 1, 'a second detect does not print it again')
W.reset({ 'esx' })
W.convars['cis_bridge:inventory'] = 'qb_inventory'
V1.detect()
check(V1.summary().inventory == nil, 'a mistyped inventory convar picks nothing, not the framework inventory')
check(printed("cis_bridge:inventory is 'qb_inventory', which is not an adapter. Use one of:") == 1,
    'and prints the names it takes')
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:inventory'] = 'ox_inventory'
V1.detect()
check(V1.summary().inventory == nil, 'a forced inventory that is not started picks nothing')
check(printed("cis_bridge:inventory is 'ox_inventory', but ox_inventory is not started") == 1,
    'and says which resource to start')
-- Forced, started, but the probe fails (an export renamed or missing): one
-- line names the cause, once, and the slot stays empty.
do
    local oxI = CisBridgeInventories.ox_inventory
    local realProbe = oxI.probe
    oxI.probe = function() return false end
    W.reset({ 'esx', 'ox' })
    W.convars['cis_bridge:inventory'] = 'ox_inventory'
    V1.detect()
    check(V1.summary().inventory == nil, 'a forced inventory whose probe fails picks nothing')
    local probeLine = "cis_bridge:inventory is 'ox_inventory' and ox_inventory is started, but it does not answer the ox_inventory probe"
    check(printed(probeLine) == 1, 'and says the probe failed')
    check(((V1.summary().config or {}).inventory or ''):find('probe', 1, true) ~= nil, 'the report carries the line')
    V1.detect()
    check(printed(probeLine) == 1, 'a second detect does not print it again')
    oxI.probe = function() error('probe raised') end
    W.reset({ 'esx', 'ox' })
    W.convars['cis_bridge:framework'] = 'esx'
    local esxF = CisBridgeFrameworks.esx
    local realFw = esxF.probe
    esxF.probe = function() return false end
    V1.detect()
    check(V1.summary().framework == nil and printed("cis_bridge:framework is 'esx' and es_extended is started, but it does not answer the esx probe") == 1,
        'a forced framework whose probe fails says so too')
    esxF.probe = realFw
    oxI.probe = realProbe
end
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:doors'] = 'oxdoorlock'
V1.detect()
check(printed("cis_bridge:doors is 'oxdoorlock', which is not an adapter") == 1, 'doors convar checked too')
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:appearance'] = 'illenium'
V1.detect()
check(printed("cis_bridge:appearance is 'illenium', which is not an adapter") == 1, 'appearance convar checked too')
W.reset({ 'qbcore', 'qb' })
V1.detect()
check(V1.summary().config == nil and #W.prints == 0, 'no convar: no config line, nothing printed')

-- A renamed framework or inventory resource: `cis_bridge:<slot>_resource`
-- names it, the forced adapter calls it there, and the summary says why.
W.reset({ 'qb' })
W.declared['my-core'] = W.declared['qb-core']
W.state['my-core'] = 'started'
W.convars['cis_bridge:framework'] = 'qbcore'
W.convars['cis_bridge:framework_resource'] = 'my-core'
V1.detect()
check(V1.summary().framework == 'qbcore', 'a qb-core renamed to my-core is found under its new name')
check((V1.summary().why or {}).framework == 'forced, resource renamed to my-core', 'and the summary says why')
ok = bridge:GetMoney(1, 'cash')
check(ok ~= false and #W.callsTo('my-core.GetPlayer') > 0, 'player reads go to my-core')
ok, why = bridge:CanCarry(1, 'not_an_item', 1)
check(ok == false and why == 'unknown_item', 'and qb-inventory looks its items up in my-core too')
-- QBCore.Shared is copied once, not on every lookup, and read again after
-- qb-core's own update event.
do
    boot({ 'qbcore', 'qb' })
    local base = #W.callsTo('qb-core.GetCoreObject')
    bridge:CanCarry(1, 'water', 1)
    bridge:CanCarry(1, 'bread', 1)
    bridge:CanCarry(1, 'not_an_item', 1)
    local copies = #W.callsTo('qb-core.GetCoreObject') - base
    check(copies <= 1, 'qb: three item lookups copy QBCore.Shared at most once: ' .. copies)
    W.items.lockpick = {}
    local okK, whyK = bridge:CanCarry(1, 'lockpick', 1)
    check(okK == false and whyK == 'unknown_item', 'qb: an item added without the update event is not seen yet')
    W.fire('QBCore:Server:UpdateObject', nil)
    okK, whyK = bridge:CanCarry(1, 'lockpick', 1)
    check(whyK ~= 'unknown_item', 'qb: after QBCore:Server:UpdateObject the new item is known: ' .. tostring(whyK))
end
W.reset({ 'qb' })
W.declared['my-core'] = W.declared['qb-core']
W.state['my-core'] = 'started'
W.convars['cis_bridge:framework'] = 'qbcore'
W.convars['cis_bridge:framework_resource'] = 'my-core'
V1.detect()
W.state['my-core'] = 'stopped'
W.fire('onResourceStop', nil, 'my-core')
check(V1.summary().framework == nil, 'my-core stopping is watched: re-detected, nothing picked')
W.reset({})
W.declared['my-esx'] = W.declared.es_extended
W.state['my-esx'] = 'started'
W.convars['cis_bridge:framework'] = 'esx'
W.convars['cis_bridge:framework_resource'] = 'my-esx'
V1.detect()
check(V1.summary().framework == 'esx' and #W.callsTo('my-esx.getSharedObject') > 0,
    'an es_extended renamed to my-esx is found and called there')

-- A custom adapter in adapters/custom.lua: here a copy of the qbcore adapter
-- for a qb-core renamed to my-core whose GetPlayer export is renamed FetchPlayer.
-- It registers under its own name, is never auto-detected, and is picked when
-- cis_bridge:framework names it.
do
    -- The copy, made the way the owner would: the same file under a new name
    -- and resource, with its GetPlayer calls renamed. The harness has no disk
    -- access for source text, so the rename is an exports proxy instead.
    local env = setmetatable({
        CisBridgeFrameworks = { __common = CisBridgeFrameworks.__common },
        exports = setmetatable({}, { __index = function(_, res)
            local real = exports[res]
            return setmetatable({}, { __index = function(_, k)
                return real[k == 'GetPlayer' and 'FetchPlayer' or k]
            end })
        end }),
    }, { __index = _G })
    assert(loadfile('adapters/framework/qbcore.lua', 't', env))()
    local A = env.CisBridgeFrameworks.qbcore
    A.name, A.resource = 'my_qbcore', 'my-core'
    CisBridgeFrameworks.my_qbcore = A
end
W.reset({})
W.declared['my-core'] = {}
for k, fn in pairs(W.declared['qb-core']) do
    W.declared['my-core'][k == 'GetPlayer' and 'FetchPlayer' or k] = fn
end
W.state['my-core'] = 'started'
V1.detect()
check(V1.summary().framework == nil, 'a custom adapter is never auto-detected')
W.convars['cis_bridge:framework'] = 'my_qbcore'
V1.detect()
check(V1.summary().framework == 'my_qbcore', 'cis_bridge:framework picks the custom adapter by its name')
ok = bridge:GetMoney(1, 'cash')
check(ok ~= false and #W.callsTo('my-core.FetchPlayer') > 0, 'and it reads players through the renamed export')
W.convars['cis_bridge:framework'] = 'my_qbcor'
W.prints = {}
V1.detect()
local listed = false
for _, line in ipairs(W.prints) do
    if tostring(line):find('Use one of: cis_core, esx, my_qbcore, qbcore, qbox', 1, true) then listed = true end
end
check(listed, 'a misspelt custom name lists the custom adapter among the choices')
CisBridgeFrameworks.my_qbcore = nil
W.reset({})
W.reset({ 'qbcore' })
W.declared['my-ox'] = W.declared.ox_inventory
W.state['my-ox'] = 'started'
W.convars['cis_bridge:inventory'] = 'ox_inventory'
W.convars['cis_bridge:inventory_resource'] = 'my-ox'
V1.detect()
check(V1.summary().inventory == 'ox_inventory', 'an ox_inventory renamed to my-ox is found')
bridge:GetItemCount(1, 'water')
check(#W.callsTo('my-ox.GetItemCount') == 1, 'and item reads go to my-ox')
W.reset({ 'qbcore', 'ox' })
V1.detect()
check(V1.summary().inventory == 'ox_inventory' and (V1.summary().why or {}).inventory == 'auto',
    'with the convars gone the adapter is auto-detected again')
bridge:GetItemCount(1, 'water')
check(#W.callsTo('ox_inventory.GetItemCount') == 1 and #W.callsTo('my-ox.GetItemCount') == 0,
    'and calls its own resource name again')
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:inventory'] = 'qb-inventory'
V1.detect()
check((V1.summary().why or {}).inventory == 'forced by convar', 'a forced name alone says forced by convar')
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:framework_resource'] = 'my-core'
V1.detect()
check(V1.summary().framework == nil, 'a resource override without the forced name picks nothing')
check(printed("cis_bridge:framework_resource is 'my-core', but cis_bridge:framework is not set. Set both") == 1,
    'and says to set both')
check(V1.summary().inventory == 'qb-inventory', 'and the other slots are still detected')
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:inventory_resource'] = 'my-inventory'
V1.detect()
check(printed('Set both: setr cis_bridge:inventory <adapter>, where <adapter> is one of: cis_inventory, codem-inventory, ox_inventory, qb-inventory, qs-inventory') == 1,
    'the set-both hint lists the adapters of that slot, and suggests none of them')
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:framework'] = 'qbcore'
W.convars['cis_bridge:framework_resource'] = 'gone-core'
V1.detect()
check(V1.summary().framework == nil, 'a renamed resource that is not started picks nothing')
check(printed("cis_bridge:framework is 'qbcore', but gone-core is not started") == 1, 'and names the renamed resource')
W.reset({ 'esx' })
W.convars['cis_bridge:inventory_resource'] = 'my-ox'
V1.detect()
check(V1.summary().inventory == nil, 'an inventory override alone does not fall back to the ESX inventory')
W.reset({ 'qbcore', 'qb' })
W.convars['cis_bridge:inventory_resource'] = 'my-ox'
V1.detect()
check(V1.summary().inventory == nil, 'an inventory override alone picks nothing, not the started qb-inventory')

boot({ 'qbcore' })
check(V1.summary().inventory == nil, 'QBCore with no inventory resource has none')
ok, why = bridge:GetItemCount(1, 'water')
check(ok == false and why == 'no_inventory', 'GetItemCount with no inventory')
ok, why = bridge:Purchase(1, { item = 'water', price = 1 })
check(ok == false and why == 'no_inventory' and money(1, 'cash') == 1000, 'Purchase with no inventory moved nothing')

-- A watched resource stopping changes the answer on the next call.
boot({ 'esx', 'ox' })
check(V1.summary().inventory == 'ox_inventory', 'ox before stop')
W.state.ox_inventory = 'stopped'
W.fire('onResourceStop', nil, 'ox_inventory')
check(V1.summary().inventory == 'esx', 'ox stopped: ESX native inventory')
W.state.ox_inventory = 'started'
W.fire('onResourceStart', nil, 'ox_inventory')
check(V1.summary().inventory == 'ox_inventory', 'ox started again')

-- ===========================================================================
--  5. Events
-- ===========================================================================

local function events(name) return #W.firedNamed(name) end

for _, fwName in ipairs({ 'esx', 'qbcore', 'qbox' }) do
    boot({ fwName, 'ox' })
    W.players[2].loaded = true
    local loadedEvent, payload
    if fwName == 'esx' then
        loadedEvent, payload = 'esx:playerLoaded', 2
    else
        loadedEvent, payload = 'QBCore:Server:PlayerLoaded', { PlayerData = W.qbPlayerData(2) }
    end
    W.fire(loadedEvent, nil, payload)
    W.fire(loadedEvent, nil, payload)
    check(events('cis_bridge:playerLoaded') == 1, fwName .. ': playerLoaded once for two framework events')
    check(W.firedNamed('cis_bridge:playerLoaded')[1][1] == 2, fwName .. ': playerLoaded carries the source')
    local unloadEvent = fwName == 'esx' and 'esx:playerDropped' or 'QBCore:Server:OnPlayerUnload'
    W.fire(unloadEvent, nil, 2)
    W.fire('playerDropped', 2, 'left')
    check(events('cis_bridge:playerUnloaded') == 1, fwName .. ': playerUnloaded once for unload then drop')
    -- Players loaded before the bridge started are seeded from GetPlayers.
    W.fire('playerDropped', 1, 'left')
    check(events('cis_bridge:playerUnloaded') == 2, fwName .. ': a seeded player unloads on drop')
end

boot({ 'esx', 'ox' })
W.players[2].loaded = true
W.fire('QBCore:Server:PlayerLoaded', nil, { PlayerData = W.qbPlayerData(2) })
check(events('cis_bridge:playerLoaded') == 0, 'another framework\'s event is ignored')

boot({ 'cis_core', 'ox' })
W.fire('playerDropped', 1, 'left')
check(events('cis_bridge:playerUnloaded') == 1, 'cis_core: unloaded comes from playerDropped')

-- A framework that starts after the bridge: its first loaded event arrives
-- before any export read, so the relay itself must re-detect.
boot({ 'ox' })
W.state.es_extended = 'started'
W.fire('onResourceStart', nil, 'es_extended')
W.players[2].loaded = true
W.fire('esx:playerLoaded', nil, 2)
check(events('cis_bridge:playerLoaded') == 1, 'a framework started after the bridge relays its first playerLoaded')
W.fire('esx:playerLoaded', nil, 2)
check(events('cis_bridge:playerLoaded') == 1, 'its second playerLoaded is still deduped')
-- A re-detect for another reason must not replay a player loaded before it.
W.fire('onResourceStop', nil, 'ox_inventory')
W.fire('onResourceStart', nil, 'ox_inventory')
W.fire('esx:playerLoaded', nil, 2)
check(events('cis_bridge:playerLoaded') == 1, 'a stale re-detect does not replay an already loaded player')

-- The same for doors: a door lock started after the bridge.
boot({ 'esx', 'ox' })
W.state.ox_doorlock = 'started'
W.fire('onResourceStart', nil, 'ox_doorlock')
W.fire('ox_doorlock:stateChanged', nil, 1, false)
check(events('cis_bridge:doorChanged') == 1, 'a door lock started after the bridge relays its first change')

-- ===========================================================================
--  6. Count-delta: an inventory that does not do what it says
-- ===========================================================================

-- ox lands one of three non-stackables and answers true. The take-back works,
-- so nothing is stuck: the honest answer is that it did not fit.
boot({ 'esx', 'ox' })
W.fault.addLands = 1
ok, why = bridge:AddItem(1, 'phone', 3)
check(ok == false and why == 'cannot_carry', 'partial add taken back answers cannot_carry: ' .. tostring(why))
check(W.count(1, 'phone') == 0, 'partial add left nothing behind')
check(events('cis_bridge:inconsistent') == 0, 'a clean take-back is not inconsistent')

-- The take-back does not land either: one unit is stuck.
boot({ 'esx', 'ox' })
W.fault.addLands, W.fault.removeTakes = 1, 0
local a, b, c = bridge:AddItem(1, 'phone', 3)
check(a == false and b == 'partial' and c == nil, 'stuck add answers partial, two values through the export')
check(W.count(1, 'phone') == 1, 'one phone is stuck')
local inc = W.firedNamed('cis_bridge:inconsistent')
check(#inc == 1 and inc[1][1] == 1 and inc[1][2].count == 1 and inc[1][2].action == 'add', 'inconsistent names it')

-- An inventory that answers true and moved nothing.
boot({ 'esx', 'ox' })
W.fault.addLands = 0
ok, why = bridge:AddItem(1, 'water', 2)
check(ok == false and why == 'refused' and W.count(1, 'water') == 0, 'true with nothing moved is refused')

-- Remove: takes one of three. No add-back: a plain add would come back
-- without the metadata (serials, durability) the taken unit carried.
boot({ 'esx', 'ox' })
W.players[1].items.water = 5
W.fault.removeTakes = 1
local pa, pb, pc = bridge:RemoveItem(1, 'water', 3)
check(pa == false and pb == 'partial' and pc == nil and W.count(1, 'water') == 4,
    'partial remove keeps what went, no add-back: ' .. tostring(pb) .. ' ' .. W.count(1, 'water'))
check(events('cis_bridge:inconsistent') == 1, 'partial remove is inconsistent')
local inc = W.firedNamed('cis_bridge:inconsistent')[1]
check(inc ~= nil and inc[2].action == 'remove' and inc[2].count == 1, 'inconsistent counts the unit that went')

-- qs RemoveItem answers nothing: the count is the proof.
boot({ 'qbcore', 'qs' })
W.players[1].items.water = 2
check(bridge:RemoveItem(1, 'water', 2) == true and W.count(1, 'water') == 0, 'qs remove proved by count')

-- qb RemoveItem takes from one slot only: a stack split over two slots is
-- removed slot by slot, and a short total touches nothing.
boot({ 'qbcore', 'qb' })
W.players[1].items.water = 5
W.qbSlots[1] = { water = { { slot = 3, amount = 2 }, { slot = 7, amount = 3 } } }
check(bridge:RemoveItem(1, 'water', 4) == true and W.count(1, 'water') == 1, 'qb remove across two slots')
check(#W.qbSlots[1].water == 1 and W.qbSlots[1].water[1].slot == 7 and W.qbSlots[1].water[1].amount == 1,
    'qb remove emptied the first slot and took the rest from the second')
check(events('cis_bridge:inconsistent') == 0, 'qb split remove is not inconsistent')

-- The slots hold fewer than the count says (a stack qb has not listed): the
-- plan is short, so no slot is touched.
boot({ 'qbcore', 'qb' })
W.players[1].items.water = 6
W.qbSlots[1] = { water = { { slot = 3, amount = 2 }, { slot = 7, amount = 3 } } }
ok, why = bridge:RemoveItem(1, 'water', 6)
check(ok == false and why == 'refused' and W.count(1, 'water') == 6 and #W.qbSlots[1].water == 2,
    'qb short slot plan touches nothing: ' .. tostring(why) .. ' ' .. W.count(1, 'water'))
check(events('cis_bridge:inconsistent') == 0, 'qb short slot plan is not inconsistent')

-- A slot refused midway (it changed between the read and the take): the
-- adapter answers refused, not removed.
boot({ 'qbcore', 'qb' })
W.players[1].items.water = 5
W.qbSlots[1] = { water = { { slot = 3, amount = 2 }, { slot = 7, amount = 3 } } }
do
    local calls = 0
    W.fault.during = { ['qb-inventory.RemoveItem'] = function()
        calls = calls + 1
        if calls == 3 then W.qbSlots[1].water[1].amount = 1 end
    end }
    local a, b = CisBridgeInventories['qb-inventory'].remove(1, 'water', 4)
    W.fault.during = nil
    check(a == false and b == 'refused', 'qb refused slot answers refused: ' .. tostring(a) .. ' ' .. tostring(b))
end

-- ===========================================================================
--  7. Purchase failure paths
-- ===========================================================================

-- The stuck phone is the player's and is paid for; the rest is refunded.
boot({ 'esx', 'ox' })
W.fault.addLands, W.fault.removeTakes = 1, 0
ok, why = bridge:Purchase(1, { item = 'phone', count = 3, price = 100 })
check(ok == false and why == 'partial', 'stuck purchase answers partial: ' .. tostring(why))
check(money(1, 'cash') == 900 and W.count(1, 'phone') == 1, 'paid for the one stuck phone only')

-- Line 2 fails; line 1 is taken back and everything refunded.
boot({ 'esx', 'ox' })
W.fault.during = { ['ox_inventory.AddItem'] = function()
    if #W.callsTo('ox_inventory.AddItem') == 2 then W.fault.addLands = 0 end
end }
ok, why = bridge:Purchase(1, { lines = {
    { item = 'water', count = 2, price = 10 },
    { item = 'bread', count = 2, price = 10 },
} })
check(ok == false and why == 'refused', 'second line refused: ' .. tostring(why))
check(money(1, 'cash') == 1000 and W.count(1, 'water') == 0 and W.count(1, 'bread') == 0, 'line 1 taken back, all refunded')

-- The refund itself fails.
boot({ 'esx', 'ox' })
W.fault.during = { ['ox_inventory.AddItem'] = function()
    W.fault.addLands = 0
    W.fault.moneyAddFails = true
end }
ok, why = bridge:Purchase(1, { item = 'water', count = 2, price = 10 })
check(ok == false and why == 'refund_failed', 'refund that fails: ' .. tostring(why))
local rf = W.firedNamed('cis_bridge:refundFailed')
check(#rf == 1 and rf[1][1] == 1 and rf[1][2] == 'cash' and rf[1][3] == 20, 'refundFailed names src, account, amount')
check(money(1, 'cash') == 980, 'the money really is gone, and the event says so')

-- The payment is refused after the balance check.
boot({ 'qbcore', 'qb' })
W.fault.raise = { ['qb-core.GetPlayer'] = true }
ok, why = bridge:Purchase(1, { item = 'water', price = 1 })
check(ok == false and W.count(1, 'water') == 0 and money(1, 'cash') == 1000, 'purchase with a raising framework moved nothing')

-- The server id changes character while the order yields (a logout to the
-- character menu, or a drop and a new player on the same id). Before the
-- payment: nothing moves.
boot({ 'esx', 'ox' })
W.fault.during = { ['ox_inventory.CanCarryItem'] = function() W.players[1].id = 'CID999' end }
ok, why = bridge:Purchase(1, { item = 'water', count = 2, price = 10 })
check(ok == false and why == 'not_loaded', 'character switch before payment is not_loaded: ' .. tostring(why))
check(money(1, 'cash') == 1000 and W.count(1, 'water') == 0, 'character switch before payment moved nothing')

-- After the payment: no further line lands, and nothing is taken back from
-- or refunded to the new character; the lost refund is reported.
boot({ 'esx', 'ox' })
W.fault.during = { ['ox_inventory.AddItem'] = function() W.players[1].id = 'CID999' end }
ok, why = bridge:Purchase(1, { lines = {
    { item = 'water', count = 2, price = 10 },
    { item = 'bread', count = 2, price = 10 },
} })
check(ok == false and why == 'error', 'character switch after payment is error: ' .. tostring(why))
check(W.count(1, 'bread') == 0, 'no line lands on the new character')
check(W.count(1, 'water') == 2 and money(1, 'cash') == 960, 'nothing taken back from or refunded to the new character')
local lost = W.firedNamed('cis_bridge:inconsistent')
check(#lost == 1 and lost[1][2].action == 'refund' and lost[1][2].amount == 20 and lost[1][2].moved == 0,
    'the refund the old character is owed is reported')

-- ===========================================================================
--  8. No contract raises
-- ===========================================================================

boot({ 'esx', 'ox' })
W.fault.raise = { ['ox_inventory.GetItemCount'] = true }
ok, why = bridge:GetItemCount(1, 'water')
check(ok == false and why == 'not_loaded', 'a raising count reads as not loaded: ' .. tostring(why))
local raisedLine = false
for _, line in ipairs(W.prints) do
    if line:find('ox_inventory.count raised', 1, true) then raisedLine = true end
end
check(raisedLine, 'the raise is printed with the adapter name')

boot({ 'qbox', 'ox' })
W.fault.raise = { ['qbx_core.GetMoney'] = true }
ok, why = bridge:GetMoney(1, 'cash')
check(ok == false and why == 'error', 'a raising balance is error: ' .. tostring(why))
ok, why = bridge:RemoveMoney(1, 'cash', 1)
check(ok == false and why == 'error' and money(1, 'cash') == 1000, 'RemoveMoney with a raising balance moved nothing')

-- ===========================================================================
--  9. The lock
-- ===========================================================================

boot({ 'esx', 'ox' })
local inner
W.fault.during = { ['ox_inventory.AddItem'] = function()
    inner = table.pack(bridge:AddMoney(1, 'cash', 5))
end }
check(bridge:AddItem(1, 'water', 1) == true, 'outer write lands')
check(inner and inner[1] == false and inner[2] == 'busy', 'a second write for the same player is busy')
check(money(1, 'cash') == 1000, 'the busy write moved nothing')
W.fault.during = nil
check(bridge:AddMoney(1, 'cash', 5) == true, 'the lock is released after the write')

-- A write for another player is not blocked.
W.fault.during = { ['ox_inventory.AddItem'] = function()
    inner = table.pack(bridge:AddMoney(3, 'cash', 5))
end }
bridge:AddItem(1, 'water', 1)
check(inner[1] == true and money(3, 'cash') == 5, 'another player is not locked')

-- Purchase runs under one lock and does not meet itself.
W.fault.during = nil
check(bridge:Purchase(1, { item = 'water', price = 1 }) == true, 'Purchase does not deadlock on its own lock')

-- A raise inside a locked write releases the lock.
W.fault.raise = { ['es_extended.getSharedObject'] = true }
boot({ 'esx', 'ox' })
W.fault.raise = { ['ox_inventory.AddItem'] = true }
bridge:AddItem(1, 'water', 1)
W.fault.raise = nil
check(bridge:AddMoney(1, 'cash', 1) == true, 'a raise does not leave the lock held')

-- A drop mid-write clears the lock; the next player with that id is not busy.
W.fault.during = { ['ox_inventory.AddItem'] = function()
    W.fire('playerDropped', 1, 'left')
    inner = table.pack(bridge:AddMoney(1, 'cash', 1))
end }
bridge:AddItem(1, 'water', 1)
check(inner[1] == true, 'after a drop the id is free')

-- ===========================================================================
--  10. cis_core: the return is not the proof
-- ===========================================================================

boot({ 'cis_core', 'ox' })
W.fault.cisRefuse = true
ok, why = bridge:AddMoney(1, 'cash', 10)
check(ok == false and why == 'refused' and money(1, 'cash') == 1000, 'cis_core refused add read back: ' .. tostring(why))
ok, why = bridge:RemoveMoney(1, 'cash', 10)
check(ok == false and why == 'refused' and money(1, 'cash') == 1000, 'cis_core refused remove read back')
ok, why = bridge:Purchase(1, { item = 'water', price = 10 })
check(ok == false and why == 'refused' and W.count(1, 'water') == 0, 'cis_core refused payment: no item')
W.fault.cisRefuse = nil
W.fired = {}
check(bridge:SetJob(1, 'police', 0) == true and events('cis_bridge:jobChanged') == 1, 'cis_core SetJob emits jobChanged')

-- ===========================================================================
--  11. Doors
-- ===========================================================================

boot({ 'esx', 'ox', 'ox_doorlock' })
check(V1.summary().doors == 'ox_doorlock', 'ox_doorlock detected')
check(bridge:GetDoorLock(1) == 'locked' and bridge:GetDoorLock(2) == 'unlocked', 'GetDoorLock by id')
check(bridge:GetDoorLock('mrpd_front') == 'locked', 'GetDoorLock by name')
check(bridge:SetDoorLock(1, false) == true and W.doors[1].state == 0, 'SetDoorLock unlocks')
local dc = W.firedNamed('cis_bridge:doorChanged')
check(#dc == 1 and dc[1][1] == 1 and dc[1][2] == false, 'doorChanged once with id and state')
check(bridge:SetDoorLock('mrpd_back', true) == true and W.doors[2].state == 1, 'SetDoorLock by name')
ok, why = bridge:GetDoorLock(99)
check(ok == false and why == 'unknown_door', 'unknown door')
ok, why = bridge:SetDoorLock(99, true)
check(ok == false and why == 'unknown_door', 'set unknown door')
for _, bad in ipairs({ {}, -1, 1.5, ('d'):rep(65), '' }) do
    ok, why = bridge:GetDoorLock(bad)
    check(ok == false and why == 'bad_door', 'GetDoorLock rejects ' .. tostring(bad))
end
ok, why = bridge:SetDoorLock(1, 'yes')
check(ok == false and why == 'bad_door', 'SetDoorLock wants a boolean')

boot({ 'esx', 'ox' })
ok, why = bridge:GetDoorLock(1)
check(ok == false and why == 'no_doors', 'no doors resource')
boot({ 'esx', 'ox', 'qb-doorlock' })
ok, why = bridge:SetDoorLock(1, true)
check(ok == false and why == 'unsupported', 'qb-doorlock has no exports: unsupported')

-- ===========================================================================
--  12. Money is proved by the balance, take-backs by the count
-- ===========================================================================

-- A framework that answers true and moved nothing: the balance says refused.
boot({ 'esx', 'ox' })
W.fault.moneySilent = true
ok, why = bridge:RemoveMoney(1, 'cash', 10)
check(ok == false and why == 'refused' and money(1, 'cash') == 1000, 'a silent remove is refused: ' .. tostring(why))
ok, why = bridge:AddMoney(1, 'cash', 10)
check(ok == false and why == 'refused' and money(1, 'cash') == 1000, 'a silent add is refused: ' .. tostring(why))
ok, why = bridge:Purchase(1, { item = 'water', price = 10 })
check(ok == false and why == 'refused' and W.count(1, 'water') == 0, 'a silent payment gives no item: ' .. tostring(why))
check(events('cis_bridge:inconsistent') == 0, 'nothing moved, so nothing is inconsistent')

-- A framework that moved the wrong amount: error, and the event names it.
boot({ 'esx', 'ox' })
W.fault.moneySkew = 1
ok, why = bridge:AddMoney(1, 'cash', 10)
check(ok == false and why == 'error' and money(1, 'cash') == 1011, 'a skewed add is error: ' .. tostring(why))
inc = W.firedNamed('cis_bridge:inconsistent')
check(#inc == 1 and inc[1][1] == 1 and inc[1][2].action == 'add_money' and inc[1][2].account == 'cash'
    and inc[1][2].amount == 10 and inc[1][2].moved == 11, 'inconsistent names account, amount and what moved')
ok, why = bridge:Purchase(1, { item = 'water', price = 10 })
check(ok == false and why == 'error' and W.count(1, 'water') == 0, 'a skewed payment gives no item: ' .. tostring(why))

-- GetMoney floors a fractional balance to an integer.
boot({ 'esx', 'ox' })
W.players[1].money.cash = 10.5
local cash = bridge:GetMoney(1, 'cash')
check(cash == 10 and math.type(cash) == 'integer', 'GetMoney floors 10.5 to the integer 10: ' .. tostring(cash))

-- Line 1 lands, line 2 is refused, and line 1 cannot be taken back: line 1
-- is the player's and paid for; line 2 is refunded.
boot({ 'esx', 'ox' })
W.fault.during = { ['ox_inventory.AddItem'] = function()
    if #W.callsTo('ox_inventory.AddItem') == 2 then W.fault.addLands, W.fault.removeTakes = 0, 0 end
end }
ok, why = bridge:Purchase(1, { lines = {
    { item = 'water', count = 2, price = 10 },
    { item = 'bread', count = 2, price = 10 },
} })
check(ok == false and why == 'partial', 'a take-back that fails answers partial: ' .. tostring(why))
check(money(1, 'cash') == 980 and W.count(1, 'water') == 2 and W.count(1, 'bread') == 0,
    'the kept line is paid for, the refused line refunded')
inc = W.firedNamed('cis_bridge:inconsistent')
check(#inc == 1 and inc[1][2].action == 'purchase' and inc[1][2].item == 'water' and inc[1][2].count == 2,
    'inconsistent names the line that stayed')

-- The take-back names the slot the add landed in (ox matches any slot of
-- that item otherwise, and takes a player's own copy).
boot({ 'esx', 'ox' })
W.oxSlot = 40
W.fault.during = { ['ox_inventory.AddItem'] = function()
    if #W.callsTo('ox_inventory.AddItem') == 2 then W.fault.addLands = 0 end
end }
bridge:Purchase(1, { lines = { { item = 'water', count = 2, price = 10 }, { item = 'bread', count = 2, price = 10 } } })
local rm = W.callsTo('ox_inventory.RemoveItem')
check(#rm == 1 and rm[1][2] == 'water' and rm[1][3] == 2 and rm[1][5] == 41 and rm[1][6] == true,
    'the take-back removes from the slot AddItem answered')
check(money(1, 'cash') == 1000 and W.count(1, 'water') == 0, 'and everything is refunded')

-- A purchase that does not fit is refused before any money moves, even when
-- the refund would fail.
boot({ 'esx', 'ox' })
W.fault.moneyAddFails = true
ok, why = bridge:Purchase(1, { item = 'water', count = 60, price = 1 })
check(ok == false and why == 'cannot_carry' and money(1, 'cash') == 1000, 'an order that does not fit is not charged: ' .. tostring(why))

-- An order total over the bound is rejected before the inventory is asked.
boot({ 'esx', 'ox' })
for _, order in ipairs({
    { item = 'water', count = 2, price = 6e8 },
    { lines = { { item = 'water', price = 6e8 }, { item = 'bread', price = 6e8 } } },
}) do
    ok, why = bridge:Purchase(1, order)
    check(ok == false and why == 'bad_amount', 'an order over the total bound is bad_amount: ' .. tostring(why))
end
check(#W.callsTo('ox_inventory.CanCarryItem') == 0, 'a rejected order never reaches CanCarryItem')

-- Sources: nil, NaN and the console are never players.
boot({ 'esx', 'ox' })
ok, why = bridge:AddMoney(nil, 'cash', 1)
check(ok == false and why == 'bad_source', 'AddMoney(nil) is bad_source')
ok, why = bridge:Purchase(0 / 0, { item = 'water', price = 1 })
check(ok == false and why == 'bad_source', 'Purchase(NaN) is bad_source')
local realName = GetPlayerName
GetPlayerName = function(src) if src == 0 then return 'console' end return realName(src) end
ok, why = bridge:GetPlayer(0)
check(ok == false and why == 'bad_source', 'source 0 is not a player even when it has a name')
ok, why = bridge:AddMoney(0, 'cash', 1)
check(ok == false and why == 'bad_source', 'AddMoney(0) is bad_source')
GetPlayerName = realName

-- Purchase holds the player's lock across its writes.
boot({ 'esx', 'ox' })
W.fault.during = { ['ox_inventory.AddItem'] = function()
    inner = table.pack(bridge:AddMoney(1, 'cash', 5))
end }
check(bridge:Purchase(1, { item = 'water', price = 10 }) == true, 'the purchase lands')
check(inner[1] == false and inner[2] == 'busy' and money(1, 'cash') == 990, 'a write inside a purchase is busy')

-- A conformance re-detect inside a purchase waits: it answers busy and the
-- purchase finishes on the adapters it started with, even when the inventory
-- stopped halfway.
boot({ 'esx', 'ox' })
W.fault.during = { ['ox_inventory.AddItem'] = function()
    W.state.ox_inventory = 'stopped'
    inner = table.pack(pcall(V1.redetect))
    W.state.ox_inventory = 'started'
end }
check(bridge:Purchase(1, { item = 'water', price = 10 }) == true, 'the purchase lands past a re-detect')
check(inner[1] == true and inner[2] == false and inner[3] == 'busy', 'a re-detect inside a purchase is busy: ' .. tostring(inner[3]))
check(V1.summary().inventory == 'ox_inventory', 'the purchase kept its inventory adapter')
W.fault.during = nil
check(V1.redetect() == true, 'a re-detect with no write in flight runs')

-- A logout does not free a write still in flight; a drop does.
boot({ 'qbcore', 'qb' })
W.fault.during = { ['qb-inventory.AddItem'] = function()
    W.fire('QBCore:Server:OnPlayerUnload', nil, 1)
    inner = table.pack(bridge:AddMoney(1, 'cash', 1))
end }
bridge:AddItem(1, 'water', 1)
check(inner[1] == false and inner[2] == 'busy', 'a logout mid-write keeps the lock: ' .. tostring(inner[2]))

-- A write that outlives its player's drop releases only its own lock: the
-- next write for that id took the freed lock and still holds it.
boot({ 'esx', 'ox' })
local step = 0
W.fault.during = { ['ox_inventory.AddItem'] = function()
    step = step + 1
    if step == 1 then W.fire('playerDropped', 1, 'left') end
    coroutine.yield()
end }
local first = coroutine.create(function() return bridge:AddItem(1, 'water', 1) end)
local second = coroutine.create(function() return bridge:AddItem(1, 'bread', 1) end)
coroutine.resume(first)
coroutine.resume(second)
W.fault.during = nil
local done1 = table.pack(coroutine.resume(first))
check(done1[1] == true and done1[2] == true, 'the first write finishes: ' .. tostring(done1[2]))
ok, why = bridge:AddMoney(1, 'cash', 1)
check(ok == false and why == 'busy', "the stale write did not release the second write's lock: " .. tostring(why))
coroutine.resume(second)
check(bridge:AddMoney(1, 'cash', 1) == true, 'the second write releases its own lock')

-- A re-detect that yields (a framework call inside detect waits) holds every
-- write and every re-detect off until it finishes: a second write for the
-- same player answers busy, and the first write still lands.
boot({ 'qbox', 'ox' })
W.fire('onResourceStart', nil, 'ox_inventory')
local yielded = false
W.fault.during = { ['qbx_core.GetPlayer'] = function()
    if not yielded then yielded = true coroutine.yield('detect') end
end }
local held = coroutine.create(function() return bridge:AddMoney(1, 'cash', 1) end)
check(select(2, coroutine.resume(held)) == 'detect', 'the first write yields inside detect')
W.fault.during = nil
local cashBefore = money(1, 'cash')
ok, why = bridge:AddMoney(1, 'cash', 1)
check(ok == false and why == 'busy', 'a write while detect yields is busy: ' .. tostring(why))
ok, why = V1.redetect()
check(ok == false and why == 'busy', 'a re-detect while detect yields is busy: ' .. tostring(why))
local heldRes = table.pack(coroutine.resume(held))
check(heldRes[1] == true and heldRes[2] == true and money(1, 'cash') == cashBefore + 1,
    'the first write lands once detect finishes: ' .. tostring(heldRes[2]) .. ' ' .. tostring(heldRes[3]))
check(bridge:AddMoney(1, 'cash', 1) == true, 'writes run again after the detect')

-- A detect can also yield before it is done picking (the ESX probe calls
-- getSharedObject). A read in that window does not start a second detect.
boot({ 'esx', 'ox' })
W.fire('onResourceStart', nil, 'ox_inventory')
yielded = false
W.fault.during = { ['es_extended.getSharedObject'] = function()
    if not yielded then yielded = true coroutine.yield('probe') end
end }
held = coroutine.create(function() return V1.summary() end)
check(select(2, coroutine.resume(held)) == 'probe', 'a read yields inside the ESX probe')
W.fault.during = nil
local probes = #W.callsTo('es_extended.getSharedObject')
V1.summary()
check(#W.callsTo('es_extended.getSharedObject') == probes,
    'a read while the probe yields starts no second detect: ' .. (#W.callsTo('es_extended.getSharedObject') - probes))
heldRes = table.pack(coroutine.resume(held))
check(heldRes[1] == true and heldRes[2].framework == 'esx', 'the held read finishes on ESX')

-- QBCore re-fires its job event on login and on duty: one change, one event.
boot({ 'qbcore', 'qb' })
local qbJob = W.qbPlayerData(1).job
W.fire('QBCore:Server:OnJobUpdate', nil, 1, qbJob)
W.fire('QBCore:Server:OnJobUpdate', nil, 1, qbJob)
check(events('cis_bridge:jobChanged') == 1, 'the same job twice is one jobChanged')
check(bridge:SetJob(1, 'police', 1) == true and events('cis_bridge:jobChanged') == 2, 'a new job is a new jobChanged')
W.fire('playerDropped', 1, 'left')
W.fire('QBCore:Server:OnJobUpdate', nil, 1, W.qbPlayerData(1).job)
check(events('cis_bridge:jobChanged') == 3, 'after a drop the id starts again')
-- A re-detect starts the memory again: the adapter that answers now may not be
-- the one that saw the last job.
W.fire('onResourceStop', nil, 'qb-inventory')
W.fire('onResourceStart', nil, 'qb-inventory')
W.fire('QBCore:Server:OnJobUpdate', nil, 1, W.qbPlayerData(1).job)
check(events('cis_bridge:jobChanged') == 4, 'a re-detect starts the job memory again: ' .. events('cis_bridge:jobChanged'))

-- ox: CanCarry on an item ox does not know is unknown_item, not a fit.
boot({ 'esx', 'ox' })
ok, why = CisBridgeInventories.ox_inventory.canCarry(1, 'unobtainium', 1)
check(ok == false and why == 'unknown_item', 'ox canCarry on an unknown item: ' .. tostring(why))

-- The facade answers in the v1 shape when cis_bridge cannot.
boot({ 'esx', 'ox' })
dofile('init.lua')
check(CisBridge.GetMoney(1, 'cash') == 1000, 'the facade forwards')
W.fault.addLands, W.fault.removeTakes = 1, 0
local fa, fb = CisBridge.AddItem(1, 'phone', 3)
check(fa == false and fb == 'partial', 'the facade passes every return value')
W.fault.raise = { ['cis_bridge.GetMoney'] = true }
ok, why = CisBridge.GetMoney(1, 'cash')
check(ok == false and why == 'error', 'a raise across the boundary is error: ' .. tostring(why))
local facadeSaid = false
for _, line in ipairs(W.prints) do
    if line:find('cis_bridge facade: GetMoney raised', 1, true) then facadeSaid = true end
end
check(facadeSaid, 'and the facade says so on the console')
W.fault.raise = nil
W.state.cis_bridge = 'stopped'
ok, why = CisBridge.GetMoney(1, 'cash')
check(ok == false and why == 'no_bridge', 'a stopped bridge is no_bridge: ' .. tostring(why))
W.state.cis_bridge = 'started'

-- ===========================================================================

-- ===========================================================================
--  13. Failure paths: refund signal, counts, re-detection, duty, clamps
-- ===========================================================================

do
    -- A refund that moved the wrong amount may have landed: error, never
    -- refundFailed (a listener that pays refundFailed again would pay twice).
    boot({ 'esx', 'ox' })
    W.fault.during = { ['ox_inventory.AddItem'] = function() W.fault.addLands = 0; W.fault.moneySkew = 1 end }
    ok, why = bridge:Purchase(1, { item = 'water', count = 2, price = 10 })
    check(ok == false and why == 'error', 'a skewed refund is error: ' .. tostring(why))
    check(events('cis_bridge:refundFailed') == 0, 'a skewed refund is not refundFailed')
    local inc13 = W.firedNamed('cis_bridge:inconsistent')
    check(#inc13 == 1 and inc13[1][2].action == 'add_money' and inc13[1][2].amount == 20 and inc13[1][2].moved == 21,
        'a skewed refund fires the money inconsistent event')

    -- A refund whose balance cannot be read after it: error, not refundFailed.
    boot({ 'qbox', 'ox' })
    W.fault.during = {
        ['ox_inventory.AddItem'] = function() W.fault.addLands = 0 end,
        ['qbx_core.AddMoney'] = function() W.fault.raise = { ['qbx_core.GetMoney'] = true } end,
    }
    ok, why = bridge:Purchase(1, { item = 'water', count = 2, price = 10 })
    W.fault.raise = nil
    check(ok == false and why == 'error' and money(1, 'cash') == 1000, 'an unreadable refund is error: ' .. tostring(why))
    check(events('cis_bridge:refundFailed') == 0, 'an unreadable refund is not refundFailed')

    -- A refund that did not move at all is still refund_failed.
    boot({ 'esx', 'ox' })
    W.fault.during = { ['ox_inventory.AddItem'] = function() W.fault.addLands = 0; W.fault.moneySilent = true end }
    ok, why = bridge:Purchase(1, { item = 'water', count = 2, price = 10 })
    check(ok == false and why == 'refund_failed' and money(1, 'cash') == 980, 'a refund that never moved is refund_failed: ' .. tostring(why))
    check(events('cis_bridge:refundFailed') == 1, 'and fires refundFailed')

    -- A missing count is bad_count, not a default.
    boot({ 'qbcore', 'qb' })
    ok, why = bridge:AddItem(1, 'water')
    check(ok == false and why == 'bad_count' and W.count(1, 'water') == 0, 'AddItem with no count is bad_count: ' .. tostring(why))
    ok, why = bridge:RemoveItem(1, 'water')
    check(ok == false and why == 'bad_count', 'RemoveItem with no count is bad_count: ' .. tostring(why))
    ok, why = bridge:CanCarry(1, 'water')
    check(ok == false and why == 'bad_count', 'CanCarry with no count is bad_count: ' .. tostring(why))
    check(bridge:GetItemCount(1, 'water') == 0, 'GetItemCount still needs no count')

    -- The inventory stopping mid-purchase does not swap adapters under it: the
    -- purchase ends on ox, which now raises, so the landed water stays paid
    -- for and the bread is refunded (before the fix the take-back raised on a
    -- nil adapter and the refund never ran).
    boot({ 'qbcore', 'ox' })
    local reads = 0
    W.fault.during = { ['ox_inventory.GetItemCount'] = function()
        reads = reads + 1
        if reads == 2 then W.state.ox_inventory = 'stopped'; W.fire('onResourceStop', nil, 'ox_inventory') end
    end }
    ok, why = bridge:Purchase(1, { lines = { { item = 'water', count = 2, price = 10 }, { item = 'bread', count = 2, price = 10 } } })
    W.fault.during = nil
    check(ok == false and why == 'partial' and money(1, 'cash') == 980 and W.count(1, 'water') == 2 and W.count(1, 'bread') == 0,
        'a purchase finishes on the inventory it started with: ' .. tostring(why) .. ' ' .. money(1, 'cash'))
    ok, why = bridge:GetItemCount(1, 'water')
    check(ok == false and why == 'no_inventory', 'and the next call re-detects: ' .. tostring(why))
    W.state.ox_inventory = 'started'

    -- A duty toggle is not a job change.
    boot({ 'qbcore', 'qb' })
    local job13 = W.qbPlayerData(1).job
    for i = 1, 10 do
        job13.onduty = (i % 2 == 0)
        W.fire('QBCore:Server:OnJobUpdate', nil, 1, job13)
    end
    check(events('cis_bridge:jobChanged') == 1, 'ten duty toggles are one jobChanged: ' .. events('cis_bridge:jobChanged'))

    -- A free line that cannot be taken back is still partial, though no money
    -- is kept for it: the second line lands nothing, the first stays.
    boot({ 'esx', 'ox' })
    local adds = 0
    W.fault.during = { ['ox_inventory.AddItem'] = function()
        adds = adds + 1
        if adds == 2 then W.fault.addLands, W.fault.removeTakes = 0, 0 end
    end }
    ok, why = bridge:Purchase(1, { lines = { { item = 'phone', count = 1, price = 0 }, { item = 'water', count = 2, price = 10 } } })
    W.fault.during = nil
    check(ok == false and why == 'partial' and money(1, 'cash') == 1000 and W.count(1, 'phone') == 1,
        'a stuck free line answers partial: ' .. tostring(why))

    -- Stuck units are clamped to what this write landed.
    boot({ 'esx', 'ox' })
    W.fault.addLands, W.fault.removeTakes = 1, 0
    W.fault.during = { ['ox_inventory.RemoveItem'] = function()
        W.players[1].items.phone = (W.players[1].items.phone or 0) + 5
    end }
    ok, why = bridge:Purchase(1, { item = 'phone', count = 3, price = 100 })
    check(ok == false and why == 'partial' and money(1, 'cash') == 900,
        'one stuck phone is paid for, the rest refunded, whatever else arrived: ' .. tostring(money(1, 'cash')))

    -- A remove's stuck units are clamped to what this remove took: items
    -- another resource takes during the put-back are not this write's.
    boot({ 'esx', 'ox' })
    W.players[1].items.phone = 10
    W.fault.addLands, W.fault.removeTakes = 0, 1
    W.fault.during = { ['ox_inventory.AddItem'] = function()
        W.players[1].items.phone = W.players[1].items.phone - 5
    end }
    ok, why = bridge:RemoveItem(1, 'phone', 3)
    W.fault.during = nil
    local rinc = W.firedNamed('cis_bridge:inconsistent')
    check(ok == false and why == 'partial' and #rinc == 1 and rinc[1][2].action == 'remove'
        and rinc[1][2].count == 1,
        'a remove reports the one unit it took, not what else left: ' .. tostring(rinc[1] and rinc[1][2].count))

    -- Balances and counts that are not finite numbers are not read.
    boot({ 'esx', 'ox' })
    W.players[1].money.cash = math.huge
    ok, why = bridge:GetMoney(1, 'cash')
    check(ok == false and why == 'not_loaded', 'an infinite balance is not_loaded: ' .. tostring(ok))
    W.players[1].money.cash = 1000
    local realCount = W.declared.ox_inventory.GetItemCount
    W.declared.ox_inventory.GetItemCount = function() return 0 / 0 end
    ok, why = bridge:GetItemCount(1, 'water')
    check(ok == false and why == 'not_loaded', 'a NaN count is not_loaded: ' .. tostring(ok))
    W.declared.ox_inventory.GetItemCount = realCount

    -- An inventory that answers no count at all has not read the player. Read
    -- as 0, the count after a remove would prove a removal that never happened.
    for _, c in ipairs({
        { inv = 'ox', res = 'ox_inventory', fn = 'GetItemCount' },
        { inv = 'qs', res = 'qs-inventory', fn = 'GetItemTotalAmount' },
        { inv = 'codem', res = 'codem-inventory', fn = 'GetItemsTotalAmount' },
    }) do
        boot({ 'qbcore', c.inv })
        local real = W.declared[c.res][c.fn]
        W.declared[c.res][c.fn] = function() return nil end
        ok, why = bridge:GetItemCount(1, 'water')
        check(ok == false and why == 'not_loaded', c.res .. ': a nil count is not_loaded: ' .. tostring(ok))
        check(printed('raised') == 0, c.res .. ': a nil count crosses as zero values and raises nothing')
        W.declared[c.res][c.fn] = real
    end

    -- A framework export that answers a lone nil hands the bridge zero values
    -- (test/lib/v1world.lua W.crossBack). The adapter reads that as no
    -- balance, not as a raise.
    boot({ 'qbox', 'ox' })
    local realMoney = W.declared.qbx_core.GetMoney
    W.declared.qbx_core.GetMoney = function() return nil end
    ok, why = bridge:GetMoney(1, 'cash')
    check(ok == false and printed('raised') == 0, 'qbox: a nil balance is refused without a raise: ' .. tostring(why))
    W.declared.qbx_core.GetMoney = realMoney
    boot({ 'qbcore', 'ox' })
    W.players[1].money.cash = nil
    ok, why = bridge:GetMoney(1, 'cash')
    check(ok == false and printed('raised') == 0, 'qbcore: a nil balance is refused without a raise: ' .. tostring(why))
    W.players[1].money.cash = 1000

    -- cis_inventory GetItem that answers nothing is an unknown item.
    boot({ 'qbox', 'cis' })
    local realGet = W.declared.cis_inventory.GetItem
    W.declared.cis_inventory.GetItem = function() return nil end
    local okK, known = pcall(CisBridgeInventories.cis_inventory.known, 'water')
    check(okK and known == false, 'cis_inventory: a nil item answer is not known: ' .. tostring(known))
    W.declared.cis_inventory.GetItem = realGet

    -- A raising item lookup is error, not unknown_item.
    boot({ 'esx', 'ox' })
    local realItems = W.declared.ox_inventory.Items
    W.declared.ox_inventory.Items = function() error('boom') end
    ok, why = bridge:CanCarry(1, 'water', 1)
    check(ok == false and why == 'error', 'a raising item lookup is error: ' .. tostring(why))
    W.declared.ox_inventory.Items = realItems

    -- A write re-detects before it takes the lock: an inventory that starts
    -- after the bridge found none is used by the next write, not only after
    -- a read.
    boot({ 'qbcore' })
    ok, why = bridge:AddItem(1, 'water', 1)
    check(ok == false and why == 'no_inventory', 'no inventory yet: ' .. tostring(why))
    W.state.ox_inventory = 'started'
    W.fire('onResourceStart', nil, 'ox_inventory')
    check(bridge:AddItem(1, 'water', 1) == true and #W.callsTo('ox_inventory.AddItem') == 1,
        'the next write uses the inventory that started')

    -- A write that yields and never comes back stops re-detection only until
    -- its player drops.
    boot({ 'esx', 'ox' })
    check(bridge:GetMoney(1, 'cash') == 1000, 'detected before the hung write')
    local hung = coroutine.create(function()
        W.fault.during = { ['ox_inventory.AddItem'] = function() coroutine.yield('hang') end }
        return bridge:AddItem(1, 'water', 1)
    end)
    check(select(2, coroutine.resume(hung)) == 'hang', 'the write is hung')
    W.fault.during = nil
    W.fire('playerDropped', 1, 'left')
    W.state.ox_inventory = 'stopped'
    W.fire('onResourceStop', nil, 'ox_inventory')
    check(V1.summary().inventory == 'esx', 'after the drop a read re-detects (ESX falls back to its own): ' .. tostring(V1.summary().inventory))
    W.state.ox_inventory = 'started'
end

-- ===========================================================================
--  14. cis_inventory: its refusals mapped to the v1 codes
-- ===========================================================================

do
    local CI = CisBridgeInventories.cis_inventory
    check(CI.name == 'cis_inventory' and CI.resource == 'cis_inventory', 'cis_inventory adapter names its resource')

    boot({ 'qbox', 'cis' })
    -- An add answers the slots it landed in; the adapter passes them on.
    W.cisSlot = 70
    local added, slots = CI.add(1, 'water', 2)
    check(added == true and type(slots) == 'table' and #slots == 1 and slots[1].slot == 71 and slots[1].count == 2,
        'cis add answers its slots as { slot, count }')
    -- Positional { slot, count } entries are read too.
    local realAdd = W.declared.cis_inventory.AddItem
    W.declared.cis_inventory.AddItem = function(inv, item, n) realAdd(inv, item, n); return true, { { 9, n } } end
    added, slots = CI.add(1, 'water', 1)
    check(added == true and slots and slots[1].slot == 9 and slots[1].count == 1, 'positional slot entries are read')
    W.declared.cis_inventory.AddItem = function(inv, item, n) realAdd(inv, item, n); return true, 'nonsense' end
    added, slots = CI.add(1, 'water', 1)
    check(added == true and slots == nil, 'a slot answer that is not a list is no slots, not a raise')
    W.declared.cis_inventory.AddItem = realAdd

    for _, case in ipairs({
        { 'too_heavy', 'cannot_carry' }, { 'no_slot', 'cannot_carry' }, { 'unknown_item', 'unknown_item' },
        { 'busy', 'busy' }, { 'frozen', 'busy' }, { 'not_loaded', 'not_loaded' },
        { 'hook_refused', 'refused' }, { 'bad_metadata', 'refused' }, { 'not_authorized', 'refused' },
    }) do
        W.fault.cisAdd = case[1]
        local ok14, why14 = CI.add(1, 'water', 1)
        check(ok14 == false and why14 == case[2], ('cis add %s answers %s: %s'):format(case[1], case[2], tostring(why14)))
    end
    W.fault.cisAdd = nil

    for _, case in ipairs({
        { 'too_heavy', 'cannot_carry' }, { 'no_slot', 'cannot_carry' }, { 'unknown_item', 'unknown_item' },
        { 'not_loaded', 'not_loaded' }, { 'frozen', 'cannot_carry' },
    }) do
        W.fault.cisCarry = case[1]
        local ok14, why14 = CI.canCarry(1, 'water', 1)
        check(ok14 == false and why14 == case[2], ('cis canCarry %s answers %s: %s'):format(case[1], case[2], tostring(why14)))
    end
    W.fault.cisCarry = nil

    W.players[1].items.water = 5
    for _, case in ipairs({
        { 'insufficient_items', 'insufficient_items' }, { 'busy', 'busy' }, { 'busy_slot', 'busy' },
        { 'frozen', 'busy' }, { 'locked_item', 'refused' }, { 'not_loaded', 'refused' },
    }) do
        W.fault.cisRemove = case[1]
        local ok14, why14 = CI.remove(1, 'water', 1)
        check(ok14 == false and why14 == case[2], ('cis remove %s answers %s: %s'):format(case[1], case[2], tostring(why14)))
    end
    W.fault.cisRemove = nil

    -- A count refusal is no count, except unknown_item, which is a real zero.
    check(CI.count(1, 'unobtainium') == 0, 'cis count of an unknown item is 0')
    check(CI.count(2, 'water') == nil, 'cis count of an unloaded player is no count')
    W.fault.cisCount = 'frozen'
    check(CI.count(1, 'water') == nil, 'cis count refused as frozen is no count')
    W.fault.cisCount = nil
    check(CI.known('water') == true and CI.known('unobtainium') == false, 'cis known reads GetItem')

    -- Through the v1 exports.
    boot({ 'cis_core', 'cis' })
    W.fault.cisAdd = 'frozen'
    local ok14, why14 = bridge:AddItem(1, 'water', 1)
    check(ok14 == false and why14 == 'busy' and W.count(1, 'water') == 0, 'a frozen inventory answers busy: ' .. tostring(why14))
    W.fault.cisAdd = nil
    W.calls = {}
    W.fault.cisCount = 'not_loaded'
    ok14, why14 = bridge:GetItemCount(1, 'water')
    check(ok14 == false and why14 == 'not_loaded', 'a refused count is not_loaded, never a false zero: ' .. tostring(why14))
    ok14, why14 = bridge:AddItem(1, 'water', 1)
    check(ok14 == false and why14 == 'not_loaded' and #W.callsTo('cis_inventory.AddItem') == 0,
        'no write is tried against a count it cannot read')
    W.fault.cisCount = nil
    W.fault.cisCarry = 'no_slot'
    ok14, why14 = bridge:CanCarry(1, 'water', 1)
    check(ok14 == false and why14 == 'cannot_carry', 'no_slot is cannot_carry: ' .. tostring(why14))
    W.fault.cisCarry = nil
    W.players[1].items.water = 3
    W.fault.cisRemove = 'busy_slot'
    ok14, why14 = bridge:RemoveItem(1, 'water', 1)
    check(ok14 == false and why14 == 'busy' and W.count(1, 'water') == 3, 'a busy slot answers busy: ' .. tostring(why14))
    W.fault.cisRemove = nil

    -- The purchase take-back removes from the slot the add answered, one call
    -- per slot, with the metadata argument left nil.
    boot({ 'qbox', 'cis' })
    W.cisSlot = 40
    W.fault.during = { ['cis_inventory.AddItem'] = function()
        if #W.callsTo('cis_inventory.AddItem') == 2 then W.fault.cisAdd = 'too_heavy' end
    end }
    ok14, why14 = bridge:Purchase(1, { lines = { { item = 'water', count = 2, price = 10 }, { item = 'bread', count = 2, price = 10 } } })
    W.fault.during, W.fault.cisAdd = nil, nil
    local rm14 = W.callsTo('cis_inventory.RemoveItem')
    check(ok14 == false and why14 == 'cannot_carry', 'the second line does not fit: ' .. tostring(why14))
    check(#rm14 == 1 and rm14[1][1] == 1 and rm14[1][2] == 'water' and rm14[1][3] == 2 and rm14[1][4] == nil
        and rm14[1][5] == 41, 'the take-back names the slot cis AddItem answered')
    check(money(1, 'cash') == 1000 and W.count(1, 'water') == 0, 'and everything is refunded')

    -- Two slots: two removes, each for its own count; a refused one is
    -- reported after the rest were tried.
    boot({ 'qbox', 'cis' })
    W.players[1].items.phone = 2
    local ok2 = CI.remove(1, 'phone', 2, { { slot = 3, count = 1 }, { slot = 4, count = 1 } })
    rm14 = W.callsTo('cis_inventory.RemoveItem')
    check(ok2 == true and #rm14 == 2 and rm14[1][5] == 3 and rm14[1][3] == 1 and rm14[2][5] == 4 and rm14[2][3] == 1,
        'a two-slot take-back removes from each slot')
    W.players[1].items.phone = 2
    W.calls = {}
    W.fault.during = { ['cis_inventory.RemoveItem'] = function()
        W.fault.cisRemove = #W.callsTo('cis_inventory.RemoveItem') == 1 and 'busy_slot' or nil
    end }
    ok14, why14 = CI.remove(1, 'phone', 2, { { slot = 3, count = 1 }, { slot = 4, count = 1 } })
    W.fault.during, W.fault.cisRemove = nil, nil
    check(ok14 == false and why14 == 'busy' and W.count(1, 'phone') == 1 and #W.callsTo('cis_inventory.RemoveItem') == 2,
        'a refused slot is reported after the next slot was still tried: ' .. tostring(why14))
end

-- ===========================================================================
--  15. GetOwnedVehicleId: one conformance case per framework
-- ===========================================================================

-- Qbox answers player_vehicles.id through qbx_vehicles.
boot({ 'qbox', 'qbx_vehicles' })
check(bridge:GetOwnedVehicleId('ABC123') == 7, 'qbox: the owned plate answers player_vehicles.id')
check(bridge:GetOwnedVehicleId('  ABC123 ') == 7, 'qbox: the plate is trimmed as GTA pads it')
local okV, whyV = bridge:GetOwnedVehicleId('NOPE1')
check(okV == false and whyV == 'not_owned', 'qbox: a plate nobody owns answers not_owned: ' .. tostring(whyV))
W.fault.raise = { ['qbx_vehicles.GetVehicleIdByPlate'] = true }
okV, whyV = bridge:GetOwnedVehicleId('ABC123')
W.fault.raise = nil
check(okV == false and whyV == 'error', 'qbox: qbx_vehicles that raises answers error: ' .. tostring(whyV))
boot({ 'qbox' })
okV, whyV = bridge:GetOwnedVehicleId('ABC123')
check(okV == false and whyV == 'unsupported', 'qbox without qbx_vehicles answers unsupported: ' .. tostring(whyV))

-- ESX and QBCore key their tables by plate: the plate is the id, read through
-- oxmysql's awaited scalar on behalf of cis_bridge.
for fw, tbl in pairs({ esx = 'owned_vehicles', qbcore = 'player_vehicles' }) do
    boot({ fw, 'oxmysql' })
    check(bridge:GetOwnedVehicleId('ABC123') == 'ABC123', fw .. ': the owned plate answers the plate')
    local q = W.sql[1]
    check(q and q.query:find(tbl, 1, true) and q.params[1] == 'ABC123', fw .. ': one query on ' .. tbl)
    check(q and q.invoker == 'cis_bridge' and q.awaited == true, fw .. ': the scalar is awaited as cis_bridge')
    okV, whyV = bridge:GetOwnedVehicleId('NOPE1')
    check(okV == false and whyV == 'not_owned', fw .. ': a plate nobody owns answers not_owned: ' .. tostring(whyV))
    bridge:GetOwnedVehicleId(123.0)
    local qn = W.sql[#W.sql]
    check(qn and qn.params[1] == '123', fw .. ': a whole float plate 123.0 reads as "123": ' .. tostring(qn and qn.params[1]))
    W.sqlError = "Table 'owned_vehicles' doesn't exist"
    okV, whyV = bridge:GetOwnedVehicleId('ABC123')
    check(okV == false and whyV == 'error', fw .. ': a database error answers error, not not_owned: ' .. tostring(whyV))
    W.sqlError = nil
    boot({ fw })
    okV, whyV = bridge:GetOwnedVehicleId('ABC123')
    check(okV == false and whyV == 'unsupported', fw .. ' without oxmysql answers unsupported: ' .. tostring(whyV))
end

boot({ 'cis_core' })
okV, whyV = bridge:GetOwnedVehicleId('ABC123')
check(okV == false and whyV == 'unsupported', 'cis_core answers unsupported: ' .. tostring(whyV))
boot({})
okV, whyV = bridge:GetOwnedVehicleId('ABC123')
check(okV == false and whyV == 'unsupported', 'no framework answers unsupported: ' .. tostring(whyV))

-- Bad plates never reach the framework.
boot({ 'qbox', 'qbx_vehicles' })
for _, bad in ipairs({ { nil, 'nil' }, { {}, 'a table' }, { '', 'empty' }, { '    ', 'only spaces' },
    { 'ABCDEFGHIJKLMNOP', '16 chars' }, { 'AB\nC', 'a control char' }, { 1.5, 'a fraction' }, { 0 / 0, 'NaN' } }) do
    W.calls = {}
    okV, whyV = bridge:GetOwnedVehicleId(bad[1])
    check(okV == false and whyV == 'bad_plate' and #W.callsTo('qbx_vehicles.GetVehicleIdByPlate') == 0,
        'plate ' .. bad[2] .. ' answers bad_plate: ' .. tostring(whyV))
end
check(bridge:GetOwnedVehicleId('ABCDEFGHIJKLMNO') == false, '15 chars is a plate the framework is asked about')
W.vehicles['4512'] = { id = 9 }
check(bridge:GetOwnedVehicleId(4512) == 9, 'a whole-number plate is read as its digits')

-- ===========================================================================
--  16. SaveAppearance: detection and one conformance case per clothing resource
-- ===========================================================================

local function saveEvents()
    local out = {}
    for _, e in ipairs(W.clientFired) do
        if e.name == 'cis_bridge:appearance:save' then out[#out + 1] = e end
    end
    return out
end

boot({ 'qbox', 'illenium-appearance', 'skinchanger', 'qb-clothing' })
check(V1.summary().appearance == 'illenium-appearance', 'illenium-appearance is picked first')
check(bridge:SaveAppearance(1) == true, 'illenium: SaveAppearance answers true')
local ev = saveEvents()
check(#ev == 1 and ev[1].target == 1 and ev[1].args[1] == 'illenium-appearance',
    'illenium: the save is asked of that player, naming the adapter')

boot({ 'qbox', 'illenium-appearance', 'qb-clothing', 'oxmysql' })
W.convars['cis_bridge:appearance'] = 'qb-clothing'
V1.detect()
check(V1.summary().appearance == 'qb-clothing', 'the appearance convar wins')
check(bridge:SaveAppearance(1) == true and saveEvents()[1].args[1] == 'qb-clothing', 'qb-clothing: the save is asked')
W.convars['cis_bridge:appearance'] = nil

boot({ 'qbox', 'fivem-appearance' })
local okA, whyA = bridge:SaveAppearance(1)
check(okA == false and whyA == 'unsupported' and #saveEvents() == 0,
    'fivem-appearance has nowhere to save: unsupported, nothing asked: ' .. tostring(whyA))

-- skinchanger + esx_skin 1.16: no open edit session. The client sends what it
-- read, once, and the server saves it through the scoped SaveOutfit.
local function outfit(over)
    local o = {}
    for _, keys in pairs(CisBridgeAppearances.skinchanger.KEYS) do o[keys[1]], o[keys[2]] = 1, 0 end
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end
boot({ 'esx', 'skinchanger', 'esx_skin' })
check(bridge:SaveAppearance(1) == true and W.skinEdits[1] == nil and #saveEvents() == 1 and saveEvents()[1].args[2] == true,
    'skinchanger: no edit session, the client is asked to reply')
W.fire('cis_bridge:appearance:reply', 2, 'skinchanger', outfit())
check(W.outfits[2] == nil, 'skinchanger: a reply nobody asked for saves nothing')
W.fire('cis_bridge:appearance:reply', 1, 'skinchanger', outfit({ face = 3, helmet_1 = 12 }))
check(W.outfits[1] and W.outfits[1].helmet_1 == 12 and W.outfits[1].face == nil and W.outfits[1].arms_2 == 0,
    'skinchanger: the reply is saved through SaveOutfit, clothing keys only')
W.outfits[1] = nil
W.fire('cis_bridge:appearance:reply', 1, 'skinchanger', outfit())
check(W.outfits[1] == nil, 'skinchanger: a second reply saves nothing')
bridge:SaveAppearance(1)
W.fire('cis_bridge:appearance:reply', 1, 'skinchanger', outfit({ torso_1 = 1.5 }))
check(W.outfits[1] == nil and printed('skinchanger did not save the appearance for player 1: bad_clothing') == 1,
    'skinchanger: a bad value saves nothing and says why')
bridge:SaveAppearance(1)
W.clock = W.clock + 10001
W.fire('cis_bridge:appearance:reply', 1, 'skinchanger', outfit())
check(W.outfits[1] == nil, 'skinchanger: a late reply saves nothing')
bridge:SaveAppearance(1)
W.outfitRefused = true
W.fire('cis_bridge:appearance:reply', 1, 'skinchanger', outfit())
check(printed('skinchanger did not save the appearance for player 1: refused') == 1, 'skinchanger: a refused SaveOutfit says so')
bridge:SaveAppearance(1)
W.fire('playerDropped', 1, 'left')
W.outfitRefused = nil
W.fire('cis_bridge:appearance:reply', 1, 'skinchanger', outfit())
check(W.outfits[1] == nil, 'skinchanger: the pending reply of a dropped player is gone')
-- An esx_skin older than 1.16 has no SaveOutfit: the edit session, its
-- answer checked, and the client saves through esx_skin:save.
boot({ 'esx', 'skinchanger', 'esx_skin' })
W.skinLegacy = true
check(bridge:SaveAppearance(1) == true and W.skinEdits[1] == true and saveEvents()[1].args[2] == false,
    'skinchanger, older esx_skin: edit session opened before the save is asked')
W.clientFired = {}
W.skinEditRefused = true
okA, whyA = bridge:SaveAppearance(1)
check(okA == false and whyA == 'refused' and #saveEvents() == 0, 'skinchanger: a refused edit session asks nothing: ' .. tostring(whyA))
boot({ 'esx', 'skinchanger' })
okA, whyA = bridge:SaveAppearance(1)
check(okA == false and whyA == 'unsupported' and #saveEvents() == 0,
    'skinchanger without esx_skin: unsupported, nothing asked: ' .. tostring(whyA))

-- qb-clothing: the client sends the clothing back and the server merges it
-- into the citizen's active playerskins row, which keeps the face and each
-- entry's defaults.
local function qbClothes(over)
    local c = {}
    for key, part in pairs(CisBridgeAppearances['qb-clothing'].PARTS) do
        c[key] = { item = part.kind == 'prop' and -1 or 0, texture = 0 }
    end
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end
boot({ 'qbox', 'qb-clothing', 'oxmysql' })
local cid = bridge:GetPlayer(1).id
W.skins[cid] = json.encode({
    face = { item = 3, texture = 0 }, facemix = { skinMix = 0.5, shapeMix = 0.2 },
    hair = { item = 1, texture = 0, defaultItem = 0, defaultTexture = 0 },
    hat = { item = -1, texture = 0, defaultItem = -1, defaultTexture = 0 },
})
check(bridge:SaveAppearance(1) == true and saveEvents()[1].args[2] == true, 'qb-clothing: the client is asked to reply')
W.fire('cis_bridge:appearance:reply', 1, 'qb-clothing', qbClothes({
    hair = { item = 7, texture = 4 }, ['t-shirt'] = { item = 15, texture = 1 }, hat = { item = 12, texture = 2 },
    vest = { item = 2, texture = 0 }, bag = { item = 5, texture = 0 }, decals = { item = 1, texture = 0 },
    bracelet = { item = 3, texture = 0 }, wings = { item = 9, texture = 9 },
}))
local skinQ = json.decode(W.skins[cid])
check(skinQ.face.item == 3 and skinQ.facemix.skinMix == 0.5, 'qb-clothing: the stored face and its mix are kept')
check(skinQ.hair.item == 7 and skinQ.hair.texture == 4 and skinQ.hair.defaultItem == 0,
    'qb-clothing: hair from the reply, its default kept')
check(skinQ['t-shirt'].item == 15 and skinQ.vest.item == 2 and skinQ.bag.item == 5 and skinQ.decals.item == 1
    and skinQ.bracelet.item == 3, 'qb-clothing: t-shirt, vest, bag, decals and bracelet are saved')
check(skinQ.hat.item == 12 and skinQ.hat.defaultItem == -1, 'qb-clothing: hat from the reply, its default kept')
check(skinQ.wings == nil, 'qb-clothing: a key that is not clothing is dropped')
local lastSql = W.sql[#W.sql]
check(lastSql.query:find('UPDATE playerskins', 1, true) and lastSql.params[2] == cid and lastSql.awaited == true,
    'qb-clothing: one awaited UPDATE of the citizen\'s row')
local before = W.skins[cid]
bridge:SaveAppearance(1)
W.fire('cis_bridge:appearance:reply', 1, 'qb-clothing', qbClothes({ torso2 = { item = 1.5, texture = 0 } }))
check(W.skins[cid] == before and printed('qb-clothing did not save the appearance for player 1: bad_clothing') == 1,
    'qb-clothing: a bad value saves nothing and says why')
bridge:SaveAppearance(1)
W.fire('cis_bridge:appearance:reply', 1, 'qb-clothing', qbClothes({ hat = { item = -2, texture = 0 } }))
check(W.skins[cid] == before and printed('qb-clothing did not save the appearance for player 1: bad_clothing') == 2,
    'qb-clothing: a prop below -1 saves nothing')
W.skins[cid] = nil
bridge:SaveAppearance(1)
W.fire('cis_bridge:appearance:reply', 1, 'qb-clothing', qbClothes())
check(W.skins[cid] == nil and printed('qb-clothing did not save the appearance for player 1: no_skin') == 1,
    'qb-clothing: no stored skin, no face to keep, nothing saved')
W.sqlError = "Table 'playerskins' doesn't exist"
bridge:SaveAppearance(1)
W.fire('cis_bridge:appearance:reply', 1, 'qb-clothing', qbClothes())
check(printed('qb-clothing did not save the appearance for player 1: error') == 1
    and printed('qb-clothing did not save the appearance for player 1: no_skin') == 1,
    'qb-clothing: a failed read answers error, not no_skin')
W.sqlError = nil
boot({ 'qbox', 'qb-clothing' })
okA, whyA = bridge:SaveAppearance(1)
check(okA == false and whyA == 'unsupported' and #saveEvents() == 0,
    'qb-clothing without oxmysql: unsupported, nothing asked: ' .. tostring(whyA))

boot({ 'qbox' })
okA, whyA = bridge:SaveAppearance(1)
check(okA == false and whyA == 'no_appearance', 'no clothing resource answers no_appearance: ' .. tostring(whyA))
-- A clothing resource that starts later is found.
W.state['qb-clothing'] = 'started'
W.fire('onResourceStart', nil, 'qb-clothing')
check(V1.summary().appearance == 'qb-clothing', 'a clothing resource started later is detected')

boot({ 'qbox', 'illenium-appearance' })
okA, whyA = bridge:SaveAppearance(2)
check(okA == false and whyA == 'not_loaded' and #saveEvents() == 0, 'a player not loaded: not_loaded: ' .. tostring(whyA))
okA, whyA = bridge:SaveAppearance(0)
check(okA == false and whyA == 'bad_source', 'source 0: bad_source: ' .. tostring(whyA))
okA, whyA = bridge:SaveAppearance('1')
check(okA == false and whyA == 'bad_source', 'a string source: bad_source: ' .. tostring(whyA))

-- An adapter whose server half raises answers error and asks nothing.
local illenium = CisBridgeAppearances['illenium-appearance']
local realSave = illenium.server.save
illenium.server.save = function() error('boom') end
okA, whyA = bridge:SaveAppearance(1)
illenium.server.save = realSave
check(okA == false and whyA == 'error' and #saveEvents() == 0, 'a raising adapter answers error: ' .. tostring(whyA))

-- ===========================================================================
--  17. GetGang: one conformance case per framework
-- ===========================================================================

local function keysOf(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

for _, fw in ipairs({ 'qbcore', 'qbox' }) do
    boot({ fw })
    local g = bridge:GetGang(1)
    check(type(g) == 'table' and g.name == 'ballas' and g.label == 'Ballas' and g.grade == 2 and g.isboss == false,
        fw .. ': GetGang answers name, label, grade level and isboss')
    check(type(g) == 'table' and keysOf(g) == 4, fw .. ': GetGang answers exactly four fields')
    W.players[1].gang.isboss = true
    g = bridge:GetGang(1)
    check(type(g) == 'table' and g.isboss == true, fw .. ': a gang boss answers isboss true')
    W.players[1].gang.isboss = false
    W.players[1].gang.gradeIsboss = true
    g = bridge:GetGang(1)
    check(type(g) == 'table' and g.isboss == true, fw .. ': a boss grade answers isboss true')
    W.players[1].gang.gradeIsboss = nil
    g = bridge:GetGang(3)
    check(type(g) == 'table' and g.name == 'none' and g.grade == 0, fw .. ': a player in no gang answers the framework none gang')
    local okG, whyG = bridge:GetGang(2)
    check(okG == false and whyG == 'not_loaded', fw .. ': GetGang for a player not loaded: not_loaded: ' .. tostring(whyG))
    okG, whyG = bridge:GetGang(0)
    check(okG == false and whyG == 'bad_source', fw .. ': GetGang source 0: bad_source: ' .. tostring(whyG))
    okG, whyG = bridge:GetGang('1')
    check(okG == false and whyG == 'bad_source', fw .. ': GetGang string source: bad_source: ' .. tostring(whyG))
    W.players[1].gang = nil
    okG, whyG = bridge:GetGang(1)
    check(okG == false and whyG == 'not_loaded', fw .. ': a player with no gang table: not_loaded: ' .. tostring(whyG))
    boot({ fw })
    local real = CisBridgeFrameworks[fw].server.gang
    CisBridgeFrameworks[fw].server.gang = function() error('boom') end
    okG, whyG = bridge:GetGang(1)
    CisBridgeFrameworks[fw].server.gang = real
    check(okG == false and whyG == 'error', fw .. ': a raising adapter answers error: ' .. tostring(whyG))
end
-- A gang whose grade is a bare number (no grade table) still reads.
boot({ 'qbox' })
W.players[1].gang = nil
local rawQbox = W.declared.qbx_core.GetPlayer
W.declared.qbx_core.GetPlayer = function(src)
    local p = rawQbox(src)
    p.PlayerData.gang = { name = 'lost', label = 'The Lost', isboss = false, grade = { name = 'prospect', level = 1 } }
    return p
end
local gl = bridge:GetGang(1)
check(type(gl) == 'table' and gl.name == 'lost' and gl.grade == 1, 'qbox: the grade level is the number, not the grade table')
W.declared.qbx_core.GetPlayer = rawQbox

for _, fw in ipairs({ 'esx', 'cis_core' }) do
    boot({ fw })
    local okG, whyG = bridge:GetGang(1)
    check(okG == false and whyG == 'unsupported', fw .. ': GetGang answers unsupported: ' .. tostring(whyG))
    okG, whyG = bridge:GetGang(2)
    check(okG == false and whyG == 'not_loaded', fw .. ': GetGang checks the player first: ' .. tostring(whyG))
end
boot({})
do
    local okG, whyG = bridge:GetGang(1)
    check(okG == false and whyG == 'no_framework', 'no framework: GetGang answers no_framework: ' .. tostring(whyG))
end

-- ===========================================================================
--  18. GetPlayerState: one conformance case per framework
-- ===========================================================================

for _, fw in ipairs({ 'qbcore', 'qbox' }) do
    boot({ fw })
    local s = bridge:GetPlayerState(1)
    check(type(s) == 'table' and s.dead == false and s.lastStand == false and s.cuffed == false,
        fw .. ': a healthy player answers three false flags')
    check(type(s) == 'table' and keysOf(s) == 3, fw .. ': GetPlayerState answers exactly three fields')
    s = bridge:GetPlayerState(3)
    check(type(s) == 'table' and s.dead == true and s.lastStand == false and s.cuffed == true,
        fw .. ': isdead and ishandcuffed read as dead and cuffed')
    W.players[1].meta.inlaststand = true
    s = bridge:GetPlayerState(1)
    check(type(s) == 'table' and s.lastStand == true and s.dead == false and s.cuffed == false,
        fw .. ': inlaststand reads as lastStand alone')
    W.players[1].meta = {}
    s = bridge:GetPlayerState(1)
    check(type(s) == 'table' and s.dead == false and s.lastStand == false and s.cuffed == false,
        fw .. ': a flag the framework never set is false, not nil')
    W.players[1].meta = nil
    local okS, whyS = bridge:GetPlayerState(1)
    check(okS == false and whyS == 'not_loaded', fw .. ': no metadata table: not_loaded: ' .. tostring(whyS))
    boot({ fw })
    okS, whyS = bridge:GetPlayerState(2)
    check(okS == false and whyS == 'not_loaded', fw .. ': GetPlayerState for a player not loaded: not_loaded: ' .. tostring(whyS))
    okS, whyS = bridge:GetPlayerState(0)
    check(okS == false and whyS == 'bad_source', fw .. ': GetPlayerState source 0: bad_source: ' .. tostring(whyS))
    local real = CisBridgeFrameworks[fw].server.state
    CisBridgeFrameworks[fw].server.state = function() error('boom') end
    okS, whyS = bridge:GetPlayerState(1)
    CisBridgeFrameworks[fw].server.state = real
    check(okS == false and whyS == 'error', fw .. ': a raising adapter answers error: ' .. tostring(whyS))
end
for _, fw in ipairs({ 'esx', 'cis_core' }) do
    boot({ fw })
    local okS, whyS = bridge:GetPlayerState(1)
    check(okS == false and whyS == 'unsupported', fw .. ': GetPlayerState answers unsupported: ' .. tostring(whyS))
    okS, whyS = bridge:GetPlayerState(2)
    check(okS == false and whyS == 'not_loaded', fw .. ': GetPlayerState checks the player first: ' .. tostring(whyS))
end
boot({})
do
    local okS, whyS = bridge:GetPlayerState(1)
    check(okS == false and whyS == 'no_framework', 'no framework: GetPlayerState answers no_framework: ' .. tostring(whyS))
end

-- ===========================================================================
--  19. UseItem: one conformance case per framework
-- ===========================================================================

-- ESX calls its callback as (source, itemName, ...); QBCore and Qbox as
-- (source, itemTable).
for _, fw in ipairs({ 'esx', 'qbcore', 'qbox' }) do
    local function t(msg) return fw .. ': ' .. msg end
    boot({ fw })
    check(bridge:UseItem(1, 'bread') == true, t('a usable item answers true'))
    check(#W.used == 1 and W.used[1].src == 1, t('the callback ran once for that player'))
    if fw == 'esx' then
        check(W.used[1].item == 'bread', t('the callback got the item name'))
    else
        check(type(W.used[1].item) == 'table' and W.used[1].item.name == 'bread', t('the callback got an item table named for the item'))
    end

    W.used = {}
    check(bridge:UseItem(1, 'bread', { slot = 3, info = { quality = 80 } }) == true, t('a usable item with data answers true'))
    if fw == 'esx' then
        check(W.used[1].extra[1] and W.used[1].extra[1].slot == 3, t('the data follows as the extra argument'))
    else
        local it = W.used[1].item
        check(it.slot == 3 and it.info.quality == 80 and it.name == 'bread', t('the data is the item table, named for the item'))
        W.used = {}
        bridge:UseItem(1, 'bread', { name = 'water', slot = 1 })
        check(W.used[1].item.name == 'bread', t('the item argument wins over a name inside the data'))
    end

    W.used = {}
    local ok, why = bridge:UseItem(1, 'water')
    check(ok == false and why == 'not_usable' and #W.used == 0, t('an item with no usable callback: not_usable, nothing ran: ') .. tostring(why))
    ok, why = bridge:UseItem(1, 'nosuchitem')
    check(ok == false and why == 'not_usable' and #W.used == 0, t('an unknown item: not_usable: ') .. tostring(why))
    ok, why = bridge:UseItem(2, 'bread')
    check(ok == false and why == 'not_loaded' and #W.used == 0, t('a player not loaded: not_loaded: ') .. tostring(why))
    ok, why = bridge:UseItem(0, 'bread')
    check(ok == false and why == 'bad_source', t('source 0: bad_source: ') .. tostring(why))
    ok, why = bridge:UseItem('1', 'bread')
    check(ok == false and why == 'bad_source', t('a string source: bad_source: ') .. tostring(why))
    for _, bad in ipairs({ { nil, 'nil' }, { '', 'empty' }, { 5, 'a number' }, { 'a b', 'a space' }, { ('x'):rep(65), '65 chars' } }) do
        ok, why = bridge:UseItem(1, bad[1])
        check(ok == false and why == 'bad_item' and #W.used == 0, t('item ' .. bad[2] .. ': bad_item: ') .. tostring(why))
    end
    ok, why = bridge:UseItem(1, 'bread', 'text')
    check(ok == false and why == 'bad_data' and #W.used == 0, t('data that is not a table: bad_data: ') .. tostring(why))
    local deep = {}
    for _ = 1, 8 do deep = { deep } end
    ok, why = bridge:UseItem(1, 'bread', deep)
    check(ok == false and why == 'bad_data' and #W.used == 0, t('data nested 9 deep: bad_data: ') .. tostring(why))

    -- The callback raises: ESX catches it inside ESX.UseItem and answers
    -- nothing, QBCore and Qbox let it reach the bridge.
    ok, why = bridge:UseItem(1, 'burger')
    if fw == 'esx' then
        check(ok == true, t('ESX swallows a raising callback itself: ') .. tostring(why))
    else
        check(ok == false and why == 'error', t('a raising callback answers error: ') .. tostring(why))
    end

    -- The framework call itself raises.
    local adapter = CisBridgeFrameworks[fw]
    local realUse = adapter.server.useItem
    adapter.server.useItem = function() error('boom') end
    ok, why = bridge:UseItem(1, 'bread')
    adapter.server.useItem = realUse
    check(ok == false and why == 'error', t('a raising useItem answers error: ') .. tostring(why))
    local realCan = adapter.server.canUseItem
    adapter.server.canUseItem = function() error('boom') end
    ok, why = bridge:UseItem(1, 'bread')
    adapter.server.canUseItem = realCan
    check(ok == false and why == 'error', t('a raising canUseItem answers error: ') .. tostring(why))
end

-- Qbox: the registry call raises.
boot({ 'qbox' })
W.fault.raise = { ['qbx_core.CanUseItem'] = true }
do
    local ok, why = bridge:UseItem(1, 'bread')
    W.fault.raise = nil
    check(ok == false and why == 'error' and #W.used == 0, 'qbox: CanUseItem that raises answers error, nothing ran: ' .. tostring(why))
end

-- QBCore answers the entry as a bare function in older cores.
boot({ 'qbcore' })
W.usableAsFunction = true
check(bridge:UseItem(1, 'bread') == true and #W.used == 1, 'qbcore: a bare-function entry is called')
W.usableAsFunction = false
-- An entry that keeps its function under `cb`.
W.usableKey = 'cb'
check(bridge:UseItem(1, 'bread') == true and #W.used == 2, 'qbcore: an entry keeping its function under cb is called')
W.usableKey = nil
-- The entry is gone between the usable check and the call: not_usable, not error.
for _, fw in ipairs({ 'qbcore', 'qbox' }) do
    boot({ fw })
    W.usableVanishes = true
    local ok, why = bridge:UseItem(1, 'bread')
    W.usableVanishes = false
    check(ok == false and why == 'not_usable' and #W.used == 0, fw .. ': an entry gone before the call answers not_usable: ' .. tostring(why))
end
-- ESX older than GetUsableItems: the call is made and its answer taken.
-- (The adapter keeps the shared object it probed, so the field goes before detection.)
W.reset({ 'esx' })
local realUsable = W.ESX.GetUsableItems
W.ESX.GetUsableItems = nil
V1.detect()
check(bridge:UseItem(1, 'bread') == true and #W.used == 1, 'esx without GetUsableItems: the call is made')
do
    local ok, why = bridge:UseItem(1, 'water')
    check(ok == true and #W.used == 1, 'esx without GetUsableItems cannot tell not_usable: ' .. tostring(ok) .. ' ' .. tostring(why) .. ' ' .. #W.used)
end
W.ESX.GetUsableItems = realUsable

boot({ 'cis_core' })
do
    local ok, why = bridge:UseItem(1, 'bread')
    check(ok == false and why == 'not_usable' and #W.used == 0, 'cis_core has no usable-item path: not_usable: ' .. tostring(why))
end
boot({})
do
    local ok, why = bridge:UseItem(1, 'bread')
    check(ok == false and why == 'no_framework', 'no framework: UseItem answers no_framework: ' .. tostring(why))
end

-- ===========================================================================
--  20. GetSourceByCharId: one conformance case per framework
-- ===========================================================================

local function indexCalls()
    local n = 0
    for _, c in ipairs(W.calls) do
        if c.key == 'byCharId' then n = n + 1 end
    end
    return n
end

for _, fw in ipairs({ 'esx', 'qbcore', 'qbox', 'cis_core' }) do
    boot({ fw })
    local src, why = bridge:GetSourceByCharId('CID001')
    check(src == 1, fw .. ': a loaded character answers its server id: ' .. tostring(src) .. ' ' .. tostring(why))
    src = bridge:GetSourceByCharId('CID003')
    check(src == 3, fw .. ': a second loaded character answers its own server id: ' .. tostring(src))
    local ok
    ok, why = bridge:GetSourceByCharId('CID002')
    check(ok == false and why == 'offline', fw .. ': a connected character not loaded: offline: ' .. tostring(why))
    ok, why = bridge:GetSourceByCharId('CID999')
    check(ok == false and why == 'offline', fw .. ': an unknown character: offline: ' .. tostring(why))
    -- The framework index still names server id 1 for a character that
    -- switched away: the bridge reads the player back and refuses.
    W.staleIndex = { CID777 = 1 }
    ok, why = bridge:GetSourceByCharId('CID777')
    check(ok == false and why == 'offline', fw .. ': a stale index entry is read back: offline: ' .. tostring(why))
    W.staleIndex = nil
    for _, bad in ipairs({ 1, '', ('x'):rep(65), 'CID' .. string.char(0) .. '1', 'CID' .. string.char(10) .. '001' }) do
        ok, why = bridge:GetSourceByCharId(bad)
        check(ok == false and why == 'bad_id', fw .. ': bad id ' .. ('%q'):format(tostring(bad)) .. ': bad_id: ' .. tostring(why))
    end
    ok, why = bridge:GetSourceByCharId(nil)
    check(ok == false and why == 'bad_id', fw .. ': nil id: bad_id: ' .. tostring(why))
end

-- Qbox, QBCore and ESX answer from the framework's own index, never a scan.
for _, fw in ipairs({ 'esx', 'qbcore', 'qbox' }) do
    boot({ fw })
    W.calls = {}
    bridge:GetSourceByCharId('CID001')
    check(indexCalls() == 1, fw .. ': one framework index lookup per call: ' .. indexCalls())
end

-- An adapter whose lookup raises answers error, not a server id.
boot({ 'qbox' })
do
    local real = CisBridgeFrameworks.qbox.server.sourceOf
    CisBridgeFrameworks.qbox.server.sourceOf = function() error('boom') end
    local ok, why = bridge:GetSourceByCharId('CID001')
    CisBridgeFrameworks.qbox.server.sourceOf = real
    check(ok == false and why == 'error', 'a raising sourceOf answers error: ' .. tostring(why))
end

boot({})
do
    local ok, why = bridge:GetSourceByCharId('CID001')
    check(ok == false and why == 'no_framework', 'no framework: GetSourceByCharId answers no_framework: ' .. tostring(why))
end

-- ===========================================================================

_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(v1): ' .. failures[i] .. '\n')
end
io.write(('v1 passed=%d failed=%d\n'):format(passed, failed))
