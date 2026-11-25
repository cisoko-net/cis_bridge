-- The v1 appearance contract, shared part (docs/V1.md, Appearance).
--
-- Every clothing resource dresses the same ped through the same natives, so
-- reading and applying one slot is done here, once, on the ped itself: the
-- ped is the truth, whatever resource put the clothes on it. What differs per
-- resource is only how the current look is saved, and that is each adapter's
-- `client.save` (adapters/appearance/*.lua).
--
-- The slot names are the v1 appearance slots (docs/V1.md, Appearance).
-- A prop slot with nothing on reads as drawable -1, as every resource here
-- writes it (illenium and fivem-appearance `setPedProp`, skinchanger `-1`).

CisBridgeAppearances = CisBridgeAppearances or {}

local Common = {}

Common.SLOTS = {
    hat = { kind = 'prop', id = 0 },
    mask = { kind = 'component', id = 1 },
    glasses = { kind = 'prop', id = 1 },
    ears = { kind = 'prop', id = 2 },
    chain = { kind = 'component', id = 7 },
    top = { kind = 'component', id = 11 },
    gloves = { kind = 'component', id = 3 },
    pants = { kind = 'component', id = 4 },
    shoes = { kind = 'component', id = 6 },
    watch = { kind = 'prop', id = 6 },
}

-- Upper bounds a product may pass. GTA has no drawable or texture index near
-- these; they only keep a bad value from reaching the native.
Common.MAX_DRAWABLE = 4095
Common.MAX_TEXTURE = 255

local function isInt(v, lo, hi)
    return type(v) == 'number' and v == v and v % 1 == 0 and v >= lo and v <= hi
end

-- `{ drawable, texture }` of one slot on `ped`. Client only.
function Common.read(ped, slot)
    local s = Common.SLOTS[slot]
    if s.kind == 'prop' then
        local drawable = GetPedPropIndex(ped, s.id)
        if not drawable or drawable < 0 then return { drawable = -1, texture = 0 } end
        return { drawable = drawable, texture = math.max(GetPedPropTextureIndex(ped, s.id) or 0, 0) }
    end
    return { drawable = GetPedDrawableVariation(ped, s.id), texture = GetPedTextureVariation(ped, s.id) }
end

-- Validates `data` for `slot`: a component takes drawable 0 and up, a prop
-- also -1 (nothing on).
function Common.valid(slot, data)
    local s = Common.SLOTS[slot]
    if type(data) ~= 'table' then return false end
    local lo = s.kind == 'prop' and -1 or 0
    return isInt(data.drawable, lo, Common.MAX_DRAWABLE) and isInt(data.texture or 0, 0, Common.MAX_TEXTURE)
end

-- Puts `data` on `ped`. Client only; `data` already passed Common.valid.
function Common.apply(ped, slot, data)
    local s = Common.SLOTS[slot]
    local texture = data.texture or 0
    if s.kind == 'prop' then
        if data.drawable < 0 then
            ClearPedProp(ped, s.id)
        else
            SetPedPropIndex(ped, s.id, data.drawable, texture, true)
        end
        return
    end
    SetPedComponentVariation(ped, s.id, data.drawable, texture, 0)
end

CisBridgeAppearances.__common = Common
