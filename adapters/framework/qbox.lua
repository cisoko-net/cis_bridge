-- Qbox adapter (qbx_core), for the v1 product API in server/v1.lua.
--
-- Facts from qbx_core@58b345e (19 commits after v1.24.0, before v1.24.1).
-- Qbox has no core object: every call is `exports.qbx_core:<Fn>`.
--
-- Money types are case-sensitive (no :lower()), bank has no minus limit, and a
-- registered hook can veto a change (server/player.lua:1320-1423). The bridge
-- passes the canonical lowercase names and checks the balance first.

CisBridgeFrameworks = CisBridgeFrameworks or {}
local Common = CisBridgeFrameworks.__common

local Adapter = {
    name = 'qbox',
    resource = 'qbx_core',
    accounts = { cash = 'cash', bank = 'bank', crypto = 'crypto' },
    server = {},
    client = {},
}

-- A started qbx_core whose GetPlayer export does not answer is not a Qbox.
-- Reading a missing export raises (scheduler.lua:717), hence the pcall.
function Adapter.probe()
    local ok, fn = pcall(function()
        return exports[Adapter.resource].GetPlayer
    end)
    return ok and fn ~= nil
end

local function data(src)
    local ok, p = pcall(function()
        return exports[Adapter.resource]:GetPlayer(src)
    end)
    if not ok or type(p) ~= 'table' or type(p.PlayerData) ~= 'table' then return nil end
    return p.PlayerData
end

local S = Adapter.server

-- A raw read for `cis_bridge test`: no shape checks, so a bug in them shows.
function S.hasPlayer(src)
    return exports[Adapter.resource]:GetPlayer(src) ~= nil
end

function S.player(src)
    local d = data(src)
    if not d then return nil end
    return {
        id = tostring(d.citizenid or ''),
        name = Common.qbName(d),
        job = Common.qbJob(d.job),
        phone = Common.qbPhone(d),
    }
end

-- `GetMoney(id, type)`: a number, false with no player, nil for an unknown
-- type (1482-1492).
function S.balance(src, account)
    -- The extra parentheses keep one value: a lone nil answer crosses the
    -- export boundary as no value at all, and tonumber() with none raises.
    return tonumber((exports[Adapter.resource]:GetMoney(src, account)))
end

function S.add(src, account, amount, reason)
    if exports[Adapter.resource]:AddMoney(src, account, amount, reason) == true then return true end
    return false, 'refused'
end

function S.remove(src, account, amount, reason)
    if exports[Adapter.resource]:RemoveMoney(src, account, amount, reason) == true then return true end
    return false, 'refused'
end

function S.job(src)
    local d = data(src)
    if not d then return nil end
    return Common.qbJob(d.job)
end

-- `GetJobs()`: grades keyed by integer (shared/jobs.lua:8-9).
function S.jobExists(name, grade)
    local jobs = exports[Adapter.resource]:GetJobs()
    local job = type(jobs) == 'table' and jobs[name] or nil
    if type(job) ~= 'table' then return false, 'unknown_job' end
    if type(job.grades) ~= 'table' or job.grades[grade] == nil then
        return false, 'unknown_grade'
    end
    return true
end

-- `SetJob(id, name, grade)` -> boolean, ErrorResult? (player.lua:147-192).
function S.setJob(src, name, grade)
    if exports[Adapter.resource]:SetJob(src, name, grade) ~= true then return false, 'refused' end
    local now = S.job(src)
    if now and now.name == name and now.grade == grade then return true end
    return false, 'refused'
end

-- `Notify(src, text, type, duration, ...)` -> ox_lib:notify (functions.lua:435-461).
function S.notify(src, message, kind)
    exports[Adapter.resource]:Notify(src, message, Common.OX_KINDS[kind] or 'info', 5000)
    return true
end

function S.gang(src)
    local d = data(src)
    if not d then return nil end
    return Common.qbGang(d)
end

function S.state(src)
    local d = data(src)
    if not d then return nil end
    return Common.qbState(d)
end

-- Usable items. qbx_core main exports `CanUseItem(item)` -> `QBX.UsableItems[item]`,
-- a `fun(source, item)` (server/functions.lua:264-278). It exports no `UseItem`
-- (not in server/functions.lua, player.lua or main.lua), so the registered
-- callback is called directly as `callback(source, item)`.
function S.canUseItem(item)
    return Common.qbUsableFunc(exports[Adapter.resource]:CanUseItem(item)) ~= nil
end

function S.useItem(src, item, itemData)
    local fn = Common.qbUsableFunc(exports[Adapter.resource]:CanUseItem(item))
    if not fn then return false, 'not_usable' end
    fn(src, Common.qbItemTable(item, itemData))
    return true
end

-- `GetPlayerByCitizenId(citizenid)` -> the loaded Player, or nil
-- (server/functions.lua:98-110).
function S.sourceOf(charId)
    local p = exports[Adapter.resource]:GetPlayerByCitizenId(charId)
    if type(p) ~= 'table' or type(p.PlayerData) ~= 'table' then return nil end
    return tonumber(p.PlayerData.source)
end

-- qbx_vehicles 1.4.2 `GetVehicleIdByPlate(plate)` -> the `player_vehicles.id`, or
-- nil (server/main.lua:203-213). It trims the plate itself.
function S.ownedVehicleId(plate)
    if GetResourceState('qbx_vehicles') ~= 'started' then return false, 'unsupported' end
    -- The extra parentheses keep one value: a lone nil answer crosses the
    -- export boundary as no value at all, and tonumber() with none raises.
    return tonumber((exports.qbx_vehicles:GetVehicleIdByPlate(plate)))
end

-- Qbox fires OnPlayerUnload on logout only; server/v1.lua also emits unloaded
-- from `playerDropped` for every framework, once per load.
Adapter.events = {
    loaded = { 'QBCore:Server:PlayerLoaded', function(p)
        local d = type(p) == 'table' and p.PlayerData or nil
        return type(d) == 'table' and tonumber(d.source) or nil
    end },
    unloaded = { 'QBCore:Server:OnPlayerUnload', function(src) return src end },
    jobChanged = { 'QBCore:Server:OnJobUpdate', function(src, job) return src, Common.qbJob(job) end },
}

local C = Adapter.client

function C.data()
    local ok, d = pcall(function()
        return exports[Adapter.resource]:GetPlayerData()
    end)
    if not ok or type(d) ~= 'table' or d.citizenid == nil then return nil end
    return {
        id = tostring(d.citizenid),
        name = Common.qbName(d),
        job = Common.qbJob(d.job),
    }
end

function C.notify(message, kind)
    exports[Adapter.resource]:Notify(message, Common.OX_KINDS[kind] or 'info', 5000)
    return true
end

Adapter.clientEvents = {
    loaded = { 'QBCore:Client:OnPlayerLoaded', function() return true end },
    jobChanged = { 'QBCore:Client:OnJobUpdate', function(job) return Common.qbJob(job) end },
}

function Adapter.reset() end

CisBridgeFrameworks.qbox = Adapter
