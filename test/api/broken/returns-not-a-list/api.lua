-- Broken on purpose: `returns` is a string rather than a list of names.
--
-- `returns` exists so the shape can be checked rather than read. `npm run docs`
-- renders it, and neither the generator nor a reader can do anything with a
-- string, so a string here means the check silently stops covering that
-- export while still reporting clean.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.GetMoney.returns = 'balance, reason'
return real
