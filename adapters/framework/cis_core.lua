-- cis_core adapter, a peer of the ESX, QBCore and Qbox adapters.
--
-- cis_core at 929438d exposes one export, `CisCoreFramework()`, which answers
-- its Framework table (framework/framework_server.lua:971-980). The functions
-- arrive as funcrefs and are dot calls.
--
-- What it gives and what it does not:
--   GetPlayer / NormalizedPlayer(src)    -> player, `{ id, name, job, identifier, money }`
--   GiveMoney / RemoveMoney(src, amount, type) -> the pcall status, not the result
--   GetPlayerJob(src)                    -> the framework's raw job
--   SetPlayerJob(src, job, grade)        -> nothing; read the job back
--   Notify(src, message, kind)           -> through cis_libs
-- It has no job registry, so `jobExists` cannot tell an unknown job from a
-- known one and SetJob proves itself by the read-back alone.
--
-- server/v1.lua picks this adapter only when no third-party framework is
-- started (docs/V1.md, The cis_core target): cis_core is itself a wrapper over
-- ESX / QBCore / Qbox, and on ESX its RemoveMoney answers the pcall status
-- rather than the framework's result (framework_server.lua:690-693).

CisBridgeFrameworks = CisBridgeFrameworks or {}
local Common = CisBridgeFrameworks.__common

local Adapter = {
    name = 'cis_core',
    resource = 'cis_core',
    accounts = { cash = 'cash', bank = 'bank' },
    server = {},
    client = {},
}

local F

function Adapter.probe()
    local ok, fw = pcall(function()
        return exports[Adapter.resource]:CisCoreFramework()
    end)
    if ok and type(fw) == 'table' and Common.callable(fw.GetPlayer) then
        F = fw
        return true
    end
    return false
end

local function normalised(src)
    if not F or not Common.callable(F.NormalizedPlayer) then return nil end
    if F.GetPlayer(src) == nil then return nil end
    local p = F.NormalizedPlayer(src)
    if type(p) ~= 'table' then return nil end
    return p
end

-- cis_core passes the raw job through: ESX shape or QBCore shape.
local function job(raw)
    if type(raw) ~= 'table' then return nil end
    if type(raw.grade) == 'table' or raw.payment ~= nil then return Common.qbJob(raw) end
    return {
        name = tostring(raw.name or 'unemployed'),
        label = tostring(raw.label or raw.name or ''),
        grade = math.floor(tonumber(raw.grade) or 0),
        gradeName = tostring(raw.grade_name or ''),
        gradeLabel = tostring(raw.grade_label or raw.grade_name or ''),
        isBoss = raw.grade_name == 'boss',
        onDuty = raw.onDuty ~= false,
        pay = math.floor(tonumber(raw.grade_salary) or 0),
    }
end

local S = Adapter.server

-- A raw read for `cis_bridge test`: no shape checks, so a bug in them shows.
function S.hasPlayer(src)
    return F ~= nil and F.GetPlayer ~= nil and F.GetPlayer(src) ~= nil
end

function S.player(src)
    local p = normalised(src)
    if not p then return nil end
    return {
        id = tostring(p.identifier or ''),
        name = tostring(p.name or ''),
        job = job(p.job),
    }
end

-- `money` is a map keyed by account name.
function S.balance(src, account)
    local p = normalised(src)
    if not p or type(p.money) ~= 'table' then return nil end
    local v = p.money[account]
    if type(v) == 'table' then v = v.money end
    return tonumber(v)
end

-- GiveMoney / RemoveMoney answer the status of cis_core's own pcall, not the
-- framework's result (framework_server.lua:660-663, 690-693), so a refused
-- write still answers true. That answer is only a hint: server/v1.lua
-- moneyWrite reads the balance before and after every write, on every
-- framework, and the balance decides (docs/V1.md § Money).
function S.add(src, account, amount, _reason)
    F.GiveMoney(src, amount, account)
    return true
end

function S.remove(src, account, amount, _reason)
    F.RemoveMoney(src, amount, account)
    return true
end

function S.job(src)
    if not F then return nil end
    return job(F.GetPlayerJob(src))
end

function S.jobExists(_name, _grade)
    return true
end

function S.setJob(src, name, grade)
    F.SetPlayerJob(src, name, grade)
    local now = S.job(src)
    if now and now.name == name and now.grade == grade then return true end
    return false, 'refused'
end

function S.notify(src, message, kind)
    F.Notify(src, message, kind)
    return true
end

-- cis_core publishes its job changes through cis_libs, not as a server event a
-- bridge can hear. v1 emits loaded / jobChanged for cis_core only from the
-- bridge's own writes; unloaded still comes from `playerDropped`.
-- cis_core keeps no gangs, no dead / cuffed state and no usable-item registry
-- the adapter can reach.
function S.gang() return false, 'unsupported' end
function S.state() return false, 'unsupported' end
function S.canUseItem() return false end
function S.useItem() return false, 'not_usable' end

-- cis_core keeps no vehicles yet.
function S.ownedVehicleId() return false, 'unsupported' end

Adapter.events = {}

local C = Adapter.client

function C.data()
    return nil
end

function C.notify(_message, _kind)
    return false
end

Adapter.clientEvents = {}

function Adapter.reset()
    F = nil
end

CisBridgeFrameworks.cis_core = Adapter
