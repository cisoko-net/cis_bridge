-- Client-side conformance for the v1 client API: player data, notify, targets.
--
-- A target resource can be started on the server and still be broken on a
-- client. A zone the client cannot create looks like a door that does not
-- respond, which is easy to mistake for a permission problem on the server.
-- So the client checks the same contract and sends its results back.
--
-- Nothing is saved. Zones are created and removed under names that start with
-- cis_bridge_client_conformance, and the one ped this spawns is deleted before
-- the run returns.
--
-- It runs only on request, not when a player joins, so a normal session spends
-- nothing on it:
--
--      cis_bridge test          -- the server asks every connected client
--      cis_bridge_client        -- one client, from its own F8 console

local results = {}

local function probeName(suffix)
    return ('cis_bridge_client_conformance_%s_%d'):format(
        suffix or 'zone', math.random(10000, 99999))
end

local function record(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
    print(('  [client] %-46s %s%s'):format(
        name, ok and 'PASS' or 'FAIL', (not ok and detail) and (' -- ' .. tostring(detail)) or ''))
end

local function skip(name, detail)
    results[#results + 1] = { name = name, ok = true, skipped = true, detail = detail }
    print(('  [client] %-46s %s -- %s'):format(name, 'SKIP', tostring(detail)))
end

-- Spawn a vanilla ped for the entity path, and delete it before returning.
--
-- A real ped, because both providers accept an entity that does not exist
-- without an error: ox_target logs a warning, qb-target registers the handle.
-- A test without a real entity would pass on both and prove nothing.
--
-- The model is requested once and polled every 50 ms. The request stays queued
-- after the first call, so asking again every frame only adds native calls.
-- A model that never loads costs MODEL_TIMEOUT_MS and is reported.
local MODEL_TIMEOUT_MS = 5000
local MODEL_POLL_MS = 50

local function withPed(fn)
    local hash = GetHashKey('a_m_m_business_01')
    RequestModel(hash)
    local deadline = GetGameTimer() + MODEL_TIMEOUT_MS
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do
        Wait(MODEL_POLL_MS)
    end
    if not HasModelLoaded(hash) then
        -- Nothing to release: a model that did not load holds no memory, and
        -- the streamer completes or drops the queued request itself.
        return nil, ('a_m_m_business_01 did not load within %dms'):format(MODEL_TIMEOUT_MS)
    end
    local ped = CreatePed(0, hash, 0.0, 0.0, 72.0, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then
        return nil, 'the ped could not be created'
    end
    SetEntityAsMissionEntity(ped, true, true)
    local ok, err = pcall(fn, ped)
    -- Delete the ped even when fn raised. A ped left in the world stays
    -- there; nothing removes it later.
    if DoesEntityExist(ped) then
        DeleteEntity(ped)
    end
    return ok, err
end

local function run()
    results = {}
    local V = CisBridgeClientV1
    if type(V) ~= 'table' then
        record('the v1 client API is loaded', false, 'client/v1.lua did not load; read F8')
        return results
    end
    print('')
    print('cis_bridge client conformance -- v1')
    print('')

    -- Player. The two reads have to agree: a product gates its UI on IsLoaded
    -- and then reads GetPlayerData, and a disagreement is a nil index.
    local data, why = V.getPlayerData()
    record('IsLoaded agrees with GetPlayerData', V.isLoaded() == (type(data) == 'table'),
        ('GetPlayerData answered %s, %s'):format(tostring(data), tostring(why)))

    -- Notify. Only the refusal: a real notification would show on the screen of
    -- every player the server asked.
    local n, nwhy = V.notify('')
    record('Notify refuses an empty message', n == false and nwhy == 'bad_message', tostring(nwhy))

    -- Refusals come before the target check, because they never reach a target.
    local bad, badWhy = V.addTargetZone({ name = probeName('bad'), kind = 'hexagon',
        coords = vec3(0.0, 0.0, 0.0), size = 1.0, options = { { label = 'x', onSelect = function() end } } })
    record('refuses an unknown zone kind', bad == false and badWhy == 'bad_target', tostring(badWhy))
    local unknown, unknownWhy = V.removeTarget(probeName('never_created'))
    record('removing an unknown name is refused, not fatal',
        unknown == false and unknownWhy == 'unknown_target', tostring(unknownWhy))

    local options = { { label = 'cis_bridge conformance', onSelect = function() end } }

    -- Sphere. The simplest create, and the one that has broken.
    local a = probeName('sphere')
    local ok1, why1 = V.addTargetZone({ name = a, kind = 'sphere', coords = vec3(0.0, 0.0, 0.0),
        size = 1.0, options = options })
    if ok1 == false and why1 == 'no_target' then
        skip('creates a sphere zone', 'no ox_target or qb-target is started on this client')
        print('')
        return results
    end
    record('creates a sphere zone', ok1 == true, tostring(why1))
    local again, againWhy = V.addTargetZone({ name = a, kind = 'sphere', coords = vec3(0.0, 0.0, 0.0),
        size = 1.0, options = options })
    record('refuses a second target under the same name', again == false and againWhy == 'exists',
        tostring(againWhy))
    local removed, removeWhy = V.removeTarget(a)
    record('removes it', removed == true, tostring(removeWhy))
    -- Both providers' removal calls return nothing, so the bridge keeps its
    -- own record. A second removal must find no record.
    local twice, twiceWhy = V.removeTarget(a)
    record('forgets a removed zone', twice == false and twiceWhy == 'unknown_target', tostring(twiceWhy))

    -- Box. qb-target takes three numbers and derives minZ and maxZ from the
    -- centre; ox_target takes a vector3. The adapter makes one shape fit both.
    local b = probeName('box')
    local ok2, why2 = V.addTargetZone({ name = b, kind = 'box', coords = vec3(0.0, 0.0, 0.0),
        size = vector3(1.0, 1.0, 1.0), options = options })
    record('creates a box zone', ok2 == true, tostring(why2))
    if ok2 == true then V.removeTarget(b) end

    -- The entity path, on a real ped.
    local pedOk, pedErr = withPed(function(ped)
        local name = probeName('entity')
        local created, cwhy = V.addTargetEntity({ name = name, entity = ped, options = options })
        record('creates a target on a real entity', created == true, tostring(cwhy))
        local gone, goneWhy = V.removeTarget(name)
        record('removes an entity target', gone == true, tostring(goneWhy))
    end)
    if not pedOk then
        record('creates a target on a real entity', false,
            type(pedErr) == 'string' and pedErr or 'the entity path raised')
    end

    print('')
    return results
end

-- The server asks the client for its results, because a support thread needs
-- both halves and only the server can be asked from a console.
RegisterNetEvent('cis_bridge:client:conformance', function()
    -- From the server or not at all: a local TriggerEvent arrives with
    -- source == ''.
    if source == nil or source == '' then return end
    -- Each row carries `skipped`, so the server can count the checks that
    -- did not run apart from the ones that passed.
    local payload = run()
    TriggerServerEvent('cis_bridge:server:conformanceResults', payload)
end)

-- Also reachable from the client console, so a developer testing a target adapter
-- does not have to be a server admin to run it.
--
-- Ten-second cooldown: any player can run this command, and each run creates
-- a ped and several target zones on their client.
local lastRun = 0
RegisterCommand('cis_bridge_client', function()
    local now = GetGameTimer()
    if now - lastRun < 10000 then
        print('cis_bridge: that ran a moment ago. It creates and removes a target and a '
            .. 'ped each time, so it is not free.')
        return
    end
    lastRun = now
    run()
end, false)
