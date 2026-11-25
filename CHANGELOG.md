# Changelog

All notable changes to `cis_bridge`. Keep a Changelog format; the version is
semantic; the **contract major** (`api = 1`) is separate from it.

---

## 1.0.0 (2026-11-02)

The first public release, and an **early access** one. The product API is
frozen for all of 1.x (`docs/V1.md` § Frozen API); what was tested on a live
server, and what only in unit tests, is listed in `docs/INSTALL.md`
§ Compatibility.

### Added

- **The v1 product API.** A product calls `exports.cis_bridge` directly for
  players, money, items, jobs, gangs, player state, usable items, notify,
  doors, interaction targets, appearance and billing, and never names a
  framework, an inventory, a doorlock or a target. The contract is
  `docs/V1.md`; every export is declared in `api.lua` and generated into
  `API.md` and `types/cis_bridge.lua`.
- **Fail closed with a reason.** No v1 export raises: each failure answers
  `false` and one of the reason codes in `docs/V1.md` § Reason codes.
  Writes for the same player are serialised; a second write while one is in
  flight answers `busy` and is never queued.
- **Detection at first use**, and again whenever a resource it could pick
  starts or stops, so start order does not matter. The boot report and
  `GetBridgeReport()` say what was picked and how: `detected`, `forced by
  convar`, or `forced, resource renamed`.
- **20 adapter files**: 18 third-party resources plus 2 shared helpers
  (`framework/common.lua`, `appearance/common.lua`):
  - frameworks: ESX Legacy, QBCore, Qbox, and `cis_core` 1.x as a peer;
  - inventories: `cis_inventory`, `ox_inventory`, `qb-inventory`,
    `qs-inventory`, `codem-inventory`, and ESX's own through the ESX adapter;
  - doors: `ox_doorlock`, `qb-doorlock`;
  - targets: `ox_target`, `qb-target`;
  - appearance: `illenium-appearance`, `fivem-appearance`, `qb-clothing`,
    `skinchanger` with `esx_skin`;
  - billing: `esx_billing`.
- **Convars for altered servers.** `cis_bridge:<slot>` forces an adapter,
  and `cis_bridge:<slot>_resource` points a forced adapter at a renamed
  resource. `adapters/custom.lua` ships empty for a server whose resource
  changed its exports.
- **`cis_bridge report`** and **`cis_bridge test`**: the boot report and the
  read-only conformance suite on the operator's own server, with
  `cis_bridge test write <server id>` for the write round trip.
- **The frozen 1.x surface.** 34 stable exports, 7 events and 47 reason
  codes are recorded in `test/frozen.json`; `npm run check:frozen` fails when
  one is removed or changed, or when a new one is not recorded.
- **`docs/INSTALL.md`** for server owners, **`SECURITY.md`** for reporting a
  vulnerability, and **`npm run package`** for the release zip.

### Deprecated

- `GetLibShim` and `GetDbProxy`, an ox_lib compatibility surface outside the
  frozen API. They stay through 1.x and go in 2.0.0, with cis_bridge's
  dependency on cis_libs for them. A product reads cis_libs or the oxmysql
  API directly.

### Notes

- `Notify` takes `inform`, the old ox_lib spelling of `info`, and hands the
  adapter `info`. cis_vehicleshop sends it.

### Tests

2659 assertions across 11 suites. The v1 suites
run every contract over each framework and inventory pair. The callers suite
replays the call shapes our own resources send, on esx, qbcore and qbox. The mutation gate
(`npm run test:mutate`) applies each known defect in `test/mutations.json`
to a copy of the repository and requires the suites to fail.

### Unverified

Not yet run live: a connected player, the write round trip, the client half,
`qs-inventory`, `codem-inventory` and `cis_core`.
