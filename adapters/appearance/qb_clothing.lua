-- qb-clothing backend for the v1 appearance contract.
--
-- Facts from qb-clothing 1.2.0, read from its installed source (client.lua,
-- server.lua):
--   server net event 'qb-clothing:saveSkin'(model, skinJson)  server.lua:3-17
--       deletes the citizen's playerskins rows and inserts this one as active
--   'qb-clothes:loadPlayerSkin' reads `SELECT * FROM playerskins WHERE
--       citizenid = ? And active = ?` (server.lua:19-28)
--   client 'qb-clothing:client:loadPlayerClothing'(data, ped)   client.lua:1052
--       puts every key of the skin on the ped (:1056-1175); the bridge's
--       appearance-loaded signal listens for it
-- The skin is `{ [key] = { item, texture, defaultItem, defaultTexture } }` and
-- also holds the face, its mix and the head overlays, which no native read
-- gives back as qb-clothing wrote them. So the save is done on the server: the
-- client half reads every component and prop key (and the hair) off the ped
-- and replies, and the server half merges them into the citizen's active
-- playerskins row, which keeps the face. With no row there is no face to keep,
-- and nothing is saved.
--
-- A prop qb-clothing reads as off at item -1 or 0 (loadPlayerClothing); off is
-- written as -1.

CisBridgeAppearances = CisBridgeAppearances or {}
local Common = CisBridgeAppearances.__common

local A = {
    name = 'qb-clothing',
    resource = 'qb-clothing',
    server = {},
    client = {},
    loadEvents = { { 'qb-clothing:client:loadPlayerClothing', net = true } },
}

-- qb-clothing skin key -> what loadPlayerClothing puts it on (client.lua
-- :1074-1175). The hair is component 2, its texture the hair colour.
A.PARTS = {
    mask = { kind = 'component', id = 1 }, hair = { kind = 'component', id = 2, hair = true },
    arms = { kind = 'component', id = 3 }, pants = { kind = 'component', id = 4 },
    bag = { kind = 'component', id = 5 }, shoes = { kind = 'component', id = 6 },
    accessory = { kind = 'component', id = 7 }, ['t-shirt'] = { kind = 'component', id = 8 },
    vest = { kind = 'component', id = 9 }, decals = { kind = 'component', id = 10 },
    torso2 = { kind = 'component', id = 11 },
    hat = { kind = 'prop', id = 0 }, glass = { kind = 'prop', id = 1 }, ear = { kind = 'prop', id = 2 },
    watch = { kind = 'prop', id = 6 }, bracelet = { kind = 'prop', id = 7 },
}

local function isInt(v, lo, hi)
    return type(v) == 'number' and v == v and v % 1 == 0 and v >= lo and v <= hi
end

function A.probe() return true end

-- The citizen's skin lives in qb-clothing's playerskins table, read and
-- written through oxmysql.
function A.server.save()
    if GetResourceState('oxmysql') ~= 'started' then return false, 'unsupported' end
    return true, 'reply'
end

-- An awaited oxmysql call answers cb(nil, message) on a failed query: that
-- answers false, so a failed read is not taken for "no row".
local function awaitDb(fn, query, params)
    local p = promise.new()
    exports.oxmysql[fn](exports.oxmysql, query, params, function(value, err)
        p:resolve({ value = value, err = err })
    end, GetCurrentResourceName(), true)
    local r = Citizen.Await(p)
    if r.err ~= nil and r.err ~= '' then return false end
    return r.value
end

-- Every key in A.PARTS, each checked; any other key in `clothes` is dropped.
function A.server.finish(_src, clothes, player)
    if type(clothes) ~= 'table' then return false, 'bad_clothing' end
    local citizenid = type(player) == 'table' and player.id or nil
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'not_loaded' end
    for key, part in pairs(A.PARTS) do
        local e = clothes[key]
        local lo = part.kind == 'prop' and -1 or 0
        if type(e) ~= 'table' or not isInt(e.item, lo, Common.MAX_DRAWABLE)
            or not isInt(e.texture, 0, Common.MAX_TEXTURE) then
            return false, 'bad_clothing'
        end
    end
    local raw = awaitDb('scalar', 'SELECT skin FROM playerskins WHERE citizenid = ? AND active = 1', { citizenid })
    if raw == false then return false, 'error' end
    if type(raw) ~= 'string' then return false, 'no_skin' end
    local okJ, skin = pcall(json.decode, raw)
    if not okJ or type(skin) ~= 'table' then return false, 'no_skin' end
    for key in pairs(A.PARTS) do
        local entry = {}
        for k, v in pairs(type(skin[key]) == 'table' and skin[key] or {}) do entry[k] = v end
        entry.item, entry.texture = clothes[key].item, clothes[key].texture
        skin[key] = entry
    end
    local changed = awaitDb('update', 'UPDATE playerskins SET skin = ? WHERE citizenid = ? AND active = 1',
        { json.encode(skin), citizenid })
    if type(changed) ~= 'number' or changed < 1 then return false, 'error' end
    return true
end

local function readPart(ped, part)
    if part.kind == 'prop' then
        local item = GetPedPropIndex(ped, part.id)
        if not item or item < 0 then return { item = -1, texture = 0 } end
        return { item = item, texture = math.max(GetPedPropTextureIndex(ped, part.id) or 0, 0) }
    end
    local texture = part.hair and GetPedHairColor(ped) or GetPedTextureVariation(ped, part.id)
    return { item = GetPedDrawableVariation(ped, part.id), texture = math.max(texture or 0, 0) }
end

function A.client.save(ped, reply)
    if not reply then return false, 'unsupported' end
    local clothes = {}
    for key, part in pairs(A.PARTS) do clothes[key] = readPart(ped, part) end
    TriggerServerEvent('cis_bridge:appearance:reply', A.name, clothes)
    return true
end

CisBridgeAppearances['qb-clothing'] = A
