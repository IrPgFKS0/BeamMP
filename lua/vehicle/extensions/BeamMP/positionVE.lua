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

-- GC: computed component-wise straight into the persistent state vector. The old form allocated
-- THREE vec3 per call (sample-st, dif*k, st+...) and this runs twice per physics step at ~2000 Hz
-- in every vehicle VM. Returns the state vector ITSELF, so callers must treat it as read-only and
-- must not stash it expecting a snapshot -- see the audit note on set() below.
function vectorSmoothing:get(sample, dt)
  local st = self.state
  local k = min(self.rate * dt, 1)
  st:set(st.x + (sample.x - st.x) * k,
         st.y + (sample.y - st.y) * k,
         st.z + (sample.z - st.z) * k)
  return st
end

-- COPIES, never aliases. It used to do `self.state = sample`, which made the smoother's state the
-- caller's vector: with the in-place get() above, the very next get() would then mutate the
-- caller's object. remoteVelSmoother:set(remoteData.vel) does exactly that, so aliasing here would
-- silently corrupt the received packet data.
function vectorSmoothing:set(sample)
  self.state:set(sample.x, sample.y, sample.z)
end

-- In place, so the state vector keeps a stable identity for the whole VM lifetime (get() relies on
-- mutating one object rather than replacing it).
function vectorSmoothing:reset()
  self.state:set(0, 0, 0)
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
-- DISABLED p13h39: hardware testing showed STOCK BeamMP syncs the T-80UD tank fine with NO tracked
-- special-casing, while this fork's x2 stiffening (+ the self-heal watchdog) FOUGHT the stock predictor
-- and made the tank spike 38-74m on the remote at 30Hz. So no vehicle is treated as "tracked" any more
-- (999 = unreachable wheel count -> isTracked stays false -> force multiplier forced to 1 = pure stock
-- predictor for ALL vehicles, tank included). Restore the band-aid by setting this back to 10.
local TRACKED_WHEEL_MIN = 999
local TRACKED_HOLD_DEFAULT = 1.0   -- stock (no extra hold); kept so applyTrackedHold/setTrackedHold stay inert
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
-- sync mode can change it at runtime WITHOUT touching the per-frame hot path (updateGFX reads the
-- live module locals).
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

