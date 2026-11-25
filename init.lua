-- The CisBridge facade (docs/V1.md, Product API shape).
--
--     shared_scripts { '@cis_libs/init.lua', '@cis_bridge/init.lua' }
--
-- One global, `CisBridge`, whose fields forward to the export of the same
-- name. It holds no state and caches nothing, so a cis_bridge restart never
-- leaves a product holding a stale reference. Each realm gets only its own
-- contracts: a server field on the client would forward to an export that
-- does not exist there.

local SERVER = {
    'GetPlayer', 'IsLoaded', 'GetMoney', 'AddMoney', 'RemoveMoney',
    'GetItemCount', 'CanCarry', 'AddItem', 'RemoveItem', 'GetJob', 'SetJob',
    'Notify', 'Purchase', 'GetDoorLock', 'SetDoorLock', 'GetSummary',
    'GetOwnedVehicleId', 'SaveAppearance', 'GetGang', 'GetPlayerState', 'UseItem',
    'GetSourceByCharId',
}

local CLIENT = {
    'GetPlayerData', 'IsLoaded', 'Notify', 'AddTargetZone', 'AddTargetEntity', 'RemoveTarget',
    'GetAppearanceComponent', 'ApplyClothing', 'HasBilling', 'GetBills', 'PayBill',
}

local facade = {}

-- A call into a stopped or missing cis_bridge raises "No such export" in the
-- Product's thread, so a shop whose bridge was restarted died mid-handler
-- instead of answering. The facade keeps the v1 shape instead: a bridge that
-- is not started answers `false, 'no_bridge'`, and a call that raises across
-- the boundary anyway (cis_bridge stopping mid-call) answers `false, 'error'`.
local function call(name, ...)
    local bridge = exports.cis_bridge
    return bridge[name](bridge, ...)
end

for _, name in ipairs(IsDuplicityVersion() and SERVER or CLIENT) do
    facade[name] = function(...)
        if GetResourceState('cis_bridge') ~= 'started' then return false, 'no_bridge' end
        local res = table.pack(pcall(call, name, ...))
        if not res[1] then
            print(('^1cis_bridge facade: %s raised: %s^7'):format(name, tostring(res[2])))
            return false, 'error'
        end
        return table.unpack(res, 2, res.n)
    end
end

CisBridge = facade
