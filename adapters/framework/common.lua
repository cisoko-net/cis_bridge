-- Shapes shared by more than one framework adapter.
--
-- QBCore and Qbox store a job the same way except for where the pay sits:
-- QBCore `job.grade.payment`, Qbox `job.payment`. One normaliser reads both.

CisBridgeFrameworks = CisBridgeFrameworks or {}

local Common = {}

function Common.qbJob(job)
    if type(job) ~= 'table' then return nil end
    local grade = type(job.grade) == 'table' and job.grade or {}
    return {
        name = tostring(job.name or 'unemployed'),
        label = tostring(job.label or job.name or ''),
        grade = math.floor(tonumber(grade.level) or tonumber(job.grade) or 0),
        gradeName = tostring(grade.name or ''),
        gradeLabel = tostring(grade.name or ''),
        isBoss = job.isboss == true or grade.isboss == true,
        onDuty = job.onduty == true,
        pay = math.floor(tonumber(grade.payment) or tonumber(job.payment) or 0),
    }
end

-- `charinfo.firstname .. ' ' .. charinfo.lastname`. `PlayerData.name` is the
-- FiveM account name and is never used as the character name.
function Common.qbName(data)
    local info = type(data) == 'table' and data.charinfo or nil
    if type(info) ~= 'table' then return '' end
    local first, last = tostring(info.firstname or ''), tostring(info.lastname or '')
    if first == '' then return last end
    if last == '' then return first end
    return first .. ' ' .. last
end

-- `charinfo.phone`: both cores generate it on first load as a 10-digit string
-- (qb-core@9b3cddc server/player.lua:623-628, qbx_core@58b345e
-- server/player.lua:632). A number from an old row is passed as its string; no
-- number, or an empty one, is nil.
function Common.qbPhone(data)
    local info = type(data) == 'table' and data.charinfo or nil
    local phone = type(info) == 'table' and info.phone or nil
    -- `%.0f`, not `%d`: a 10-digit number is past 2^31, which `%d` rejects on a
    -- 32-bit-integer Lua (fengari, the test VM).
    if type(phone) == 'number' and phone >= 0 and phone == math.floor(phone) then
        phone = ('%.0f'):format(phone)
    end
    if type(phone) ~= 'string' or phone == '' then return nil end
    return phone
end

-- `PlayerData.gang` on QBCore (qb-core server/player.lua:101-119) and Qbox
-- (qbx_core server/player.lua:461-470): `{ name, label, isboss, grade = { name,
-- level } }`. Nil when the player carries no gang table.
function Common.qbGang(data)
    local gang = type(data) == 'table' and data.gang or nil
    if type(gang) ~= 'table' then return nil end
    local grade = type(gang.grade) == 'table' and gang.grade or {}
    return {
        name = tostring(gang.name or 'none'),
        label = tostring(gang.label or gang.name or ''),
        grade = math.floor(tonumber(grade.level) or tonumber(gang.grade) or 0),
        isboss = gang.isboss == true or grade.isboss == true,
    }
end

-- `PlayerData.metadata` flags `isdead` and `inlaststand` (qb-ambulancejob
-- server/main.lua:133,141; qbx_core server/player.lua:648-651) and
-- `ishandcuffed` (qb-policejob server/main.lua:181; qbx_core :651). A flag
-- nobody set is false. Nil when the player carries no metadata table.
function Common.qbState(data)
    local meta = type(data) == 'table' and data.metadata or nil
    if type(meta) ~= 'table' then return nil end
    return {
        dead = meta.isdead == true,
        lastStand = meta.inlaststand == true,
        cuffed = meta.ishandcuffed == true,
    }
end

-- A function, or the callable table FiveM hands over for a function in another
-- resource (qb-core server/functions.lua tests `__cfx_functionReference`).
function Common.callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and mt.__call ~= nil
end

-- The function behind a QBCore or Qbox usable-item entry: a bare function
-- (Qbox `QBX.UsableItems[item]`, older qb-core), or `{ func, resource }`
-- (current qb-core, server/functions.lua:495-510). Nil for no entry.
function Common.qbUsableFunc(entry)
    if Common.callable(entry) then return entry end
    if type(entry) ~= 'table' then return nil end
    for _, key in ipairs({ 'func', 'cb', 'callback' }) do
        if Common.callable(entry[key]) then return entry[key] end
    end
    return nil
end

-- The item table QBCore and Qbox usable callbacks take as their second
-- argument: the caller's data, always named for the item asked for.
function Common.qbItemTable(item, data)
    local out = {}
    if type(data) == 'table' then
        for k, v in pairs(data) do out[k] = v end
    end
    out.name = item
    return out
end

-- Canonical notify kind -> the ox_lib / QBCore type.
Common.QB_KINDS = { info = 'primary', success = 'success', warning = 'warning', error = 'error' }
Common.OX_KINDS = { info = 'info', success = 'success', warning = 'warning', error = 'error' }

-- One value from oxmysql, awaited. Uses the callback form with its own
-- promise, as oxmysql's lib/MySQL.lua does (2.14.x, lines 15-26): what a Lua
-- caller of the `_async` exports gets back is not confirmed. Answers the value
-- (nil for no row), false, 'unsupported' when oxmysql is not started, or
-- false, 'error' when the query fails: an awaited call gets cb(nil, message)
-- (cis_database server.js, wantErrors), so a failed query is not "no row".
function Common.scalar(query, params)
    if GetResourceState('oxmysql') ~= 'started' then return false, 'unsupported' end
    local p = promise.new()
    exports.oxmysql:scalar(query, params, function(value, err)
        p:resolve({ value = value, err = err })
    end, GetCurrentResourceName(), true)
    local r = Citizen.Await(p)
    if r.err ~= nil and r.err ~= '' then return false, 'error' end
    return r.value
end

-- QBCore.Shared, kept per core resource. GetCoreObject({ 'Shared' }) copies
-- every job, item and gang across the export boundary, so it is asked for once
-- and again only when qb-core says it changed: every runtime AddJob, AddItem,
-- RemoveGang and the rest fires QBCore:Server:UpdateObject
-- (qb-core server/exports.lua), and a start or stop of the core starts over.
-- A failed read is not kept.
local sharedCache = {}

function Common.qbShared(resource)
    local hit = sharedCache[resource]
    if hit then return hit end
    local ok, core = pcall(function()
        return exports[resource]:GetCoreObject({ 'Shared' })
    end)
    local shared = ok and type(core) == 'table' and type(core.Shared) == 'table' and core.Shared or nil
    sharedCache[resource] = shared
    return shared
end

AddEventHandler('QBCore:Server:UpdateObject', function() sharedCache = {} end)
AddEventHandler('onResourceStart', function(name) sharedCache[name] = nil end)
AddEventHandler('onResourceStop', function(name) sharedCache[name] = nil end)

CisBridgeFrameworks.__common = Common