-- Cross-frame predictor state, deliberately in ONE table: updateGFX reads all four, and as separate
-- file locals they cost it four upvalues out of LuaJIT's hard cap of 60 (exceeding it fails the
-- WHOLE file at load, and this function was sitting at 58). One table costs one, which buys back
-- the headroom the remaining GC work needs.
--
-- The four fields keep their nil-or-vector semantics exactly (nil = "no previous frame", which is
-- what onReset, the teleport branch and setVehiclePosRot's clock-reset branch all rely on). What
-- changed in p13h97 is only WHERE the vector lives: updateGFX now COPIES into the dedicated s*
-- backing vectors below and points the field at one of those, instead of handing over a freshly
-- allocated one. An s* slot must NEVER be one of E's scratch slots -- E is rewritten at the top of
-- the next frame, before these are read, so aliasing would make vehAcc/vehRacc identically zero
-- every frame with no error anywhere (verified: naive pooling gives vec3(0,0,0) forever).
local P = { vehVel = nil, vehRvel = nil, acc = nil, racc = nil,
            sVehVel = vec3(), sVehRvel = vec3(), sAcc = vec3(), sRacc = vec3() }



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
-- Reusable samples for the 2000 Hz smoother feed (see update()). Never escape this file.
local sVelSample = vec3(0,0,0)
local sRvelSample = vec3(0,0,0)
-- Reusable working set for doSendPosRot, which allocated ~15 vec3/quat per send. ONE table so it
-- costs a single upvalue. Every member is written before it is read on each send, and none escapes:
-- the values leave only as NUMBERS copied into posSendTbl for jsonEncode.
local W = { dir = vec3(), dirUp = vec3(), rot = quat(), rvel = vec3(), cog = vec3(), pos = vec3(), vel = vec3() }
-- W's sibling for the RECEIVE side: the remote-ghost predictor in updateGFX, which allocated
-- ~2.8 KB per render frame PER GHOST (44 vec3 + 5 quat) and, unlike the send path, scales with the
-- number of remote players. ONE table = ONE upvalue (updateGFX sits near LuaJIT's hard cap of 60,
-- and exceeding it fails the WHOLE file at load); inlining limitVecLength's clamp pays that back.
--
-- ALIASING CONTRACT -- read this before touching updateGFX:
--  * READ-ONLY, never the SELF of a set*: the four remote*Smoother:get returns, accError/raccError,
--    smoothVel/smoothRvel (all are the smoothers' OWN state vectors since p13h95), every
--    remoteData.* field (received packet state), and velocityVE.cogRel (velocityVE's own state).
--    Passing them as an OPERAND is safe -- every mathlib set* reads its operands into locals first.
--  * Never assign a slot from here into P or into remoteData; P has its own s* backing vectors.
--  * One slot per named value. Do NOT share two live values on one slot to save memory: vehAcc
--    stays live until the accError line and vehRacc until raccError, long after they are computed.
local E = {
	dir = vec3(), dirUp = vec3(), vehRot = quat(),
	vehRvel = vec3(), vehRacc = vec3(), cog = vec3(), vehPos = vec3(),
	vehVel = vec3(), vehAcc = vec3(),
	pos = vec3(), vel = vec3(), rotAdd = vec3(), qe = quat(), rot = quat(), rvel = vec3(),
	posError = vec3(), rotErrQ = quat(), eul = vec3(), rotError = vec3(),
	velError = vec3(), accSample = vec3(), rvelError = vec3(), raccSample = vec3(),
	targetAcc = vec3(), targetRacc = vec3(),
}
local mailboxName = nil     -- GC: cached "mpPos"..obj:getID(), built once on first use

-- Ghost anti-sleep: set true once this vehicle proves remote (first received packet) and
-- obj:setSleepingEnabled(false) has been applied; cleared on reset (onReset) so it re-arms.
-- Declared HERE, above onReset/setVehiclePosRot, so both close over the same local.
-- See the comment at the top of setVehiclePosRot for why a ghost must never physics-sleep.
local sleepDisabled = false

-- APPLY-STALL DIAGNOSTIC (p13h43): instrument the one spot a remote ghost can freeze -- updateGFX's
-- "no fresh packet" early-return -- so a single /savelogs after a freeze NAMES the cause instead of us
-- guessing. Purely additive: counters + a one-shot 'W' log, no behavior change. ONE table = ONE upvalue
-- in the hot updateGFX (LuaJIT caps a function at 60 upvalues; 9 separate locals blew past it).
local sd = {
	realTimer = 0,       -- real (NOT simSpeed-scaled) clock; updateGFX advances it by the raw dt
	recRealT  = 0,       -- realTimer at the last ACCEPTED packet (for the real-time gap)
	recvCount = 0,       -- setVehiclePosRot calls = packets that actually reached this VE
	rejectCount = 0,     -- packets rejected out-of-order at the tim guard (sender clock reset?)
	starveT = 0,         -- s the apply has been continuously starved (early-returning)
	recv0 = 0, rej0 = 0, -- recv/reject snapshot at the start of the current starve
	logged = false,      -- one-shot per starve episode
	logS = 1.0,          -- log once the apply has been starved this long
	diagOn = false,      -- UI gate (Options>Multiplayer "Log position apply-stalls"); off = no tracking/logs
}

local physHandlerAdded = false

local debugDrawer = obj.debugDrawProxy

local simSpeedReal = 1
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

-- ONE table, deliberately: updateGFX sits within a couple of upvalues of LuaJIT's hard cap of 60,
-- and exceeding it fails the WHOLE FILE at load. Two plain local functions cost two upvalues; this
-- costs one. Same reason the scratch vectors below live in a table rather than as file locals.
local gc = { mark = 0, stats = {} }   -- stats: key -> { n, sum(bytes), max(bytes) }
function gc.begin_()
	if profOn then gc.mark = collectgarbage('count') end
end

function gc.finish(key)
	if not profOn then return end
	local delta = (collectgarbage('count') - gc.mark) * 1024 -- KB -> bytes
	if delta < 0 then return end -- a collection ran mid-call; that sample tells us nothing
	local s = gc.stats[key]
	if not s then s = {n = 0, sum = 0, max = 0}; gc.stats[key] = s end
	s.n = s.n + 1
	s.sum = s.sum + delta
	if delta > s.max then s.max = delta end
end

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
	for k, v in pairs(gc.stats) do
		if v.n > 0 then
			log('I', 'posProf', string.format('VE %-20s n=%d avg=%.0fB/call max=%.0fB', k, v.n, v.sum / v.n, v.max))
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

-- GC accounting for the hot path: bytes of Lua garbage produced per call, which is what actually
-- drives collector stutter (timings alone hide it). Sampled around a whole updateGFX call via
-- collectgarbage('count'), which returns KB and allocates nothing itself. Gated on profOn so a
-- before/after comparison runs under identical conditions.
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
	for k in pairs(gc.stats)   do gc.stats[k]   = nil end
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

-- In-place sibling of the above, for the per-frame predictor (updateGFX) where the returned vector
-- was pure garbage. Same arithmetic: __mul(vec, n) computes n*v.x and setScaled(n) computes v.x*n,
-- and IEEE multiplication is bitwise commutative. Kept SEPARATE rather than converting the original
-- because the two differ in ownership of the result and their callers are disjoint: the allocating
-- version stays for the receive path (setVehiclePosRot), which assigns straight into remoteData.acc
-- /.racc and so needs a fresh, uniquely-owned vector. Do not point that path at this one.
local function limitVecLengthIP(vec, length)
	local vecLength = vec:length()
	if vecLength > length then
		vec:setScaled(length/vecLength)
	end
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
	
	P.vehVel = nil
	P.vehRvel = nil

	P.acc = nil
	P.racc = nil

	smoothVel = vec3(0,0,0)
	smoothRvel = vec3(0,0,0)
	remoteData.acc = vec3(0,0,0)
	remoteData.racc = vec3(0,0,0)
	remoteData.timer = 0
	framesSinceReset = 0
	sleepDisabled = false -- re-arm the ghost anti-sleep on the next received packet (reset/reload may clear the engine flag)
end

local physcounter = 0
local physstart = 0                                   -- os.clock() fallback start (seconds)
local physTimer = PROF_TIMER and PROF_TIMER() or nil  -- wall-clock window timer (reuses the timer ctor above)


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

-- Apply-stall diagnostic gate (pushed from positionGE.refreshFlags). Off by default = zero per-frame
-- work and no logs; flip it on from Options>Multiplayer to capture the next freeze's cause.
local function setApplyStallDiag(state)
	sd.diagOn = state and true or false
	if not sd.diagOn then sd.starveT = 0; sd.logged = false end -- clear any in-flight episode when disabling
end

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
			-- `local`: without it this writes a GLOBAL in every seated vehicle's VM, which the
			-- engine's globals watchdog logs with a stack traceback (~5x per machine per session).
			-- Nothing reads it elsewhere -- it is consumed on the next line, and it reaches GE as a
			-- stringified literal in the queued command, not as a global lookup.
			local physmult = 1/physdiff -- (physdiff == 0) and 0 or 1/physdiff
			--print(tostring(physmult*100) .."% realtime")
			obj:queueGameEngineLua("positionGE.setActualSimSpeed("..tostring(physmult)..")")
		end
	end


	gc.begin_()
	-- Smooth vehicle velocity to prevent vibrating.
	-- GC: both samples are built into reusable scratch vectors instead of allocating a fresh vec3
	-- per physics step. getVelocityXYZ returns the three components directly, avoiding the engine
	-- allocating a vec3 that we then copied again. The smoothers return their own state vector, so
	-- smoothVel/smoothRvel are references to it -- only ever READ below (:rotated / + cross, both
	-- of which allocate their own result), never stored as a snapshot.
	sVelSample:set(obj:getVelocityXYZ())
	sRvelSample:set(obj:getPitchAngularVelocity(), obj:getRollAngularVelocity(), obj:getYawAngularVelocity())
	smoothVel = localVelSmoother:get(sVelSample, dtSim)
	smoothRvel = localRvelSmoother:get(sRvelSample, dtSim)

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
	gc.finish('update.gc')   -- physics-step garbage: the number the GC rework targets
end



-- NOTE (4.22 sync): upstream's updateRemoteData() (vehPosPckt mailbox -> remoteData) is NOT
-- used here -- this fork receives positions through setVehiclePosRot (the mpPos mailbox and
-- the #245 direct vehicle socket) and runs its own predictor on top, so keeping a second,
-- never-called receive path would only invite the two to drift apart.
-- Its state variable `lastMailboxVersion` went with it (p13h97) -- upstream still declares and
-- uses that name, so a merge may reintroduce the bare declaration: it belongs to the removed
-- path, not to the live poll below, which uses `lastMailboxVer`. Delete it again if it returns.



local function updateGFX(dt)
	gc.begin_()
	local rawDt = dt                        -- real render dt, BEFORE the simSpeed scaling below (stall diag)
	sd.realTimer = sd.realTimer + rawDt
	dt = dt * (remoteData.localSimspeed or 1)
	timer = timer + dt
	lastDT = dt
	framesSinceReset = framesSinceReset + 1

	-- Mailbox apply: pull the latest position GE delivered (when enabled). Latest-wins
	-- is correct -- stale intermediate samples are useless to the predictor.
	if mailboxOn then
		-- GC: the mailbox name is constant for this VM's lifetime; building it per frame allocated a
		-- fresh string every render frame on every ghost. Built once, lazily (obj:getID() is not
		-- reliable at file scope).
		if not mailboxName then mailboxName = "mpPos"..obj:getID() end
		local name = mailboxName
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

	-- If there is no received data, or data is older than timeout, do nothing.
	-- This early-return is THE spot a remote ghost freezes (it stops queuing the GE apply). The diag
	-- block tracks how long we've been starved and, once per episode, logs the state that pins the cause:
	--   recv+0   => packets aren't reaching the VE at all (GE->VE delivery stalled)
	--   reject+N => packets arrive but are rejected out-of-order (sender clock reset, e.g. on respawn)
	--   realGap small + simSpeed high => the simSpeed-scaled VE clock raced past packetTimeout (timer-race)
	--   realGap large => packets genuinely stopped
	if not remoteData.pos or (timer - remoteData.recTime) > packetTimeout then
		if sd.diagOn and remoteData.pos then
			if sd.starveT == 0 then sd.recv0 = sd.recvCount; sd.rej0 = sd.rejectCount end
			sd.starveT = sd.starveT + rawDt
			if sd.starveT > sd.logS and not sd.logged then
				sd.logged = true
				local realGap = sd.realTimer - sd.recRealT
				local dRecv, dRej = sd.recvCount - sd.recv0, sd.rejectCount - sd.rej0
				local why = (dRecv == 0) and "packets NOT reaching the VE (GE->VE delivery stalled)"
					or (dRej > 0 and dRej >= dRecv) and "packets REJECTED out-of-order at the tim guard (sender clock reset on respawn?)"
					or (realGap < packetTimeout) and "TIMER-RACE: packets ARE arriving but the simSpeed-scaled VE clock timed out"
					or "packets genuinely stopped (real gap large)"
				log('W', 'posApplyStall', string.format(
					"ghost apply STALLED ~%.1fs -- simGap=%.2f realGap=%.2f simSpeed=%.2f recv+%d reject+%d mailbox=%s(v%s) :: %s",
					sd.starveT, timer - remoteData.recTime, realGap, remoteData.localSimspeed or 1,
					dRecv, dRej, tostring(mailboxOn), tostring(lastMailboxVer), why))
			end
		end
		return
	end
	sd.starveT = 0
	sd.logged = false
	
	-- Since the line above returns end if there is no remote data we know this vehicle should be remote if this runs
	if v.mpVehicleType == "L" then v.mpVehicleType = "R" end

	-- One-time tracked-vehicle detection. Runs once wheels are initialised; flips isTracked and
	-- applies the current GE-pushed hold via applyTrackedHold (which mutates the live force constants
	-- the predictor reads).
	if not trackedHoldChecked and wheels and (wheels.wheelCount or 0) > 0 then
		trackedHoldChecked = true
		if wheels.wheelCount >= TRACKED_WHEEL_MIN then
			isTracked = true
			applyTrackedHold()   -- apply the current hold (GE may have already pushed the sync-mode value)
			log('I', 'positionVE', 'tracked vehicle ('..tostring(wheels.wheelCount)..' wheels): position hold x'..trackedHoldMul..' (GE sync-mode controlled)')
		end
	end

	profBegin()

	-- Local vehicle data
	-- GC: computed in place into the E pool. The *XYZ getters hand back the three components
	-- directly, so neither the engine nor mathlib allocates -- the same substitution doSendPosRot
	-- already ships and p13h96 verified in-game. smoothRvel/smoothVel and velocityVE.cogRel are
	-- foreign state: OPERANDS ONLY (the two-arg setRotate; the one-arg form would overwrite them).
	local vehRot = E.vehRot
	E.dir:set(obj:getDirectionVectorXYZ())
	E.dir:setScaled(-1)
	E.dirUp:set(obj:getDirectionVectorUpXYZ())
	vehRot:setFromDir(E.dir, E.dirUp)

	local vehRvel = E.vehRvel
	vehRvel:setRotate(vehRot, smoothRvel)
	local vehRacc = E.vehRacc
	vehRacc:setSub2(vehRvel, P.vehRvel or vehRvel)

	local cog = E.cog
	cog:setRotate(vehRot, velocityVE.cogRel)
	local vehPos = E.vehPos
	vehPos:set(obj:getPositionXYZ())
	vehPos:setAdd(cog)
	local vehVel = E.vehVel
	vehVel:setCross(cog, vehRvel)   -- cog x vehRvel ...
	vehVel:setAdd(smoothVel)        -- ... + smoothVel (IEEE addition commutes; cog is not clobbered)
	local vehAcc = E.vehAcc
	vehAcc:setSub2(vehVel, P.vehVel or vehVel)

	-- COPY into P's backing vectors -- see the aliasing contract on E. Order matters: this runs
	-- AFTER vehRacc/vehAcc have consumed last frame's values.
	P.sVehVel:set(vehVel.x, vehVel.y, vehVel.z);     P.vehVel  = P.sVehVel
	P.sVehRvel:set(vehRvel.x, vehRvel.y, vehRvel.z); P.vehRvel = P.sVehRvel

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
	-- GC: written per component so the float grouping is EXACTLY the old operator form,
	--   a + b*t + 0.5*c*t*t  ==  (a + (b*t)) + (((0.5*c)*t)*t)
	-- Do NOT "simplify" by hoisting 0.5*predictTime*predictTime into a local: that re-associates the
	-- multiply and moves the last bit. remoteVel/remoteRvel/remoteAcc/remoteRacc above ARE the
	-- smoothers' own state vectors -- every appearance here is a READ.
	local pt = predictTime
	local pos, vel, rotAdd, rot, rvel = E.pos, E.vel, E.rotAdd, E.rot, E.rvel
	pos:set(remoteData.pos.x + remoteVel.x*pt + 0.5*remoteAcc.x*pt*pt,
	        remoteData.pos.y + remoteVel.y*pt + 0.5*remoteAcc.y*pt*pt,
	        remoteData.pos.z + remoteVel.z*pt + 0.5*remoteAcc.z*pt*pt)
	vel:set(remoteVel.x + remoteAcc.x*pt,
	        remoteVel.y + remoteAcc.y*pt,
	        remoteVel.z + remoteAcc.z*pt)
	rotAdd:set(remoteRvel.x*pt + 0.5*remoteRacc.x*pt*pt,
	           remoteRvel.y*pt + 0.5*remoteRacc.y*pt*pt,
	           remoteRvel.z*pt + 0.5*remoteRacc.z*pt*pt)
	E.qe:setFromEuler(rotAdd.x, rotAdd.y, rotAdd.z)
	rot:setMul2(remoteData.rot, E.qe)   -- destination must never be an operand: keep E.rot dedicated
	rvel:set(remoteRvel.x + remoteRacc.x*pt,
	         remoteRvel.y + remoteRacc.y*pt,
	         remoteRvel.z + remoteRacc.z*pt)

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
	-- GC: setInvMul2 IS vehRot:inversed() * rot -- same invSqNorm, same setMulXYZW, no temporaries --
	-- and setEulerYXZ is the body toEulerYXZ calls. The y,z,x swizzle needs its own second slot:
	-- done in one vector it would read a component after overwriting it.
	local posError = E.posError
	posError:setSub2(pos, vehPos)
	local rotErrorQuat = E.rotErrQ
	rotErrorQuat:setInvMul2(vehRot, rot)
	E.eul:setEulerYXZ(rotErrorQuat)
	local rotError = E.rotError
	rotError:set(E.eul.y, E.eul.z, E.eul.x)
	
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
			-- RARE path, deliberately left allocating: it returns immediately and is dominated by
			-- serialize() anyway. vehVel and rvel here are the OUTER E pool slots (rvel was computed at
			-- the un-incremented predictTime, unlike the shadowed pos/vel/rot above) -- copied so the
			-- payload cannot depend on nothing having touched the pool between here and serialize().
			local posData = {pos = tpPos, vel = vel, vehVel = vec3(vehVel), rot = rot,rvel = vec3(rvel) , noCounter = noCounterVelocity}
			
			obj:queueGameEngineLua("positionGE.setPositionRotationVelocity("..obj:getID()..","..serialize(posData)..")")
	
			remoteVelSmoother:set(remoteData.vel)
			remoteRvelSmoother:set(remoteData.rvel)
	
			remoteData.acc = vec3(0,0,0)
			remoteData.racc = vec3(0,0,0)
			remoteAccSmoother:reset()
			remoteRaccSmoother:reset()
	
			P.acc = nil
	
			accErrorSmoother:reset()
			raccErrorSmoother:reset()

			profEnd('updateGFX')
			return
		end
	end

	-- GC: E.accSample/E.raccSample carry the (previous - current) difference into the smoothers,
	-- which read the sample componentwise and keep no reference. accError/raccError come back as the
	-- smoothers' OWN state vectors: only :dot()'ed below, never written.
	local velError = E.velError
	velError:setSub2(vel, vehVel)
	E.accSample:setSub2(P.acc or vehAcc, vehAcc)
	local accError = accErrorSmoother:get(E.accSample, dt)
	--print("AccError: "..tostring(accError:length()/dt))

	local rvelError = E.rvelError
	rvelError:setSub2(rvel, vehRvel)
	E.raccSample:setSub2(P.racc or vehRacc, vehRacc)
	local raccError = raccErrorSmoother:get(E.raccSample, dt)
	--print("RaccError: "..tostring(raccError:length()/dt))

	local targetAcc, targetRacc = E.targetAcc, E.targetRacc
	local kPos = min(posForceMul*dt,1)
	targetAcc:set((velError.x + posCorrectMul*posError.x)*kPos,
	              (velError.y + posCorrectMul*posError.y)*kPos,
	              (velError.z + posCorrectMul*posError.z)*kPos)
	limitVecLengthIP(targetAcc, maxPosForce*dt)
	local kRot = min(rotForceMul*dt,1)
	targetRacc:set((rvelError.x + rotCorrectMul*rotError.x)*kRot,
	               (rvelError.y + rotCorrectMul*rotError.y)*kRot,
	               (rvelError.z + rotCorrectMul*rotError.z)*kRot)
	limitVecLengthIP(targetRacc, maxRotForce*dt)

	local targetAccMul = 1-min(max(targetAcc:dot(accError)/(targetAcc:squaredLength()+maxAccError*maxAccError*dt),0),1)
	--print("Force multiplier: "..targetAccMul)
	targetAcc:setScaled(targetAccMul)

	local targetRaccMul = 1-min(max(targetRacc:dot(raccError)/(targetRacc:squaredLength()+maxRaccError*maxRaccError*dt),0),1)
	--print("Rotation force multiplier: "..targetRaccMul)
	targetRacc:setScaled(targetRaccMul)

	--print("targetAcc: "..targetAcc:length())
	--print("targetRacc: "..targetRacc:length())
	if framesSinceReset > 5 then
		if targetRacc:length() > minRotForce or vehVel:length() > 1 then
			velocityVE.addAngularVelocity(targetAcc.x, targetAcc.y, targetAcc.z, targetRacc.x, targetRacc.y, targetRacc.z)
		elseif targetAcc:length() > minPosForce then
			velocityVE.addVelocity(targetAcc.x, targetAcc.y, targetAcc.z)
		end
	end

	-- COPY, never alias: targetAcc/targetRacc are E slots, rewritten next frame.
	P.sAcc:set(targetAcc.x, targetAcc.y, targetAcc.z);     P.acc  = P.sAcc
	P.sRacc:set(targetRacc.x, targetRacc.y, targetRacc.z); P.racc = P.sRacc

	profEnd('updateGFX')
	gc.finish('updateGFX.gc')
end


-- Reused per-send table: avoids allocating a fresh table + 4 subtables on every
-- send (~100Hz) which adds GC pressure and frame-time spikes. jsonEncode reads
-- the current values each call, so reuse is safe.
local posSendTbl = { pos = {0,0,0}, vel = {0,0,0}, rot = {0,0,0,0}, rvel = {0,0,0}, tim = 0, ping = 0 }
-- Shared send body. `useSendTime` selects the physics-rate clock (self-send) vs the
-- render-frame timer (legacy GE-driven send) for the packet timestamp -- the receiver
-- rejects tim <= last, so rapid self-sends need the finer, always-advancing clock.
-- ============= Direct vehicle socket (#245, EXPERIMENTAL, default-off) =============
-- When positionGE pushes setDirectVehicle(true, sid, port) on an OWN vehicle, this VE sends its
-- position packet straight to the launcher's direct UDP socket (127.0.0.1: launcherPort+2), bypassing
-- the VE->GE Lua queue + the GE proxy (the measured send-side funnel). The launcher forwards it to the
-- server exactly like the proxy path -- the wire format ("Zp:<sid>:<json>") is identical, so the
-- server and every receiver are unchanged. Position-only first cut (the template for the other 5
-- subsystems). LIMITATION: the GE-side simspeed scaling (positionGE.sendVehiclePosRot) is skipped on
-- this path, so slow-motion velocity sync is unscaled in direct mode (identical at normal speed).
-- Falls back to the GE path if require('socket') is unavailable or direct is off -> zero risk when off.
local dvEnabled = false
local dvSid = nil
local dvPort = nil
local dvSock = nil
local dvHadSock = false -- a socket existed earlier in THIS VM: a reopen = a NEW source port -> must re-register (launcher pins one port per sid)
local dvSocketLib = nil -- nil = not tried, false = unavailable, table = the socket lib
-- Launcher-ack confirmation (the void-send guard): UDP send() succeeds even when NOTHING listens on
-- the port -- an OLD launcher without the direct socket made a car's entire output vanish silently
-- (LAN2 2026-07-09, frozen for every other player). The NEW launcher acks each registration (and
-- ~1/s as keepalive) straight back to this socket; until ANY datagram arrives here, dvSend keeps
-- returning false so callers ALSO send via the GE path (brief duplicates are harmless: position
-- rejects tim<=last, inputs are idempotent). No ack within DV_CONFIRM_TIMEOUT of the first send ->
-- give up and stay on the GE path until the toggle/vehicle re-arms.
local dvConfirmed = false
local dvProbes = 0 -- unconfirmed sends since (re)arm; count-based so the deadline is clock-semantics-free (os.clock is CPU-time on Linux)
local DV_CONFIRM_MAX_PROBES = 150 -- ~3-5s at typical send rates (position+inputs ~40-70/s driven, ~12/s parked)
-- #245 diagnostic (EXPERIMENTAL): dvSend/setDirectVehicle are otherwise silent (all pcall), so a
-- silent fallback to the GE path is invisible. dvDiag logs each DISTINCT outcome line exactly once
-- (per VM load) to beamng.log so one test run pinpoints where the direct path engages or fails.
local dvDiagged = {}
local function dvDiag(msg, key) -- key defaults to msg; pass a stable key when the msg has a varying part (e.g. byte count) so it still logs ONCE
	key = key or msg
	if dvDiagged[key] then return end
	dvDiagged[key] = true
	log('I', 'dvSocket', msg)
end
local function dvClose()
	if dvSock then pcall(function() dvSock:close() end); dvSock = nil end
end
local function setDirectVehicle(enabled, sid, port)
	local newEnabled = (enabled == true) and (sid ~= nil)
	local newPort = tonumber(port)
	-- Idempotent re-push (refreshFlags fires on every settings change): keep the confirm state so a
	-- confirmed socket isn't pointlessly re-probed. Any actual change re-arms the ack cycle.
	if not (newEnabled == dvEnabled and sid == dvSid and newPort == dvPort) then
		dvConfirmed = false
		dvProbes = 0
	end
	dvEnabled = newEnabled
	dvSid = sid
	dvPort = newPort
	if not dvEnabled then dvClose() end
	dvDiag('setDirectVehicle: enabled='..tostring(dvEnabled)..' sid='..tostring(sid)..' port='..tostring(dvPort))
end
-- Send a TAGGED payload straight to the launcher's DV socket over this vehicle's ONE shared UDP
-- socket. `tag` is the wire prefix the GE path would have used ('Zp' position, 'Vi' inputs); the
-- packet ("<tag>:<sid>:<payload>") is byte-identical to the proxy path so the server + every receiver
-- are unchanged. The launcher learns this vehicle's source port from the FIRST packet and rejects any
-- other port, so EVERY subsystem for a vehicle MUST go through this one socket -- hence other VE
-- modules (MPInputsVE, ...) call positionVE.dvSend rather than opening their own. Returns true on
-- success (caller skips the GE queue), false to fall back to the GE proxy. ONLY latest-wins data
-- belongs here (UDP is drop-tolerant only if the next packet self-corrects): position + inputs.
local function dvSend(tag, payload)
	if not (dvEnabled and dvSid and dvPort) then return false end
	if not dvSock then
		if dvSocketLib == nil then
			local ok, lib = pcall(require, 'socket')
			dvSocketLib = (ok and lib) or false
			dvDiag('require(socket): ok='..tostring(ok)..' type='..type(lib)..(ok and '' or (' err='..tostring(lib))))
		end
		if not dvSocketLib then dvEnabled = false; dvDiag('socket lib UNAVAILABLE in VE VM -> staying on GE path'); return false end -- VE can't open sockets: stay on the GE path
		local ok, s = pcall(function() return dvSocketLib.udp() end)
		if not ok or not s then dvDiag('socket.udp() FAILED: '..tostring(s)); return false end
		s:settimeout(0)
		local okp, errp = pcall(function() s:setpeername('127.0.0.1', dvPort) end)
		dvDiag('socket opened; setpeername ok='..tostring(okp)..(okp and '' or (' err='..tostring(errp)))..' -> 127.0.0.1:'..tostring(dvPort))
		dvSock = s
		if dvHadSock then
			-- REOPENED socket (a send threw and dvClose'd the old one) = a NEW source port on the SAME
			-- VM. The launcher pins one port per sid and silently drops others, so re-run the GE-side
			-- registration: the fresh 'Va' clears the stale pin (Core.cpp) and the next packet
			-- re-learns this socket's port. (A full VE VM reload doesn't need this -- veReady re-runs
			-- dvSetupVehicle anyway; this covers the same-VM error-recovery path.)
			obj:queueGameEngineLua("if positionGE and positionGE.dvSetupVehicle then positionGE.dvSetupVehicle("..obj:getID()..") end")
			dvDiag('socket REOPENED -> requested GE re-registration')
			dvConfirmed = false -- new source port: the launcher must ack it again (re-registration triggers one)
			dvProbes = 0
		end
		dvHadSock = true
	end
	local ok, ret = pcall(function() return dvSock:send(tag..':'..dvSid..':'..payload) end)
	if not ok then dvDiag(tag..' dvSock:send THREW: '..tostring(ret)); dvClose(); return false end
	if ret == nil then dvDiag(tag..' dvSock:send soft-failed (nil return) -> GE path'); return false end
	-- Drain one pending datagram every send (non-blocking). The launcher keepalive-acks ~1/s
	-- forever; without this the acks would slowly fill the socket's OS receive buffer after
	-- confirmation (benign today -- acks are the only inbound -- but a latent trap for any future
	-- bidirectional use). While unconfirmed, the same read doubles as the ack check.
	local okr, ack = pcall(function() return dvSock:receive() end)
	if not dvConfirmed then
		-- Probe phase: the packet went out, but until the launcher acks this socket we must assume
		-- nobody is listening. Any datagram back (registration ack / keepalive) = confirmed.
		if okr and ack then
			dvConfirmed = true
			dvProbes = 0
			dvDiag('direct socket CONFIRMED by launcher ack -> GE fallback stops')
		else
			dvProbes = dvProbes + 1
			if dvProbes > DV_CONFIRM_MAX_PROBES then
				dvEnabled = false
				dvClose()
				dvDiag('NO launcher ack after '..DV_CONFIRM_MAX_PROBES..' sends -> reverting to GE path (launcher lacks the direct socket or port '..tostring(dvPort)..' is blocked)')
			end
			return false -- caller keeps using the GE path; this send was only a probe
		end
	end
	dvDiag('DIRECT SOCKET SEND OK ['..tag..'] (bytes='..tostring(ret)..'); further '..tag..' sends silent', 'sendok:'..tag)
	return true
end

function doSendPosRot(useSendTime)
	profBegin()
	-- this attempts to send a full table of nan if there are several rapid instability causing VE lua to break after next vehicle reload, seems to be caused by a game issue
	-- GC: computed in place into the reusable W pool. getPositionXYZ / getDirectionVector*XYZ were
	-- verified IN-GAME to return values bit-identical to their vec3-returning counterparts (worst
	-- delta 0 over 801 samples at 17 significant digits), so this cannot shift what goes on the wire.
	local rot, rvel, cog, pos, vel = W.rot, W.rvel, W.cog, W.pos, W.vel
	W.dir:set(obj:getDirectionVectorXYZ())
	W.dir:setScaled(-1)
	W.dirUp:set(obj:getDirectionVectorUpXYZ())
	rot:setFromDir(W.dir, W.dirUp)

	rvel:set(smoothRvel.x, smoothRvel.y, smoothRvel.z) -- COPY: smoothRvel IS the smoother's own state
	rvel:setRotate(rot)

	cog:setRotate(rot, velocityVE.cogRel)
	pos:set(obj:getPositionXYZ())
	pos:setAdd(cog)
	vel:setCross(cog, rvel)          -- vel = cog x rvel ...
	vel:setAdd(smoothVel)            -- ... + smoothVel (addition commutes, cog is not clobbered)
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

	vel:setScaled(simSpeedReal)
	rvel:setScaled(simSpeedReal)

	local t = posSendTbl
	t.pos[1], t.pos[2], t.pos[3] = pos.x, pos.y, pos.z
	t.vel[1], t.vel[2], t.vel[3] = vel.x, vel.y, vel.z
	t.rot[1], t.rot[2], t.rot[3], t.rot[4] = rot.x, rot.y, rot.z, rot.w
	t.rvel[1], t.rvel[2], t.rvel[3] = rvel.x, rvel.y, rvel.z
	t.tim = useSendTime and sendClock or timer
	t.ping = ownPing + lastDT
	local payload = jsonEncode(t)
	if not dvSend('Zp', payload) then -- direct vehicle socket (#245); false = off/unavailable -> GE proxy path
		obj:queueGameEngineLua("positionGE.sendVehiclePosRot(\'"..payload.."\', "..obj:getID()..")") -- Send it
	end

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
	-- Resync the wire clock on (re)start so tim stays continuous across a physicsRateSend toggle --
	-- but FORWARD-ONLY. During a GE stall the physics thread keeps stepping, so sendClock can run
	-- AHEAD of the frame-driven timer; if a >0.5s GE hitch decays the arm, the old `sendClock = timer`
	-- re-arm jumped the wire time BACKWARD, and every receiver then rejected our packets at its
	-- out-of-order guard (tim <= last) until its copy of our clock caught up = our ghost froze on
	-- every other machine for exactly the jump duration.
	if selfSendTimer <= 0 then sendClock = max(sendClock, timer) end
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
	sd.recvCount = sd.recvCount + 1  -- a packet reached this VE (stall diag: distinguishes GE->VE delivery gaps from rejects)

	local pr   = jsonDecode(data)
	if not pr then return end -- malformed packet: don't kill this vehicle's VE Lua VM

	-- A vehicle receiving position data is a REMOTE ghost: it must never physics-SLEEP. The engine
	-- stops calling a sleeping vehicle's updateGFX entirely, and the mailbox apply is a PULL from
	-- updateGFX -- so a ghost that parks long enough to doze off can never apply again and stays
	-- frozen when its owner drives away (diagnosed live: 110s of GE receiving 10/s while this VM ran
	-- ZERO frames; the watchdog snapped it 24x without waking it). Disabling sleep here (first packet
	-- arrives while the fresh-spawned vehicle is guaranteed awake) prevents it ever dozing. Same API
	-- the game's own playerController uses to keep the walking unicycle responsive. Re-armed after a
	-- reset by onReset in case the engine clears the flag on reload. Guarded per the fork's API rule.
	if not sleepDisabled then
		sleepDisabled = true
		if obj.setSleepingEnabled then obj:setSleepingEnabled(false) end
	end
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
	if remoteData.timer > tim then
		-- Sender time went backwards. A SMALL step is a genuinely out-of-order/duplicate packet
		-- (UDP reorder) -> drop it, count it for the stall diag. A LARGE backward jump (>3s --
		-- the same reset rule the GE smoother uses) means the sender's clock RESTARTED (vehicle
		-- Lua reload / send-clock re-base): every future packet would be rejected and this ghost
		-- would freeze until manually reset (the stall the posApplyStall diag names "sender clock
		-- reset"). Re-base the predictor on this packet instead: zero the deltas so the acc math
		-- below can't spike, and let the timeOffset jump guard in updateGFX snap the time smoother.
		if (remoteData.timer - tim) <= 3 then sd.rejectCount = sd.rejectCount + 1; return end
		remoteData.vel = vel
		remoteData.rvel = rvel
		remoteVelSmoother:set(vel)
		remoteRvelSmoother:set(rvel)
		remoteAccSmoother:reset()
		remoteRaccSmoother:reset()
		P.acc = nil
		P.racc = nil
		remoteData.timer = tim -- remoteDT below floors at 0.001; with the deltas zeroed acc/racc stay 0
	end

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
	sd.recRealT = sd.realTimer     -- real-time stamp of this accepted packet (stall diag: real vs sim gap)
	remoteData.localSimspeed = math.min(simspeedfraction or 1, 25)

	profEnd('setVehiclePosRot')
end

-- Called from GE (positionGE.veReady) when this VM belongs to a REMOTE vehicle. Needed on a VE VM
-- RELOAD (vehicle edit/config change), where waiting for the first received packet isn't enough:
-- with the mailbox transport that packet only arrives AFTER setMailboxApply is re-pushed, so the
-- anti-sleep must be re-armed independently of the data path.
local function setRemote()
	if not sleepDisabled then
		sleepDisabled = true
		if obj.setSleepingEnabled then obj:setSleepingEnabled(false) end
	end
end

local function onInit()
	enablePhysicsStepHook()
	-- Announce this VM (re)load to GE so it re-pushes the per-vehicle flags (mailbox/profiling/
	-- diag/sendHz, + remote type/anti-sleep for ghosts). A vehicle EDIT reloads this VM in place
	-- and wipes all of those to defaults -- without this callback a ghost froze permanently after
	-- its owner swapped vehicle/config (see positionGE.veReady for the full story).
	obj:queueGameEngineLua("if positionGE and positionGE.veReady then positionGE.veReady("..obj:getID()..") end")
end

local function setGameSpeed(speed)
	simSpeedReal = speed
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
M.setGameSpeed       = setGameSpeed -- 4.22: GE pushes the sim speed here (used when building the send)
M.setProfiling       = setProfiling
M.setMailboxApply    = setMailboxApply
M.setApplyStallDiag  = setApplyStallDiag
M.setSendHz          = setSendHz
M.setTrackedHold     = setTrackedHold
M.setRemote          = setRemote -- GE veReady: (re)arm remote-ghost state after a VE VM (re)load
M.setDirectVehicle   = setDirectVehicle -- #245: GE enables/disables the direct send socket for this own vehicle
M.dvSend             = dvSend           -- #245: other VE modules (MPInputsVE) send tagged latest-wins data over this vehicle's ONE shared socket
M.dvIsActive         = function() return dvEnabled and dvConfirmed end -- #245: other VE modules gate direct-only behaviors (chunked deformation, input resync) on the socket being CONFIRMED by a launcher ack, not merely enabled


return M
