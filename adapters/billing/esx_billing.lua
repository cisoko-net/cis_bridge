-- esx_billing backend for the v1 billing contract (client/v1.lua).
--
-- Every fact here was read in esx_billing 1.16.3 (esx-framework/esx_addons
-- v1.16.3, `[esx_addons]/esx_billing/`, `legacyversion '1.16.3'`,
-- on esx_lib and es_extended 1.16.3) on 2026-10-28:
--
--   server/main.lua:283, :295  the only exports, BillPlayer and
--       BillPlayerByIdentifier, both issue bills. Nothing on the server reads
--       or pays one for another resource.
--   server/main.lua:331-357  callback `esx_billing:getBills(afterId)`: the
--       caller's rows `{ amount, id, label }` with `id > afterId`, ORDER BY id,
--       page Config.BillsPageSize (50, at most 100), second value `hasNext`;
--       `{}` for a bad cursor or when its read limiter refuses.
--   server/main.lua:394-705  callback `esx_billing:payBill(billId)`: locks
--       the bill and the payer, journals the payment (`billing_payments`),
--       recovers a half-done one, and answers `true` or `false`, no reason.
--   client/main.lua:8, :63  its own menu calls both through xLib.callback.
--
-- Both are client callbacks run as the caller's `source`, so the payer is the
-- local player by construction, and the money moves inside esx_billing's own
-- locks. That is why this adapter is client side and does nothing but relay.
--
-- The call goes through ESX's public client API, es_extended 1.16.3
-- client/modules/callback.lua:10-12:
--   ESX.TriggerServerCallback(name, cb, ...) -> xLib.callback(name, false, cb, ...)
-- not ESX.AwaitServerCallback (:17-19): esx_lib's await gives up only after
-- 300000 ms by default (imports/callback/client.lua:17), and a callback that
-- does not exist raises inside esx_lib's reply handler, so its caller never
-- hears back. client/v1.lua waits for the cb with its own 10 s limit.

CisBridgeBilling = CisBridgeBilling or {}

-- Shared adapters/framework/common.lua loads first in both realms.
local Common = CisBridgeFrameworks.__common

local B = { name = 'esx_billing', resource = 'esx_billing', framework = 'es_extended' }

-- The ESX resource, renamed when cis_bridge:framework_resource renames it.
local function esxResource()
    local esx = CisBridgeFrameworks and CisBridgeFrameworks.esx
    return type(esx) == 'table' and esx.resource or B.framework
end

-- Fetched on every call: a restarted es_extended leaves the old shared object
-- behind, and its functions raise once their resource is gone.
local function core()
    local ESX = exports[esxResource()]:getSharedObject()
    if type(ESX) ~= 'table' or not Common.callable(ESX.TriggerServerCallback) then return nil end
    return ESX
end

function B.probe()
    if GetResourceState(esxResource()) ~= 'started' then return false end
    local ok, ESX = pcall(core)
    return ok and ESX ~= nil
end

-- done(rows, hasNext), on a later tick.
function B.list(after, done)
    local ESX = core()
    if not ESX then error('es_extended has no TriggerServerCallback') end
    ESX.TriggerServerCallback('esx_billing:getBills', done, after)
end

-- done(paid), on a later tick.
function B.pay(id, done)
    local ESX = core()
    if not ESX then error('es_extended has no TriggerServerCallback') end
    ESX.TriggerServerCallback('esx_billing:payBill', done, id)
end

CisBridgeBilling.esx_billing = B
