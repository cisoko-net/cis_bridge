-- Contract compliance: does this resource build against cis_libs the way the
-- contract says it should?
--
-- The other suites ask whether the code does what it says. This one asks
-- whether the code and the contract agree, which is a different question and the
-- only one that catches a platform moving underneath a product that still passes
-- every other test.
--
-- Almost every assertion here is a grep. That is not laziness: the failure being
-- prevented is a resource that boots, registers nothing, and reports nothing
-- wrong, and the only way to see it before a customer does is to compare the
-- source against a list. Every rule is one somebody broke at least once while
-- this resource was being written, which is why each carries that story.
--
-- Read with fengari and no FiveM server. It reads files with `io`, so it is
-- checking the source on disk -- the thing that ships -- rather than whatever
-- happens to be loaded in a running VM.

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

-- ===================================================== reading the source
--
-- fengari has no filesystem. `io.open` answers nil and the first version of this
-- suite died on it with "attempt to call a nil value (field 'open')", which reads
-- as a Lua bug rather than as the VM having no disk. The harness therefore reads
-- every .lua file and hands them over as `__SOURCES`, already stripped of
-- comments; only the bytes come from there, because only the harness can get
-- them.
--
-- The knowledge -- which rule exists and why -- stays here, because that is the
-- expensive part and it does not belong in a test runner.
local SOURCES = _G.__SOURCES or {}
-- The same source with string contents neutralised: identifiers survive, every
-- other character inside a literal becomes `_`. Rules that ask "does the code
-- call this" run against this, so a rule cannot fire on the sentence a developer
-- wrote to explain the rule -- which is what happened to the realm rule below,
-- on the message that says `Cis.target` is a client surface.
local BARE = _G.__BARE or {}
check(type(SOURCES) == 'table' and next(SOURCES) ~= nil,
    'the harness handed over the source of this resource to audit')

local function readFile(rel)
    return SOURCES[rel]
end

