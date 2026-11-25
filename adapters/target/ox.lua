-- ox_target backend for the v1 target contract (client/v1.lua).
--
-- client/v1.lua hands over canonical options, the same on every target:
--   { label, icon, distance, onSelect(entity), canInteract(entity) }
-- ox wants `onSelect(data)` with the entity at `data.entity`, and calls
-- `canInteract(entity, distance, coords, name, bone)`. This file translates
-- and keeps the ids ox answers, because removeZone and removeLocalEntity
-- answer nothing a caller could check.

CisBridgeTargets = CisBridgeTargets or {}

local T = { name = 'ox_target', resource = 'ox_target' }

function T.probe()
    local ok, fn = pcall(function()
        return exports[T.resource].addBoxZone
    end)
    return ok and fn ~= nil
end

local function translate(name, options)
    local out, names = {}, {}
    for i, o in ipairs(options) do
        local id = ('%s:%d'):format(name, i)
        names[i] = id
        local onSelect, canInteract = o.onSelect, o.canInteract
        out[i] = {
            name = id,
            label = o.label,
            icon = o.icon,
            distance = o.distance,
            onSelect = onSelect and function(data) onSelect(data and data.entity) end or nil,
            canInteract = canInteract and function(entity) return canInteract(entity) == true end or nil,
        }
    end
    return out, names
end

function T.addZone(spec)
    local options = translate(spec.name, spec.options)
    if spec.kind == 'sphere' then
        return exports[T.resource]:addSphereZone({
            name = spec.name, coords = spec.coords, radius = spec.size,
            debug = spec.debug, options = options,
        })
    end
    return exports[T.resource]:addBoxZone({
        name = spec.name, coords = spec.coords, size = spec.size,
        rotation = spec.rotation or 0, debug = spec.debug, options = options,
    })
end

function T.addEntity(spec)
    local options, names = translate(spec.name, spec.options)
    exports[T.resource]:addLocalEntity(spec.entity, options)
    return names
end

-- `handle` is what addZone / addEntity answered: the zone id, or the option
-- names to take off the entity.
function T.remove(record)
    if record.entity then
        exports[T.resource]:removeLocalEntity(record.entity, record.handle)
    else
        exports[T.resource]:removeZone(record.handle or record.name)
    end
    return true
end

CisBridgeTargets.ox_target = T
