-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPDebug API.
--- Author of this documentation is Titch
--- @module MPDebug
--- @usage getPlayerNames() -- internal access
--- @usage MPDebug.tpPlayerToPos(...) -- external access


local M = {}


--- Teleports the players vehicle to a specified position.
--- @param targetPos vec3 The target position to teleport the player to. Format: {x, y, z}
local function tpPlayerToPos(targetPos)
	local activeVehicle = getPlayerVehicle(0)

	if activeVehicle then

		local targetVehRot = quatFromDir(vec3(activeVehicle:getDirectionVector()), vec3(activeVehicle:getDirectionVectorUp()))

		local vec3Pos = vec3(targetPos[1], targetPos[2], targetPos[3])

		spawn.safeTeleport(activeVehicle, vec3Pos, targetVehRot, false)
		return
	else
		log('M', 'tpPlayerToPos', 'no active vehicle')
	end
end


--- Returns the names of all players in the current session.
--- @return table names A table where the key is the username and the value is an owned vehicle ID (can be ignored).
local function getPlayerNames()
	if not MPVehicleGE then return {} end

	local names = {}

	for k,v in pairs(MPVehicleGE.getNicknameMap() or {}) do
		names[v] = k
	end
	return names
end


M.dependencies = {"ui_imgui"}

local gui_module = require("ge/extensions/editor/api/gui")
local gui = {setupEditorGuiTheme = nop}
local im = ui_imgui

local ui_strings = {}

--- Retrieves translations from a JSON file and caches them?
--- @param _ any Unused parameter.
--- @param content string The content of the JSON file.
local function getTranslations(_, content)
	local data = jsonDecode(content)
	if data and data[1] and data[1] == "translationFileUpdate" then
		local languageMap = require('utils/languageMap')
		local selectedLang = Lua:getSelectedLanguage()

		ui_strings = data[2] and data[2][selectedLang] and data[2][selectedLang]['translations'] or {}
		log('M', 'getTranslations', "language data received, cached "..languageMap.resolve(selectedLang) or "unknown language")
	end
end

--- Triggered by BeamNG when the lua mod is loaded by the modmanager system.
--- We use this to register our IMGUI windows.
local function onExtensionLoaded()
	gui_module.initialize(gui)
	gui.registerWindow("MPplayerList", im.ImVec2(256, 256))
	gui.registerWindow("MPspawnTeleport", im.ImVec2(256, 256))
	gui.registerWindow("MPnetworkPerf", im.ImVec2(256, 256))



	--guihooks.updateListener("beammpui", getTranslations)
	--core_modmanager.requestTranslations()
end


--- Draws the IMGUI player list.
local function drawPlayerList()
	if not gui.isWindowVisible("MPplayerList") then return end
	local players = MPVehicleGE.getPlayers()
	if tableIsEmpty(players) then return end
	gui.setupWindow("MPplayerList")
    im.SetNextWindowBgAlpha(0.4)
	im.Begin("MP Developer Tools")

	im.Columns(5, "Bar") -- gimme ein táblázat

	im.Text("Name") im.NextColumn()
	--im.Text("Ping") im.NextColumn()
	im.Text("") im.NextColumn()
	im.Text("") im.NextColumn()
	im.Text("") im.NextColumn()
	im.Text("") im.NextColumn()

	local listIndex = 1
	for playerID, player in pairs(players) do
		listIndex = listIndex+1

		if player.isLocal then im.TextColored(im.ImVec4(0.0, 1.0, 1.0, 1.0), player.name) --teal if current user
		else im.Text(player.name) end
		im.NextColumn()

		--im.Text(tostring(ping))
		--im.NextColumn()

		if im.Button("Camera##"..tostring(listIndex)) then MPVehicleGE.focusCameraOnPlayer(player.name) end
		im.NextColumn()

		if im.Button("GPS##"..tostring(listIndex)) then MPVehicleGE.groundmarkerToPlayer(player.name) end
		im.NextColumn()

		if im.Button("Follow##"..tostring(listIndex)) then MPVehicleGE.groundmarkerFollowPlayer(player.name) end
		im.NextColumn()

		if im.Button("Teleport##"..tostring(listIndex)) then MPVehicleGE.teleportVehToPlayer(player.name) end
		im.NextColumn()
	end

	im.Columns(1);
	im.End()
end

--- Draws the IMGUI Teleport / Spawning Menu
local function drawSpawnTeleport()
	if not gui.isWindowVisible("MPspawnTeleport") then return end
	if getMissionFilename() == "" then return end
	gui.setupWindow("MPspawnTeleport")
    --im.SetNextWindowBgAlpha(0.4)
	im.Begin("Teleport menu")


	local listIndex = 1
	im.Columns(2, "Bar");

	im.Text("Name") im.NextColumn()
	im.NextColumn()

	local spawnpoints = extensions.ui_uiNavi and extensions.ui_uiNavi.getSpawnpoints() or {}

	for _, point in pairs(spawnpoints) do
		listIndex = listIndex+1
		im.Text(tostring(ui_strings[point.translationId] or point.objectname))
		im.NextColumn()

		if im.Button("Teleport##"..tostring(listIndex)) then
			tpPlayerToPos(point.pos)
		end
		im.NextColumn()
	end

	im.Columns(1);
	im.End()
