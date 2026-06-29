--[[ BeamMP LAN fork -- networked weapon-explosion sync.

UniversalWeapons applies explosions purely locally (BeamEngine:queueAllObjectLua), so on
each machine the locally-simulated shell (the real car on the owner, the ghost elsewhere)
detonates at its own physics-divergent position -- explosions land inconsistently across
clients. Here the weapon OWNER broadcasts each authoritative blast (world position + radii
+ force) over network code 'B'; every other client applies the IDENTICAL blast to its local
objects, so the target's authoritative car takes matching damage on every screen.

Pairing: universalweapons.lua's createExplosionAtPosition calls broadcastExplosion (via
queueGameEngineLua) only when the firing vehicle is local-owned (v.mpVehicleType == "L"),
and a remote ghost ("R") suppresses its own divergent local blast -- so each explosion is
applied exactly once per client, from the owner's coordinates. ]]

local M = {}

local huge = math.huge
local function finite(n) return type(n) == "number" and n == n and n < huge and n > -huge end

-- Sanity caps for a networked blast. Legit UniversalWeapons values are tiny by comparison
-- (howitzer outer radius 10, m242 1; force default 30), so in normal LAN play these never
-- trigger -- they only reject a corrupt or maliciously-crafted 'B' packet. That matters for
-- more than abuse: an oversized radius would force EVERY car on the map through __uwExplode's
-- per-node loop in one frame (a hard hitch), so the cap is also a worst-case perf guard.
local MAX_BLAST_RADIUS = 50    -- outer radius; 5x the biggest stock weapon (howitzer = 10)
local MAX_BLAST_FORCE  = 1000  -- ~33x the default force of 30

--- OWNER side: send an authoritative blast to the server, which relays it to all OTHER
--- clients (code 'B', reliable/TCP; the sender is excluded and already applied it locally).
--- No-op outside an MP session.
local function broadcastExplosion(px, py, pz, r1, r2, force, invCoef)
	if not (MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession()) then return end
	if not (MPGameNetwork and MPGameNetwork.send) then return end
	if not (finite(px) and finite(py) and finite(pz) and finite(r1) and finite(r2) and finite(force) and finite(invCoef)) then return end
	-- compact CSV; values are plain numbers (incl. world coords) so no escaping is needed
	MPGameNetwork.send(string.format("B%f,%f,%f,%f,%f,%f,%f", px, py, pz, r1, r2, force, invCoef))
end

--- OWNER side: tell other clients the firing STATE of this vehicle (1=started, 0=stopped) so the
--- remote runs its own fire loop -- ~2 packets per burst instead of one per shot (the per-shot
--- flood was starving the position stream and causing remote-car drift). Reuses the reliable 'B'
--- relay (no server change) with an "F:" sub-tag; the explosion CSV always starts with a digit or
--- '-', never 'F'. Firing gates on the "fireweapons" electric, which BeamMP only delta-syncs on a
--- tick, so a reliable explicit state is what keeps single shots and bursts in sync.
local function broadcastFire(gameVehicleID, state)
	if not (MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession()) then return end
	if not (MPGameNetwork and MPGameNetwork.send and MPVehicleGE) then return end
	local serverVehicleID = MPVehicleGE.getServerVehicleID and MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not serverVehicleID then return end
	if MPVehicleGE.isOwn and not MPVehicleGE.isOwn(gameVehicleID) then return end -- only the owner broadcasts
	-- Is this the car the owner is actively driving? Remotes give an actively-driven weapon car FULL
	-- physics projectiles; a spawned/AI weapon car gets a light muzzle+sound replay (CPU saver),
	-- unless the receiver's remoteFullProjectiles toggle forces full.
	local active = 0
	local ok, pv = pcall(function() return be:getPlayerVehicle(0) end)
	if ok and pv and pv:getID() == gameVehicleID then active = 1 end
	MPGameNetwork.send("BF:"..serverVehicleID..":"..(state == 1 and "1" or "0")..":"..active)
end

--- RECEIVER side: set the remote ghost's fire flag (its UniversalWeapons controller runs the fire
--- loop while it's on). "1" also refreshes a safety expiry so a missed "0" can't make it fire
--- forever. Payload is "<serverVehicleID>:<0|1>". No-op on our own car or if not found / no mod.
local function handleFire(payload)
	if not MPVehicleGE then return end
	-- "<sid>:<state>:<active>" (h11). Fall back to the 2-field h9/h10 form (active=0) for safety.
	local serverVehicleID, state, active = tostring(payload):match("^(%d+%-%d+):([01]):([01])$")
	if not serverVehicleID then
		serverVehicleID, state = tostring(payload):match("^(%d+%-%d+):([01])$"); active = "0"
	end
	if not serverVehicleID then return end
	local vinfo = MPVehicleGE.getVehicles and MPVehicleGE.getVehicles()[serverVehicleID]
	if not vinfo or vinfo.isLocal then return end
	local gameVehicleID = MPVehicleGE.getGameVehicleID and MPVehicleGE.getGameVehicleID(serverVehicleID)
	local vobj = gameVehicleID and be:getObjectByID(gameVehicleID)
	if vobj then
		if state == "1" then
			-- full physics projectiles if the owner is driving this car, OR we opted into full for all
			local full = (active == "1" or settings.getValue("remoteFullProjectiles") == true) and 1 or 0
			vobj:queueLuaCommand("if electrics then electrics.values.uw_remoteFire = 1; electrics.values.uw_remoteFireExpiry = 1.5; electrics.values.uw_fullProjectiles = "..full.." end")
		else
			vobj:queueLuaCommand("if electrics then electrics.values.uw_remoteFire = 0; electrics.values.uw_remoteFireExpiry = 0 end")
		end
	end
end

--- RECEIVER side: another client's weapon exploded -- apply the same blast locally to all
--- objects (including our authoritative car). __uwExplode is defined on every object by
--- UniversalWeapons (broadcastExplosionFunc); the guard makes this a harmless no-op if no
--- weapon mod is loaded, and finite() rejects any malformed/non-finite payload.
local function handle(data)
	if type(data) ~= "string" then return end
	-- Fire-event sub-message on the same reliable 'B' relay: "F:<serverVehicleID>" -> replay one
	-- shot on that remote ghost (explosion CSV always starts with a digit or '-', never 'F').
	if data:sub(1, 2) == "F:" then return handleFire(data:sub(3)) end
	-- Chase opt-in sub-message, routed to MPVehicleGE: "C:<playerServerID>:<0|1>"
	if data:sub(1, 2) == "C:" then if MPVehicleGE and MPVehicleGE.handleChaseOptIn then MPVehicleGE.handleChaseOptIn(data:sub(3)) end return end
	local px, py, pz, r1, r2, force, invCoef = data:match(
		"^(%-?[%d%.eE]+),(%-?[%d%.eE]+),(%-?[%d%.eE]+),(%-?[%d%.eE]+),(%-?[%d%.eE]+),(%-?[%d%.eE]+),(%-?[%d%.eE]+)$")
	px, py, pz = tonumber(px), tonumber(py), tonumber(pz)
	r1, r2, force, invCoef = tonumber(r1), tonumber(r2), tonumber(force), tonumber(invCoef)
	if not (finite(px) and finite(py) and finite(pz) and finite(r1) and finite(r2) and finite(force) and finite(invCoef)) then return end
	-- Reject (don't clamp) an implausible blast: a corrupt/malicious packet must not apply a
	-- map-wide, every-car explosion. Real weapons sit far inside these bounds.
	if r1 < 0 or r2 < r1 or r2 > MAX_BLAST_RADIUS or math.abs(force) > MAX_BLAST_FORCE then return end
	if invCoef < 0 then invCoef = 0 elseif invCoef > 1 then invCoef = 1 end
	-- GE context: the BeamEngine INSTANCE is the global `be` (capital-B BeamEngine is the
	-- static class and has no queueAllObjectLua -- that's the VE-side name UniversalWeapons uses).
	be:queueAllObjectLua(string.format(
		"if __uwExplode then __uwExplode(%f,%f,%f,%f,%f,%f,%f) end",
		px, py, pz, r1, r2, force, invCoef))
end

M.broadcastExplosion = broadcastExplosion
M.broadcastFire = broadcastFire
M.handle = handle
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
