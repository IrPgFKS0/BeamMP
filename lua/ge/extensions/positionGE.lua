-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- positionGE API.
--- Author of this documentation is Titch
--- @module positionGE
--- @usage applyPos(...) -- internal access
--- @usage positionGE.handle(...) -- external access


local M = {}

local targetGameSpeed = 1
local actualSimSpeed = 1

--[[
	["X-Y"] = table
		[data] = table
			[pos] = array[3]
			[rot] = array[4]
			[vel] = array[3]
			[rvel] = array[4]
			[tim] = float
			[ping] = float
		[last_executed_tim] = float
		[executed_last] = hptimerstruct
		[median] = float
		[median_array] = array
			[1] = next index
			[2] = max array buffer size
			[3..[2] + 2] = float
		[median_timer] = hptimerstruct
		[executed] = bool
]]
local POSSMOOTHER = {}
local TIMER = (HighPerfTimer or hptimer) -- game own timer that is much more accurate then os.clock()

-- ============================================================================
-- LAN perf toggles (cached here, pushed to each vehicle's positionVE via refreshFlags).
-- See MPConfig defaultSettings + README-LAN.md for the full intent of each.
-- ============================================================================
local profOn = false  -- cached settings.getValue("profilePosSync") -- log timing of the hot apply path every ~5s to beamng.log
local physRateSend = false  -- cached settings.getValue("physicsRateSend")
local mailboxOn = false  -- cached settings.getValue("mailboxApplyPos") -- GE->VE apply via engine mailbox (the apply transport; falls back to base64 queueLuaCommand when off)
local applyStallDiagOn = false  -- cached settings.getValue("applyStallDiag") -- VE-side apply-stall diagnostic (off by default); pushed to each vehicle's positionVE
local directVehSock = false  -- cached settings.getValue("directVehicleSocket") -- #245 EXPERIMENTAL: own vehicles send position straight to the launcher's DV socket (bypassing VE->GE)
local dvPort = 4446          -- launcher's direct-vehicle UDP port = launcherPort + 2

-- (The "Remote sync mode" / tracked-vehicle HOLD machinery was removed for the public release:
-- testing showed the stiffening fought the stock predictor, so all vehicles ride it unmodified.)

local profT          = TIMER and TIMER() or nil  -- per-call timer (ms)
local profLastReport = TIMER and TIMER() or nil  -- summary cadence timer (ms)
local profStats      = {}                         -- key -> { n, sum(ms), max(ms) }
local PROF_INTERVAL  = 5000                        -- ms between summary lines

local function profBegin()
	if profOn and profT then profT:stopAndReset() end
end

local function profEnd(key)
	if not (profOn and profT) then return end
	local dur = profT:stop()
	local s = profStats[key]
	if not s then s = {n = 0, sum = 0, max = 0}; profStats[key] = s end
	s.n = s.n + 1
	s.sum = s.sum + dur
	if dur > s.max then s.max = dur end
	local win = profLastReport:stop()
	if win >= PROF_INTERVAL then
		for k, v in pairs(profStats) do
			if v.n > 0 then
				log('I', 'posProf', string.format('GE %-18s n=%d rate=%.0f/s avg=%.4fms max=%.4fms',
					k, v.n, v.n * 1000 / win, v.sum / v.n, v.max))
			end
			v.n = 0; v.sum = 0; v.max = 0
		end
		profLastReport:stopAndReset()
	end
end

-- Re-read the experiment toggles and push the profiling flag down into every
-- spawned vehicle's VE state. Called on init and whenever settings change.
-- #245 direct vehicle socket: register/unregister ONE own vehicle with the launcher (over the core
-- channel, where Core.cpp Parse handles 'Va'/'Vd') and enable/disable its VE-side direct send. Own
-- vehicles with a serverVehicleID + the toggle on send position straight to the DV socket; anything
-- else is torn down back to the GE path. Safe to call repeatedly (idempotent registration).
local function dvSetupVehicle(gameVehicleID)
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return end
	local sid = MPVehicleGE and MPVehicleGE.getServerVehicleID and MPVehicleGE.getServerVehicleID(gameVehicleID)
	local isOwn = sid and MPVehicleGE.isOwn and MPVehicleGE.isOwn(gameVehicleID)
	if directVehSock and isOwn then
		if MPCoreNetwork and MPCoreNetwork.send then MPCoreNetwork.send('Va:'..sid) end -- register with the launcher
		veh:queueLuaCommand("if positionVE and positionVE.setDirectVehicle then positionVE.setDirectVehicle(true, '"..sid.."', "..dvPort..") end")
	else
		if sid and MPCoreNetwork and MPCoreNetwork.send then MPCoreNetwork.send('Vd:'..sid) end -- unregister
		veh:queueLuaCommand("if positionVE and positionVE.setDirectVehicle then positionVE.setDirectVehicle(false) end")
	end
end

