-- The v1 product API, client half (docs/V1.md).
--
-- The client reads and asks; it never decides. Everything here is display:
-- the local player's data, a notification, and interaction targets whose
-- `onSelect` a product turns into a net event the server validates.

local V1 = {}

local FRAMEWORK_ORDER = { 'qbox', 'esx', 'qbcore', 'cis_core' }
local TARGET_ORDER = { 'ox_target', 'qb-target' }
local BILLING_ORDER = { 'esx_billing' }
local MAX_OPTIONS = 16
local MAX_MESSAGE = 512
local KINDS = { info = true, success = true, warning = true, error = true }

-- The one default interaction distance, in metres, for an option that names
-- none. Both targets default to 7 m on their own (ox_target client/main.lua
-- `option.distance or 7`; qb-target `Config.MaxDistance = 7.0`), which is a
-- shop counter you can use from across the room. The bridge fills the option in
-- before either adapter sees it, so a product gets the same reach on both.
local DEFAULT_DISTANCE = 2.0
local MAX_DISTANCE = 50.0
-- Bounds on what a product may hand a target resource. A NaN or an infinity
-- reaches the zone maths of ox_lib / PolyZone, which never recover from one.
-- The GTA map spans about -4000..8000 on each axis; 1e4 leaves room for an
-- interior placed out at sea or in the sky.
local MAX_COORD = 1e4
local MAX_SIZE = 1000.0
local MAX_ROTATION = 360.0
-- How long the loaded relay waits for the framework's own data (below).
local LOADED_POLL_MS = 100
local LOADED_TIMEOUT_MS = 10000

local fw, target, billing
local detected = false

local function started(resource)
    return GetResourceState(resource) == 'started'
end

-- A forced convar that names no adapter, or an adapter whose resource is not
-- started, picks nothing for its slot (fail closed, never the detected one) and
-- says why in one plain line in F8, printed once per cause.
local said = {}

