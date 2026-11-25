-- Tests for the boot report.
--
-- The report is the most support-cost-sensitive thing in this resource: it is
-- the artifact an operator pastes into a ticket instead of writing a paragraph
-- describing their server. So what is tested is not the printing -- which is
-- formatting -- but the decision it encodes: for every detection outcome, does
-- the report produce a row that names the cause and a next step?
--
-- A row with an empty `fix` is a support ticket that has not been closed yet,
-- and that is the one failure mode this suite exists to catch.

local passed, failed = 0, 0
local failures = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
end

local printed = {}
local realPrint = print
_G.print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
end

local function render()
    local mark = #printed
    local ok, ret = pcall(CisBridgeReport.render)
    local out = {}
    for i = mark + 1, #printed do out[#out + 1] = printed[i] end
    return ok, table.concat(out, '\n'), ret
end

_G.GetCurrentResourceName = function() return 'cis_bridge' end
_G.GetResourceMetadata = function() return '1.0.0' end
local threads = 0
_G.CreateThread = function() threads = threads + 1 end
local declared = {}
_G.exports = setmetatable({}, {
    __call = function(_, name, fn) declared[name] = fn end,
})

local summary = {}
_G.CisBridgeV1 = {
    summary = function() return summary end,
}

dofile('server/report.lua')
local GetBridgeReport = declared.GetBridgeReport

check(type(CisBridgeReport) == 'table' and type(CisBridgeReport.render) == 'function', 'server/report.lua publishes CisBridgeReport.render')
check(type(GetBridgeReport) == 'function', 'the report exports its rows for another resource')
check(threads == 1, 'and prints once at boot, from one thread')

local function rowFor(rows, kind)
    for _, row in ipairs(rows or {}) do
        if row.kind == kind then return row end
    end
end

