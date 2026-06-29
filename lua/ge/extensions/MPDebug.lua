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
	local activeVehicle = be:getPlayerVehicle(0)

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
local ov = { sent = 0, recv = 0, sentB = 0, recvB = 0, timer = 0, sentRate = 0, recvRate = 0, sentKB = 0, recvKB = 0 }

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
local function drawSyncStatsOverlay(dt)
	local showOverlay = settings.getValue("showSyncStats") == true
	local logStats = settings.getValue("logSyncStats") == true
	if not showOverlay and not logStats then return end
	ov.timer = ov.timer + (dt or 0)
	ov.frames = (ov.frames or 0) + 1

	-- Reset the peak/persistent trackers whenever the send rate is changed, so each tuning step
	-- (e.g. dropping to 30Hz) gets a fresh "is it still bad?" window instead of carrying old history.
	local hz = tonumber(settings.getValue("physRateSendHz")) or 30
	if hz ~= ov.lastHz then
		ov.lastHz = hz
		ov.applyPeak, ov.applyWorst, ov.applyBadTime = 0, nil, 0
		ov.fpsPeak, ov.fpsWorst, ov.fpsBadTime = 0, nil, 0
		ov.driftBadTime, ov.driftWorst, ov.healTotal = 0, nil, 0
	end

	local synced = 0
	if MPVehicleGE and MPVehicleGE.getVehicles then
		for _, v in pairs(MPVehicleGE.getVehicles()) do
			if v and not v.isLocal and v.isSpawned then synced = synced + 1 end
		end
	end

	if ov.timer >= 1.0 then
		ov.sentRate, ov.recvRate = ov.sent, ov.recv
		ov.sentKB, ov.recvKB = ov.sentB/1000, ov.recvB/1000
		ov.sent, ov.recv, ov.sentB, ov.recvB = 0, 0, 0, 0
		ov.fps = ov.frames; ov.frames = 0
		ov.applyRate = (positionGE and positionGE.getApplyPosRate and positionGE.getApplyPosRate()) or 0
		-- Per-second bad-state eval + peak/persistent tracking (badTime in whole seconds).
		-- "Bad" = a sharp drop below a slowly-decaying baseline of the best recent value, so it
		-- adapts to the chosen send rate / car count / a genuinely slow machine instead of a fixed line.
		ov.applyPeak = math.max((ov.applyPeak or 0) * 0.95, ov.applyRate)
		ov.applyBad = synced > 0 and (ov.applyPeak or 0) > 5 and ov.applyRate < ov.applyPeak * 0.4 -- received <40% of baseline = relay starving
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
		-- Optional log trail (/synclog -> logSyncStats): mirror this health line to beamng.log every
		-- ~15s so a /savelogs after an intermittent drift episode captures what the overlay was showing
		-- over time. Runs even with the overlay hidden; off by default.
		if logStats then
			ov.logTimer = (ov.logTimer or 0) + 1
			if ov.logTimer >= 15 then
				ov.logTimer = 0
				log('I', 'mpSyncHealth', string.format(
					"%d synced | drift %.1fm, %d heals | in %d pkt/s %.1f KB/s, out %d pkt/s %.1f KB/s | applied %d/s | FPS %d",
					synced, ov.driftM or 0, ov.healTotal or 0,
					ov.recvRate or 0, ov.recvKB or 0, ov.sentRate or 0, ov.sentKB or 0,
					ov.applyRate or 0, ov.fps or 0))
			end
		end
		ov.timer = ov.timer - 1.0
	end

	if not showOverlay then return end -- /synclog can run with the overlay hidden; nothing more to draw

	ov.RED = ov.RED or im.ImVec4(1.0, 0.35, 0.35, 1.0)
	im.SetNextWindowBgAlpha(0.7) -- darker / more opaque backdrop for readability (was 0.35); tweak 0.0-1.0
	-- FirstUseEver (not Always) so (14,90) is just the INITIAL spot -- the user can then drag the panel
	-- (NoMove + NoInputs removed) and imgui remembers where they put it. Drag anywhere on the body.
	im.SetNextWindowPos(im.ImVec2(14, 90), im.Cond_FirstUseEver)
	im.Begin("BeamMPSyncStats", nil, bit.bor(im.WindowFlags_NoTitleBar, im.WindowFlags_NoResize,
		im.WindowFlags_AlwaysAutoResize, im.WindowFlags_NoNav, im.WindowFlags_NoFocusOnAppearing))
	im.Text(string.format("Synced vehicles: %d   (send %d Hz)", synced, hz))
	im.Text(string.format("Net in:  %d pkt/s  (%.1f KB/s)", ov.recvRate, ov.recvKB))
	im.Text(string.format("Net out: %d pkt/s  (%.1f KB/s)", ov.sentRate, ov.sentKB))

	-- Pos applied = receive rate (relay health). Red while starving; the [dip/bad] tail persists so
	-- you can see how deep + how long it went even after it recovers -- that's the tuning signal.
	local aTxt = string.format("Pos applied: %d/s", ov.applyRate or 0)
	if (ov.applyBadTime or 0) > 0 then aTxt = aTxt .. string.format("   [dipped to %d/s, bad %ds total]", ov.applyWorst or 0, ov.applyBadTime) end
	if ov.applyBad then im.TextColored(ov.RED, aTxt) else im.Text(aTxt) end

	-- FPS = main-thread health (one core). Red while spiking down; tail persists like above.
	local fTxt = string.format("FPS: %d", ov.fps or 0)
	if (ov.fpsBadTime or 0) > 0 then fTxt = fTxt .. string.format("   [dropped to %d, bad %ds total]", ov.fpsWorst or 0, ov.fpsBadTime) end
	if ov.fpsBad then im.TextColored(ov.RED, fTxt) else im.Text(fTxt) end

	-- Ghost drift = the actual sync symptom (told-vs-actual). A few metres is the normal predictor
	-- lead (healthy); red = a correction fired or drift went well past that. [N corrections] = the
	-- self-heal resyncs since the last rate change. This is what stays green-while-broken if omitted.
	local dTxt = string.format("Ghost drift: %.1fm", ov.driftM or 0)
	if (ov.healTotal or 0) > 0 then dTxt = dTxt .. string.format("   [%d corrections]", ov.healTotal) end
	if ov.driftBad then im.TextColored(ov.RED, dTxt) else im.Text(dTxt) end

	if ov.applyBad then im.TextColored(ov.RED, ">> relay starving: lower 'Position send rate'") end
	if ov.fpsBad then im.TextColored(ov.RED, ">> FPS spike: enable 'Low-GC predictor' (fastPredict)") end
	if ov.driftBad then im.TextColored(ov.RED, ">> ghost drifting/correcting: cut AI/traffic count or LOWER 'Position send rate' (overload, not too-low a rate)") end
	im.End()
end

--- Draws Imgui playerlist, spawnTeleport and NetworkPerf.
--- This is the main processing thread of BeamMP in the game
--- @param dt float
local function onUpdate(dt)
	drawPlayerList()
	drawSpawnTeleport()
	drawNetworkPerf()
	drawSyncStatsOverlay(dt)
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
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
