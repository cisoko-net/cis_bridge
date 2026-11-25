# cis_bridge — documentation

**Version 1.0.0.** One API for money, items, jobs, doors and interaction
targets, and one adapter file per framework, inventory, doorlock and target
behind it.

**Security posture.** Nothing outside this resource names a third-party
resource, no v1 export raises, the one handler a player can reach is rate
limited, and all three are unit tested rather than asserted. See §11.

**Nothing registered into cis_libs.** cis_bridge uses no cis_libs capability
slot (`RegisterCapability`, the slot registry), has no per-adapter exports and
ships no database or Discord adapter. Products call the v1 exports, and the
database through the oxmysql API.

---

## §0 — Read this first

Everything on your server that is not us has exactly **one file** here, and
nothing outside this resource knows any of their names. A Cisoko product is
written once against cis_bridge and runs on ESX, QBCore, Qbox and cis_core, on
four inventories, two doorlocks and two target resources.

| Resource | Owns tables |
|---|---|
| `cis_libs` | never |
| `cis_core` | one |
| **`cis_bridge`** | no |
| `cis_keys` | yes |

If you are writing a product, **[docs/V1.md](docs/V1.md)** is the contract: every
parameter, every reason code, the order a purchase runs in, and the order
things are detected in. **[API.md](API.md)** is the export reference, generated
from `api.lua`. This file is the rest: why the design is what it is, what the
operator can run, and how to add a target.

API.md is **generated** and `npm run docs:check` fails if it is not what
`api.lua` and the source would produce. A hand-written reference is wrong within
two releases; this one is wrong only if somebody skips the check.

---

## §1 — The product API

A product calls `exports.cis_bridge` and gets a value, or `false` and a reason.
It never names a framework, an inventory, a target or a doorlock.

| Realm | Exports |
|---|---|
| Server | `GetPlayer`, `IsLoaded`, `GetMoney`, `AddMoney`, `RemoveMoney`, `GetItemCount`, `CanCarry`, `AddItem`, `RemoveItem`, `GetJob`, `SetJob`, `Notify`, `Purchase`, `GetDoorLock`, `SetDoorLock`, `GetSummary`, `GetOwnedVehicleId`, `SaveAppearance`, `GetGang`, `GetPlayerState`, `UseItem`, `GetSourceByCharId` |
| Client | `GetPlayerData`, `IsLoaded`, `Notify`, `AddTargetZone`, `AddTargetEntity`, `RemoveTarget`, `GetAppearanceComponent`, `ApplyClothing`, `HasBilling`, `GetBills`, `PayBill` |
| Operator, server | `RunConformance`, `GetConformanceResults`, `GetBridgeReport` (§6, §8) |
| Migration, server | `GetLibShim`, `GetDbProxy` (§5) |

`IsLoaded` and `Notify` exist in both realms with different signatures.

A product may call the exports directly or take the facade, which is one global
that forwards each field to the export of the same name and holds no state:

```lua
-- fxmanifest.lua of a product
shared_scripts { '@cis_libs/init.lua', '@cis_bridge/init.lua' }
dependencies { 'cis_libs', 'cis_bridge' }
```

```lua
local ok, reason = CisBridge.Purchase(src, { item = 'water', count = 2, price = 10, account = 'cash' })
```

The facade caches nothing, so a cis_bridge restart never leaves a product
holding a stale reference.

The properties that make it safe to build on:

- **No export raises.** Every call into a framework or inventory runs under
  `pcall`; a raise becomes `false, 'error'` and one console line.
- **Failure is `false, reason`**, with `reason` from a closed list. Never `nil`
  first, because a bare `nil` truncates an export's return list.
- **The bridge validates before the framework sees anything.** ESX throws on an
  amount of zero or less, QBCore returns `nil`, Qbox returns `false`, and ESX with
  ox_inventory lets NaN through. One validation layer gives one set of answers.
- **Writes are proved, not trusted.** Every money and item write reads the
  balance or the count back, and the write counts as done only when it moved by
  exactly the amount. A framework that answers success without writing is caught.
  A partial add is taken back, and `cis_bridge:inconsistent` fires when it
  cannot be. A partial remove answers `false, 'partial'` and fires
  `cis_bridge:inconsistent` with the count that went (the export returns no
  count); nothing is added back, because a plain add makes
  fresh units without the weapon serial or durability the removed ones had.
- **One lock per player.** A write for a player who already has one in flight
  answers `busy` at once. It never queues, because a queue hides a stuck adapter.
- **`Purchase` is in the bridge**, so a product cannot get the order wrong:
  check carry, take the money, give every line, and on any failure take back
  what landed and refund the rest.

Local events cis_bridge fires, the same on every framework, are
`cis_bridge:playerLoaded`, `playerUnloaded`, `jobChanged`, `inconsistent`,
`refundFailed` and `doorChanged`; the table with arguments is in V1.md. They are
local `TriggerEvent`s, so no client can fire them.

---

## §2 — Why it is a separate resource

