-- =============================================================================
--  Cisoko Bridge -- the product API
--
--  One API that every Cisoko product calls for money, items, jobs,
--  notifications, doors, interaction targets, appearance and billing. Behind
--  it is one adapter file per supported resource: ESX, QBCore, Qbox and
--  cis_core; cis_inventory, ox_inventory, qb-inventory, qs-inventory and
--  codem-inventory; ox_doorlock and qb-doorlock; ox_target and qb-target;
--  illenium-appearance, fivem-appearance, qb-clothing and skinchanger;
--  esx_billing. No product names any of them.
--  docs/V1.md is the contract.
--
--  Why a separate resource
--
--  ox_inventory is GPL-3.0. The bridge calls its exports from its own adapter
--  file and never copies or changes its code, so the licences stay apart.
--  One file per target also makes support for a target easy to add, test and
--  remove.
--
--  `cis_bridge test` runs the v1 contracts against the framework and inventory
--  this server really has and prints PASS, FAIL or SKIP for each check, because
--  third-party resources change between versions. `cis_bridge report` says
--  what was detected and how to fix anything missing.
--
--      ensure cis_libs
--      ensure <your framework and inventory>
--      ensure cis_bridge
-- =============================================================================

fx_version 'cerulean'
game 'gta5'

name "Cisoko - Bridge - Product API"
description "One API for money, items, jobs, doors, targets, appearance and billing, on every framework."
author "Cisoko"
version "1.0.0"
lua54 'yes'

-- cis_libs, for the `lib.*` shim's callbacks (server/lib.lua). The v1 API
-- itself needs nothing from it.
dependencies {
    'cis_libs',
    -- The build floor of cis_libs, which this resource cannot run without.
    -- No OneSync: the bridge reads no entity or state bag on the server.
    '/server:4500',
}

shared_scripts {
    -- v1 framework adapters. Both realms: each file holds a server half and a
    -- client half, and `common` is read by the QB-shaped three.
    'adapters/framework/common.lua',
    'adapters/framework/esx.lua',
    'adapters/framework/qbcore.lua',
    'adapters/framework/qbox.lua',
    'adapters/framework/cis_core.lua',
    -- v1 appearance adapters, both realms: the server half prepares a save,
    -- the client half runs it. `common` first, the others read it.
    'adapters/appearance/common.lua',
    'adapters/appearance/illenium.lua',
    'adapters/appearance/fivem_appearance.lua',
    'adapters/appearance/qb_clothing.lua',
    'adapters/appearance/skinchanger.lua',
    -- The owner's own adapters (empty as shipped). Shared scripts load first,
    -- so this is after the framework and appearance adapters and before the
    -- inventory, doors, target and billing ones; every registry is
    -- `X = X or {}`, so an adapter under a new name survives them all.
    'adapters/custom.lua',
}

-- The product facade. A product lists `@cis_bridge/init.lua` in its own
-- shared_scripts; `files` is what lets a client fetch it.
files {
    'init.lua',
}

client_scripts {
    'adapters/target/ox.lua',
    'adapters/target/qb.lua',
    -- v1 billing adapters, client only: the billing resources' read and pay
    -- paths are client callbacks run as the caller (adapters/billing/*.lua).
    'adapters/billing/esx_billing.lua',
    'client/v1.lua',
    'client/conformance.lua',
}

server_scripts {
    -- Keep this order. Every adapter publishes itself into a table that v1.lua reads when it
    -- loads, and ratelimit.lua publishes the global conformance.lua reads, so
    -- each producer is listed before its consumer. test/contract.lua asserts
    -- the order.
    'adapters/inventory/cis_inventory.lua',
    'adapters/inventory/ox.lua',
    'adapters/inventory/qb.lua',
    'adapters/inventory/qs.lua',
    'adapters/inventory/codem.lua',
    'adapters/doors/ox_doorlock.lua',
    'adapters/doors/qb_doorlock.lua',
    'server/v1.lua',
    'server/report.lua',
    -- The `lib.*` shim publishes `CisBridgeLibShim`, which server/lib.lua
    -- reads. FiveM has no `require` for a resource's own files.
    'shared/lib/shim.lua',
    'server/lib.lua',
    'server/ratelimit.lua',
    'server/conformance.lua',
}