local function refreshFlags()
	local newProf = (settings and settings.getValue("profilePosSync")) and true or false
	if newProf and not profOn then -- starting a fresh profiling window
		for k in pairs(profStats) do profStats[k] = nil end
		if profLastReport then profLastReport:stopAndReset() end
	end
	profOn = newProf
	physRateSend = (settings and settings.getValue("physicsRateSend")) and true or false
	mailboxOn = (settings and settings.getValue("mailboxApplyPos")) and true or false
	applyStallDiagOn = (settings and settings.getValue("applyStallDiag")) and true or false
	directVehSock = (settings and settings.getValue("directVehicleSocket")) and true or false -- #245
	dvPort = (tonumber(settings and settings.getValue("launcherPort")) or 4444) + 2
	local sendHz = tonumber(settings and settings.getValue("physRateSendHz")) or 30
	-- The 100Hz UI option was removed (it oversubscribes the relay with 2+ players -> growing
	-- latency). Clamp + migrate any saved value above the new 60Hz ceiling down to the 30Hz default,
	-- and write it back so the dropdown doesn't show a blank (orphaned) selection.
	if sendHz > 60 then
		sendHz = 30
		if settings and settings.setValue then settings.setValue("physRateSendHz", 30) end
	end
	for i = 0, be:getObjectCount() - 1 do
		local veh = be:getObject(i)
		if veh then
			veh:queueLuaCommand("if positionVE and positionVE.setProfiling then positionVE.setProfiling("..tostring(profOn)..") end")
			veh:queueLuaCommand("if positionVE and positionVE.setMailboxApply then positionVE.setMailboxApply("..tostring(mailboxOn)..") end")
			veh:queueLuaCommand("if positionVE and positionVE.setApplyStallDiag then positionVE.setApplyStallDiag("..tostring(applyStallDiagOn)..") end")
			veh:queueLuaCommand("if positionVE and positionVE.setSendHz then positionVE.setSendHz("..sendHz..") end")
			dvSetupVehicle(veh:getID()) -- #245: register/tear down the direct socket for this vehicle
		end
	end
end

-- Called by each vehicle's positionVE the moment its VM (re)loads (queued from VE onInit).
-- THE FIX for the permanent ghost-freeze-after-edit (p13h50): a vehicle EDIT/config change/model
-- swap reloads the VE VM IN PLACE (same object id), silently resetting every VE-side flag to its
-- default -- and the one-time setup in applyPos (gated on veh.mpVehicleType == nil, which lives on
-- the PERSISTENT GE object wrapper) never re-fires. With mailboxApplyPos on, GE kept writing a
-- mailbox the fresh VM never polled: the ghost froze PERMANENTLY after its owner swapped
-- vehicle/config, until any unrelated settings change happened to re-push flags. (Confirmed in the
-- 2026-07-04 17:21+17:51 log pair: each freeze starts at 'applyVehEdit Updating vehicle ...', each
-- recovery at a settings change.) Also fixes the OWN-car variant: a reloaded own VM fell back to
-- the VE-default 100Hz SEND_INTERVAL until the next settings change (relay-overload rate).
-- Re-pushes ALL per-vehicle flags; for a REMOTE vehicle also re-arms the remote type + anti-sleep.
local function veReady(gameVehicleID)
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return end
	local sendHz = tonumber(settings and settings.getValue("physRateSendHz")) or 30
	if sendHz > 60 then sendHz = 30 end
	veh:queueLuaCommand("if positionVE and positionVE.setProfiling then positionVE.setProfiling("..tostring(profOn)..") end")
	veh:queueLuaCommand("if positionVE and positionVE.setMailboxApply then positionVE.setMailboxApply("..tostring(mailboxOn)..") end")
	veh:queueLuaCommand("if positionVE and positionVE.setApplyStallDiag then positionVE.setApplyStallDiag("..tostring(applyStallDiagOn)..") end")
	veh:queueLuaCommand("if positionVE and positionVE.setSendHz then positionVE.setSendHz("..sendHz..") end")
	local v = MPVehicleGE and MPVehicleGE.getVehicleByGameID and MPVehicleGE.getVehicleByGameID(gameVehicleID)
	if v and not v.isLocal then
		veh:queueLuaCommand("if MPVehicleVE then MPVehicleVE.setVehicleType('R') end")
		veh:queueLuaCommand("if positionVE and positionVE.setRemote then positionVE.setRemote() end")
	end
	dvSetupVehicle(gameVehicleID) -- #245: (re)register the direct socket after a VM (re)load / on spawn
end



