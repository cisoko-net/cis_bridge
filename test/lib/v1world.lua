-- A fake FiveM server for the v1 suites (test/v1.lua, test/v1-client.lua).
--
-- One store holds the players, their money, items and jobs, and the doors.
-- Every framework, inventory, doors and target resource the v1 adapters talk
-- to is built on that store, with the call shapes the adapters' header
-- comments cite, so a write made through ESX is the same write ox_inventory
-- counts.
--
-- The exports proxy is strict on purpose. In FiveM `exports.res:Fn(a)` reaches
-- the export as `Fn(a)`: the proxy drops its own self. Indexing an export a
-- resource never declared raises, and so does calling into a resource that is
-- not started. Tables cross as copies (msgpack); functions cross as references.
-- A fake that forgave a dot call on the proxy, a missing export, or a write
-- into a snapshot would pass exactly the defects these suites exist to catch.
--
-- The framework methods are strict the other way: ESX xPlayer methods and QB
-- `Functions` are dot calls, and each one raises when its first argument is a
-- table, which is what a colon call hands it.

local W = {}

-- A function crosses as a funcref: a table whose metatable has __call, and
-- whose __index raises (citizen scheduler.lua, funcref_mt). `type()` of it is
-- 'table', so an adapter that tests `type(f) == 'function'` on anything an
-- export handed it is wrong in FiveM and goes red here.
-- What it answers crosses back the same way, so an xPlayer from
-- ESX.GetPlayerFromId carries funcref methods, as it does in FiveM.
local copy
local funcrefMt = {
    __index = function() error('Cannot index a funcref', 2) end,
    __newindex = function() error('Cannot set indexes on a funcref', 2) end,
    __call = function(self, ...)
        return W.crossBack(rawget(self, '__fn')(...))
    end,
}

function copy(v)
    if type(v) == 'function' then
        return setmetatable({ __cfx_functionReference = tostring(v), __fn = v }, funcrefMt)
    end
    if type(v) ~= 'table' then return v end
    if rawget(v, '__cfx_functionReference') ~= nil then return v end
    local out = {}
    for k, x in pairs(v) do out[copy(k)] = copy(x) end
    return out
end
W.copy = copy

local function packCopy(...)
    local res = table.pack(...)
    for i = 1, res.n do res[i] = copy(res[i]) end
    return res
end

-- The answer crosses back as `{ fn(...) }` packed and unpacked by length
-- (citizen scheduler.lua SetCallRefRoutine and funcref __call), so trailing
-- nils are gone: a callee that answers a lone nil hands the caller zero
-- values, and `tonumber(call())` raises "bad argument #1".
function W.crossBack(...)
    local res = { ... }
    local n = #res
    for i = 1, n do res[i] = copy(res[i]) end
    return table.unpack(res, 1, n)
end

-- ===========================================================================
--  Engine
-- ===========================================================================

W.declared = {}

local function resetEngine()
    W.state = { cis_bridge = 'started' }
    W.convars = {}
    W.fired = {}
    W.clientFired = {}
    W.prints = {}
    W.calls = {}
    W.invoker = nil
    W.fault = {}
    W.threads = {}
    W.gone = {}
    W.serverFired = {}
    W.sql = {}
    W.skins = {}
    W.sqlError = nil
    W.jsonStore = {}
end

W.handlers = {}
W.netEvents = {}

