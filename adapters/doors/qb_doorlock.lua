-- qb-doorlock backend for the v1 doors contract (server/v1.lua).
--
-- qb-doorlock at 4a8e911 has no server exports. A door's state changes only
-- through the net event 'qb-doorlock:server:updateState' (server.lua:140),
-- which wants a loaded player as its source and trusts client-supplied
-- `unlockAnyway` / `sentSource` arguments. The bridge does not drive a door
-- through that hole, so both calls answer `unsupported`: a product sees that
-- qb-doorlock is present and that it cannot be scripted from the server.

CisBridgeDoors = CisBridgeDoors or {}

local D = { name = 'qb-doorlock', resource = 'qb-doorlock' }

function D.probe()
    return true
end

function D.state(_id)
    return false, 'unsupported'
end

function D.set(_id, _locked)
    return false, 'unsupported'
end

CisBridgeDoors['qb-doorlock'] = D
