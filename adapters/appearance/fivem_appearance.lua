-- fivem-appearance (pedr0fontoura) backend for the v1 appearance contract.
--
-- Facts from pedr0fontoura/fivem-appearance v1.3.1 (b06da32): a client-only
-- resource. Its exports read and set the ped (getPedAppearance,
-- setPedComponent, setPedProp, the same shapes as illenium-appearance), and it
-- has no server folder, no net event and no storage. Where a server keeps the
-- look is that server's own glue, which the bridge cannot know, so
-- SaveAppearance answers 'unsupported' here. The slot exports still work: they
-- read and dress the ped through the natives (adapters/appearance/common.lua).

CisBridgeAppearances = CisBridgeAppearances or {}

local A = {
    name = 'fivem-appearance',
    resource = 'fivem-appearance',
    server = {},
    client = {},
    loadEvents = {},
}

function A.probe() return true end

function A.server.save() return false, 'unsupported' end

function A.client.save() return false, 'unsupported' end

CisBridgeAppearances['fivem-appearance'] = A
