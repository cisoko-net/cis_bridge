-- The v1 product API, client half (client/v1.lua, docs/V1.md).
--
-- The client only reads and displays: the local player's data, a notify, and
-- interaction targets. The targets are where the frameworks differ most, so
-- each canonical option is checked as the target resource receives it, and
-- its onSelect is called the way that resource calls it.

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
W.server = false
W.install()

for _, f in ipairs({
    'adapters/framework/common.lua',
    'adapters/framework/esx.lua',
    'adapters/framework/qbcore.lua',
    'adapters/framework/qbox.lua',
    'adapters/framework/cis_core.lua',
    'adapters/target/ox.lua',
    'adapters/target/qb.lua',
    'adapters/billing/esx_billing.lua',
    'adapters/appearance/common.lua',
    'adapters/appearance/illenium.lua',
    'adapters/appearance/fivem_appearance.lua',
    'adapters/appearance/qb_clothing.lua',
    'adapters/appearance/skinchanger.lua',
    'client/v1.lua',
}) do
    dofile(f)
end

local bridge = exports.cis_bridge

local function boot(started)
    W.reset(started)
    W.fire('onResourceStart', nil, 'test')
end

-- ===========================================================================
--  1. Surface and events
-- ===========================================================================

local EXPORT_NAMES = { 'GetPlayerData', 'IsLoaded', 'Notify', 'AddTargetZone', 'AddTargetEntity', 'RemoveTarget',
    'GetAppearanceComponent', 'ApplyClothing', 'HasBilling', 'GetBills', 'PayBill' }
for _, name in ipairs(EXPORT_NAMES) do
    check(type(W.declared.cis_bridge[name]) == 'function', 'client export registered: ' .. name)
