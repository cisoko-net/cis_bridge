-- QBCore adapter (qb-core), for the v1 product API in server/v1.lua.
--
-- Facts from qb-core@9b3cddc.
--
-- The call convention. `exports['qb-core']:GetPlayer(src)` answers a flattened
-- copy holding `PlayerData` and `Functions` (server/player.lua:653-677). The
-- Functions are funcrefs declared on the Functions table, so they are dot calls.
-- `PlayerData` is a snapshot taken when the copy crossed into this resource,
-- so a balance is read through `Functions.GetMoney`, never from the snapshot.
--
-- Qbox declares `provide 'qb-core'`. Detection in server/v1.lua never picks
-- this adapter while qbx_core is started.

CisBridgeFrameworks = CisBridgeFrameworks or {}
local Common = CisBridgeFrameworks.__common

local Adapter = {
    name = 'qbcore',
    resource = 'qb-core',
    accounts = { cash = 'cash', bank = 'bank', crypto = 'crypto' },
    server = {},
    client = {},
}

local QBCore

function Adapter.probe()
    local ok, core = pcall(function()
        return exports[Adapter.resource]:GetCoreObject()
    end)
    if ok and type(core) == 'table' then
        QBCore = core
        return true
    end
    return false
end

-- `nil` for a valid source whose character is not loaded yet.
local function player(src)
    local ok, p = pcall(function()
        return exports[Adapter.resource]:GetPlayer(src)
    end)
    if not ok or type(p) ~= 'table' or type(p.PlayerData) ~= 'table' then return nil end
    return p
end

local S = Adapter.server

-- A raw read for `cis_bridge test`: no shape checks, so a bug in them shows.
function S.hasPlayer(src)
    return exports[Adapter.resource]:GetPlayer(src) ~= nil
end

function S.player(src)
    local p = player(src)
    if not p then return nil end
    return {
        id = tostring(p.PlayerData.citizenid or ''),
        name = Common.qbName(p.PlayerData),
        job = Common.qbJob(p.PlayerData.job),
        phone = Common.qbPhone(p.PlayerData),
    }
end

-- `GetMoney(type)` answers a number, or nil for an unknown type (266-269).
function S.balance(src, account)
    local p = player(src)
    if not p or type(p.Functions) ~= 'table' then return nil end
    -- The extra parentheses keep one value: a lone nil answer crosses the
    -- export boundary as no value at all, and tonumber() with none raises.
    return tonumber((p.Functions.GetMoney(account)))
end

-- `AddMoney` / `RemoveMoney`: nil for a bad amount, false for a bad type or a
-- refused removal, true otherwise (185-240). Only `true` is success.
function S.add(src, account, amount, reason)
    local p = player(src)
    if not p or type(p.Functions) ~= 'table' then return false, 'not_loaded' end
    if p.Functions.AddMoney(account, amount, reason) == true then return true end
    return false, 'refused'
end

function S.remove(src, account, amount, reason)
    local p = player(src)
    if not p or type(p.Functions) ~= 'table' then return false, 'not_loaded' end
    if p.Functions.RemoveMoney(account, amount, reason) == true then return true end
    return false, 'refused'
end

function S.job(src)
    local p = player(src)
    if not p then return nil end
    return Common.qbJob(p.PlayerData.job)
end

-- `QBCore.Shared.Jobs[job].grades` is keyed by string '0' (shared/jobs.lua:3-10).
-- Common.qbShared reads the core again after qb-core's update event, so a job
-- added at runtime is seen.
function S.jobExists(name, grade)
    local shared = Common.qbShared(Adapter.resource) or (QBCore and QBCore.Shared)
    local jobs = type(shared) == 'table' and shared.Jobs or nil
    local job = type(jobs) == 'table' and jobs[name] or nil
    if type(job) ~= 'table' then return false, 'unknown_job' end
    if type(job.grades) ~= 'table' or job.grades[tostring(grade)] == nil then
        return false, 'unknown_grade'
    end
    return true
end

-- `SetJob` answers true for an unknown grade (66-122), so the bridge checks the
-- grade first and reads the job back after.
function S.setJob(src, name, grade)
    local p = player(src)
    if not p or type(p.Functions) ~= 'table' then return false, 'not_loaded' end
    if p.Functions.SetJob(name, grade) ~= true then return false, 'refused' end
    local now = S.job(src)
    if now and now.name == name and now.grade == grade then return true end
    return false, 'refused'
