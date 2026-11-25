-- codem-inventory backend for the v1 inventory contract (server/v1.lua).
--
-- codem-inventory is paid and closed. Its docs list the calls but no return
-- values, and there is no canCarry export:
--   GetItemsTotalAmount(source, item)
--   AddItem(source, item, amount, slot?, metadata?)
--   RemoveItem(source, item, amount)
-- So `canCarry` answers nil ("not checked") and server/v1.lua's count check is
-- the only proof of a write. The README's "Tested on" table records that
-- this adapter's test model is built from those docs, not from source.

CisBridgeInventories = CisBridgeInventories or {}

local I = { name = 'codem-inventory', resource = 'codem-inventory' }

function I.probe()
    local ok, fn = pcall(function()
        return exports[I.resource].GetItemsTotalAmount
    end)
    return ok and fn ~= nil
end

-- No number is no count: server/v1.lua reads nil as not_loaded, where a 0
-- would prove a removal that never happened.
function I.count(src, item)
    -- The extra parentheses keep one value: a lone nil answer crosses the
    -- export boundary as no value at all, and tonumber() with none raises.
    return tonumber((exports[I.resource]:GetItemsTotalAmount(src, item)))
end

function I.known(_item)
    return nil
end

function I.canCarry(_src, _item, _count)
    return nil
end

function I.add(src, item, count, metadata)
    if exports[I.resource]:AddItem(src, item, count, nil, metadata) == false then
        return false, 'refused'
    end
    return true
end

function I.remove(src, item, count)
    if exports[I.resource]:RemoveItem(src, item, count) == false then
        return false, 'refused'
    end
    return true
end

CisBridgeInventories['codem-inventory'] = I
