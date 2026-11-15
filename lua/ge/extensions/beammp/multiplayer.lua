-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- beammp_multiplayer API.
--- Author of this documentation is Titch
--- @module beammp_multiplayer
--- @usage modifiedGetDriverData(veh) -- internal access
--- @usage beammp_multiplayer.onWorldReadyState(1) -- external access

local M = {state={}}



local originalGetDriverData
local original_onInstabilityDetected
local original_markerInteraction_onPreRender
local addedMarkerState -- LAN p13h120: this module put 'multiplayer' into the game's list of game states that have map markers
local mapMarkersApplied -- LAN p13h120: the optimizeMapMarkers value applied in this session (nil = not in a session)


--- Custom GetDriverData for allowing the getting of the right hand door or not for passenger aspects.
--- @param veh userdata The vehicle data
--- @return unknown
local function modifiedGetDriverData(veh)
	if not veh then return nil end
	local caller = debug.getinfo(2).name
	if caller and caller == "getDoorsidePosRot" and veh.mpVehicleType and veh.mpVehicleType == 'R' then
		local id, right = core_camera.getDriverDataById(veh and veh:getID())
		return id, not right
	end
	return core_camera.getDriverDataById(veh and veh:getID())
end


-- 0.40 keeps one unicycle per local player and deactivates it on entering a car.
-- Delete that inactive local object so the existing destroy event removes it on peers too.
local function onVehicleActiveChanged(vehicleID, active)
	if active or not (MPCoreNetwork and MPCoreNetwork.isMPSession()) then return end
	local mpVehicle = MPVehicleGE.getVehicleByGameID(vehicleID)
	if mpVehicle and not mpVehicle.isLocal then return end
	if not (gameplay_walk and gameplay_walk.onSerialize) then return end
	local walkData = gameplay_walk.onSerialize()
	for _, unicycleID in pairs(walkData and walkData.unicycleIds or {}) do
		if unicycleID == vehicleID then
			local unicycle = getObjectByID(vehicleID)
			if unicycle then unicycle:delete() end
			return
		end
	end
end


--- A custom onInstabilityDetected function to prevent the freezing / pausing of the game for when in MP session.
--- The engine passes the unstable vehicle's ID here (the old "jbeamFilename" name was misleading).
--- @param vid number The id of the vehicle that became unstable
local function modified_onInstabilityDetected(vid)
	log('W', "onInstabilityDetected", "Instability detected for vehicle " .. tostring(vid))
	-- LAN: with instability pausing disabled, the diverging physics would otherwise
	-- run to NaN and the engine would hard-reset the car back to its SPAWN point
	-- (the "high-impact collision teleports me to where I started" bug). Instead we
	-- recover it IN PLACE so it stabilises right where it crashed. Guarded so a
	-- future BeamNG API change can't break the mod.
	if not vid then return end
	local veh = be:getObjectByID(vid)
	if not veh then return end
	-- Recover REMOTE vehicles in place too (p13h90): pre-0.39.4 the engine only paused on
	-- instability, so leaving remote cars to the position sync was fine -- but 0.39.4 DELETES a
	-- vehicle that goes unstable twice within its timer window, which is how a remote player's
	-- unstable prop became a permanent grey ball. recoverInPlace resets the NaN'd physics where
	-- it stands; the position sync immediately re-drives a remote car afterwards.
	veh:queueLuaCommand("if recovery and recovery.recoverInPlace then recovery.recoverInPlace() end")
end


