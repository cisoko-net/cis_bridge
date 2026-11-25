-- ox_inventory backend for the v1 inventory contract (server/v1.lua).
--
-- Facts from ox_inventory v2.48.0 (`modules/inventory/server.lua`):
--   AddItem      -> true, slotData | false, 'invalid_item' | 'inventory_full' | ...
--                   No weight check, and a non-stackable add can land partially
--                   and still answer true (1147-1263).
--   RemoveItem   -> true | false, reason | a bare false (1357-1466)
--   GetItemCount -> always a number (2343-2362)
--   CanCarryItem -> true | false | nil. nil is an invalid item, an invalid
--                   inventory, or a full inventory with no matching stack
--                   (1472-1501), so nil alone never means "unknown item".
-- server/v1.lua verifies every write by the count before and after, so this
-- file translates and nothing more.

CisBridgeInventories = CisBridgeInventories or {}

local I = { name = 'ox_inventory', resource = 'ox_inventory' }

function I.probe()
    local ok, fn = pcall(function()
        return exports[I.resource].GetItemCount
    end)
    return ok and fn ~= nil
end

-- Only a number is a count. tonumber turns any other answer into nil, which
-- server/v1.lua reads as not_loaded, never as a 0 that would prove a removal
-- that never happened.
function I.count(src, item)
    -- The extra parentheses keep one value: a lone nil answer crosses the
    -- export boundary as no value at all, and tonumber() with none raises.
    return tonumber((exports[I.resource]:GetItemCount(src, item)))
end

-- `Items(name)` answers the item's definition, or nil for an unknown name.
function I.known(item)
    return exports[I.resource]:Items(item) ~= nil
end

function I.canCarry(src, item, count)
    local r = exports[I.resource]:CanCarryItem(src, item, count)
    if r == true then return true end
    if r == nil and not I.known(item) then return false, 'unknown_item' end
    return false, 'cannot_carry'
end

local ADD_REASONS = { invalid_item = 'unknown_item', inventory_full = 'cannot_carry' }

-- The slots an add landed in, as { { slot, count }, ... }. ox answers one
-- slot item for a stackable add (its `count` is the whole stack, so the units
-- this add put there are `count` itself) and an array of slot items, one per
-- unit, for a non-stackable one (modules/inventory/server.lua:1205-1258).
local function landed(data, count)
    if type(data) ~= 'table' then return nil end
    if data.slot ~= nil then return { { slot = data.slot, count = count } } end
    local out = {}
    for _, d in ipairs(data) do
        if type(d) == 'table' and d.slot ~= nil then
            out[#out + 1] = { slot = d.slot, count = math.floor(tonumber(d.count) or 1) }
        end
    end
    return #out > 0 and out or nil
end

function I.add(src, item, count, metadata)
    local ok, why = exports[I.resource]:AddItem(src, item, count, metadata)
    if ok == true then return true, landed(why, count) end
    return false, ADD_REASONS[why] or 'refused'
end

-- With `slots` (from I.add) the take-back removes from exactly those slots;
-- `ignoreTotal` caps each removal at what the slot still holds
-- (modules/inventory/server.lua:1358-1390). server/v1.lua counts what left.
function I.remove(src, item, count, slots)
    if type(slots) == 'table' and #slots > 0 then
        local left = count
        for _, s in ipairs(slots) do
            if left <= 0 then break end
            local take = math.min(left, s.count)
            if exports[I.resource]:RemoveItem(src, item, take, nil, s.slot, true) == true then
                left = left - take
            end
        end
        if left <= 0 then return true end
        return false, 'refused'
    end
    local ok, why = exports[I.resource]:RemoveItem(src, item, count)
    if ok == true then return true end
    if why == 'not_enough_items' then return false, 'insufficient_items' end
    return false, 'refused'
end

CisBridgeInventories.ox_inventory = I