end




local var = {}
var.refresh_rate = 1.0 --in Hz
var.refresh_time = 0.0

var.sentCount = im.ArrayFloat(90)
var.sentSize = im.ArrayFloat(90)
var.receivedCount = im.ArrayFloat(90)
var.receivedSize = im.ArrayFloat(90)

var.values_offset = 0
var.last_offset = 0

local sentPacketCount = 0
local receivedPacketCount = 0
local sentPacketSize = 0
local receivedPacketSize = 0

-- Lightweight always-on sync overlay (separate accumulators so it doesn't fight
-- the draggable "Network Performance" window above, which resets the counters too).
local ov = { sent = 0, recv = 0, sentB = 0, recvB = 0, timer = 0, sentRate = 0, recvRate = 0, sentKB = 0, recvKB = 0,
	h25Total = 0, h50Total = 0, h100Total = 0, h250Total = 0, fMaxWorst = 0, invalidRawTotal = 0, fallbackTotal = 0 }

-- LAN: frame diagnostics belong to the renderer, not the network send-rate experiment.
-- dtReal is smoothed by BeamNG; only onUpdate's third argument measures the raw frame.
local fd = { active = false, clock = 0, sequence = 0, recentIntervals = {} }
-- LAN: 15 s intervals whose summary + worst detailed frame survive in /savelogs' mp_state.txt (two minutes).
local RETAINED_INTERVALS = 8
local diagnosticsEnabled, previousWallClock = false, nil
local snapshotModule, snapshotLoadError
local unavailableWarnings = {}
local snapshotOptions = { renderTimingTrackingEnabled = true, sceneComplexityTrackingEnabled = true }

local function finite(value)
	return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function positive(value)
	return finite(value) and value > 0
end

local function milliseconds(value)
	return finite(value) and value * 1000 or nil
end

local function newFrameInterval()
	return { intervalSeconds = 0, frameCount = 0, h25 = 0, h50 = 0, h100 = 0, h250 = 0,
		maxMs = 0, wallGapMaxMs = 0, invalidRawFrames = 0, fallbackFrames = 0, skippedFrames = 0,
		detailCount = 0, coalescedDetails = 0 }
end

-- Optional engine/context reads must never prevent the raw timing record. Failures are
-- attached to every affected event and warned once, rather than inventing zero metrics.
local function optionalContext(record, name, reader)
	local ok, result = false, 'API unavailable'
	if type(reader) == 'function' then ok, result = pcall(reader) end
	if ok and result ~= nil then return result end
	local err = ok and 'API returned no data' or tostring(result)
	record.contextErrors = record.contextErrors or {}
	record.contextErrors[name] = err
	if not unavailableWarnings[name] then
		unavailableWarnings[name] = true
		log('W', 'mpFrameContext', name .. ': ' .. err)
	end
end

local function captureFrameContext(record, dt)
	record.readStage = 'onUpdate; latest available engine metrics'
	record.level = optionalContext(record, 'level', getMissionFilename)
	record.isMultiplayer = optionalContext(record, 'isMultiplayer', MPCoreNetwork and MPCoreNetwork.isMPSession)
	record.vehicle = optionalContext(record, 'vehicle', function()
		if type(getPlayerVehicle) ~= 'function' then error('getPlayerVehicle unavailable') end
		local vehicle = getPlayerVehicle(0)
		if not vehicle then return { available = false } end
		local position = vehicle:getPosition()
		return { available = true, id = vehicle:getID(), model = vehicle:getJBeamFilename(),
			speedKph = vehicle:getVelocity():length() * 3.6,
			position = { x = position.x, y = position.y, z = position.z } }
	end)
	if not snapshotModule and not snapshotLoadError then
		local ok, result = pcall(require, 'ge/extensions/telemetry/performanceSpatialSnapshot')
		if ok and type(result) == 'table' and type(result.capture) == 'function' then
			snapshotModule = result
		else
			snapshotLoadError = ok and 'capture API unavailable' or tostring(result)
		end
	end
	record.snapshot = optionalContext(record, 'snapshot', function()
		if not snapshotModule then error(snapshotLoadError) end
		return snapshotModule.capture(record.level, 1 / dt, dt * 1000, nil, snapshotOptions)
	end)
	record.renderMemory = optionalContext(record, 'renderMemory', Engine and Engine.Render and Engine.Render.getMemoryInfo)
	record.focused = optionalContext(record, 'focused', Engine and Engine.isProgramFocused)
	record.luaHeapKiB = collectgarbage('count')
end

