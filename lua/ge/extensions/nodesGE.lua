-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- nodesGE API.
--- Author of this documentation is Titch
--- @module nodesGE
--- @usage applyElectrics(...) -- internal access
--- @usage nodesGE.handle(...) -- external access


local M = {}


--- Called on specified interval by MPUpdatesGE to simulate our own tick event to collect data.
local function tick()
	local ownMap = MPVehicleGE.getOwnMap()
	for i,v in pairs(ownMap) do
		local veh = be:getObjectByID(i)
		if veh then
			--veh:queueLuaCommand("nodesVE.getNodes()")
			veh:queueLuaCommand("if nodesVE then nodesVE.getBreakGroups() end")
		end
	end
end


--- EXPERIMENTAL (LAN-only build): full soft-body deformation sync.
--- Sends the entire node/beam state (positions + per-beam deformation) for our
--- own vehicles so remote clients match our deformation, not just which parts
--- broke off. This is HEAVY (serializes every node + beam), so it is driven by
--- a separate low-rate timer in MPUpdatesGE (fullNodesTickrate). Tune the rate
--- there, or comment the call to disable.
local function fullTick()
	local ownMap = MPVehicleGE.getOwnMap()
	for i,v in pairs(ownMap) do
		local veh = be:getObjectByID(i)
		if veh then
			veh:queueLuaCommand("if nodesVE then nodesVE.getNodes() end")
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
			MPGameNetwork.send('Xn:'..serverVehicleID..":"..data)
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
			MPGameNetwork.send('Xg:'..serverVehicleID..":"..data)
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
			MPGameNetwork.send('Xc:'..serverVehicleID..":"..data)
		end
	end
end


--- This function serves to send the nodes data received for another players vehicle from GE to VE, where it is handled.
-- @param data table The data to be applied as nodes
-- @param serverVehicleID string The VehicleID according to the server.
local function applyNodes(data, serverVehicleID)
	local gameVehicleID = MPVehicleGE.getGameVehicleID(serverVehicleID) or -1
	local veh = be:getObjectByID(gameVehicleID)
	if veh then
		veh:queueLuaCommand("if nodesVE then nodesVE.applyNodes(mime.unb64(\'".. MPHelpers.b64encode(data) .."\')) end")
	end
end


--- This function serves to send the break groups data received for another players vehicle from GE to VE, where it is handled.
-- @param data table The data to be applied as break groups
-- @param serverVehicleID string The VehicleID according to the server.
local function applyBreakGroups(data, serverVehicleID)
	local gameVehicleID = MPVehicleGE.getGameVehicleID(serverVehicleID) or -1
	local veh = be:getObjectByID(gameVehicleID)
	if veh then
		veh:queueLuaCommand("if nodesVE then nodesVE.applyBreakGroups(mime.unb64(\'".. MPHelpers.b64encode(data) .."\')) end")
	end
end


-- ==== #245 chunked full-deformation reassembly ('Xd', sent by nodesVE.getNodes/updateGFX) ====
-- One in-progress snapshot per sending vehicle; a chunk from a NEWER generation (or a different
-- chunk count) replaces an incomplete older one -- latest-wins at snapshot granularity, so a lost
-- UDP chunk simply discards that snapshot and the next 2Hz one self-corrects. A snapshot is only
-- ever delivered COMPLETE (never torn). Memory is bounded (DF_MAX_CHUNKS chunks per sender, freed
-- on completion/replacement; a sender that vanishes mid-snapshot leaves at most one partial until
-- the session ends -- acceptable for this experimental feature).
local dfAsm = {}
local DF_MAX_CHUNKS = 256 -- must match nodesVE.DF_MAX_CHUNKS
local dfDiagged = false
local function handleDeformChunk(data, serverVehicleID)
	local gen, i, n, part = string.match(data, "^(%d+),(%d+),(%d+)%:(.*)")
	gen, i, n = tonumber(gen), tonumber(i), tonumber(n)
	if not (gen and i and n and part) or n < 1 or n > DF_MAX_CHUNKS or i < 1 or i > n then return end
	local a = dfAsm[serverVehicleID]
	if not a or a.gen ~= gen or a.total ~= n then
		a = { gen = gen, total = n, got = 0, parts = {} }
		dfAsm[serverVehicleID] = a
	end
	if a.parts[i] then return end -- duplicate chunk
	a.parts[i] = part
	a.got = a.got + 1
	if a.got == a.total then
		dfAsm[serverVehicleID] = nil
		local full = table.concat(a.parts)
		if not dfDiagged then dfDiagged = true; log('I', 'nodesGE', 'chunked deformation assembled: '..serverVehicleID..' gen='..gen..' ('..n..' chunks, '..#full..' bytes); further assemblies silent') end
		applyNodes(full, serverVehicleID) -- same delivery + VE-side shape/count guards as the legacy path
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
	elseif code == "d" then
		handleDeformChunk(data, serverVehicleID) -- #245: chunked full-deformation snapshot piece
	elseif code == "g" then
		applyBreakGroups(data, serverVehicleID)
	elseif code == "c" then
		MPControllerGE.applyControllerData(data, serverVehicleID)
	else
		log('W', 'handle', "Received unknown packet '"..tostring(code).."'! ".. rawData)
	end
end



M.tick       = tick
M.fullTick   = fullTick
M.handle     = handle
M.sendNodes  = sendNodes
M.applyNodes = applyNodes
M.onInit = function() setExtensionUnloadMode(M, "manual") end

M.sendBreakGroups  = sendBreakGroups
M.sendControllerData  = sendControllerData

return M