**Because `ox_inventory` is GPL-3.0.** That is not a formality. It is on roughly
half of all servers, actively maintained, and a hard dependency of Qbox.
Vendoring it, or modifying it, or wrapping it in a way that is hard to separate
puts our licence and our customers' servers in a position nobody wants to be in.

**One adapter file, optional, never vendored, never modified** is the entire
mitigation — and the isolation is only real if nothing outside that file names
`ox_inventory`. That is an invariant this resource is built around, not a habit.

The same reason, less sharply, applies to everything else here. A target we do
not support is a target a customer cannot use, and the cost of that is paid by
them. One file per target is the unit of support, and the conformance test is
the unit of proof.

It is also why cis_bridge stopped registering into cis_libs. With a slot, two
providers could answer the same product call, each with its own idea of whether
the money moved. Now there is one place that answers, and it proves the answer.

---

## §3 — Install and detection

```cfg
ensure cis_libs
ensure <your framework and inventory>
ensure cis_bridge
```

cis_bridge depends on `cis_libs` only for the `lib` shim (§5). The v1 API needs
nothing from it, and `@cis_libs/init.lua` is no longer loaded by this resource.
Every framework, inventory, doorlock and target is an optional runtime target.

**Detection runs at first use, and again whenever a resource it could pick
starts or stops.** There is no start-order wait: the answer is
recomputed when the situation changes, so `ensure cis_bridge` above or below
`ensure ox_inventory` both work. A product that calls before its framework is
up gets `false, 'no_framework'` rather than a hang.

Framework order, server and client independently:

1. the convar `cis_bridge:framework`, if set and that resource is started;
2. `qbx_core`, then `es_extended`, then `qb-core` (only while `qbx_core` is
   **not** started, because Qbox provides `qb-core`), then `cis_core`.

`cis_core` is last because it wraps the other three: on a server running one of
them, talking to the framework directly is one hop shorter and does not inherit
cis_core's quirks. Inventories are tried as the convar `cis_bridge:inventory`,
then `cis_inventory`, `ox_inventory`, `qs-inventory`, `codem-inventory`,
`qb-inventory`, then the framework's own (ESX). `cis_inventory` is first because
it ships faces under the `ox_inventory` and `qb-inventory` names. Doors are `cis_bridge:doors`, then `ox_doorlock`, then
`qb-doorlock`. Clothing resources, for `SaveAppearance`, are
`cis_bridge:appearance`, then `illenium-appearance`, `fivem-appearance`,
`qb-clothing`, `skinchanger`. Targets, on the client, are `cis_bridge:target`, then
`ox_target`, then `qb-target`.

```cfg
setr cis_bridge:framework qbcore     # esx | qbcore | qbox | cis_core
setr cis_bridge:inventory qs-inventory
```

`setr`, not `set`: the client detects on its own and reads the replicated value.
Unset is the normal case and means "work it out". The full order, and why each
step is where it is, is V1.md § Detection.

**Databases and Discord are not here.** Products use `oxmysql` directly, or
`cis_database`, which provides it. Outbound Discord logging will be a cis_libs
primitive.

The live-verification procedure is
**[test/live/RUNBOOK.md](test/live/RUNBOOK.md)**.

---

## §4 — The adapters

Every adapter has the same job: translate. Validation, balance checks, the
read-back, the lock and the reason codes live in `server/v1.lua` and
`client/v1.lua` and are the same on every framework; an adapter that reimplemented
any of them would be a place for the frameworks to disagree again.

Each adapter file publishes itself into a table owned by this resource, which
`server/v1.lua` or `client/v1.lua` reads when it loads. Nothing is registered
anywhere else. Every export on a third-party resource is called with a colon
(`exports.res:Fn(a)`): FiveM's export proxy drops its first argument, so a dot
call silently runs `Fn()`.

### 4.1 Frameworks (both realms)

`adapters/framework/{common,esx,qbcore,qbox,cis_core}.lua`. Each file holds a
server half and a client half. `common` is the job and name normaliser shared by
the two QB-shaped frameworks.

| | ESX Legacy | QBCore | Qbox |
|---|---|---|---|
| Fetched with | `getSharedObject` | `GetPlayer`, a flattened copy | `exports.qbx_core:<Fn>` |
| Character id | `identifier` | `citizenid` | `citizenid` |
| Job grade key | string | string | integer |
| Pay | `grade_salary` | `grade.payment` | `job.payment` |
| Trap | methods are closures: **dot** calls | `PlayerData` is a snapshot: read money through `Functions.GetMoney` | money type names are case-sensitive; bank has no floor |

The grade is an integer everywhere in the contract; the adapter converts to the
key type its framework uses. The character name is built from the character's
first and last name, never the FiveM account name.

`cis_core` 1.x is a peer adapter over `exports.cis_core:CisCoreFramework()`;
cis_core 2.0.0 removed that export, so the adapter needs cis_core 1.x. Its money
calls answer the `pcall` status, not the framework's
result, and it fires no player or job events. The read-back is what makes its
money answers true; the bridge seeds its loaded set from `GetPlayers()` and fires
`cis_bridge:jobChanged` itself.

