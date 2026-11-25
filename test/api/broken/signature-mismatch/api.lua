-- Broken on purpose: RunConformance is declared as (target) but registers ().
--
-- E032 -- the declaration and the code disagree about the parameter list. The
-- classic form of this bug is an argument arriving one slot left of where the
-- reader expected, which raises nothing and returns a wrong answer.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.RunConformance.signature = '(target)'
return real