local function adapterNames(registry)
    local out = {}
    for name, a in pairs(registry or {}) do
        if type(a) == 'table' and name:sub(1, 2) ~= '__' then out[#out + 1] = name end
    end
    table.sort(out)
    return table.concat(out, ', ')
end

-- `cis_bridge:<slot>_resource` names the resource a renamed framework, target,
-- billing or appearance resource runs under, as on the server: it applies to
-- the adapter the slot's convar forces, and set alone it picks nothing and
-- says so.
local function applyResource(registry, convar, forced)
    local renamed = GetConvar(convar .. '_resource', '')
    for _, a in pairs(registry or {}) do
        if type(a) == 'table' and a.resource ~= nil then
            a.defaultResource = a.defaultResource or a.resource
            a.resource = a.defaultResource
        end
    end
    if renamed == '' then return nil end
    if not forced then
        -- The hint lists every adapter of this slot and picks none: the
        -- renamed resource could run any of them (qb-core as my-core).
        return ("%s_resource is '%s', but %s is not set. Set both: setr %s <adapter>, where <adapter> is one of: %s")
            :format(convar, renamed, convar, convar, adapterNames(registry))
    end
    local a = registry and registry[forced]
    if type(a) == 'table' and forced:sub(1, 2) ~= '__' then a.resource = renamed end
    return nil
end

--- The adapter name a convar forces (nil when it is unset), and true when the
--- slot's convars are wrong, so it picks nothing.
local function forcedName(registry, convar)
    local forced = GetConvar(convar, '')
    if forced == '' then forced = nil end
    local line = applyResource(registry, convar, forced)
    local a = forced and registry and registry[forced]
    if forced then
        if type(a) ~= 'table' or forced:sub(1, 2) == '__' then
            line = ("%s is '%s', which is not an adapter. Use one of: %s")
                :format(convar, forced, adapterNames(registry))
        elseif not started(a.resource) then
            line = ("%s is '%s', but %s is not started"):format(convar, forced, a.resource)
        end
    end
    if line and said[convar] ~= line then print('^1' .. line .. '^7') end
    said[convar] = line
    return forced, line ~= nil
end

-- A forced adapter that is started but fails its probe picks nothing, and F8
-- says so once per cause. Called with the pick, or nil when nothing answered.
local function probeLine(convar, forced, registry, picked)
    local key = convar .. ':probe'
    local a = forced and registry and registry[forced]
    local line = not picked and type(a) == 'table' and forced:sub(1, 2) ~= '__' and started(a.resource)
        and ("%s is '%s' and %s is started, but it does not answer the %s probe")
            :format(convar, forced, a.resource, forced)
        or nil
    if line and said[key] ~= line then print('^1' .. line .. '^7') end
    said[key] = line
end

-- Every framework adapter drops its cached core object first, as the server's
-- V1.detect does: a restarted es_extended or qb-core leaves the old shared
-- object behind, and every function in it raises once its resource is gone.
-- The adapters fetch a fresh one on their next call.
--
-- Unlike the server, the client does not probe. Qbox's probe reads the
-- `GetPlayer` export, which qbx_core declares on the server only (its client
-- exports are GetPlayerData, Notify, HasPrimaryGroup, HasGroup, GetGroups and
-- the shared lookups), so a client probe would never find Qbox. A started
-- resource is enough here; `data()` and `notify()` answer for the rest.
local function detect()
    for _, a in pairs(CisBridgeFrameworks or {}) do
        if type(a) == 'table' and type(a.reset) == 'function' then pcall(a.reset) end
    end
    fw, target, billing = nil, nil, nil
    local forced, wrong = forcedName(CisBridgeFrameworks, 'cis_bridge:framework')
    for _, name in ipairs(wrong and {} or forced and { forced } or FRAMEWORK_ORDER) do
        local a = CisBridgeFrameworks and CisBridgeFrameworks[name]
        if a and started(a.resource)
            and not (name == 'qbcore' and not forced and started('qbx_core')) then
            fw = a
            break
        end
    end
    local forcedTarget, wrongTarget = forcedName(CisBridgeTargets, 'cis_bridge:target')
    for _, name in ipairs(wrongTarget and {} or forcedTarget and { forcedTarget } or TARGET_ORDER) do
        local t = CisBridgeTargets and CisBridgeTargets[name]
        local ok, yes = pcall(function() return t ~= nil and started(t.resource) and t.probe() end)
        if ok and yes == true then
            target = t
            break
        end
    end
    probeLine('cis_bridge:target', forcedTarget, CisBridgeTargets, target)
    local forcedBilling, wrongBilling = forcedName(CisBridgeBilling, 'cis_bridge:billing')
    for _, name in ipairs(wrongBilling and {} or forcedBilling and { forcedBilling } or BILLING_ORDER) do
        local b = CisBridgeBilling and CisBridgeBilling[name]
        local ok, yes = pcall(function() return b ~= nil and started(b.resource) and b.probe() end)
        if ok and yes == true then
            billing = b
            break
        end
    end
    probeLine('cis_bridge:billing', forcedBilling, CisBridgeBilling, billing)
    -- The server picks the appearance adapter and names it in each save; the
    -- client only needs the resource a renamed one runs under. The server
    -- prints any wrong appearance config, so nothing is printed here.
    local forcedLook = GetConvar('cis_bridge:appearance', '')
    applyResource(CisBridgeAppearances, 'cis_bridge:appearance', forcedLook ~= '' and forcedLook or nil)
    detected = true
end

local function ensure()
    if not detected then detect() end
end

local function guard(label, fn, ...)
    local res = table.pack(pcall(fn, ...))
    if not res[1] then
        print(('^1cis_bridge: %s raised: %s^7'):format(label, tostring(res[2])))
        return false, 'error'
    end
    return table.unpack(res, 2, res.n)
end

-- ===========================================================================
--  Player and notify
--
--  A raise inside the framework answers 'error', never 'not_loaded' or
--  'unsupported': those two say something true about the player or the
--  framework, and a raise says only that the call broke.
-- ===========================================================================

function V1.getPlayerData()
    ensure()
    if not fw then return false, 'no_framework' end
    local data, why = guard(fw.name .. '.data', fw.client.data)
    if data == false and why == 'error' then return false, 'error' end
    if type(data) ~= 'table' then return false, 'not_loaded' end
    return data
end

function V1.isLoaded()
    return type((V1.getPlayerData())) == 'table'
end

function V1.notify(message, kind)
    if type(message) ~= 'string' or #message < 1 or #message > MAX_MESSAGE then
        return false, 'bad_message'
    end
    kind = kind or 'info'
    -- 'inform' is the old ox_lib spelling of info; ox_lib maps it itself.
    if kind == 'inform' then kind = 'info' end
    if not KINDS[kind] then return false, 'bad_message' end
    ensure()
    if not fw then return false, 'no_framework' end
    local ok, why = guard(fw.name .. '.notify', fw.client.notify, message, kind)
    if ok == false and why == 'error' then return false, 'error' end
    if ok ~= true then return false, 'unsupported' end
    return true
end

-- ===========================================================================
--  Targets
--
--  A record is keyed by `owner .. ':' .. name`, the owner being the resource
--  that called the export. Two products may both call a target 'shop', and
--  neither can remove the other's. The key is also the name the target
--  resource sees (the qb zone name, the ox zone and option names), so the two
--  never collide there either. The product keeps using its own short name.
--
--  A record also remembers which target resource holds it (`via`), because
--  that resource can stop under it (below).
-- ===========================================================================

local records = {}

local function validName(name)
    return type(name) == 'string' and #name >= 1 and #name <= 64
end

-- `x == x` is false only for NaN; the open bounds refuse both infinities.
local function finite(x, lo, hi)
    return type(x) == 'number' and x == x and x > lo and x < hi
end

-- `type()` of a FiveM vector is 'vector3' (LuaGLM), and a vector that crossed
-- from another resource arrives the same way; a plain { x, y, z } table is
-- accepted too.
local function isVec(v, lo, hi)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'table' then return false end
    return finite(v.x, lo, hi) and finite(v.y, lo, hi) and finite(v.z, lo, hi)
end

-- A function from this resource, or a reference from another one: a function
-- that crosses an export boundary arrives as a table that carries
-- `__cfx_functionReference` or has a `__call` metamethod. A plain table is
-- refused here, because the target resource would raise only when the player
-- selects the option.
local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and mt.__call ~= nil
end

-- The canonical option list both adapters translate, or nil for a bad one.
local function canonicalOptions(options)
    if type(options) ~= 'table' or #options < 1 or #options > MAX_OPTIONS then return nil end
    -- qb-target keys options by label (SetOptions), so a second option with
    -- the same label replaces the first; the pair is refused on every backend.
    local out, labels = {}, {}
    for i, o in ipairs(options) do
        if type(o) ~= 'table' or type(o.label) ~= 'string' or #o.label < 1 or #o.label > 64 then
            return nil
        end
        if labels[o.label] then return nil end
        labels[o.label] = true
        if not callable(o.onSelect) then return nil end
        if o.canInteract ~= nil and not callable(o.canInteract) then return nil end
        if o.distance ~= nil and not finite(o.distance, 0, MAX_DISTANCE) then return nil end
        -- The target resource shows the icon as a class name in its UI.
        if o.icon ~= nil and (type(o.icon) ~= 'string' or #o.icon > 64) then return nil end
        out[i] = {
            label = o.label,
            icon = o.icon,
            distance = o.distance or DEFAULT_DISTANCE,
            onSelect = o.onSelect,
            canInteract = o.canInteract,
        }
    end
    if #out ~= #options then return nil end
    return out
end

local function ownerOf()
    return GetInvokingResource() or GetCurrentResourceName()
end

function V1.addTargetZone(spec)
    local owner = ownerOf()
    if type(spec) ~= 'table' or not validName(spec.name) then return false, 'bad_target' end
    if spec.kind ~= 'box' and spec.kind ~= 'sphere' then return false, 'bad_target' end
    if not isVec(spec.coords, -MAX_COORD, MAX_COORD) then return false, 'bad_target' end
    if spec.kind == 'box' and not isVec(spec.size, 0, MAX_SIZE) then return false, 'bad_target' end
    if spec.kind == 'sphere' and not finite(spec.size, 0, MAX_SIZE) then return false, 'bad_target' end
    if spec.rotation ~= nil and not finite(spec.rotation, -MAX_ROTATION, MAX_ROTATION) then
        return false, 'bad_target'
    end
    local options = canonicalOptions(spec.options)
    if not options then return false, 'bad_target' end
    ensure()
    if not target then return false, 'no_target' end
    local key = owner .. ':' .. spec.name
    if records[key] then return false, 'exists' end
    local handle, why = guard(target.name .. '.addZone', target.addZone, {
        name = key, kind = spec.kind, coords = spec.coords, size = spec.size,
        rotation = spec.rotation, debug = spec.debug == true, options = options,
    })
    -- false from the adapter is a failure with its reason (guard turns a raise
    -- into 'error'); nothing is recorded.
    if handle == false then return false, why or 'refused' end
    records[key] = { name = key, owner = owner, via = target.resource, handle = handle }
    return true
end

function V1.addTargetEntity(spec)
    local owner = ownerOf()
    if type(spec) ~= 'table' or not validName(spec.name) then return false, 'bad_target' end
    if type(spec.entity) ~= 'number' or spec.entity == 0 then return false, 'bad_target' end
    if not DoesEntityExist(spec.entity) then return false, 'bad_target' end
    local options = canonicalOptions(spec.options)
    if not options then return false, 'bad_target' end
    ensure()
    if not target then return false, 'no_target' end
    local key = owner .. ':' .. spec.name
    if records[key] then return false, 'exists' end
    local handle, why = guard(target.name .. '.addEntity', target.addEntity,
        { name = key, entity = spec.entity, options = options })
    -- false from the adapter is a failure with its reason (guard turns a raise
    -- into 'error'); nothing is recorded.
    if handle == false then return false, why or 'refused' end
    records[key] = { name = key, owner = owner, via = target.resource, entity = spec.entity, handle = handle }
    return true
end

-- The record goes whether or not the call lands: a target we still believe in
-- after a failed removal is offered for removal forever.
local function drop(key)
    local record = records[key]
    records[key] = nil
    ensure()
    if not target or target.resource ~= record.via then return false, 'no_target' end
    if guard(target.name .. '.remove', target.remove, record) ~= true then return false, 'error' end
    return true
end

function V1.removeTarget(name)
    if not validName(name) then return false, 'bad_target' end
    local key = ownerOf() .. ':' .. name
    if not records[key] then return false, 'unknown_target' end
    return drop(key)
end

-- Three kinds of stop:
--
--   - cis_bridge itself: every record is removed. qb-target never cleans up
--     after the resource that added a zone, so a zone whose callbacks died
--     with this resource would otherwise stay in the world.
--   - the target resource that holds a record: its zones went with it, so the
--     records are dropped without a remove call. ox_target hands out zone ids
--     as `#Zones + 1` (ox_lib zones), so after its restart the same id belongs
--     to whoever registered next, and removing a stale record would delete
--     another product's zone.
--   - the record's owner: its own records are removed.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        for key in pairs(records) do drop(key) end
        return
    end
    for key, record in pairs(records) do
        if record.via == resource then
            records[key] = nil
        elseif record.owner == resource then
            drop(key)
        end
    end
    detected = false
end)

AddEventHandler('onResourceStart', function()
    detected = false
end)

-- ===========================================================================
--  Appearance
--
--  One slot of the local ped, read or dressed through the natives: the ped is
--  the truth whatever resource dressed it (adapters/appearance/common.lua).
--  Saving is the clothing resource's own path, asked for by the server
--  (SaveAppearance) and run here by the adapter it names.
-- ===========================================================================

local Look = CisBridgeAppearances and CisBridgeAppearances.__common
-- Net events this file registered, so none is registered twice.
local registered = {}
-- The skin-loaded event waits this long after the last load signal, because a
-- clothing resource applies the look in steps (illenium after a callback,
-- skinchanger model then clothes) and fires nothing when it is done.
local APPEARANCE_SETTLE_MS = 1500

function V1.getAppearanceComponent(slot)
    if type(slot) ~= 'string' or not Look.SLOTS[slot] then return false, 'bad_slot' end
    return Look.read(PlayerPedId(), slot)
end

function V1.applyClothing(slot, data)
    if type(slot) ~= 'string' or not Look.SLOTS[slot] then return false, 'bad_slot' end
    if not Look.valid(slot, data) then return false, 'bad_clothing' end
    Look.apply(PlayerPedId(), slot, { drawable = data.drawable, texture = data.texture or 0 })
    return true
end

local settleWait = 0

local function appearanceSignal()
    settleWait = settleWait + 1
    local mine = settleWait
    CreateThread(function()
        Wait(APPEARANCE_SETTLE_MS)
        if mine == settleWait then TriggerEvent('cis_bridge:appearanceLoaded') end
    end)
end

-- The server asks; only the adapter it names, started here, saves.
RegisterNetEvent('cis_bridge:appearance:save', function(name, reply)
    -- From the server or not at all: a local TriggerEvent arrives with
    -- source == ''.
    if source == nil or source == '' then return end
    ensure()
    local a = type(name) == 'string' and CisBridgeAppearances and CisBridgeAppearances[name] or nil
    if type(a) ~= 'table' or not a.client or not started(a.resource) then return end
    local ok, why = guard(a.name .. '.save', a.client.save, PlayerPedId(), reply == true)
    if ok ~= true then
        print(('^3cis_bridge: %s did not save the appearance: %s^7'):format(a.name, tostring(why)))
    end
end)

for name, a in pairs(CisBridgeAppearances or {}) do
    if name ~= '__common' and type(a) == 'table' then
        for _, spec in ipairs(a.loadEvents or {}) do
            local event = spec[1]
            if spec.net and not registered[event] then
                registered[event] = true
                RegisterNetEvent(event)
            end
            AddEventHandler(event, function(...)
                if type(a.client.loaded) == 'function' then pcall(a.client.loaded, ...) end
                ensure()
                if started(a.resource) then appearanceSignal() end
            end)
        end
    end
end
AddEventHandler('cis_bridge:playerLoaded', appearanceSignal)

-- ===========================================================================
--  Billing
--
--  The billing resource's own client callbacks list and pay the local
--  player's bills (adapters/billing/esx_billing.lua says why it must be
--  theirs): the money moves inside that resource's locks and journal, and the
--  bridge only bounds the call and what comes back. The reply comes on a later
--  tick, so GetBills and PayBill wait for it and must be called from a thread
--  (a NUI callback, CreateThread). A reply after BILLING_TIMEOUT_MS is
--  ignored: a pay that timed out may still have landed, so read the list
--  again.
-- ===========================================================================

