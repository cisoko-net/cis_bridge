-- =============================================================================
--  cis_bridge -- the machine-readable public contract
--
--  This file is data. It defines nothing, runs nothing, and is deliberately not
--  listed in fxmanifest.lua. Read it on demand, and run `npm run test:api`,
--  which validates it against what the code actually registers and fails on the
--  difference.
--
--  One API, no slot exports
--
--  cis_bridge registers nothing into cis_libs' capability slots and has no
--  per-adapter exports. A product calls the v1 exports below and never names a
--  framework, an inventory, a target or a doorlock; the adapter files behind
--  them publish into this resource's own tables, not into cis_libs.
--
--  `api = 1` is the contract major and is not the product version.
-- =============================================================================

return {
    name = 'cis_bridge',
    version = '1.0.0',
    api = 1,
    schema = 0,

    exports = {
        -- ------------------------------------------------------------ v1
        -- The product API (docs/V1.md). A product calls these directly; it
        -- never names a framework, an inventory, a target or a doorlock.
        -- Every one answers its value, or false and a reason, and none raises.
        GetPlayer = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The loaded player: { source, id, name, job, phone }. id is the character id; phone is the QBCore or Qbox charinfo.phone, nil elsewhere',
            realm = 'server',
            signature = '(src)',
        },
        IsLoaded = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'true when the player (server) or the local player (client) has a loaded character',
            realm = 'both',
            signature = { server = '(src)', client = '()' },
        },
        GetMoney = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Balance of one account: cash (default), bank, dirty, crypto. An account the framework does not have answers bad_account',
            realm = 'server',
            signature = '(src, accountName)',
        },
        AddMoney = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Adds a positive whole amount; proved by reading the balance back',
            realm = 'server',
            signature = '(src, accountName, amount, reason)',
        },
        RemoveMoney = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Removes a positive whole amount, never more than the balance',
            realm = 'server',
            signature = '(src, accountName, amount, reason)',
        },
        GetItemCount = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'How many of one item the player holds, from the detected inventory',
            realm = 'server',
            signature = '(src, item)',
        },
        CanCarry = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Whether the player can take this many more. true where the inventory cannot check',
            realm = 'server',
            signature = '(src, item, n)',
        },
        AddItem = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Adds items; the count before and after is the proof, and a partial add is taken back',
            realm = 'server',
            signature = '(src, item, n, metadata)',
        },
        RemoveItem = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Removes items; a partial remove is not put back: it answers partial and fires cis_bridge:inconsistent with the count that went',
            realm = 'server',
            signature = '(src, item, n)',
        },
        GetJob = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The job as { name, label, grade, gradeName, gradeLabel, isBoss, onDuty, pay }',
            realm = 'server',
            signature = '(src)',
        },
        SetJob = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Sets a job and grade that exist; emits cis_bridge:jobChanged once',
            realm = 'server',
            signature = '(src, name, grade)',
        },
        Notify = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'A notification through the framework: info, success, warning or error',
            realm = 'both',
            signature = { server = '(src, message, kind)', client = '(message, kind)' },
        },
        Purchase = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Takes the money, then gives every line; any failure takes back what landed and refunds the rest. One lock per player for the whole order',
            realm = 'server',
            signature = '(src, order)',
        },
        GetDoorLock = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "'locked' or 'unlocked' for a door id or name, from the detected doorlock",
            realm = 'server',
            signature = '(id)',
        },
        SetDoorLock = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Locks (true) or unlocks (false) a door; emits cis_bridge:doorChanged',
            realm = 'server',
            signature = '(id, isLocked)',
        },
        GetSummary = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = '{ api, version, framework, inventory, doors, appearance, config, why }: what was detected and how, for a support thread',
            realm = 'server',
            signature = '()',
        },
        GetOwnedVehicleId = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "The framework's id of an owned vehicle by plate (Qbox player_vehicles.id, the plate on ESX and QBCore), or false, 'not_owned'",
            realm = 'server',
            signature = '(plate)',
        },
        SaveAppearance = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "Saves the player's current look through the detected clothing resource (illenium-appearance, qb-clothing, ESX skinchanger)",
            realm = 'server',
            signature = '(src)',
        },
        GetGang = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "The player's gang: { name, label, grade, isboss } (QBCore and Qbox), or false, 'unsupported' (ESX, cis_core) / 'not_loaded'",
            realm = 'server',
            signature = '(src)',
        },
        GetPlayerState = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "{ dead, lastStand, cuffed } from the QBCore / Qbox metadata flags, or false, 'unsupported' (ESX, cis_core) / 'not_loaded'",
            realm = 'server',
            signature = '(src)',
        },
        UseItem = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "Runs the framework's registered usable-item callback for the player: true, or false, 'not_usable' / 'not_loaded' / 'bad_item' / 'bad_data' / 'error'. Does not check that the player holds the item",
            realm = 'server',
            signature = '(src, item, data)',
        },
        GetSourceByCharId = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "The server id of the loaded player with this character id (GetPlayer().id), or false, 'offline' / 'bad_id' / 'no_framework' / 'error'",
            realm = 'server',
            signature = '(charId)',
        },
        GetPlayerData = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The local player: { id, name, job }',
            realm = 'client',
            signature = '()',
        },
        AddTargetZone = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'A box or sphere zone with canonical options { label, icon, distance, onSelect(entity), canInteract(entity) }. Removed when the resource that added it stops',
            realm = 'client',
            signature = '(spec)',
        },
        AddTargetEntity = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Target options on one entity, the same option shape as AddTargetZone',
            realm = 'client',
            signature = '(spec)',
        },
        RemoveTarget = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Removes a zone or entity target by the name it was added with',
            realm = 'client',
            signature = '(name)',
        },
        GetAppearanceComponent = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'One clothing slot of the local ped: { drawable, texture }, drawable -1 for a prop slot with nothing on',
            realm = 'client',
            signature = '(slot)',
        },
        ApplyClothing = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Dresses one clothing slot of the local ped with { drawable, texture }; drawable -1 takes a prop off',
            realm = 'client',
            signature = '(slot, data)',
        },
        HasBilling = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "true and the billing resource's name when the client has one (esx_billing), or false, 'no_billing'",
            realm = 'client',
            signature = '()',
        },
        GetBills = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "The local player's unpaid bills after id `after`: { items = { { id, label, amount } }, more }, or false, 'bad_cursor' / 'no_billing' / 'failed' / 'timeout' / 'error'. Waits for the reply: call from a thread",
            realm = 'client',
            signature = '(after)',
        },
        PayBill = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = "Pays one of the local player's bills through the billing resource's own pay path: true, or false, 'bad_id' / 'no_billing' / 'refused' / 'timeout' / 'error'. Waits for the reply: call from a thread",
            realm = 'client',
            signature = '(id)',
        },

        -- ------------------------------------------------------ lib shims
        -- Exports, not a global, and the difference is the platform: each FiveM
        -- resource has its own Lua state, so a `lib` written here is a different
        -- variable from the `lib` a consumer reads. A shim that "installs lib"
        -- installs it for itself and nobody else -- which looks like a working
        -- drop-in on the machine it was tested on. A consumer takes it with one
        -- line, and that line says cis_bridge is being used.
        -- Deprecated in 1.0.0, outside the frozen v1 API (docs/V1.md § Frozen
        -- API). lib.zones answers false and a reason without calling cis_libs,
        -- whose zone exports are client-only; GetDbProxy answers false and a reason.
        GetLibShim = {
            since = '1.0.0', ['until'] = '2.0.0', stable = false, deprecated = true, deprecatedIn = '1.0.0',
            use = "Deprecated: call cis_libs directly (Cis.callback on either realm, Cis.zones on the client). "
                .. "ox_lib's lib.callback over cis_libs. lib.zones answers false and a reason on the server, because cis_libs zones are client-only",
            realm = 'server',
            signature = '()',
            returns = { 'callback', 'zones', 'zone' },
            returnTypes = { callback = 'table', zones = 'table' },
        },
        GetDbProxy = {
            since = '1.0.0', ['until'] = '2.0.0', stable = false, deprecated = true, deprecatedIn = '1.0.0',
            use = "Deprecated: use the oxmysql API (MySQL.query.await and the rest), served by oxmysql or cis_database. "
                .. "Answers false and a reason: the proxy forwarded to cis_libs' Db* exports, which no shipped "
                .. "resource serves",
            realm = 'server',
            signature = '()',
        },

        -- ---------------------------------------------------- conformance
        RunConformance = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The same as `cis_bridge test`: the v1 read-only suite. Writes nothing to a player; the write round trip is the console-only `cis_bridge test write <id>`',
            realm = 'server',
            signature = '()',
        },
        GetConformanceResults = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The last run, as an array of { target, name, ok, skipped, detail }. For a support thread',
            realm = 'server',
            signature = '()',
        },
        -- The boot report, as data rather than as printed lines.
        GetBridgeReport = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'One row per kind (framework, inventory, doors): { kind, label, target, detail, fix }. '
                .. 'The same content the boot printout shows, so another resource can render it',
            realm = 'server',
            signature = '()',
        },
    },

    -- cis_bridge publishes no net events for products to consume.
    --
    -- It registers net event handlers for the client conformance results and
    -- for the appearance save the server asks of one client, which is not the
    -- same thing: a handler consumes, a publisher declares. Those events
    -- belong to this resource and are documented here as dependencies so the
    -- wire is visible in one place.
    events = {
        -- Framework notify events the v1 adapters fire. They belong to the
        -- framework; they are listed so the wire is visible in one place.
        ['QBCore:Notify'] = {
            since = '1.0.0',
            payload = 'server to client: (message, type, length) the QBCore notification, sent by the qbcore adapter',
        },
        ['esx:showNotification'] = {
            since = '1.0.0',
            payload = 'client local event: (message, type, length) the ESX notification, fired by the esx adapter',
        },
        -- The clothing resources' own save events, sent by the appearance
        -- adapters' client half. They belong to those resources.
        ['illenium-appearance:server:saveAppearance'] = {
            since = '1.0.0',
            payload = 'client to server: (appearance) the whole look, sent by the illenium-appearance adapter',
        },
        ['esx_skin:save'] = {
            since = '1.0.0',
            payload = 'client to server: (skin) the skinchanger skin, sent by the skinchanger adapter inside an esx_skin edit session',
        },
        ['cis_bridge:appearance:save'] = {
            since = '1.0.0',
            payload = 'server to client: (adapterName, reply) SaveAppearance asks the client to save through that clothing adapter; with reply true the client sends what it read back instead',
        },
        ['cis_bridge:appearance:reply'] = {
            since = '1.0.0',
            payload = 'client to server: (adapterName, clothes) the clothing keys read off the ped, taken once and only within 10 s of a SaveAppearance that asked for them',
        },
        ['cis_bridge:client:conformance'] = {
            since = '1.0.0',
            payload = 'server to client: no arguments, asks the client to run its own conformance checks',
        },
        ['cis_bridge:server:conformanceResults'] = {
            since = '1.0.0',
            payload = 'client to server: (results) the client half of a conformance run',
        },
    },
}
