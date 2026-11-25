-- ESX Legacy adapter (es_extended), for the v1 product API in server/v1.lua.
--
-- Every fact this file relies on was read in esx_core at 03c3fc7 (tag 1.16.4)
-- and the 1.16 tree. Paths are under `[core]/es_extended/`.
--
-- The call convention. ESX builds its player with closures:
-- `function self.removeAccountMoney(accountName, money, reason)` (accounts.lua).
-- There is no implicit self, so every xPlayer method here is a dot call. A
-- colon call hands the xPlayer itself in as `accountName`, ESX raises on the
-- unknown account, and a pcall turns that into a refusal nobody can explain.
--
-- What this file does not do. It does not validate amounts, check balances or
-- take the per-player lock: server/v1.lua does all three before an adapter is
-- reached, the same way on every framework. An adapter's job is to translate.

CisBridgeFrameworks = CisBridgeFrameworks or {}
local Common = CisBridgeFrameworks.__common

local Adapter = {
    name = 'esx',
    resource = 'es_extended',
    -- Canonical account -> ESX account. ESX calls cash `money`.
    accounts = { cash = 'money', bank = 'bank', dirty = 'black_money' },
    server = {},
    client = {},
}

local ESX

-- `getSharedObject` is the probe and the fetch. A started es_extended whose
-- export does not answer is not a usable ESX, and detection moves on.
function Adapter.probe()
    local ok, core = pcall(function()
        return exports[Adapter.resource]:getSharedObject()
    end)
    if ok and type(core) == 'table' then
        ESX = core
        return true
    end
    return false
end

local function xPlayer(src)
    if not ESX or not Common.callable(ESX.GetPlayerFromId) then return nil end
    local player = ESX.GetPlayerFromId(src)
    if type(player) ~= 'table' then return nil end
    return player
end

-- ESX `job`: `{ name, label, grade:number, grade_name, grade_label,
-- grade_salary, onDuty }` (job.lua:56-70). ESX has no boss flag; `boss` is the
-- grade name its stock jobs use for the top grade.
local function normaliseJob(job)
    if type(job) ~= 'table' then return nil end
    return {
        name = tostring(job.name or 'unemployed'),
        label = tostring(job.label or job.name or ''),
        grade = math.floor(tonumber(job.grade) or 0),
        gradeName = tostring(job.grade_name or ''),
        gradeLabel = tostring(job.grade_label or job.grade_name or ''),
        isBoss = job.grade_name == 'boss',
        onDuty = job.onDuty ~= false,
        pay = math.floor(tonumber(job.grade_salary) or 0),
    }
end

local S = Adapter.server

-- A raw read for `cis_bridge test`: no shape checks, so a bug in them shows.
function S.hasPlayer(src)
    return ESX ~= nil and ESX.GetPlayerFromId ~= nil and ESX.GetPlayerFromId(src) ~= nil
end

function S.player(src)
    local p = xPlayer(src)
    if not p then return nil end
    local name = Common.callable(p.getName) and p.getName() or p.name
    local job = Common.callable(p.getJob) and p.getJob() or p.job
    return {
        id = tostring(p.identifier or ''),
        name = tostring(name or ''),
        job = normaliseJob(job),
    }
end

-- `getAccount(name)` -> `{ name, money, ... }` or nil
-- (server/classes/player/accounts.lua:76-91).
-- Read through the method, never the snapshot field: `xPlayer.accounts` is
-- the msgpack copy taken when the xPlayer crossed into this resource.
function S.balance(src, account)
    local p = xPlayer(src)
    if not p then return nil end
    local acc = p.getAccount(account)
    if type(acc) ~= 'table' then return nil end
    return tonumber(acc.money)
end

-- `addAccountMoney` returns true, false on overflow, and raises on a bad
-- amount or account. The raise never reaches here with a validated amount;
-- the pcall in server/v1.lua covers a plugin that overrides the method.
function S.add(src, account, amount, reason)
    local p = xPlayer(src)
    if not p then return false, 'not_loaded' end
    if p.addAccountMoney(account, amount, reason) == true then return true end
    return false, 'refused'
