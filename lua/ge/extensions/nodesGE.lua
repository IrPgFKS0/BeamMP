-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- nodesGE API.
--- Author of this documentation is Titch
--- @module nodesGE
--- @usage nodesGE.handle(...) -- external access


local M = {}

-- NOTE: the experimental full node/beam deformation sync ('Xn' blobs + the #245 'Xd' chunked
-- variant, fullTick/sendNodes/applyNodes) was REMOVED 2026-07-09 -- never reliable, intrinsically
-- CPU-heavy on both ends (see nodesVE header). This module now carries break groups ('Xg') and
-- synced-controller data ('Xc') only. 'Xn'/'Xd' from old peers are discarded silently below.


--- Called on specified interval by MPUpdatesGE to simulate our own tick event to collect data.
local function tick()
	for i,v in pairs(MPVehicleGE.getPlayerVehicleObjects(MPConfig.getPlayerServerID())) do
		if v then
			v:queueLuaCommand("if nodesVE then nodesVE.getBreakGroups() end") -- guard: the VE VM may not have loaded its extensions yet (spawn/recover) -- an unguarded call FATALs it
		end
	end
end


--- Wraps break group data of player own vehicles and sends it to the server.
-- INTERNAL USE
-- @param data table The break group data from VE
-- @param gameVehicleID number The vehicle ID according to the local game
local function sendBreakGroups(data, gameVehicleID)
	if MPGameNetwork.launcherConnected() then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		if serverVehicleID and MPVehicleGE.isOwn(gameVehicleID) then
			MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Xg',serverVehicleID,data))
		end
	end
end


local function sendControllerData(data, gameVehicleID)
	if MPGameNetwork.launcherConnected() then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		if serverVehicleID and MPVehicleGE.isOwn(gameVehicleID) then
			local decodedData = jsonDecode(data)
			if not decodedData then return end -- guard a nil decode before indexing/re-encoding
			if decodedData.vehID then
				decodedData.vehID = MPVehicleGE.getServerVehicleID(decodedData.vehID)
			end
			data = jsonEncode(decodedData)

			MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Xc',serverVehicleID,data))
		end
	end
end


--- This function serves to send the break groups data received for another players vehicle from GE to VE, where it is handled.
-- @param data table The data to be applied as break groups
-- @param serverVehicleID string The VehicleID according to the server.
local function applyBreakGroups(data, serverVehicleID)
	local gameVehicleID = MPVehicleGE.getGameVehicleID(serverVehicleID) or -1
	local veh = getObjectByID(gameVehicleID)
	if veh then
		veh:queueLuaCommand("if nodesVE then nodesVE.applyBreakGroups(mime.unb64(\'".. MPHelpers.b64encode(data) .."\')) end")
	end
end


--- Handles raw break group / controller packets received from other players vehicles.
-- @param rawData string The raw message data.
local function handle(rawData)
	local code, serverVehicleID, data = string.match(rawData, "^(%a)%:(%d+%-%d+)%:(.*)")

	local veh = MPVehicleGE.getVehicles()[serverVehicleID]

	if not veh or veh.isLocal then
		return
	end

	if code == "g" then
		applyBreakGroups(data, serverVehicleID)
	elseif code == "c" then
		MPControllerGE.applyControllerData(data, serverVehicleID)
	elseif code == "n" or code == "d" then
		-- Full-deformation packets (legacy 'Xn' blob / chunked 'Xd') from a peer still running an
		-- old mod with the removed feature enabled: discard SILENTLY -- warning per packet would
		-- spam ~100KB lines ('Xn') or hundreds of lines per snapshot ('Xd').
	else
		log('W', 'handle', "Received unknown packet '"..tostring(code).."'! ".. rawData)
	end
end



M.tick       = tick
M.handle     = handle
M.onInit = function() setExtensionUnloadMode(M, "manual") end

M.sendBreakGroups  = sendBreakGroups
M.sendControllerData  = sendControllerData

return M
