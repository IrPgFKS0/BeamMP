-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

local M = {}

-- compare set to true only sends data when there is a change
-- compare set to false sends the data every time the function is called
-- storeState stores the incoming data and then if the remote car was reset for whatever reason it reapplies the state
-- adding ownerFunction and/or receiveFunction can set custom functions to read or change data before sending or on receiveing

--example
--[[
local function couplerToggleCheck(controllerName, funcName, tempTable, ...)
	local groupState = controller.getControllerSafe(controllerName).getGroupState()
	tempTable.variables = {groupState = groupState}
	controllerSyncVE.sendControllerData(tempTable)

	controllerSyncVE.OGcontrollerFunctionsTable[controllerName][funcName](...)
end

local function couplerToggleReceive(data)
	if v.mpVehicleType == "R" then
		if controller.getControllerSafe(data.controllerName).getGroupState() == data.variables.groupState then
			controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName]()
		end
	end
end

["controllerFunctionName"] = {
  ownerFunction = couplerToggleCheck,
  receiveFunction = couplerToggleReceive
},
]]

local lastvehID = 0

local aimMode = "auto"

-- LAN fork: shared by prepairID (missiles/rockets, which MUST send every call -- each call assigns
-- the next missile) and prepairAimID (targetAim, which must NOT). Returns the vehicle id the target
-- belongs to and stores tempTable.missileID when the id was a missile's.
local function normalizeTargetID(vehID, tempTable)
	-- syncing targeting missiles, missiles have the vehicleID of the original vehicle but with it's own id added at the end
	-- this system checks if removing two numbers make it match with a vehicle, if it does then we know that this is the vehicle it belongs too,
	-- if not then we try removing just one number and check again, it has to be done in this order or id 11 will mistake the missile with id 1 as being it's vehicle
	-- thanks Stefan750 for helping me figure out this system
	local mapObjects = mapmgr.getObjects() or {}
	local flooredID100 = math.floor((vehID/100))
	local found = false
	for k,_ in pairs(mapObjects) do
		if k == flooredID100 then
			tempTable.missileID = vehID - (k*100)
			vehID = flooredID100
			found = true
		end
	end
	local flooredID10 = math.floor((vehID/10))
	if not found then -- if we already found a matching id we skip this loop
		for k,_ in pairs(mapObjects) do
			if k == flooredID10 then
				tempTable.missileID = vehID - (k*10)
				vehID = flooredID10
			end
		end
	end
	return vehID
end

-- LAN fork: targetAim.setTargetID is called by the CIWS/RAM controllers EVERY graphics frame while
-- locked, and prepairID sent a controller packet on every call -- 60-140 pkt/s per turret over
-- the same UDP relay lane as positions (the fork's measured ~150 pkt/s wall). The ghost's
-- targetAim no-ops on an unchanged id, so that stream carried nothing. Send on CHANGE (including
-- the nil transition) plus a 0.5 s keepalive while a target is set -- the keepalive is required:
-- a ghost whose VE VM reloads (edit) starts with an empty controller state and its own auto-aim is
-- disabled by the sync wrapper, so without it the ghost would never aim until the owner's target
-- changed. Sim time pauses with the game, which is the right clock for this.
local aimLastVehID = 0        -- 0 = 'never sent' (a real id is never 0; nil = 'no target')
local aimLastSendTime = -1
local AIM_KEEPALIVE_S = 0.5
local function prepairAimID(controllerName, funcName, tempTable, ...)
	local vehID = tempTable.variables[1]
	if vehID then vehID = normalizeTargetID(vehID, tempTable) end
	local now = obj:getSimTime()
	if vehID ~= aimLastVehID or (vehID ~= nil and now - aimLastSendTime >= AIM_KEEPALIVE_S) then
		tempTable["vehID"] = vehID -- store vehicleID separately so we can convert it to serverVehID in GE
		controllerSyncVE.sendControllerData(tempTable)
		aimLastVehID = vehID
		aimLastSendTime = now
	end
	return controllerSyncVE.OGcontrollerFunctionsTable[controllerName][funcName](...)
end

local function prepairID(controllerName, funcName, tempTable, ...)
	local vehID = tempTable.variables[1]
	if vehID or lastvehID then -- the Phulcan spams the setTargetID in auto mode, but just comparing to last can break normal targeting, and we still need to send an empty table once, so instead I'm checking if either is true
		if vehID then
			vehID = normalizeTargetID(vehID, tempTable)
		end
		tempTable["vehID"] = vehID -- store vehicleID separately so we can convert it to serverVehID in GE
		controllerSyncVE.sendControllerData(tempTable)
	end
	lastvehID = vehID
	return controllerSyncVE.OGcontrollerFunctionsTable[controllerName][funcName](...)
end

local function receiveID(data)
	if data.missileID and data.vehID then
		if data.missileID >= 10 then
			data.vehID = (data.vehID*100)+data.missileID
		else
			data.vehID = (data.vehID*10)+data.missileID
		end
	end
	controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName](data.vehID)
end

local function setAimMode(controllerName, funcName, tempTable, ...)
	aimMode = ...
	controllerSyncVE.sendControllerData(tempTable)
	return controllerSyncVE.OGcontrollerFunctionsTable[controllerName][funcName](...)
end

local function setAimModeReceive(data)
	aimMode = data.variables[1]
	if controllerSyncVE.OGcontrollerFunctionsTable["ciws"] then
		controllerSyncVE.OGcontrollerFunctionsTable["ciws"]["setTargetMode"](aimMode)
	end
	controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName](aimMode)
