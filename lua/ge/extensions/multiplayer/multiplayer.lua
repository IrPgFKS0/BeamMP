-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- multiplayer_multiplayer API.
--- Author of this documentation is Titch
--- @module multiplayer_multiplayer
--- @usage modifiedGetDriverData(veh) -- internal access
--- @usage multiplayer_multiplayer.onWorldReadyState(1) -- external access

local M = {state={}}



local originalGetDriverData
local originalToggleWalkingMode
local originalOnVehicleSwitched
local original_onInstabilityDetected
local original_markerInteraction_onPreRender


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


--- Custom walking mode function that handles the getting of the unicycle and handles the deletion of it.
local function modifiedToggleWalkingMode()
	local unicycle = (gameplay_walk.getCurrentUnicycle or gameplay_walk.getPlayerUnicycle)() -- renamed getCurrentUnicycle in BeamNG 0.39; fallback keeps 0.38 compat
	if unicycle ~= nil then
		local veh = gameplay_walk.getVehicleInFront()
		if not veh or veh:getJBeamFilename() == "unicycle" then return end
	end
	originalToggleWalkingMode()
	
	-- If we were in a unicycle and entered a vehicle, delete it so it disappears for other players as well
	if unicycle ~= nil then
		unicycle:delete()
	end
end

--- 0.39: switching vehicles no longer routes through toggleWalkingMode, so hook onVehicleSwitched
--- too -- if we left a unicycle for a real vehicle, delete the unicycle so it also disappears for
--- every other player (upstream 0.39-compat #918).
local function modifiedOnVehicleSwitched(oldId, newId, player)
	local unicycle = scenetree.findObjectById(oldId)
	local walkData = gameplay_walk.onSerialize()

	originalOnVehicleSwitched(oldId, newId, player)
	if unicycle ~= nil and walkData.unicycleId == oldId then
		unicycle:delete()
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
	-- recover it IN PLACE so it stabilises right where it crashed. Only do this for
	-- our own vehicles; remote cars are handled by the position sync. Guarded so a
	-- future BeamNG API change can't break the mod.
	if not vid then return end
	local veh = be:getObjectByID(vid)
	if not veh then return end
	if MPVehicleGE and MPVehicleGE.isOwn and not MPVehicleGE.isOwn(vid) then return end
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


--- Called when the Big Map is loaded by the user.
local function onBigMapActivated() -- don't pause the game when opening the Big Map
	if MPCoreNetwork and MPCoreNetwork.isMPSession() then
		simTimeAuthority.pause(false)
		hideAllMissionMarkers()
	end
end


--- Called when the Big Map is closed -- re-hide the markers the map re-shows.
local function onDeactivateBigMapCallback()
	if MPCoreNetwork and MPCoreNetwork.isMPSession() then
		hideAllMissionMarkers()
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
		if gameplay_walk then
			if gameplay_walk.toggleWalkingMode ~= modifiedToggleWalkingMode then
				log('W', 'onUpdate', 'Setting modifiedToggleWalkingMode')
				originalToggleWalkingMode = gameplay_walk.toggleWalkingMode
				gameplay_walk.toggleWalkingMode = modifiedToggleWalkingMode
			end
			if gameplay_walk.onVehicleSwitched ~= modifiedOnVehicleSwitched then
				log('W', 'onUpdate', 'Setting modifiedOnVehicleSwitched')
				originalOnVehicleSwitched = gameplay_walk.onVehicleSwitched
				gameplay_walk.onVehicleSwitched = modifiedOnVehicleSwitched
			end
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

	-- Minimap/marker perf (ported from Olrosse/BeamMP minimap_lag_workaround): BeamNG
	-- runs gameplay_markerInteraction.onPreRender EVERY frame (mission/POI marker
	-- raycasts), a known FPS sink in MP and useless for LAN driving. Swap it for a
	-- no-op and hide the markers; restored in onServerLeave. Toggle-gated (default on)
	-- so the win can be A/B'd, and fully guarded against a BeamNG API change.
	if settings.getValue("optimizeMapMarkers") ~= false and gameplay_markerInteraction then
		original_markerInteraction_onPreRender = gameplay_markerInteraction.onPreRender
		gameplay_markerInteraction.onPreRender = nop
		if gameplay_markerInteraction.setMarkersVisibleTemporary then
			gameplay_markerInteraction.setMarkersVisibleTemporary(false)
		end
		hideAllMissionMarkers()
	end
end


--- This function is called when the user leaves a server as part of cleanup 
local function onServerLeave()
	if original_onInstabilityDetected then onInstabilityDetected = original_onInstabilityDetected end
	if originalGetDriverData then core_camera.getDriverData = originalGetDriverData end
	if originalToggleWalkingMode and gameplay_walk and gameplay_walk.toggleWalkingMode then gameplay_walk.toggleWalkingMode = originalToggleWalkingMode end
	if originalOnVehicleSwitched and gameplay_walk and gameplay_walk.onVehicleSwitched then gameplay_walk.onVehicleSwitched = originalOnVehicleSwitched end
	-- restore BeamNG's per-frame marker processing if we disabled it on join
	if original_markerInteraction_onPreRender and gameplay_markerInteraction then
		gameplay_markerInteraction.onPreRender = original_markerInteraction_onPreRender
		if gameplay_markerInteraction.setMarkersVisibleTemporary then
			gameplay_markerInteraction.setMarkersVisibleTemporary(true)
		end
		original_markerInteraction_onPreRender = nil
	end
end


--- This function is called by BeamNG upon the change of the world ready state.
--- 1 = World is loading
--- 2 = World is ready, You are about to have the loading screen disappear. This is the time to show anything you have.
--- @param state number The state in numerical form.
local function onWorldReadyState(state)
	log('W', 'onWorldReadyState', state)
	if state == 2 then
		if MPCoreNetwork and MPCoreNetwork.isMPSession() then
			log('M', 'onWorldReadyState', 'Setting game state to multiplayer.')
			core_gamestate.setGameState('multiplayer', 'multiplayer', 'multiplayer')
			local spawnDefaultGroups = { "CameraSpawnPoints", "PlayerSpawnPoints", "PlayerDropPoints", "spawnpoints" }

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
M.runPostJoin = runPostJoin
M.onServerLeave = onServerLeave
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
