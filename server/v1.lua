-- The v1 product API, server half (docs/V1.md).
--
-- A product calls `exports.cis_bridge:<Contract>(...)` or the `CisBridge`
-- facade from `@cis_bridge/init.lua`. This file is the only place that decides
-- anything: it validates input, picks the adapters, takes the per-player lock,
-- checks balances and counts, and turns every adapter answer into `true` /
-- a value, or `false, reason`. The adapters in adapters/ only translate.
--
-- Three rules this file keeps
--   1. No contract raises. Every adapter call runs under pcall, and a raise is
--      `false, 'error'` with one console line naming the adapter.
--   2. A write is proved by a read. Money is checked against the balance before
--      it is removed; an item write is checked by the count before and after,
--      because no inventory's return value can be trusted on its own (ox adds
--      non-stackables partially and still answers true).
--   3. One write per player at a time. Exported writes take `busy[src]` and fail
--      fast with `busy`; Purchase calls the unlocked internals under one lock,
--      so it never meets its own lock.

local V1 = {}

local MAX_AMOUNT = 1000000000
local MAX_COUNT = 1000000
local MAX_LINES = 20
local MAX_MESSAGE = 512
local MAX_REASON = 128
local MAX_BLOB_DEPTH = 8
local MAX_BLOB_KEYS = 256
local ACCOUNTS = { cash = true, bank = true, dirty = true, crypto = true }
local KINDS = { info = true, success = true, warning = true, error = true }

-- ===========================================================================
--  Detection
-- ===========================================================================

local fw, inv, doors, appearance
local detected = false

local function started(resource)
    return GetResourceState(resource) == 'started'
end

local function probe(adapter)
    local ok, yes = pcall(adapter.probe)
    return ok and yes == true
end

-- Qbox first: it declares `provide 'qb-core'`, so a started qb-core may be
-- Qbox. cis_core last: it wraps the other three, so on a server that runs one
-- of them the bridge talks to the framework directly (docs/V1.md, Detection).
local FRAMEWORK_ORDER = { 'qbox', 'esx', 'qbcore', 'cis_core' }
-- cis_inventory first: it ships faces under the ox_inventory and qb-inventory
-- names, so on its server those look started too and would be picked instead.
local INVENTORY_ORDER = { 'cis_inventory', 'ox_inventory', 'qs-inventory', 'codem-inventory', 'qb-inventory' }
local DOORS_ORDER = { 'ox_doorlock', 'qb-doorlock' }
-- illenium-appearance first: it carries ESX and QB compatibility handlers
-- (skinchanger events among them), so beside it the others may answer too.
local APPEARANCE_ORDER = { 'illenium-appearance', 'fivem-appearance', 'qb-clothing', 'skinchanger' }

-- A forced convar that names no adapter, or an adapter whose resource is not
-- started, picks nothing for its slot (fail closed, never the detected one) and
-- says why in one plain line (kept for the boot report), printed once per cause.
local configLines = {}
local said = {}