--- Called on specified interval by positionGE to simulate our own tick event to collect data.
-- sendTraffic (passed by MPUpdatesGE) gates the LOW-rate send for NON-driven owned vehicles
-- (AI/traffic/parked). It is true only at trafficTickrate (~12Hz), NOT every position tick.
-- WHY: physRateSendHz only ever throttled the DRIVEN car (the physics-rate armSelfSend path);
-- every other owned vehicle fell through to getVehicleRotation() on EVERY GE tick (~FPS =
-- 60-90Hz), which the rate lever never touched. With N spawned vehicles that floods the relay
-- (measured 370 pos/s applied at a "10Hz" setting with 7 cars) and starves every ghost into
-- drift -- and dialing physRateSendHz down did nothing to it. The driven car still streams at
-- its full per-tick rate; only the extra vehicles are rate-limited here.
local function tick(sendTraffic)
	local ownMap = MPVehicleGE.getOwnMap() -- Get map of own vehicles
	local activeID = -1
	local ok, av = pcall(function() return be:getPlayerVehicle(0) end)
	if ok and av then activeID = av:getID() end
	for i,v in pairs(ownMap) do -- For each own vehicle
		local veh = be:getObjectByID(i) -- Get vehicle
		if veh then
			if i == activeID then
				-- The vehicle the player is driving: full rate, every tick.
				if physRateSend then
					-- Keep the VE physics-rate self-send armed; it emits at physRateSendHz
					-- from onPhysicsStep regardless of FPS. Arm decays in SELF_SEND_ARM s.
					veh:queueLuaCommand("if positionVE then positionVE.armSelfSend() end")
				else
					-- Legacy per-frame send.
					veh:queueLuaCommand("if positionVE then positionVE.getVehicleRotation() end")
				end
			elseif sendTraffic then
				-- Non-driven owned vehicle (AI/traffic/parked): throttled to trafficTickrate.
				veh:queueLuaCommand("if positionVE then positionVE.getVehicleRotation() end")
			end
		end
	end
end

--- Wraps vehicle position, rotation etc. data from player own vehicles and sends it to the server.
-- INTERNAL USE
-- @param data table The position and rotation data from VE
-- @param gameVehicleID number The vehicle ID according to the local game
local function sendVehiclePosRot(data, gameVehicleID)
	if MPGameNetwork.launcherConnected() then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID) -- Get serverVehicleID
		if serverVehicleID and MPVehicleGE.isOwn(gameVehicleID) then -- If serverVehicleID not null and player own vehicle
			-- Profile the GE-side send handler (the VE->GE funnel's GE half): this is the per-packet,
			-- per-vehicle work the single main-thread GE VM does for every owned vehicle -- jsonDecode
			-- the VE payload, scale vel/rvel by simspeed, jsonEncode again, and hand to the launcher.
			-- (The queueGameEngineLua string COMPILE that precedes this call is engine-internal and not
			-- visible to Lua profiling; this captures the handler-body cost, incl. the decode+re-encode
			-- round-trip.) Shows up in beamng.log as 'GE sendVehiclePosRot' under profilePosSync.
			profBegin()
			local decoded = jsonDecode(data)
			if not decoded then profEnd('sendVehiclePosRot') return end
			local simspeedReal = simTimeAuthority.getReal()

			decoded.isTransitioning = (simTimeAuthority.get() ~= simspeedReal) or nil

			-- NOTE (4.22 sync): the vel/rvel sim-speed scaling that used to live here moved into
			-- positionVE.doSendPosRot (upstream pushes the speed to VE via positionVE.setGameSpeed).
			-- Doing it there covers BOTH send paths -- including the #245 direct vehicle socket,
			-- which bypasses this handler entirely and therefore never got scaled before.

			MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Zp',serverVehicleID,jsonEncode(decoded))) -- 4.22: string-buffer packet build
			profEnd('sendVehiclePosRot')
		end
	end
end


--- This function serves to send the position data received for another players vehicle from GE to VE, where it is handled.
-- @param encoded json The data to be applied to a vehicle, needs to contain "pos", "rot", "vel", "rvel", "ping" and "tim"
-- @param serverVehicleID string The VehicleID according to the server.
local applyPosCount = 0  -- LAN sync-stats overlay: positions applied since last sample (receive rate; falls toward 0 when the relay starves -> the visible drift)
local applyPosRejects = 0 -- packets applyPos REFUSED (unknown vehicle / malformed pose): nonzero = receive-path breakage (e.g. mismatched mod builds) -- the exact state the overlay must never paint green
local function applyPos(decoded, serverVehicleID)
	local vehicle = MPVehicleGE.getVehicleByServerID(serverVehicleID)
	if not vehicle then applyPosRejects = applyPosRejects + 1 log('E', 'applyPos', 'Could not find vehicle by ID '..serverVehicleID) return end
	if not (decoded.pos and decoded.rot) then applyPosRejects = applyPosRejects + 1 log('E', 'applyPos', 'malformed pose for '..serverVehicleID) return end -- crafted/short packet: don't nil-index pos[1]/rot[1] below
	-- Count ONLY past the guards: this feeds the overlay's 'Pos applied' row, and counting at the
	-- top made it read healthy while 100% of packets were being REJECTED (the p13h82-p13h86 break
	-- would have shown 'applied 30/s' the whole time). Rejects get their own counter + row instead.
	applyPosCount = applyPosCount + 1

	profBegin()

	local simspeedFraction = 1
	local gameSpeed = simTimeAuthority.getReal()
	if gameSpeed > 0 then
		simspeedFraction = 1/gameSpeed
		if decoded.vel then for k,v in pairs(decoded.vel) do decoded.vel[k] = v*simspeedFraction end end
		if decoded.rvel then for k,v in pairs(decoded.rvel) do decoded.rvel[k] = v*simspeedFraction end end
	end

	decoded.localSimspeed = simspeedFraction

	local veh = be:getObjectByID(vehicle.gameVehicleID)
	if veh then -- vehicle already spawned, send data
		if veh.mpVehicleType == nil then
			veh:queueLuaCommand("if MPVehicleVE then MPVehicleVE.setVehicleType('R') end")
			veh.mpVehicleType = 'R'
			veh:queueLuaCommand("if positionVE and positionVE.setProfiling then positionVE.setProfiling("..tostring(profOn)..") end")
			veh:queueLuaCommand("if positionVE and positionVE.setMailboxApply then positionVE.setMailboxApply("..tostring(mailboxOn)..") end")
			veh:queueLuaCommand("if positionVE and positionVE.setApplyStallDiag then positionVE.setApplyStallDiag("..tostring(applyStallDiagOn)..") end")
		end
		if mailboxOn then
			-- Engine mailbox transport: deliver the JSON via be:sendToMailbox instead of
			-- compiling a queueLuaCommand string per packet. The VE polls
			-- "mpPos"..obj:getID() each frame (latest-wins -- exactly right for position).
			-- No Lua compile, no base64.
			be:sendToMailbox("mpPos"..vehicle.gameVehicleID, jsonEncode(decoded))
		else
			-- Fallback (mailbox off): legacy base64 queueLuaCommand path.
			veh:queueLuaCommand("if positionVE then positionVE.setVehiclePosRot(mime.unb64(\'".. MPHelpers.b64encode(jsonEncode(decoded)) .."\')) end")
		end
	end
	local deltaDt = math.max((decoded.tim or 0) - (vehicle.lastDt or 0), 0.001)
	vehicle.lastDt = decoded.tim
	local ping = math.floor(decoded.ping*1000) -- (d.ping-deltaDt)

	vehicle.ping = ping
	vehicle.fps = 1/deltaDt
	-- #838 garbage cleanup: pool ONE vec3/quat per vehicle and :set() into them per packet
	-- (was a fresh Point3F + quat per packet; MPVehicleGE's render loop pools the same pair
	-- via the same mpPooledPos flag, so both writers share safe-to-:set objects)
	if not vehicle.mpPooledPos then
		vehicle.position = vec3()
		vehicle.rotation = quat(0, 0, 0, 1)
		vehicle.mpPooledPos = true
	end
	vehicle.position:set(decoded.pos[1], decoded.pos[2], decoded.pos[3])
	vehicle.rotation:set(decoded.rot[1], decoded.rot[2], decoded.rot[3], decoded.rot[4])
	-- Dedicated copy of the RECEIVED pose for the self-heal watchdog. vehicle.position above is
	-- overwritten every frame by MPVehicleGE's nametag loop (it sets it to the rendered OOBB
	-- center + height), so the watchdog can't use it to detect a drifted/frozen ghost -- it would
	-- be comparing the rendered position against itself. rxPos/rxRot are written ONLY here, straight
	-- from the network packet, so received-vs-rendered actually means something.
	vehicle.rxPos = {decoded.pos[1], decoded.pos[2], decoded.pos[3]}
	vehicle.rxRot = {decoded.rot[1], decoded.rot[2], decoded.rot[3], decoded.rot[4]}

	local owner = vehicle:getOwner()
	if owner then UI.setPlayerPing(owner.name, ping) end-- Send ping to UI

	profEnd('applyPos')
