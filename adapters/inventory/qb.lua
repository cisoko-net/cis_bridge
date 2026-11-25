-- qb-inventory backend for the v1 inventory contract (server/v1.lua).
--
-- Facts from qb-inventory v2.2.3 at dc3d07f (`server/functions.lua`):
--   AddItem(id, item, amount, slot?, info?, reason?) -> boolean (711-802)
--     slot comes before metadata, unlike ox.
--   RemoveItem(id, item, amount, slot?, reason?)     -> boolean (812-899)
--     with no slot it reads the first matching slot only, and refuses when
--     that slot holds fewer than `amount` (825-850).
--   GetItemsByName(source, item) -> { { slot, amount, ... } } (319-331)
--   GetItemCount(source, items) -> a number, nil when not loaded (357-376)
--   CanAddItem(id, item, amount) -> true | false, 'weight' | 'slots' (384-419)
-- Item names are compared case-exact against QBCore.Shared.Items, which is
-- keyed lowercase; server/v1.lua lowercases before it gets here.

CisBridgeInventories = CisBridgeInventories or {}

local I = { name = 'qb-inventory', resource = 'qb-inventory' }

function I.probe()
    local ok, fn = pcall(function()
        return exports[I.resource].CanAddItem
    end)
    return ok and fn ~= nil
end

function I.count(src, item)
    local n = exports[I.resource]:GetItemCount(src, item)
    if n == nil then return nil end
    return math.floor(tonumber(n) or 0)
end

function I.known(item)
    local qb = CisBridgeFrameworks and CisBridgeFrameworks.qbcore
    local common = CisBridgeFrameworks and CisBridgeFrameworks.__common
    local shared = common and common.qbShared(type(qb) == 'table' and qb.resource or 'qb-core') or nil
    local items = type(shared) == 'table' and shared.Items or nil
    if type(items) ~= 'table' then return nil end
    return items[item] ~= nil
end

function I.canCarry(src, item, count)
    if I.known(item) == false then return false, 'unknown_item' end
    if exports[I.resource]:CanAddItem(src, item, count) == true then return true end
    return false, 'cannot_carry'
end

function I.add(src, item, count, metadata)
    if exports[I.resource]:AddItem(src, item, count, false, metadata, 'cis_bridge') == true then
        return true
    end
    return false, 'refused'
end

-- A stack split over slots is removed slot by slot. The total is checked
-- first, so a short one touches nothing; a slot refused midway leaves a
-- partial removal, which server/v1.lua sees in the count and reports as
-- partial, with cis_bridge:inconsistent; nothing is added back.
function I.remove(src, item, count)
    local res = exports[I.resource]
    if res:RemoveItem(src, item, count, false, 'cis_bridge') == true then
        return true
    end
    local stacks = res:GetItemsByName(src, item)
    if type(stacks) ~= 'table' then return false, 'refused' end
    local plan, have = {}, 0
    for _, st in ipairs(stacks) do
        local slot = type(st) == 'table' and tonumber(st.slot) or nil
        local amount = type(st) == 'table' and math.floor(tonumber(st.amount) or 0) or 0
        if slot and amount > 0 and have < count then
            local take = math.min(amount, count - have)
            plan[#plan + 1] = { slot, take }
            have = have + take
        end
    end
    if have < count then return false, 'refused' end
    for _, p in ipairs(plan) do
        if res:RemoveItem(src, item, p[2], p[1], 'cis_bridge') ~= true then return false, 'refused' end
    end
    return true
end

CisBridgeInventories['qb-inventory'] = I
