-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- nodesGE API.
--- Author of this documentation is Titch
--- @module nodesGE
--- @usage applyElectrics(...) -- internal access
--- @usage nodesGE.handle(...) -- external access


local M = {}

-- LAN: 'Xn' damage snapshots move only when a mod asks for one (BeamNG.Earth's sendDamage); see nodesVE.

--- Called on specified interval by MPUpdatesGE to simulate our own tick event to collect data.
local function tick()
	for i,v in pairs(MPVehicleGE.getPlayerVehicleObjects(MPConfig.getPlayerServerID())) do
		if v then
			v:queueLuaCommand("if nodesVE then nodesVE.getBreakGroups() end") -- LAN: guard -- the VE VM may not have loaded its extensions yet (spawn/recover); an unguarded call FATALs it
		end
	end
end


--- Wraps up node data from player own vehicles and sends it to the server.
-- INTERNAL USE
-- @param data table The node data from VE
-- @param gameVehicleID number The vehicle ID according to the local game
local function sendNodes(data, gameVehicleID)
	if MPGameNetwork.launcherConnected() then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		if serverVehicleID and MPVehicleGE.isOwn(gameVehicleID) then
			MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Xn',serverVehicleID,data))
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
			if not decodedData then return end -- LAN: guard a nil decode before indexing/re-encoding
			if decodedData.vehID then
				decodedData.vehID = MPVehicleGE.getServerVehicleID(decodedData.vehID)
			end
			data = jsonEncode(decodedData)

			MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Xc',serverVehicleID,data))
		end
	end
end


--- This function serves to send the nodes data received for another players vehicle from GE to VE, where it is handled.
-- @param data table The data to be applied as nodes
-- @param serverVehicleID string The VehicleID according to the server.
local function applyNodes(data, serverVehicleID)
	local gameVehicleID = MPVehicleGE.getGameVehicleID(serverVehicleID) or -1
	local veh = getObjectByID(gameVehicleID)
	if veh then
		veh:queueLuaCommand("if nodesVE then local ok, err = pcall(nodesVE.applyNodes, mime.unb64(\'".. MPHelpers.b64encode(data) .."\')) if not ok then log('E', 'nodesVE.applyNodes', tostring(err)) end end") -- LAN: pcall -- an error in a queued command kills this ghost's vehicle Lua and its sync for the session
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


--- Handles raw node and break group packets received from other players vehicles. Disassembles and sends it to either applyNodes() or applyBreakGroups()
-- @param rawData string The raw message data.
local function handle(rawData)
	local code, serverVehicleID, data = string.match(rawData, "^(%a)%:(%d+%-%d+)%:(.*)")

	local veh = MPVehicleGE.getVehicles()[serverVehicleID]

	if not veh or veh.isLocal then
		return
	end

	if code == "n" then
		applyNodes(data, serverVehicleID)
	elseif code == "g" then
		applyBreakGroups(data, serverVehicleID)
	elseif code == "c" then
		MPControllerGE.applyControllerData(data, serverVehicleID)
	elseif code == "d" then
		-- LAN: the chunked full-deformation variant ('Xd', #245, removed 2026-07-09) from a peer still running an old
		-- mod: discard SILENTLY -- a warning per packet would spam hundreds of lines per snapshot.
	else
		log('W', 'handle', "Received unknown packet '"..tostring(code).."'! ".. rawData)
	end
end



M.tick       = tick
M.handle     = handle
M.sendNodes  = sendNodes
M.applyNodes = applyNodes
M.onInit = function() setExtensionUnloadMode(M, "manual") end

M.sendBreakGroups  = sendBreakGroups
M.sendControllerData  = sendControllerData

return M
