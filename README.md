<p align="center"><a target="_blank" rel="noopener" href="https://cisoko.net"><img src="docs/img/banner.svg" alt="cis_bridge: One API for every FiveM framework" width="100%"></a></p>

<p align="center">
<a target="_blank" rel="noopener" href="https://github.com/cisoko-net/cis_bridge/releases/latest"><img src="docs/img/badge-version.svg" alt="version 1.0.0"></a>
<a target="_blank" rel="noopener" href="https://github.com/cisoko-net/cis_bridge/blob/main/LICENSE.md"><img src="docs/img/badge-license.svg" alt="license: source-available"></a>
<a target="_blank" rel="noopener" href="https://docs.fivem.net/docs/server-download/"><img src="docs/img/badge-fxserver.svg" alt="FXServer 4500+"></a>
</p>

<p align="center">
<a target="_blank" rel="noopener" href="https://github.com/cisoko-net/cis_bridge/releases/latest"><img src="docs/img/button-download.svg" alt="Download"></a>
<a target="_blank" rel="noopener" href="https://cisoko.net/docs/cis-bridge/"><img src="docs/img/button-docs.svg" alt="Documentation"></a>
<a target="_blank" rel="noopener" href="https://cisoko.net"><img src="docs/img/button-website.svg" alt="Website"></a>
<a target="_blank" rel="noopener" href="https://discord.cisoko.net"><img src="docs/img/button-discord.svg" alt="Discord"></a>
<a target="_blank" rel="noopener" href="https://github.com/cisoko-net/cis_bridge"><img src="docs/img/button-github.svg" alt="GitHub"></a>
</p>

# cis_bridge

`cis_bridge` is the Cisoko product API (**1.0.0**). One set of exports for money, items, jobs, doors, and interaction targets, with one adapter file per third-party resource behind it. It is free and source-available.

- **One API, every target:** Cisoko products call `exports.cis_bridge` and get a value, or `false` and a reason.
- **Clean isolation:** Every third-party resource has one optional adapter file here, never vendored or modified, and nothing outside that file names it.
- **Frozen v1 contract:** The product API is frozen for all of 1.x ([docs/V1.md](docs/V1.md) § Frozen API).

| Resource | What it is |
|---|---|
| `cis_libs` | The shared boundary. Owns no table, no config, no framework. |
| **`cis_bridge`** | **This.** The product API and its 20 adapter files. |
| `cis_core` | Cisoko's own framework: state, config, migrations. |

## Tested on

Every resource below is supported; the last column says how far that claim is proven. "Live" means `cis_bridge test` ran on a real FXServer (build 35245, no player connected). "Unit tests only" means contract suites against a model of that resource's API.

| Slot | Resource | How it is proven |
|---|---|---|
| Framework | ESX Legacy, QBCore, Qbox | Live, 2026-11-01: 10/0/2, 11/0/1, 11/0/1 passed/failed/skipped |
| Framework | `cis_core` 1.x | Unit tests only |
| Inventory | ESX's own, `qb-inventory`, `cis_inventory` | Live, 2026-11-01 |
| Inventory | `ox_inventory` | Live on 2026-10-24; unit tests since |
| Inventory | `qs-inventory`, `codem-inventory` | Unit tests only (paid resources) |
| Doors | `ox_doorlock`, `qb-doorlock` | Detected live, 2026-11-01; no door read or set live |
| Target | `ox_target`, `qb-target` | Unit tests only (client half needs a player) |
| Appearance | `illenium-appearance`, `fivem-appearance`, `qb-clothing`, `skinchanger` | Unit tests only (needs a player) |
| Billing | `esx_billing` | Started live beside `cis_bridge`; client half needs a player |
| Custom | `_resource` convars & `adapters/custom.lua` | Unit tests only |

Not covered live yet: per-player checks, the write round trip (`cis_bridge test write <server id>`), and the client half. Run `cis_bridge test` on your own server to verify your setup.

## Install

> **Note:** Needs FXServer with OneSync on (build 4500 or newer), `cis_libs` 1.0.0, and ESX Legacy, QBCore, or Qbox.

