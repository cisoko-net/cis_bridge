-- The `lib.*` shim, exported.
--
-- Why an export and not a global `lib`
--
-- **Each FiveM resource has its own Lua state,** so a global written here is
-- not visible elsewhere: it is a different variable from the same name in the
-- resource that reads it. So a shim that "installs lib"
-- installs it for itself and nobody else -- which looks like a working drop-in
-- on the machine it was built on and silently does nothing on a customer's.
--
-- The honest shape is an export, and a consumer takes it with one line:
--
--     local lib = exports['cis_bridge']:GetLibShim()
--
-- One line, and not nothing -- and worth more than a silent injection, because
-- a line says the dependency is there. Somebody who removes cis_bridge finds out
-- from their own source rather than from a support ticket.
--
-- Server side, and that is not an arbitrary choice: a callback shim a consumer
-- wants on the client reaches for cis_libs' own `Cis.*` directly, which is what
-- the client realm is for. Declaring these as shared would also make them invisible to the api
-- validator, which scans `server_scripts` and `client_scripts` and so cannot
-- see an export declared in a shared script at all.

-- Published by shared/lib/shim.lua, listed before this file in the manifest.
-- Not a `require`: FiveM has no loader for a resource's own files, and the
-- one cis_libs/init.lua supplied is no longer loaded.
local Shim = CisBridgeLibShim

-- Every engine call below is a colon call: `exports['cis_libs']` is an exports
-- table and `exports['cis_libs']:Name(...)` passes it as self. The fake in
-- test/shim.lua is shaped the same way, so losing that argument fails in a unit
-- suite instead of on a server.
local function engine()
    local e = {}
    for _, name in ipairs({
        'RegisterCallback', 'TryAwaitCallback', 'CallCallback',
    }) do
        e[name] = function(_, ...)
            return exports['cis_libs'][name](exports['cis_libs'], ...)
        end
    end
    return e
end

local lib

exports('GetLibShim', function()
    if lib == nil then
        lib = Shim.build(engine())
    end
    return lib
end)

-- The database proxy forwarded to cis_libs' Db* exports, which answer only
-- when a resource registers the `database` capability, and none Cisoko ships
-- does. It answers false and a reason, so a caller that branches on it does
-- not take the proxy for a working database.
local NO_DB_PROXY = 'GetDbProxy is retired: use the oxmysql API (MySQL.query.await and the rest), '
    .. 'served by oxmysql or cis_database'

exports('GetDbProxy', function()
    return false, NO_DB_PROXY
end)
