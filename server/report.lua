-- The boot report.
--
-- Why this exists
--
-- Most support threads open with "is this installed, and what is it doing?".
-- The report answers that without a ticket. Each line below is written to be
-- the whole of a support conversation:
--
--   "framework MISSING"   -> start es_extended, qb-core, qbx_core or cis_core
--                            before cis_bridge
--   "inventory MISSING"   -> start the inventory before cis_bridge, or name it
--                            with the cis_bridge:inventory convar
--
-- A report that stops at "not detected" has answered none of that. A report
-- that states the cause and the next step ends the conversation.
--
-- What it reports
--
-- What the v1 API (server/v1.lua) detected: one framework, one inventory, one
-- door resource. Targets are a client concern -- ox_target and qb-target are
-- picked on each client -- so they are named here only as a pointer to the
-- client half of `cis_bridge test`.
--
-- What it never prints
--
-- No webhook URLs, no credentials, no player identifiers, no config values.
-- It prints the names of the third-party resources present, which is the
-- operator's own server.cfg and is already in their console, and nothing else.

CisBridgeReport = {}

local OK = 'OK      '
local MISSING = 'MISSING '
local NONE = 'NONE    '

-- One row per kind. `required` decides between MISSING, which is a broken
-- install, and none, which is a server that simply has no door resource.
local KINDS = {
    {
        key = 'framework', required = true,
        fix = 'start es_extended, qb-core, qbx_core or cis_core before cis_bridge, '
            .. 'or name it with `setr cis_bridge:framework <esx|qbcore|qbox|cis_core>`',
    },
    {
        key = 'inventory', required = true,
        fix = 'start cis_inventory, ox_inventory, qs-inventory, codem-inventory or qb-inventory before cis_bridge, '
            .. 'or name it with `setr cis_bridge:inventory <name>`',
    },
    {
        key = 'doors', required = false,
        fix = 'only needed by products that lock doors: start ox_doorlock or qb-doorlock',
    },
}

local function summary()
    local V = CisBridgeV1
    if type(V) ~= 'table' or type(V.summary) ~= 'function' then return nil end
    local ok, s = pcall(V.summary)
    if not ok or type(s) ~= 'table' then return nil end
    return s
end

--- One row per kind, in a fixed order.
local function lines()
    local s = summary() or {}
    local out = {}
    for _, kind in ipairs(KINDS) do
        local name = s[kind.key]
        local row = { kind = kind.key, target = name or '-' }
        local wrong = type(s.config) == 'table' and s.config[kind.key] or nil
        -- How the slot was picked: auto-detected, or forced by the server's convars.
        local why = type(s.why) == 'table' and s.why[kind.key] or nil
        if name then
            row.label, row.detail = OK, (type(why) == 'string' and why ~= 'auto') and why or 'detected'
        elseif type(wrong) == 'string' then
            -- The convar is the cause, so its own line is the fix.
            row.label, row.detail, row.fix = kind.required and MISSING or NONE,
                'convar names no usable adapter', wrong
        elseif kind.required then
            row.label, row.detail, row.fix = MISSING, 'nothing answered', kind.fix
        else
            row.label, row.detail, row.fix = NONE, 'not on this server', kind.fix
        end
        out[#out + 1] = row
    end
    return out, s
end

--- Render the report. The headline is one sentence, so a pasted console line
--- still makes sense on its own.
function CisBridgeReport.render()
    local rows, s = lines()
    print('')
    print('================================ cis_bridge ================================')
    print(('cis_bridge %s -- v1 API %s, what it detected on this server')
        :format(tostring(GetResourceMetadata(GetCurrentResourceName(), 'version', 0)), tostring(s.api or '?')))
    print('')
    print('  state    kind            resource')
    print('  -------  --------------  ---------------------------------------------')
    local broken = 0
    for _, row in ipairs(rows) do
        broken = broken + (row.label == MISSING and 1 or 0)
        print(('  %s  %-14s  %-16s %s'):format(row.label, row.kind, row.target, row.detail))
    end
    print('  (targets are picked on each client: the client half of `cis_bridge test` reports them)')
    print('')

    if s.api == nil then
        print('  The v1 API did not load. The boot log above has the error.')
    elseif broken == 0 then
        print('  Products that use cis_bridge can run on this server.')
    else
        print(('  %d required resource(s) missing: products that use cis_bridge will refuse.'):format(broken))
    end
    print('')

    local fixes = {}
    for _, row in ipairs(rows) do
        if row.fix then fixes[#fixes + 1] = row end
    end
    if #fixes > 0 then
        print('  what to do about the rows above:')
        for _, row in ipairs(fixes) do
            print(('    %-14s %s'):format(row.kind, row.fix))
        end
        print('')
    end

    print('  Next: run `cis_bridge test`. It reads, and writes nothing to a player.')
    print('=======================================================================')
    print('')
    return true
end

exports('GetBridgeReport', function()
    local out = {}
    for _, row in ipairs(lines()) do
        out[#out + 1] = row
    end
    return out
end)

-- Printed once at boot. The framework and inventory are dependencies a server
-- starts before this resource, so one tick is enough; a resource started later
-- is picked up by detection on its own `onResourceStart`, and `cis_bridge
-- report` prints the current answer at any time.
CreateThread(function()
    Wait(1000)
    CisBridgeReport.render()
end)
