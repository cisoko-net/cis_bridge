-- Broken on purpose: a deprecated entry with `until = false`.
--
-- `deprecated` is a promise to remove something. With no `until`, the promise
-- has no end: a consumer reading this has to decide for itself when the entry
-- disappears, which is exactly the decision the field exists to make for them.
--
-- This rule (E011) was unreachable until the manifest loader stopped reading
-- every boolean as `false`. It had never fired, which means it had never been
-- tested, and a rule that has never fired is indistinguishable from a rule that
-- does not work. The fixture exists so that stops being true.
--
-- An earlier release deleted the last deprecated export, so the fixture marks a live one
-- (GetMoney) deprecated and leaves its `until` false.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.GetMoney.deprecated = true
real.exports.GetMoney.stable = false
-- `until` is a LUA keyword, so it cannot be reached with a dot. The real
-- api.lua writes `['until']` for the same reason, and this fixture did not,
-- so it failed to load rather than failing the rule it exists to prove --
-- which is a different failure with the same initials, and one a less
-- careful self-test would report as "the rule is broken".
real.exports.GetMoney['until'] = false
return real
