# cis_bridge — live verification runbook

**Everything else in this repository runs without a game.** 2659 assertions
across eleven suites under fengari, a syntax check, a real luacheck, an
API-contract validator with its own fixtures, a generated documentation check,
and a GPL-isolation grep.

None of that can tell you whether `ox_inventory` answers the way the fake says
on *your* server. This file is what is left, and it is short on purpose: a
runbook nobody finishes is worse than no runbook, because the person who needs it
is already out of time.

**Tracked project documentation. It goes in the repository on purpose** — it is
how a support thread becomes an answer, and an answer that lives only in one
person's head stops existing when they stop working here.

---

## 0. Before you start

You need a FiveM server, this resource, `cis_libs`, a framework and an
inventory actually started, and ideally one player connected with a loaded
character.

```cfg
ensure cis_libs
ensure qbx_core          # or es_extended, qb-core, cis_core
ensure ox_inventory      # or qs-inventory, codem-inventory, qb-inventory
ensure ox_doorlock       # optional: only for products that lock doors
ensure ox_target         # or qb-target; picked on each client
ensure cis_bridge
```

Start order does not matter: detection runs again whenever a resource it could
pick starts or stops. A resource that is not installed at all is reported
immediately, so do not read `MISSING` as "slow to start".

If two candidates are started, or you want a specific one, name it with
`setr cis_bridge:framework <esx|qbcore|qbox|cis_core>` and
`setr cis_bridge:inventory <name>` in `server.cfg`.

**Steps 1 to 3 write nothing.** Step 4 is the only one that changes a player, and
it only runs when you name the player.

The command is console-only: run it from the txAdmin console or the server
terminal. No ACE opens it in game, because `test write` moves a named
player's money and items.

---

## 1. The boot report

The first thing to look at, because it answers the question that opens almost
every support thread: *is this installed, and what is it doing?*

```
  state    kind            resource
  -------  --------------  ---------------------------------------------
  OK       framework       qbox              detected
  OK       inventory       ox_inventory      detected
  NONE     doors           -                 not on this server
```

Three rows, and three labels:

| State | What it means | What to do |
|---|---|---|
| `OK` | detected | nothing |
| `MISSING` | a required kind (framework, inventory) that nothing answered for | start it before `cis_bridge`, or name it with the convar the row prints |
| `NONE` | doors only: no `ox_doorlock` or `qb-doorlock` | nothing, unless a product you run locks doors |

Every non-`OK` row is followed by its fix under "what to do about the rows
above". Targets are not a row, because they are picked on each client; step 3
reports them.

Re-run it on demand at any time:

```
cis_bridge report
```

## 2. The conformance suite (read-only)

```
cis_bridge test
```

Read the **tally** at the bottom, not the rows:

```
cis_bridge: 14 passed, 0 failed, 3 skipped
```

(The numbers are illustrative; they depend on how many players are connected.)

What the rows are:

- `[detect]` — the framework and inventory were found; the door resource is a
  `SKIP` if you run none.
- `[refuse]` — a bad argument (source `0`, a bad door id) is refused with the
  right reason and nothing is written.
- `[player N]` — for each connected player: their job, cash and bank balances, an
  item count and a carry check, all reads.

What the labels mean:

- `FAIL` — a contract does not hold against your framework or inventory. The
  detail says which check and what it answered instead.
- `SKIP` — a check did not run: no door resource, no player connected, nothing
  to spend. The tally counts these separately, so you always know how much of the
  suite actually executed.

With no player online the per-player checks `SKIP` with "join and run it again".
Join with a loaded character for a real answer.

## 3. The client half

`cis_bridge test` ends by asking every connected client to run its own half and
prints their answers when they come back, under `client results from <name>`. A
target resource can be started on the server and broken on a client, and the two
are independent.

If nothing comes back, no client is running the resource: check that the client
scripts loaded. A developer can run the client half alone from the client console:

```
cis_bridge_client
```

It has a 10-second cooldown, because it spawns a ped and creates zones each run.
With neither `ox_target` nor `qb-target` started you get one `SKIP` with
`no_target`, not a failure.

## 4. The write round trip (opt-in)

This is the one step that touches a real player. **It moves 1 cash and 1 item and
puts them back.** Run it on a test character, never on a player who is mid-session
on a live economy, and never while something else is writing that player's money.

```
cis_bridge test write <server id> water
```

Use the player's server id (`status` or `players` in the console) and an item
that exists on your server; the item is optional and defaults to `water`. It runs
the read-only suite first, then on that one player:

1. `AddMoney` cash 1, checks the balance rose by 1, then `RemoveMoney` cash 1 and
   checks it is back where it started;
2. `AddItem` the item 1, checks the count rose by 1, then `RemoveItem` and checks
   it is back;
3. a `Purchase` of the item for 1 cash, checks that 1 cash left and 1 item
   arrived, then undoes both by hand.

```
  [write 3] AddMoney cash 1 moves the balance by 1      PASS
  [write 3] RemoveMoney cash 1 puts it back             PASS
  [write 3] AddItem water 1 moves the count by 1        PASS
  [write 3] RemoveItem water 1 puts it back             PASS
  [write 3] Purchase takes 1 cash and gives 1 item      PASS
  [write 3] the purchase is undone                      PASS

cis_bridge: 20 passed, 0 failed, 3 skipped
```

An unknown item, a full inventory, or a player with no cash makes that step a
`SKIP` that says why, not a failure. **A `FAIL` here may leave the player
changed**: the detail names which step failed and what is left to put back by
hand, so read it before anything else, and check the player's cash and item count.

## 5. Reading the results from another resource

```lua
local ok = exports['cis_bridge']:RunConformance()
local rows = exports['cis_bridge']:GetConformanceResults()
-- { { target, name, ok, skipped, detail }, ... }

for _, row in ipairs(rows) do
    if not row.ok and not row.skipped then
        print(('%s: %s -- %s'):format(row.target, row.name, row.detail))
    end
end
```

`RunConformance` is the read-only run; it never does step 4. A client's `PASS` is
not proof of anything the server did not check itself. It is an observation from
a machine you do not control, reported as such.

---

## 6. What is deliberately NOT covered here

| Not covered | Why |
|---|---|
| Whether a third-party resource works at all | Not our code. If `ox_target` is broken, the client half says so. |
| Performance under load | There is almost nothing running in this resource; `npm test` asserts that structurally. |
| Whether `cis_libs` itself is healthy | It ships `cis_doctor`. Start there. |
| Databases and Discord | Not part of cis_bridge. Products use `oxmysql` directly. |
| Anything escrow-protected | Nothing in this resource is escrowed; every file here is readable. |

## 7. If something is wrong and the report does not say why

1. `cis_bridge report` — what was detected, and the fix for what was not.
2. `cis_bridge test` — which contract disagrees with your framework or inventory.
3. `cis_libs:cis_doctor` — cis_libs's own health check, which matters only if you
   use the `lib` shim.
4. `npm run test:all` — if this is a fresh checkout rather than a live server,
   that is the fastest way to find out whether the problem is here at all.

Step 4 first when you have a clone, step 1 first when you have a server. That
ordering is not a preference: a report that names the cause is worth more than a
test that passes.