### 4.2 Inventories (server)

`adapters/inventory/{cis_inventory,ox,qb,qs,codem}.lua`, plus the ESX native
inventory through the ESX adapter.

| Adapter | The difference that matters |
|---|---|
| `cis_inventory` | Cisoko's own. All-or-nothing writes that name the slots they landed in, so a take-back removes from exactly those slots. A count answered with a reason other than `unknown_item` is no count (`not_loaded`) |
| `ox` | ox_inventory is GPL-3.0; the bridge only calls its exports, from this one file. `AddItem` has no weight check, and a non-stackable add can land **partially** and still answer `true` |
| `qb` | The slot argument comes **before** metadata. Item names are compared case-exact against a lowercase table, so the bridge lowercases first |
| `qs` | Paid and closed; calls come from its public docs. `RemoveItem`'s return is undocumented |
| `codem` | Paid and closed. No carry check, so `CanCarry` answers `true`; no documented return values |

Those differences are why the count is the proof. `AddItem` checks `CanCarry`
first, reads the count before and after, puts back what moved if fewer than asked
did, and answers `partial`, `cannot_carry` or `refused`. For `qs` and `codem` the
count check is the only proof there is.

**Nothing is registered on the client.** A client-side inventory would be a second
source of truth about what a player carries.

#### `GetItemCount`, not `Search`

Both ox_inventory exports answer "how many", and they answer differently:

| | item the player does not have | inventory that does not exist yet |
|---|---|---|
| `GetItemCount(inv, item)` | `0` | `0` |
| `Search(inv, 'count', item)` | `0` | `false` |

The contract promises an integer, never `nil`, so the adapter uses the export
that returns one. Otherwise a player who has not finished spawning looks like an
inventory outage.

### 4.3 Doors (server)

`adapters/doors/{ox_doorlock,qb_doorlock}.lua`. A door id is an integer (an
ox_doorlock id) or a string of 1 to 64 characters (a door name).

`ox_doorlock` reads and sets a door's state through its exports; called from an
export it runs no permission check, so the **product** decides who may toggle
what. `qb-doorlock` has no server exports. Its state changes only through a net
event that wants a loaded player and trusts client-supplied arguments, and the
bridge will not drive a door through that hole, so both calls answer
`unsupported`. A product learns that the resource is present and cannot be
scripted from the server, which is more useful than a fake answer.

### 4.4 Targets (client)

`adapters/target/{ox,qb}.lua`. The product hands over one canonical option shape,
`{ label, icon, distance, onSelect(entity), canInteract(entity) }`, and the
adapter translates it.

**Why two files and not one with a flag.** `qb-target` takes a box zone as a
length, a width and a `minZ` / `maxZ` pair; `ox_target` takes a vector3 size.
`qb-target` wants `action(entity)` and the distance beside the option list;
`ox_target` wants `onSelect(data)` with the entity at `data.entity`. That is a
different API, not a parameter.

**Removals return nothing.** Both resources' removal calls return `nil`, so the
return value cannot be a success flag: reading it reports failure for a removal
that worked. The adapter keeps the ids the target resource handed back, and
success is decided from that record.

A target belongs to the resource that added it and is removed when that resource
stops, so a restarted product does not leave dead zones behind.

### 4.5 Appearance (both realms)

`adapters/appearance/{common,illenium,fivem_appearance,qb_clothing,skinchanger}.lua`.
The client reads and dresses the ped through the natives
(`GetAppearanceComponent`, `ApplyClothing`), so those work whatever put the
clothes on. `SaveAppearance(src)` stores the look through the clothing
resource, in two halves: the server prepares the resource and asks that
player's client to send the resource's own save event. skinchanger with
esx_skin 1.16 or newer saves on the server instead: the client sends the
clothing keys back through `cis_bridge:appearance:reply`, and esx_skin's
`SaveOutfit` stores only those keys. An older esx_skin gets an edit session
(`BeginSkinEdit`) and the client's `esx_skin:save`. fivem-appearance has no server side and answers
`unsupported`. qb-clothing's skin also holds the face, which no native reads
back, so its client half reads every clothing key and the hair off the ped
and replies, and the server merges them into the citizen's active
`playerskins` row through oxmysql, which keeps the face. With no row, or
without oxmysql, nothing is saved. The full table is V1.md § Appearance.

### 4.6 Billing (client)

`adapters/billing/esx_billing.lua`. `HasBilling()`, `GetBills(after?)` and
`PayBill(id)` list and pay the local player's bills through the billing
resource's own client callbacks, so the money moves inside its own locks and
journal; the bridge only bounds the call and the answer. Both calls wait for
the reply, so call them from a thread; after 10 s they answer `timeout`.
esx_billing 1.16.3 on es_extended is the one billing resource so far; the
convar `cis_bridge:billing` forces a choice. Without one every call answers
`no_billing`. The full contract is V1.md § Billing.

---

## §5 — The `lib` shim (server)