end

local lastElevationDirection = 0

local function prepairSetElevationChange(controllerName, funcName, tempTable, ...)
	local servo = powertrain.getDevice("elevationServo")
	if aimMode == "manual" and servo then
		local servoAngle = servo.currentAngle
		if ... ~= 0 then
			lastElevationDirection = ...
			servoAngle = servoAngle + (...* 0.013) -- we have to add a bit extra rotation because servo.currentAngle is a frame behind
		else
			servoAngle = servoAngle + (lastElevationDirection* 0.013) -- we also need it for stopping so it doesn't stop short, but because stopping has an input of 0 we need to use the previous state
		end
		tempTable.servoAngle = servoAngle
		controllerSyncVE.sendControllerData(tempTable)
	end
	return controllerSyncVE.OGcontrollerFunctionsTable[controllerName][funcName](...)
end

local function receiveSetElevationChange(data)
	local servo = powertrain.getDevice("elevationServo")
	if aimMode == "manual" and servo then
		servo:setTargetAngle(data.servoAngle)
	end
	controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName](unpack(data.variables))
end

local lastRotationDirection = 0

local function prepairSetRotationChange(controllerName, funcName, tempTable, ...)
	local servo = powertrain.getDevice("rotationServo")
	if aimMode == "manual" and servo then
		local servoAngle = servo.currentAngle
		if ... ~= 0 then
			lastRotationDirection = ...
			servoAngle = servoAngle + (...* 0.003)
		else
			servoAngle = servoAngle + (lastRotationDirection* 0.003)
		end
		tempTable.servoAngle = servoAngle
		controllerSyncVE.sendControllerData(tempTable)
	end
	local returnData = controllerSyncVE.OGcontrollerFunctionsTable[controllerName][funcName](...)
	return returnData
end

local function receiveSetRotationChange(data)
	local servo = powertrain.getDevice("rotationServo")
	if aimMode == "manual" and servo then
		servo:setTargetAngle(data.servoAngle)
	end
	controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName](unpack(data.variables))
end

local includedControllerTypes = {
	-- PlayerWeapons mod --
	["pw2"] = {
		["camForwardCallback"] = {
			compare = true
			},
	},

	-- me262 and Phoulkon --
	["bombs"] = {
		-- LAN fork: deployWeaponDown(useBombCam) replayed on a GHOST would arm the bomb-cam on the
		-- OBSERVER's machine (camera hijack + a queued chunk into the observer's own vehicle VM that
		-- indexes a controller it doesn't have = the sync-killing FATAL class). Force the cam off.
		["deployWeaponDown"] = {
			receiveFunction = function(data)
				controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName](false)
			end
		},
		["deployWeaponUp"] = {},
	},
	["countermeasures"] = {
		["activateCountermeasures"] = {}
	},
	["missiles"] = {
		-- LAN fork: deployWeaponDown(index, useMissileCam) -- same cam-hijack class as bombs above
		-- (seen with the turrets mod: a remote RAM launch in semi-auto/manual switched every
		-- observer's camera and queued a nil-index into their own car's VM). Keep the index, force
		-- the cam flag off on the ghost.
		["deployWeaponDown"] = {
			receiveFunction = function(data)
				controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName](type(data.variables) == "table" and data.variables[1] or nil, false)
			end
		},
		["setTargetID"] = {
			ownerFunction = prepairID,
			receiveFunction = receiveID,
			storeState = true,
		},
		["deployWeaponUp"] = {}
	},
	["rockets"] = {
		["deployWeaponDown"] = {},
		["setTargetID"] = {
			ownerFunction = prepairID,
			receiveFunction = receiveID,
			storeState = true,
		},
		["deployWeaponUp"] = {}
	},
	["targetAim"] = {
		["setAimMode"] = {
			ownerFunction = setAimMode,
			receiveFunction = setAimModeReceive,
			storeState = true
		},
		["setTargetID"] = {
			ownerFunction = prepairAimID, -- LAN fork: change + 0.5 s keepalive instead of one packet per frame
			receiveFunction = receiveID,
			storeState = true, -- restoring the states happens in the wrong order for this and setAimMode causing it not to aim on local reset
		},
		["setElevationChange"] = {
			ownerFunction = prepairSetElevationChange,
			receiveFunction = receiveSetElevationChange,
			storeState = true
		},
		["setRotationChange"] = {
			ownerFunction = prepairSetRotationChange,
			receiveFunction = receiveSetRotationChange,
			storeState = true
		},
		["killSystem"] = {}
	},
	["missileTargetSelector"] = {
		["toggleTargetMode"] = {}
	},
	-- Phulcan specific --
	["ciws"] = {
		["setTargetMode"] = {storeState = true},
		["fireWeapon"] = {storeState = true},
		["stopWeapon"] = {storeState = true},
	},
	["ram"] = {
		["setTargetMode"] = {storeState = true},
		["fireWeapon"] = {storeState = true},
		["stopWeapon"] = {storeState = true},
	},

	-- Javielucho Mad Mod --
	["madmod_missles"] = {
		["checkMissleLL"] = {},
		["checkMissleL"] = {},
		["checkMissleR"] = {},
		["checkMissleRR"] = {},
	},
}

local function loadFunctions()
	if controllerSyncVE ~= nil then
		controllerSyncVE.addControllerTypes(includedControllerTypes)
	else
		dump("controllerSyncVE not found")
	end
end

local function onReset()
	aimMode = "auto"
end

M.onBeamMPLoadControllerSyncFunctions = loadFunctions
M.onReset = onReset

return M