1. Download `cis_bridge-<version>.zip` from the [releases page](https://github.com/cisoko-net/cis_bridge/releases).
2. Unzip it into `resources` and keep the folder name `cis_bridge`.
3. Add to `server.cfg` after your framework and inventory:

   ```cfg
   ensure cis_libs
   ensure cis_bridge
   ```

4. Check it in the server console with `cis_bridge report` and `cis_bridge test`.

Start order does not matter for detection: it runs at first use and again whenever a candidate resource starts or stops. Databases are not part of `cis_bridge`: products use `oxmysql` or `cis_database` directly. Full steps and convars: [docs/INSTALL.md](docs/INSTALL.md).

## Supported targets

One adapter file each (20 files total):

| Kind | Adapter files | Realm | Target |
|---|---|---|---|
| Framework | `adapters/framework/common.lua` | both | Shared job and name shapes for QBCore and Qbox |
| Framework | `adapters/framework/esx.lua` | both | ESX Legacy (`es_extended`) |
| Framework | `adapters/framework/qbcore.lua` | both | QBCore (`qb-core`) |
| Framework | `adapters/framework/qbox.lua` | both | Qbox (`qbx_core`) |
| Framework | `adapters/framework/cis_core.lua` | both | `cis_core` 1.x |
| Inventory | `adapters/inventory/cis_inventory.lua` | server | `cis_inventory` (detected first: ships ox and qb faces) |
| Inventory | `adapters/inventory/ox.lua` | server | `ox_inventory` |
| Inventory | `adapters/inventory/qb.lua` | server | `qb-inventory` |
| Inventory | `adapters/inventory/qs.lua` | server | `qs-inventory` |
| Inventory | `adapters/inventory/codem.lua` | server | `codem-inventory` |
| Doors | `adapters/doors/ox_doorlock.lua` | server | `ox_doorlock` |
| Doors | `adapters/doors/qb_doorlock.lua` | server | `qb-doorlock` (answers `unsupported`: no server exports) |
| Target | `adapters/target/ox.lua` | client | `ox_target` |
| Target | `adapters/target/qb.lua` | client | `qb-target` |
| Appearance | `adapters/appearance/common.lua` | both | Shared read and dress of the ped |
| Appearance | `adapters/appearance/illenium.lua` | both | `illenium-appearance` |
| Appearance | `adapters/appearance/fivem_appearance.lua` | both | `fivem-appearance` (save answers `unsupported`: no server side) |
| Appearance | `adapters/appearance/qb_clothing.lua` | both | `qb-clothing` |
| Appearance | `adapters/appearance/skinchanger.lua` | both | `skinchanger` with `esx_skin` |
| Billing | `adapters/billing/esx_billing.lua` | client | `esx_billing` |

ESX's own inventory is reached through the ESX adapter when none of the five inventories is started.

## More details

<details>
<summary><b>Altered, renamed, or custom servers</b></summary>

Detection is automatic on a stock server. If your server runs two candidates, renamed resources, or custom exports, use `setr` lines in `server.cfg`:

```cfg
setr cis_bridge:framework qbcore        # esx | qbcore | qbox | cis_core
setr cis_bridge:framework_resource my-core
setr cis_bridge:inventory ox_inventory  # cis_inventory | ox_inventory | qs-inventory | codem-inventory | qb-inventory
setr cis_bridge:doors ox_doorlock       # ox_doorlock | qb-doorlock
setr cis_bridge:target ox_target        # ox_target | qb-target
setr cis_bridge:appearance illenium-appearance
setr cis_bridge:billing esx_billing
```

For renamed exports, copy the closest adapter into `adapters/custom.lua`, rename `Adapter.name` and `Adapter.resource`, select it with `setr cis_bridge:framework <name>`, and run `cis_bridge test`. Full reference: [DOCUMENTATION.md](DOCUMENTATION.md) §10.

</details>

<details>
<summary><b>Boot report & Conformance suite</b></summary>

```text
  state    kind            resource
  -------  --------------  ---------------------------------------------
  OK       framework       qbox              detected
  MISSING  inventory       -                 nothing answered
  NONE     doors           -                 not on this server
```

Console commands:
- `cis_bridge test` — read-only conformance check against your live framework and inventory (`PASS`, `FAIL`, or `SKIP`).
- `cis_bridge test write <server id> [item]` — opt-in round trip that moves 1 cash and 1 item on one player, then puts them back.
- `cis_bridge report` — prints what was detected and how to fix any `MISSING` row.
- `cis_bridge_client` — client console command for the client half.

</details>

<details>
<summary><b>Security & Trust model</b></summary>

Client asks, server decides. `cis_bridge` makes no outbound requests.

- **Server resources are trusted:** Server exports validate and bound all inputs (`ids`, `amounts`, `counts`, `item names`, `reasons`, `metadata`) and fail closed with a reason. Install only server resources you trust.
- **Purchase is pinned to one character:** Checks that the server id still holds the same character before payment and before each line. On switch, stops and logs `cis_bridge:inconsistent`.
- **Bounded client net events:** Only two player-reachable server net events exist (`appearance` reply valid for 10 s after server ask; `conformance` results bounded, truncated, and rate-limited per source).
- **Client checks:** `cis_bridge_client` is read-only apart from one temporary probe target/ped and has a 10-second cooldown.

</details>

<details>
<summary><b>Tests & Development</b></summary>

```bash
npm install
npm test          # 2659 assertions across 11 suites, no FiveM server required
npm run test:all  # + syntax check + api contract self-test + docs check
npm run test:mutate  # applies 214 known defects (test/mutations.json)
```

</details>

## Compatibility

| Item | Status |
|---|---|
| FXServer | Build 4500 or newer. OneSync must be enabled. |
| Dependencies | `cis_libs` 1.0.0. |
| Frameworks | ESX Legacy, QBCore, Qbox, and `cis_core` 1.x. |
| Contract | Frozen 1.x API ([docs/V1.md](docs/V1.md)). |

## Documentation

| Topic | Link |
|---|---|
| Install & convars | [docs/INSTALL.md](docs/INSTALL.md) |
| Product contract | [docs/V1.md](docs/V1.md) |
| Design & adapters | [DOCUMENTATION.md](DOCUMENTATION.md) |
| Exports reference | [API.md](API.md) |
| Changelog | [CHANGELOG.md](CHANGELOG.md) |
| Security policy | [SECURITY.md](SECURITY.md) |
| Licence | [LICENSE.md](LICENSE.md) |

## Support and licence

- Help: [Discord](https://discord.cisoko.net).
- Bugs and pull requests: [CONTRIBUTING.md](CONTRIBUTING.md).
- Security problems: [SECURITY.md](SECURITY.md) (report privately, never file a public issue).
- Licence: Cisoko Platform Source-Available License 1.0, in [LICENSE.md](LICENSE.md).
- More FiveM resources by Cisoko: [cisoko.net](https://cisoko.net).

Author: Cisoko. Source: https://github.com/cisoko-net/cis_bridge.