end
local count = 0
for _ in pairs(W.declared.cis_bridge) do count = count + 1 end
check(count == #EXPORT_NAMES, ('exactly %d client exports, got %d'):format(#EXPORT_NAMES, count))

-- Client framework events come from the server: without RegisterNetEvent the
-- resource never receives them.
for _, event in ipairs({ 'esx:playerLoaded', 'esx:setJob', 'QBCore:Client:OnPlayerLoaded', 'QBCore:Client:OnJobUpdate' }) do
    check(W.netEvents[event] == true, 'net event registered: ' .. event)
end

-- ===========================================================================
--  2. Player data and notify per framework
-- ===========================================================================

for _, fw in ipairs({ 'esx', 'qbcore', 'qbox' }) do
    boot({ fw })
    local d = bridge:GetPlayerData()
    check(type(d) == 'table' and d.id == 'CID001', fw .. ': GetPlayerData id')
    check(type(d) == 'table' and type(d.job) == 'table' and d.job.name == 'unemployed', fw .. ': GetPlayerData job')
    check(bridge:IsLoaded() == true, fw .. ': IsLoaded')
    W.client.loaded = false
    local ok, why = bridge:GetPlayerData()
    check(ok == false and why == 'not_loaded', fw .. ': not loaded: ' .. tostring(why))
    check(bridge:IsLoaded() == false, fw .. ': IsLoaded false')
    W.client.loaded = true

    check(bridge:Notify('hello', 'success') == true, fw .. ': Notify')
    ok, why = bridge:Notify('')
    check(ok == false and why == 'bad_message', fw .. ': Notify empty')
    ok, why = bridge:Notify('x', 'loud')
    check(ok == false and why == 'bad_message', fw .. ': Notify unknown kind')

    -- The local job event, once, normalised.
    W.fired = {}
    local loadedEvent = fw == 'esx' and 'esx:playerLoaded' or 'QBCore:Client:OnPlayerLoaded'
    local jobEvent = fw == 'esx' and 'esx:setJob' or 'QBCore:Client:OnJobUpdate'
    local job = fw == 'esx' and { name = 'police', label = 'Police', grade = 1, grade_name = 'officer' }
        or { name = 'police', label = 'Police', grade = { level = 1, name = 'officer' }, isboss = false }
    W.fire(loadedEvent, nil, {})
    W.fire(jobEvent, nil, job)
    -- The loaded relay runs in a thread that waits for the data (section 4).
    W.runThreads(200)
    check(#W.firedNamed('cis_bridge:playerLoaded') == 1, fw .. ': local playerLoaded')
    local jc = W.firedNamed('cis_bridge:jobChanged')
    check(#jc == 1 and type(jc[1][1]) == 'table' and jc[1][1].name == 'police' and jc[1][1].grade == 1,
        fw .. ': local jobChanged normalised')
end

boot({ 'esx' })
bridge:Notify('hi', 'error')
local shown = W.firedNamed('esx:showNotification')
check(#shown == 1 and shown[1][1] == 'hi' and shown[1][2] == 'error', 'ESX notify fires esx:showNotification')
boot({ 'qbcore' })
bridge:Notify('hi', 'warning')
local qbn = W.callsTo('qb-core.Functions.Notify')
check(#qbn == 1 and qbn[1][1] == 'hi', 'QBCore notify reaches Functions.Notify')

-- Only the active framework's events count.
boot({ 'esx' })
W.fired = {}
W.fire('QBCore:Client:OnJobUpdate', nil, { name = 'police', grade = { level = 1 } })
check(#W.firedNamed('cis_bridge:jobChanged') == 0, 'another framework\'s client event is ignored')

boot({ 'cis_core' })
local ok, why = bridge:GetPlayerData()
check(ok == false and why == 'not_loaded', 'cis_core has no client data yet: ' .. tostring(why))
ok, why = bridge:Notify('hi')
check(ok == false and why == 'unsupported', 'cis_core client notify is unsupported')

boot({})
ok, why = bridge:GetPlayerData()
check(ok == false and why == 'no_framework', 'no framework client side')

-- ===========================================================================
--  3. Targets
-- ===========================================================================

local selected
local function options()
    return {
        { label = 'Open shop', icon = 'fa-solid fa-cart', distance = 2.5, onSelect = function(e) selected = e end },
        { label = 'Rob', distance = 1.5, onSelect = function() end, canInteract = function() return 'yes' end },
    }
end
local here = { x = 1.0, y = 2.0, z = 30.0 }

-- ox_target
boot({ 'ox_target' })
W.invoker = 'cis_shop'
check(bridge:AddTargetZone({ name = 'shop', kind = 'box', coords = here, size = { x = 2, y = 2, z = 2 },
    options = options() }) == true, 'ox: box zone')
local zid, zone = next(W.targets.zones)
-- The name the target resource sees is scoped to the caller (section 4).
check(zone and zone.name == 'cis_shop:shop' and zone.size.z == 2 and zone.rotation == 0, 'ox: box spec')
check(zone and zone.options[1].name == 'cis_shop:shop:1' and zone.options[1].label == 'Open shop',
    'ox: option name and label')
zone.options[1].onSelect({ entity = 77 })
check(selected == 77, 'ox: onSelect gets data.entity')
check(zone.options[2].canInteract(5) == false, 'ox: canInteract is true only for true')
ok, why = bridge:AddTargetZone({ name = 'shop', kind = 'sphere', coords = here, size = 1.5, options = options() })
check(ok == false and why == 'exists', 'ox: a second target with the name exists')
check(bridge:AddTargetZone({ name = 'till', kind = 'sphere', coords = here, size = 1.5, options = options() }) == true,
    'ox: sphere zone')
local sphere
for _, z in pairs(W.targets.zones) do if z.name == 'cis_shop:till' then sphere = z end end
check(sphere and sphere.radius == 1.5, 'ox: sphere radius')
check(bridge:AddTargetEntity({ name = 'clerk', entity = 501, options = options() }) == true, 'ox: entity')
check(W.targets.entities[501] and #W.targets.entities[501] == 2, 'ox: entity options')
check(bridge:RemoveTarget('shop') == true and W.targets.zones[zid] == nil, 'ox: remove zone by its id')
check(bridge:RemoveTarget('clerk') == true and W.targets.entities[501] == nil, 'ox: remove entity')
ok, why = bridge:RemoveTarget('shop')
check(ok == false and why == 'unknown_target', 'ox: removed twice is unknown')

-- Stopping the owner takes its targets with it; another owner's stay.
W.invoker = 'cis_garage'
bridge:AddTargetZone({ name = 'garage', kind = 'sphere', coords = here, size = 2, options = options() })
W.invoker = nil
W.fire('onResourceStop', nil, 'cis_shop')
local names = {}
for _, z in pairs(W.targets.zones) do names[z.name] = true end
check(not names['cis_shop:till'] and names['cis_garage:garage'], 'ox: cis_shop stop removed till and kept garage')

-- qb-target. With no invoker the caller is cis_bridge itself.
boot({ 'qb-target' })
check(bridge:AddTargetZone({ name = 'shop', kind = 'box', coords = here, size = { x = 4, y = 3, z = 2 },
    options = options() }) == true, 'qb: box zone')
zone = W.targets.zones['cis_bridge:shop']
-- PolyZone BoxZone puts length on Y and width on X (BoxZone.lua _calculatePoints,
-- qbcore-framework/PolyZone@0f90030): a 4 x 3 box is length 3, width 4.
check(zone and zone.length == 3 and zone.width == 4 and zone.opts.minZ == 29 and zone.opts.maxZ == 31, 'qb: box geometry, length on Y')
check(zone and zone.options.distance == 2.5, 'qb: distance is the widest option')
selected = nil
zone.options.options[1].action(88)
check(selected == 88, 'qb: action calls onSelect with the entity')
check(bridge:AddTargetZone({ name = 'till', kind = 'sphere', coords = here, size = 1.5, options = options() }) == true
    and W.targets.zones['cis_bridge:till'].radius == 1.5 and W.targets.zones['cis_bridge:till'].opts.useZ == true,
    'qb: circle zone')
check(bridge:AddTargetEntity({ name = 'clerk', entity = 9, options = options() }) == true
    and W.targets.entities[9] ~= nil, 'qb: entity')
check(bridge:RemoveTarget('shop') == true and W.targets.zones['cis_bridge:shop'] == nil, 'qb: remove zone by name')
check(bridge:RemoveTarget('clerk') == true and W.targets.entities[9] == nil, 'qb: remove entity')
-- qb-target keys options by label, so a second option with the same label
-- would replace the first. The contract refuses the pair on every backend.
do
    local twice = options()
    twice[2].label = twice[1].label
    local okE, whyE = bridge:AddTargetEntity({ name = 'twin', entity = 9, options = twice })
    check(okE == false and whyE == 'bad_target' and W.targets.entities[9] == nil,
        'qb: two options with one label are bad_target')
    local okZ, whyZ = bridge:AddTargetZone({ name = 'twin', kind = 'sphere', coords = here, size = 1, options = twice })
    check(okZ == false and whyZ == 'bad_target' and W.targets.zones['cis_bridge:twin'] == nil,
        'qb: a zone with two options of one label is bad_target')
end

-- ox before qb, and the convar.
boot({ 'ox_target', 'qb-target' })
bridge:AddTargetZone({ name = 'a', kind = 'sphere', coords = here, size = 1, options = options() })
check(W.targets.zones['cis_bridge:a'] == nil and next(W.targets.zones) ~= nil, 'ox_target before qb-target')
W.reset({ 'ox_target', 'qb-target' })
W.convars['cis_bridge:target'] = 'qb-target'
W.fire('onResourceStart', nil, 'test')
bridge:AddTargetZone({ name = 'b', kind = 'sphere', coords = here, size = 1, options = options() })
check(W.targets.zones['cis_bridge:b'] ~= nil, 'the target convar wins')

-- A mistyped forced target or billing name is said plainly in F8.
local function saidF8(text)
    for _, line in ipairs(W.prints) do
        if line:find(text, 1, true) then return true end
    end
    return false
end
W.reset({ 'ox_target', 'qb-target' })
W.convars['cis_bridge:target'] = 'oxtarget'
W.fire('onResourceStart', nil, 'test')
bridge:AddTargetZone({ name = 'c', kind = 'sphere', coords = here, size = 1, options = options() })
check(next(W.targets.zones) == nil, 'a mistyped target convar adds no zone')
check(saidF8("cis_bridge:target is 'oxtarget', which is not an adapter. Use one of: ox_target, qb-target"),
    'and F8 names the targets it takes')
do
    local oxT2 = CisBridgeTargets.ox_target
    local realProbe = oxT2.probe
    oxT2.probe = function() return false end
    W.reset({ 'ox_target' })
    W.convars['cis_bridge:target'] = 'ox_target'
    W.fire('onResourceStart', nil, 'test')
    local a, b = bridge:AddTargetZone({ name = 'p', kind = 'sphere', coords = here, size = 1, options = options() })
    oxT2.probe = realProbe
    check(a == false and b == 'no_target', 'a forced target whose probe fails picks nothing')
    check(saidF8("cis_bridge:target is 'ox_target' and ox_target is started, but it does not answer the ox_target probe"),
        'and F8 says the probe failed')
end
W.reset({ 'esx', 'esx_billing' })
W.convars['cis_bridge:billing'] = 'okokBilling'
W.fire('onResourceStart', nil, 'test')
bridge:HasBilling()
check(saidF8("cis_bridge:billing is 'okokBilling', which is not an adapter. Use one of: esx_billing"),
    'a billing name we have no adapter for is said plainly')
W.reset({ 'esx' })
W.convars['cis_bridge:framework'] = 'es_extended'
W.fire('onResourceStart', nil, 'test')
bridge:HasBilling()
check(saidF8("cis_bridge:framework is 'es_extended', which is not an adapter. Use one of: cis_core, esx, qbcore, qbox"),
    'the client checks the framework convar too')

-- A renamed target or framework resource, named by `cis_bridge:<slot>_resource`.
local function callsUnder(resource)
    local n = 0
    for _, c in ipairs(W.calls) do
        if c.key:sub(1, #resource + 1) == resource .. '.' then n = n + 1 end
    end
    return n
end
W.reset({ 'qb-target' })
W.declared['my-target'] = W.declared.ox_target
W.state['my-target'] = 'started'
W.convars['cis_bridge:target'] = 'ox_target'
W.convars['cis_bridge:target_resource'] = 'my-target'
W.fire('onResourceStart', nil, 'test')
ok = bridge:AddTargetZone({ name = 'd', kind = 'sphere', coords = here, size = 1, options = options() })
check(ok == true and callsUnder('my-target') > 0 and callsUnder('ox_target') == 0,
    'an ox_target renamed to my-target gets the zone')
check(bridge:RemoveTarget('d') == true, 'and removes it there')
W.reset({ 'ox_target', 'qb-target' })
W.convars['cis_bridge:target_resource'] = 'my-target'
W.fire('onResourceStart', nil, 'test')
bridge:AddTargetZone({ name = 'e', kind = 'sphere', coords = here, size = 1, options = options() })
check(next(W.targets.zones) == nil, 'a target override without the forced name adds no zone')
check(saidF8("cis_bridge:target_resource is 'my-target', but cis_bridge:target is not set. Set both"),
    'and F8 says to set both')
check(saidF8('Set both: setr cis_bridge:target <adapter>, where <adapter> is one of: ox_target, qb-target'),
    'and it lists the target adapters')
W.reset({ 'esx_billing' })
W.declared['my-esx'] = W.declared.es_extended
W.state['my-esx'] = 'started'
W.convars['cis_bridge:framework'] = 'esx'
W.convars['cis_bridge:framework_resource'] = 'my-esx'
W.fire('onResourceStart', nil, 'test')
check(bridge:HasBilling() == true and callsUnder('my-esx') > 0, 'esx_billing finds an ESX renamed to my-esx')
W.reset({ 'ox_target' })
W.fire('onResourceStart', nil, 'test')
ok = bridge:AddTargetZone({ name = 'f', kind = 'sphere', coords = here, size = 1, options = options() })
check(ok == true and callsUnder('ox_target') > 0, 'with the convars gone ox_target is called by its own name')

-- Bad specs.
boot({ 'ox_target' })
for i, spec in ipairs({
    'shop',
    { kind = 'box', coords = here, size = { x = 1, y = 1, z = 1 }, options = options() },
    { name = ('n'):rep(65), kind = 'sphere', coords = here, size = 1, options = options() },
    { name = 'x', kind = 'poly', coords = here, size = 1, options = options() },
    { name = 'x', kind = 'sphere', coords = { x = 1, y = 2 }, size = 1, options = options() },
    { name = 'x', kind = 'sphere', coords = here, size = -1, options = options() },
    { name = 'x', kind = 'box', coords = here, size = 2, options = options() },
    { name = 'x', kind = 'sphere', coords = here, size = 1, options = {} },
    { name = 'x', kind = 'sphere', coords = here, size = 1, options = { { label = 'no select' } } },
    { name = 'x', kind = 'sphere', coords = here, size = 1, options = { { label = '', onSelect = print } } },
}) do
    ok, why = bridge:AddTargetZone(spec)
    check(ok == false and why == 'bad_target', ('bad zone spec %d: %s'):format(i, tostring(why)))
end
ok, why = bridge:AddTargetEntity({ name = 'x', entity = 0, options = options() })
check(ok == false and why == 'bad_target', 'entity 0 is bad')
ok, why = bridge:RemoveTarget(5)
check(ok == false and why == 'bad_target', 'RemoveTarget wants a name')
check(next(W.targets.zones) == nil, 'no bad spec reached ox_target')

boot({})
ok, why = bridge:AddTargetZone({ name = 'x', kind = 'sphere', coords = here, size = 1, options = options() })
check(ok == false and why == 'no_target', 'no target resource')

-- A target resource that raises answers error, not a throw.
boot({ 'ox_target' })
W.fault.raise = { ['ox_target.addSphereZone'] = true }
ok, why = bridge:AddTargetZone({ name = 'x', kind = 'sphere', coords = here, size = 1, options = options() })
check(ok == false and why == 'error', 'raising target answers error: ' .. tostring(why))
W.fault.raise = nil
check(bridge:AddTargetZone({ name = 'x', kind = 'sphere', coords = here, size = 1, options = options() }) == true,
    'a failed add leaves no record behind')

-- A target adapter that answers false is a failure with its reason, not a
-- stored record and a true.
boot({ 'ox_target' })
local oxT = CisBridgeTargets.ox_target
local realZone, realEntity = oxT.addZone, oxT.addEntity
oxT.addZone = function() return false, 'unsupported' end
oxT.addEntity = function() return false end
ok, why = bridge:AddTargetZone({ name = 'z', kind = 'sphere', coords = here, size = 1, options = options() })
check(ok == false and why == 'unsupported', 'a false zone add keeps its reason: ' .. tostring(why))
ok, why = bridge:AddTargetEntity({ name = 'e', entity = 501, options = options() })
check(ok == false and why == 'refused', 'a false entity add with no reason answers refused: ' .. tostring(why))
oxT.addZone, oxT.addEntity = realZone, realEntity
check(bridge:AddTargetZone({ name = 'z', kind = 'sphere', coords = here, size = 1, options = options() }) == true
    and bridge:AddTargetEntity({ name = 'e', entity = 501, options = options() }) == true,
    'a refused add leaves no record behind')

-- ===========================================================================
--  4. Review fixes: the loaded relay, reasons, ownership, stops, distance,
--     and the bounds on what reaches a target resource
-- ===========================================================================

local function printedLike(pattern)
    for _, line in ipairs(W.prints) do
        if line:find(pattern, 1, true) then return true end
    end
    return false
end

-- ESX fires esx:playerLoaded, then waits for the ped before ESX.PlayerLoaded
-- is true. The relay waits with it instead of firing into a 'not_loaded'.
boot({ 'esx' })
W.client.loaded = false
W.fire('esx:playerLoaded', nil, {})
W.runThreads(300)
check(#W.firedNamed('cis_bridge:playerLoaded') == 0, 'esx: playerLoaded waits while the player data is not there')
W.client.loaded = true
W.runThreads(150)
check(#W.firedNamed('cis_bridge:playerLoaded') == 1, 'esx: playerLoaded fires once the data answers')
check(type((bridge:GetPlayerData())) == 'table', 'esx: and GetPlayerData answers by then')
W.runThreads(20000)
check(#W.firedNamed('cis_bridge:playerLoaded') == 1, 'esx: one loaded event relays once')

-- Data that never comes: the relay gives up at 10 s, fires, and says so.
boot({ 'esx' })
W.client.loaded = false
W.fire('esx:playerLoaded', nil, {})
W.runThreads(9800)
check(#W.firedNamed('cis_bridge:playerLoaded') == 0, 'esx: no relay before the 10 s deadline')
W.runThreads(400)
check(#W.firedNamed('cis_bridge:playerLoaded') == 1, 'esx: the relay fires anyway at the deadline')
check(printedLike('did not answer within 10000 ms'), 'esx: and warns in F8 that the data never came')
W.runThreads(20000)
check(#W.firedNamed('cis_bridge:playerLoaded') == 1, 'esx: the timed-out relay fires once')

-- Two loaded events (a character switch) before the data: one relay.
boot({ 'esx' })
W.client.loaded = false
W.fire('esx:playerLoaded', nil, {})
W.runThreads(200)
W.fire('esx:playerLoaded', nil, {})
W.client.loaded = true
W.runThreads(500)
check(#W.firedNamed('cis_bridge:playerLoaded') == 1, 'esx: a second loaded event replaces the first wait')

-- A framework that raises answers 'error', not 'not_loaded' or 'unsupported'.
boot({ 'esx' })
local esxClient = CisBridgeFrameworks.esx.client
local realData, realNotify = esxClient.data, esxClient.notify
esxClient.data = function() error('es_extended went away') end
esxClient.notify = function() error('es_extended went away') end
ok, why = bridge:GetPlayerData()
check(ok == false and why == 'error', 'a raising GetPlayerData answers error: ' .. tostring(why))
ok, why = bridge:Notify('hello')
check(ok == false and why == 'error', 'a raising Notify answers error: ' .. tostring(why))
esxClient.notify = function() return nil end
ok, why = bridge:Notify('hello')
check(ok == false and why == 'unsupported', 'a notify that does not answer true is still unsupported')
esxClient.data, esxClient.notify = realData, realNotify

-- Detect drops every adapter's cached core object, not only the active one.
local resets = {}
local realResets = {}
for name, a in pairs(CisBridgeFrameworks) do
    realResets[name] = a.reset
    a.reset = function(...)
        resets[name] = (resets[name] or 0) + 1
        if realResets[name] then return realResets[name](...) end
    end
end
boot({ 'esx' })
bridge:GetPlayerData()
check((resets.esx or 0) >= 1 and (resets.qbcore or 0) >= 1 and (resets.qbox or 0) >= 1,
    'detect resets every framework adapter')
CisBridgeFrameworks.qbcore.reset = function() error('reset raised') end
boot({ 'esx' })
check(type((bridge:GetPlayerData())) == 'table', 'a reset that raises does not stop detection')
for name, a in pairs(CisBridgeFrameworks) do a.reset = realResets[name] end

-- Two products may use one name; neither can remove the other's.
local function zoneNamed(name)
    for id, z in pairs(W.targets.zones) do
        if z.name == name or id == name then return z, id end
    end
end
boot({ 'ox_target' })
W.invoker = 'cis_one'
check(bridge:AddTargetZone({ name = 'counter', kind = 'sphere', coords = here, size = 1, options = options() }) == true,
    'owner one adds counter')
W.invoker = 'cis_two'
check(bridge:AddTargetZone({ name = 'counter', kind = 'sphere', coords = here, size = 1, options = options() }) == true,
    'owner two adds a counter of its own')
W.invoker = 'cis_three'
ok, why = bridge:RemoveTarget('counter')
check(ok == false and why == 'unknown_target', 'a third resource cannot remove either counter')
W.invoker = 'cis_one'
check(bridge:RemoveTarget('counter') == true, 'owner one removes its own counter')
check(zoneNamed('cis_one:counter') == nil and zoneNamed('cis_two:counter') ~= nil,
    "and owner two's counter stays")
W.invoker = nil

-- A target resource that stops took its zones with it: the records go, and
-- no remove reaches the restarted resource, whose ids now belong to others.
W.invoker = 'cis_stall'
bridge:AddTargetZone({ name = 'stall', kind = 'sphere', coords = here, size = 1, options = options() })
W.invoker = nil
W.calls = {}
W.state.ox_target = 'stopped'
W.fire('onResourceStop', nil, 'ox_target')
W.state.ox_target = 'started'
W.fire('onResourceStart', nil, 'ox_target')
W.invoker = 'cis_stall'
ok, why = bridge:RemoveTarget('stall')
check(ok == false and why == 'unknown_target', "the stopped resource's record is gone: " .. tostring(why))
check(#W.callsTo('ox_target.removeZone') == 0, 'a stopped target resource is never asked to remove its zones')
check(bridge:AddTargetZone({ name = 'stall', kind = 'sphere', coords = here, size = 1, options = options() }) == true,
    'and the product can add it again after the restart')
W.fire('onResourceStop', nil, 'cis_stall')
W.invoker = nil

-- cis_bridge stopping removes everything it added, whoever asked.
boot({ 'qb-target' })
W.invoker = 'cis_a'
bridge:AddTargetZone({ name = 'z', kind = 'sphere', coords = here, size = 1, options = options() })
W.invoker = 'cis_b'
bridge:AddTargetEntity({ name = 'e', entity = 601, options = options() })
W.invoker = nil
check(W.targets.zones['cis_a:z'] ~= nil and W.targets.entities[601] ~= nil, 'two owners hold qb targets')
W.fire('onResourceStop', nil, 'cis_bridge')
check(W.targets.zones['cis_a:z'] == nil and W.targets.entities[601] == nil,
    'cis_bridge stopping removes every target it added')
W.invoker = 'cis_a'
check(bridge:AddTargetZone({ name = 'z', kind = 'sphere', coords = here, size = 1, options = options() }) == true,
    'and holds no stale record afterwards')
W.invoker = nil

-- One default distance, on both targets; qb has no 2.0 floor.
local function plain() return { { label = 'Use', onSelect = function() end } } end
boot({ 'ox_target' })
W.invoker = 'cis_dist'
bridge:AddTargetZone({ name = 'd', kind = 'sphere', coords = here, size = 1, options = plain() })
local dz = zoneNamed('cis_dist:d')
check(dz and dz.options[1].distance == 2.0, 'ox: an option with no distance gets the 2.0 m default')
boot({ 'qb-target' })
W.invoker = 'cis_dist'
bridge:AddTargetZone({ name = 'd2', kind = 'sphere', coords = here, size = 1, options = plain() })
dz = W.targets.zones['cis_dist:d2']
check(dz and dz.options.distance == 2.0 and dz.options.options[1].distance == 2.0,
    'qb: an option with no distance gets the same 2.0 m default')
bridge:AddTargetZone({ name = 'near', kind = 'sphere', coords = here, size = 1, options = {
    { label = 'A', distance = 1.0, onSelect = function() end },
    { label = 'B', distance = 1.5, onSelect = function() end },
} })
dz = W.targets.zones['cis_dist:near']
check(dz and dz.options.distance == 1.5, 'qb: the zone reach is the widest option, with no 2.0 floor')
check(dz and dz.options.options[1].distance == 1.0 and dz.options.options[2].distance == 1.5,
    'qb: each option keeps its own distance')
W.invoker = nil

-- What reaches a target resource is bounded and finite.
boot({ 'ox_target' })
W.invoker = 'cis_bounds'
local nan, inf = 0 / 0, math.huge
local function opt(o) o.label = o.label or 'Use'; return { o } end
for i, spec in ipairs({
    { name = 'v', kind = 'sphere', coords = here, size = 1, options = opt({ onSelect = 'open' }) },
    { name = 'v', kind = 'sphere', coords = here, size = 1, options = opt({ onSelect = 42 }) },
    { name = 'v', kind = 'sphere', coords = here, size = 1, options = opt({ onSelect = print, canInteract = 'yes' }) },
    { name = 'v', kind = 'sphere', coords = here, size = 1, options = opt({ onSelect = print, distance = nan }) },
    { name = 'v', kind = 'sphere', coords = here, size = 1, options = opt({ onSelect = print, distance = 0 }) },
    { name = 'v', kind = 'sphere', coords = here, size = 1, options = opt({ onSelect = print, distance = 51 }) },
    { name = 'v', kind = 'sphere', coords = { x = nan, y = 0, z = 0 }, size = 1, options = options() },
    { name = 'v', kind = 'sphere', coords = { x = 0, y = inf, z = 0 }, size = 1, options = options() },
    { name = 'v', kind = 'sphere', coords = { x = 0, y = 0, z = 1e5 }, size = 1, options = options() },
    { name = 'v', kind = 'sphere', coords = here, size = nan, options = options() },
    { name = 'v', kind = 'sphere', coords = here, size = inf, options = options() },
    { name = 'v', kind = 'sphere', coords = here, size = 5000, options = options() },
    { name = 'v', kind = 'box', coords = here, size = { x = 1, y = nan, z = 1 }, options = options() },
    { name = 'v', kind = 'box', coords = here, size = { x = 1, y = 1, z = 0 }, options = options() },
    { name = 'v', kind = 'box', coords = here, size = { x = 2000, y = 1, z = 1 }, options = options() },
    { name = 'v', kind = 'box', coords = here, size = { x = 1, y = 1, z = 1 }, rotation = nan, options = options() },
    { name = 'v', kind = 'box', coords = here, size = { x = 1, y = 1, z = 1 }, rotation = 720, options = options() },
}) do
    ok, why = bridge:AddTargetZone(spec)
    check(ok == false and why == 'bad_target', ('bounded zone spec %d answers bad_target: %s'):format(i, tostring(why)))
end
check(next(W.targets.zones) == nil, 'no unbounded spec reached ox_target')

local seventeen = {}
for i = 1, 17 do seventeen[i] = { label = 'o' .. i, onSelect = function() end } end
ok, why = bridge:AddTargetZone({ name = 'many', kind = 'sphere', coords = here, size = 1, options = seventeen })
check(ok == false and why == 'bad_target', '17 options answer bad_target: ' .. tostring(why))
seventeen[17] = nil
check(bridge:AddTargetZone({ name = 'many', kind = 'sphere', coords = here, size = 1, options = seventeen }) == true,
    '16 options are accepted')

-- A function from another resource arrives as a table that carries
-- __cfx_functionReference (the scheduler's funcref unpack). This world copies
-- tables the way msgpack does, so a metatable set here would not reach the
-- bridge; the field is the shape that crosses.
check(bridge:AddTargetZone({ name = 'ref2', kind = 'sphere', coords = here, size = 1,
    options = { { label = 'Use', onSelect = { __cfx_functionReference = 'res:1' } } } }) == true,
    'a table carrying __cfx_functionReference is a valid onSelect')
-- A plain table is not a function: the target resource would raise when the
-- player selects the option, not when the product adds it.
ok, why = bridge:AddTargetZone({ name = 'plain', kind = 'sphere', coords = here, size = 1,
    options = { { label = 'Use', onSelect = { 'open' } } } })
check(ok == false and why == 'bad_target', 'a plain table onSelect answers bad_target: ' .. tostring(why))
ok, why = bridge:AddTargetZone({ name = 'plain', kind = 'sphere', coords = here, size = 1,
    options = { { label = 'Use', onSelect = print, canInteract = {} } } })
check(ok == false and why == 'bad_target', 'a plain table canInteract answers bad_target: ' .. tostring(why))
-- The icon goes to the target resource's UI as a class name: a string, bounded.
ok, why = bridge:AddTargetZone({ name = 'icon', kind = 'sphere', coords = here, size = 1,
    options = { { label = 'Use', icon = 42, onSelect = print } } })
check(ok == false and why == 'bad_target', 'a number icon answers bad_target: ' .. tostring(why))
ok, why = bridge:AddTargetZone({ name = 'icon', kind = 'sphere', coords = here, size = 1,
    options = { { label = 'Use', icon = ('x'):rep(65), onSelect = print } } })
check(ok == false and why == 'bad_target', 'a 65-character icon answers bad_target: ' .. tostring(why))
check(bridge:AddTargetZone({ name = 'icon', kind = 'sphere', coords = here, size = 1,
    options = { { label = 'Use', icon = 'fa-solid fa-store', onSelect = print } } }) == true,
    'a normal icon is accepted')

-- A real vector3: type() says 'vector3', never 'table' (LuaGLM).
local realType = type
local vec = { x = 1.0, y = 2.0, z = 30.0 }
local boxSize = { x = 1.0, y = 1.0, z = 1.0 }
_G.type = function(v)
    if rawequal(v, vec) or rawequal(v, boxSize) then return 'vector3' end
    return realType(v)
end
local okVec, whyVec = pcall(bridge.AddTargetZone, bridge,
    { name = 'vec', kind = 'box', coords = vec, size = boxSize, options = options() })
_G.type = realType
check(okVec == true and whyVec == true, 'a real vector3 is accepted for coords and size: ' .. tostring(whyVec))

-- An entity that does not exist is refused before it reaches the target.
W.gone[777] = true
ok, why = bridge:AddTargetEntity({ name = 'ghost', entity = 777, options = options() })
check(ok == false and why == 'bad_target', 'an entity that does not exist answers bad_target: ' .. tostring(why))
check(W.targets.entities[777] == nil, 'and never reaches ox_target')
W.invoker = nil

-- ===========================================================================

-- ===========================================================================
--  5. Appearance: slots read and dressed on the ped, the save each clothing
--     resource is sent, and the skin-loaded event
-- ===========================================================================

for _, event in ipairs({ 'cis_bridge:appearance:save', 'illenium-appearance:client:reloadSkin',
    'qb-clothing:client:loadPlayerClothing' }) do
    check(W.netEvents[event] == true, 'net event registered: ' .. event)
end

boot({ 'qbox' })
local slot = bridge:GetAppearanceComponent('hat')
check(slot.drawable == 12 and slot.texture == 2, 'hat reads prop 0')
slot = bridge:GetAppearanceComponent('glasses')
check(slot.drawable == -1 and slot.texture == 0, 'a prop that is off reads -1, texture 0, never the native -1')
slot = bridge:GetAppearanceComponent('top')
check(slot.drawable == 55 and slot.texture == 3, 'top reads component 11')
slot = bridge:GetAppearanceComponent('gloves')
check(slot.drawable == 15 and slot.texture == 0, 'gloves reads component 3')
for _, bad in ipairs({ { 'wings', 'an unknown slot' }, { nil, 'nil' }, { 11, 'a component id' } }) do
    local ok, why = bridge:GetAppearanceComponent(bad[1])
    check(ok == false and why == 'bad_slot', 'slot ' .. bad[2] .. ' answers bad_slot: ' .. tostring(why))
end

check(bridge:ApplyClothing('hat', { drawable = -1 }) == true and W.look.props[0] == nil, 'hat -1 clears prop 0')
check(bridge:ApplyClothing('glasses', { drawable = 5, texture = 1 }) == true and W.look.props[1][1] == 5
    and W.look.props[1][2] == 1, 'glasses sets prop 1')
check(bridge:ApplyClothing('top', { drawable = 3 }) == true and W.look.comps[11][1] == 3 and W.look.comps[11][2] == 0,
    'top sets component 11, texture 0 when none is given')
slot = bridge:GetAppearanceComponent('glasses')
check(slot.drawable == 5 and slot.texture == 1, 'what ApplyClothing put on reads back')
local before = W.copy(W.look)
for _, bad in ipairs({
    { 'top', { drawable = -1 }, 'a component at -1' }, { 'hat', { drawable = -2 }, 'a prop at -2' },
    { 'top', { drawable = 1.5 }, 'a fraction' }, { 'top', { drawable = 0 / 0 }, 'NaN' },
    { 'top', { drawable = 4096 }, 'a drawable over 4095' }, { 'top', { drawable = 1, texture = 256 }, 'texture 256' },
    { 'top', { drawable = 1, texture = -1 }, 'texture -1' }, { 'top', nil, 'nil data' }, { 'top', 'x', 'a string' },
}) do
    local ok, why = bridge:ApplyClothing(bad[1], bad[2])
    check(ok == false and why == 'bad_clothing', bad[3] .. ' answers bad_clothing: ' .. tostring(why))
end
check(W.look.comps[11][1] == before.comps[11][1] and W.look.props[0] == nil, 'a refused ApplyClothing changes nothing')
local okS, whyS = bridge:ApplyClothing('wings', { drawable = 1 })
check(okS == false and whyS == 'bad_slot', 'ApplyClothing on an unknown slot answers bad_slot')

local function sentNamed(name)
    local out = {}
    for _, e in ipairs(W.serverFired) do
        if e.name == name then out[#out + 1] = e.args end
    end
    return out
end
-- A net event from the server arrives on the client with source 65535.
local function askSave(name) W.fire('cis_bridge:appearance:save', 65535, name) end

-- A local TriggerEvent from another client resource (source '') is ignored.
boot({ 'qbox', 'illenium-appearance' })
W.fire('cis_bridge:appearance:save', '', 'illenium-appearance')
check(#W.serverFired == 0, 'a save fired locally, not from the server, sends nothing')

-- The server names the adapter; one that is not started here, or no adapter at
-- all, sends nothing.
boot({ 'qbox' })
askSave('illenium-appearance')
askSave('nope')
askSave(42)
check(#W.serverFired == 0, 'a save for an adapter not started, unknown, or not a name sends nothing')

-- illenium-appearance: the whole look from getPedAppearance, through its own event.
boot({ 'qbox', 'illenium-appearance' })
askSave('illenium-appearance')
local sent = sentNamed('illenium-appearance:server:saveAppearance')
check(#sent == 1 and sent[1][1].ped == 101 and sent[1][1].model == 'mp_m_freemode_01',
    'illenium: getPedAppearance of the local ped is sent to saveAppearance')

-- An illenium-appearance renamed by cis_bridge:appearance_resource still saves.
W.reset({ 'qbox' })
W.declared['my-look'] = W.declared['illenium-appearance']
W.state['my-look'] = 'started'
W.convars['cis_bridge:appearance'] = 'illenium-appearance'
W.convars['cis_bridge:appearance_resource'] = 'my-look'
W.fire('onResourceStart', nil, 'test')
askSave('illenium-appearance')
check(#sentNamed('illenium-appearance:server:saveAppearance') == 1,
    'an illenium-appearance renamed to my-look still saves')
boot({ 'qbox' })
askSave('illenium-appearance')
check(#W.serverFired == 0, 'with the convars gone the renamed resource is not used')

-- fivem-appearance has no save path: nothing sent, the reason printed.
boot({ 'qbox', 'fivem-appearance' })
askSave('fivem-appearance')
check(#W.serverFired == 0 and printedLike('unsupported'), 'fivem-appearance: nothing sent, unsupported printed')

-- qb-clothing: the save is done on the server, so a save that asks for no
-- reply sends nothing and says why.
boot({ 'qbox', 'qb-clothing' })
askSave('qb-clothing')
check(#W.serverFired == 0 and printedLike('unsupported'), 'qb-clothing: no reply asked, nothing sent, unsupported printed')
-- Asked for a reply, every clothing key is read off the ped and sent back:
-- the hair with its colour, the props off as -1. qb-clothing's own saveSkin is
-- never sent, so the stored face stays.
W.look.comps[2] = { 7, 0 }
W.look.hair = 4
W.look.comps[8] = { 15, 1 }
W.look.props[7] = { 3, 0 }
W.fire('cis_bridge:appearance:save', 65535, 'qb-clothing', true)
sent = sentNamed('cis_bridge:appearance:reply')
local clothes = sent[1] and sent[1][2] or {}
check(#sent == 1 and sent[1][1] == 'qb-clothing' and #sentNamed('qb-clothing:saveSkin') == 0,
    'qb-clothing: the look is sent back to the server, not to saveSkin')
check(clothes.hair and clothes.hair.item == 7 and clothes.hair.texture == 4, 'qb-clothing: hair and its colour from the ped')
check(clothes['t-shirt'] and clothes['t-shirt'].item == 15 and clothes['t-shirt'].texture == 1,
    'qb-clothing: t-shirt is component 8 from the ped')
check(clothes.bracelet and clothes.bracelet.item == 3, 'qb-clothing: bracelet is prop 7 from the ped')
check(clothes.hat and clothes.hat.item == 12 and clothes.hat.texture == 2, 'qb-clothing: hat from the ped')
check(clothes.torso2 and clothes.torso2.item == 55 and clothes.torso2.texture == 3, 'qb-clothing: top is torso2 from the ped')
check(clothes.glass and clothes.glass.item == -1 and clothes.glass.texture == 0, 'qb-clothing: glasses off is item -1')
check(clothes.arms and clothes.arms.item == 15 and clothes.accessory and clothes.accessory.item == 0,
    'qb-clothing: gloves is arms, chain is accessory')
check(clothes.face == nil, 'qb-clothing: the face is not read off the ped')
-- qb-clothing stopped: nothing is sent.
boot({ 'qbox' })
W.fire('cis_bridge:appearance:save', 65535, 'qb-clothing', true)
check(#W.serverFired == 0, 'qb-clothing stopped: nothing sent')

-- skinchanger + esx_skin: GetSkin with the clothing keys read off the ped.
boot({ 'esx', 'skinchanger' })
askSave('skinchanger')
sent = sentNamed('esx_skin:save')
local skin = sent[1] and sent[1][1] or {}
check(#sent == 1 and skin.face == 21 and skin.hair_1 == 4, 'skinchanger: GetSkin is sent, the face kept')
check(skin.helmet_1 == 12 and skin.helmet_2 == 2 and skin.glasses_1 == -1, 'skinchanger: props from the ped')
check(skin.torso_1 == 55 and skin.torso_2 == 3 and skin.arms == 15 and skin.pants_1 == 21 and skin.pants_2 == 1,
    'skinchanger: components from the ped')
W.serverFired = {}
W.fault.raise = { ['skinchanger.GetSkin'] = true }
askSave('skinchanger')
W.fault.raise = nil
check(#W.serverFired == 0 and printedLike('skinchanger did not save'), 'skinchanger: a raising GetSkin sends nothing')
-- esx_skin 1.16: the server asked for a reply, so only the clothing keys go
-- back to cis_bridge, and esx_skin:save is not sent.
W.serverFired = {}
W.fire('cis_bridge:appearance:save', 65535, 'skinchanger', true)
sent = sentNamed('cis_bridge:appearance:reply')
local reply = sent[1] and sent[1][2] or {}
check(#sent == 1 and sent[1][1] == 'skinchanger' and #sentNamed('esx_skin:save') == 0, 'skinchanger: reply sent, not esx_skin:save')
check(reply.helmet_1 == 12 and reply.torso_1 == 55 and reply.arms == 15 and reply.face == nil and reply.hair_1 == nil,
    'skinchanger: the reply holds the clothing keys only')

-- cis_bridge:appearanceLoaded fires once, 1.5 s after the last load signal of
-- the started clothing resource.
boot({ 'qbox', 'illenium-appearance' })
W.runThreads(5000)
W.fired = {}
W.fire('illenium-appearance:client:reloadSkin', nil)
W.runThreads(1400)
check(#W.firedNamed('cis_bridge:appearanceLoaded') == 0, 'appearanceLoaded waits for the look to settle')
W.runThreads(200)
check(#W.firedNamed('cis_bridge:appearanceLoaded') == 1, 'appearanceLoaded fires after 1.5 s')

boot({ 'esx', 'skinchanger' })
W.runThreads(5000)
W.fired = {}
W.fire('skinchanger:loadSkin', nil, {})
W.runThreads(1000)
W.fire('skinchanger:loadClothes', nil, {}, {})
W.runThreads(1000)
check(#W.firedNamed('cis_bridge:appearanceLoaded') == 0, 'a second signal restarts the wait')
W.runThreads(600)
check(#W.firedNamed('cis_bridge:appearanceLoaded') == 1, 'two signals in a row fire one appearanceLoaded')

boot({ 'qbox' })
W.runThreads(5000)
W.fired = {}
W.fire('illenium-appearance:client:reloadSkin', nil)
W.runThreads(2000)
check(#W.firedNamed('cis_bridge:appearanceLoaded') == 0, 'a clothing resource not started fires nothing')
W.fire('cis_bridge:playerLoaded', nil)
W.runThreads(2000)
check(#W.firedNamed('cis_bridge:appearanceLoaded') == 1, 'the player loaded is a load signal too')

-- ===========================================================================
--  Billing: HasBilling, GetBills, PayBill
--
--  esx_billing pays through its own client callback (server/main.lua:394-705
--  journals, locks and recovers each payment), so the bridge only relays the
--  local player's call and bounds what comes back. The reply arrives on a
--  later tick, so GetBills and PayBill wait, and must be called from a thread.
-- ===========================================================================

-- Runs fn in a thread for `ms` of fake uptime; nil while it is still waiting.
local function inThread(fn, ms)
    local out
    CreateThread(function() out = table.pack(fn()) end)
    W.runThreads(ms or 11000)
    return out
end

local function billCalls(name)
    local out = {}
    for _, c in ipairs(W.billing.calls) do
        if c.name == name then out[#out + 1] = c.args end
    end
    return out
end

-- No billing resource, or no ESX under it: hidden, nothing called.
for _, started in ipairs({ { 'qbox' }, { 'esx' }, { 'esx_billing' }, { 'qbcore', 'esx_billing' } }) do
    boot(started)
    local label = table.concat(started, '+')
    local ok, why = bridge:HasBilling()
    check(ok == false and why == 'no_billing', label .. ': HasBilling no_billing: ' .. tostring(why))
    local r = inThread(function() return bridge:GetBills() end)
    check(r and r[1] == false and r[2] == 'no_billing', label .. ': GetBills no_billing')
    r = inThread(function() return bridge:PayBill(3) end)
    check(r and r[1] == false and r[2] == 'no_billing', label .. ': PayBill no_billing')
    check(#W.billing.calls == 0, label .. ': no callback called')
end

boot({ 'esx', 'esx_billing' })
local okB, nameB = bridge:HasBilling()
check(okB == true and nameB == 'esx_billing', 'HasBilling true, esx_billing: ' .. tostring(nameB))

-- A forced billing resource that is not one of ours, or not started.
boot({ 'esx', 'esx_billing' })
W.convars['cis_bridge:billing'] = 'okokBilling'
check(select(2, bridge:HasBilling()) == 'no_billing', 'forced unknown billing: no_billing')
boot({ 'esx', 'esx_billing' })
W.convars['cis_bridge:billing'] = 'esx_billing'
check(bridge:HasBilling() == true, 'forced esx_billing: found')

-- GetBills: the local player's rows, in id order, nobody else's.
boot({ 'esx', 'esx_billing' })
local r = inThread(function() return bridge:GetBills() end)
local list = r and r[1]
check(type(list) == 'table' and type(list.items) == 'table' and #list.items == 2, 'GetBills: two rows')
check(list and list.items[1] and list.items[1].id == 3 and list.items[1].label == 'Speeding'
    and list.items[1].amount == 250, 'GetBills: row shape { id, label, amount }')
check(list and list.items[2] and list.items[2].id == 7, 'GetBills: id order')
check(list and list.more == false, 'GetBills: more false')
local gc = billCalls('esx_billing:getBills')
check(#gc == 1 and gc[1][1] == 0, 'GetBills: esx_billing:getBills with after 0')

r = inThread(function() return bridge:GetBills(3) end)
check(r and r[1] and #r[1].items == 1 and r[1].items[1].id == 7, 'GetBills(3): rows after id 3')

-- The reply comes on a later tick: nothing answers before it.
boot({ 'esx', 'esx_billing' })
r = inThread(function() return bridge:GetBills() end, 100)
check(r == nil, 'GetBills waits for the reply')
W.runThreads(100)

-- Cursor bounds: integers 0..2147483647; nothing is called for a bad one.
for _, after in ipairs({ -1, 1.5, 2147483648, '3', 0 / 0, true, math.huge, {} }) do
    boot({ 'esx', 'esx_billing' })
    r = inThread(function() return bridge:GetBills(after) end)
    check(r and r[1] == false and r[2] == 'bad_cursor', 'GetBills bad cursor: ' .. tostring(after))
    check(#W.billing.calls == 0, 'GetBills bad cursor calls nothing: ' .. tostring(after))
end
for _, after in ipairs({ 0, 2147483647 }) do
    boot({ 'esx', 'esx_billing' })
    r = inThread(function() return bridge:GetBills(after) end)
    check(r and type(r[1]) == 'table', 'GetBills cursor accepted: ' .. tostring(after))
end

-- Rows are bounded: a bad id or amount drops the row, a long label is cut.
boot({ 'esx', 'esx_billing' })
local long = string.rep('x', 200)
W.billing.rows = {
    { id = 1, label = 'ok', amount = 10 },
    { id = 0, label = 'id zero', amount = 10 },
    { id = 2147483648, label = 'id high', amount = 10 },
    { id = 1.5, label = 'id half', amount = 10 },
    { id = '9', label = 'id string', amount = 10 },
    { id = 2, label = 'amount low', amount = -1 },
    { id = 3, label = 'amount high', amount = 1e9 + 1 },
    { id = 4, label = 'amount half', amount = 2.5 },
    { id = 5, label = 'amount nan', amount = 0 / 0 },
    { id = 6, label = nil, amount = 10 },
    { id = 7, label = long, amount = 1e9 },
    { id = 8, label = 'free', amount = 0 },
    { id = 2147483647, label = 'id top', amount = 1 },
    'not a row',
}
W.billing.hasNext = false
r = inThread(function() return bridge:GetBills() end)
local ids = {}
for _, it in ipairs(r and r[1] and r[1].items or {}) do ids[#ids + 1] = it.id end
check(table.concat(ids, ',') == '1,7,8,2147483647', 'GetBills drops bad rows: ' .. table.concat(ids, ','))
local row7 = r and r[1] and r[1].items[2]
check(row7 and #row7.label == 80 and row7.amount == 1e9, 'GetBills cuts a label to 80, keeps amount 1e9')
check(row7 and math.type(row7.amount) == 'integer', 'GetBills amount is an integer')

-- more is true only for hasNext == true; a page above 100 rows is cut and
-- answers more.
for _, case in ipairs({ { true, true }, { 1, false }, { 'yes', false }, { nil, false } }) do
    boot({ 'esx', 'esx_billing' })
    W.billing.rows, W.billing.hasNext = { { id = 1, label = 'a', amount = 1 } }, case[1]
    r = inThread(function() return bridge:GetBills() end)
    check(r and r[1] and r[1].more == case[2], 'GetBills more for hasNext ' .. tostring(case[1]))
end
boot({ 'esx', 'esx_billing' })
W.billing.rows, W.billing.hasNext = {}, false
for i = 1, 150 do W.billing.rows[i] = { id = i, label = 'b' .. i, amount = i } end
r = inThread(function() return bridge:GetBills() end)
check(r and r[1] and #r[1].items == 100 and r[1].more == true, 'GetBills caps a page at 100, more true')

-- A reply that is not a row list fails; a silent callback times out at 10 s;
-- a raising trigger is an error.
boot({ 'esx', 'esx_billing' })
W.billing.rows = 'nope'
r = inThread(function() return bridge:GetBills() end)
check(r and r[1] == false and r[2] == 'failed', 'GetBills non-table reply: failed')

boot({ 'esx', 'esx_billing' })
W.billing.mode = 'silent'
r = inThread(function() return bridge:GetBills() end, 9900)
check(r == nil, 'GetBills still waits at 9.9 s')
W.runThreads(200)
boot({ 'esx', 'esx_billing' })
W.billing.mode = 'silent'
r = inThread(function() return bridge:GetBills() end, 10200)
check(r and r[1] == false and r[2] == 'timeout', 'GetBills silent: timeout after 10 s')

boot({ 'esx', 'esx_billing' })
W.billing.delay = 10500
r = inThread(function() return bridge:GetBills() end, 12000)
check(r and r[1] == false and r[2] == 'timeout', 'GetBills late reply: timeout, the late reply ignored')

boot({ 'esx', 'esx_billing' })
W.billing.mode = 'raise'
r = inThread(function() return bridge:GetBills() end)
check(r and r[1] == false and r[2] == 'error', 'GetBills raising trigger: error')

-- PayBill: the id goes to esx_billing's own pay callback; the money moves
-- there, never here.
boot({ 'esx', 'esx_billing' })
r = inThread(function() return bridge:PayBill(3) end)
check(r and r[1] == true and r.n == 1, 'PayBill(3): true')
local pc = billCalls('esx_billing:payBill')
check(#pc == 1 and pc[1][1] == 3 and math.type(pc[1][1]) == 'integer', 'PayBill: esx_billing:payBill with integer id 3')
check(W.players[1].money.bank == 4750, 'PayBill: esx_billing took 250 from bank')
r = inThread(function() return bridge:GetBills() end)
check(r and r[1] and #r[1].items == 1 and r[1].items[1].id == 7, 'PayBill: the paid bill is gone')

boot({ 'esx', 'esx_billing' })
r = inThread(function() return bridge:PayBill(5) end)
check(r and r[1] == false and r[2] == 'refused', 'PayBill another player\'s bill: refused')
check(W.players[1].money.bank == 5000, 'PayBill refused: no money moved')
r = inThread(function() return bridge:PayBill(999) end)
check(r and r[1] == false and r[2] == 'refused', 'PayBill unknown bill: refused')

boot({ 'esx', 'esx_billing' })
r = inThread(function() return bridge:PayBill(3.0) end)
check(r and r[1] == true, 'PayBill(3.0) is the integer 3')

-- 2147483648 is refused here by math.tointeger already (the driver's integers
-- are 32-bit); on the 64-bit FiveM runtime the MAX_BILL_ID bound refuses it.
local BAD_IDS = table.pack(nil, 0, -1, 1.5, 2147483648, '3', 0 / 0, true, math.huge, {})
for i = 1, BAD_IDS.n do
    local id = BAD_IDS[i]
    boot({ 'esx', 'esx_billing' })
    r = inThread(function() return bridge:PayBill(id) end)
    check(r and r[1] == false and r[2] == 'bad_id', 'PayBill bad id: ' .. tostring(id))
    check(#W.billing.calls == 0, 'PayBill bad id calls nothing: ' .. tostring(id))
end
for _, id in ipairs({ 1, 2147483647 }) do
    boot({ 'esx', 'esx_billing' })
    r = inThread(function() return bridge:PayBill(id) end)
    check(r and r[2] == 'refused' and #billCalls('esx_billing:payBill') == 1, 'PayBill id accepted: ' .. id)
end

-- Only the boolean true is a payment.
for _, answer in ipairs({ 1, 'true', {}, false }) do
    boot({ 'esx', 'esx_billing' })
    W.billing.payAnswer = answer
    r = inThread(function() return bridge:PayBill(3) end)
    check(r and r[1] == false and r[2] == 'refused', 'PayBill answer ' .. tostring(answer) .. ': refused')
end

boot({ 'esx', 'esx_billing' })
W.billing.mode = 'silent'
r = inThread(function() return bridge:PayBill(3) end, 10200)
check(r and r[1] == false and r[2] == 'timeout', 'PayBill silent: timeout')

boot({ 'esx', 'esx_billing' })
W.billing.mode = 'raise'
r = inThread(function() return bridge:PayBill(3) end)
check(r and r[1] == false and r[2] == 'error', 'PayBill raising trigger: error')

-- A second reply to the same call is ignored (the first answer stands).
boot({ 'esx', 'esx_billing' })
W.billing.mode = 'twice'
r = inThread(function() return bridge:PayBill(3) end)
check(r and r[1] == true, 'PayBill twice-answered: the first answer')

-- esx_billing stopped after detection: detection runs again, no_billing.
boot({ 'esx', 'esx_billing' })
check(bridge:HasBilling() == true, 'billing found before the stop')
W.state.esx_billing = 'stopped'
W.fire('onResourceStop', nil, 'esx_billing')
check(select(2, bridge:HasBilling()) == 'no_billing', 'esx_billing stopped: no_billing')

-- ===========================================================================

_G.__suite_failed =(_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(v1-client): ' .. failures[i] .. '\n')
end
io.write(('v1-client passed=%d failed=%d\n'):format(passed, failed))