end

--- Tries to delay the positional update execution to match the average update interval from this vehicle
-- Reduces vehicle warping
-- @tparam serverVehicleID string X-Y
-- @tparam decoded table The data to be applied to a vehicle, needs to contain "pos", "rot", "vel", "rvel", "ping" and "tim"
local function smoothPosExec(serverVehicleID, decoded)
	--[[ Alternate idea
		Buffer the unexecuted received packets in a by tim sorted table
			[0] = packet
			[1] = packet
			[2] = packet
		Tick at a specific interval (eg every 22 miliseconds)
		Look at the buffer of packets, take packet that is closest to it.
		If we want to exec a packet with tim 0.044 but we only have 0.022 and 0.066
		then produce the 0.044 packet from those two. We need to calc where the car would be in relation of these two packets, not just make a median of two packets. This Idea needs to be thought through.
	]]
	if POSSMOOTHER[serverVehicleID] == nil then
		local new = {}
		new.data = decoded
		new.last_executed_tim = decoded.tim
		new.executed_last = TIMER()
		new.executed = false
		new.median = 32
		new.median_array = {3,10,32,32,32,32,32,32,32,32,32,32}
		--new.median_array = {3,20,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32}
		new.median_timer = TIMER()
		POSSMOOTHER[serverVehicleID] = new
				
	elseif decoded.tim < 3 or (POSSMOOTHER[serverVehicleID].last_executed_tim - decoded.tim) > 3 then -- if remote timer got reset or if new data is 3 seconds earlier then the known, expect that the remote vehicle got reset.
		POSSMOOTHER[serverVehicleID].data = decoded
		POSSMOOTHER[serverVehicleID].last_executed_tim = decoded.tim
		POSSMOOTHER[serverVehicleID].executed = false
				
	elseif POSSMOOTHER[serverVehicleID].last_executed_tim > decoded.tim then
		-- nothing, outdated data
		
	else
		-- notes
		-- right order 0.022 -- 0.044 -- 0.066
		-- wrong order 0.022 -- 0.066 -- 0.044 (if 0.066 is received first, we overwrite it with 0.044 -> if 0.066 wasnt executed yet. otherwise this wouldnt be reached)
		-- Todo: When this happens, try to calc a median packet between the two for all relevant data. eg. (decoded.pos + POSSMOOTHER[serverVehicleID].data.pos) / 2POSSMOOTHER[serverVehicleID].data.pos) / 2
		-- This likely proposes an issue if the tim values are to far away from each other.
		
		-- ensure that there is a min age distance between the remote packages.
		-- LAN-only build: lowered from 15ms to 8ms (~125 Hz) so the receiver
		-- actually applies the higher-rate position updates we now send instead
		-- of discarding ~1/3 of them.
		if (decoded.tim - POSSMOOTHER[serverVehicleID].last_executed_tim) < 0.008 then return nil end
		
		local median_time = POSSMOOTHER[serverVehicleID].median_timer:stopAndReset()
		POSSMOOTHER[serverVehicleID].data = decoded -- also outdates unexecuted packets
		POSSMOOTHER[serverVehicleID].executed = false
		if median_time > 14 then -- there can be lower intervals then 32ms, so we cover that
			if median_time < 80 then
				local median_array = POSSMOOTHER[serverVehicleID].median_array
				local next_index = median_array[1]
				median_array[next_index] = median_time
				median_array[1] = next_index + 1
				if next_index == median_array[2] + 2 then
					median_array[1] = 3
					local median = 0
					for i = 3, median_array[2] + 2 do
						median = median + median_array[i]
					end
					-- median + X to artificially count in small fluctuations
					POSSMOOTHER[serverVehicleID].median = (median / median_array[2]) + 3
				end
				POSSMOOTHER[serverVehicleID].median_array = median_array
			end
		end
	end