local function call(resource, name, fn)
    return function(_self, ...)
        if W.state[resource] ~= 'started' then
            error(('resource %s is not started'):format(resource), 2)
        end
        local key = resource .. '.' .. name
        W.calls[#W.calls + 1] = { key = key, args = packCopy(...) }
        if W.fault.raise and W.fault.raise[key] then
            error(('%s raised on purpose'):format(key), 2)
        end
        if W.fault.during and W.fault.during[key] then
            W.fault.during[key]()
        end
        return W.crossBack(fn(table.unpack(packCopy(...), 1, select('#', ...))))
    end
end

local function proxy(resource)
    return setmetatable({}, {
        __index = function(_, name)
            local fns = W.declared[resource]
            local fn = fns and fns[name]
            if fn == nil then
                error(('No such export %s in resource %s'):format(name, resource), 2)
            end
            return call(resource, name, fn)
        end,
    })
end

local exportsObject = setmetatable({}, {
    __index = function(_, resource) return proxy(resource) end,
    __call = function(_, name, fn)
        W.declared.cis_bridge = W.declared.cis_bridge or {}
        W.declared.cis_bridge[name] = fn
    end,
})

-- Every call the store saw for one export, in order.
function W.callsTo(key)
    local out = {}
    for _, c in ipairs(W.calls) do
        if c.key == key then out[#out + 1] = c.args end
    end
    return out
end

-- Every event of this name fired since the last reset.
function W.firedNamed(name)
    local out = {}
    for _, e in ipairs(W.fired) do
        if e.name == name then out[#out + 1] = e.args end
    end
    return out
end

function W.fire(name, src, ...)
    W.fired[#W.fired + 1] = { name = name, args = table.pack(...) }
    local prev = rawget(_G, 'source')
    rawset(_G, 'source', src)
    for _, h in ipairs(W.handlers[name] or {}) do h(...) end
    rawset(_G, 'source', prev)
end

local engine = {
    exports = exportsObject,
    -- Server json: encode answers a token and keeps a copy; decode gives a
    -- copy back for a token and raises on anything else, as bad JSON does.
    json = {
        encode = function(t)
            local token = 'sjson:' .. tostring(#W.jsonStore + 1)
            W.jsonStore[#W.jsonStore + 1] = copy(t)
            W.jsonStore[token] = W.jsonStore[#W.jsonStore]
            return token
        end,
        decode = function(s)
            local t = W.jsonStore[s]
            if type(t) ~= 'table' then error('bad json', 2) end
            return copy(t)
        end,
    },
    GetResourceState = function(r) return W.state[r] or 'missing' end,
    GetConvar = function(k, d) return W.convars[k] or d end,
    GetPlayerName = function(src) local p = W.players[src]; return p and p.account or nil end,
    GetPlayers = function()
        local ids = {}
        for src in pairs(W.players) do ids[#ids + 1] = src end
        table.sort(ids)
        for i, src in ipairs(ids) do ids[i] = tostring(src) end
        return ids
    end,
    TriggerEvent = function(name, ...) W.fire(name, nil, ...) end,
    AddEventHandler = function(name, fn)
        W.handlers[name] = W.handlers[name] or {}
        table.insert(W.handlers[name], fn)
    end,
    RegisterNetEvent = function(name, fn)
        W.netEvents[name] = true
        if fn then
            W.handlers[name] = W.handlers[name] or {}
            table.insert(W.handlers[name], fn)
        end
    end,
    GetGameTimer = function() return W.clock end,
    TriggerClientEvent = function(name, target, ...)
        W.clientFired[#W.clientFired + 1] = { name = name, target = target, args = table.pack(...) }
    end,
    -- A bool native answers the number 1 when true and false when false in
    -- Lua, never the boolean true (citizenfx @46de79b ScriptInvoker.h:361-372).
    -- Answering true would keep a `== true` comparison green that fails live.
    IsDuplicityVersion = function()
        if W.server ~= false then return 1 end
        return false
    end,
    GetCurrentResourceName = function() return 'cis_bridge' end,
    GetResourceMetadata = function(_r, key) return key == 'version' and '1.0.0' or nil end,
    GetInvokingResource = function() return W.invoker end,
    -- FiveM's promise and Citizen.Await, for a callback the fake runs at once:
    -- awaiting a promise nothing resolved raises instead of hanging.
    promise = {
        new = function()
            local p = { done = false }
            function p:resolve(v) self.done, self.value = true, v end
            function p:reject(e) self.done, self.err = true, e end
            return p
        end,
    },
    Citizen = {
        Await = function(p)
            if not p.done then error('Citizen.Await on a promise nothing resolved', 2) end
            if p.err ~= nil then error(p.err, 2) end
            return p.value
        end,
    },
    print = function(...)
        local parts = table.pack(...)
        for i = 1, parts.n do parts[i] = tostring(parts[i]) end
        W.prints[#W.prints + 1] = table.concat(parts, ' ')
    end,
}

-- Client only (installed when `W.server == false`): threads, uptime, entities.
--
-- `CreateThread` queues, as FiveM's does (the body starts on a later tick,
-- not inside the call), and `Wait(ms)` yields the thread for `ms` of fake
-- uptime. Nothing runs until a test calls `W.runThreads(ms)`, which advances
-- `W.clock` by `ms` and wakes every thread due on the way. A `Wait(0)` costs
-- one millisecond, as a frame does, so a poll loop always ends.
-- `DoesEntityExist` answers 1 unless the test put the handle in `W.gone`.
W.clock = 0
local clientEngine = {
    CreateThread = function(fn)
        W.threads[#W.threads + 1] = { co = coroutine.create(fn), wake = W.clock }
    end,
    Wait = function(ms) coroutine.yield(ms) end,
    GetGameTimer = function() return W.clock end,
    -- Bool: 1 or false, as the real native (see IsDuplicityVersion above).
    DoesEntityExist = function(entity)
        if W.gone[entity] then return false end
        return 1
    end,
    PlayerPedId = function() return W.ped end,
    GetEntityModel = function() return 1885233650 end,
    -- A prop that is off reads -1, its texture -1 (the natives' answer).
    GetPedPropIndex = function(_ped, id) local p = W.look.props[id]; return p and p[1] or -1 end,
    GetPedPropTextureIndex = function(_ped, id) local p = W.look.props[id]; return p and p[2] or -1 end,
    GetPedDrawableVariation = function(_ped, id) local c = W.look.comps[id]; return c and c[1] or 0 end,
    GetPedTextureVariation = function(_ped, id) local c = W.look.comps[id]; return c and c[2] or 0 end,
    GetPedHairColor = function() return W.look.hair or 0 end,
    SetPedPropIndex = function(_ped, id, d, t, attach)
        if attach ~= true then error('SetPedPropIndex attach must be true', 2) end
        W.look.props[id] = { d, t }
    end,
    ClearPedProp = function(_ped, id) W.look.props[id] = nil end,
    SetPedComponentVariation = function(_ped, id, d, t, palette)
        if palette ~= 0 then error('SetPedComponentVariation palette must be 0', 2) end
        W.look.comps[id] = { d, t }
    end,
    TriggerServerEvent = function(name, ...)
        W.serverFired[#W.serverFired + 1] = { name = name, args = packCopy(...) }
    end,
    -- json.encode answers a token and keeps a copy, so a test reads the table.
    json = {
        encode = function(t)
            W.encoded = copy(t)
            return 'json:' .. tostring(#W.serverFired + 1)
        end,
    },
}

function W.runThreads(ms)
    local stop = W.clock + (ms or 0)
    while true do
        local due
        for _, t in ipairs(W.threads) do
            if coroutine.status(t.co) ~= 'dead' and (due == nil or t.wake < due) then due = t.wake end
        end
        if due == nil or due > stop then break end
        if due > W.clock then W.clock = due end
        for _, t in ipairs(W.threads) do
            if coroutine.status(t.co) ~= 'dead' and t.wake <= W.clock then
                local ok, waited = coroutine.resume(t.co)
                if not ok then error(waited, 0) end
                t.wake = W.clock + math.max(tonumber(waited) or 0, 1)
            end
        end
    end
    if stop > W.clock then W.clock = stop end
end

function W.install()
    for k, v in pairs(engine) do rawset(_G, k, v) end
    if W.server == false then
        for k, v in pairs(clientEngine) do rawset(_G, k, v) end
    end
end

-- ===========================================================================
--  The store
-- ===========================================================================

W.items = { water = {}, bread = {}, phone = { unique = true }, burger = {} }

W.jobs = {
    unemployed = { label = 'Civilian', grades = { [0] = 'freelancer' } },
    police = { label = 'Police', grades = { [0] = 'recruit', [1] = 'officer', [4] = 'boss' } },
}

local function newPlayer(src, account, first, last, loaded, cash)
    return {
        src = src, account = account, id = ('CID%03d'):format(src),
        phone = ('555%07d'):format(src),
        first = first, last = last, loaded = loaded,
        money = { cash = cash, bank = 5000, dirty = 0, crypto = 0 },
        items = {}, cap = 50,
        job = { name = 'unemployed', grade = 0 },
        -- The gang QBCore and Qbox keep beside the job, and the metadata flags
        -- the ambulance and police resources set.
        gang = { name = 'none', label = 'No Gang Affiliation', grade = 0, gradeName = 'none', isboss = false },
        meta = { isdead = false, inlaststand = false, ishandcuffed = false },
    }
end

local function resetStore()
    W.players = {
        [1] = newPlayer(1, 'alice_acct', 'Alice', 'Doe', true, 1000),
        [2] = newPlayer(2, 'bob_acct', 'Bob', 'Roe', false, 1000),
        [3] = newPlayer(3, 'carol_acct', 'Carol', 'Poe', true, 0),
    }
    -- A character the framework stored without a number: the bridge answers
    -- no phone rather than an empty string.
    W.players[3].phone = nil
    W.players[1].gang = { name = 'ballas', label = 'Ballas', grade = 2, gradeName = 'Shot Caller', isboss = false }
    W.players[3].meta = { isdead = true, inlaststand = false, ishandcuffed = true }
    -- Usable items by name: 'ok' records the call, 'raise' raises inside the
    -- callback. `used` is what the callbacks saw.
    W.qbSlots = {}
    W.outfits = {}
    W.skinLegacy = nil
    W.skinEditRefused = nil
    W.outfitRefused = nil
    W.usable = { bread = 'ok', burger = 'raise' }
    W.used = {}
    W.usableAsFunction = false
    W.staleIndex = nil
    -- The key a qb-core entry keeps its function under, and an entry that is
    -- gone by the second lookup (a callback unregistered between the checks).
    W.usableKey = nil
    W.usableVanishes = false
    W.canUseCalls = {}
    W.doors = {
        [1] = { id = 1, name = 'mrpd_front', state = 1 },
        [2] = { id = 2, name = 'mrpd_back', state = 0 },
    }
    W.client = { loaded = true, src = 1 }
    W.targets = { zones = {}, entities = {} }
    -- Owned vehicles by plate, as the framework tables hold them; id is Qbox's
    -- player_vehicles.id.
    W.vehicles = { ABC123 = { id = 7, owner = 1 } }
    W.skinEdits = {}
    -- The local ped (client): props by id { drawable, texture }, a prop that is
    -- off missing; components by id.
    W.ped = 101
    W.look = {
        props = { [0] = { 12, 2 } },
        comps = { [1] = { 0, 0 }, [3] = { 15, 0 }, [4] = { 21, 1 }, [6] = { 34, 0 },
            [7] = { 0, 0 }, [11] = { 55, 3 } },
    }
    -- The skin qb-clothing and skinchanger keep beside the clothes.
    W.skinchanger = { sex = 0, face = 21, hair_1 = 4, helmet_1 = -1, helmet_2 = 0, torso_1 = 1, torso_2 = 0 }
    -- esx_billing's `billing` rows, and how its callbacks answer: 'answer'
    -- after `delay` ms, 'silent' never, 'raise' in the trigger itself, 'twice'
    -- calls the cb two times.
    W.billing = {
        bills = {
            { id = 3, identifier = 'CID001', label = 'Speeding', amount = 250 },
            { id = 7, identifier = 'CID001', label = 'Pillbox Medical', amount = 1200 },
            { id = 5, identifier = 'CID002', label = 'Not yours', amount = 10 },
        },
        mode = 'answer', delay = 120, calls = {},
        rows = nil, hasNext = nil, payAnswer = nil,
    }
end

local function loadedPlayer(src)
    local p = W.players[src]
    if p and p.loaded then return p end
    return nil
end
W.loadedPlayer = loadedPlayer

-- The framework's own index by character id, as qbx_core, qb-core and ESX keep
-- it: only loaded players. `W.staleIndex` maps a character id to a server id
-- the index still holds after a character switch.
local function byCharId(id)
    W.calls[#W.calls + 1] = { key = 'byCharId', args = table.pack(id) }
    if W.staleIndex and W.staleIndex[id] then return W.staleIndex[id] end
    for src, p in pairs(W.players) do
        if p.loaded and p.id == id then return src end
    end
    return nil
end

function W.count(src, item)
    local p = W.players[src]
    return p and p.items[item] or 0
end

local function total(p)
    local n = 0
    for _, c in pairs(p.items) do n = n + c end
    return n
end

function W.fits(src, n)
    local p = W.players[src]
    return p ~= nil and total(p) + n <= p.cap
end

-- `fault.addLands` / `fault.removeTakes` cap how many units a write really
-- moves, whatever the resource answers. That is the ox non-stackable partial
-- add, and the inventory that answers true and did nothing.
local function give(src, item, n)
    local p = W.players[src]
    local land = n
    if W.fault.addLands ~= nil then land = math.min(n, W.fault.addLands) end
    p.items[item] = (p.items[item] or 0) + land
    return land
end

local function take(src, item, n)
    local p = W.players[src]
    local gone = n
    if W.fault.removeTakes ~= nil then gone = math.min(n, W.fault.removeTakes) end
    p.items[item] = (p.items[item] or 0) - gone
    if p.items[item] == 0 then p.items[item] = nil end
    return gone
end

local function dot(first, what)
    if type(first) == 'table' then
        error(('%s is a dot call: got a table where a name was expected (colon call?)'):format(what), 3)
    end
end

-- `fault.moneySilent` is a framework that answers true and moves nothing;
-- `fault.moneySkew` moves that many units more than asked. Both answer true,
-- so only a balance read-back can tell.
local function moved(amount)
    if W.fault.moneySilent then return 0 end
    return amount + (W.fault.moneySkew or 0)
end

local function addMoney(p, acc, amount)
    if W.fault.moneyAddFails then return false end
    p.money[acc] = p.money[acc] + moved(amount)
    return true
end

local function removeMoney(p, acc, amount)
    if p.money[acc] < amount then return false end
    p.money[acc] = p.money[acc] - moved(amount)
    return true
end

local function setJob(p, name, grade)
    local job = W.jobs[name]
    if not job or job.grades[grade] == nil then return false end
    p.job = { name = name, grade = grade }
    return true
end

-- ===========================================================================
--  ESX (es_extended)
-- ===========================================================================

-- A usable-item callback, the way the frameworks keep one: it records what it
-- was called with.
local function usableCallback(name)
    local mode = W.usable[name]
    if not mode then return nil end
    return function(src, item, ...)
        if mode == 'raise' then error('usable callback raised on purpose') end
        W.used[#W.used + 1] = { src = src, item = item, extra = table.pack(...) }
    end
end

-- The registry lookup behind CanUseItem; with `vanishes` the entry is gone from
-- the second lookup of an item on.
local function usableLookup(item)
    local cb = usableCallback(item)
    if cb and W.usableVanishes then
        W.canUseCalls[item] = (W.canUseCalls[item] or 0) + 1
        if W.canUseCalls[item] > 1 then return nil end
    end
    return cb
end

local ESX_ACCOUNTS = { money = 'cash', bank = 'bank', black_money = 'dirty' }

local function esxJob(p)
    local job = W.jobs[p.job.name]
    local gradeName = job.grades[p.job.grade]
    return {
        name = p.job.name, label = job.label, grade = p.job.grade,
        grade_name = gradeName, grade_label = gradeName, grade_salary = 100,
    }
end

local function xPlayer(src)
    local p = loadedPlayer(src)
    if not p then return nil end
    local x = { source = src, identifier = p.id, accounts = copy(p.money) }
    function x.getName() return p.first .. ' ' .. p.last end
    function x.getJob() return esxJob(p) end
    function x.getAccount(name)
        dot(name, 'xPlayer.getAccount')
        local acc = ESX_ACCOUNTS[name]
        if not acc then return nil end
        return { name = name, money = p.money[acc], label = name }
    end
    function x.addAccountMoney(name, amount, _reason)
        dot(name, 'xPlayer.addAccountMoney')
        local acc = ESX_ACCOUNTS[name]
        if not acc then error('unknown account ' .. tostring(name)) end
        return addMoney(p, acc, amount)
    end
    function x.removeAccountMoney(name, amount, _reason)
        dot(name, 'xPlayer.removeAccountMoney')
        local acc = ESX_ACCOUNTS[name]
        if not acc then error('unknown account ' .. tostring(name)) end
        return removeMoney(p, acc, amount)
    end
    -- Returns nil on success and on failure (job.lua:43).
    function x.setJob(name, grade)
        dot(name, 'xPlayer.setJob')
        local last = esxJob(p)
        if setJob(p, name, tonumber(grade)) then
            W.fire('esx:setJob', nil, src, esxJob(p), last)
        end
    end
    function x.getInventoryItem(item)
        dot(item, 'xPlayer.getInventoryItem')
        if not W.items[item] then return nil end
        return { name = item, count = W.count(src, item), label = item }
    end
    function x.canCarryItem(item, n)
        dot(item, 'xPlayer.canCarryItem')
        return W.fits(src, n)
    end
    function x.addInventoryItem(item, n)
        dot(item, 'xPlayer.addInventoryItem')
        if not W.items[item] then return false end
        give(src, item, n)
        return true
    end
    function x.removeInventoryItem(item, n)
        dot(item, 'xPlayer.removeInventoryItem')
        if not W.items[item] then return false end
        take(src, item, n)
        return true
    end
    return x
end
W.xPlayer = xPlayer

local ESX = {
    GetPlayerFromId = xPlayer,
    -- esx_core 1.16.4 lookup.lua:101-103: the source, or nil.
    GetPlayerIdFromIdentifier = function(id) return byCharId(id) end,
    GetJobs = function()
        local out = {}
        for name, job in pairs(W.jobs) do
            local grades = {}
            for g, gname in pairs(job.grades) do grades[tostring(g)] = { grade = g, name = gname } end
            out[name] = { name = name, label = job.label, grades = grades }
        end
        return out
    end,
    GetItemLabel = function(item) return W.items[item] and item or nil end,
    -- esx_core server/functions.lua: { [item] = true } for every registered
    -- usable item; UseItem calls the callback in a pcall and answers nothing.
    GetUsableItems = function()
        local out = {}
        for name in pairs(W.usable) do out[name] = true end
        return out
    end,
    UseItem = function(src, item, ...)
        if not W.items[item] then return end
        local cb = usableCallback(item)
        if not cb then return end
        local ok, e = pcall(cb, src, item, ...)
        if not ok then print('esx: error when using item ' .. item .. ': ' .. tostring(e)) end
    end,
    IsPlayerLoaded = function() return W.client.loaded end,
    GetPlayerData = function()
        local p = loadedPlayer(W.client.src)
        if not p then return {} end
        return { identifier = p.id, name = p.account, job = esxJob(p) }
    end,
    -- es_extended 1.16.3 client/modules/callback.lua:10-12:
    -- `xLib.callback(eventName, false, callback, ...)`. The server answers on a
    -- Later tick (a net round trip), so the fake answers after
    -- `W.billing.delay` ms of fake uptime, from a thread. A callback no started
    -- resource registered never answers (esx_lib raises 'does not exist' inside
    -- its own reply handler, so the caller's cb is never called).
    TriggerServerCallback = function(name, cb, ...)
        local B = W.billing
        B.calls[#B.calls + 1] = { name = name, args = packCopy(...) }
        if B.mode == 'raise' then error('TriggerServerCallback raised on purpose', 2) end
        local answer = W.billingAnswer(name, ...)
        if not answer or B.mode == 'silent' or W.state.esx_billing ~= 'started' then return end
        CreateThread(function()
            Wait(B.delay)
            cb(table.unpack(answer, 1, answer.n))
            -- A second, different answer: the caller must keep the first.
            if B.mode == 'twice' then cb(false) end
        end)
    end,
}

W.ESX = ESX

-- esx_billing 1.16.3 server/main.lua, the two callbacks the bridge reads.
--   :329-358 getBills(afterId): `{}` for a bad cursor (not an integer
--     0..2147483647); else rows `{ amount, id, label }` of the caller's
--     identifier with `id > afterId`, ORDER BY id, page `Config.BillsPageSize`
--     (50), and `hasNext`.
--   :394-705 payBill(billId): `false` for an id that is not an integer
--     1..2147483647, an unknown bill, another's bill, or too little money;
--     `true` once paid (the bill row goes, the money moves).
-- `W.billing.rows` (with `W.billing.hasNext`) replaces the read's answer
-- verbatim, for rows the bridge must drop; `W.billing.payAnswer` replaces the
-- pay answer.
function W.billingAnswer(name, ...)
    local B = W.billing
    local p = loadedPlayer(W.client.src)
    if name == 'esx_billing:getBills' then
        if B.rows ~= nil then return table.pack(B.rows, B.hasNext) end
        local after = tonumber((...)) or 0
        if not p or after ~= after or after < 0 or after > 2147483647 or after % 1 ~= 0 then
            return table.pack({})
        end
        local mine = {}
        for _, b in ipairs(B.bills) do
            if b.identifier == p.id and b.id > after then
                mine[#mine + 1] = { amount = b.amount, id = b.id, label = b.label }
            end
        end
        table.sort(mine, function(a, b) return a.id < b.id end)
        local hasNext = #mine > 50
        while #mine > 50 do mine[#mine] = nil end
        return table.pack(mine, hasNext)
    elseif name == 'esx_billing:payBill' then
        if B.payAnswer ~= nil then return table.pack(B.payAnswer) end
        local id = tonumber((...))
        if not p or not id or id ~= id or id < 1 or id > 2147483647 or id % 1 ~= 0 then return table.pack(false) end
        for i, b in ipairs(B.bills) do
            if b.id == id then
                if b.identifier ~= p.id or p.money.bank < b.amount then return table.pack(false) end
                p.money.bank = p.money.bank - b.amount
                table.remove(B.bills, i)
                return table.pack(true)
            end
        end
        return table.pack(false)
    end
    return nil
end

W.declared.es_extended = {
    getSharedObject = function() return ESX end,
}

-- ===========================================================================
--  QBCore (qb-core) and Qbox (qbx_core)
-- ===========================================================================

local function qbJob(p)
    local job = W.jobs[p.job.name]
    return {
        name = p.job.name, label = job.label, onduty = true, isboss = p.job.grade == 4,
        grade = { level = p.job.grade, name = job.grades[p.job.grade], isboss = p.job.grade == 4 },
        payment = 75,
    }
end

-- QBCore keeps the pay on the grade, Qbox on the job.
local function qbcoreJob(p)
    local j = qbJob(p)
    j.grade.payment, j.payment = j.payment, nil
    return j
end

local function playerData(p, job)
    local g = p.gang
    return {
        source = p.src, citizenid = p.id, name = p.account,
        charinfo = { firstname = p.first, lastname = p.last, phone = p.phone },
        job = job(p), money = copy(p.money),
        gang = g and { name = g.name, label = g.label, isboss = g.isboss,
            grade = { name = g.gradeName, level = g.grade, isboss = g.gradeIsboss } } or nil,
        metadata = p.meta and copy(p.meta) or nil,
    }
end
W.qbPlayerData = function(src) return playerData(W.players[src], qbcoreJob) end

local QB_ACCOUNTS = { cash = true, bank = true, crypto = true }

local function qbPlayer(src)
    local p = loadedPlayer(src)
    if not p then return nil end
    return {
        PlayerData = playerData(p, qbcoreJob),
        Functions = {
            GetMoney = function(acc)
                dot(acc, 'Functions.GetMoney')
                if not QB_ACCOUNTS[acc] then return nil end
                return p.money[acc]
            end,
            AddMoney = function(acc, amount)
                dot(acc, 'Functions.AddMoney')
                if not QB_ACCOUNTS[acc] then return false end
                return addMoney(p, acc, amount)
            end,
            RemoveMoney = function(acc, amount)
                dot(acc, 'Functions.RemoveMoney')
                if not QB_ACCOUNTS[acc] then return false end
                return removeMoney(p, acc, amount)
            end,
            -- True for an unknown grade too (player.lua:66-122): it falls
            -- back to grade 0.
            SetJob = function(name, grade)
                dot(name, 'Functions.SetJob')
                if not W.jobs[name] then return false end
                grade = tonumber(grade)
                if W.jobs[name].grades[grade] == nil then grade = 0 end
                p.job = { name = name, grade = grade }
                W.fire('QBCore:Server:OnJobUpdate', nil, src, qbcoreJob(p))
                return true
            end,
        },
    }
end

local function qbShared()
    local jobs = {}
    for name, job in pairs(W.jobs) do
        local grades = {}
        for g, gname in pairs(job.grades) do grades[tostring(g)] = { name = gname } end
        jobs[name] = { label = job.label, grades = grades }
    end
    local items = {}
    for name in pairs(W.items) do items[name] = { name = name, label = name } end
    return { Jobs = jobs, Items = items }
end

W.declared['qb-core'] = {
    GetCoreObject = function()
        return {
            Shared = qbShared(),
            Functions = {
                -- qb-core server/functions.lua: the registered entry, { func,
                -- resource } (a bare function in older cores), or nil.
                CanUseItem = function(item)
                    local cb = usableLookup(item)
                    if not cb then return nil end
                    if W.usableAsFunction then return cb end
                    return { [W.usableKey or 'func'] = cb, resource = 'qb-inventory' }
                end,
                GetPlayerData = function()
                    local p = loadedPlayer(W.client.src)
                    if not p or not W.client.loaded then return {} end
                    return playerData(p, qbcoreJob)
                end,
                Notify = function(message, kind, length)
                    W.calls[#W.calls + 1] = { key = 'qb-core.Functions.Notify', args = table.pack(message, kind, length) }
                end,
            },
        }
    end,
    GetPlayer = qbPlayer,
    -- qb-core player.lua:679-681: the rebuilt interface, or nil.
    GetPlayerByCitizenId = function(cid)
        local src = byCharId(cid)
        return src and qbPlayer(src) or nil
    end,
}

W.declared.qbx_core = {
    GetPlayer = function(src)
        local p = loadedPlayer(src)
        if not p then return nil end
        return { PlayerData = playerData(p, qbJob) }
    end,
    -- qbx_core functions.lua:98-110: the Player, or nil.
    GetPlayerByCitizenId = function(cid)
        local src = byCharId(cid)
        local p = src and W.players[src]
        if not p then return nil end
        return { PlayerData = playerData(p, qbJob) }
    end,
    GetMoney = function(src, acc)
        local p = loadedPlayer(src)
        if not p or not QB_ACCOUNTS[acc] then return false end
        return p.money[acc]
    end,
    AddMoney = function(src, acc, amount)
        local p = loadedPlayer(src)
        if not p or not QB_ACCOUNTS[acc] then return false end
        return addMoney(p, acc, amount)
    end,
    RemoveMoney = function(src, acc, amount)
        local p = loadedPlayer(src)
        if not p or not QB_ACCOUNTS[acc] then return false end
        return removeMoney(p, acc, amount)
    end,
    -- Qbox grades are keyed by number.
    GetJobs = function()
        local out = {}
        for name, job in pairs(W.jobs) do
            local grades = {}
            for g, gname in pairs(job.grades) do grades[g] = { name = gname } end
            out[name] = { label = job.label, grades = grades }
        end
        return out
    end,
    SetJob = function(src, name, grade)
        local p = loadedPlayer(src)
        if not p then return false end
        if not setJob(p, name, grade) then return false end
        W.fire('QBCore:Server:OnJobUpdate', nil, src, qbJob(p))
        return true
    end,
    Notify = function() end,
    -- qbx_core server/functions.lua: QBX.UsableItems[item], a function.
    CanUseItem = function(item) return usableLookup(item) end,
    GetPlayerData = function()
        local p = loadedPlayer(W.client.src)
        if not p or not W.client.loaded then return nil end
        return playerData(p, qbJob)
    end,
}

-- ===========================================================================
--  cis_core
--
--  GiveMoney / RemoveMoney answer the status of cis_core's own pcall, so they
--  answer true for a refused write. `fault.cisRefuse` is that refusal.
-- ===========================================================================

local CisCore = {
    GetPlayer = function(src) return loadedPlayer(src) and { source = src } or nil end,
    NormalizedPlayer = function(src)
        local p = loadedPlayer(src)
        if not p then return nil end
        return {
            identifier = p.id, name = p.first .. ' ' .. p.last, job = esxJob(p),
            money = { cash = p.money.cash, bank = p.money.bank },
        }
    end,
    GiveMoney = function(src, amount, kind)
        local p = loadedPlayer(src)
        if p and not W.fault.cisRefuse and p.money[kind] then addMoney(p, kind, amount) end
        return true
    end,
    RemoveMoney = function(src, amount, kind)
        local p = loadedPlayer(src)
        if p and not W.fault.cisRefuse and p.money[kind] then removeMoney(p, kind, amount) end
        return true
    end,
    GetPlayerJob = function(src)
        local p = loadedPlayer(src)
        return p and esxJob(p) or nil
    end,
    SetPlayerJob = function(src, name, grade)
        local p = loadedPlayer(src)
        if p then setJob(p, name, grade) end
    end,
    Notify = function() end,
}

W.declared.cis_core = {
    CisCoreFramework = function() return CisCore end,
}

-- ===========================================================================
--  Inventories
-- ===========================================================================

W.declared.ox_inventory = {
    GetItemCount = function(src, item) return W.count(src, item) end,
    Items = function(name) return W.items[name] and { name = name } or nil end,
    CanCarryItem = function(src, item, n)
        if not W.items[item] then return nil end
        return W.fits(src, n)
    end,
    -- No weight check of its own beyond the fit, and a partial add answers
    -- true (modules/inventory/server.lua:1148-1264).
    -- Each add answers a slot of its own, so a test can see which slot a
    -- take-back named.
    AddItem = function(src, item, n)
        if not W.items[item] then return false, 'invalid_item' end
        if not W.fits(src, n) then return false, 'inventory_full' end
        give(src, item, n)
        W.oxSlot = (W.oxSlot or 0) + 1
        return true, { slot = W.oxSlot, name = item, count = n }
    end,
    RemoveItem = function(src, item, n, _metadata, _slot, _ignoreTotal)
        if W.count(src, item) < n then return false, 'not_enough_items' end
        take(src, item, n)
        return true
    end,
}

W.declared['qb-inventory'] = {
    GetItemCount = function(src, item)
        if not loadedPlayer(src) then return nil end
        return W.count(src, item)
    end,
    CanAddItem = function(src, item, n)
        if not W.items[item] then return false, 'item' end
        if not W.fits(src, n) then return false, 'weight' end
        return true
    end,
    AddItem = function(src, item, n, _slot, _info, _reason)
        if not W.items[item] or not W.fits(src, n) then return false end
        give(src, item, n)
        return true
    end,
    -- `W.qbSlots[src][item]` (opt-in) splits a stack over slots, as qb holds
    -- it: RemoveItem with no slot reads only the first matching slot and fails
    -- when that slot holds fewer than asked (functions.lua 825-850).
    RemoveItem = function(src, item, n, slot, _reason)
        local stacks = W.qbSlots[src] and W.qbSlots[src][item]
        if stacks then
            local at
            for i, st in ipairs(stacks) do
                if (slot == nil or slot == false) and i == 1 or st.slot == slot then at = i; break end
            end
            if not at or stacks[at].amount < n then return false end
            stacks[at].amount = stacks[at].amount - n
            if stacks[at].amount == 0 then table.remove(stacks, at) end
            take(src, item, n)
            return true
        end
        if W.count(src, item) < n then return false end
        take(src, item, n)
        return true
    end,
    GetItemsByName = function(src, item)
        if not loadedPlayer(src) then return nil end
        local stacks = W.qbSlots[src] and W.qbSlots[src][item]
        local out = {}
        if stacks then
            for i, st in ipairs(stacks) do out[i] = { name = item, slot = st.slot, amount = st.amount } end
        elseif W.count(src, item) > 0 then
            out[1] = { name = item, slot = 1, amount = W.count(src, item) }
        end
        return out
    end,
}

W.declared['qs-inventory'] = {
    GetItemTotalAmount = function(src, item) return W.count(src, item) end,
    CanCarryItem = function(src, item, n)
        if not W.items[item] then return false end
        return W.fits(src, n)
    end,
    AddItem = function(src, item, n)
        if not W.items[item] or not W.fits(src, n) then return false end
        give(src, item, n)
        return true
    end,
    -- Undocumented return: this one answers nothing at all.
    RemoveItem = function(src, item, n)
        if W.count(src, item) < n then return false end
        take(src, item, n)
    end,
}

W.declared['codem-inventory'] = {
    GetItemsTotalAmount = function(src, item) return W.count(src, item) end,
    AddItem = function(src, item, n)
        if not W.items[item] or not W.fits(src, n) then return false end
        give(src, item, n)
    end,
    RemoveItem = function(src, item, n)
        if W.count(src, item) < n then return false end
        take(src, item, n)
    end,
}

-- cis_inventory, Cisoko's own inventory: its server export surface. Every refusal is `false, reason` and
-- GetItemCount answers 0 and the reason. The engine is all-or-nothing, so a
-- write lands whole or not at all; `fault.addLands` / `fault.removeTakes`
-- still apply, to drive the count-delta paths an engine bug would take.
-- `fault.cisAdd` / `fault.cisRemove` / `fault.cisCarry` / `fault.cisCount`
-- are the refusal reasons the engine answers instead. Each add answers a slot
-- of its own (`W.cisSlot`), so a test can see which slot a take-back named.
W.declared.cis_inventory = {
    GetVersion = function() return '1.0.0' end,
    GetItem = function(name)
        if not W.items[name] then return false, 'unknown_item' end
        return { name = name, label = name, weight = 100, stack = not W.items[name].unique }
    end,
    GetItemCount = function(inv, item)
        if W.fault.cisCount then return 0, W.fault.cisCount end
        if not loadedPlayer(inv) then return 0, 'not_loaded' end
        if not W.items[item] then return 0, 'unknown_item' end
        return W.count(inv, item)
    end,
    CanCarryItem = function(inv, item, n)
        if W.fault.cisCarry then return false, W.fault.cisCarry end
        if not loadedPlayer(inv) then return false, 'not_loaded' end
        if not W.items[item] then return false, 'unknown_item' end
        if not W.fits(inv, n) then return false, 'too_heavy' end
        return true
    end,
    AddItem = function(inv, item, n, _metadata, _slot)
        if W.fault.cisAdd then return false, W.fault.cisAdd end
        if not loadedPlayer(inv) then return false, 'not_loaded' end
        if not W.items[item] then return false, 'unknown_item' end
        if not W.fits(inv, n) then return false, 'too_heavy' end
        local landed = give(inv, item, n)
        W.cisSlot = (W.cisSlot or 0) + 1
        return true, { { slot = W.cisSlot, count = landed } }
    end,
    RemoveItem = function(inv, item, n, _metadata, slot)
        if W.fault.cisRemove then return false, W.fault.cisRemove end
        if not loadedPlayer(inv) then return false, 'not_loaded' end
        if W.count(inv, item) < n then return false, 'insufficient_items' end
        local gone = take(inv, item, n)
        return true, { { slot = slot or 1, count = gone } }
    end,
}

-- ===========================================================================
--  Doors
-- ===========================================================================

W.declared.ox_doorlock = {
    getDoor = function(id)
        local d = W.doors[id]
        if not d then return false end
        return d
    end,
    getDoorFromName = function(name)
        for _, d in pairs(W.doors) do
            if d.name == name then return d end
        end
        return nil
    end,
    setDoorState = function(id, state)
        local d = W.doors[id]
        if not d then return false end
        d.state = state
        W.fire('ox_doorlock:stateChanged', nil, nil, id, state == 1, nil)
        return true
    end,
}

-- ===========================================================================
--  Targets (client)
-- ===========================================================================

local zoneSeq = 0

W.declared.ox_target = {
    addBoxZone = function(spec)
        zoneSeq = zoneSeq + 1
        W.targets.zones[zoneSeq] = spec
        return zoneSeq
    end,
    addSphereZone = function(spec)
        zoneSeq = zoneSeq + 1
        W.targets.zones[zoneSeq] = spec
        return zoneSeq
    end,
    removeZone = function(id) W.targets.zones[id] = nil end,
    addLocalEntity = function(entity, options) W.targets.entities[entity] = options end,
    removeLocalEntity = function(entity) W.targets.entities[entity] = nil end,
}

W.declared['qb-target'] = {
    AddBoxZone = function(name, coords, length, width, opts, options)
        W.targets.zones[name] = { kind = 'box', coords = coords, length = length, width = width,
            opts = opts, options = options }
    end,
    AddCircleZone = function(name, coords, radius, opts, options)
        W.targets.zones[name] = { kind = 'sphere', coords = coords, radius = radius,
            opts = opts, options = options }
    end,
    RemoveZone = function(name) W.targets.zones[name] = nil end,
    AddTargetEntity = function(entity, options) W.targets.entities[entity] = options end,
    RemoveTargetEntity = function(entity) W.targets.entities[entity] = nil end,
}

-- ===========================================================================
--  Vehicles and appearance
-- ===========================================================================

W.declared.qbx_vehicles = {
    GetVehicleIdByPlate = function(plate)
        local v = W.vehicles[plate]
        return v and v.id or nil
    end,
}

-- oxmysql scalar(query, params, cb, invoker, awaited): the first column of the
-- first row, or nil. The fake knows the two owned-vehicle lookups and
-- qb-clothing's playerskins row, `W.skins[citizenid]` (a json token).
-- update(...) answers the rows changed; it knows the playerskins row.
-- `W.sqlError` fails the scalar the way oxmysql does for an awaited call:
-- cb(nil, message).
W.declared.oxmysql = {
    scalar = function(query, params, cb, invoker, awaited)
        W.sql[#W.sql + 1] = { query = query, params = params, invoker = invoker, awaited = awaited }
        if W.sqlError then return cb(nil, W.sqlError) end
        local value
        if query:find('owned_vehicles', 1, true) or query:find('player_vehicles', 1, true) then
            value = W.vehicles[params[1]] and params[1] or nil
        elseif query:find('playerskins', 1, true) then
            value = W.skins[params[1]]
        end
        cb(value)
    end,
    update = function(query, params, cb, invoker, awaited)
        W.sql[#W.sql + 1] = { query = query, params = params, invoker = invoker, awaited = awaited }
        local changed = 0
        if query:find('playerskins', 1, true) and W.skins[params[2]] then
            W.skins[params[2]] = params[1]
            changed = 1
        end
        cb(changed)
    end,
}

-- esx_skin 1.16.3 (esx_core main): SaveOutfit takes only the outfit fields
-- and answers through its callback. `W.skinLegacy` drops it, as an esx_skin
-- older than 1.16 has it not; `W.skinEditRefused` / `W.outfitRefused` refuse.
W.declared.esx_skin = setmetatable({
    BeginSkinEdit = function(src)
        if W.skinEditRefused then return false end
        W.skinEdits[src] = true
        return true
    end,
}, { __index = function(_, k)
    if k == 'SaveOutfit' and not W.skinLegacy then
        return function(src, clothes, cb)
            if W.outfitRefused then cb(false); return false end
            W.outfits[src] = clothes
            cb(true)
            return true
        end
    end
end })

W.declared['illenium-appearance'] = {
    getPedAppearance = function(ped)
        return { model = 'mp_m_freemode_01', ped = ped, props = copy(W.look.props), components = copy(W.look.comps) }
    end,
}

W.declared.skinchanger = {
    GetSkin = function() return copy(W.skinchanger) end,
}

-- ===========================================================================
--  Worlds
-- ===========================================================================

W.RESOURCE = {
    esx = 'es_extended', qbcore = 'qb-core', qbox = 'qbx_core', cis_core = 'cis_core',
    ox = 'ox_inventory', qb = 'qb-inventory', qs = 'qs-inventory', codem = 'codem-inventory',
    cis = 'cis_inventory',
}

-- A fresh store and engine with these resources started.
function W.reset(started)
    resetEngine()
    resetStore()
    for _, r in ipairs(started or {}) do W.state[W.RESOURCE[r] or r] = 'started' end
    -- A new world holds new jobs and items. qb-core says so with this event
    -- after every runtime change (server/exports.lua), so a cache of
    -- QBCore.Shared starts over here as it would there.
    W.fire('QBCore:Server:UpdateObject', nil)
end

W.reset()

return W