`GetLibShim` covers part of ox_lib's `lib.callback`. Its `lib.zones` answers `false` and a reason,
because cis_libs registers its zone exports on the client only; create zones
from a client script with `Cis.zones`. They are not a drop-in ox_lib: the
server `lib.callback.await` takes `(name, delay, target, cb, ...)`, not
ox_lib's `(event, playerId, ...)`. A resource that needs that reads ox_lib
directly. `GetDbProxy` answers `false` and a reason: it forwarded to cis_libs'
`Db*` exports, which answer only when a resource registers the `database`
capability, and none Cisoko ships does. Use the oxmysql API, served by oxmysql
or cis_database. This is
compatibility, outside the v1 API, and the one reason `cis_libs` is still a
dependency.

```lua
local lib = exports['cis_bridge']:GetLibShim()
```

**Why an export and not a `lib` global.** Each FiveM resource has its own Lua
state, so a global written in cis_bridge is a different variable from the one a
consumer reads. A shim that "installs lib" installs it for itself and nobody else,
which looks like a working drop-in on the machine it was built on and does
nothing on a customer's. One line in the consumer is not nothing: it **says** the
dependency is there, so removing cis_bridge is something you find out from your
own source.

| Surface | Translation |
|---|---|
| `lib.callback.await(name, delay, target, cb)` | `TryAwaitCallback(name, ...)`; **delay and target are DROPPED**, because there is no target argument |
| `lib.callback.register` | `RegisterCallback` |
| `lib.callback.call` / `.send` | `CallCallback`, and its answer is returned unchanged. ox_lib's `lib.callback(...)` on the table itself is not offered: the shim crosses the export boundary as a copy, which drops metatables; write `lib.callback.send(...)` |
| `lib.zones.box/sphere/poly` | `false` and a reason: zones are client-only in cis_libs |
| `lib.zone(id)` | an object whose `:remove()` and `:contains()` answer `false` and the same reason |

Two rules, each pinned by a test:

1. **`TryAwaitCallback`, never `AwaitCallback`.** The latter calls `error()` on a
   refusal by design. ox_lib *answers* `false`, so the raising form turns a
   missing callback into an exception inside a consumer that never expected one.
2. **A refusal is passed through with its reason unchanged.** Every consumer
   branches on that string.

The zone calls touch no engine: there is no server zone to create, so the shim
answers without calling cis_libs.

---

## §6 — Conformance

```
cis_bridge                          # same as `cis_bridge test`
cis_bridge test                     # read-only
cis_bridge test write <server id> [item]   # opt-in round trip on one player
cis_bridge report                   # what was detected, and what to do about it
cis_bridge_client                   # client console: the client half
```

### 6.1 Why

Third-party resources change under us, and every one of those changes arrived as
a bug report that looked like a bug in somebody's server. `ox_target` changed how
it handles zones; `qb-target` returns nothing from a removal; ESX with
ox_inventory let NaN through; cis_core answers the `pcall` status instead of the
result. The unit suites run every contract against fakes that follow each
framework's source. The conformance run is the same contracts against the
framework and inventory this server **really has**, so a fake that drifted from
upstream shows up as a `FAIL` here and not as a customer's lost money.

### 6.2 What is checked, and what is written

**What a check is pointed at: the v1 contracts themselves.** Not an adapter in
isolation. The adapters are only reached through `server/v1.lua`, and a check
that bypassed it would test a path no product takes.

`cis_bridge test` **writes nothing**. It checks:

| Group | Checks |
|---|---|
| `detect` | the framework, the inventory, and (optionally) a door resource were found |
| `refuse` | `GetPlayer`, `GetMoney`, `AddMoney`, `RemoveMoney`, `AddItem`, `Purchase` and `SetJob` on source `0` answer `bad_source`; `GetDoorLock` on a bad id answers `bad_door`. Every contract owes a bad argument `false, reason`, never a raise and never a write |
| `player N` | for each connected player: `GetPlayer` is a table, `GetJob` has a name and grade, `GetMoney` for cash and bank is a whole number, `GetItemCount` is a count, `CanCarry` answers |

`cis_bridge test write <server id> [item]` additionally changes **one named
player**: +1 then −1 cash, +1 then −1 of the item (default `water`), and a
1-cash `Purchase` that is then undone by hand. Every write is paired with its
reverse and verified by reading the balance and count back, so a passing run
leaves the player as it found them; a failing one says which step failed and what
to put back. It exists because a contract that is never exercised on the real
inventory is a contract that has not been checked, and it needs a named player
because a test that gives an anonymous player an item is a test that can leave
one with it. An item the server does not have, or a full inventory, is a `SKIP`
that says so.

The final server line is the tally:

```
cis_bridge: 14 passed, 0 failed, 3 skipped
```

### 6.3 `SKIP` is not `FAIL`

A server with no door resource, no connected player, or no cash to spend on the
purchase check is not broken, and a `FAIL` line for it would bury the one result
the operator came for. Skipped checks are tallied separately so you know how much
of the run actually executed.

### 6.4 The client half

Targets are a **client** concern, so the server asks every connected client to
run its own half after the server checks, and prints what comes back. A target
resource can be started on the server and still be broken on a client, and a
client that cannot create a zone produces a door that does not respond — which
looks exactly like a server-side permission problem.