local function frameTiming(dt, source, dtReal, dtSim, dtRaw, wallGap)
	return { frameMs = dt * 1000, source = source, dtRealMs = milliseconds(dtReal),
		dtSimMs = milliseconds(dtSim), dtRawMs = milliseconds(dtRaw), wallGapMs = milliseconds(wallGap),
		sessionSeconds = fd.clock }
end

local function flushFrameDiagnostics(reason)
	local interval = fd.interval
	if not fd.active or not interval or (interval.frameCount == 0 and interval.skippedFrames == 0) then return end
	interval.reason = reason or 'flush'
	interval.session = fd.sequence
	interval.sessionSeconds = fd.clock
	interval.thresholdMs = fd.thresholdMs
	interval.detailIntervalSeconds = fd.detailIntervalSeconds
	fd.latestSummaryText = jsonEncode(interval)
	log('I', 'mpFrameSummary', fd.latestSummaryText)
	-- LAN: the session's worst detailed frame is usually a load frame (level load, vehicle spawn or reload:
	-- dtRaw clamps at 1000 ms there), so it would hide the driving hitch a /savelogs is taken for. Keep the
	-- worst detailed frame of each of the last RETAINED_INTERVALS intervals beside it (both parts are the exact
	-- emitted JSON; the interval's worst frame >= threshold always has a record: new maxima bypass the limit).
	fd.recentIntervals[#fd.recentIntervals + 1] = '{"summary":' .. fd.latestSummaryText
		.. ',"worstDetail":' .. (fd.intervalWorstDetailText or 'null') .. '}'
	while #fd.recentIntervals > RETAINED_INTERVALS do table.remove(fd.recentIntervals, 1) end
	fd.intervalWorstDetailText = nil
	-- Transport values are the latest one-second window; frame values cover the entire
	-- explicitly stated interval, including hitches that happened between health lines.
	log('I', 'mpSyncHealth', string.format(
		"%d synced | drift %.1fm, %d heals | in %d pkt/s %.1f KB/s, out %d pkt/s %.1f KB/s | applied %d/s, rejected %d (total %d) | FPS %d [transport/FPS lastWindow %.3fs] | frame max %dms, hitches>=50ms %d (total %d, worst %dms) [frame interval %.3fs, %d frames]",
		ov.synced or 0, ov.driftM or 0, ov.healTotal or 0,
		ov.recvRate or 0, ov.recvKB or 0, ov.sentRate or 0, ov.sentKB or 0,
		ov.applyRate or 0, ov.rejRate or 0, ov.rejTotal or 0, ov.fps or 0, ov.lastWindowSeconds or 0,
		interval.maxMs, interval.h50, ov.h50Total or 0, ov.fMaxWorst or 0, interval.intervalSeconds, interval.frameCount))
	fd.interval = newFrameInterval()
end

-- BeamNG buffers beamng.log. Keep only the latest emitted summary/detail so
-- /savelogs can synchronously preserve them in mp_state.txt before gathering logs.
-- This is a selected snapshot, not another history buffer or a new native capture.
local function getFrameDiagnosticsText()
	-- LAN: the latest detail is whatever qualified last (at 30 fps a 33 ms frame every second), so the stall a
	-- /savelogs was taken for would be displaced within a second; keep the session's worst detailed frame too.
	-- That worst frame is usually a load frame (level load, vehicle spawn or reload: dtRaw clamps at 1000 ms,
	-- and a spawn's vehicle context reports a teleport speed), so the worst detailed frame of each of the last
	-- RETAINED_INTERVALS intervals is listed too, oldest first: 'reproduce, then /savelogs' lands the driving
	-- hitch in one of them with its context, whatever else the session loaded.
	local text = '=== BeamMP latest frame diagnostics (selected snapshot, not full history) ===\n'
		.. 'mpFrameSummary: ' .. (fd.latestSummaryText or 'none captured in this session') .. '\n'
		.. 'mpFrameHitch: ' .. (fd.latestDetailText or 'none captured in this session') .. '\n'
		.. 'mpFrameHitchWorst: ' .. (fd.worstDetailText or 'none captured in this session')
	if #fd.recentIntervals == 0 then
		text = text .. '\nmpFrameInterval: none captured in this session'
	else
		for _, entry in ipairs(fd.recentIntervals) do text = text .. '\nmpFrameInterval: ' .. entry end
	end
	return text
end

local function updateDiagnosticLifecycle(showOverlay, logStats)
	if logStats ~= fd.active then
		if fd.active then
			flushFrameDiagnostics('disabled')
			log('I', 'mpFrameSession', jsonEncode({ event = 'end', session = fd.sequence, sessionSeconds = fd.clock }))
		else
			fd.clock, fd.lastDetailClock = 0, nil
			fd.latestSummaryText, fd.latestDetailText = nil, nil
			fd.worstDetailText, fd.worstDetailMs = nil, 0 -- the session's largest detailed frame (see getFrameDiagnosticsText)
			fd.recentIntervals, fd.intervalWorstDetailText = {}, nil -- per-interval worst records (see getFrameDiagnosticsText)
			fd.sequence = fd.sequence + 1
			fd.interval = newFrameInterval()
			local threshold = tonumber(settings.getValue('frameHitchLogThresholdMs'))
			local spacing = tonumber(settings.getValue('frameHitchDetailInterval'))
			fd.thresholdMs = positive(threshold) and threshold or 25
			fd.detailIntervalSeconds = positive(spacing) and spacing or 1
			log('I', 'mpFrameSession', jsonEncode({ event = 'start', session = fd.sequence,
				thresholdMs = fd.thresholdMs, detailIntervalSeconds = fd.detailIntervalSeconds,
				timing = 'dtRaw; wallGap then dtReal fallback when unavailable' }))
		end
		fd.active = logStats
		previousWallClock = nil -- the independent clock must not include disabled time
	end
	local enabled = showOverlay or logStats
	if enabled ~= diagnosticsEnabled then
		previousWallClock = nil
		ov.timer, ov.frames, ov.sent, ov.recv, ov.sentB, ov.recvB = 0, 0, 0, 0, 0, 0
		ov.fMaxCur, ov.h25Cur, ov.h50Cur, ov.h100Cur, ov.h250Cur = 0, 0, 0, 0, 0
		ov.lastHitchClock, ov.hitchGap = nil, nil
		if enabled and positionGE then
			-- These getters drain counters owned by positionGE. Discard activity while
			-- diagnostics were off so the first measured window has the right baseline.
			if positionGE.getApplyPosRate then positionGE.getApplyPosRate() end
			if positionGE.getApplyPosRejects then positionGE.getApplyPosRejects() end
			if positionGE.getDriftStats then positionGE.getDriftStats() end
		end
		diagnosticsEnabled = enabled
	end
	return enabled
end

local function readFrameTime(dtReal, dtRaw)
	local wallNow = os.clockhp and os.clockhp()
	local wallGap = finite(wallNow) and finite(previousWallClock) and (wallNow - previousWallClock) or nil
	previousWallClock = finite(wallNow) and wallNow or nil
	if not positive(wallGap) then wallGap = nil end
	local validRaw = positive(dtRaw)
	local dt, source = dtRaw, 'dtRaw'
	if not validRaw then
		ov.invalidRawTotal = (ov.invalidRawTotal or 0) + 1
		if fd.active then fd.interval.invalidRawFrames = fd.interval.invalidRawFrames + 1 end
		if wallGap then dt, source = wallGap, 'wallGapFallback'
		elseif positive(dtReal) then dt, source = dtReal, 'dtRealFallback'
		else dt, source = nil, 'unavailable' end
		if dt then
			ov.fallbackTotal = (ov.fallbackTotal or 0) + 1
			if fd.active then fd.interval.fallbackFrames = fd.interval.fallbackFrames + 1 end
		elseif fd.active then fd.interval.skippedFrames = fd.interval.skippedFrames + 1 end
	end
	if source ~= ov.frameSource then
		if source ~= 'dtRaw' or ov.frameSource then
			log(source == 'dtRaw' and 'I' or 'W', 'mpFrameClock', jsonEncode({ source = source, previous = ov.frameSource }))
		end
		ov.frameSource = source
	end
	return dt, source, wallGap
end

local function recordFrame(dt, source, dtReal, dtSim, dtRaw, wallGap)
	local frameMs = dt * 1000
	ov.clock = (ov.clock or 0) + dt
	ov.fMaxCur = math.max(ov.fMaxCur or 0, frameMs)
	ov.fMaxWorst = math.max(ov.fMaxWorst or 0, frameMs)
	-- The fixed buckets always describe the full population, independently of the
	-- configurable detailed-event threshold and the network send rate.
	if frameMs >= 25 then ov.h25Cur = (ov.h25Cur or 0) + 1; ov.h25Total = (ov.h25Total or 0) + 1 end
	if frameMs >= 50 then ov.h50Cur = (ov.h50Cur or 0) + 1; ov.h50Total = (ov.h50Total or 0) + 1 end
	if frameMs >= 100 then ov.h100Cur = (ov.h100Cur or 0) + 1; ov.h100Total = (ov.h100Total or 0) + 1 end
	if frameMs >= 250 then ov.h250Cur = (ov.h250Cur or 0) + 1; ov.h250Total = (ov.h250Total or 0) + 1 end
	if frameMs >= 50 then
		if ov.lastHitchClock then
			local gap = ov.clock - ov.lastHitchClock
			ov.hitchGap = ov.hitchGap and (ov.hitchGap * 0.7 + gap * 0.3) or gap
		end
		ov.lastHitchClock = ov.clock
	end
	if not fd.active then return end
	fd.clock = fd.clock + dt
	local interval = fd.interval
	interval.intervalSeconds = interval.intervalSeconds + dt
	interval.frameCount = interval.frameCount + 1
	if wallGap then interval.wallGapMaxMs = math.max(interval.wallGapMaxMs, wallGap * 1000) end
	if frameMs >= 25 then interval.h25 = interval.h25 + 1 end
	if frameMs >= 50 then interval.h50 = interval.h50 + 1 end
	if frameMs >= 100 then interval.h100 = interval.h100 + 1 end
	if frameMs >= 250 then interval.h250 = interval.h250 + 1 end
	local newIntervalMax = frameMs > interval.maxMs
	if newIntervalMax then
		interval.maxMs = frameMs
		interval.worstFrame = frameTiming(dt, source, dtReal, dtSim, dtRaw, wallGap)
	end
	if frameMs >= fd.thresholdMs then
		-- LAN: a frame that sets a new interval maximum always gets its context record, rate limit or not.
		-- Live check 2026-10-22: a 43 ms frame took the one-second detail slot and the 268 ms stall right
		-- after it was coalesced, leaving the interval's WORST frame -- the one a stall investigation needs
		-- the CPU/GPU/streaming context for -- with timing only. Equal-length sustained frames set the
		-- maximum once, so the bound on detail records per interval is unchanged for them.
		if newIntervalMax or not fd.lastDetailClock or fd.clock - fd.lastDetailClock + 1e-9 >= fd.detailIntervalSeconds then
			local record = frameTiming(dt, source, dtReal, dtSim, dtRaw, wallGap)
			record.session = fd.sequence
			record.thresholdMs = fd.thresholdMs
			record.newIntervalMax = newIntervalMax or nil
			captureFrameContext(record, dt)
			fd.latestDetailText = jsonEncode(record)
			if frameMs > (fd.worstDetailMs or 0) then fd.worstDetailMs, fd.worstDetailText = frameMs, fd.latestDetailText end
			if newIntervalMax then fd.intervalWorstDetailText = fd.latestDetailText end -- this interval's worst, for the ring
			log('I', 'mpFrameHitch', fd.latestDetailText)
			fd.lastDetailClock = fd.clock
			interval.detailCount = interval.detailCount + 1
		else
			interval.coalescedDetails = interval.coalescedDetails + 1
		end
	end
end

local function avgData(data)
	local sum, max = 0, 0
	
	for i=0, im.GetLengthArrayFloat(data) do
		sum = sum + data[i]
		if data[i] > max then max = data[i] end
	end
	return sum/im.GetLengthArrayFloat(data), max
end

local function drawPlotWithAvg(format, data, offset, lastVal)
	local avgSent, maxSent = avgData(data)
	im.PlotLines1(string.format(format, lastVal), data, im.GetLengthArrayFloat(data), offset, string.format("avg %.2f, max %i", avgSent or 0, maxSent or 0), 0.0, maxSent, im.ImVec2(0,80))
end

local function drawNetworkPerf()
	if not gui.isWindowVisible("MPnetworkPerf") then return end
	gui.setupWindow("MPnetworkPerf")
    --im.SetNextWindowBgAlpha(0.4)
	im.Begin("Network Performance")


		-- Tip: If your float aren't contiguous but part of a structure, you can pass a pointer to your first float and the sizeof() of your structure in the Stride parameter.
		if refresh_time == 0.0 then var.refresh_time = im.GetTime() end


		if var.refresh_time < im.GetTime() then
			var.sentCount[var.values_offset] = sentPacketCount
			sentPacketCount = 0
			var.receivedCount[var.values_offset] = receivedPacketCount
			receivedPacketCount = 0

			var.sentSize[var.values_offset] = sentPacketSize
			sentPacketSize = 0
			var.receivedSize[var.values_offset] = receivedPacketSize
			receivedPacketSize = 0

			var.last_offset = var.values_offset
			var.values_offset = (var.values_offset + 1) % (im.GetLengthArrayFloat(var.sentCount))
			var.refresh_time = var.refresh_time + 1.0 / var.refresh_rate
		end


		drawPlotWithAvg("Sent packets: %i/s", var.sentCount, var.values_offset, var.sentCount[var.last_offset])
		drawPlotWithAvg("Sent bytes: %.2f KB/s", var.sentSize, var.values_offset, var.sentSize[var.last_offset]/1000.0)

		drawPlotWithAvg("Received packets: %i/s", var.receivedCount, var.values_offset, var.receivedCount[var.last_offset])
		drawPlotWithAvg("Received bytes: %.2f KB/s", var.receivedSize, var.values_offset, var.receivedSize[var.last_offset]/1000.0)

	im.End()
end

--- Used to call the UI to show itself.
---@usage MPDebug.showUI()
local function showUI()
	gui.showWindow("MPplayerList")
	gui.showWindow("MPspawnTeleport")
	gui.showWindow("MPnetworkPerf")
end
--- Used to call the UI to hide itself.
---@usage MPDebug.hideUI()
local function hideUI()
	gui.hideWindow("MPplayerList")
	gui.hideWindow("MPspawnTeleport")
	gui.hideWindow("MPnetworkPerf")
end

function MP_Console(show)
	if show and show == 1 then
		showUI()
	elseif show == 0 then
		hideUI()
	end
end

--- Lightweight always-on overlay: synced (remote) vehicle count + live network
--- packet/byte rates. Toggle via the "showSyncStats" setting (Options >
--- Multiplayer > "Show sync stats overlay"). Cheap: one tiny imgui window/frame.
local function drawSyncStatsOverlay(dtReal, dtSim, dtRaw)
	local showOverlay = settings.getValue("showSyncStats") == true
	local logStats = settings.getValue("logSyncStats") == true
	if not updateDiagnosticLifecycle(showOverlay, logStats) then return end
	local dt, source, wallGap = readFrameTime(dtReal, dtRaw)
	if not dt then return end -- no valid clock: counted as skipped, never poison future windows
	ov.timer = ov.timer + dt
	ov.frames = (ov.frames or 0) + 1
	recordFrame(dt, source, dtReal, dtSim, dtRaw, wallGap)

	-- Reset the peak/persistent trackers whenever the send rate is changed, so each tuning step
	-- (e.g. dropping to 30Hz) gets a fresh "is it still bad?" window instead of carrying old history.
	local hz = tonumber(settings.getValue("physRateSendHz")) or 30
	if hz ~= ov.lastHz then
		ov.lastHz = hz
		ov.applyPeak, ov.applyWorst, ov.applyBadTime = 0, nil, 0
		ov.fpsPeak, ov.fpsWorst, ov.fpsBadTime = 0, nil, 0
		ov.driftBadTime, ov.driftWorst, ov.healTotal = 0, nil, 0
		ov.rejTotal = 0
	end

	local synced = 0
	if MPVehicleGE and MPVehicleGE.getVehicles then
		for _, v in pairs(MPVehicleGE.getVehicles()) do
			if v and not v.isLocal and v.isSpawned then synced = synced + 1 end
		end
	end

	ov.synced = synced

	if ov.timer >= 1.0 then
		-- ONE evaluation per window, every count normalised by how long the window really was. The old
		-- `timer - 1.0` carry-over did two things wrong exactly when it mattered (a stall): a window that
		-- spanned 1.4 s reported its counts as per-second rates (the 2026-10-05 host log has a row reading
		-- "in 124 pkt/s" where the steady state is ~90), and any single frame >= 1 s left >= 1 s in the
		-- timer, so the very next frame was evaluated as a window of its own -- one frame of data read as
		-- "FPS 1, applied 0/s", tripping fpsBad/applyBad and poisoning the [dropped to N] tails.
		local win = ov.timer
		ov.lastWindowSeconds = win
		ov.sentRate, ov.recvRate = math.floor(ov.sent / win + 0.5), math.floor(ov.recv / win + 0.5)
		ov.sentKB, ov.recvKB = ov.sentB / 1000 / win, ov.recvB / 1000 / win
		ov.sent, ov.recv, ov.sentB, ov.recvB = 0, 0, 0, 0
		ov.fps = math.floor(ov.frames / win + 0.5); ov.frames = 0
		local applied = (positionGE and positionGE.getApplyPosRate and positionGE.getApplyPosRate()) or 0
		ov.applyRate = math.floor(applied / win + 0.5)
		-- rejected/s: packets the receive path REFUSED (unknown vehicle / malformed pose). Any
		-- nonzero here is breakage (mismatched mod builds between machines is the classic cause) --
		-- this row exists because the p13h82 seam rejected 100% of packets while every other row
		-- looked healthy. Tracked with its own persistent total so a burst is visible after the fact.
		local rejected = (positionGE and positionGE.getApplyPosRejects and positionGE.getApplyPosRejects()) or 0
		ov.rejNow = rejected -- the red condition: ANY rejection in this window, however long it was
		ov.rejRate = math.floor(rejected / win + 0.5)
		ov.rejTotal = (ov.rejTotal or 0) + rejected
		-- frame hitches this window (per-frame accounting above)
		ov.fMax = ov.fMaxCur or 0; ov.fMaxCur = 0
		ov.h25, ov.h50, ov.h100, ov.h250 = ov.h25Cur or 0, ov.h50Cur or 0, ov.h100Cur or 0, ov.h250Cur or 0
		ov.h25Cur, ov.h50Cur, ov.h100Cur, ov.h250Cur = 0, 0, 0, 0
		-- Per-second bad-state eval + peak/persistent tracking (badTime in whole seconds).
		-- "Bad" = a sharp drop below a slowly-decaying baseline of the best recent value, so it
		-- adapts to the chosen send rate / car count / a genuinely slow machine instead of a fixed line.
		ov.applyPeak = math.max((ov.applyPeak or 0) * 0.95, ov.applyRate)
		ov.applyBad = synced > 0 and (ov.applyPeak or 0) > 5 and ov.applyRate < ov.applyPeak * 0.4 -- applies <40% of baseline: relay not delivering OR a local FPS hitch (disambiguated against fpsBad in the hints)
		if ov.applyBad then
			ov.applyBadTime = (ov.applyBadTime or 0) + 1
			ov.applyWorst = math.min(ov.applyWorst or ov.applyRate, ov.applyRate)
		end
		ov.fpsPeak = math.max((ov.fpsPeak or 0) * 0.95, ov.fps)
		ov.fpsBad = (ov.fpsPeak or 0) > 10 and ov.fps < ov.fpsPeak * 0.6 -- FPS dropped >40% from baseline = one core spiking
		if ov.fpsBad then
			ov.fpsBadTime = (ov.fpsBadTime or 0) + 1
			ov.fpsWorst = math.min(ov.fpsWorst or ov.fps, ov.fps)
		end
		-- Drift = the DIRECT symptom (told-vs-actual gap of remote ghosts) from the positionGE watchdog,
		-- which the indirect apply-rate/FPS metrics miss during a traffic flood. Bad = a self-heal
		-- correction actually fired, OR drift well past the few-metre healthy predictor lead.
		local md, hc = 0, 0
		if positionGE and positionGE.getDriftStats then md, hc = positionGE.getDriftStats() end
		ov.driftM = md
		ov.healTotal = (ov.healTotal or 0) + (hc or 0)
		ov.driftBad = synced > 0 and ((hc or 0) > 0 or (md or 0) > 8)
		if ov.driftBad then
			ov.driftBadTime = (ov.driftBadTime or 0) + 1
			ov.driftWorst = math.max(ov.driftWorst or 0, md or 0)
		end
		ov.timer = 0 -- the window is fully accounted for; a fresh one starts now (see the note at the top of this block)
	end

	if fd.active and fd.interval.intervalSeconds >= 15 then flushFrameDiagnostics("interval") end

	if not showOverlay then return end -- /synclog can run with the overlay hidden; nothing more to draw

	ov.RED = ov.RED or im.ImVec4(1.0, 0.35, 0.35, 1.0)
	im.SetNextWindowBgAlpha(0.7) -- darker / more opaque backdrop for readability (was 0.35); tweak 0.0-1.0
	-- FirstUseEver (not Always) so (14,90) is just the INITIAL spot -- the user can then drag the panel
	-- (NoMove + NoInputs removed) and imgui remembers where they put it. Drag anywhere on the body.
	im.SetNextWindowPos(im.ImVec2(14, 90), im.Cond_FirstUseEver)
	im.Begin("BeamMPSyncStats", nil, bit.bor(im.WindowFlags_NoTitleBar, im.WindowFlags_NoResize,
		im.WindowFlags_AlwaysAutoResize, im.WindowFlags_NoNav, im.WindowFlags_NoFocusOnAppearing))
	local sendMode = (settings.getValue("physicsRateSend") ~= false) and string.format("%d Hz", hz) or "per-frame"
	if settings.getValue("directVehicleSocket") == true then sendMode = sendMode .. " +direct" end
	im.Text(string.format("Synced vehicles: %d   (send %s)", synced, sendMode))
	im.Text(string.format("Net in:  %d pkt/s  (%.1f KB/s)", ov.recvRate, ov.recvKB))
	im.Text(string.format("Net out: %d pkt/s  (%.1f KB/s)", ov.sentRate, ov.sentKB))
	if settings.getValue("directVehicleSocket") == true then
		-- the DV socket sends from VE Lua straight to the launcher, so those packets never pass
		-- the GE counters above -- say so rather than let 'Net out' read as the whole story
		im.Text("         (own-car pos/inputs ride the direct socket -- not counted above)")
	end

	-- Pos applied = positions applied/sec. It reflects BOTH relay delivery AND local apply throughput
	-- (the apply runs per render frame), so read it WITH the FPS row: a drop while FPS is FINE = the
	-- relay isn't delivering; a drop alongside an FPS drop = a local hitch, not the relay. The [dip/bad]
	-- tail persists so you can see how deep + how long it went even after it recovers.
	local aTxt = string.format("Pos applied: %d/s", ov.applyRate or 0)
	if (ov.applyBadTime or 0) > 0 then aTxt = aTxt .. string.format("   [dipped to %d/s, bad %ds total]", ov.applyWorst or 0, ov.applyBadTime) end
	if ov.applyBad then im.TextColored(ov.RED, aTxt) else im.Text(aTxt) end
	-- rejections are never normal: red whenever this second's count is nonzero, and keep a
	-- [total] tail so a burst that already ended is still visible on the overlay
	if (ov.rejTotal or 0) > 0 then
		local rTxt = string.format("Pos REJECTED: %d/s   [total %d]", ov.rejRate or 0, ov.rejTotal or 0)
		if (ov.rejNow or 0) > 0 then im.TextColored(ov.RED, rTxt) else im.Text(rTxt) end
		if (ov.rejNow or 0) > 0 then im.TextColored(ov.RED, ">> packets REJECTED: usually mismatched BeamMP builds between machines -- update BOTH from the same release bundle") end
	end

	-- FPS = main-thread health (one core). Red while spiking down; tail persists like above.
	local fTxt = string.format("FPS: %d", ov.fps or 0)
	if (ov.fpsBadTime or 0) > 0 then fTxt = fTxt .. string.format("   [dropped to %d, bad %ds total]", ov.fpsWorst or 0, ov.fpsBadTime) end
	if ov.fpsBad then im.TextColored(ov.RED, fTxt) else im.Text(fTxt) end

	-- Frame hitches use raw frame duration (dtRaw), with a visible fallback if unavailable, which the FPS average smooths away. Always shows
	-- the longest frame of the last window; red when one crossed 100 ms. The tail keeps the count, the worst
	-- one and how far apart they come -- "a 200 ms frame every ~2.6 s" is the pattern this row exists for.
	local hTxt = string.format("Frame max: %d ms (%s)", ov.fMax or 0, ov.frameSource == "dtRaw" and "raw" or tostring(ov.frameSource))
	if (ov.h50Total or 0) > 0 then
		hTxt = hTxt .. string.format("   [>=50ms: %d/window, total %d, worst %d ms%s]", ov.h50 or 0, ov.h50Total,
			ov.fMaxWorst or 0, ov.hitchGap and string.format(", ~%.1fs apart", ov.hitchGap) or "")
	end
	hTxt = hTxt .. string.format("   [total >=25/100/250ms: %d/%d/%d]", ov.h25Total or 0, ov.h100Total or 0, ov.h250Total or 0)
	if (ov.h100 or 0) > 0 then im.TextColored(ov.RED, hTxt) else im.Text(hTxt) end

	-- Ghost drift = the actual sync symptom (told-vs-actual). A few metres is the normal predictor
	-- lead (healthy); red = a correction fired or drift went well past that. [N corrections] = the
	-- self-heal resyncs since the last rate change. This is what stays green-while-broken if omitted.
	local dTxt = string.format("Ghost drift: %.1fm", ov.driftM or 0)
	if (ov.healTotal or 0) > 0 then dTxt = dTxt .. string.format("   [%d corrections]", ov.healTotal) end
	if ov.driftBad then im.TextColored(ov.RED, dTxt) else im.Text(dTxt) end

	-- Only call it "relay starving" when FPS is FINE -- otherwise the apply-rate drop is the local
	-- hitch below, and "lower send rate" would be the wrong fix.
	if ov.applyBad and not ov.fpsBad then im.TextColored(ov.RED, ">> relay starving (positions not arriving, FPS is fine): LOWER 'Position send rate' or cut AI/traffic cars") end
	if ov.fpsBad then im.TextColored(ov.RED, ">> FPS hitch: trim the mod set / AI-traffic / heavy vehicles (LOAD, not the netcode -- a >1s hitch freezes the remote ghosts THIS machine draws)") end
	if ov.driftBad then im.TextColored(ov.RED, ">> ghost drift/heals: usually a LOAD/FPS hitch (trim mods + AI-traffic) or relay overload (LOWER 'Position send rate') -- never RAISE the rate") end
	if (ov.h100 or 0) > 0 then im.TextColored(ov.RED, ">> frame hitch: enable /synclog, reproduce, then /savelogs for raw timing + rendering/streaming context; timing alone does not identify the cause") end
	im.End()
end

--- Draws Imgui playerlist, spawnTeleport and NetworkPerf.
--- This is the main processing thread of BeamMP in the game
--- @param dt float
local function onUpdate(dtReal, dtSim, dtRaw)
	drawPlayerList()
	drawSpawnTeleport()
	drawNetworkPerf()
	drawSyncStatsOverlay(dtReal, dtSim, dtRaw)
end


--- Updates the count and size of sent packets.
--- @param[opt] bytes number The size of the packet in bytes.
local function packetSent(bytes)
	sentPacketCount = sentPacketCount+1
	sentPacketSize = sentPacketSize + (bytes or 0)
	ov.sent = ov.sent + 1; ov.sentB = ov.sentB + (bytes or 0)
end
--- Updates the count and size of received packets.
--- @param[opt] bytes number The size of the packet in bytes.
local function packetReceived(bytes)
	receivedPacketCount = receivedPacketCount+1
	receivedPacketSize = receivedPacketSize + (bytes or 0)
	ov.recv = ov.recv + 1; ov.recvB = ov.recvB + (bytes or 0)
end


M.onExtensionLoaded		= onExtensionLoaded
M.onUpdate				= onUpdate
M.showUI				= showUI
M.hideUI				= hideUI


M.packetSent = packetSent
M.packetReceived = packetReceived
M.flushFrameDiagnostics = flushFrameDiagnostics
M.getFrameDiagnosticsText = getFrameDiagnosticsText
M.getSyncStats = function() return ov end -- read-only view of the overlay's accumulators for probes (smoke gate, tools/ge-guard)
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
