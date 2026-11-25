-- qs-inventory backend for the v1 inventory contract (server/v1.lua).
--
-- qs-inventory is paid and closed; these calls come from its public docs,
-- not from source:
--   AddItem(source, item, amount, slot?, info?) -> compare `== true`
--   RemoveItem(source, item, amount, slot?, metadata?) -> not documented
--   GetItemTotalAmount(source, item); an earlier adapter called it GetItemTotal
--   CanCarryItem(source, item, amount)
-- Because RemoveItem's return is undocumented, server/v1.lua's count check is
-- the proof of every write here.

CisBridgeInventories = CisBridgeInventories or {}

local I = { name = 'qs-inventory', resource = 'qs-inventory' }

local totalFn = 'GetItemTotalAmount'

function I.probe()
    for _, name in ipairs({ 'GetItemTotalAmount', 'GetItemTotal' }) do
        local ok, fn = pcall(function()
            return exports[I.resource][name]
        end)
        if ok and fn ~= nil then
            totalFn = name
            return true
        end
    end
    return false
end

-- No number is no count: server/v1.lua reads nil as not_loaded, where a 0
-- would prove a removal that never happened.
function I.count(src, item)
    local qs = exports[I.resource]
    -- The extra parentheses keep one value: a lone nil answer crosses the
    -- export boundary as no value at all, and tonumber() with none raises.
    return tonumber((qs[totalFn](qs, src, item)))
end

function I.known(_item)
    return nil
end

function I.canCarry(src, item, count)
    if exports[I.resource]:CanCarryItem(src, item, count) == true then return true end
    return false, 'cannot_carry'
end

function I.add(src, item, count, metadata)
    if exports[I.resource]:AddItem(src, item, count, nil, metadata) == true then return true end
    return false, 'refused'
end

-- The return is undocumented: anything but an explicit false goes on to the
-- count check in server/v1.lua.
function I.remove(src, item, count)
    if exports[I.resource]:RemoveItem(src, item, count) == false then return false, 'refused' end
    return true
end

CisBridgeInventories['qs-inventory'] = I