local function noBareRow(rows, label)
    local bare = {}
    for _, row in ipairs(rows) do
        if row.label ~= 'OK      ' and (type(row.fix) ~= 'string' or row.fix == '') then
            bare[#bare + 1] = row.kind .. ' (' .. tostring(row.label) .. ')'
        end
    end
    check(#bare == 0, label .. ': no unhealthy row lacks a next step; bare rows: ' .. table.concat(bare, ', '))
end

-- ============================================================ 1. all present
summary = { api = 1, framework = 'qbox', inventory = 'ox_inventory', doors = 'ox_doorlock' }
local rows = GetBridgeReport()
check(type(rows) == 'table' and #rows == 3, 'one row per kind: framework, inventory, doors')
check(rows[1].kind == 'framework' and rows[2].kind == 'inventory' and rows[3].kind == 'doors',
    'in a fixed order, so two pasted reports line up')
for _, row in ipairs(rows) do
    check(row.label == 'OK      ', row.kind .. ' is OK when detected')
    check(row.fix == nil, row.kind .. ' carries no fix when there is nothing to fix')
end
check(rowFor(rows, 'framework').target == 'qbox', 'the framework row names what was found')
local ok, text, ret = render()
check(ok and ret == true, 'render does not raise and answers true')
check(text:find('cis_bridge 1.0.0 -- v1 API 1', 1, true) ~= nil, 'the headline names the version and the API')
check(text:find('Products that use cis_bridge can run on this server.', 1, true) ~= nil,
    'a healthy server is told so in one sentence')
check(text:find('what to do about', 1, true) == nil, 'and gets no fix section')
check(text:find('cis_bridge test', 1, true) ~= nil, 'the report points at the conformance suite next')

-- ============================================================ 2. no doors
summary = { api = 1, framework = 'esx', inventory = 'ox_inventory' }
rows = GetBridgeReport()
local doors = rowFor(rows, 'doors')
check(doors.label == 'NONE    ', 'no door resource is NONE, not MISSING: plenty of servers have none')
check(type(doors.fix) == 'string' and doors.fix:find('ox_doorlock', 1, true) ~= nil,
    'and still says what would fill it')
ok, text = render()
check(ok and text:find('can run on this server', 1, true) ~= nil,
    'and the server is still healthy, because doors are optional')
noBareRow(rows, 'no doors')

-- ============================================================ 3. nothing found
summary = { api = 1 }
rows = GetBridgeReport()
check(rowFor(rows, 'framework').label == 'MISSING ', 'no framework is MISSING')
check(rowFor(rows, 'inventory').label == 'MISSING ', 'no inventory is MISSING')
check(rowFor(rows, 'framework').fix:find('setr cis_bridge:framework', 1, true) ~= nil,
    'the framework fix names the convar that forces one')
check(rowFor(rows, 'inventory').fix:find('setr cis_bridge:inventory', 1, true) ~= nil,
    'and the inventory fix names its convar')
check(rowFor(rows, 'framework').fix:find('before cis_bridge', 1, true) ~= nil,
    'and both say the start order, which is the usual cause')
ok, text = render()
check(ok and text:find('2 required resource(s) missing', 1, true) ~= nil,
    'the headline counts what is missing')
check(text:find('what to do about the rows above:', 1, true) ~= nil, 'and the fixes are printed under it')
noBareRow(rows, 'nothing found')

-- ============================================================ 3b. wrong convar
-- A forced name that is not an adapter: the row says the convar is the cause,
-- and the fix is the plain line detection printed, not the start-order advice.
summary = { api = 1, inventory = 'ox_inventory', config = {
    framework = "cis_bridge:framework is 'qbcor', which is not an adapter. Use one of: cis_core, esx, qbcore, qbox",
} }
rows = GetBridgeReport()
check(rowFor(rows, 'framework').label == 'MISSING ', 'a wrong framework convar is MISSING')
check(rowFor(rows, 'framework').detail == 'convar names no usable adapter', 'and the row says the convar is the cause')
check(rowFor(rows, 'framework').fix == summary.config.framework, 'and the fix is the line detection printed')
check(rowFor(rows, 'inventory').fix == nil, 'and a slot with no config line keeps its OK row')
noBareRow(rows, 'wrong convar')

-- A forced or renamed slot says how it was picked; an auto one says detected.
summary = { api = 1, framework = 'qbcore', inventory = 'ox_inventory', why = {
    framework = 'forced, resource renamed to my-core', inventory = 'auto',
} }
rows = GetBridgeReport()
check(rowFor(rows, 'framework').detail == 'forced, resource renamed to my-core', 'a renamed slot says so')
check(rowFor(rows, 'inventory').detail == 'detected', 'an auto slot says detected')

-- ============================================================ 4. no API
_G.CisBridgeV1 = nil
rows = GetBridgeReport()
check(type(rows) == 'table' and #rows == 3, 'with no v1 API the report still has every row')
check(rowFor(rows, 'framework').label == 'MISSING ', 'and they say MISSING rather than raising')
ok, text = render()
check(ok and text:find('The v1 API did not load', 1, true) ~= nil,
    'and the headline sends the operator to the boot log')

-- ============================================================ 5. summary raises
_G.CisBridgeV1 = { summary = function() error('summary exploded') end }
local okRows, raised = pcall(GetBridgeReport)
check(okRows and type(raised) == 'table', 'a summary that raises does not take the export down')
ok, text = render()
check(ok and text:find('did not load', 1, true) ~= nil, 'or the render')

-- ============================================================ 6. no secrets
_G.CisBridgeV1 = { summary = function() return { api = 1, framework = 'qbox', inventory = 'ox_inventory' } end }
ok, text = render()
check(not text:find('https?://'), 'the report prints no URL')
check(not text:find('license:', 1, true) and not text:find('steam:', 1, true), 'and no player identifier')

-- ------------------------------------------------------------------ report
_G.print = realPrint
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(report): ' .. failures[i] .. '\n')
end
io.write(('report passed=%d failed=%d\n'):format(passed, failed))