The client checks, with names that are obviously ours:

- `IsLoaded` agrees with `GetPlayerData`;
- `Notify` refuses an empty message (`bad_message`; a real notification would
  show on every player's screen);
- an unknown zone kind is refused (`bad_target`);
- removing an unknown name is refused, not fatal (`unknown_target`);
- a sphere zone is created, a second under the same name is refused (`exists`),
  it is removed, and a second removal finds none — the check that actually breaks;
- a box zone is created and removed;
- a target is created on a **real spawned ped** and removed. Both target
  resources silently do nothing for an entity that does not exist, so without a
  real ped the one case that differs between them goes untested. The ped is
  deleted before the function returns, even when the check raises.

With neither target resource started it reports `SKIP` with `no_target`. A client
`PASS` is an observation from a machine we do not control, so the server prints
and counts but never treats it as proof of anything it did not check itself. The
client half also runs on demand with `cis_bridge_client`; it is unrestricted so a
developer need not be an admin, and throttled for the reasons in §11.

### 6.5 Programmatic access

```lua
exports['cis_bridge']:RunConformance()          --> boolean (the read-only run)
exports['cis_bridge']:GetConformanceResults()   --> { { target, name, ok, skipped, detail }, ... }
```

`RunConformance` is `cis_bridge test` and never writes to a player; the write
round trip is console-only. The results are the answer to "is this a broken
adapter or an incompatible target?", the first half of every support thread.

---

## §7 — Threads, loops and the frame budget

The rule is that nothing runs per-frame unless it is drawing, and the budget is
0.00–0.02 ms idle. cis_bridge has **three loops and two delayed threads**, and
none of them runs while nothing is happening:

| Where | What | Bound | When it fails |
|---|---|---|---|
| `client/conformance.lua` | the model probe | on demand only, 50 ms poll, 5 s deadline | the client check fails with "a_m_m_business_01 did not load within 5000ms" |
| `client/v1.lua` | the billing reply poll | once per `GetBills` or `PayBill`, 50 ms poll, 10 s deadline | the call answers `false, 'timeout'` |
| `client/v1.lua` | the loaded relay | once per framework loaded event, 100 ms poll, 10 s deadline; a newer loaded event ends the older wait | it prints a warning and relays `cis_bridge:playerLoaded` anyway |
| `client/v1.lua` | the appearance settle | one thread per appearance change, a single `Wait(1500)`; only the newest one fires | nothing to fail: it fires `cis_bridge:appearanceLoaded` or returns |
| `server/report.lua` | the boot printout | one thread, a single `Wait(1000)`, then it returns | nothing to fail: it prints once and returns |

`test/perf.lua` enforces the account: no `Wait(0)` in shipped code, every loop
waits, and a loop that is not in the account, by file and condition, is a
failure. That last rule is what makes the account mean something rather than
describing today.

**The model probe used to be `Wait(0)`**, the shape everybody writes:

```lua
while not HasModelLoaded(hash) and GetGameTimer() < timeout do
    RequestModel(hash)
    Wait(0)
end
```

`RequestModel` is idempotent, so every call after the first is an identical native
doing nothing, and the loop is hundreds of scheduler wakeups checking a flag the
streamer sets on its own schedule. The request is made once and polled at 50 ms.

There is no drawing in this resource: no `DrawMarker`, `DrawText3D` or
`DrawRect`, no NUI, no spatial queries. `test/perf.lua` asserts that too, so
adding one becomes a decision rather than a paste.

---

## §8 — The boot report

Printed once at boot, and on demand with `cis_bridge report`.

Support is roughly seventy percent of this company's cost base. The cheapest
thing that moves it is an answer that arrives without a ticket, so every row
carries three things: the outcome, the sentence that explains it, and the next
step.

```
  state    kind            resource
  -------  --------------  ---------------------------------------------
  OK       framework       qbox              detected
  MISSING  inventory       -                 nothing answered
  NONE     doors           -                 not on this server
  (targets are picked on each client: the client half of `cis_bridge test` reports them)

  1 required resource(s) missing: products that use cis_bridge will refuse.

  what to do about the rows above:
    inventory      start cis_inventory, ox_inventory, qs-inventory, codem-inventory or qb-inventory before cis_bridge, or name it with `setr cis_bridge:inventory <name>`
    doors          only needed by products that lock doors: start ox_doorlock or qb-doorlock

  Next: run `cis_bridge test`. It reads, and writes nothing to a player.
```

There are three rows — framework, inventory, doors — and three labels:

| Label | Means | Counts as broken |
|---|---|---|
| `OK` | detected | no |
| `MISSING` | a required kind (framework, inventory) nothing answered for | yes |
| `NONE` | doors only: no door resource, which is a valid server | no |

Targets are not a row because they are picked per client; the client half of the
conformance run is where they are reported.

```lua
exports['cis_bridge']:GetBridgeReport()
--> { { kind, label, target, detail, fix }, ... }
exports['cis_bridge']:GetSummary()
--> { api, version, framework, inventory, doors }
```

`GetSummary` is the short form for a support thread. The report never prints a
webhook, a credential, a config value or a player identifier: only the names of
third-party resources, which are already in the operator's `server.cfg`.

---

## §9 — Extending

Adding a target is one adapter file plus its coverage in the unit world.

1. Create `adapters/<kind>/<target>.lua`, where kind is `framework`, `inventory`,
   `doors` or `target`.
2. Implement the methods the sibling adapters implement, matching the contract in
   V1.md. Translate only; validation, the balance check, the read-back and the
   lock are not the adapter's job.
3. Publish the adapter into its kind's table at load, as the siblings do. The
   first adapter of a kind creates the table; later ones add to it.
4. List the file in `fxmanifest.lua` **before** `server/v1.lua` (or `client/v1.lua`
   for a target). The consumer reads the table when it loads, so the manifest
   order is a correctness property, and `test/contract.lua` asserts it.
5. Add a fake for the target to `test/lib/v1world.lua` so `test/v1.lua` (or
   `test/v1-client.lua`) runs every contract against it. A fake follows the
   target's source, not a remembered API.
6. Add the file to the shipped list in `test/perf.lua`, to `tools/audit-docs.js`, the
   README table and §4 here. The audit fails on an adapter file nobody decided to
   ship.

**Never vendor, never modify, never copy.** Read the target's source to
understand it; the one-file rule is the whole mitigation and copying breaks it
silently. Verify export signatures against the target's own source, not against a
remembered API: every third-party shape this resource adapts was checked against
upstream, and the ones written from memory were wrong.

---

## §10 — Configuration this resource reads

**cis_bridge has no config file of its own.** Two config files describing one
server is two places to be wrong. It reads **convars**, which a server already
has, and every value is a **resource name to look for**, never a connection
string.

| Convar | Realm | Accepted | Default |
|---|---|---|---|
| `cis_bridge:framework` | both | `esx`, `qbcore`, `qbox`, `cis_core` | detected |
| `cis_bridge:inventory` | server | `cis_inventory`, `ox_inventory`, `qs-inventory`, `codem-inventory`, `qb-inventory` | detected |
| `cis_bridge:doors` | server | `ox_doorlock`, `qb-doorlock` | detected |
| `cis_bridge:target` | client | `ox_target`, `qb-target` | detected |
| `cis_bridge:appearance` | both | `illenium-appearance`, `fivem-appearance`, `qb-clothing`, `skinchanger` | detected |
| `cis_bridge:billing` | client | `esx_billing` | detected |

Set them with `setr` so the client sees them. A convar that names no adapter,
or an adapter whose resource is not started, is not obeyed and nothing is picked
for that slot, rather than quietly falling back to something the operator did
not ask for. Detection prints one plain line for it, once, in the server console
or F8:

```
cis_bridge:framework is 'qbcor', which is not an adapter. Use one of: cis_core, esx, qbcore, qbox
cis_bridge:inventory is 'ox_inventory', but ox_inventory is not started
```

The report row then says `convar names no usable adapter` and shows the same
line as its fix.

**Renamed resources.** A server that runs a framework or inventory under
another resource name (qb-core started as `my-core`) names it with
`cis_bridge:<slot>_resource`, beside the slot's forcing convar:

```
setr cis_bridge:framework qbcore
setr cis_bridge:framework_resource my-core
setr cis_bridge:inventory ox_inventory
setr cis_bridge:inventory_resource my-inventory
```

The slots are `framework`, `inventory`, `doors`, `appearance`, `target` and
`billing`. The forced adapter checks, watches and calls the renamed resource;
every other adapter keeps its own name. The override needs the forcing convar:
the bridge never guesses which adapter a renamed resource is, so set alone it
picks nothing and prints
`cis_bridge:framework_resource is 'my-core', but cis_bridge:framework is not set. Set both: setr cis_bridge:framework <adapter>, where <adapter> is one of: cis_core, esx, qbcore, qbox`.
A renamed resource that is not started says so like any forced one. The
boot report row says `forced, resource renamed to my-core`.

**Renamed or changed exports.** When a resource renamed its functions (a
qb-core whose `GetPlayer` export is `FetchPlayer`), no convar can fix the
call: write your own adapter in `adapters/custom.lua`. The file ships empty
and loads in both realms as a shared script, so after the framework and
appearance adapters and before the inventory, doors, target and billing ones;
an adapter under a new name survives them all. Copy the closest
built-in adapter into it, give it a new `name` and register it under that
name (`CisBridgeFrameworks.my_qbcore = Adapter`), set `resource` to your
resource, and change only the renamed calls. Pick it with the slot's convar
(`setr cis_bridge:framework my_qbcore`): a custom adapter is never
auto-detected. `cis_bridge test` checks it like a built-in one. The steps,
including the realm guard for server-only and client-only slots, are at the
top of the file. An update ships the empty file again, so keep a copy.

Because cis_bridge registers nothing into cis_libs, it needs no entry in
cis_libs' `Security.AuthorizedResources` for its own work.

### What this resource does NOT read

- No webhook URLs, no database credentials, no connection strings, no ACE groups.
- No operator feature switches. Nothing here sends anything outbound.

---

## §11 — Security notes

| Control | What it does |
|---|---|
| No vendoring | GPL isolation for `ox_inventory` is a file boundary, and a file boundary is only real if nothing crosses it |
| No outbound requests | cis_bridge makes none. It has no Discord logging |
| No net events on the server except two | Framework events are subscribed with `AddEventHandler` only, so no client can fire them |
| Bounded client payload | The conformance-results handler is reachable by any connected player; the table is capped at 64 rows and every field is truncated before printing |
| **Rate limit on the client handler** | That handler prints to the console on every accepted call. Five seconds per source, refusals dropped without a log line, `playerDropped` cleanup |
| **Validate before announcing** | A payload with no valid rows prints **nothing**: not a header, not a summary, not a name. Junk must not produce a block of console that reads like a report arrived |
| **Rows counted before they are shown** | Junk rows do not consume the 64-row budget, so 10,000 of them cannot displace the one real result |
| **Client command cooldown** | Ten seconds. `cis_bridge_client` allocates a ped and zones per run and is reachable by any player |
| Clock failure falls **closed** | If the clock is absent, nil, a string, or raises, the cooldown refuses rather than opening |
| Reads by default | `cis_bridge test` writes nothing. The write round trip needs the console and a named player |
| Console-only command | `cis_bridge` is `restricted`, and the handler refuses every caller but the console (source 0), so no ACE opens it in game. A player who tries it is told to use the console |
| No secrets in the report | Names of third-party resources only |

### 11.1 The two player-reachable surfaces

The server registers exactly **two** net events a player can reach:

```
cis_bridge:server:conformanceResults   (client -> server)
cis_bridge:appearance:reply            (client -> server)
```

The client registers `cis_bridge:client:conformance` and the four framework
client events it relays (`esx:playerLoaded`, `esx:setJob`,
`QBCore:Client:OnPlayerLoaded`, `QBCore:Client:OnJobUpdate`). Those arrive from
the server and the client acts only for the detected framework. It also
registers `cis_bridge:appearance:save` and the clothing resources' load events;
a client firing one at itself only saves or announces its own look.

The conformance handler has three defences, because these two handlers are the
only places where an attacker with a Lua executor can make the **server** do
something:

| Defence | Against |
|---|---|
| Payload must be a table, ≤ 64 rows | A malformed or enormous packet reaching the printing loop |
| Every string truncated (46 / 120 chars) | Terminal escape sequences and log-line injection |
| **Per-source cooldown, 5 s** | A flood that crashes nothing but scrolls the operator's only window past the report they asked for |

The appearance reply saves only what the server asked for. It is dropped
unless `SaveAppearance` asked that player in the last 10 s, it is taken once
per ask, its adapter name must match the detected one, and only the clothing
keys are read from it, each one checked as a whole number in range before
esx_skin's `SaveOutfit` sees it.

The cooldown lives in `server/ratelimit.lua` and has its own suite. Three
properties are asserted rather than assumed, because each is a way for a guard to
quietly stop guarding:

- **per source, not global** — a global guard lets one player lock everyone else
  out of the report;
- **forget on `playerDropped`** — FiveM recycles server ids, so without cleanup
  the next player to receive a used id has their first request refused;
- **clock failure falls closed** — an absent, nil, string-valued or raising clock
  refuses rather than opening.

`server/ratelimit.lua` publishes `CisBridgeRateLimit` for `server/conformance.lua`,
and the manifest lists it first (§13).

**What is deliberately not defended against:** anything in your `server.cfg`
already has every permission you have. These are guards against accidents.

---

## §12 — Tests

```
npm install
npm test          # 2659 assertions, no FiveM server required
npm run test:all  # + syntax check + the api contract self-test
                  # + lint + the generated-docs check + the count check
```

**The count is checked, not trusted.** It appears in four files — this one, the
README, the changelog and a comment in the workflow — and it was wrong in three of
them at least once while `test:all` stayed green. `npm run check:counts` runs the
suites, sums what they reported, and fails when any file that quotes the number
disagrees. It checks the suite count too, which is a separate claim and drifts
separately.

Eleven suites, each in a **fresh Lua state** so one cannot read another's globals:

| Suite | What it covers |
|---|---|
| `test/report.lua` | the boot report: every detection outcome produces a row with a cause and a fix |
| `test/ratelimit.lua` | the cooldown: ten thousand calls in one instant, per-source isolation, `playerDropped` cleanup, a recycled source id, a clock that goes backwards, a clock that is nil or raises, and malformed sources |
| `test/contract.lua` | **compliance with cis_libs**, read from the source on disk: the manifest requirements, **no capability-slot call of any kind, no cis_libs `Bridge` registration, and no bridge registry file in the manifest (the slot system was removed in 2.0.0)**, no deprecated API, every cis_libs export called actually existing, realm boundaries, the manifest's load order, and no internal cis_libs files included |
| `test/globals.lua` | every shipped file loaded against a stubbed engine with a `_G` watcher on `__newindex`: no file writes an undeclared global, and each declared global is created only by the file that owns it |
| `test/handler.lua` | **the player-reachable surface, attacked.** Every payload category against `cis_bridge:server:conformanceResults`: wrong types, 10,000 rows, a megabyte-long string, 10,000-deep nesting, terminal escape sequences, format specifiers, and a 5,000-call flood. Plus both commands' ACLs |
| `test/perf.lua` | **`Wait()` discipline**, checked against the source: no `Wait(0)`, every loop waits, every loop is in the written account, and no draw calls |
| `test/runner.lua` | **the conformance runner itself**, headless, against a fake v1 API that holds its own money and counts: PASS/FAIL/SKIP counted separately, a missing API or a raising contract counted once, the write round trip leaving the player as found, the client half asked on every run |
| `test/shim.lua` | the `lib` shim: callback translation, the server zone refusals, and the two rules in §5 |
| `test/v1.lua` | **every server contract, on every framework and inventory pair**, against fakes that keep one store; the failure paths a live server only shows under load (partial add, failed put-back, failed refund, a raising adapter, two writes for one player) |
| `test/v1-client.lua` | the client contracts: player data, notify, and each canonical target option as the target resource receives it, with `onSelect` called the way that resource calls it |
| `test/callers.lua` | **the call shapes our own resources really send** (`release/caller-shapes.md`), on esx, qbcore and qbox: the argument types and the first value or `ok, reason` pair each caller reads, plus the shapes the bridge refuses on purpose (Notify kind `inform`, the unexported `GetItemSlots` / `SetItemMetadata`, a summary with no `features`) |

The technique worth knowing: the fakes **record the exact table they were
handed**, because the interesting question is almost never "what did it answer" —
it is "what did it ask for". A qb-clothing save that drops the stored face is
invisible to a fake that only returns a value, and a framework that answers success without writing is
invisible to one that does not keep a store.

**`test/globals.lua` watches what RUNS, and that is not enough.** A missing
`local` inside a function no suite ever calls is invisible to it, which was
verified by applying exactly that mutation and watching nothing fail. So
**luacheck is the authority on undeclared names and CI installs it**, while this
runs everywhere, including on a machine with no Lua toolchain, and catches the
writes that actually happen. Both run; neither is described as the other.

Every fix in this resource ships with an assertion that was **observed failing
first**. The mutation gate (`npm run test:mutate`, `tools/mutate.js`) proves
the suites bite: each row of `test/mutations.json` is a known defect (the lock
off, a partial add read as success, stuck units refunded, a refund that may
have landed reported as failed, a re-detect mid-write, a shipped `require`,
and 178 more). The gate applies one row to a copy of the repo and requires the
suite to fail; a row whose text no longer matches the source is STALE and
fails the gate too. The rest is tested where it can actually fail: on a live
server, by `cis_bridge test`.

---

## §13 — Layout

```
fxmanifest.lua        depends on cis_libs (for the shim only)
init.lua              the CisBridge facade. fetched by clients, loaded by products
api.lua               data. the contract. not loaded at runtime
API.md                generated from api.lua + the source. checked
docs/V1.md            the product contract
types/cis_bridge.lua  generated LuaCATS annotations. never loaded
adapters/
  framework/    common, esx, qbcore, qbox, cis_core    (both realms)
  inventory/    cis_inventory, ox, qb, qs, codem        (server)
  doors/        ox_doorlock, qb_doorlock                (server)
  target/       ox, qb                                  (client)
  appearance/   common, illenium, fivem_appearance, qb_clothing, skinchanger (both)
server/
  v1.lua            the server contracts, detection, the lock, Purchase
  report.lua        the boot report
  lib.lua           the lib shim exports
  ratelimit.lua     the per-source cooldown
  conformance.lua   the runner and the server half
client/
  v1.lua            the client contracts and target records
  conformance.lua   the client half
shared/lib/shim.lua
test/  tools/
```

**One file publishes a global for the file that reads it, and the manifest orders
them:** `server/ratelimit.lua` publishes `CisBridgeRateLimit`, which
`server/conformance.lua` reads. The adapters follow the same rule: each is listed
before `server/v1.lua` or `client/v1.lua`, which read what they published.

These were once `require`d by dotted path, which was a **boot-blocking
unknown**: not one dotted `require` exists between the sibling resources, and if
FiveM's `require` did not resolve resource-relative dotted paths the resource
would not start at all. So the ordering is a correctness property, and
`test/contract.lua` checks it: swapping two lines in `fxmanifest.lua` fails a
test. Being modules rather than inlined code is what lets the unit suites load
them without the engine.

---

## §14 — Licence

The Cisoko Platform Source-Available License, version 1.0. See `LICENSE.md`.
The copyright notice and the licence must stay with every copy.
Third-party resources are not vendored, modified or relicensed here, and remain
under their own licences.

---

**Author:** Cisoko · **Docs:** <https://cisoko.net/docs/cis-bridge/> ·
