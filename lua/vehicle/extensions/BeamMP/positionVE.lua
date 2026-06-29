-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

local M = {}



local abs = math.abs
local min = math.min
local max = math.max



-- =============================== SOME FUNCTIONS ===============================
-- Smoothing for vectors, original temporalSmoothingNonLinear created by BeamNG
local vectorSmoothing = {}
vectorSmoothing.__index = vectorSmoothing

local function newVectorSmoothing(rate)
  local data = {rate = rate or 10, state = vec3(0,0,0)}
  setmetatable(data, vectorSmoothing)
  return data
end

function vectorSmoothing:get(sample, dt)
  local st = self.state
  local dif = sample - st
  st = st + dif * min(self.rate * dt, 1)
  self.state = st
  return st
end

function vectorSmoothing:set(sample)
  self.state = sample
end

function vectorSmoothing:reset()
  self.state = vec3(0,0,0)
end
-- =============================== SOME FUNCTIONS ===============================



-- ============= VARIABLES =============
-- Tracked-vehicle hold (tanks): skid-steer + tracks push the ghost off the synced position
-- faster than the stock spring catches up. Detected by wheel count (T-80UD reports 14 road
-- wheels; cars 4, trucks <=10). When tracked, the correction force/ceiling is multiplied by the
-- live hold (NOT the gains, to avoid oscillation). The hold is driven by the GE *sync mode*
-- (positionGE pushes setTrackedHold): 1.0 = stock-smooth (no extra hold, relies on the stock
-- predictor's own teleport), 2.0 = accurate (firm hold). Auto picks between them by FPS. Cars are
-- never stiffened (isTracked stays false -> multiplier forced to 1).
-- NOTE: the previous fixed x4 over-stiffened the tank -- combined with the (now frozen-only)
-- self-heal watchdog it caused the warble that made the tank feel WORSE than stock at 10Hz.
local TRACKED_WHEEL_MIN = 10
local TRACKED_HOLD_DEFAULT = 2.0   -- "accurate" hold; GE overrides per-vehicle at runtime
local trackedHoldChecked = false

-- Position
local posCorrectMul = 5        -- How much velocity to use for correcting position error (m/s per m)
local posForceMul = 5          -- How much acceleration is used to correct velocity
local minPosForce = 0.04       -- If force is smaller than this, ignore to save performance
local maxPosForce = 100        -- Maximum position correction force (m/s^2)
local maxAcc = 100             -- Maximum acceleration in received data (m/s^2)
local maxAccError = 3          -- If difference between target and actual acceleration larger than this, decrease force

-- Rotation
local rotCorrectMul = 7        -- How much velocity to use for correcting angle error (rad/s per rad)
local rotForceMul = 7          -- How much acceleration is used to correct angular velocity
local minRotForce = 0.02       -- If force is smaller than this, ignore to save performance
local maxRotForce = 50         -- Maximum rotation correction force (rad/s^2)
local maxRacc = 50             -- Maximum angular acceleration in received data (rad/s^2)
local maxRaccError = 3         -- If difference between target and actual angular acceleration larger than this, decrease force

-- Base (stock, un-stiffened) correction constants. applyTrackedHold() recomputes the LIVE
-- posForceMul/maxPosForce/etc from these, so the tracked multiplier never compounds and the GE
-- sync mode can change it at runtime WITHOUT touching the per-frame hot paths (both updateGFX and
-- updateGFXFast read the live module locals).
local BASE_posForceMul, BASE_maxPosForce = posForceMul, maxPosForce
local BASE_rotForceMul, BASE_maxRotForce = rotForceMul, maxRotForce
local isTracked = false
local trackedHoldMul = TRACKED_HOLD_DEFAULT   -- effective hold for THIS vehicle (1 = stock); set by GE

local function applyTrackedHold()
	local m = (isTracked and trackedHoldMul) or 1
	posForceMul = BASE_posForceMul * m
	maxPosForce = BASE_maxPosForce * m
	rotForceMul = BASE_rotForceMul * m
	maxRotForce = BASE_maxRotForce * m
end

-- Called by GE (refreshFlags + the sync-mode FPS watcher) to set the live hold. Safe on ANY
-- vehicle: cars keep isTracked=false so the multiplier is forced to 1 (stock) regardless.
local function setTrackedHold(mul)
	trackedHoldMul = tonumber(mul) or trackedHoldMul
	applyTrackedHold()
end

-- Teleport
local tpDelayAdd = 1           -- Additional teleport delay (s)
local tpDistAdd = 1            -- Additional teleport distance (m)
local tpDistMul1 = 0.1         -- Multiplier for delayed teleport distance based on velocity (m per m/s)
local tpDistMul2 = 0.5         -- Multiplier for instant teleport distance based on velocity (m per m/s)
local tpRotAdd = 0.5           -- Additional teleport rotation (rad)
local tpRotMul1 = 0.2          -- Multiplier for delayed teleport rotation based on rotation velocity (rad per rad/s)
local tpRotMul2 = 0.5          -- Multiplier for instant teleport rotation based on rotation velocity (rad per rad/s)
local tpVelSmoother = newTemporalSmoothingNonLinear(2,1000)  -- Smoother for filtering low velocities during collisions
local tpRvelSmoother = newTemporalSmoothingNonLinear(2,1000) -- Smoother for filtering low rotation velocities during collisions

-- Prediction
local maxPredict = 0.3         -- Maximum prediction limit (s)
local packetTimeout = 0.1      -- Stop prediction if no packet received within this time (s)

-- Smoothing
local localVelSmoother = newVectorSmoothing(50)             -- Smoother for local velocity
local localRvelSmoother = newVectorSmoothing(50)            -- Smoother for local angular velocity
local remoteVelSmoother = newVectorSmoothing(2)             -- Smoother for received velocity
local remoteRvelSmoother = newVectorSmoothing(2)            -- Smoother for received angular velocity
local remoteAccSmoother = newVectorSmoothing(1)             -- Smoother for acceleration calculated from received data
local remoteRaccSmoother = newVectorSmoothing(1)            -- Smoother for angular acceleration calculated from received data
local accErrorSmoother = newVectorSmoothing(50)             -- Smoother for acceleration error
local raccErrorSmoother = newVectorSmoothing(50)            -- Smoother for angular acceleration error
local timeOffsetSmoother = newTemporalSmoothingNonLinear(1) -- Smoother for getting average time offset

-- Persistent data
local framesSinceReset = 0
local timer = 0
local ownPing = 0
local lastDT = 0

local lastVehVel = nil
local lastVehRvel = nil

local lastAcc = nil
local lastRacc = nil

local tpTimer = 0

local remoteData = {
	pos = nil,
	vel = vec3(0,0,0),
	acc = vec3(0,0,0),
	rot = quat(0,0,0,0),
	rvel = vec3(0,0,0),
	racc = vec3(0,0,0),
	timer = 0,
	timeOffset = 0,
	recTime = 0,
	localSimspeed = 1
}

local smoothVel = vec3(0,0,0)
local smoothRvel = vec3(0,0,0)

local physHandlerAdded = false

local debugDrawer = obj.debugDrawProxy
-- ============= VARIABLES =============



-- ============= LAN perf experiment (opt-in; toggled from positionGE) =============
-- Times the receive-side hot path and logs an avg/max summary every ~5s. Prefer the
-- engine high-perf timer (wall-clock ms) for BOTH per-call timing and the report
-- interval: os.clock() is wall time on Windows but *process CPU time* on Linux (it
-- sums every thread), which would distort the window length and the reported rate
-- there. If the VE state somehow lacks the timer we fall back to os.clock() and at
-- least report call counts.
local PROF_TIMER = (hptimer or HighPerfTimer)
local profOn = false
local profStats  = {}                                   -- key -> { n, sum(ms), max(ms) }  (timed)
local profCounts = {}                                   -- key -> n                         (count-only)
local profT       = PROF_TIMER and PROF_TIMER() or nil  -- per-call timer (ms)
local profReportT = PROF_TIMER and PROF_TIMER() or nil  -- report-interval timer (ms, wall-clock)
local profClkFallback = os.clock()                      -- only used when PROF_TIMER is nil
local PROF_INTERVAL_MS = 5000

local function profMaybeReport()
	local win = profReportT and profReportT:stop() or ((os.clock() - profClkFallback) * 1000)  -- ms
	if win < PROF_INTERVAL_MS then return end
	for k, v in pairs(profStats) do
		if v.n > 0 then
			log('I', 'posProf', string.format('VE %-20s n=%d rate=%.0f/s avg=%.4fms max=%.4fms',
				k, v.n, v.n * 1000 / win, v.sum / v.n, v.max))
		end
		v.n = 0; v.sum = 0; v.max = 0
	end
	for k, n in pairs(profCounts) do
		if n > 0 then
			log('I', 'posProf', string.format('VE %-20s n=%d rate=%.0f/s', k, n, n * 1000 / win))
		end
		profCounts[k] = 0
	end
	if profReportT then profReportT:stopAndReset() else profClkFallback = os.clock() end
end

local function profBegin()
	if profOn and profT then profT:stopAndReset() end
end

local function profEnd(key)
	if not profOn then return end
	local dur = profT and profT:stop() or 0
	local s = profStats[key]
	if not s then s = {n = 0, sum = 0, max = 0}; profStats[key] = s end
	s.n = s.n + 1
	s.sum = s.sum + dur
	if dur > s.max then s.max = dur end
	profMaybeReport()
end

-- Count-only metric (no timing) for things measured by frequency: send rate,
-- frame rate, predictor starvation, etc.
local function profCount(key)
	if not profOn then return end
	profCounts[key] = (profCounts[key] or 0) + 1
	profMaybeReport()
end

local function setProfiling(state)
	profOn = state and true or false
	for k in pairs(profStats)  do profStats[k]  = nil end   -- clean window on each toggle
	for k in pairs(profCounts) do profCounts[k] = nil end
	if profReportT then profReportT:stopAndReset() end
	profClkFallback = os.clock()
end



local function setPing(p)
	-- some ping packets seem to go missing on local servers
	if p < 0.99 or p > 1.01 then
		ownPing = p
	end
end



-- Limit vector length
local function limitVecLength(vec, length)
	local vecLength = vec:length()
	
	if vecLength > length then
		return vec*(length/vecLength)
	end
	
	return vec
end



-- Rotate the vehicle relative to its current rotation
local function rotateVehicle(rot)
	for _, n in pairs(v.data.nodes) do
		obj:setNodePosition(n.cid, vec3(obj:getNodePosition(n.cid)):rotated(rot):toFloat3())
	end
end



local function onReset()
	-- Reset smoothers and state variables
	localVelSmoother:reset()
	localRvelSmoother:reset()
	tpVelSmoother:reset()
	tpRvelSmoother:reset()
	remoteVelSmoother:reset()
	remoteRvelSmoother:reset()
	remoteAccSmoother:reset()
	remoteRaccSmoother:reset()
	accErrorSmoother:reset()
	raccErrorSmoother:reset()
	
	lastVehVel = nil
	lastVehRvel = nil

	lastAcc = nil
	lastRacc = nil

	smoothVel = vec3(0,0,0)
	smoothRvel = vec3(0,0,0)
	remoteData.acc = vec3(0,0,0)
	remoteData.racc = vec3(0,0,0)
	remoteData.timer = 0
	framesSinceReset = 0
end

local physcounter = 0
local physstart = 0                                   -- os.clock() fallback start (seconds)
local physTimer = PROF_TIMER and PROF_TIMER() or nil  -- wall-clock window timer (reuses the timer ctor above)

local physmult = 1

-- Physics-rate position send (decoupled from render FPS), gated by the
-- physicsRateSend setting. GE arms us each frame via armSelfSend(); we then emit
-- from onPhysicsStep (~2000Hz) at SEND_INTERVAL. sendClock is a physics-rate
-- timestamp so the receiver doesn't dedupe rapid packets (it rejects tim <= last).
local doSendPosRot                  -- forward decl; defined below, shared by both send paths
local sendClock = 0                 -- monotonic send timestamp (s), advanced per physics step while sending
local selfSendTimer = 0             -- >0 while GE keeps arming us; decays once it stops (e.g. vehicle no longer own)
local sendAccum = 0                 -- accumulates dtSim toward one send
local SEND_INTERVAL = 1/100         -- 100 Hz
local SELF_SEND_ARM = 0.5           -- s; one arm heartbeat keeps self-send alive this long

-- Mailbox apply transport (gated by mailboxApplyPos, pushed from positionGE). When on,
-- GE delivers incoming positions via be:sendToMailbox("mpPos"..id) instead of a
-- queueLuaCommand; we poll it per frame in updateGFX (latest-wins). setVehiclePosRot is
-- forward-declared so the poll can call it (it's defined further down).
local setVehiclePosRot
local mailboxOn = false
local lastMailboxVer = nil
local function setMailboxApply(state)
	mailboxOn = state and true or false
	lastMailboxVer = nil -- re-read on next poll after a toggle
end

-- fastPredict (experimental, opt-in, pushed from positionGE.refreshFlags): when on,
-- updateGFX dispatches to updateGFXFast -- a low-GC variant that does the per-frame
-- predictor/error/force math in place using the scratch vecs below instead of
-- allocating ~20 temporary vec3s per frame per remote car (the GC churn KISS-MP and
-- PR #789 reviewers flag). Mathematically identical to the default path. Default OFF;
-- the original updateGFX stays the fallback so toggling off restores known-good behavior.
local fastPredictOn = false
local function setFastPredict(state)
	fastPredictOn = state and true or false
end
local updateGFXFast -- forward decl; defined just after updateGFX

-- Reused scratch vecs for the fastPredict path (module scope = allocated once). Only
-- hold within-frame values; never stored across frames (lastAcc/lastRacc are copied,
-- not aliased, at the end of updateGFXFast).
local fpPos        = vec3(0,0,0)
local fpVel        = vec3(0,0,0)
local fpRotAdd     = vec3(0,0,0)
local fpRvel       = vec3(0,0,0)
local fpPosError   = vec3(0,0,0)
local fpVelError   = vec3(0,0,0)
local fpRvelError  = vec3(0,0,0)
local fpTargetAcc  = vec3(0,0,0)
local fpTargetRacc = vec3(0,0,0)
local fpTmp        = vec3(0,0,0)

local function update(dtSim)
	if physcounter == 0 then
		-- start of the 2000-step measurement window
		if physTimer then physTimer:stopAndReset() else physstart = os.clock() end
	end
	physcounter = physcounter+1
	if physcounter == 2000 then
		physcounter = 0
		-- Wall-clock seconds elapsed over those 2000 physics steps. This MUST be wall
		-- time, not CPU time: os.clock() is wall time on Windows but per-process CPU
		-- time (all threads summed) on Linux, which inflates physdiff and drives
		-- physmult below 1 even at full realtime. hptimer is wall-clock on both OSes.
		local physdiff = physTimer and (physTimer:stop() / 1000) or (os.clock() - physstart)
		if playerInfo.firstPlayerSeated then
			physmult = 1/physdiff -- (physdiff == 0) and 0 or 1/physdiff
			--print(tostring(physmult*100) .."% realtime")
			obj:queueGameEngineLua("positionGE.setActualSimSpeed("..tostring(physmult)..")")
		end
	end


	-- Smooth vehicle velocity to prevent vibrating
	smoothVel = localVelSmoother:get(vec3(obj:getVelocity()), dtSim)
	smoothRvel = localRvelSmoother:get(vec3(obj:getPitchAngularVelocity(), obj:getRollAngularVelocity(), obj:getYawAngularVelocity()), dtSim)

	-- Physics-rate self-send: emit at ~100Hz from here (runs ~2000Hz) instead of
	-- once per render frame, so a low-FPS machine still sends fresh data. Active
	-- only while GE keeps us armed (own vehicle + physicsRateSend on).
	if selfSendTimer > 0 then
		selfSendTimer = selfSendTimer - dtSim
		sendClock = sendClock + dtSim
		sendAccum = sendAccum + dtSim
		if sendAccum >= SEND_INTERVAL then
			sendAccum = sendAccum - SEND_INTERVAL
			doSendPosRot(true)
		end
	end
end



local function updateGFX(dt)
	dt = dt * (remoteData.localSimspeed or 1)
	timer = timer + dt
	lastDT = dt
	framesSinceReset = framesSinceReset + 1

	-- Mailbox apply: pull the latest position GE delivered (when enabled). Latest-wins
	-- is correct -- stale intermediate samples are useless to the predictor.
	if mailboxOn then
		local name = "mpPos"..obj:getID()
		local ver = obj:getLastMailboxVersion(name)
		if ver ~= lastMailboxVer then
			lastMailboxVer = ver
			local data = obj:getLastMailbox(name)
			if data and data ~= "" then setVehiclePosRot(data) end
		end
	end

	-- Frame/starvation accounting. Only counts on vehicles that have ever received
	-- remote data (i.e. the remote car), so it never conflates with the local one.
	-- 'frames' ~= this client's render FPS; 'stale' = frames where the last packet
	-- was older than packetTimeout, so the predictor sat idle (warping/freezing).
	if profOn and remoteData.pos then
		profCount('updateGFX.frames')
		if (timer - remoteData.recTime) > packetTimeout then profCount('updateGFX.stale') end
	end

	-- If there is no received data, or data is older than timeout, do nothing
	if not remoteData.pos or (timer-remoteData.recTime) > packetTimeout then return end
	
	-- Since the line above returns end if there is no remote data we know this vehicle should be remote if this runs
	if v.mpVehicleType == "L" then v.mpVehicleType = "R" end

	-- One-time tracked-vehicle detection. Runs once wheels are initialised; flips isTracked and
	-- applies the current GE-pushed hold via applyTrackedHold (which mutates the live force constants
	-- both predictor paths read, so it covers updateGFX and updateGFXFast).
	if not trackedHoldChecked and wheels and (wheels.wheelCount or 0) > 0 then
		trackedHoldChecked = true
		if wheels.wheelCount >= TRACKED_WHEEL_MIN then
			isTracked = true
			applyTrackedHold()   -- apply the current hold (GE may have already pushed the sync-mode value)
			log('I', 'positionVE', 'tracked vehicle ('..tostring(wheels.wheelCount)..' wheels): position hold x'..trackedHoldMul..' (GE sync-mode controlled)')
		end
	end

	-- experimental opt-in: low-GC in-place predictor path. The default math below is
	-- left fully intact, so toggling fastPredict off restores known-good behavior.
	if fastPredictOn then return updateGFXFast(dt) end

	profBegin()

	-- Local vehicle data
	local vehRot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
	local vehRvel = smoothRvel:rotated(vehRot)
	local vehRacc = vehRvel-(lastVehRvel or vehRvel)
	
	local cog = velocityVE.cogRel:rotated(vehRot)
	local vehPos = vec3(obj:getPosition()) + cog
	local vehVel = smoothVel + cog:cross(vehRvel)
	local vehAcc = vehVel-(lastVehVel or vehVel)

	lastVehVel = vehVel
	lastVehRvel = vehRvel

	-- Smoothed difference between local and remote timestamps
	local timeOffset = timeOffsetSmoother:get(remoteData.timeOffset, dt)
	if abs(timeOffset - remoteData.timeOffset) > 1 then
		timeOffsetSmoother:set(remoteData.timeOffset)
		timeOffset = remoteData.timeOffset
	end

	-- Calculate back to local time using the remote timestamp and the smoothed time difference
	local calcLocalTime = remoteData.timer + timeOffset

	-- How far ahead the position needs to be predicted
	local predictTime = min(max(timer - calcLocalTime, -maxPredict), maxPredict)

	-- More prediction = slower smoothing
	local smootherDT = dt / guardZero(abs(predictTime))
	local remoteVel = remoteVelSmoother:get(remoteData.vel, smootherDT)
	local remoteRvel = remoteRvelSmoother:get(remoteData.rvel, smootherDT)
	local remoteAcc = remoteAccSmoother:get(remoteData.acc, smootherDT)
	local remoteRacc = remoteRaccSmoother:get(remoteData.racc, smootherDT)

	-- Use received position, and smoothed velocity and acceleration to predict vehicle position
	local pos = remoteData.pos + remoteVel*predictTime + 0.5*remoteAcc*predictTime*predictTime
	local vel = remoteVel + remoteAcc*predictTime
	local rotAdd = remoteRvel*predictTime + 0.5*remoteRacc*predictTime*predictTime
	local rot = remoteData.rot * quatFromEuler(rotAdd.x, rotAdd.y, rotAdd.z)
	local rvel = remoteRvel + remoteRacc*predictTime

	--[[
	-- Debug
	debugDrawer:drawSphere(0.3, remoteData.pos:toFloat3(), color(0,0,255,200))
	debugDrawer:drawLine(remoteData.pos:toFloat3(), (remoteData.pos + vec3(0,-5,0):rotated(remoteData.rot)):toFloat3(), color(0,0,255,200))
	debugDrawer:drawSphere(0.3, pos:toFloat3(), color(0,255,0,200))
	debugDrawer:drawLine(pos:toFloat3(), (pos + vec3(0,-5,0):rotated(rot)):toFloat3(), color(0,255,0,200))
	debugDrawer:drawSphere(0.3, vehPos:toFloat3(), color(255,0,0,200))
	debugDrawer:drawLine(vehPos:toFloat3(), (vehPos + vec3(0,-5,0):rotated(vehRot)):toFloat3(), color(255,0,0,200))
	debugDrawer:drawText(pos:toFloat3(), color(0,0,0,255), string.format("Prediction: %.0f ms", predictTime*1000))
	--]]

	-- Error correction
	local posError = pos - vehPos
	local rotErrorQuat = vehRot:inversed() * rot
	local rotError = rotErrorQuat:toEulerYXZ()
	rotError = vec3(rotError.y, rotError.z, rotError.x)
	
	-- Calculate teleport thresholds
	local maxVel = tpVelSmoother:get(max(vel:length(), vehVel:length()), dt)
	local tpDist1 = tpDistAdd + maxVel*tpDistMul1
	local tpDist2 = tpDistAdd + maxVel*tpDistMul2
	
	-- Debug for teleport distances
	--debugDrawer:drawSphere(tpDist1, vehPos:toFloat3(), color(0,0,255,50))
	--debugDrawer:drawSphere(tpDist2, vehPos:toFloat3(), color(255,0,0,50))
	
	local maxRvel = tpRvelSmoother:get(max(rvel:length(), vehRvel:length()), dt)
	local tpRot1 = tpRotAdd + maxRvel*tpRotMul1
	local tpRot2 = tpRotAdd + maxRvel*tpRotMul2
	
	local posErrorLen = posError:length()
	local rotErrorLen = rotError:length()
	
	if posErrorLen > tpDist1 or rotErrorLen > tpRot1 then
		tpTimer = tpTimer + dt
	else
		tpTimer = 0
	end

	-- If instant teleport distance or teleport timer exceeded, teleport
	if framesSinceReset > 5 then -- wating 6 frames then always teleporting the 6th frame makes reseting/recovering a remote vehicle at speed teleport much more consistent, maybe the smoothers catching up?
		if framesSinceReset == 6 or tpTimer > (tpDelayAdd + abs(predictTime)) or posErrorLen > tpDist2 or rotErrorLen > tpRot2 then
			local predictTime = predictTime + dt -- add one frame so postion is correct when arriving in GE
			-- Use received position, and smoothed velocity and acceleration to predict vehicle position
			local pos = remoteData.pos + remoteVel*predictTime + 0.5*remoteAcc*predictTime*predictTime
			local vel = remoteVel + remoteAcc*predictTime
			local rotAdd = remoteRvel*predictTime + 0.5*remoteRacc*predictTime*predictTime
			local rot = remoteData.rot * quatFromEuler(rotAdd.x, rotAdd.y, rotAdd.z)
			-- Subtract COG offset because setPosition works relative to refNode
			local tpPos = pos - velocityVE.cogRel:rotated(rot)

			local noCounterVelocity = 0
			if framesSinceReset == 6 then
				noCounterVelocity = 1 -- logs on the t series count as not attached so they would fly backwards on spawn, this disables the counter velocity preventing that
			end
			local posData = {pos = tpPos, vel = vel, vehVel = vehVel, rot = rot,rvel = rvel , noCounter = noCounterVelocity}
			
			obj:queueGameEngineLua("positionGE.setPositionRotationVelocity("..obj:getID()..","..serialize(posData)..")")
	
			remoteVelSmoother:set(remoteData.vel)
			remoteRvelSmoother:set(remoteData.rvel)
	
			remoteData.acc = vec3(0,0,0)
			remoteData.racc = vec3(0,0,0)
			remoteAccSmoother:reset()
			remoteRaccSmoother:reset()
	
			lastAcc = nil
	
			accErrorSmoother:reset()
			raccErrorSmoother:reset()

			profEnd('updateGFX')
			return
		end
	end

	local velError = vel - vehVel
	local accError = accErrorSmoother:get((lastAcc or vehAcc) - vehAcc, dt)
	--print("AccError: "..tostring(accError:length()/dt))

	local rvelError = rvel - vehRvel
	local raccError = raccErrorSmoother:get((lastRacc or vehRacc) - vehRacc, dt)
	--print("RaccError: "..tostring(raccError:length()/dt))

	local targetAcc = limitVecLength((velError + posError*posCorrectMul)*min(posForceMul*dt,1), maxPosForce*dt)
	local targetRacc = limitVecLength((rvelError + rotError*rotCorrectMul)*min(rotForceMul*dt,1), maxRotForce*dt)

	local targetAccMul = 1-min(max(targetAcc:dot(accError)/(targetAcc:squaredLength()+maxAccError*maxAccError*dt),0),1)
	--print("Force multiplier: "..targetAccMul)
	targetAcc = targetAcc*targetAccMul

	local targetRaccMul = 1-min(max(targetRacc:dot(raccError)/(targetRacc:squaredLength()+maxRaccError*maxRaccError*dt),0),1)
	--print("Rotation force multiplier: "..targetRaccMul)
	targetRacc = targetRacc*targetRaccMul

	--print("targetAcc: "..targetAcc:length())
	--print("targetRacc: "..targetRacc:length())
	if framesSinceReset > 5 then
		if targetRacc:length() > minRotForce or vehVel:length() > 1 then
			velocityVE.addAngularVelocity(targetAcc.x, targetAcc.y, targetAcc.z, targetRacc.x, targetRacc.y, targetRacc.z)
		elseif targetAcc:length() > minPosForce then
			velocityVE.addVelocity(targetAcc.x, targetAcc.y, targetAcc.z)
		end
	end

	lastAcc = targetAcc
	lastRacc = targetRacc

	profEnd('updateGFX')
end


-- Low-GC variant of updateGFX, run only when fastPredict is on. The per-frame VEC
-- math (predictor, error, force) is done in place into the module scratch vecs above;
-- the quat math, the vehRot/vehPos block, the smoothers and the (rare) teleport branch
-- are kept identical to updateGFX -- converting those carries quaternion-convention and
-- cross-frame-aliasing risk for little allocation volume. Result is mathematically the
-- same as the default path. EXPERIMENTAL: validate in-game (watch for remote-car
-- warping/jitter) before trusting; toggle fastPredict off to fall back instantly.
updateGFXFast = function(dt)
	profBegin()

	-- Local vehicle data (kept as original -- low-volume quat/helper allocs)
	local vehRot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
	local vehRvel = smoothRvel:rotated(vehRot)
	local vehRacc = vehRvel-(lastVehRvel or vehRvel)

	local cog = velocityVE.cogRel:rotated(vehRot)
	local vehPos = vec3(obj:getPosition()) + cog
	local vehVel = smoothVel + cog:cross(vehRvel)
	local vehAcc = vehVel-(lastVehVel or vehVel)

	lastVehVel = vehVel
	lastVehRvel = vehRvel

	local timeOffset = timeOffsetSmoother:get(remoteData.timeOffset, dt)
	if abs(timeOffset - remoteData.timeOffset) > 1 then
		timeOffsetSmoother:set(remoteData.timeOffset)
		timeOffset = remoteData.timeOffset
	end

	local calcLocalTime = remoteData.timer + timeOffset
	local predictTime = min(max(timer - calcLocalTime, -maxPredict), maxPredict)

	local smootherDT = dt / guardZero(abs(predictTime))
	local remoteVel = remoteVelSmoother:get(remoteData.vel, smootherDT)
	local remoteRvel = remoteRvelSmoother:get(remoteData.rvel, smootherDT)
	local remoteAcc = remoteAccSmoother:get(remoteData.acc, smootherDT)
	local remoteRacc = remoteRaccSmoother:get(remoteData.racc, smootherDT)

	-- pos = remoteData.pos + remoteVel*predictTime + 0.5*remoteAcc*predictTime^2  (in place)
	fpPos:setScaled2(remoteAcc, 0.5*predictTime*predictTime)
	fpTmp:setScaled2(remoteVel, predictTime)
	fpPos:setAdd(fpTmp)
	fpPos:setAdd(remoteData.pos)
	local pos = fpPos
	-- vel = remoteVel + remoteAcc*predictTime
	fpVel:setScaled2(remoteAcc, predictTime)
	fpVel:setAdd(remoteVel)
	local vel = fpVel
	-- rotAdd = remoteRvel*predictTime + 0.5*remoteRacc*predictTime^2
	fpRotAdd:setScaled2(remoteRacc, 0.5*predictTime*predictTime)
	fpTmp:setScaled2(remoteRvel, predictTime)
	fpRotAdd:setAdd(fpTmp)
	local rotAdd = fpRotAdd
	local rot = remoteData.rot * quatFromEuler(rotAdd.x, rotAdd.y, rotAdd.z)
	-- rvel = remoteRvel + remoteRacc*predictTime
	fpRvel:setScaled2(remoteRacc, predictTime)
	fpRvel:setAdd(remoteRvel)
	local rvel = fpRvel

	-- Error correction
	fpPosError:setSub2(pos, vehPos)
	local posError = fpPosError
	local rotErrorQuat = vehRot:inversed() * rot
	local rotError = rotErrorQuat:toEulerYXZ()
	rotError = vec3(rotError.y, rotError.z, rotError.x)

	local maxVel = tpVelSmoother:get(max(vel:length(), vehVel:length()), dt)
	local tpDist1 = tpDistAdd + maxVel*tpDistMul1
	local tpDist2 = tpDistAdd + maxVel*tpDistMul2

	local maxRvel = tpRvelSmoother:get(max(rvel:length(), vehRvel:length()), dt)
	local tpRot1 = tpRotAdd + maxRvel*tpRotMul1
	local tpRot2 = tpRotAdd + maxRvel*tpRotMul2

	local posErrorLen = posError:length()
	local rotErrorLen = rotError:length()

	if posErrorLen > tpDist1 or rotErrorLen > tpRot1 then
		tpTimer = tpTimer + dt
	else
		tpTimer = 0
	end

	if framesSinceReset > 5 then
		if framesSinceReset == 6 or tpTimer > (tpDelayAdd + abs(predictTime)) or posErrorLen > tpDist2 or rotErrorLen > tpRot2 then
			local predictTime = predictTime + dt -- add one frame so postion is correct when arriving in GE
			local pos = remoteData.pos + remoteVel*predictTime + 0.5*remoteAcc*predictTime*predictTime
			local vel = remoteVel + remoteAcc*predictTime
			local rotAdd = remoteRvel*predictTime + 0.5*remoteRacc*predictTime*predictTime
			local rot = remoteData.rot * quatFromEuler(rotAdd.x, rotAdd.y, rotAdd.z)
			local tpPos = pos - velocityVE.cogRel:rotated(rot)

			local noCounterVelocity = 0
			if framesSinceReset == 6 then
				noCounterVelocity = 1
			end
			local posData = {pos = tpPos, vel = vel, vehVel = vehVel, rot = rot,rvel = rvel , noCounter = noCounterVelocity}

			obj:queueGameEngineLua("positionGE.setPositionRotationVelocity("..obj:getID()..","..serialize(posData)..")")

			remoteVelSmoother:set(remoteData.vel)
			remoteRvelSmoother:set(remoteData.rvel)

			remoteData.acc = vec3(0,0,0)
			remoteData.racc = vec3(0,0,0)
			remoteAccSmoother:reset()
			remoteRaccSmoother:reset()

			lastAcc = nil

			accErrorSmoother:reset()
			raccErrorSmoother:reset()

			profEnd('updateGFX')
			return
		end
	end

	-- velError = vel - vehVel ; rvelError = rvel - vehRvel  (in place)
	fpVelError:setSub2(vel, vehVel)
	local velError = fpVelError
	local accError = accErrorSmoother:get((lastAcc or vehAcc) - vehAcc, dt)

	fpRvelError:setSub2(rvel, vehRvel)
	local rvelError = fpRvelError
	local raccError = raccErrorSmoother:get((lastRacc or vehRacc) - vehRacc, dt)

	-- targetAcc = limitVecLength((velError + posError*posCorrectMul)*min(posForceMul*dt,1), maxPosForce*dt)
	fpTargetAcc:setScaled2(posError, posCorrectMul)
	fpTargetAcc:setAdd(velError)
	fpTargetAcc:setScaled(min(posForceMul*dt,1))
	local taLen, taMax = fpTargetAcc:length(), maxPosForce*dt
	if taLen > taMax then fpTargetAcc:setScaled(taMax/taLen) end
	local targetAcc = fpTargetAcc
	-- targetRacc = limitVecLength((rvelError + rotError*rotCorrectMul)*min(rotForceMul*dt,1), maxRotForce*dt)
	fpTargetRacc:setScaled2(rotError, rotCorrectMul)
	fpTargetRacc:setAdd(rvelError)
	fpTargetRacc:setScaled(min(rotForceMul*dt,1))
	local trLen, trMax = fpTargetRacc:length(), maxRotForce*dt
	if trLen > trMax then fpTargetRacc:setScaled(trMax/trLen) end
	local targetRacc = fpTargetRacc

	local targetAccMul = 1-min(max(targetAcc:dot(accError)/(targetAcc:squaredLength()+maxAccError*maxAccError*dt),0),1)
	targetAcc:setScaled(targetAccMul)

	local targetRaccMul = 1-min(max(targetRacc:dot(raccError)/(targetRacc:squaredLength()+maxRaccError*maxRaccError*dt),0),1)
	targetRacc:setScaled(targetRaccMul)

	if framesSinceReset > 5 then
		if targetRacc:length() > minRotForce or vehVel:length() > 1 then
			velocityVE.addAngularVelocity(targetAcc.x, targetAcc.y, targetAcc.z, targetRacc.x, targetRacc.y, targetRacc.z)
		elseif targetAcc:length() > minPosForce then
			velocityVE.addVelocity(targetAcc.x, targetAcc.y, targetAcc.z)
		end
	end

	-- Retain as PERSISTENT COPIES, not scratch refs: fpTargetAcc/fpTargetRacc are
	-- overwritten next frame, so aliasing them into lastAcc/lastRacc would corrupt the
	-- accError/raccError terms above. Copy values instead (allocates once, then reuses).
	if lastAcc then lastAcc:set(targetAcc.x, targetAcc.y, targetAcc.z) else lastAcc = targetAcc:copy() end
	if lastRacc then lastRacc:set(targetRacc.x, targetRacc.y, targetRacc.z) else lastRacc = targetRacc:copy() end

	profEnd('updateGFX')
end



-- Reused per-send table: avoids allocating a fresh table + 4 subtables on every
-- send (~100Hz) which adds GC pressure and frame-time spikes. jsonEncode reads
-- the current values each call, so reuse is safe.
local posSendTbl = { pos = {0,0,0}, vel = {0,0,0}, rot = {0,0,0,0}, rvel = {0,0,0}, tim = 0, ping = 0 }
-- Shared send body. `useSendTime` selects the physics-rate clock (self-send) vs the
-- render-frame timer (legacy GE-driven send) for the packet timestamp -- the receiver
-- rejects tim <= last, so rapid self-sends need the finer, always-advancing clock.
function doSendPosRot(useSendTime)
	profBegin()
	-- this attempts to send a full table of nan if there are several rapid instability causing VE lua to break after next vehicle reload, seems to be caused by a game issue
	local rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
	local rvel = smoothRvel:rotated(rot)

	local cog = velocityVE.cogRel:rotated(rot)
	local pos = vec3(obj:getPosition()) + cog
	local vel = smoothVel + cog:cross(rvel)
	-- Skip sending if ANY value is NaN. During rapid instability the game can
	-- produce NaN position/rotation (not just velocity); sending it teleports our
	-- car to NaN on every other client -- it "disappears" for them until we reload.
	-- Checking only velocity (the old behaviour) let NaN positions through.
	if pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z
		or vel.x ~= vel.x or vel.y ~= vel.y or vel.z ~= vel.z
		or rot.x ~= rot.x or rot.y ~= rot.y or rot.z ~= rot.z or rot.w ~= rot.w
		or rvel.x ~= rvel.x or rvel.y ~= rvel.y or rvel.z ~= rvel.z then
		log('E','getVehicleRotation', 'skipped invalid (NaN) position/velocity values')
		return
	end

	-- disabled because the GE implementation of slowmo sync is instant, but doesn't account for low fps compensation
	--vel = vel * physmult
	--rvel = rvel * physmult

	local t = posSendTbl
	t.pos[1], t.pos[2], t.pos[3] = pos.x, pos.y, pos.z
	t.vel[1], t.vel[2], t.vel[3] = vel.x, vel.y, vel.z
	t.rot[1], t.rot[2], t.rot[3], t.rot[4] = rot.x, rot.y, rot.z, rot.w
	t.rvel[1], t.rvel[2], t.rvel[3] = rvel.x, rvel.y, rvel.z
	t.tim = useSendTime and sendClock or timer
	t.ping = ownPing + lastDT
	obj:queueGameEngineLua("positionGE.sendVehiclePosRot(\'"..jsonEncode(t).."\', "..obj:getID()..")") -- Send it

	profEnd('getVehicleRotation') -- counts only actual sends (NaN-skipped frames return above)
end

-- Legacy per-frame send (GE drives this via positionGE.tick when physicsRateSend is off).
local function getVehicleRotation()
	doSendPosRot(false)
end

-- GE calls this every frame on own vehicles when physicsRateSend is on; it keeps the
-- physics-step self-send (in update) alive. Remote vehicles are never armed, so they
-- never self-send. The arm decays in SELF_SEND_ARM seconds once GE stops calling it
-- (e.g. the vehicle is no longer owned), so no diffing of the own-set is needed.
local function armSelfSend()
	if selfSendTimer <= 0 then sendClock = timer end -- resync clock on (re)start so tim stays monotonic across a toggle
	selfSendTimer = SELF_SEND_ARM
end

-- LAN: tunable physics-rate send. GE pushes physRateSendHz here (default 100) so the user can dial
-- the per-vehicle send rate DOWN (e.g. 10Hz = stock-BeamMP) to fit a throughput-limited relay, then
-- back up depending on the clients. Reassigns the SEND_INTERVAL upvalue, so update() picks it up live.
local function setSendHz(hz)
	hz = tonumber(hz)
	if hz and hz >= 1 and hz <= 200 then SEND_INTERVAL = 1/hz end
end



function setVehiclePosRot(data)  -- assigns the forward-declared local (called by the mailbox poll above)
	profBegin()

	local pr   = jsonDecode(data)
	if not pr then return end -- malformed packet: don't kill this vehicle's VE Lua VM
	local pos  = vec3(pr.pos)
	local vel  = vec3(pr.vel)
	local rot  = quat(pr.rot)
	local rvel = vec3(pr.rvel)
	local tim  = pr.tim
	local ping = pr.ping
	local simspeedfraction = pr.localSimspeed

	if not tim then return end
	-- Reject NaN/garbage so a bad packet can't fling the remote car off-world
	-- (defensive; the sender also guards against this now).
	if pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z
		or rot.x ~= rot.x or rot.y ~= rot.y or rot.z ~= rot.z or rot.w ~= rot.w then
		return
	end
	if remoteData.timer > tim then return end

	local remoteDT = max(tim - remoteData.timer, 0.001)

	remoteData.pos = pos
	remoteData.rot = rot
	remoteData.acc = limitVecLength((vel - remoteData.vel)/remoteDT, maxAcc)
	remoteData.racc = limitVecLength((rvel - remoteData.rvel)/remoteDT, maxRacc)
	remoteData.vel = vel
	remoteData.rvel = rvel
	remoteData.timer = tim
	remoteData.timeOffset = timer-tim - ownPing/2 - ping/2 - lastDT
	remoteData.recTime = timer
	remoteData.localSimspeed = math.min(simspeedfraction or 1, 25)

	profEnd('setVehiclePosRot')
end

local function onInit()
	enablePhysicsStepHook()
end



M.onReset            = onReset
M.onInit             = onInit
M.onExtensionLoaded  = onInit
M.onPhysicsStep      = update
M.updateGFX          = updateGFX
M.getVehicleRotation = getVehicleRotation
M.armSelfSend        = armSelfSend
M.setVehiclePosRot   = setVehiclePosRot
M.setPing            = setPing
M.setProfiling       = setProfiling
M.setMailboxApply    = setMailboxApply
M.setFastPredict     = setFastPredict
M.setSendHz          = setSendHz
M.setTrackedHold     = setTrackedHold


return M