end

--- The raw message from the server. This is unpacked first and then sent to applyPos() or smoothPosExec()
-- @param rawData string The raw message data.
local function handle(rawData)
	local code, serverVehicleID, data = string.match(rawData, "^(%a)%:(%d+%-%d+)%:({.*})")

	local veh = MPVehicleGE.getVehicles()[serverVehicleID]

	if not veh or veh.isLocal then
		return
	end

	if code == 'p' then
		local decoded = jsonDecode(data)
		if not decoded then return end -- malformed/truncated packet: don't nil-crash applyPos/smoothPosExec
		if settings.getValue("enablePosSmoother") then
			smoothPosExec(serverVehicleID, decoded)
		else
			-- MUST be the decoded TABLE: this fork's applyPos takes the decoded packet (upstream's
			-- takes the raw string -- the 4.22.1 merge left upstream's string-passing call here,
			-- so applyPos saw string.pos == nil and rejected EVERY remote position as 'malformed
			-- pose'; remote cars froze for the whole session. Single-machine gates can't catch
			-- this -- only a 2-player session exercises this line).
			applyPos(decoded, serverVehicleID)
		end
	else
		log('W', 'handle', "Received unknown packet '"..tostring(code).."'! ".. rawData)
	end
end

--- This function is for setting a ping value for use in the math of predition of the positions 
-- @param ping number The Ping value
local function setPing(ping)
	-- The launcher reports sentinel pings: -1 = no pong yet (session just started), -2 = >800ms.
	-- Passing those through gave every vehicle a NEGATIVE ownPing, which skews the predictor's
	-- time-offset estimate the wrong way. Clamp to 0 (LAN: "unknown" ~= "instant").
	local p = (tonumber(ping) or 0)/1000
	if p < 0 then p = 0 end
	for i = 0, be:getObjectCount() - 1 do
		local veh = be:getObject(i)
		if veh then
			veh:queueLuaCommand("if positionVE then positionVE.setPing("..p..") end")
		end
	end
end

--- This function is to allow for the setting of the vehicle/objects position.
-- @param gameVehicleID number The local game vehicle / object ID
-- @param x number Coordinate x
-- @param y number Coordinate y
-- @param z number Coordinate z
local function setPosition(gameVehicleID, x, y, z) -- TODO: this is only here because there seems to be no way to set vehicle position in vehicle lua without resetting the vehicle
	local veh = getObjectByID(gameVehicleID)
	veh:setPositionNoPhysicsReset(Point3F(x, y, z))
end

local function setPositionRotationVelocity(gameVehicleID, positionData) -- this is done here because setting velocity and rotation in GE doesn't damage vehicles
	local pos = positionData.pos
	local newRot = positionData.rot
	local vel = positionData.vel
	local rvel = positionData.rvel
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return end -- vehicle despawned while a position packet was in flight

	local localVel = veh:getVelocity()
	local vehVel = positionData.vehVel

	if math.abs(localVel.x) + math.abs(localVel.y) + math.abs(localVel.z) > (math.abs(vehVel.x) + math.abs(vehVel.y) + math.abs(vehVel.z))*5 then -- detect if velocity was a teleport
		return
	end

	local refNodeID = veh:getRefNodeId()
	local vehRot = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
	local rot = vehRot:inversed() * newRot
	veh:setClusterPosRelRot(refNodeID, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)

	vel = vel - localVel:rotated(rot) -- setClusterPosRelRot also rotates the velocity so we have to do that as well
	veh:applyClusterVelocityScaleAdd(refNodeID, 1, vel.x, vel.y, vel.z) -- setting velocity with the GE command doesn't destroy vehicles so we set most of the velocity here

	local noCounterVelocity = positionData.noCounter or 0
	local onlyAngularVelocity = 1

	-- but since it doesn't do rotational velocity we still need to use VE
	-- apparently GE to VE queues are really fast, so we don't need any extra prediction with this queue
	veh:queueLuaCommand("if velocityVE then velocityVE.setAngularVelocity("..vel.x..", "..vel.y..", "..vel.z..", "..rvel.x..", "..rvel.y..", "..rvel.z..","..onlyAngularVelocity..","..noCounterVelocity..") end")