local function adapterNames(registry)
    local out = {}
    for name, a in pairs(registry or {}) do
        if type(a) == 'table' and name:sub(1, 2) ~= '__' then out[#out + 1] = name end
    end
    table.sort(out)
    return table.concat(out, ', ')
end

-- How each slot was picked, for the boot report: 'auto', 'forced by convar',
-- or 'forced, resource renamed to <name>'.
local whyLines = {}

-- `cis_bridge:<slot>_resource` names the resource a renamed framework or
-- inventory runs under (qb-core started as my-core). It applies to the adapter
-- the slot's convar forces; every other adapter keeps its own resource name.
-- Set without the forcing convar it picks nothing and says so: the bridge
-- does not guess which adapter the renamed resource is.
local function applyResource(registry, convar, forced)
    local renamed = GetConvar(convar .. '_resource', '')
    for _, a in pairs(registry or {}) do
        if type(a) == 'table' and a.resource ~= nil then
            a.defaultResource = a.defaultResource or a.resource
            a.resource = a.defaultResource
        end
    end
    if renamed == '' then return nil end
    if not forced then
        -- The hint lists every adapter of this slot and picks none: the
        -- renamed resource could run any of them (qb-core as my-core).
        return ("%s_resource is '%s', but %s is not set. Set both: setr %s <adapter>, where <adapter> is one of: %s")
            :format(convar, renamed, convar, convar, adapterNames(registry))
    end
    local a = registry and registry[forced]
    if type(a) == 'table' and forced:sub(1, 2) ~= '__' then a.resource = renamed end
    return nil
end

--- The adapter name a convar forces (nil when it is unset), and true when the
--- slot's convars are wrong, so it picks nothing.
local function forcedName(registry, convar)
    local forced = GetConvar(convar, '')
    if forced == '' then forced = nil end
    local renamed = GetConvar(convar .. '_resource', '')
    local slot = convar:sub(#'cis_bridge:' + 1)
    local line = applyResource(registry, convar, forced)
    local a = forced and registry and registry[forced]
    if forced then
        if type(a) ~= 'table' or forced:sub(1, 2) == '__' then
            line = ("%s is '%s', which is not an adapter. Use one of: %s")
                :format(convar, forced, adapterNames(registry))
        elseif not started(a.resource) then
            line = ("%s is '%s', but %s is not started"):format(convar, forced, a.resource)
        end
    end
    whyLines[slot] = not forced and 'auto'
        or renamed ~= '' and ('forced, resource renamed to ' .. renamed)
        or 'forced by convar'
    if line then
        configLines[slot] = line
        if said[convar] ~= line then print('^1' .. line .. '^7') end
    end
    said[convar] = line
    return forced, line ~= nil
end

-- A forced adapter that is started but fails its probe (an export renamed or
-- missing) picks nothing too, with its own line, printed once per cause.
local function probeFailed(convar, forced, a)
    local key = convar .. ':probe'
    local line = forced and a and started(a.resource) and not probe(a)
        and ("%s is '%s' and %s is started, but it does not answer the %s probe")
            :format(convar, forced, a.resource, forced)
        or nil
    if line then
        configLines[convar:sub(#'cis_bridge:' + 1)] = line
        if said[key] ~= line then print('^1' .. line .. '^7') end
    end
    said[key] = line
end

local function pickFramework()
    local forced, wrong = forcedName(CisBridgeFrameworks, 'cis_bridge:framework')
    if wrong then return nil end
    local order = forced and { forced } or FRAMEWORK_ORDER
    for _, name in ipairs(order) do
        local a = CisBridgeFrameworks and CisBridgeFrameworks[name]
        if a and started(a.resource)
            and not (name == 'qbcore' and not forced and started('qbx_core'))
            and probe(a) then
            said['cis_bridge:framework:probe'] = nil
            return a
        end
    end
    probeFailed('cis_bridge:framework', forced, forced and CisBridgeFrameworks[forced])
    return nil
end

local function pickFrom(registry, order, convar)
    local forced, wrong = forcedName(registry, convar)
    if wrong then return nil end
    local list = forced and { forced } or order
    for _, name in ipairs(list) do
        local a = registry and registry[name]
        if a and started(a.resource) and probe(a) then
            said[convar .. ':probe'] = nil
            return a
        end
    end
    probeFailed(convar, forced, forced and registry and registry[forced])
    return nil
end

local loaded = {}
local lastJob = {}

function V1.detect()
    for _, a in pairs(CisBridgeFrameworks or {}) do
        if type(a) == 'table' and type(a.reset) == 'function' then pcall(a.reset) end
    end
    configLines = {}
    whyLines = {}
    fw = pickFramework()
    inv = pickFrom(CisBridgeInventories, INVENTORY_ORDER, 'cis_bridge:inventory')
    if not inv and not configLines.inventory and fw and fw.inventory and probe(fw.inventory) then
        inv = fw.inventory
    end
    doors = pickFrom(CisBridgeDoors, DOORS_ORDER, 'cis_bridge:doors')
    appearance = pickFrom(CisBridgeAppearances, APPEARANCE_ORDER, 'cis_bridge:appearance')
    detected = true
    -- Players who loaded before this resource started are loaded now.
    loaded = {}
    lastJob = {}
    if fw then
        for _, id in ipairs(GetPlayers and GetPlayers() or {}) do
            local src = tonumber(id)
            local ok, p = pcall(fw.server.player, src)
            if ok and p then loaded[src] = true end
        end
    end
    return fw, inv, doors
end

-- Re-detection waits while any write is in flight. A write that re-detects
-- halfway (each line of a Purchase checks the inventory) would take back or
-- refund through a different adapter, or through none: a stopped inventory
-- swapped `inv` to nil between the payment and the take-back, the take-back
-- raised, and the refund never ran. The write finishes on the adapters it
-- started with; a stopped one answers through `guard` and fails closed.
--
-- "In flight" is the per-player lock table (below), not a counter of its
-- own: `locked()` re-detects before it takes the lock, so a write sees a
-- newly started inventory, and `playerDropped` clears the entry of a write
-- that yielded and never came back, so one lost write cannot stop
-- re-detection for every player.
local busy = {}

-- A detect calls into other resources, so it can yield. While it is
-- suspended `fw`, `inv` and `doors` are half assigned: writes and re-detects
-- answer busy until it finishes. Only a detect yields inside `ensure()`, so
-- with this flag no second write can take the lock between `locked()`'s busy
-- check and its token.
local detecting = false

local function runDetect()
    detecting = true
    local ok, err = pcall(V1.detect)
    detecting = false
    if not ok then error(err, 0) end
end

local function ensure()
    if not detected and not detecting and next(busy) == nil then runDetect() end
end

-- The conformance run re-detects on demand, under the same rule: while any
-- write or detect is in flight it answers busy and changes nothing.
function V1.redetect()
    if detecting or next(busy) ~= nil then return false, 'busy' end
    runDetect()
    return true
end

function V1.summary()
    ensure()
    return {
        api = 1,
        framework = fw and fw.name or nil,
        inventory = inv and inv.name or nil,
        doors = doors and doors.name or nil,
        appearance = appearance and appearance.name or nil,
        config = next(configLines) and configLines or nil,
        why = whyLines,
        version = GetResourceMetadata and GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or nil,
    }
end

-- ===========================================================================
--  Guards
-- ===========================================================================

local function guard(label, fn, ...)
    local res = table.pack(pcall(fn, ...))
    if not res[1] then
        print(('^1cis_bridge: %s raised: %s^7'):format(label, tostring(res[2])))
        return false, 'error'
    end
    return table.unpack(res, 2, res.n)
end

local function isInt(v, lo, hi)
    return type(v) == 'number' and v == v and v % 1 == 0 and v >= lo and v <= hi
end

local function validSource(src)
    if not isInt(src, 1, 65535) then return false end
    return GetPlayerName(src) ~= nil
end

local function validItem(item)
    return type(item) == 'string' and #item >= 1 and #item <= 64 and item:match('^[%w_%-%.]+$') ~= nil
end

-- Item metadata and UseItem data are passed on to the inventory or framework
-- as they are. Bounded so one call cannot hand an adapter a table that costs
-- seconds to walk or serialise: nesting depth, and keys counted at every level.
local function validBlob(t)
    if t == nil then return true end
    if type(t) ~= 'table' then return false end
    local keys = 0
    local function walk(v, depth)
        if depth > MAX_BLOB_DEPTH then return false end
        for _, x in pairs(v) do
            keys = keys + 1
            if keys > MAX_BLOB_KEYS then return false end
            if type(x) == 'table' and not walk(x, depth + 1) then return false end
        end
        return true
    end
    return walk(t, 1)
end

local function validReason(r)
    return r == nil or (type(r) == 'string' and #r <= MAX_REASON)
end

local function needPlayer(src)
    if not validSource(src) then return false, 'bad_source' end
    ensure()
    if not fw then return false, 'no_framework' end
    local ok, p = pcall(fw.server.player, src)
    if not ok or not p then return false, 'not_loaded' end
    return true
end

-- `count` is required: a missing count is bad_count, never a default (qb's
-- AddItem adds 1 for a nil amount, and the bridge would then compare against
-- nil). A read with no count of its own passes 1.
local function needInventory(src, item, count)
    if not validSource(src) then return false, 'bad_source' end
    if not validItem(item) then return false, 'bad_item' end
    if not isInt(count, 1, MAX_COUNT) then return false, 'bad_count' end
    ensure()
    if not inv then return false, 'no_inventory' end
    return true
end

-- ===========================================================================
--  The lock
--
--  A token, not a flag: `playerDropped` clears the slot, the server id can be
--  reused, and the old write's release must not clear the new player's lock.
-- ===========================================================================

local seq = 0

local function locked(src, fn, ...)
    if not validSource(src) then return false, 'bad_source' end
    if busy[src] or detecting then return false, 'busy' end
    ensure()
    seq = seq + 1
    local token = seq
    busy[src] = token
    local res = table.pack(pcall(fn, src, ...))
    if busy[src] == token then busy[src] = nil end
    if not res[1] then
        print(('^1cis_bridge: write raised: %s^7'):format(tostring(res[2])))
        return false, 'error'
    end
    return table.unpack(res, 2, res.n)
end

-- ===========================================================================
--  Player and job
-- ===========================================================================

function V1.getPlayer(src)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    local p = guard(fw.name .. '.player', fw.server.player, src)
    if type(p) ~= 'table' then return false, 'not_loaded' end
    return { source = src, id = p.id, name = p.name, job = p.job, phone = p.phone }
end

function V1.isLoaded(src)
    return (needPlayer(src)) == true
end

-- For `cis_bridge test` only, not exported: asks the framework itself, past
-- every bridge shape check, whether it holds a player for `src`.
function V1.frameworkHasPlayer(src)
    ensure()
    if not validSource(src) or not fw or not fw.server.hasPlayer then return false end
    local ok, has = pcall(fw.server.hasPlayer, src)
    return ok and has == true
end

function V1.getJob(src)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    local job = guard(fw.name .. '.job', fw.server.job, src)
    if type(job) ~= 'table' then return false, 'not_loaded' end
    return job
end

local function emit(name, ...)
    TriggerEvent(name, ...)
end

-- `cis_bridge:jobChanged` fires once per change of job or grade (docs/V1.md
-- § Jobs). QBCore re-fires OnJobUpdate on every login (UpdateClient with key
-- 'all') and on every duty toggle, and QBCore:ToggleDuty is a client net
-- event with no cooldown, so a relay without this lets any client fire every
-- product's job handler at will. Duty is not part of the key for the same
-- reason: a key with `onDuty` in it is new on every toggle. A product that
-- cares about duty reads it from GetJob when it acts. Only a job that differs
-- from the last one sent goes out (`lastJob`, declared beside `loaded`: a
-- re-detect starts it again).

local function jobChanged(src, job)
    local key = type(job) == 'table'
        and ('%s|%s'):format(tostring(job.name), tostring(job.grade))
        or tostring(job)
    if lastJob[src] == key then return end
    lastJob[src] = key
    emit('cis_bridge:jobChanged', src, job)
end

function V1.setJob(src, name, grade)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    if type(name) ~= 'string' or #name < 1 or #name > 64 or not name:match('^[%w_%-]+$') then
        return false, 'bad_job'
    end
    if not isInt(grade, 0, 100) then return false, 'bad_grade' end
    -- 0.0 from msgpack or JSON is grade 0: ESX keys grades by tostring(grade),
    -- and tostring(0.0) is '0.0'.
    grade = math.tointeger(grade)
    local exists, missing = guard(fw.name .. '.jobExists', fw.server.jobExists, name, grade)
    if exists ~= true then return false, missing or 'unknown_job' end
    local set, refused = guard(fw.name .. '.setJob', fw.server.setJob, src, name, grade)
    if set ~= true then return false, refused or 'refused' end
    -- A framework with no job event of its own (cis_core) still tells products.
    if not (fw.events and fw.events.jobChanged) then
        jobChanged(src, (guard(fw.name .. '.job', fw.server.job, src)))
    end
    return true
end

function V1.notify(src, message, kind)
    if not validSource(src) then return false, 'bad_source' end
    if type(message) ~= 'string' or #message < 1 or #message > MAX_MESSAGE then
        return false, 'bad_message'
    end
    kind = kind or 'info'
    -- 'inform' is the old ox_lib spelling of info; ox_lib maps it itself.
    if kind == 'inform' then kind = 'info' end
    if not KINDS[kind] then return false, 'bad_message' end
    ensure()
    if not fw then return false, 'no_framework' end
    local ok = guard(fw.name .. '.notify', fw.server.notify, src, message, kind)
    if ok ~= true then return false, 'refused' end
    return true
end

-- ===========================================================================
--  Money
-- ===========================================================================

local function account(name)
    name = name or 'cash'
    if type(name) ~= 'string' or not ACCOUNTS[name] then return nil end
    local mapped = fw.accounts[name]
    return mapped
end

local function moneyArgs(src, accountName, amount, reason)
    local ok, why = needPlayer(src)
    if not ok then return nil, why end
    local acc = account(accountName)
    if not acc then return nil, 'bad_account' end
    if not isInt(amount, 1, MAX_AMOUNT) then return nil, 'bad_amount' end
    if not validReason(reason) then return nil, 'bad_order' end
    return acc
end

-- The balance as a whole number, or nil, reason. Floored the way GetMoney is,
-- so a fractional ESX balance still moves by exactly `amount`:
-- floor(x + n) == floor(x) + n for a whole n.
local function balance(src, acc)
    local bal, e = guard(fw.name .. '.balance', fw.server.balance, src, acc)
    if bal == false and e == 'error' then return nil, 'error' end
    if type(bal) ~= 'number' or bal ~= bal or bal == math.huge or bal == -math.huge then
        return nil, 'not_loaded'
    end
    return math.floor(bal)
end

function V1.getMoney(src, accountName)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    local acc = account(accountName)
    if not acc then return false, 'bad_account' end
    local bal, unread = balance(src, acc)
    if not bal then return false, unread end
    return bal
end

local function moneyInconsistent(src, what, acc, amount, moved)
    print(('^1cis_bridge: %s of %d %s for player %d moved %s^7'):format(what, amount, acc, src, tostring(moved)))
    emit('cis_bridge:inconsistent', src, { action = what, account = acc, amount = amount, moved = moved })
end

-- One money write, proved by the balance before and after (docs/V1.md
-- § Money). The adapter's answer is a hint: ESX, QBCore and Qbox
-- answer true from code a server can override or hook (a Qbox money hook can
-- veto and the caller still sees its own `true`), so only the balance decides.
--   moved exactly `amount`  -> true, whatever the adapter said
--   moved nothing           -> false, the adapter's reason or 'refused'
--   moved anything else, or unreadable after the write -> false, 'error',
--   one console line and cis_bridge:inconsistent: money changed hands and
--   the bridge cannot say how much was its own.
-- A third-party resource writing the same balance between the two reads lands
-- in the last case. The per-player lock covers only the bridge's own writes.
-- `name` is the v1 account the caller asked for, which the event reports;
-- `acc` is the framework's own name for it.
local function moneyWrite(src, acc, amount, sign, reason, name)
    local before, unread = balance(src, acc)
    if not before then return false, unread end
    if sign < 0 and before < amount then return false, 'insufficient_funds' end
    local label = sign > 0 and 'add' or 'remove'
    local ok, refused = guard(fw.name .. '.' .. label, fw.server[label], src, acc, amount, reason or 'cis_bridge')
    local after = balance(src, acc)
    if not after then
        moneyInconsistent(src, label .. '_money', name, amount, nil)
        return false, 'error', true
    end
    local moved = (after - before) * sign
    if moved == amount then return true end
    if moved == 0 then
        if ok == true then return false, 'refused' end
        return false, refused or 'refused'
    end
    moneyInconsistent(src, label .. '_money', name, amount, moved)
    return false, 'error', true
end

local function addMoney(src, accountName, amount, reason)
    local acc, why = moneyArgs(src, accountName, amount, reason)
    if not acc then return false, why end
    return moneyWrite(src, acc, amount, 1, reason, accountName)
end

-- The floor is checked here on every framework: QBCore bank goes to -5000,
-- Qbox bank is unbounded, and ESX with ox_inventory removes bank with no
-- check at all (es_extended overrides/oxinventory.lua).
local function removeMoney(src, accountName, amount, reason)
    local acc, why = moneyArgs(src, accountName, amount, reason)
    if not acc then return false, why end
    return moneyWrite(src, acc, amount, -1, reason, accountName)
end

-- ===========================================================================
--  Items
--
--  `count` is the proof. The internals answer a third value on failure: how
--  many units are stuck, meaning they changed hands and could not be put
--  back. Purchase prices those units instead of refunding them.
-- ===========================================================================

local function count(src, item)
    local n = guard(inv.name .. '.count', inv.count, src, item)
    if type(n) ~= 'number' or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.floor(n)
end

function V1.getItemCount(src, item)
    local ok, why = needInventory(src, item, 1)
    if not ok then return false, why end
    item = item:lower()
    local n = count(src, item)
    if n == nil then return false, 'not_loaded' end
    return n
end

local function canCarry(src, item, n)
    local known, unknown = guard(inv.name .. '.known', inv.known, item)
    if known == false and unknown == 'error' then return false, 'error' end
    if known == false then return false, 'unknown_item' end
    local yes, why = guard(inv.name .. '.canCarry', inv.canCarry, src, item, n)
    -- nil is "this inventory cannot check" (codem); the count check decides.
    if yes == nil and why == nil then return true end
    if yes ~= true then return false, why or 'cannot_carry' end
    return true
end

function V1.canCarry(src, item, n)
    local ok, why = needInventory(src, item, n)
    if not ok then return false, why end
    return canCarry(src, item:lower(), n)
end

local function inconsistent(src, what, item, stuck)
    print(('^1cis_bridge: %s %s x%d for player %d could not be undone^7'):format(what, item, stuck, src))
    emit('cis_bridge:inconsistent', src, { action = what, item = item, count = stuck })
end

local function addItem(src, item, n, metadata)
    local ok, why = needInventory(src, item, n)
    if not ok then return false, why end
    if not validBlob(metadata) then return false, 'bad_metadata' end
    item = item:lower()
    local before = count(src, item)
    if before == nil then return false, 'not_loaded' end
    local carry, cannot = canCarry(src, item, n)
    if not carry then return false, cannot end
    -- On success an adapter may answer the slots the add landed in (ox does).
    -- A take-back passes them on, so it removes these units and not an older
    -- one of the same name: ox's RemoveItem with no slot takes any matching
    -- slot, which can be a weapon the player already owned, serial and all.
    local added, info = guard(inv.name .. '.add', inv.add, src, item, n, metadata)
    local refused = added ~= true and info or nil
    local slots = added == true and type(info) == 'table' and info or nil
    local after = count(src, item)
    if after == nil then
        inconsistent(src, 'add', item, n)
        return false, 'error', n
    end
    local landed = after - before
    if landed >= n then return true, nil, 0, slots end
    if landed <= 0 then return false, refused or 'refused', 0 end
    -- Partial: put the units that did land back. ox does this for a
    -- non-stackable item with too few free slots; with nothing stuck after the
    -- take-back, the honest answer is that it did not fit.
    guard(inv.name .. '.remove', inv.remove, src, item, landed, slots)
    -- Clamped to what this add landed: a change from elsewhere to the same
    -- item is not this write's, and pricing it would refund too little.
    local now = count(src, item) or after
    local stuck = math.min(landed, math.max(0, now - before))
    if stuck == 0 then return false, 'cannot_carry', 0 end
    inconsistent(src, 'add', item, stuck)
    return false, 'partial', stuck
end

local function removeItem(src, item, n)
    local ok, why = needInventory(src, item, n)
    if not ok then return false, why end
    item = item:lower()
    local before = count(src, item)
    if before == nil then return false, 'not_loaded' end
    if before < n then return false, 'insufficient_items' end
    local _, refused = guard(inv.name .. '.remove', inv.remove, src, item, n)
    local after = count(src, item)
    if after == nil then
        inconsistent(src, 'remove', item, n)
        return false, 'error', n
    end
    local gone = before - after
    if gone >= n then return true end
    if gone <= 0 then return false, refused or 'refused', 0 end
    -- Partial: no add-back. A plain add creates fresh units, so a weapon's
    -- serial or an item's durability would not come back; the honest answer
    -- is what went, for the product to settle.
    inconsistent(src, 'remove', item, gone)
    return false, 'partial', gone
end

-- ===========================================================================
--  Purchase
--
--  validate -> CanCarry every line -> balance -> RemoveMoney -> AddItem every
--  line -> on failure take back what landed and refund what was not kept.
--  One lock for the whole order.
-- ===========================================================================

local function orderLines(order)
    if type(order) ~= 'table' then return nil end
    local lines = order.lines
    if lines == nil then
        lines = { { item = order.item, count = order.count or 1, price = order.price, metadata = order.metadata } }
    end
    if type(lines) ~= 'table' or #lines < 1 or #lines > MAX_LINES then return nil end
    local out, total = {}, 0
    for i = 1, #lines do
        local l = lines[i]
        if type(l) ~= 'table' or not validItem(l.item) then return nil, 'bad_item' end
        local n = l.count or 1
        if not isInt(n, 1, MAX_COUNT) then return nil, 'bad_count' end
        if not isInt(l.price, 0, MAX_AMOUNT) then return nil, 'bad_amount' end
        if not validBlob(l.metadata) then return nil, 'bad_metadata' end
        total = total + l.price * n
        if total > MAX_AMOUNT then return nil, 'bad_amount' end
        out[i] = { item = l.item:lower(), count = n, price = l.price, metadata = l.metadata }
    end
    return out, total
end

-- The character on `src` now, or nil. An order yields at every inventory and
-- framework call, and in that time the server id can change character: a
-- logout to the character menu, or a drop and a new player on the same id.
local function characterOf(src)
    local ok, p = pcall(fw.server.player, src)
    if not ok or type(p) ~= 'table' then return nil end
    return p.id
end

local function purchase(src, order)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    if not inv then return false, 'no_inventory' end
    -- Pinned once and checked before each phase: what lands, is taken back or
    -- is refunded after a switch would land on the wrong character.
    local pinned = characterOf(src)
    if pinned == nil then return false, 'not_loaded' end
    local function same() return characterOf(src) == pinned end
    local lines, total = orderLines(order)
    if not lines then return false, total or 'bad_order' end
    local accountName = order.account or 'cash'
    if not account(accountName) then return false, 'bad_account' end
    if not validReason(order.reason) then return false, 'bad_order' end
    local reason = order.reason or 'cis_bridge purchase'

    for _, l in ipairs(lines) do
        local carry, cannot = canCarry(src, l.item, l.count)
        if not carry then return false, cannot end
    end

    if not same() then return false, 'not_loaded' end
    if total > 0 then
        local paid, refused = removeMoney(src, accountName, total, reason)
        if not paid then return false, refused end
    end

    local failure, kept, anyStuck, switched = nil, 0, false, false
    local done = {}
    for i, l in ipairs(lines) do
        if not same() then
            failure, switched = 'error', true
            break
        end
        local added, refused, stuck, slots = addItem(src, l.item, l.count, l.metadata)
        if not added then
            failure = refused or 'refused'
            kept = kept + (stuck or 0) * l.price
            anyStuck = (stuck or 0) > 0
            break
        end
        done[i] = { line = l, slots = slots }
    end
    if not failure then return true end

    -- Take back every line that landed. A unit that cannot be taken back is
    -- the player's, and it is paid for.
    --
    -- Not through removeItem: its third value counts units it could not put
    -- Back after a partial remove, which is the opposite of what is kept here,
    -- and a refused remove answers 0 -- read as "nothing kept", that refunded
    -- the whole line and the player kept it for free. The count before and
    -- after is the only measure: whatever did not leave is kept and paid for,
    -- and an unreadable count keeps the whole line.
    --
    -- After a character switch nothing is taken back or refunded: the lines
    -- that landed stay with the character that paid, and the refund it is
    -- owed is reported, never paid to whoever holds the id now.
    for _, d in pairs(done) do
        local l = d.line
        if not switched and not same() then switched = true end
        if switched then
            kept = kept + l.count * l.price
        else
            local before = count(src, l.item)
            guard(inv.name .. '.remove', inv.remove, src, l.item, l.count, d.slots)
            local after = count(src, l.item)
            local gone = (before and after) and math.max(0, math.min(l.count, before - after)) or 0
            if gone < l.count then
                kept = kept + (l.count - gone) * l.price
                anyStuck = true
                inconsistent(src, 'purchase', l.item, l.count - gone)
            end
        end
    end
    local refund = total - kept
    if refund > 0 and (switched or not same()) then
        print(('^1cis_bridge: player %d changed character during a purchase; refund of %d %s to %s not paid^7')
            :format(src, refund, accountName, pinned))
        emit('cis_bridge:inconsistent', src, { action = 'refund', account = accountName, amount = refund, moved = 0 })
        return false, 'error'
    end
    if switched then return false, 'error' end
    if refund > 0 then
        -- refundFailed means the refund did not move: a listener may pay it
        -- again. A refund that moved the wrong amount, or left the balance
        -- unreadable, may have landed, so it is `error` and the money
        -- inconsistent event moneyWrite already fired, never refundFailed.
        local back, _, unknown = addMoney(src, accountName, refund, 'cis_bridge refund')
        if not back and unknown then return false, 'error' end
        if not back then
            print(('^1cis_bridge: refund of %d %s to player %d FAILED^7'):format(refund, accountName, src))
            emit('cis_bridge:refundFailed', src, accountName, refund)
            return false, 'refund_failed'
        end
    end
    return false, anyStuck and 'partial' or failure
end

-- ===========================================================================
--  Doors
-- ===========================================================================

local function validDoor(id)
    return isInt(id, 0, 2 ^ 31) or (type(id) == 'string' and #id >= 1 and #id <= 64)
end

function V1.getDoorLock(id)
    if not validDoor(id) then return false, 'bad_door' end
    ensure()
    if not doors then return false, 'no_doors' end
    local state, why = guard(doors.name .. '.state', doors.state, id)
    if state == nil or state == false then return false, why or 'unknown_door' end
    return state
end

function V1.setDoorLock(id, isLocked)
    if not validDoor(id) then return false, 'bad_door' end
    if type(isLocked) ~= 'boolean' then return false, 'bad_door' end
    ensure()
    if not doors then return false, 'no_doors' end
    local ok, why = guard(doors.name .. '.set', doors.set, id, isLocked)
    if ok ~= true then return false, why or 'refused' end
    return true
end

-- ===========================================================================
--  Vehicles
-- ===========================================================================

local MAX_PLATE = 15

-- The id the framework keeps for an owned vehicle: Qbox `player_vehicles.id`,
-- the plate itself on ESX and QBCore, whose tables key by plate. A framework
-- that cannot tell answers 'unsupported', so a product can fall back to the
-- plate instead of treating every vehicle as not owned.
function V1.getOwnedVehicleId(plate)
    if type(plate) == 'number' and plate == plate and plate % 1 == 0 then
        plate = tostring(math.tointeger(plate) or plate)
    end
    if type(plate) ~= 'string' then return false, 'bad_plate' end
    plate = plate:match('^%s*(.-)%s*$')
    if #plate < 1 or #plate > MAX_PLATE or plate:find('%c') then return false, 'bad_plate' end
    ensure()
    if not fw or type(fw.server.ownedVehicleId) ~= 'function' then return false, 'unsupported' end
    local id, why = guard(fw.name .. '.ownedVehicleId', fw.server.ownedVehicleId, plate)
    if id == false then return false, why or 'error' end
    if id == nil or id == '' then return false, 'not_owned' end
    return id
end

-- ===========================================================================
--  Gang, player state and usable items
-- ===========================================================================

-- QBCore and Qbox keep a gang beside the job. A framework with no gang says
-- 'unsupported' (after the player check, so an unloaded player is still
-- 'not_loaded').
function V1.getGang(src)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    if type(fw.server.gang) ~= 'function' then return false, 'unsupported' end
    local gang, reason = guard(fw.name .. '.gang', fw.server.gang, src)
    if gang == false then return false, reason or 'error' end
    if type(gang) ~= 'table' then return false, 'not_loaded' end
    return { name = gang.name, label = gang.label, grade = gang.grade, isboss = gang.isboss }
end

-- Dead, last stand and handcuffed, as the ambulance and police resources
-- leave them in the framework's player metadata.
function V1.getPlayerState(src)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    if type(fw.server.state) ~= 'function' then return false, 'unsupported' end
    local state, reason = guard(fw.name .. '.state', fw.server.state, src)
    if state == false then return false, reason or 'error' end
    if type(state) ~= 'table' then return false, 'not_loaded' end
    return { dead = state.dead == true, lastStand = state.lastStand == true, cuffed = state.cuffed == true }
end

-- Runs the item's registered usable callback for the player, the way the
-- framework's own inventory does. It does not check that the player holds the
-- item and takes nothing from them: the callback and the inventory own that.
function V1.useItem(src, item, data)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    if not validItem(item) then return false, 'bad_item' end
    if not validBlob(data) then return false, 'bad_data' end
    if type(fw.server.canUseItem) ~= 'function' or type(fw.server.useItem) ~= 'function' then
        return false, 'not_usable'
    end
    local usable, usableWhy = guard(fw.name .. '.canUseItem', fw.server.canUseItem, item)
    if usable ~= true then return false, usableWhy == 'error' and 'error' or 'not_usable' end
    local used, usedWhy = guard(fw.name .. '.useItem', fw.server.useItem, src, item, data)
    if used ~= true then return false, usedWhy == 'not_usable' and 'not_usable' or 'error' end
    return true
end

-- ===========================================================================
--  Character id to server id
-- ===========================================================================

local function validCharId(id)
    return type(id) == 'string' and #id >= 1 and #id <= 64 and not id:find('%c')
end

-- The server id of the loaded player whose character id (`GetPlayer().id`) is
-- `charId`, or false, 'offline'. The framework's own index answers when the
-- adapter has one; else the bridge's loaded players are read. Either way the
-- player is read back, so an index entry left over from a character switch is
-- never trusted.
function V1.getSourceByCharId(charId)
    if not validCharId(charId) then return false, 'bad_id' end
    ensure()
    if not fw then return false, 'no_framework' end
    local function holds(src)
        local ok, p = pcall(fw.server.player, src)
        return ok and type(p) == 'table' and p.id == charId
    end
    if type(fw.server.sourceOf) == 'function' then
        local src, why = guard(fw.name .. '.sourceOf', fw.server.sourceOf, charId)
        if src == false then return false, why or 'error' end
        if isInt(src, 1, 65535) and holds(src) then return src end
        return false, 'offline'
    end
    for src in pairs(loaded) do
        if holds(src) then return src end
    end
    return false, 'offline'
end

-- ===========================================================================
--  Appearance
--
--  The look lives on the client's ped, so a save is two halves: the server
--  half prepares what the clothing resource needs (esx_skin's edit session)
--  and asks the client; the client half reads the ped and saves through the
--  resource's own net event (client/v1.lua). True means the save was sent.
--
--  A server half that answers true, 'reply' saves on the server instead:
--  the client half sends what it read back through
--  'cis_bridge:appearance:reply', once, within APPEARANCE_REPLY_MS, and the
--  adapter's server.finish(src, data, player) saves it. skinchanger does this
--  so esx_skin's scoped SaveOutfit takes only clothing keys, where an edit
--  session would let the client save any field of the skin. qb-clothing does
--  it so the clothing is merged into the citizen's stored skin, which keeps
--  the face.
-- ===========================================================================

local APPEARANCE_REPLY_MS = 10000
local replyWanted = {}

function V1.saveAppearance(src)
    local ok, why = needPlayer(src)
    if not ok then return false, why end
    if not appearance then return false, 'no_appearance' end
    local sent, reason = guard(appearance.name .. '.save', appearance.server.save, src)
    if sent ~= true then return false, reason or 'refused' end
    local reply = reason == 'reply'
    if reply then
        replyWanted[src] = { name = appearance.name, expires = GetGameTimer() + APPEARANCE_REPLY_MS }
    end
    TriggerClientEvent('cis_bridge:appearance:save', src, appearance.name, reply)
    return true
end

RegisterNetEvent('cis_bridge:appearance:reply', function(name, data)
    local src = source
    local want = replyWanted[src]
    if not want then return end
    replyWanted[src] = nil
    if want.name ~= name or want.expires < GetGameTimer() then return end
    if not appearance or appearance.name ~= name or type(appearance.server.finish) ~= 'function' then return end
    local saved, why = guard(name .. '.finish', appearance.server.finish, src, data, (V1.getPlayer(src)))
    if saved ~= true then
        print(('^3cis_bridge: %s did not save the appearance for player %d: %s^7'):format(name, src, tostring(why)))
    end
end)

-- ===========================================================================
--  Exports
-- ===========================================================================

-- The internal money writers answer a third value, true when money may have
-- moved by an unknown amount; Purchase reads it, a product never sees it.
function V1.addMoney(src, accountName, amount, reason)
    local ok, why = locked(src, addMoney, accountName, amount, reason)
    return ok, why
end

function V1.removeMoney(src, accountName, amount, reason)
    local ok, why = locked(src, removeMoney, accountName, amount, reason)
    return ok, why
end

-- The internal writers answer a third value, the units that are stuck; the
-- export answers only ok, reason.
function V1.addItem(src, item, n, metadata)
    local ok, why = locked(src, addItem, item, n, metadata)
    if ok == true then return true end
    return false, why
end

function V1.removeItem(src, item, n)
    local ok, why = locked(src, removeItem, item, n)
    return ok, why
end

function V1.purchase(src, order)
    return locked(src, purchase, order)
end

function V1.setJobLocked(src, name, grade)
    return locked(src, V1.setJob, name, grade)
end

-- Every exported function answers `false, 'error'` instead of raising. The
-- wrap replaces the V1 entry itself, so CisBridgeV1 callers in this resource
-- get the same answer an export caller does. The registrations below are
-- literal so `npm run test:api` can read each signature from its definition.
for exportName, key in pairs({
    GetPlayer = 'getPlayer', IsLoaded = 'isLoaded', GetMoney = 'getMoney', AddMoney = 'addMoney',
    RemoveMoney = 'removeMoney', GetItemCount = 'getItemCount', CanCarry = 'canCarry', AddItem = 'addItem',
    RemoveItem = 'removeItem', GetJob = 'getJob', SetJob = 'setJobLocked', Notify = 'notify',
    Purchase = 'purchase', GetDoorLock = 'getDoorLock', SetDoorLock = 'setDoorLock', GetSummary = 'summary',
    GetOwnedVehicleId = 'getOwnedVehicleId', SaveAppearance = 'saveAppearance',
    GetGang = 'getGang', GetPlayerState = 'getPlayerState', UseItem = 'useItem',
    GetSourceByCharId = 'getSourceByCharId',
}) do
    local fn = V1[key]
    V1[key] = function(...) return guard(exportName, fn, ...) end
end

exports('GetPlayer', V1.getPlayer)
exports('IsLoaded', V1.isLoaded)
exports('GetMoney', V1.getMoney)
exports('AddMoney', V1.addMoney)
exports('RemoveMoney', V1.removeMoney)
exports('GetItemCount', V1.getItemCount)
exports('CanCarry', V1.canCarry)
exports('AddItem', V1.addItem)
exports('RemoveItem', V1.removeItem)
exports('GetJob', V1.getJob)
exports('SetJob', V1.setJobLocked)
exports('Notify', V1.notify)
exports('Purchase', V1.purchase)
exports('GetDoorLock', V1.getDoorLock)
exports('SetDoorLock', V1.setDoorLock)
exports('GetSummary', V1.summary)
exports('GetOwnedVehicleId', V1.getOwnedVehicleId)
exports('SaveAppearance', V1.saveAppearance)
exports('GetGang', V1.getGang)
exports('GetPlayerState', V1.getPlayerState)
exports('UseItem', V1.useItem)
exports('GetSourceByCharId', V1.getSourceByCharId)

-- ===========================================================================
--  Events
--
--  Framework server events are local TriggerEvents, so AddEventHandler is the
--  whole subscription: no RegisterNetEvent, which would let a client fire them.
--  Every adapter's events are hooked; only the active adapter's are re-emitted.
-- ===========================================================================

local function playerLoaded(src)
    if not src or loaded[src] then return end
    loaded[src] = true
    emit('cis_bridge:playerLoaded', src)
end

-- A logout or a character switch does not clear the lock: a write still
-- running for that source (a Qbox SetJob does DB work and yields) owns it
-- until its own token releases it, and clearing it here let a second write
-- run beside the first. Only a dropped player's lock is cleared, because a
-- write stuck on a gone player must not block the next player given that id.
local function playerUnloaded(src)
    if not src then return end
    lastJob[src] = nil
    replyWanted[src] = nil
    if not loaded[src] then return end
    loaded[src] = nil
    emit('cis_bridge:playerUnloaded', src)
end

for _, adapter in pairs(CisBridgeFrameworks or {}) do
    if type(adapter) == 'table' and type(adapter.events) == 'table' then
        for kind, spec in pairs(adapter.events) do
            AddEventHandler(spec[1], function(...)
                -- A framework started after the bridge marks detection stale; its
                -- first event can arrive before any export read re-detects.
                local before = not detected and loaded or nil
                ensure()
                if fw ~= adapter then return end
                local ok, src, job = pcall(spec[2], ...)
                src = ok and tonumber(src) or nil
                if not src then return end
                if kind == 'loaded' then
                    -- The re-detect above seeds every player the framework holds,
                    -- this one too, which would swallow its own loaded event. Only
                    -- a player loaded before the re-detect stays seeded.
                    if before and not before[src] then loaded[src] = nil end
                    playerLoaded(src)
                elseif kind == 'unloaded' then
                    playerUnloaded(src)
                elseif kind == 'jobChanged' then
                    jobChanged(src, job)
                end
            end)
        end
    end
end

for _, adapter in pairs(CisBridgeDoors or {}) do
    if type(adapter) == 'table' and type(adapter.events) == 'table' and adapter.events.changed then
        local spec = adapter.events.changed
        AddEventHandler(spec[1], function(...)
            ensure()
            if doors ~= adapter then return end
            local ok, id, isLocked = pcall(spec[2], ...)
            if ok and id ~= nil then emit('cis_bridge:doorChanged', id, isLocked) end
        end)
    end
end

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then busy[src] = nil end
    playerUnloaded(src)
end)

-- A framework, inventory, door or clothing resource that starts or stops
-- changes the answer.
local function onResource(resource)
    if resource == GetCurrentResourceName() then return end
    local watched = false
    for _, reg in ipairs({ CisBridgeFrameworks or {}, CisBridgeInventories or {}, CisBridgeDoors or {},
        CisBridgeAppearances or {} }) do
        for _, a in pairs(reg) do
            if type(a) == 'table' and a.resource == resource then watched = true end
        end
    end
    if watched then detected = false end
end

AddEventHandler('onResourceStart', onResource)
AddEventHandler('onResourceStop', onResource)

CisBridgeV1 = V1
