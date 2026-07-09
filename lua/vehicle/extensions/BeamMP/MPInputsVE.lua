-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

local M = {}

-- ============= VARIABLES =============
local smoothingRate = 30 -- lower values makes the inputs more smooth but less responsive

local lastInputs = {
	s = 0,
	t = 0,
	b = 0,
	p = 0,
	c = 0,
}

local inputCache = {}

local periodicGearSyncTimer = 0
-- #245: inputs are delta-synced (only CHANGED inputs are sent). On the reliable GE path a dropped
-- delta never happens; on the direct UDP socket a dropped HELD-input delta (e.g. parkingbrake set and
-- left) would leave the ghost stuck until that input next changes. This timer forces a full re-send of
-- ALL current inputs every INPUT_RESYNC_S so any such loss self-heals (same idea as the 5s gear
-- resync). Cheap (~5 small numbers at 0.5Hz) and it makes the normal path a touch more robust too.
local periodicInputSyncTimer = 0
local INPUT_RESYNC_S = 2
local remoteGear
local unsupportedPowertrainDevice = false
local unsupportedPowertrainGearbox = false
local disableGhostInputs = false
-- ============= VARIABLES =============

local translationTable = {
	['R'] = -1,
	['N'] = 0,
	['P'] = 1,
	['D'] = 2,
	['S'] = 3,
	['2'] = 4,
	['1'] = 5,
	['M'] = 6
}

local gearBoxHandler = {
	["manualGearbox"] = 1,
	["sequentialGearbox"] = 1,
	["dctGearbox"] = 2,
	["cvtGearbox"] = 2,
	["automaticGearbox"] = 2,
	["electricMotor"] = 2
}

local function applyGear(data) --TODO: add handling for mismatched gearbox types between local and remote vehicle
	if not electrics.values.gearIndex or electrics.values.gear == data then return end
	local powertrainDevice = powertrain.getDevice("gearbox") or powertrain.getDevice("frontMotor") or powertrain.getDevice("rearMotor") or powertrain.getDevice("mainMotor")
	if powertrainDevice == nil then -- mods that introduce custom powertrains can trigger this
		if not unsupportedPowertrainDevice then
			unsupportedPowertrainDevice = true -- prevent spamming the log
			print('MPInputsVE Error in "applyGear()". Unsupported powertrain')
		end
		return nil
	end

	if electrics.values.gearboxMode and electrics.values.gearboxMode == "arcade" then
		-- a modded/custom-powertrain vehicle may have no mainController; index-guard it (this runs on
		-- the per-frame remote apply path, which is NOT pcall-wrapped, so a nil deref FATALs the VE VM)
		if controller.mainController and controller.mainController.setGearboxMode then
			controller.mainController.setGearboxMode("realistic")
		end
	end

	-- certain gearbox need to be shifted with setGearIndex() while others need to be shifted with shiftXOnY()
	if gearBoxHandler[powertrainDevice.type] == 1 then
		local index = tonumber(data)
		if not index then return end
		powertrainDevice:setGearIndex(index)

	elseif gearBoxHandler[powertrainDevice.type] == 2 then
		if electrics.values.isShifting then return end
		-- a custom powertrain can report gearIndex (passing the guard above) while electrics.values.gear
		-- is nil, or have no mainController -> string.sub(nil)/mainController deref would FATAL this
		-- (non-pcall'd) remote apply path. Skip rather than kill the VE VM.
		if type(electrics.values.gear) ~= "string" or controller.mainController == nil then return end
		local remoteGearMode = string.sub(data, 1, 1)
		local localGearMode = string.sub(electrics.values.gear, 1, 1)
		local remoteIndex = tonumber(string.sub(data, 2))
		if remoteGearMode == 'M' and localGearMode == 'M' then
			if electrics.values.gearIndex < remoteIndex then
				controller.mainController.shiftUpOnDown()
			elseif electrics.values.gearIndex > remoteIndex then
				controller.mainController.shiftDownOnDown()
			end
		else
			controller.mainController.shiftToGearIndex(translationTable[remoteGearMode])
		end

	else
		if not unsupportedPowertrainGearbox then
			unsupportedPowertrainGearbox = true -- prevent spamming the log
			print('MPInputsVE Error in "applyGear()" unknown GearBoxType "' .. powertrainDevice.type .. '"')
		end
	end
end

local shortName = {
	steering = "s",
	throttle = "t",
	brake = "b",
	parkingbrake = "p",
	clutch = "c"
}

local function getInputs()
	local inputsToSend = {}
	-- #245: periodically forget the last-sent snapshot so EVERY input (incl. held ones the delta path
	-- would otherwise never resend) is re-emitted once -> a UDP-dropped held input self-heals within
	-- INPUT_RESYNC_S. Clearing lastInputs (incl. .g) makes the loop + gear block below re-send all.
	if periodicInputSyncTimer >= INPUT_RESYNC_S then
		periodicInputSyncTimer = 0
		lastInputs = {}
	end
	for inputName, _ in pairs(input.state) do
		local state = electrics.values[inputName] or electrics.values[inputName.."_input"] -- the electric is the most accurate place to get the input value, the state.val is different with different filters and using the smoother states causes wrong inputs in arcade mode
		if state then
			if inputName == "steering" then
				if v.data.input then
					state = -state / (v.data.input.steeringWheelLock or 1) -- converts steering wheel degrees to an input value
				end
			end
			if math.abs(state) < 0.0001 then -- prevent super small values to count as updates
				state = 0
			end
			state = math.floor((state * 10000) + 0.5) / 10000
			if lastInputs[inputName] ~= state then
				inputsToSend[shortName[inputName] or inputName] = state
				if not lastInputs[inputName] then
					if MPElectricsVE then
						MPElectricsVE.excludeElectric(inputName)
						MPElectricsVE.excludeElectric(inputName.."_input")
					end
				end
				lastInputs[inputName] = state
			end
		end
	end

	if electrics.values.gear ~= lastInputs.g or periodicGearSyncTimer >= 5 then -- sending the gear every 5 seconds for when a car is spawned after it's been put into gear
		periodicGearSyncTimer = 0
		inputsToSend.g = electrics.values.gear
	end
	lastInputs.g = electrics.values.gear

	if tableIsEmpty(inputsToSend) then return end
	local payload = jsonEncode(inputsToSend)
	-- #245: inputs are latest-wins -> route over this vehicle's shared direct socket (owned by
	-- positionVE) when the toggle is on; dvSend returns false when off/unavailable -> GE proxy path.
	if not (positionVE and positionVE.dvSend and positionVE.dvSend('Vi', payload)) then
		obj:queueGameEngineLua("MPInputsGE.sendInputs(\'"..payload.."\', "..obj:getID()..")") -- Send it to GE lua
	end
