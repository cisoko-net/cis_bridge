-- illenium-appearance backend for the v1 appearance contract.
--
-- Facts from illenium-appearance 5.7.0, read from its installed source:
--   client export getPedAppearance(ped)   game/util.lua:399 (defined :171), the
--                                         whole look: model, head blend, faces,
--                                         overlays, components, props, hair,
--                                         tattoos, eye colour
--   server net event 'illenium-appearance:server:saveAppearance'(appearance)
--                                         server/server.lua:165-171; the owner is
--                                         the sender's citizenid, so a client can
--                                         only ever save its own look
--   client net event 'illenium-appearance:client:reloadSkin'
-- It fires no event when the skin has loaded: InitAppearance (client/client.lua:59)
-- runs on the framework's loaded event and applies the look after a callback.

CisBridgeAppearances = CisBridgeAppearances or {}

local A = {
    name = 'illenium-appearance',
    resource = 'illenium-appearance',
    server = {},
    client = {},
    loadEvents = { { 'illenium-appearance:client:reloadSkin', net = true } },
}

-- The resource has no server export to probe; started is the whole check.
function A.probe() return true end

-- Nothing to prepare: the save event needs no session.
function A.server.save() return true end

function A.client.save(ped)
    local appearance = exports[A.resource]:getPedAppearance(ped)
    if type(appearance) ~= 'table' then return false, 'no_skin' end
    TriggerServerEvent('illenium-appearance:server:saveAppearance', appearance)
    return true
end

CisBridgeAppearances['illenium-appearance'] = A
