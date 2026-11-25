-- qb-target backend for the v1 target contract (client/v1.lua).
--
-- qb-target takes `action(entity)` where v1 says `onSelect(entity)`, takes a
-- box as length, width and a minZ / maxZ pair instead of a size vector, and
-- reads distance twice: `targetoptions.distance` beside the option list is the
-- reach of the whole zone or entity, and each option's own `distance` hides
-- that option past it (CheckOptions in client/init.lua; SetOptions in
-- client/main.lua caps an entity option at the list's). So the list gets the
-- widest option's distance and each option keeps its own. client/v1.lua has
-- already filled in the default for an option that named none, so there is
-- no floor here: a 1.5 m option is 1.5 m, as it is on ox_target.

CisBridgeTargets = CisBridgeTargets or {}

local T = { name = 'qb-target', resource = 'qb-target' }

function T.probe()
    local ok, fn = pcall(function()
        return exports[T.resource].AddBoxZone
    end)
    return ok and fn ~= nil
end

local function translate(options)
    local out, labels, distance = {}, {}, 0
    for i, o in ipairs(options) do
        labels[i] = o.label
        if type(o.distance) == 'number' then distance = math.max(distance, o.distance) end
        local onSelect, canInteract = o.onSelect, o.canInteract
        out[i] = {
            label = o.label,
            icon = o.icon,
            distance = o.distance,
            action = onSelect and function(entity) onSelect(entity) end or nil,
            canInteract = canInteract and function(entity) return canInteract(entity) == true end or nil,
        }
    end
    return { options = out, distance = distance }, labels
end

function T.addZone(spec)
    local options = translate(spec.options)
    if spec.kind == 'sphere' then
        exports[T.resource]:AddCircleZone(spec.name, spec.coords, spec.size, {
            name = spec.name, debugPoly = spec.debug, useZ = true,
        }, options)
        return spec.name
    end
    -- PolyZone BoxZone takes (length, width) with length on Y and width on X
    -- (BoxZone.lua _calculatePoints, qbcore-framework/PolyZone@0f90030).
    local size = spec.size
    exports[T.resource]:AddBoxZone(spec.name, spec.coords, size.y, size.x, {
        name = spec.name,
        heading = spec.rotation or 0,
        debugPoly = spec.debug,
        minZ = spec.coords.z - size.z / 2,
        maxZ = spec.coords.z + size.z / 2,
    }, options)
    return spec.name
end

function T.addEntity(spec)
    local options, labels = translate(spec.options)
    exports[T.resource]:AddTargetEntity(spec.entity, options)
    return labels
end

function T.remove(record)
    if record.entity then
        exports[T.resource]:RemoveTargetEntity(record.entity, record.handle)
    else
        exports[T.resource]:RemoveZone(record.name)
    end
    return true
end

CisBridgeTargets['qb-target'] = T
