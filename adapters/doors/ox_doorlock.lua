-- ox_doorlock backend for the v1 doors contract (server/v1.lua).
--
-- Facts from ox_doorlock v1.23.0 at 553e85d (`server/main.lua`):
--   getDoor(id)            -> false for an unknown id, else a table with `.state`
--   getDoorFromName(name)  -> the first door with that name, or nil
--   setDoorState(id, state) state 0 = unlocked, 1 = locked -> true | false
--                          (317-356). Called from an export, `source` is nil, so
--                          ox runs no permission check: the product decides.
--   event 'ox_doorlock:stateChanged'(source, doorId, locked:boolean, usedItem)
--                          a server-local TriggerEvent (340).
-- Ids are ox's numeric database ids; a string is looked up by door name.

CisBridgeDoors = CisBridgeDoors or {}

local D = { name = 'ox_doorlock', resource = 'ox_doorlock' }

function D.probe()
    local ok, fn = pcall(function()
        return exports[D.resource].getDoor
    end)
    return ok and fn ~= nil
end

local function door(id)
    if type(id) == 'string' then
        local d = exports[D.resource]:getDoorFromName(id)
        if type(d) ~= 'table' then return nil end
        return d
    end
    local d = exports[D.resource]:getDoor(id)
    if type(d) ~= 'table' then return nil end
    return d
end

function D.state(id)
    local d = door(id)
    if not d then return false, 'unknown_door' end
    return (d.state == 1 or d.state == true) and 'locked' or 'unlocked'
end

function D.set(id, locked)
    local d = door(id)
    if not d then return false, 'unknown_door' end
    if exports[D.resource]:setDoorState(d.id or id, locked and 1 or 0) == true then return true end
    return false, 'refused'
end

D.events = {
    changed = { 'ox_doorlock:stateChanged', function(_src, doorId, locked) return doorId, locked == true end },
}

CisBridgeDoors.ox_doorlock = D
