-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

local M = {}

-- Custom functions

--kickplate

local function changePowerLevel(controllerName, funcName, tempTable, ...)
    local powerIncrease = ...
    if powerIncrease and electrics.values.kickplatePowerLevel then
        controller.getControllerSafe("kickplate").setPowerLevel(electrics.values.kickplatePowerLevel + powerIncrease)
    end
end

-- spikestrips

local function prepareID(controllerName, funcName, tempTable, ...)
	tempTable["vehID"] = ...
	controllerSyncVE.sendControllerData(tempTable)
	return controllerSyncVE.OGcontrollerFunctionsTable[controllerName][funcName](...)
end

local function receiveID(data)
    if data.vehID then
        controllerSyncVE.OGcontrollerFunctionsTable[data.controllerName][data.functionName](data.vehID)
    end
end

-- compare set to true only sends data when there is a change
-- compare set to false sends the data every time the function is called
-- adding ownerFunction and/or receiveFunction can set custom functions to read or change data before sending or on receiveing
--["controllerFunctionName"] = {
--  ownerFunction = customFunctionOnSend,
--  receiveFunction = customFunctionOnReceive
--},
-- storeState stores the incoming data and then if the remote car was reset locally for whatever reason it reapplies the state

local includedControllerTypes = {
    ["rollover"] = {
        ["cycle"] = {},
        ["prepare"] = {}
    },

    ["hamster_wheel"] = {
        ["setTargetRPMRatioIncrease"] = {},
        ["setTargetRPMRatioDecrease"] = {},
        ["setTargetRPMRatio"] = {}
    },

    ["spinner"] = {
        ["setTargetRPMRatioIncrease"] = {},
        ["setTargetRPMRatioDecrease"] = {},
        ["setTargetRPMRatio"] = {}
    },

    ["large_roller"] = {
        ["setTargetThrottle"] = {},
        ["setRollerHeight"] = {}
    },

    ["large_cannon"] = {
        ["fireCannon"] = {},
        ["shootStrengthChange"] = {},
        ["targetInclinationChange"] = {}
    },

    ["kickplate"] = { -- TODO finish this, only power level syncs atm
        ["setPowerLevel"] = {},
        ["changePowerLevel"] = {
			ownerFunction = changePowerLevel
        },
        ["setRandomDirection"] = {},
        ["setPlateDirection"] = {}
    },

    ["spikestripRemoteScissor"] = {
        ["setOperationMode"] = {},
        ["toggleOperationMode"] = {},
        ["setTargetSelectionMode"] = {},
        ["setManualTargetId"] = {
			ownerFunction = prepareID,
			receiveFunction = receiveID,
        },
        ["setManualExtension"] = {},
        ["toggleManualExtension"] = {}
    },

    ["spikestripRemoteStick"] = {
        ["setOperationMode"] = {},
        ["toggleOperationMode"] = {},
        ["toggleArmed"] = {},
        ["setTargetSelectionMode"] = {},
        ["setManualTargetId"] = {
			ownerFunction = prepareID,
			receiveFunction = receiveID,
        },
        ["manualLaunch"] = {},
        ["manualRetract"] = {}
    },

    ["roofCrusherTester"] = {
        ["moveManually"] = {},
        ["toggleState"] = {}
    },

    ["testRoller"] = {
        ["changeRampAngle"] = {} -- TODO exclude ramp_angle electrics from electrics sync and sync it manually here, the hydros are so fast it causes shaking when using electrics sync
    },
}

local function onReset()
end

local function loadFunctions()
    if controllerSyncVE ~= nil then
        controllerSyncVE.addControllerTypes(includedControllerTypes)
    else
        dump("controllerSyncVE not found")
    end
end

M.loadControllerSyncFunctions = loadFunctions
M.onReset = onReset

return M