end

local function storeTargetValue(inputName,inputState)
	if not inputCache[inputName] then
		local maxLimit
		local minLimit
		if input.state[inputName] then
			maxLimit = input.state[inputName].maxLimit
			minLimit = input.state[inputName].minLimit
		end
		inputCache[inputName] = {smoother = newTemporalSmoothingNonLinear(smoothingRate), currentValue = 0, state = inputState, maxLimit = maxLimit or 1, minLimit = minLimit or -1}
		if v.mpVehicleType == "R" then -- non defined inputs do not exist in input.state until they are pressed once so we have to add those here instead
			input.setAllowedInputSource(inputName, "local", false)
			input.setAllowedInputSource(inputName, "BeamMP", true)
		end
	end
	inputCache[inputName].state = inputState
end

local function applyInputs(data)
	local decodedData = jsonDecode(data)
	if not decodedData then return end
	for inputName, inputState in pairs(decodedData) do
		if inputName == "g" then remoteGear = decodedData.g
		elseif inputName == "s" then storeTargetValue("steering",inputState)
		elseif inputName == "t" then storeTargetValue("throttle",inputState)
		elseif inputName == "b" then storeTargetValue("brake",inputState)
		elseif inputName == "p" then storeTargetValue("parkingbrake",inputState)
		elseif inputName == "c" then storeTargetValue("clutch",inputState)
		else
			storeTargetValue(inputName,inputState)
		end
	end
end

local function updateGFX(dt)
	if v.mpVehicleType == 'R' then
		if remoteGear then
			applyGear(remoteGear)
		end
		for inputName, inputData in pairs(inputCache) do -- smoothing and applying the inputs
			local difference = math.abs(inputData.state - inputData.currentValue)
			local distToMax = math.abs(inputData.state - inputData.maxLimit)
			local distToMin = math.abs(inputData.state - inputData.minLimit)
			if distToMax < 0.01 or distToMin < 0.01 or difference > 0.2 or difference < 0.000001 then -- because exponential smoothing never reaches the target value the brake/parking brake would never reach 0 causing automatics to never shift up
				inputData.currentValue = inputData.state
				inputData.smoother:set(inputData.state,dt)
			else
				inputData.currentValue = inputData.smoother:get(inputData.state,dt)
			end
			input.event(inputName, inputData.currentValue or 0, FILTER_DIRECT,nil,nil,nil,"BeamMP")
		end
		if not disableGhostInputs then
			disableGhostInputs = true
			for inputName, _ in pairs(input.state) do
				input.setAllowedInputSource(inputName, "local", false) -- disables local inputs, prevents ghost controlling
				input.setAllowedInputSource(inputName, "BeamMP", true)
			end
		end
	elseif v.mpVehicleType == 'L' then
		periodicGearSyncTimer = periodicGearSyncTimer + dt
		periodicInputSyncTimer = periodicInputSyncTimer + dt -- #245: drives the full-input resync in getInputs
		if disableGhostInputs then -- if we get vehicle owner change this will enable the inputs again when the vehicle is set to local
			disableGhostInputs = false
			for inputName, _ in pairs(input.state) do
				input.setAllowedInputSource(inputName, "local", true)
			end
		end
	end
end

local function onReset()
	lastInputs = {} -- clear the lastInputs table on reset so arcade auto brake, clutch and parking brake syncs correctly on reset
	for _, inputData in pairs(inputCache) do
		inputData.currentValue = 0
		inputData.state = 0
		inputData.smoother:reset()
	end
end

local function onExtensionLoaded()
	for inputName, state in pairs(input.state) do
		storeTargetValue(inputName, 0) -- sets all inputs to 0 on spawn so cars don't drive around with the parking brake stuck on
		if MPElectricsVE then
			MPElectricsVE.excludeElectric(inputName)
			MPElectricsVE.excludeElectric(inputName.."_input")
		end
	end
end

M.updateGFX = updateGFX
M.onReset = onReset
M.getInputs   = getInputs
M.applyInputs = applyInputs
M.onExtensionLoaded = onExtensionLoaded


return M