end

--- This function is used for setting the simulation speed 
--- @param speed number
local function setActualSimSpeed(speed)
	actualSimSpeed = speed*(1/simTimeAuthority.getReal())
end

--- This function is used for getting the simulation speed 
--- @return number actualSimSpeed
local function getActualSimSpeed()
	return actualSimSpeed
end

-- Self-heal watchdog (LAN robustness). A remote car whose VE apply stalls -- e.g. a broken
-- third-party vehicle (the fullsuv police config, whose setVehiclePosRot fails on its discarded
-- prop structure) -- freezes in place while position data keeps arriving, until someone resets
-- it. We detect a persistent gap between where we're TOLD the ghost is (vehicle.position, set
-- by applyPos) and where it ACTUALLY is, and force a GE-direct resync (setClusterPosRelRot
-- bypasses the stuck VE) so it self-heals without a manual reset. Thresholds are deliberately
-- large -> a healthy / parked / teleporting ghost never trips this.
local selfHealClock = 0
-- RE-ENABLED p13h41 with the rxMoved guard (see the heal condition below). p13h39 disabled it because
-- the snap fought the stock predictor on a drifted TANK (the 38-74m warble); but turning it fully off let
-- a NaN-stalled fullsuv ghost sit out of sync until a manual reset. The rxMoved guard fixes both: it heals
-- ONLY a ghost stuck while fresh positions keep arriving (a real VE-apply stall), never the tank's
-- prediction gaps (no new packets -> rxMoved ~0). The drift GAUGE (wdMaxDrift, overlay) runs regardless.
local SELFHEAL_ENABLED  = true
local SELFHEAL_INTERVAL = 0.25 -- run the check ~4x/sec
local SELFHEAL_DIST_SQ  = 25   -- 5m: told-vs-actual gap that counts as "diverged" (now the metric is real, healthy lead is ~1m)
local SELFHEAL_STALL_S  = 1.0  -- stuck-while-fresh-positions-arrive continuously this long => force a resync. The
                               -- rxMoved guard already excludes the tank; the 1.0s wait excludes BRIEF between-apply
                               -- freezes (under multi-vehicle load the per-vehicle apply rate dips below the 0.1s
                               -- packetTimeout, so a HIGH-SPEED car hits >20m on a 0.3s freeze the predictor would
                               -- recover smoothly on the next packet -- DON'T snap those). A p13h42 'speed-aware fast
                               -- path' (heal at >=20m after 0.3s) was REMOVED p13h47: it warbled a fast Chiron 107x in
                               -- one session by snapping exactly those brief freezes. The tradeoff was a marginal win
                               -- on the broken B25 aircraft (heal ~50m vs ~100m) for a bad warble on a normal car.
local FROZEN_MOVE       = 0.25 -- m the ghost's OWN body moved since the last check, BELOW which it counts as
                               -- "frozen" (stalled apply). Above it the ghost is live/drifting and we DON'T snap
                               -- it -- the stock predictor's own (smooth) teleport handles it. This is the fix for
                               -- the watchdog hard-snapping a moving tank to the stale raw position every 0.5s
                               -- (the warble that made it feel worse than stock). 0.25m over ~0.25s ~= <1 m/s.
local diagTick = 0
local DIAG_TICKS = 20          -- when profiling, log each ghost's peak divergence every DIAG_TICKS*SELFHEAL_INTERVAL (~5s)

-- Sync-stats overlay (MPDebug) live drift signal. wdMaxDrift = worst told-vs-actual gap (m) across
-- ALL ghosts since the overlay last sampled; wdHealCount = self-heal corrections since then. This is
-- the FIX for "the overlay stayed green while ghosts drifted/corrected": the old overlay only watched
-- apply-rate drops + FPS, both of which look healthy during a traffic FLOOD (high aggregate apply rate,
-- one ghost still starved). These measure the actual symptom, regardless of cause.
local wdMaxDrift = 0
local wdHealCount = 0

--- This function is used to execute smoothed positional updates if enabled
local function onPreRender(dt)
	-- tick pos updates per vehicle based on their median pos update interval
	for serverVehicleID, data in pairs(POSSMOOTHER) do
		local timedif = data.executed_last:stop()
		if not data.executed and timedif >= data.median then
			POSSMOOTHER[serverVehicleID].executed_last:stopAndReset()
			POSSMOOTHER[serverVehicleID].executed = true
			POSSMOOTHER[serverVehicleID].last_executed_tim = data.data.tim
			applyPos(data.data, serverVehicleID)

		elseif timedif > 60000 then -- seconds. vehicle potentially removed. rem entry
			POSSMOOTHER[serverVehicleID] = nil
		end
	end


	-- Self-heal: force-resync any ghost whose VE apply has frozen (see notes above).
	-- When position profiling is on, also log each ghost's PEAK told-vs-actual divergence every
	-- ~5s -- this exposes drift BELOW the 10m heal trigger (the steady-state predictor lag the
	-- host sees as "losing" a remote car) so we can measure and tune it. Gated on profPosSync so
	-- normal play stays quiet; the heal path itself runs unconditionally.
	selfHealClock = selfHealClock + dt
	if selfHealClock >= SELFHEAL_INTERVAL then
		local elapsed = selfHealClock
		selfHealClock = 0
		diagTick = diagTick + 1
		local doDiag = profOn and diagTick >= DIAG_TICKS
		for sid, v in pairs(MPVehicleGE.getVehicles()) do
			if type(v) == "table" and not v.isLocal and v.rxPos and v.rxRot and v.gameVehicleID then
				local veh = be:getObjectByID(v.gameVehicleID)
				if veh then
					-- Distance of the ghost from its RECEIVED pose (rxPos = the sender's COG), measured
					-- against TWO candidate anchors, keeping whichever sits CLOSER to rxPos:
					--  * the OOBB CENTER (p13h27: right for LONG vehicles -- the refNode sits ~cogRel from
					--    the COG, 6m on a 12m bus, which read as a permanent fake "6m off" + false snaps);
					--  * the REFNODE (p13h50: right for WEAPON-MOD vehicles that fire NODE-based
					--    projectiles -- flung/spent bullet nodes stretch the OOBB hundreds of meters, so its
					--    center stops being a COG proxy. Live log pair: a healthy turret ghost applying at a
					--    steady 30/s was reported as a constant "170m of drift" on one machine, and on the
					--    other the watchdog false-healed a healthy ghost by the OOBB error -- THROWING it
					--    hundreds of meters, the visible warp).
					-- A genuinely frozen ghost is far from rxPos on BOTH anchors, so detection is intact;
					-- the overlay's drift number inherits the same correction.
					local refPos = veh:getPosition()
					local dxr, dyr, dzr = v.rxPos[1] - refPos.x, v.rxPos[2] - refPos.y, v.rxPos[3] - refPos.z
					local a, distSq = refPos, dxr*dxr + dyr*dyr + dzr*dzr
					local ocx, ocy, ocz = be:getObjectOOBBCenterXYZ(v.gameVehicleID)
					if ocx then
						local dxo, dyo, dzo = v.rxPos[1] - ocx, v.rxPos[2] - ocy, v.rxPos[3] - ocz
						local dsqo = dxo*dxo + dyo*dyo + dzo*dzo
						if dsqo < distSq then a = { x = ocx, y = ocy, z = ocz }; distSq = dsqo end
					end
					-- moved = how far the ghost's OWN BODY moved since the last check -- distinguishes a
					-- FROZEN ghost (stalled apply: barely moves) from one that's just DRIFTING (predictor
					-- live, actively moving). Only a frozen ghost gets the hard snap; a moving one is the
					-- stock predictor's job (the fix for the watchdog warble-snapping a moving tank).
					-- Tracked on the REFNODE (not the chosen anchor): the body is what freezes, and the
					-- refNode can't be dragged around by flung projectile nodes the way the OOBB center can.
					local la = v._wdLastA
					local moved = la and math.sqrt((refPos.x-la[1])*(refPos.x-la[1]) + (refPos.y-la[2])*(refPos.y-la[2]) + (refPos.z-la[3])*(refPos.z-la[3])) or 0
					if la then la[1], la[2], la[3] = refPos.x, refPos.y, refPos.z else v._wdLastA = {refPos.x, refPos.y, refPos.z} end -- reuse the table (moved read above first); no per-check GC litter on the GE heap
					-- rxMoved = how far the RECEIVED position moved since the last check (is the SENDER moving +
					-- streaming fresh positions?). This tells a true VE-apply STALL (sender moving, ghost stuck)
					-- apart from a packet GAP (no new positions -> ghost stalls too, but nothing fresh to snap to).
					local lr = v._wdLastRx
					local rxMoved = lr and math.sqrt((v.rxPos[1]-lr[1])^2 + (v.rxPos[2]-lr[2])^2 + (v.rxPos[3]-lr[3])^2) or 0
					if lr then lr[1], lr[2], lr[3] = v.rxPos[1], v.rxPos[2], v.rxPos[3] else v._wdLastRx = {v.rxPos[1], v.rxPos[2], v.rxPos[3]} end
					local dist = math.sqrt(distSq) -- distSq = min-anchor distance computed above
					if profOn and dist > (v._diagPeak or 0) then v._diagPeak = dist end -- only track peak while profiling (consumed in the doDiag block); avoids a stale unbounded climb otherwise
					if dist > wdMaxDrift and dist < 100 then wdMaxDrift = dist end -- overlay: live max told-vs-actual (cap excludes spawn/teleport transients)
					-- p13h41: heal a GENUINE VE-apply stall only -- ghost far + FROZEN (moved tiny) WHILE the sender
					-- is MOVING (rxMoved live). Re-enabled after p13h39-40 had the watchdog off (which let a NaN-stalled
					-- fullsuv ghost sit out of sync until a manual reset). The rxMoved guard keeps it OFF the tank: a
					-- tank prediction gap has rxMoved ~0, so it never qualifies -- only a ghost stuck while fresh
					-- positions keep arriving does.
					if SELFHEAL_ENABLED and distSq > SELFHEAL_DIST_SQ and moved < FROZEN_MOVE and rxMoved > FROZEN_MOVE then
						v._stallT = (v._stallT or 0) + elapsed
						if v._stallT >= SELFHEAL_STALL_S then -- healed only after a SUSTAINED stall (brief between-apply freezes are the predictor's job, not a snap)
							local ok = pcall(function()
								local refNodeID = veh:getRefNodeId()
								local vehRot = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
								local r = vehRot:inversed() * quat(v.rxRot[1], v.rxRot[2], v.rxRot[3], v.rxRot[4])
								-- Snap so the OOBB CENTER lands on rxPos (the COG), not the refNode: offset the
								-- refNode target by the current refNode->center vector so a long vehicle isn't
								-- shoved by cogRel on the heal.
								local ox, oy, oz = a.x - refPos.x, a.y - refPos.y, a.z - refPos.z
								veh:setClusterPosRelRot(refNodeID, v.rxPos[1]-ox, v.rxPos[2]-oy, v.rxPos[3]-oz, r.x, r.y, r.z, r.w)
							end)
							log('W', 'posWatchdog', string.format(
								"self-heal: ghost %s was %.0fm off its synced position for ~%.1fs -- forced a GE-direct resync%s",
								tostring(sid), dist, v._stallT, ok and "" or " (FAILED)"))
							v._stallT = 0
							wdHealCount = wdHealCount + 1 -- overlay: count corrections
						end
					else
						v._stallT = 0
					end
					if doDiag then
						log('I', 'posWatchdog', string.format(
							"ghost %s told-vs-actual peak %.1fm over ~%.0fs (heal trigger: >%.0fm for %.1fs)",
							tostring(sid), v._diagPeak or 0, DIAG_TICKS * SELFHEAL_INTERVAL,
							math.sqrt(SELFHEAL_DIST_SQ), SELFHEAL_STALL_S))
						v._diagPeak = 0
					end
				end
			end
		end
		if doDiag then diagTick = 0 end
	end
end

local function onUpdate(dtReal, dtSim, dtRaw)
	if MPGameNetwork and MPGameNetwork.launcherConnected() then
		setActualSimSpeed(dtSim/dtRaw)
		local simSpeed = simTimeAuthority.getReal() * (simTimeAuthority.getPause() and 0 or 1)
		if targetGameSpeed ~= simSpeed then
			be:queueAllObjectLua("if positionVE then positionVE.setGameSpeed("..simSpeed..") end") -- guard: fires in EVERY vehicle VM on any pause/slow-mo; an unguarded call FATALs a VM still mid-load (upstream b2bb5685 shipped it unguarded)
		end
		targetGameSpeed = simSpeed
		local players = getPlayers()
		for k,player in pairs(players) do
			player.hasUpdatedPing = false
		end
	end
end

--- This function is used to reset the positional update smoother when it is disabled
local function onSettingsChanged()
	if not settings.getValue("enablePosSmoother") then -- nil/false
		for serverVehicleID, _ in pairs(POSSMOOTHER) do
			POSSMOOTHER[serverVehicleID] = nil
		end
	end
	refreshFlags()
end

M.applyPos                    = applyPos
M.getApplyPosRate             = function() local c = applyPosCount; applyPosCount = 0; return c end -- sync-stats overlay: positions applied since last call
M.getApplyPosRejects          = function() local c = applyPosRejects; applyPosRejects = 0; return c end -- overlay: rejected/s (see applyPos)
M.getDriftStats               = function() local d, h = wdMaxDrift, wdHealCount; wdMaxDrift, wdHealCount = 0, 0; return d, h end -- overlay: max told-vs-actual (m) + self-heal corrections since last call
M.tick                        = tick
M.handle                      = handle
M.sendVehiclePosRot           = sendVehiclePosRot
M.setPosition                 = setPosition
M.setPositionRotationVelocity = setPositionRotationVelocity
M.setPing                     = setPing
M.veReady                     = veReady -- called by positionVE.onInit: re-push per-vehicle flags after a VE VM (re)load
M.dvSetupVehicle              = dvSetupVehicle -- #245: called by positionVE when its socket REOPENS mid-VM (new source port) -> re-send 'Va' so the launcher re-learns the port
M.setActualSimSpeed           = setActualSimSpeed
M.getActualSimSpeed           = getActualSimSpeed
M.onPreRender                 = onPreRender
M.onUpdate                    = onUpdate
M.onSettingsChanged           = onSettingsChanged
M.posSmoother                 = POSSMOOTHER -- debug entry
M.onInit = function() setExtensionUnloadMode(M, "manual"); refreshFlags() end

return M
