-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

local M = {}

local timer = 0.1 -- timer to prevent doors from opening on spawn and reset
local MPcouplercache = {}
local lastNodeIDcoupled
local lastNodeID2coupled
local lastNodeIDdecoupled
local lastNodeID2decoupled

local originalActivateAutoCoupling = beamstate.activateAutoCoupling

local function activateAutoCoupling(...)
	if v.mpVehicleType and v.mpVehicleType == "R" then return end
	originalActivateAutoCoupling(...)
end

beamstate.activateAutoCoupling = activateAutoCoupling

local function toggleCouplerState(data)
	local decodedData = jsonDecode(data)
	if not decodedData then return end -- a truncated/corrupt packet decodes to nil; pairs(nil) would FATAL the VE VM
	for k,v in pairs(decodedData) do
		if v.state == false or v.state == true then
			if v._nodetag then
				local coupler = beamstate.couplerCache[v._nodetag]
				if coupler then
					if v.state then
						obj:attachCoupler(coupler.cid, coupler.couplerTag or "", coupler.couplerStrength or 1000000, 10, coupler.couplerLockRadius or 0.025, 0.3, coupler.couplerTargets or 0)
					else
						obj:detachCoupler(v._nodetag, 0)
						obj:queueGameEngineLua(string.format("onCouplerDetach(%s,%s)", obj:getId(), coupler.cid))
						extensions.couplings.onBeamstateDetachCouplers()
					end
				else
					log("D", "couplerVE", "no cached coupler found with tag"..v._nodetag)
				end
			end
		else
			-- Advanced (controller-group) coupler. getControllerSafe() returns nil when the named
			-- controller doesn't exist locally (a peer running a different/broken/absent mod). The
			-- original code chained .getGroupState() on that nil AND could call detachGroup() on an
			-- empty table -- either FATAL-kills this vehicle's VE VM (the broken-mod desync class).
			-- Resolve a real controller first and skip the whole branch if there is none.
			local realController = controller.getControllerSafe(v.name)
			if realController and realController.getGroupState and realController.getGroupState() ~= v.state then
				local couplerController = realController
				if controllerSyncVE.OGcontrollerFunctionsTable and controllerSyncVE.OGcontrollerFunctionsTable[v.name] then -- controller-sync compat: it disables the funcs on remote vehicles, so use the saved originals
					couplerController = controllerSyncVE.OGcontrollerFunctionsTable[v.name]
				end

				if v.state == "detached" or v.state == "autoCoupling" or v.state == "broken" then
					couplerController.detachGroup()
				elseif v.state == "attached" then
					couplerController.tryAttachGroupImpulse()
				end
			end
		end
	end
end

local function onCouplerAttached(nodeId, obj2id, obj2nodeId, attachSpeed, attachEnergy)
	if nodeId == lastNodeID2coupled and obj2nodeId == lastNodeIDcoupled then return end -- stops it from sending a double packet
	if timer <= 0 and v.mpVehicleType == "L" then
		local ID = obj:getID()
		local Advanced = false
		-- Advanced couplers, doors etc
		local MPcouplerdata = {}
		if ID == obj2id then
			for k,v in pairs(MPcouplercache) do
				local sc = controller.getControllerSafe(v.name) -- nil if the controller was removed (part change/reset) or never existed; calling on nil would FATAL the VE VM
				local state = sc and sc.getGroupState()
				if v.state ~= state then
					Advanced = true
					local couplerstates = {}
					couplerstates.name = v.name
					couplerstates.state = state
					table.insert(MPcouplerdata,couplerstates)
				end
				v.state = state
			end
		end

		-- basic couplers
		if not Advanced then
			local MPcouplers = {}
			MPcouplers.state = true
			MPcouplers._nodetag = nodeId
			if ID == obj2id then -- checking if coupler is connecting to another vehicle
				MPcouplers.trailer = false
			else
				MPcouplers.trailer = true
			end
			MPcouplers.obj2id = obj2id
			table.insert(MPcouplerdata,MPcouplers)
		end

		obj:queueGameEngineLua("MPVehicleGE.sendBeamstate(\'"..jsonEncode(MPcouplerdata).."\'," ..tostring(obj:getID())..")")
	end

	lastNodeIDcoupled = nodeId
	lastNodeID2coupled = obj2nodeId
end

local function onCouplerDetached(nodeId, obj2id, obj2nodeId)
	if nodeId == lastNodeID2decoupled and obj2nodeId == lastNodeIDdecoupled then return end -- stops it from sending a double packet
	if timer <= 0 and v.mpVehicleType == "L" then
		local ID = obj:getID()
		local Advanced = false
		-- Advanced couplers, doors etc
		local MPcouplerdata = {}
		if ID == obj2id then
			for k,v in pairs(MPcouplercache) do
				local sc = controller.getControllerSafe(v.name) -- nil if the controller was removed (part change/reset) or never existed; calling on nil would FATAL the VE VM
				local state = sc and sc.getGroupState()
				if v.state ~= state then
					Advanced = true
					local couplerstates = {}
					couplerstates.name = v.name
					couplerstates.state = state
					table.insert(MPcouplerdata,couplerstates)
				end
				v.state = state
			end
		end

		-- basic couplers
		if not Advanced then
			local MPcouplers = {}
			MPcouplers.state = false
			MPcouplers._nodetag = nodeId
			if ID == obj2id then -- checking if coupler is connecting to another vehicle
				MPcouplers.trailer = false
			else
				MPcouplers.trailer = true
			end
			MPcouplers.obj2id = obj2id
			table.insert(MPcouplerdata,MPcouplers)
		end

		obj:queueGameEngineLua("MPVehicleGE.sendBeamstate(\'"..jsonEncode(MPcouplerdata).."\'," ..tostring(obj:getID())..")")
	end

	lastNodeIDdecoupled = nodeId
	lastNodeID2decoupled = obj2nodeId
end

local function updateGFX(dt)
	if timer >= 0 then
		timer = timer - dt
	end
end

local function onReset()
	timer = 0.1
	MPcouplercache = {}
	local AdvCouplers = controller.getControllersByType("advancedCouplerControl")
	if AdvCouplers == nil then return end
	for k,v in pairs(AdvCouplers) do
		local couplerstates = {}
		couplerstates.name = v.name
		couplerstates.state = "attached"
		table.insert(MPcouplercache,couplerstates)
	end
	
	lastNodeIDcoupled = nil
	lastNodeID2coupled = nil
	lastNodeIDdecoupled = nil
	lastNodeID2decoupled = nil
end

M.onReset            = onReset
M.onInit             = onReset
M.onExtensionLoaded  = onReset
M.toggleCouplerState = toggleCouplerState
M.onCouplerAttached  = onCouplerAttached
M.onCouplerDetached  = onCouplerDetached
M.updateGFX          = updateGFX

return M