end

-- `removeAccountMoney` returns false when the balance would go negative
-- (accounts.lua:237 base), and with ox_inventory's override it does not check
-- the bank balance at all (overrides/oxinventory.lua:345-347). The balance
-- check in server/v1.lua runs first on both.
function S.remove(src, account, amount, reason)
    local p = xPlayer(src)
    if not p then return false, 'not_loaded' end
    if p.removeAccountMoney(account, amount, reason) == true then return true end
    return false, 'refused'
end

function S.job(src)
    local p = xPlayer(src)
    if not p then return nil end
    return normaliseJob(Common.callable(p.getJob) and p.getJob() or p.job)
end

-- `ESX.GetJobs()` -> `ESX.Jobs`, grades keyed by string
-- (server/modules/jobs/registry.lua:123-131 and :20, job.lua:54). It waits
-- for the jobs to load, so it is called only from SetJob.
function S.jobExists(name, grade)
    if not ESX or not Common.callable(ESX.GetJobs) then return false, 'unknown_job' end
    local jobs = ESX.GetJobs()
    local job = type(jobs) == 'table' and jobs[name] or nil
    if type(job) ~= 'table' then return false, 'unknown_job' end
    if type(job.grades) ~= 'table' or job.grades[tostring(grade)] == nil then
        return false, 'unknown_grade'
    end
    return true
end

-- `setJob` returns nil on success and on an invalid job (job.lua:43), so the
-- only proof is to read the job back.
function S.setJob(src, name, grade)
    local p = xPlayer(src)
    if not p then return false, 'not_loaded' end
    p.setJob(name, grade)
    local now = S.job(src)
    if now and now.name == name and now.grade == grade then return true end
    return false, 'refused'
end

-- `xPlayer.showNotification` is `triggerEvent('esx:showNotification', ...)`
-- (notifications.lua:7-9); the event is sent directly so an unloaded player
-- still gets the message. ESX's own types are info, success, error.
local KINDS = { info = 'info', success = 'success', warning = 'info', error = 'error' }

function S.notify(src, message, kind)
    TriggerClientEvent('esx:showNotification', src, message, KINDS[kind] or 'info', 5000)
    return true
end

-- esx_core 1.16.4 `ESX.GetPlayerIdFromIdentifier(identifier)` -> the source of
-- a loaded player, or nil (server/modules/player/lookup.lua:101-103). An older
-- core without it is read through GetPlayerFromIdentifier (:96-98).
function S.sourceOf(charId)
    if not ESX then return nil end
    if Common.callable(ESX.GetPlayerIdFromIdentifier) then
        -- The extra parentheses keep one value: a lone nil answer crosses the
        -- export boundary as no value at all, and tonumber() with none raises.
        return tonumber((ESX.GetPlayerIdFromIdentifier(charId)))
    end
    if Common.callable(ESX.GetPlayerFromIdentifier) then
        local x = ESX.GetPlayerFromIdentifier(charId)
        return type(x) == 'table' and tonumber(x.source) or nil
    end
    return nil
end

-- ESX has no gangs. Its player metadata has no dead, last stand or cuffed flag
-- that esx_ambulancejob or esx_policejob writes, so the state is not read.
function S.gang() return false, 'unsupported' end
function S.state() return false, 'unsupported' end

-- Usable items. server/modules/items/usable.lua:37-55: `ESX.UseItem(source,
-- item, ...)` runs the registered callback in a pcall and answers nothing, and
-- only says so in the console for an item ESX does not know. The registry
-- (`Core.UsableItemsCallbacks`) is private to es_extended; its public view is
-- `ESX.GetUsableItems()` -> `{ [item] = true }` (:58-64). A core without
-- GetUsableItems cannot say, so the call is made and taken as made.
function S.canUseItem(item)
    if not ESX or not Common.callable(ESX.UseItem) then return false end
    if not Common.callable(ESX.GetUsableItems) then return true end
    local usable = ESX.GetUsableItems()
    return type(usable) == 'table' and usable[item] == true
