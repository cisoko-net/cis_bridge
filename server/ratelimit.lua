-- A per-source cooldown, in its own file so it can be tested without a server.
--
-- What it is for
--
-- `cis_bridge:server:conformanceResults` is a net event, so any connected
-- player can send it, as often as they like, with any payload. Each accepted
-- call prints up to 64 lines into the server console. A player who fires it in
-- a loop does not stop the server, but the console fills with their lines and
-- the operator cannot read the report they asked for.
--
-- FiveM's own net-event limits cap the bytes per second. They do not stop the
-- printing, so this guard refuses the call itself.
--
-- Why a class and not a plain table
--
-- Three details are easy to get wrong, and each one makes the guard stop
-- working without an error:
--
--   - the clock is injectable, so the tests can drive time, and a missing
--     `GetGameTimer` does not stop the handler;
--   - `now` never goes backwards, because `GetGameTimer` is uptime and FiveM
--     gives a source id to a new player after the old one leaves;
--   - `forget` on `playerDropped`, or the table grows by one entry for each
--     player who ever answered.

local Cooldown = {}
Cooldown.__index = Cooldown

--- @param opts table|nil  { intervalMs = number, clock = function }.
---   `clock` defaults to `GetGameTimer`. A test passes its own, so it can move
---   time without sleeping.
---
---   The default is resolved when `take` runs, not here. If it were read here
---   on a realm without the native, the constructor would store nil and the
---   first `take` would raise. Resolved late, a missing clock keeps the guard
---   closed instead.
function Cooldown.new(opts)
    opts = opts or {}
    return setmetatable({
        intervalMs = tonumber(opts.intervalMs) or 5000,
        clock = type(opts.clock) == 'function' and opts.clock or nil,
        last = {},
        -- The highest time seen so far. A clock that goes back is clamped to
        -- it, so deadlines stored before the jump do not refuse calls whose
        -- window has really ended.
        now = 0,
    }, Cooldown)
end

--- Read the clock, or nil when it is missing, raises or is not a number.
---
--- A nil reading becomes the last time this object saw, so the guard stays
--- closed when the clock fails. A guard must never fail open.
local function readClock(self)
    local clock = self.clock
    if clock == nil and type(GetGameTimer) == 'function' then
        clock = GetGameTimer
    end
    if type(clock) ~= 'function' then
        return nil
    end
    local ok, value = pcall(clock)
    if not ok or type(value) ~= 'number' then
        return nil
    end
    return value
end

--- Take the slot for a source, or refuse.
---
--- Refusals are not logged: a log line per refused call from a flooding client
--- is the same flood.
---
--- @return boolean allowed
function Cooldown:take(src)
    -- Only a number can be a player and a table key here. Anything else comes
    -- from a malformed packet, so refuse it.
    if type(src) ~= 'number' or src ~= src then
        return false
    end
    local now = readClock(self) or self.now
    if now < self.now then
        now = self.now
    end
    self.now = now
    local next = self.last[src]
    if next ~= nil and now < next then
        return false
    end
    self.last[src] = now + self.intervalMs
    return true
end

--- Forget a source. Called from `playerDropped`.
function Cooldown:forget(src)
    self.last[src] = nil
end

-- Published as a global as well as returned: fxmanifest loads this file before
-- server/conformance.lua, which reads the global. The test suite reads the
-- return value through `dofile`.
CisBridgeRateLimit = Cooldown

return Cooldown
