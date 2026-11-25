# Installing cis_bridge

For server owners. cis_bridge is the resource Cisoko products call for money,
items, jobs, doors and interaction targets; you install it once, beside the
framework and inventory you already run. You do not configure it for most
servers: it detects what is there.

**1.0.0 is an early access release.** The product API is frozen for all of
1.x (`docs/V1.md` § Frozen API); what has and has not been tested on a live
server is in [Compatibility](#compatibility).

## Requirements

| What | Version |
|---|---|
| FXServer | OneSync enabled, build 4500 or newer (cis_libs requires both). Tested on 35245. |
| cis_libs | 1.0.0, from https://github.com/cisoko-net/cis_libs |
| A framework | ESX Legacy, QBCore or Qbox (see [Compatibility](#compatibility)) |
| An inventory | the framework's own, or cis_inventory, ox_inventory, qb-inventory, qs-inventory or codem-inventory |

Doors (ox_doorlock, qb-doorlock) and targets (ox_target, qb-target) are
optional: a server without them works, and only the exports that need them
answer `no_doors` or `no_target`.

## Install

1. Download `cis_bridge-<version>.zip` from the release page and unzip it.
   You get one folder, `cis_bridge`. Do the same for cis_libs.
2. Put both folders in your resources, for example `resources/[cis]/`. **Keep
   the folder names `cis_bridge` and `cis_libs`**: every product calls
   `exports.cis_bridge`, so a renamed folder breaks them all.

   If you downloaded GitHub's "Source code" zip instead, the folder is called
   `cis_bridge-<version>`: rename it to `cis_bridge`.
3. Add two lines to `server.cfg`, **after** your framework and inventory:

### ESX Legacy

```cfg
ensure oxmysql
ensure es_extended
# ensure ox_inventory    (if you use it; otherwise ESX's own inventory is used)
ensure cis_libs
ensure cis_bridge
```

### QBCore

```cfg
ensure oxmysql
ensure qb-core
ensure qb-inventory      # or qs-inventory, codem-inventory, ox_inventory
ensure cis_libs
ensure cis_bridge
```

### Qbox

```cfg
ensure oxmysql
ensure ox_lib
ensure qbx_core
ensure ox_inventory
ensure cis_libs
ensure cis_bridge
```

`oxmysql` may be `cis_database`; cis_bridge itself does not use a database.
Your door and target resources (ox_doorlock, qb-doorlock, ox_target,
qb-target) stay where they are in your `server.cfg`.

4. Start the server, or run `refresh` then `ensure cis_libs` and
   `ensure cis_bridge` in the server console.
5. Check it, in the server console:

```
cis_bridge report
cis_bridge test
```

`cis_bridge report` prints one row each for framework, inventory and doors:
`OK` with what it found (`esx`, `qbox`, `ox_inventory`, ...), `MISSING` with
the line that fixes it, or `NONE` (doors only: a server without a door
resource is fine).
`cis_bridge test` runs the read-only checks. The server's tally is
`cis_bridge: N passed, N failed, N skipped`; each connected client's results
follow it. It writes nothing to any player; with players connected, each
client also runs its half, which places a temporary ped and target zones and
removes them. A `SKIP` is not a failure: per-player checks skip when nobody
is connected.

Start order between cis_bridge and your framework does not matter for
detection: cis_bridge detects at first use and again whenever a framework,
inventory, door or target resource starts or stops. Keeping it after them
avoids a `MISSING` line in the boot report.

## Choosing a resource by name

Only needed when your server runs two candidates of one kind, or detection
picks the wrong one. `setr`, not `set`: the client reads the framework and
target too.

```cfg
setr cis_bridge:framework qbcore        # esx | qbcore | qbox | cis_core
setr cis_bridge:inventory ox_inventory  # cis_inventory | ox_inventory | qs-inventory | codem-inventory | qb-inventory
setr cis_bridge:doors ox_doorlock       # ox_doorlock | qb-doorlock
setr cis_bridge:target ox_target        # ox_target | qb-target
setr cis_bridge:appearance illenium-appearance  # fivem-appearance | qb-clothing | skinchanger
setr cis_bridge:billing esx_billing
```

A resource that runs under another name (qb-core started as `my-core`) is
named beside its slot, with the same slot name plus `_resource`:

```cfg
setr cis_bridge:framework qbcore
setr cis_bridge:framework_resource my-core
```

Set alone, a `_resource` convar picks nothing and prints a line saying to set
both.

A convar is obeyed exactly: when the resource it names is not started, or
the name is misspelled, that kind stays undetected (`MISSING` in the report,
`no_doors` or `no_target` from the exports). Only ESX's own inventory still
steps in. Remove the convar to go back to detection.

What is detected when no convar is set:

- Framework: `qbx_core`, then `es_extended`, then `qb-core` (only when
  `qbx_core` is not started, since Qbox also provides `qb-core`), then
  `cis_core`.
- Inventory: `cis_inventory`, `ox_inventory`, `qs-inventory`,
  `codem-inventory`, `qb-inventory`, then ESX's own.
- Doors: `ox_doorlock`, then `qb-doorlock`.
- Targets: `ox_target`, then `qb-target`.

## Compatibility

One adapter file per resource. "Tested live" means `cis_bridge test` ran on
a real server with that resource on 2026-11-01 (FXServer 35245, no player
connected). "Unit tested" means the adapter passes the contract suites against
a model of that resource's API, but has not run on a live server yet.

| Kind | Resource | Version tested live | Status |
|---|---|---|---|
| Framework | ESX Legacy (`es_extended`) | manifest 1.16.3, with `esx_lib` 1.0.0 | tested live: 10 passed, 0 failed, 2 skipped |
| Framework | QBCore (`qb-core`) | manifest 1.3.0 | tested live: 11 passed, 0 failed, 1 skipped |
| Framework | Qbox (`qbx_core`) | 1.24.0 | tested live: 11 passed, 0 failed, 1 skipped |
| Framework | `cis_core` 1.x | none | unit tested (cis_core 2.0.0 removed `CisCoreFramework()`, which the adapter calls) |
| Inventory | `cis_inventory` | with Qbox above | tested live |
| Inventory | ESX's own | with ESX above | tested live |
| Inventory | `qb-inventory` | 2.2.3 | tested live |
| Inventory | `ox_inventory` | 2.48.0 | tested live on 2026-10-24; unit tested since (the test servers now run cis_inventory) |
| Inventory | `qs-inventory` | none | unit tested |
| Inventory | `codem-inventory` | none | unit tested |
| Doors | `ox_doorlock` | 1.23.0 | detected live |
| Doors | `qb-doorlock` | 2.0.0 | detected live; answers `unsupported` (it has no server exports to read or set a door) |
| Target | `ox_target` | 1.18.1 | unit tested (client; installed on the Qbox test server, not exercised) |
| Target | `qb-target` | 5.5.0 | unit tested (client; installed on the QBCore test server, not exercised) |

Other versions of these resources are expected to work as long as their
exports keep the same names and shapes; `cis_bridge test` is how you find
out on your server. ND_Core, vRP and other frameworks are not supported in
1.x.

Not yet tested live: the per-player checks with a player connected, the
write round trip (`cis_bridge test write <server id>`), and the client half
(`cis_bridge_client` in the F8 console).

## Common problems

| You see | Why | Fix |
|---|---|---|
| `Could not find dependency cis_libs for resource cis_bridge` | cis_libs is not installed, or its folder is renamed | install cis_libs as `resources/[cis]/cis_libs` and `ensure cis_libs` before cis_bridge |
| cis_libs does not start, naming the dependency `/onesync` | OneSync is off | set `onesync on` in `server.cfg` |
| a `MISSING` framework row in `cis_bridge report` | no supported framework is started, or `cis_bridge:framework` names one that is not | start your framework before cis_bridge, or fix the convar |
| a `MISSING` inventory row | none of the supported inventories is started, and the framework is not ESX | start your inventory before cis_bridge, or name it with `setr cis_bridge:inventory <name>` |
| `Could not find dependency cis_bridge for resource <product>` | the folder is not named `cis_bridge`, or cis_bridge is not ensured | rename the folder to `cis_bridge` and `ensure cis_bridge` before the product |
| A product answers `no_bridge` | cis_bridge was stopped after the product started | `ensure cis_bridge` |
| `MISSING` after you set a convar | the convar names a resource that is not started, or is misspelled | fix the name, or remove the convar |
| A product answers `busy` | two writes for the same player at once; the second is refused, never queued | nothing to fix on the server; the product retries or tells the player |
| `cis_bridge test` shows `SKIP` lines | no player is connected, or a door or target resource is not installed | join the server and run it again; a missing optional resource stays `SKIP` |
| The QBCore framework is detected as Qbox | `qbx_core` is started; Qbox provides `qb-core` | that is correct on a Qbox server; on QBCore, stop `qbx_core` |

Anything else: run `cis_bridge report` and `cis_bridge test`, and bring both
outputs to https://discord.cisoko.net.

## Upgrading

Replace the whole `cis_bridge` folder; do not copy a new version over an
old folder, or deleted files stay behind. What changed is in
`CHANGELOG.md`.

## Removing it

Remove the `ensure cis_bridge` line and the folder. cis_bridge creates no
database table and writes no file.
