# Security policy

## Reporting a vulnerability

Email **info@cisoko.net** with "security" in the subject, and:

- the `cis_bridge` version (`version` in `fxmanifest.lua`), your FXServer
  build, and the framework and inventory you run, with their versions;
- what an attacker can do, and the steps to reproduce it;
- whether the issue is already public.

Please do not open a public issue for a vulnerability.

## What happens next

- We acknowledge the report within 72 hours.
- We confirm or reject it, and agree a disclosure date with you, within 7 days.
- A fix ships as a GitHub release with a CHANGELOG entry that credits you,
  unless you ask us not to.

## Supported versions

Only the latest 1.x release gets security fixes. Upgrade to it before
reporting.

## Scope

In scope:

- a money, item or job write that moves more, less or something other than
  the caller asked, or reports success when it did not happen;
- a way for a client to reach a write, or to make the server act on a value
  the client chose;
- the two net events a player can reach: the client's conformance results
  (its bounds, truncation and rate limit) and the appearance reply (asked
  for, once, within 10 s, clothing keys only);
- the console-only `cis_bridge` command running from anywhere but the
  server console.

Out of scope: a product that passes client-chosen amounts or ids to the
exports, and bugs in the framework, inventory, door or target resource
itself.

## What cis_bridge exposes

- **No outbound request.** cis_bridge contacts no host.
- **Two net events a player can reach.**
  - `cis_bridge:server:conformanceResults`, sent when the console runs
    `cis_bridge test`. Its payload is bounded, every field is truncated
    before it is printed, and the handler is rate limited per player.
  - `cis_bridge:appearance:reply`, the client half of a server-side
    appearance save. The server takes it only from the player a save was
    started for, once, for the clothing resource that save named, within
    10 s; any other reply is dropped. The adapter keeps only clothing keys
    (skinchanger) or merges them into the stored skin (qb-clothing).
- **Fail closed.** Every export answers a value, or `false` and a reason. A
  framework or inventory that raises answers `false, 'error'`; a write is
  read back, and a partial write is taken back or reported through
  `cis_bridge:inconsistent`.
