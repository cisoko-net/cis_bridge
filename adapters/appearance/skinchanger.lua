-- ESX skinchanger + esx_skin backend for the v1 appearance contract.
--
-- Facts from skinchanger and esx_skin 1.16.3, read from its installed source:
--   skinchanger client export GetSkin()      client/main.lua:461-483, the
--                                            current skin table
--   esx_skin net event 'esx_skin:save'(skin) server/main.lua:470-478; it saves
--       only inside an edit session (edit_session_missing otherwise), which
--       the server export BeginSkinEdit(playerId) opens for
--       Config.SkinEditSessionTTL (900000 ms). validateSkin takes integer
--       fields from Config.SkinFields only; saves are rate limited (2000 ms).
--   esx_skin server export SaveOutfit(playerId, clothes, cb) server/main.lua:
--       495-520 (esx_core main is 1.16.3 too); it saves on the server, taking
--       only Config.SkinEditFields.outfit, which holds every key in A.KEYS,
--       and answers cb(saved).
-- So with SaveOutfit the client half sends the clothing keys read off the ped
-- back to cis_bridge, and the server saves them: no edit session, in which
-- the client could save any field of the skin (face, sex), is opened. An
-- esx_skin older than 1.16 has no SaveOutfit: the server half opens the
-- session where BeginSkinEdit exists, and the client half sends GetSkin()
-- with the clothing keys read off the ped through esx_skin:save.
-- skinchanger writes -1 for a prop that is off, as the natives read it.

CisBridgeAppearances = CisBridgeAppearances or {}
local Common = CisBridgeAppearances.__common

local A = {
    name = 'skinchanger',
    resource = 'skinchanger',
    server = {},
    client = {},
    loadEvents = { { 'skinchanger:loadSkin' }, { 'skinchanger:loadClothes' } },
}

-- cis slot -> skinchanger drawable key, texture key (client/main.lua:309-362).
A.KEYS = {
    hat = { 'helmet_1', 'helmet_2' }, glasses = { 'glasses_1', 'glasses_2' },
    ears = { 'ears_1', 'ears_2' }, watch = { 'watches_1', 'watches_2' },
    mask = { 'mask_1', 'mask_2' }, chain = { 'chain_1', 'chain_2' },
    top = { 'torso_1', 'torso_2' }, gloves = { 'arms', 'arms_2' },
    pants = { 'pants_1', 'pants_2' }, shoes = { 'shoes_1', 'shoes_2' },
}

function A.probe() return true end

-- An export another resource does not have raises when it is indexed.
local function skinExport(name)
    local ok, fn = pcall(function() return exports.esx_skin[name] end)
    return ok and fn ~= nil
end

-- esx_skin is what stores the skin; without it there is nowhere to save.
function A.server.save(src)
    if GetResourceState('esx_skin') ~= 'started' then return false, 'unsupported' end
    if skinExport('SaveOutfit') then return true, 'reply' end
    if skinExport('BeginSkinEdit') and exports.esx_skin:BeginSkinEdit(src) ~= true then
        return false, 'refused'
    end
    return true
end

-- The clothing keys the client read, each checked as ApplyClothing checks
-- it; any other key in `clothes` is dropped.
function A.server.finish(src, clothes)
    if type(clothes) ~= 'table' then return false, 'bad_clothing' end
    local outfit = {}
    for slot, keys in pairs(A.KEYS) do
        local drawable, texture = clothes[keys[1]], clothes[keys[2]]
        if not Common.valid(slot, { drawable = drawable, texture = texture }) then return false, 'bad_clothing' end
        outfit[keys[1]], outfit[keys[2]] = drawable, texture
    end
    local sent = exports.esx_skin:SaveOutfit(src, outfit, function(saved)
        if saved ~= true then
            print(('^3cis_bridge: esx_skin did not save the outfit for player %d^7'):format(src))
        end
    end)
    if sent ~= true then return false, 'refused' end
    return true
end

local function readClothes(ped, into)
    for slot, keys in pairs(A.KEYS) do
        local now = Common.read(ped, slot)
        into[keys[1]], into[keys[2]] = now.drawable, now.texture
    end
    return into
end

function A.client.save(ped, reply)
    if reply then
        TriggerServerEvent('cis_bridge:appearance:reply', A.name, readClothes(ped, {}))
        return true
    end
    local current = exports[A.resource]:GetSkin()
    if type(current) ~= 'table' then return false, 'no_skin' end
    local skin = {}
    for k, v in pairs(current) do skin[k] = v end
    TriggerServerEvent('esx_skin:save', readClothes(ped, skin))
    return true
end

CisBridgeAppearances.skinchanger = A
