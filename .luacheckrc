-- luacheck configuration. `npm run lint` runs luacheck with it.
--
-- luacheck is not an npm dependency and `npm ci` does not install it: CI
-- installs a pinned release. `npm run lint` says so plainly when the tool is
-- absent instead of exiting 0 and leaving a reader to assume the code was
-- checked.
--
-- It catches what a syntax check cannot: an unused local, a shadowed name, a
-- global assigned in one file and read in another by accident, and a variable
-- written on one line and read on the next from a branch that never runs. The
-- last one is the class that matters here -- this resource makes decisions at
-- registration time and reads them later, so an assignment that silently fails
-- to happen is a capability that answers differently than its source says.

std = "lua54"

-- Everything the FiveM runtime provides that this resource calls. Written by
-- hand: the resource calls a couple of dozen natives, so a generator would cost
-- more than the list.
--
-- `require` is std; `exports`, `json`, `promise` and the vector constructors
-- are CfxLua, as is everything else here.
read_globals = {
    -- scheduler and resource lifecycle
    "CreateThread", "Wait",
    "GetGameTimer", "Citizen", "promise",
    "GetResourceState", "GetResourceMetadata", "GetCurrentResourceName",
    "RegisterCommand", "exports", "json", "vector3", "vec3",
    -- events
    "RegisterNetEvent", "TriggerClientEvent", "TriggerServerEvent",
    "AddEventHandler", "TriggerEvent", "GetInvokingResource", "source",
    -- realm and configuration, read by the v1 detection
    "IsDuplicityVersion", "GetConvar",
    -- players
    "GetPlayers", "GetPlayerName", "PlayerPedId",
    -- entities, for the client conformance probe
    "GetHashKey", "RequestModel", "HasModelLoaded", "CreatePed", "DeleteEntity",
    "DoesEntityExist", "SetEntityAsMissionEntity", "SetModelAsNoLongerNeeded",
    -- ped components and props, read and applied by the appearance adapters'
    -- client halves
    "GetPedDrawableVariation", "GetPedTextureVariation", "GetPedHairColor", "SetPedComponentVariation",
    "GetPedPropIndex", "GetPedPropTextureIndex", "SetPedPropIndex", "ClearPedProp",
}

-- Not ours to lint: the vendored test interpreter, the generated LuaCATS
-- stubs (signatures with no bodies), and the validator's deliberately broken
-- api.lua fixtures, which read a global the validator injects.
exclude_files = { "node_modules/", "types/", "test/api/broken/" }

-- The manifest is a list of directive calls, not code.
files["fxmanifest.lua"] = {
    read_globals = {
        "fx_version", "game", "name", "description", "author", "version", "lua54",
        "dependencies", "shared_scripts", "client_scripts", "server_scripts", "files",
    },
}

-- What this repository defines. Each is a global on purpose, because that is
-- how one resource file reaches another: `CisBridgeConformance` and
-- `CisBridgeReport` are read by a command registered in a different file.
--
-- Declared writable rather than read-only so that luacheck does not resolve a
-- name appearing in both lists to read-only and then report the assignment that
-- defines it. Only these are ours; everything else a file touches has to
-- be a local or an error.
globals = {
    "CisBridgeConformance",
    "CisBridgeReport",
    -- The v1 API (docs/V1.md): adapter registries filled one file at a time,
    -- the two realm halves, and the facade init.lua gives a product.
    "CisBridgeFrameworks", "CisBridgeInventories", "CisBridgeDoors", "CisBridgeTargets",
    "CisBridgeBilling", "CisBridgeAppearances",
    "CisBridgeV1", "CisBridgeClientV1", "CisBridge",
    -- Published by one server file for the next one in load order.
    "CisBridgeLibShim", "CisBridgeRateLimit",
}

-- The test suites stand the whole engine up themselves, so every FiveM global is
-- assigned rather than read. That is what the suites are for, and reading it as
-- a lint failure would mean disabling the file instead.
files["test/"] = {
    -- Every stub the suites define. Listed rather than wildcarded because a
    -- wildcard here would silence a typo in a stub name -- the stub would not
    -- match, the code would call nil, and the suite would raise.
    globals = {
        "exports", "CreateThread", "GetResourceState", "GetCurrentResourceName",
        "GetResourceMetadata", "GetGameTimer", "Wait",
        "__declared", "__caps", "__suite_failed",
        -- The v1 suites swap adapter halves and the player-name native to
        -- drive one branch at a time.
        "CisBridgeFrameworks", "CisBridgeTargets", "GetPlayerName",
    },
    -- test/lib/v1world.lua installs its engine with rawset, which luacheck does
    -- not see, so the v1 suites need only the names they read.
    read_globals = {
        "CisBridgeV1",
    },
    -- The suites are straight-line assertion scripts: one `ok, why` pair is
    -- reassigned and re-declared per block, a step's result is sometimes
    -- captured only to show the call returned, and an assertion's message is
    -- a sentence. Undefined and accidental globals stay errors here.
    ignore = { "211", "212", "213", "311", "314", "411", "421", "431" },
    max_line_length = false,
}

-- luacheck's default is 120. The shipped Lua holds to it (the longest line is
-- 118), and a real limit is worth having on code.
max_line_length = 120

-- api.lua is exempt, and the reason is that it is data: one table of prose
-- describing every export, where a `use` sentence that explains a decision is
-- allowed to be a sentence. Wrapping those strings to fit a number would either
-- truncate the explanation or make it unreadable, and a lint rule that forces
-- either is not buying anything.
--
-- It is not loaded at runtime and `npm run test:api` validates it on its own
-- terms -- against the surface the code actually registers.
files["api.lua"] = { max_line_length = false }