local BILLING_TIMEOUT_MS = 10000
local BILLING_POLL_MS = 50
local MAX_BILL_ID = 2147483647
local MAX_BILL_AMOUNT = 1e9
local MAX_BILL_LABEL = 80
local MAX_BILLS = 100

-- An integer lo..MAX_BILL_ID as a Lua integer, or nil. 3.0 is 3.
local function billInt(v, lo)
    if type(v) ~= 'number' or v ~= v or v < lo or v > MAX_BILL_ID then return nil end
    return math.tointeger(v)
end

-- Calls fn(arg, done) and waits for done's first call: its values packed,
-- or nil after BILLING_TIMEOUT_MS. A second call of done changes nothing.
local function awaitReply(fn, arg)
    local reply
    fn(arg, function(...)
        if reply == nil then reply = table.pack(...) end
    end)
    local deadline = GetGameTimer() + BILLING_TIMEOUT_MS
    while reply == nil and GetGameTimer() < deadline do Wait(BILLING_POLL_MS) end
    return reply
end

function V1.hasBilling()
    ensure()
    if not billing then return false, 'no_billing' end
    return true, billing.name
end

function V1.getBills(after)
    if after == nil then after = 0 end
    after = billInt(after, 0)
    if not after then return false, 'bad_cursor' end
    ensure()
    if not billing then return false, 'no_billing' end
    local ok, reply = pcall(awaitReply, billing.list, after)
    if not ok then
        print(('^1cis_bridge: %s.list raised: %s^7'):format(billing.name, tostring(reply)))
        return false, 'error'
    end
    if reply == nil then return false, 'timeout' end
    local rows = reply[1]
    if type(rows) ~= 'table' then return false, 'failed' end
    local items, more = {}, reply[2] == true
    for _, row in ipairs(rows) do
        if #items >= MAX_BILLS then
            more = true
            break
        end
        if type(row) == 'table' then
            local id = billInt(row.id, 1)
            local amount = type(row.amount) == 'number' and row.amount <= MAX_BILL_AMOUNT
                and math.tointeger(row.amount) or nil
            if id and amount and amount >= 0 and type(row.label) == 'string' then
                items[#items + 1] = { id = id, label = row.label:sub(1, MAX_BILL_LABEL), amount = amount }
            end
        end
    end
    return { items = items, more = more }
end

function V1.payBill(id)
    id = billInt(id, 1)
    if not id then return false, 'bad_id' end
    ensure()
    if not billing then return false, 'no_billing' end
    local ok, reply = pcall(awaitReply, billing.pay, id)
    if not ok then
        print(('^1cis_bridge: %s.pay raised: %s^7'):format(billing.name, tostring(reply)))
        return false, 'error'
    end
    if reply == nil then return false, 'timeout' end
    if reply[1] ~= true then return false, 'refused' end
    return true
end

-- ===========================================================================
--  Exports and events
--
--  Client framework events arrive from the server, so they are net events:
--  RegisterNetEvent is what lets this resource receive them at all.
-- ===========================================================================

for exportName, key in pairs({
    GetPlayerData = 'getPlayerData', IsLoaded = 'isLoaded', Notify = 'notify',
    AddTargetZone = 'addTargetZone', AddTargetEntity = 'addTargetEntity', RemoveTarget = 'removeTarget',
    GetAppearanceComponent = 'getAppearanceComponent', ApplyClothing = 'applyClothing',
    HasBilling = 'hasBilling', GetBills = 'getBills', PayBill = 'payBill',
}) do
    local fn = V1[key]
    V1[key] = function(...) return guard(exportName, fn, ...) end
end

exports('GetPlayerData', V1.getPlayerData)
exports('IsLoaded', V1.isLoaded)
exports('Notify', V1.notify)
exports('AddTargetZone', V1.addTargetZone)
exports('AddTargetEntity', V1.addTargetEntity)
exports('RemoveTarget', V1.removeTarget)
exports('GetAppearanceComponent', V1.getAppearanceComponent)
exports('ApplyClothing', V1.applyClothing)
exports('HasBilling', V1.hasBilling)
exports('GetBills', V1.getBills)
exports('PayBill', V1.payBill)

-- The loaded relay waits for the data, because a framework's loaded event can
-- arrive before its own GetPlayerData answers. es_extended's handler for
-- `esx:playerLoaded` (es_extended 1.16.4
-- client/modules/player/lifecycle.lua:8-26) sets PlayerData, then
-- waits in a `Wait(20)` loop for the ped to exist, and only then sets
-- `ESX.PlayerLoaded`; our handler runs while it waits, so a product that reads
-- GetPlayerData on `cis_bridge:playerLoaded` would get 'not_loaded'.
--
-- So the relay polls the adapter every LOADED_POLL_MS and fires once data is a
-- table. A second loaded event (a character switch) replaces the first wait,
-- so one load fires once. If the data never comes within LOADED_TIMEOUT_MS the
-- relay fires anyway and says so in F8: a product that waits for the event to
-- start its client would otherwise never start, while GetPlayerData keeps
-- answering 'not_loaded' honestly for it to check.
local loadedWait = 0

local function relayLoaded(adapter)
    loadedWait = loadedWait + 1
    local mine = loadedWait
    CreateThread(function()
        local deadline = GetGameTimer() + LOADED_TIMEOUT_MS
        while mine == loadedWait and fw == adapter do
            local ok, data = pcall(adapter.client.data)
            if ok and type(data) == 'table' then break end
            if GetGameTimer() >= deadline then
                print(('^3cis_bridge: %s sent its loaded event but its player data did not answer within %d ms; '
                    .. 'relaying cis_bridge:playerLoaded anyway^7'):format(adapter.name, LOADED_TIMEOUT_MS))
                break
            end
            Wait(LOADED_POLL_MS)
        end
        if mine == loadedWait and fw == adapter then
            TriggerEvent('cis_bridge:playerLoaded')
        end
    end)
end

for _, adapter in pairs(CisBridgeFrameworks or {}) do
    if type(adapter) == 'table' and type(adapter.clientEvents) == 'table' then
        for kind, spec in pairs(adapter.clientEvents) do
            local event = spec[1]
            if not registered[event] then
                registered[event] = true
                RegisterNetEvent(event)
            end
            AddEventHandler(event, function(...)
                ensure()
                if fw ~= adapter then return end
                local ok, value = pcall(spec[2], ...)
                if not ok then return end
                if kind == 'loaded' then
                    relayLoaded(adapter)
                elseif kind == 'jobChanged' then
                    TriggerEvent('cis_bridge:jobChanged', value)
                end
            end)
        end
    end
end

CisBridgeClientV1 = V1
