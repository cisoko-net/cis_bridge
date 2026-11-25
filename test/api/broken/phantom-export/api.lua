-- Broken on purpose: GetMoney is declared for the client realm, where nothing
-- registers it. It is a server export: money is the server's to read.
--
-- E030 -- a declaration for a realm that does not exist. A consumer writing
-- against the client signature ships, and finds a nil index at runtime with
-- nothing in the contract to explain it.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.GetMoney.realm = 'client'
return real
