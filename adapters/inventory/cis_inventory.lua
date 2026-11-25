-- cis_inventory backend for the v1 inventory contract (server/v1.lua).
--
-- cis_inventory is Cisoko's own inventory. This file maps its server exports:
--   GetVersion()                          -> string (the probe)
--   GetItem(name)                         -> def | false, 'unknown_item'
--   GetItemCount(inv, item)               -> integer; 0 and a reason on any refusal
--   CanCarryItem(inv, item, n)            -> true | false, 'too_heavy' | 'no_slot' | ...
--   AddItem(inv, item, n, metadata)       -> true, { {slot, count} } | false, reason
--   RemoveItem(inv, item, n, nil, slot)   -> true, { {slot, count} } | false, reason
-- The engine is all-or-nothing: a write lands whole or not at all, so this
-- file never answers `partial`. server/v1.lua still proves every write by the
-- count before and after, as it does for every inventory.
--
-- Detected first. cis_inventory ships faces that answer to the ox_inventory
-- and qb-inventory names, so on its server those can look started as well.
-- INVENTORY_ORDER in server/v1.lua puts cis_inventory ahead of both.

CisBridgeInventories = CisBridgeInventories or {}

local I = { name = 'cis_inventory', resource = 'cis_inventory' }

-- A started cis_inventory whose GetVersion export does not answer is not a
-- usable cis_inventory. Reading a missing export raises, hence the pcall.
function I.probe()
    local ok, fn = pcall(function()
        return exports[I.resource].GetVersion
    end)
    return ok and fn ~= nil
end

-- 0 with a reason is a refusal, not an empty pocket. `unknown_item` is a real
-- zero: the write that follows refuses by name. Any other refusal
-- (not_loaded, frozen, bad_inventory) is no count at all, which server/v1.lua
-- answers as not_loaded, so no write is ever proved against a false zero.
function I.count(src, item)
    local n, why = exports[I.resource]:GetItemCount(src, item)
    if why ~= nil and why ~= 'unknown_item' then return nil end
    n = tonumber(n)
    if n == nil then return nil end
    return math.floor(n)
end

function I.known(item)
    -- The extra parentheses keep one value: a lone nil answer crosses the
    -- export boundary as no value at all, and type() with none raises.
    return type((exports[I.resource]:GetItem(item))) == 'table'
end

-- A refusal the table does not name is still a no: CanCarry answers only
-- cannot_carry, unknown_item or not_loaded (docs/V1.md § Server contracts).
local CARRY_REASONS = {
    too_heavy = 'cannot_carry', no_slot = 'cannot_carry',
    unknown_item = 'unknown_item', not_loaded = 'not_loaded',
}

function I.canCarry(src, item, count)
    local ok, why = exports[I.resource]:CanCarryItem(src, item, count)
    if ok == true then return true end
    return false, CARRY_REASONS[why] or 'cannot_carry'
end

-- `frozen` is an inventory mid-save or mid-rollback: a retry can land, which
-- is what `busy` tells a product.
local ADD_REASONS = {
    too_heavy = 'cannot_carry', no_slot = 'cannot_carry', unknown_item = 'unknown_item',
    busy = 'busy', frozen = 'busy', not_loaded = 'not_loaded',
}

local REMOVE_REASONS = {
    insufficient_items = 'insufficient_items', busy = 'busy', busy_slot = 'busy', frozen = 'busy',
}

-- The slots an add landed in, as { { slot, count }, ... } keyed by name, the
-- shape every inventory adapter answers. cis_inventory's entries are read
-- keyed or positional (a { slot, count } entry can be either), and an
-- entry that is not two whole numbers is dropped: a take-back with a wrong
-- slot would remove from the wrong stack.
local function landed(placed)
    if type(placed) ~= 'table' then return nil end
    local out = {}
    for _, p in ipairs(placed) do
        if type(p) == 'table' then
            local slot, n = tonumber(p.slot or p[1]), tonumber(p.count or p[2])
            if slot and n and slot % 1 == 0 and n % 1 == 0 and n > 0 then
                out[#out + 1] = { slot = math.floor(slot), count = math.floor(n) }
            end
        end
    end
    return #out > 0 and out or nil
end

function I.add(src, item, count, metadata)
    local ok, placed = exports[I.resource]:AddItem(src, item, count, metadata)
    if ok == true then return true, landed(placed) end
    return false, ADD_REASONS[placed] or 'refused'
end

-- With `slots` (from I.add) the take-back removes from exactly those slots,
-- one call each, so it takes these units and not an older stack of the same
-- name. Every slot is tried even after one refuses, so as much as can come
-- back does; server/v1.lua counts what left and prices the rest.
function I.remove(src, item, count, slots)
    if type(slots) == 'table' and #slots > 0 then
        local left, refused = count, nil
        for _, s in ipairs(slots) do
            if left <= 0 then break end
            local take = math.min(left, s.count)
            local ok, why = exports[I.resource]:RemoveItem(src, item, take, nil, s.slot)
            if ok == true then
                left = left - take
            elseif refused == nil then
                refused = REMOVE_REASONS[why] or 'refused'
            end
        end
        if left <= 0 then return true end
        return false, refused or 'refused'
    end
    local ok, why = exports[I.resource]:RemoveItem(src, item, count)
    if ok == true then return true end
    return false, REMOVE_REASONS[why] or 'refused'
end

CisBridgeInventories.cis_inventory = I