local function linesOf(rel, from)
    local body = (from or SOURCES)[rel]
    if not body then return nil end
    local out = {}
    -- The harness already flattened every newline to a space, so this splits on
    -- a character that cannot occur inside a stripped source line.
    for line in (body .. '|'):gmatch('([^|]*)|') do
        out[#out + 1] = line
    end
    return out, body
end

-- Comments are already gone: the harness strips them, once, with one scanner.
-- Every rule below has a header explaining the incident it prevents, and a header
-- explaining an incident is full of the very names it is explaining -- so a rule
-- that matched comments would fire on its own documentation, and a rule that
-- fires on its own documentation is a rule that gets deleted.

-- The files the manifest actually loads, split by realm. Derived from the
-- manifest rather than hard-coded, because a hard-coded list goes stale the
-- moment an adapter is added -- and then the suite stops checking the new one,
-- which is the exact failure mode a compliance suite exists to prevent.
local manifest = readFile('fxmanifest.lua') or ''

local function scriptsIn(section)
    local out = {}
    -- `shared_scripts { ... }` and friends, or the singular `dependency` form.
    local body = manifest:match(section .. '%s*{(.-)}')
    if not body then return out end
    for entry in body:gmatch("['\"]([^'\"]+)['\"]") do
        -- `@other/file.lua` is a reference into a sibling resource. It resolves
        -- against the resources root, not against this directory, so it is
        -- recorded for the realm it belongs to and not checked for existence.
        out[#out + 1] = entry
    end
    return out
end

local SHARED = scriptsIn('shared_scripts')
local CLIENT = scriptsIn('client_scripts')
local SERVER = scriptsIn('server_scripts')

-- Files a `require` reaches rather than the manifest. None any more: the
-- cooldown and the `lib.*` shim are listed, the Discord embed builder is gone
-- with its adapter, and a shipped `require` fails the scan in § 1b.
local EXTRA_SERVER = {}

local function shippedByRealm()
    local server, client = {}, {}
    local function add(list, into)
        for _, entry in ipairs(list) do
            if entry:sub(1, 1) ~= '@' then
                into[entry] = true
            end
        end
    end
    add(SERVER, server)
    add(EXTRA_SERVER, server)
    add(CLIENT, client)
    return server, client
end

local SERVER_FILES, CLIENT_FILES = shippedByRealm()

-- Every shipped file this resource has, whether the manifest lists it or a
-- `require` reaches it. Written out rather than built by iterating a table of
-- tables: `{ a, b, { x = 1 } }` is a nested table constructor whose meaning
-- depends on how the parser reads the trailing brace, and "clever" here bought
-- nothing over three named calls.
local SHIPPED = {}
local function collect(into, out)
    for name in pairs(into) do
        out[#out + 1] = name
    end
end
collect(SERVER_FILES, SHIPPED)
collect(CLIENT_FILES, SHIPPED)
-- The shared adapters hold a server half and a client half, so they belong to
-- neither realm's scan and to every other one.
for _, entry in ipairs(SHARED) do
    if entry:sub(1, 1) ~= '@' then SHIPPED[#SHIPPED + 1] = entry end
end
table.sort(SHIPPED)

check(#SHIPPED >= 15, 'the manifest describes at least fifteen shipped files (found '
    .. tostring(#SHIPPED) .. ')')

-- ============================================ 1. the two manifest requirements
--
-- Both are in the contract, both are load-bearing, and both have the same
-- failure: a resource that starts, looks installed, and does nothing.


-- The server build floor is declared, not implied: cis_libs needs 4500, and a
-- resource that cannot run below it says so itself (no OneSync use here).
check(manifest:match("dependencies%s*{[^}]*'/server:4500'") ~= nil,
    'fxmanifest declares the /server:4500 build floor')

local declaresDependency = manifest:match("dependencies%s*{[^}]*'cis_libs'") ~= nil
    or manifest:match("dependency%s+'cis_libs'") ~= nil
check(declaresDependency,
    "fxmanifest declares cis_libs as a dependency -- without it FiveM may start this "
    .. "resource first, and every adapter's WaitReady then waits for something that "
    .. "is not coming yet")

-- ============================================ 1b. Nothing registers into cis_libs
--
-- cis_bridge is not in cis_libs' capability slots: products call the
-- bridge's own exports, and cis_libs keeps only its primitives. A slot
-- registration that came back would put two providers behind one product call,
-- each with its own answer to "did the money move", which is the bug the
-- boundary exists to end. The scan covers every shipped file and the manifest.
local SLOT_CALLS = { 'RegisterCapability', 'UnregisterCapability', 'WaitCapability', 'GetCapabilities' }
for _, rel in ipairs(SHIPPED) do
    for _, line in ipairs(linesOf(rel, BARE) or {}) do
        for _, name in ipairs(SLOT_CALLS) do
            check(line:find('%f[%w_]' .. name .. '%f[^%w_]') == nil,
                ('%s calls cis_libs:%s; cis_bridge registers into no cis_libs slot')
                    :format(rel, name))
        end
        check(line:find('Bridge%.register') == nil and line:find('Bridge%.publish') == nil,
            ('%s reaches for the deleted Bridge slot registry'):format(rel))
    end
end
check(manifest:find('shared/bridge%.lua') == nil,
    'the manifest no longer loads shared/bridge.lua, the slot registry')
check(manifest:find('cis_requires') == nil, 'the manifest names no cis_libs slot it requires')
-- init.lua is how a consumer reaches the slots (`Cis.target`, `Cis.inventory`).
-- The v1 API reads none of them, so loading it again would only invite a
-- product-facing call back through cis_libs.
check(manifest:find('@cis_libs/init%.lua') == nil,
    'the manifest no longer loads @cis_libs/init.lua, the cis_libs slot facade')
check(true, 'the slot-registration scan completed over every shipped file')

-- FiveM gives a resource no `require` for its own files: the loader came from
-- `@cis_libs/init.lua`, which cis_bridge does not load. The suites run under
-- fengari, whose `require` does read files, so a shipped `require` passed here
-- and raised `module 'shared.lib.shim' not found` on the first live boot.
-- A shipped file reaches another through the manifest and a global.
for _, rel in ipairs(SHIPPED) do
    for _, line in ipairs(linesOf(rel, BARE) or {}) do
        check(line:find('%f[%w_]require%f[^%w_]') == nil,
            ('%s calls require; FiveM has no loader for resource files without @cis_libs/init.lua')
                :format(rel))
    end
end
check(SERVER_FILES['shared/lib/shim.lua'] == true,
    'the manifest loads shared/lib/shim.lua, which server/lib.lua reads')
-- cis_libs zones are client exports; the server shim must not forward to them.
check((readFile('server/lib.lua') or ''):find('Shim.build(engine())', 1, true) ~= nil,
    'server/lib.lua builds the shim over the engine, which has no zone calls')
check((readFile('server/lib.lua') or ''):find('CreateZone', 1, true) == nil,
    'server/lib.lua does not forward to the cis_libs zone exports, which are client-only')
-- GetDbProxy answers false and a reason: no shipped resource serves cis_libs' Db*.
do
    local made = {}
    local env = setmetatable({
        exports = function(name, fn) made[name] = fn end,
        CisBridgeLibShim = { build = function() return {} end },
    }, { __index = _G })
    local chunk = assert(load(readFile('server/lib.lua'), '@server/lib.lua', 't', env))
    chunk()
    local okP, whyP = made.GetDbProxy()
    check(okP == false and type(whyP) == 'string' and whyP:find('oxmysql', 1, true) ~= nil,
        'GetDbProxy answers false and a reason naming oxmysql: ' .. tostring(whyP))
end

check(manifest:find("lua54%s+'yes'") ~= nil,
    "fxmanifest sets lua54 'yes'")

check(manifest:find('game%s+') ~= nil, 'fxmanifest names a game')

-- adapters/custom.lua holds an owner's own adapters (DOCUMENTATION.md §10). It
-- is a shared script listed after every shared built-in adapter (framework and
-- appearance), so a copy of one can read `__common`, and the shared block
-- comes before the client and server blocks, so v1.lua sees what it registers.
local customAt, lastAdapter = nil, 0
for i, f in ipairs(SHARED) do
    if f == 'adapters/custom.lua' then customAt = i
    elseif f:find('^adapters/') then lastAdapter = i end
end
check(customAt ~= nil and customAt > lastAdapter,
    'the manifest loads adapters/custom.lua as a shared script after the shared built-in adapters')
local sharedPos = manifest:find('shared_scripts%s*{') or math.huge
check(sharedPos < (manifest:find('client_scripts%s*{') or 0) and sharedPos < (manifest:find('server_scripts%s*{') or 0),
    'the shared block, with adapters/custom.lua, loads before client/v1.lua and server/v1.lua')

-- =========================================== 2. No deprecated cis_libs API
--
-- The contract lists these explicitly: logged once per calling resource per
-- boot, removed in 3.0.0. Calling one today works and is how a resource breaks
-- on a cis_libs upgrade -- the worst time to find out, because it is a platform
-- release affecting every product at once.
--
-- The door names are the exports cis_libs really declares (its fxmanifest and
-- the door module: GetDoorState on both sides; GetClosestDoor,
-- RequestLockDoors and RequestUnlockDoors on the client; the rest on the
-- server). An
-- earlier list named SetDoorState, AddDoor, RemoveDoor, DoorExists,
-- SetDoorHeading and GetAllDoors, which cis_libs never declared, so the scan
-- guarded six names nobody could call and missed nine that work today.
-- GetFramework was a compat shim of the cis_libs dev builds; it stays listed
-- so that nobody brings it back.
local DOORS_WHY = 'use the cis_bridge GetDoorLock / SetDoorLock exports'
local DEPRECATED = {
    { name = 'GetFramework', why = 'use Cis.registry.resolve or Cis.framework.*' },
    { name = 'GetDoorState', why = DOORS_WHY },
    { name = 'GetClosestDoor', why = DOORS_WHY },
    { name = 'LockDoors', why = DOORS_WHY },
    { name = 'UnlockDoors', why = DOORS_WHY },
    { name = 'RequestLockDoors', why = DOORS_WHY },
    { name = 'RequestUnlockDoors', why = DOORS_WHY },
    { name = 'AddDoorToSystem', why = DOORS_WHY },
    { name = 'AddDoorGroup', why = DOORS_WHY },
    { name = 'GetAllDoorData', why = DOORS_WHY },
    { name = 'BreakDoor', why = DOORS_WHY },
    { name = 'FixDoor', why = DOORS_WHY },
}

-- The deprecated names one line mentions. The scan reads bare: comments are
-- gone, and inside a string every non-word character became `_` while the
-- identifier characters stayed. So a name inside a string counts, and that is
-- deliberate: `exports.cis_libs['GetDoorState']()` is a call, and its name is
-- only ever a string. `%f[%w]` and `%f[^%w]` make it a whole name, so
-- `RequestLockDoors` does not also report `LockDoors`, and a `_` (what a space
-- in a string became) is a boundary. A name in a comment does not count.
local function deprecatedIn(line)
    local hits = {}
    for _, dep in ipairs(DEPRECATED) do
        if line:find('%f[%w]' .. dep.name .. '%f[^%w]') then hits[#hits + 1] = dep end
    end
    return hits
end

-- The scan is checked against lines shaped the way the harness hands them
-- over, so a pattern that stops matching fails here and not silently.
for _, case in ipairs({
    { 'exports.cis_libs:LockDoors(1)', 'LockDoors', 'a colon call' },
    { "exports.cis_libs['GetDoorState'](1)", 'GetDoorState', 'a name inside a string' },
    { "local s = '_use_FixDoor_now_'", 'FixDoor', 'a name in neutralised prose' },
    { 'exports.cis_libs:RequestLockDoors(1)', 'RequestLockDoors', 'a longer name, reported once' },
}) do
    local hits = deprecatedIn(case[1])
    check(#hits == 1 and hits[1].name == case[2],
        ('the deprecated scan finds %s (%s)'):format(case[2], case[3]))
end
for _, line in ipairs({ 'exports.cis_bridge:GetDoorLock(1)', 'local LockDoorsX = 1', '  ' }) do
    check(#deprecatedIn(line) == 0, ('the deprecated scan ignores `%s`'):format(line))
end

for _, rel in ipairs(SHIPPED) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        for _, dep in ipairs(deprecatedIn(line)) do
            check(false, ('%s calls the deprecated cis_libs API %s (%s)')
                :format(rel, dep.name, dep.why))
        end
    end
end
check(true, 'the deprecated-API scan completed over every shipped file')

-- ======================================== 3. Every cis_libs export exists
--
-- The list is cis_libs' own, read out of its source. A call to an export that
-- does not exist does not return nil -- it raises "No such export", at the first
-- real call, on a live server, in whatever code path happened to reach it.
local CIS_LIBS_EXPORTS = {
    'AwaitCallback', 'AwaitCallbackClient', 'CheckResourceVersion', 'CreatePed',
    'CreateSafeCallback', 'CreateTarget', 'CreateZone', 'DbInsert', 'DbQuery',
    'DbScalar', 'DbSingle', 'DbTransaction', 'DbUpdate', 'DetectDatabase',
    'DetectFramework', 'GetCapabilities', 'GetClientConfig', 'GetConfigSummary',
    'GetDiagnostics', 'GetDiscordConfig', 'GetDiscordQueueDepth',
    'GetKnownTargets', 'GetLastRefusal', 'GetNormalizedPlayer', 'GetSelfCheck',
    'InventoryCount', 'InventoryHas', 'InventoryAdd', 'InventoryRemove',
    'IsReady', 'LogError', 'LogWarn', 'LogInfo', 'LogDebug', 'Notify',
    'NotifyClient', 'RateOk', 'RegisterCallback', 'RegisterCapability',
    'RemoveTarget', 'TargetExists', 'UnregisterCapability', 'UpdateTarget',
    'WaitCapability', 'WaitReady', 'ZoneContains',
    -- The legacy database aliases, still present and still callable.
    'DatabaseExecute', 'DatabaseFetchAll', 'DatabaseFetchOne', 'DatabaseInsert',
    'DatabaseUpdate', 'DatabaseDelete',
    -- Deprecated but still exported; a call is caught above, so listing them
    -- here only changes which message fires.
    'GetFramework',
}

local exportSet = {}
for _, name in ipairs(CIS_LIBS_EXPORTS) do exportSet[name] = true end

for _, rel in ipairs(SHIPPED) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        -- The bracket and quote characters are neutralised in bare, so the match
        -- accepts either the source form or the stripped form. Relaxed to
        -- `[%W_]` on purpose rather than pinned to the exact shape, because the
        -- alternative is a rule that needs updating every time the bracket
        -- style changes -- which is the kind of rule that gets deleted.
        for name in line:gmatch("exports%[[%W_]?cis_libs[%W_]?%]%s*:%s*([%a_][%w_]*)") do
            check(exportSet[name] == true,
                ('%s calls cis_libs:%s, which is not an export cis_libs defines')
                    :format(rel, name))
        end
    end
end
check(true, 'the cis_libs-export scan completed over every shipped file')

-- ================================================== 4. Realm boundaries
--
-- `Cis.target` is a client surface and `Cis.db` is a server surface, and the two
-- halves are different files for a reason: `init.lua` defines `Cis.target`
-- inside its not-server branch, so on the server `Cis.target` is nil and the
-- call raises "attempt to call field 'add' (a nil value)". That is not a
-- theoretical failure; it is what both target conformance tests reported on a
-- perfectly healthy install before the suite was split.

for rel in pairs(CLIENT_FILES) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        check(line:find('Cis%.db%.') == nil,
            ('%s is a client file and calls Cis.db, which is a server surface'):format(rel))
    end
end
for rel in pairs(SERVER_FILES) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        check(line:find('Cis%.target%.') == nil,
            ('%s is a server file and calls Cis.target, which is a client surface'):format(rel))
        check(line:find('Cis%.zones%.') == nil,
            ('%s is a server file and calls Cis.zones, which is a client surface'):format(rel))
        check(line:find('Cis%.player%.') == nil,
            ('%s is a server file and calls Cis.player, which is a client surface'):format(rel))
        check(line:find('Cis%.streaming%.') == nil,
            ('%s is a server file and calls Cis.streaming, which is a client surface'):format(rel))
        check(line:find('Cis%.world%.') == nil,
            ('%s is a server file and calls Cis.world, which is a client surface'):format(rel))
        check(line:find('Cis%.keybind%.') == nil,
            ('%s is a server file and calls Cis.keybind, which is a client surface'):format(rel))
    end
end
check(true, 'the realm scan completed over every shipped file')

-- ================================ 5. Cis.* namespaces that cis_libs knows
--
-- A namespace that does not exist is `nil`, and `nil.method()` raises at the
-- call rather than at load -- so a typo in a namespace name is invisible to
-- every other check in this repository.
local KNOWN_NAMESPACES = {
    callback = true, db = true, doors = true, framework = true, hooks = true,
    inventory = true, log = true, net = true, player = true, points = true,
    raycast = true, registry = true, require = true, security = true,
    statebag = true, streaming = true, sync = true, target = true,
    ui = true, vehicle = true, wait = true, waitFor = true, world = true,
    zones = true, command = true, keybind = true,
}

for _, rel in ipairs(SHIPPED) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        for ns in line:gmatch('Cis%.([%a_][%w_]*)%.') do
            check(KNOWN_NAMESPACES[ns] == true,
                ('%s calls Cis.%s, which cis_libs does not define. Known namespaces: %s')
                    :format(rel, ns,
                        (function()
                            local t = {}
                            for k in pairs(KNOWN_NAMESPACES) do t[#t + 1] = k end
                            table.sort(t)
                            return table.concat(t, ', ')
                        end)()))
        end
    end
end
check(true, 'the namespace scan completed over every shipped file')

-- ============================ 5b. The manifest's order is a correctness property
--
-- Modules publish a global for the file that reads them, and the manifest
-- is the only thing that guarantees the producer loads first:
--
--   server/ratelimit.lua        ->  CisBridgeRateLimit  ->  server/conformance.lua
--
-- That was `require`d by dotted path until this release, and no sibling resource
-- in this platform does that -- every one of them loads shared code through
-- explicit manifest entries. If `require` did not resolve, the resource would not
-- Start, so the mechanism was changed and the ordering became load-bearing.
--
-- Which means the order is a rule, and nothing was checking it: swapping the two
-- lines in fxmanifest.lua passes every suite in this repository, and produces a
-- server whose Discord adapter holds a nil builder until a log line is sent.
-- That is precisely the failure mode the previous mechanism had, reached by a
-- different route. (The Discord adapter is gone; the rule is not.)
--
-- Derived from the manifest rather than hard-coded, so moving a file is caught
-- as a moved file and not as a hard-coded list disagreeing with reality.
--
-- The adapters publish into one table per kind that server/v1.lua
-- reads when it loads; the first listed adapter of each kind is the producer,
-- and every later one of that kind and v1.lua are consumers.
local PUBLISHERS = {
    CisBridgeRateLimit = 'server/ratelimit.lua',
    CisBridgeInventories = 'adapters/inventory/cis_inventory.lua',
    CisBridgeDoors = 'adapters/doors/ox_doorlock.lua',
    CisBridgeV1 = 'server/v1.lua',
}

local function positionIn(section, file)
    local body = manifest:match(section .. '%s*{(.-)}')
    if not body then return nil end
    local index = 0
    for entry in body:gmatch("['\"]([^'\"]+)['\"]") do
        index = index + 1
        if entry == file then return index end
    end
    return nil
end

for global, producer in pairs(PUBLISHERS) do
    -- Every shipped file that reads it. The producer names the global on the
    -- line that assigns it, so it is excluded -- a file cannot consume a global
    -- before creating it, and including it makes the rule demand that a file
    -- precede itself.
    local consumers = {}
    for rel in pairs(SERVER_FILES) do
        if rel ~= producer then
            local lines = linesOf(rel, BARE)
            for _, line in ipairs(lines or {}) do
                if line:find('%f[%w_]' .. global .. '%f[^%w_]') then
                    consumers[#consumers + 1] = rel
                    break
                end
            end
        end
    end
    check(#consumers > 0,
        ('%s is actually consumed, so its load order matters'):format(global))

    local producerAt = positionIn('server_scripts', producer)
    check(producerAt ~= nil,
        ('%s is listed in server_scripts, because the manifest is what orders it')
            :format(producer))

    for _, consumer in ipairs(consumers) do
        local consumerAt = positionIn('server_scripts', consumer)
        check(consumerAt ~= nil,
            ('%s reads %s and is therefore listed in server_scripts too')
                :format(consumer, global))
        check(producerAt ~= nil and consumerAt ~= nil and producerAt < consumerAt,
            ('fxmanifest loads %s (position %s) before %s (position %s): a consumer '
                .. 'that loads first reads a global nobody has written yet')
                :format(producer, tostring(producerAt), consumer, tostring(consumerAt)))
    end
end

-- ============================== 6. No cis_libs internal files are included
--
-- The contract is explicit: no `@cis_libs/server/registry.lua` or any other
-- internal include. Reaching into a sibling's internals means its globals and
-- locals arrive in this resource's Lua state unannounced, and the day that file
-- moves, this one breaks in a way that reads as a cis_libs bug.
for _, entry in ipairs(SHARED) do
    if entry:sub(1, 1) == '@' then
        check(entry == '@cis_libs/init.lua',
            ('shared_scripts includes %s, which is a cis_libs INTERNAL file. Only '
                .. '@cis_libs/init.lua is published for consumers'):format(entry))
    end
end
check(true, 'the internal-include scan completed')

-- ================================ 7. No server IDs supplied by a client
--
-- `source` is the only identity on the server side that a caller cannot choose.
-- This resource has one net event handler, and it takes no arguments at all --
-- the whole point of the design is that the server asks and the client answers
-- with observations. A future edit that adds a parameter has to add the check
-- here at the same time.
local confLines = linesOf('server/conformance.lua') or {}
local netEventLines = {}
for _, line in ipairs(confLines) do
    if line:find('RegisterNetEvent') then
        netEventLines[#netEventLines + 1] = line
    end
end
check(#netEventLines >= 1, 'the server registers at least one net event handler')
for _, line in ipairs(netEventLines) do
    -- `function(payload)` -- one parameter, which is the client's answer and is
    -- treated as untrusted data rather than as an identity.
    check(line:find('function%(payload%)') ~= nil,
        'the net event handler takes only the client payload and no player id')
end
check(true, 'the source-derivation scan completed')

-- The CisBridge facade (init.lua) names every export of its realm, and only
-- those: a missing name leaves a product calling a nil field, an extra one
-- forwards to an export that does not exist.
do
    local init = readFile('init.lua') or ''
    local function list(block)
        local body = init:match('local ' .. block .. ' = (%b{})') or ''
        local names = {}
        for name in body:gmatch("'([%w_]+)'") do names[#names + 1] = name end
        table.sort(names)
        return names
    end
    local function exported(rel)
        local names = {}
        local seen = {}
        for name in (readFile(rel) or ''):gmatch("exports%('([%w_]+)'") do
            if not seen[name] then seen[name] = true; names[#names + 1] = name end
        end
        table.sort(names)
        return names
    end
    for _, realm in ipairs({ { 'SERVER', 'server/v1.lua' }, { 'CLIENT', 'client/v1.lua' } }) do
        local facade, exports = list(realm[1]), exported(realm[2])
        check(#exports >= 1, realm[2] .. ' registers its exports')
        check(table.concat(facade, ',') == table.concat(exports, ','),
            ('init.lua %s lists every %s export and no other: facade %s, exports %s')
                :format(realm[1], realm[2], table.concat(facade, ','), table.concat(exports, ',')))
    end
end

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(contract): ' .. failures[i] .. '\n')
end
io.write(('contract passed=%d failed=%d\n'):format(passed, failed))