end

-- `QBCore.Functions.Notify` on the server is this event (functions.lua:731-733).
function S.notify(src, message, kind)
    TriggerClientEvent('QBCore:Notify', src, message, Common.QB_KINDS[kind] or 'primary', 5000)
    return true
end

-- Gang and state are PlayerData fields; `player(src)` is a fresh copy per call.
function S.gang(src)
    local p = player(src)
    if not p then return nil end
    return Common.qbGang(p.PlayerData)
end

function S.state(src)
    local p = player(src)
    if not p then return nil end
    return Common.qbState(p.PlayerData)
end

-- Usable items. qb-core main: `Functions.CanUseItem(item)` answers
-- `QBCore.UsableItems[item]`, `{ func, resource }` (server/functions.lua:495-519).
-- `Functions.UseItem(source, item)` is not called: it forwards to
-- `exports['qb-inventory']:UseItem(source, item)` (:524-527), whose signature is
-- `UseItem(itemName, source, item, ...)` (qb-inventory server/functions.lua:226),
-- so the arguments land swapped, and with no qb-inventory it does nothing. The
-- registered callback is called directly, as `callback(source, item)`, which
-- skips qb-inventory's ItemUsed hook and listener.
local function usableFunc(item)
    local core = QBCore
    if type(core) ~= 'table' then
        local ok, fresh = pcall(function() return exports[Adapter.resource]:GetCoreObject() end)
        core = ok and fresh or nil
    end
    local fns = type(core) == 'table' and core.Functions or nil
    if type(fns) ~= 'table' or not Common.callable(fns.CanUseItem) then return nil end
    return Common.qbUsableFunc(fns.CanUseItem(item))
end

function S.canUseItem(item)
    return usableFunc(item) ~= nil
end

function S.useItem(src, item, data)
    local fn = usableFunc(item)
    if not fn then return false, 'not_usable' end
    fn(src, Common.qbItemTable(item, data))
    return true
end

-- qb-core@9b3cddc `exports['qb-core']:GetPlayerByCitizenId(citizenid)` -> the
-- rebuilt interface of a loaded player, or nil (server/player.lua:679-681).
function S.sourceOf(charId)
    local ok, p = pcall(function()
        return exports[Adapter.resource]:GetPlayerByCitizenId(charId)
    end)
    if not ok or type(p) ~= 'table' or type(p.PlayerData) ~= 'table' then return nil end
    return tonumber(p.PlayerData.source)
end

-- `player_vehicles` has two official DDLs, one without an `id` column
-- (qb-garages player_vehicles.sql); `plate` is in both, so it is the id.
function S.ownedVehicleId(plate)
    return Common.scalar('SELECT plate FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
end

Adapter.events = {
    loaded = { 'QBCore:Server:PlayerLoaded', function(p)
        local data = type(p) == 'table' and p.PlayerData or nil
        return type(data) == 'table' and tonumber(data.source) or nil
    end },
    -- Fires on logout and on drop (server/events.lua:16-17).
    unloaded = { 'QBCore:Server:OnPlayerUnload', function(src) return src end },
    jobChanged = { 'QBCore:Server:OnJobUpdate', function(src, job) return src, Common.qbJob(job) end },
}

local C = Adapter.client

function C.data()
    if not QBCore and not Adapter.probe() then return nil end
    local data = QBCore.Functions.GetPlayerData()
    if type(data) ~= 'table' or data.citizenid == nil then return nil end
    return {
        id = tostring(data.citizenid),
        name = Common.qbName(data),
        job = Common.qbJob(data.job),
    }
end

function C.notify(message, kind)
    if not QBCore and not Adapter.probe() then return false end
    QBCore.Functions.Notify(message, Common.QB_KINDS[kind] or 'primary', 5000)
    return true
end

Adapter.clientEvents = {
    loaded = { 'QBCore:Client:OnPlayerLoaded', function() return true end },
    jobChanged = { 'QBCore:Client:OnJobUpdate', function(job) return Common.qbJob(job) end },
}

function Adapter.reset()
    QBCore = nil
end

CisBridgeFrameworks.qbcore = Adapter