end

function S.useItem(src, item, data)
    if not ESX or not Common.callable(ESX.UseItem) then return false, 'not_usable' end
    ESX.UseItem(src, item, data)
    return true
end

-- ESX has no vehicle id: `owned_vehicles.plate` is the primary key
-- (esx_vehicleshop.sql:44-53), stored trimmed and upper case. The plate is the id.
function S.ownedVehicleId(plate)
    return Common.scalar('SELECT plate FROM owned_vehicles WHERE plate = ? LIMIT 1', { plate })
end

-- Framework events to the bridge's own. Each mapper answers the source and,
-- for a job change, the normalised job, or nil to ignore the event.
Adapter.events = {
    loaded = { 'esx:playerLoaded', function(src) return src end },
    -- Fires on drop and on /logout (session/runtime/events.lua:31-36).
    unloaded = { 'esx:playerDropped', function(src) return src end },
    jobChanged = { 'esx:setJob', function(src, job) return src, normaliseJob(job) end },
}

-- ESX's own inventory, used only when no inventory resource is started. With
-- ox_inventory running, ESX routes these methods to ox (overrides/oxinventory),
-- and the bridge talks to ox directly instead.
Adapter.inventory = {
    name = 'esx',
    resource = 'es_extended',
}

local I = Adapter.inventory

function I.probe()
    return ESX ~= nil or Adapter.probe()
end

-- `getInventoryItem` answers a zero-count entry for a known item and nil for
-- an unknown one (player.lua:62, inventory.lua:122-130).
function I.count(src, item)
    local p = xPlayer(src)
    if not p then return nil end
    local entry = p.getInventoryItem(item)
    if type(entry) ~= 'table' then return 0 end
    return math.floor(tonumber(entry.count) or 0)
end

function I.known(item)
    if not ESX or not Common.callable(ESX.GetItemLabel) then return nil end
    return ESX.GetItemLabel(item) ~= nil
end

-- `canCarryItem` is a weight check and prints a warning for an unknown item
-- (inventory.lua:226-235).
function I.canCarry(src, item, count)
    local p = xPlayer(src)
    if not p then return false, 'not_loaded' end
    if I.known(item) == false then return false, 'unknown_item' end
    if p.canCarryItem(item, count) == true then return true end
    return false, 'cannot_carry'
end

-- `addInventoryItem` returns true, or false for an unknown item. It does not
-- check weight; CanCarry runs first.
function I.add(src, item, count, _metadata)
    local p = xPlayer(src)
    if not p then return false, 'not_loaded' end
    if p.addInventoryItem(item, count) == true then return true end
    return false, 'refused'
end

function I.remove(src, item, count)
    local p = xPlayer(src)
    if not p then return false, 'not_loaded' end
    if p.removeInventoryItem(item, count) == true then return true end
    return false, 'refused'
end

-- Client half. ESX's client data comes from the shared object too.
local C = Adapter.client

function C.data()
    if not ESX and not Adapter.probe() then return nil end
    if Common.callable(ESX.IsPlayerLoaded) and not ESX.IsPlayerLoaded() then return nil end
    local data = ESX.GetPlayerData()
    if type(data) ~= 'table' then return nil end
    return {
        id = tostring(data.identifier or ''),
        name = tostring(data.name or ''),
        job = normaliseJob(data.job),
    }
end

function C.notify(message, kind)
    TriggerEvent('esx:showNotification', message, KINDS[kind] or 'info', 5000)
    return true
end

Adapter.clientEvents = {
    loaded = { 'esx:playerLoaded', function() return true end },
    jobChanged = { 'esx:setJob', function(job) return normaliseJob(job) end },
}

function Adapter.reset()
    ESX = nil
end

CisBridgeFrameworks.esx = Adapter
