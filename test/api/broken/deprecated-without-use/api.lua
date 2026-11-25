-- Broken on purpose: a deprecated entry that does not say what replaced it.
--
-- `use` is the whole point of declaring something deprecated. An entry marked
-- deprecated with no `use` tells a consumer it is going away and not what to
-- move to, which is the version of this that turns into a support ticket.
--
-- E013, like E011, was unreachable while the loader read every boolean as
-- false. Both are proved here now. An earlier release deleted the last deprecated export,
-- so GetMoney is marked deprecated, with a removal version, and no `use`.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.GetMoney.deprecated = true
real.exports.GetMoney.stable = false
real.exports.GetMoney['until'] = '3.0.0'
real.exports.GetMoney.use = nil
return real
