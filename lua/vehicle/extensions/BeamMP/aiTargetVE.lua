-- BeamMP LAN fork addition.
-- Vehicle-side helper for the "AI/weapon cars chase nearest player" feature.
--
-- MPVehicleGE pushes the list of valid target object IDs (remote players' active,
-- currently-DRIVEN vehicles) to each local AI car every ~0.6s. We pick the NEAREST of
-- them and tell the AI to chase it; the turret controller aims at ai.targetObjectID, so
-- the gun tracks whatever we pick.
--
-- The whole point of this file is that the car must MOVE BETWEEN targets as the nearest
-- one changes -- not commit to the first player it ever saw. The earlier version held
-- the current target for ~3s whenever the gun was firing; with a weapon that fires
-- almost continuously that hold was active nearly all the time, so a genuinely-closer
-- player could not steal focus and the car looked permanently locked onto one target.
--
-- New rule (no firing dependence): keep the current target only while it is still the
-- nearest, or close to it. As soon as a DIFFERENT valid target is meaningfully closer,
-- switch to it immediately. A small hysteresis margin stops the gun jittering between
-- two near-equal targets without preventing real switches. If the current target drops
-- out of the candidate list (player left or switched out of that vehicle) we retarget at
-- once. Runs in the vehicle VM where live world positions (mapmgr) are known.

local M = {}

local curTarget = nil   -- object ID we last told the AI to chase

-- A new candidate must be at least this much closer (linear distance) than the current
-- target to steal focus. 0.85 => "15% closer". Compared in squared distance below.
local SWITCH_MARGIN = 0.85
local SWITCH_MARGIN_SQ = SWITCH_MARGIN * SWITCH_MARGIN

--- Retarget this vehicle's AI to the nearest of the given object IDs, switching live as
--- the nearest changes (with light hysteresis to avoid jitter).
--- @param ids table array of game object IDs (active player vehicles)
local function retargetIfNotFiring(ids)
	if not ids or #ids == 0 then return end
	if not (ai and ai.isDriving and ai.isDriving()) then return end

	if mapmgr and mapmgr.getObjects then mapmgr.getObjects() end
	local objs = mapmgr and mapmgr.objects
	if not objs then return end

	-- Nearest valid candidate, plus the current target's distance if it's still a
	-- candidate (so we can apply hysteresis / detect that it left the list).
	local myPos = obj:getPosition()
	local bestId, bestD = nil, math.huge
	local curD = nil
	for i = 1, #ids do
		local id = ids[i]
		local o = objs[id]
		if o and o.pos then
			local dx, dy, dz = o.pos.x - myPos.x, o.pos.y - myPos.y, o.pos.z - myPos.z
			local d = dx * dx + dy * dy + dz * dz
			if d < bestD then bestD = d; bestId = id end
			if id == curTarget then curD = d end
		end
	end
	if not bestId then return end

	-- If the current target is still valid, keep it unless the new nearest is
	-- meaningfully closer. (bestD <= curD always, since bestId is the global nearest.)
	-- If curD is nil the current target left the candidate list -> fall through and
	-- switch to the nearest immediately.
	if curD and bestId ~= curTarget and bestD >= curD * SWITCH_MARGIN_SQ then
		bestId = curTarget
	end

	if bestId ~= curTarget then
		if ai.setTargetObjectID then ai.setTargetObjectID(bestId) end
		curTarget = bestId
	end
end

M.retargetIfNotFiring = retargetIfNotFiring

return M