--- Hides BeamNG's built-in freeroam mission/POI markers. They're irrelevant for LAN
--- MP (you can't start singleplayer missions in a session) and the big map re-shows
--- them. Guarded so a BeamNG API change can't break the mod.
local function hideAllMissionMarkers()
	if not gameplay_playmodeMarkers then return end
	for _, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
		local marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
		if marker then marker:hide() end
	end
end


--- LAN p13h120: one switch for BeamNG's own map markers in a session (setting optimizeMapMarkers).
--- ON (default): no markers. gameplay_markerInteraction.onPreRender becomes a no-op (ported from Olrosse/BeamMP
--- minimap_lag_workaround: its per-frame marker work is an FPS sink) and the markers are hidden.
--- OFF: markers as in Freeroam -- gas stations with their refuel prompt, the points on the big map. Leaving the
--- stock onPreRender in place is not enough for that: the game keeps markers only in the game states listed in
--- gameplay_playmodeMarkers.validPlaymodeMarkersStates (freeroam and career; playmodeMarkers.lua: "this can be
--- adjusted to allow other states") and clears them every frame in any other, and a session runs in the state
--- 'multiplayer'. So that state is added to the list for the session.
--- Called at post-join and when the setting changes during a session; restoreMapMarkers undoes both at leave.
--- Every engine call is guarded so a BeamNG API change can't break the mod.
local function applyMapMarkerMode()
	if not gameplay_markerInteraction then return end
	local optimize = settings.getValue("optimizeMapMarkers") ~= false
	local changedLive = mapMarkersApplied ~= nil and mapMarkersApplied ~= optimize
	local states = gameplay_playmodeMarkers and gameplay_playmodeMarkers.validPlaymodeMarkersStates
	if optimize then
		if addedMarkerState and type(states) == 'table' then states.multiplayer = nil end
		addedMarkerState = nil
		-- Seamless map switches repeat post-join without unloading this extension.
		if gameplay_markerInteraction.onPreRender ~= nop then
			original_markerInteraction_onPreRender = gameplay_markerInteraction.onPreRender
		end
		gameplay_markerInteraction.onPreRender = nop
		if gameplay_markerInteraction.setMarkersVisibleTemporary then
			gameplay_markerInteraction.setMarkersVisibleTemporary(false)
		end
		hideAllMissionMarkers()
		if changedLive then
			-- switched on while markers were live: drop them and an open refuel/mission prompt, as the game
			-- does itself in a state without markers
			if gameplay_markerInteraction.closeViewDetailPrompt then gameplay_markerInteraction.closeViewDetailPrompt(true) end
			if gameplay_playmodeMarkers and gameplay_playmodeMarkers.clear then gameplay_playmodeMarkers.clear() end
		end
	else
		if original_markerInteraction_onPreRender then
			gameplay_markerInteraction.onPreRender = original_markerInteraction_onPreRender
			original_markerInteraction_onPreRender = nil
		end
		if gameplay_markerInteraction.setMarkersVisibleTemporary then
			gameplay_markerInteraction.setMarkersVisibleTemporary(true)
		end
		if type(states) == 'table' and not states.multiplayer then
			states.multiplayer = true
			addedMarkerState = true
		end
		if changedLive and gameplay_markerInteraction.setForceReevaluateOpenPrompt then
			gameplay_markerInteraction.setForceReevaluateOpenPrompt() -- already parked at a pump: offer the prompt
		end
	end
	if changedLive and freeroam_bigMapPoiProvider and freeroam_bigMapPoiProvider.forceSend then
		freeroam_bigMapPoiProvider.forceSend() -- the big map's point list follows the same game-state list
	end
	mapMarkersApplied = optimize
end


--- Undoes applyMapMarkerMode when the session ends.
local function restoreMapMarkers()
	-- restore BeamNG's per-frame marker processing if we disabled it on join
	if original_markerInteraction_onPreRender and gameplay_markerInteraction then
		gameplay_markerInteraction.onPreRender = original_markerInteraction_onPreRender
		if gameplay_markerInteraction.setMarkersVisibleTemporary then
			gameplay_markerInteraction.setMarkersVisibleTemporary(true)
		end
		original_markerInteraction_onPreRender = nil
	end
	local states = gameplay_playmodeMarkers and gameplay_playmodeMarkers.validPlaymodeMarkersStates
	if addedMarkerState and type(states) == 'table' then states.multiplayer = nil end
	addedMarkerState = nil
	mapMarkersApplied = nil
end


--- The option applies at once: no rejoin needed (p13h120).
local function onSettingsChanged()
	if mapMarkersApplied == nil then return end -- not in a session
	if (settings.getValue("optimizeMapMarkers") ~= false) ~= mapMarkersApplied then applyMapMarkerMode() end
end


--- Called when the Big Map is loaded by the user.
local function onBigMapActivated() -- don't pause the game when opening the Big Map
	if MPCoreNetwork and MPCoreNetwork.isMPSession() then
		simTimeAuthority.pause(false)
		if mapMarkersApplied ~= false then hideAllMissionMarkers() end -- LAN p13h120: not when the markers are wanted
	end
end


--- Called when the Big Map is closed -- re-hide the markers the map re-shows.
local function onDeactivateBigMapCallback()
	if MPCoreNetwork and MPCoreNetwork.isMPSession() then
		if mapMarkersApplied ~= false then hideAllMissionMarkers() end -- LAN p13h120
	end
end


--- onUpdate is a game eventloop function. It is called each frame by the game engine.
--- This is the main processing thread of BeamMP in the game
--- @param dt float
local function onUpdate(dt)
	if MPCoreNetwork and MPCoreNetwork.isMPSession() then
		--log('W', 'onUpdate', 'Running modified beammp code!')
		if core_camera.getDriverData ~= modifiedGetDriverData then
			log('W', 'onUpdate', 'Setting modifiedGetDriverData')
			originalGetDriverData = core_camera.getDriverData
			core_camera.getDriverData = modifiedGetDriverData
		end
		if worldReadyState == 0 then
			-- Workaround for worldReadyState not being set properly if there are no vehicles
			serverConnection.onCameraHandlerSetInitial()
			extensions.hook('onCameraHandlerSet')
			--commands.setGameCamera()
		end
	end
end




--- This function/event is triggered internally upon the joining on a map.
local function runPostJoin()
	-- Save the original engine instability handler so onServerLeave can restore it.
	-- Re-entrancy guard: on a rejoin (runPostJoin called again without a full Lua
	-- reload) onInstabilityDetected may already be OUR function -- don't capture that
	-- as the "original" or the real handler is lost forever.
	if onInstabilityDetected ~= modified_onInstabilityDetected then
		original_onInstabilityDetected = onInstabilityDetected
	end

	-- LAN (default on): suppress BeamNG's instability pause + spawn-point teleport and
	-- recover the car in place instead (see modified_onInstabilityDetected). Honour the
	-- toggle -- the previous code force-enabled this regardless of the setting.
	if settings.getValue("disableInstabilityPausing") ~= false then
		onInstabilityDetected = modified_onInstabilityDetected
	end

	-- Map markers (gas stations, mission and POI markers): off for performance by default, or as
	-- in Freeroam -- setting optimizeMapMarkers, see applyMapMarkerMode. Undone in onServerLeave.
	applyMapMarkerMode()
end


--- This function is called when the user leaves a server as part of cleanup 
local function onServerLeave()
	if original_onInstabilityDetected then onInstabilityDetected = original_onInstabilityDetected end
	if originalGetDriverData then core_camera.getDriverData = originalGetDriverData end
	restoreMapMarkers()
end


--- This function is called by BeamNG upon the change of the world ready state.
--- 1 = World is loading
--- 2 = World is ready, You are about to have the loading screen disappear. This is the time to show anything you have.
--- @param state number The state in numerical form.
local function onWorldReadyState(state)
	log('W', 'onWorldReadyState', state)
	if state == 2 then
		if MPCoreNetwork and MPCoreNetwork.isMPSession() then
			log('M', 'onWorldReadyState', 'Setting game state to BeamMP multiplayer.')
			local spawnDefaultGroups = { "CameraSpawnPoints", "PlayerSpawnPoints", "PlayerDropPoints", "spawnpoints" }
			if not commands.isFreeCamera() then
				commands.setFreeCamera()
			end
			for i, v in pairs(spawnDefaultGroups) do
				if scenetree.findObject(spawnDefaultGroups[i]) then
					local spawngroupPoint = scenetree.findObject(spawnDefaultGroups[i]):getRandom()
					if not spawngroupPoint then
						break
					end
					local sgPpointID = scenetree.findObjectById(spawngroupPoint:getId())
					if not sgPpointID then
						break
					end
					if sgPpointID and sgPpointID.obj then
						local spawnPos = sgPpointID.obj:getPosition()
						core_camera.setPosRot(0, spawnPos.x, spawnPos.y, spawnPos.z + 3, 0, 0, 0, 0)
						return
					end
				end
			end

			local defaultSpawn = scenetree.findObject(setSpawnpoint.loadDefaultSpawnpoint())
			if defaultSpawn and defaultSpawn.obj then
				local spawnPos = defaultSpawn.obj:getPosition()
				core_camera.setPosRot(0, spawnPos.x, spawnPos.y, spawnPos.z + 3, 0, 0, 0, 0)
				return
			end
		end
	end
end

-- public interface
M.onUpdate          = onUpdate
M.onWorldReadyState = onWorldReadyState
M.onBigMapActivated = onBigMapActivated
M.onDeactivateBigMapCallback = onDeactivateBigMapCallback
-- 0.39.4 and 0.40.1's stock onInstabilityDetected offer extensions first refusal:
--   extensions.hook('onInstabilityDetected', vid, returnData)
-- and, if unhandled, ghosts + safe-teleports the vehicle -- and DELETES it when it goes
-- unstable AGAIN within the timer window. The global replacement in runPostJoin no longer
-- intercepts reliably on 0.39.4 (the stock body demonstrably ran in the p13h89 session that
-- produced the grey-ball report), so claim the instability here on the sanctioned path. The
-- global override is kept as a harmless belt for older game builds.
local function onInstabilityDetectedHook(vid, returnData)
	if not (MPCoreNetwork and MPCoreNetwork.isMPSession()) then return end
	if settings.getValue("disableInstabilityPausing") == false then return end -- toggle off = let the stock flow run
	if type(returnData) == 'table' then returnData.instabilityHandled = true end
	modified_onInstabilityDetected(vid)
end

M.onInstabilityDetected = onInstabilityDetectedHook
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onBeamMPPostJoin = runPostJoin
M.onBeamMPServerLeave = onServerLeave
M.onSettingsChanged = onSettingsChanged -- LAN p13h120: optimizeMapMarkers applies live
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
