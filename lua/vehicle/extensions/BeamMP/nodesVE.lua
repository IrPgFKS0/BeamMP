-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later
local M = {}



-- ============= VARIABLES =============
local lastPos = vec3(0,0,0)
-- ============= VARIABLES =============


local propsfunction = nil
local justBrokenBreakGroups = {}

local function distance( x1, y1, z1, x2, y2, z2 )
	local dx = x1 - x2
	local dy = y1 - y2
	local dz = z1 - z2
	return math.sqrt ( dx*dx + dy*dy + dz*dz)
end



-- Round to N decimals. MUST be defined before getNodes (Lua lexical scope): getNodes/applyNodes
-- called a capital 'Round' which is a nil global -> FATAL Lua error on every full-deformation-sync
-- tick, killing the vehicle's VE VM (seen spamming on a TriX_Chiron). The real fn was (uselessly)
-- defined lower down, AFTER its callers, so even the correct case would have been out of scope.
local function round(num, numDecimalPlaces)
	local mult = 10^(numDecimalPlaces or 0)
	return math.floor(num * mult + 0.5) / mult
end

local function getNodes()

  -- TODO: color
  local save = {}
  --save.nodeCount = #v.data.nodes
  --save.beamCount = #v.data.beams
  --save.luaState = serialize(serializePackages("save"))
  --save.hydros = {}
  --for _, h in pairs(hydros.hydros) do
    --table.insert(save.hydros, h.state)
  --end

  save.nodes = {}
  for _, node in pairs(v.data.nodes) do
	local Pos = obj:getNodePosition(node.cid)
	Pos.x = round(Pos.x,3)
	Pos.y = round(Pos.y,3)
	Pos.z = round(Pos.z,3)
    local d = {vec3(Pos):toTable()}

    if math.abs(obj:getOriginalNodeMass(node.cid) - obj:getNodeMass(node.cid)) > 0.1 then
      table.insert(d, obj:getNodeMass(node.cid))
    end
    save.nodes[node.cid + 1] = d
  end

  save.beams = {}
  for _, beam in pairs(v.data.beams) do
    local d = {
      round(obj:getBeamRestLength(beam.cid),3),
      obj:beamIsBroken(beam.cid),
      round(obj:getBeamDeformation(beam.cid),3)
    }
    save.beams[beam.cid + 1] = d
  end


	--print("ok")
	--local pos = obj:getPosition()
	--local dist = distance(pos.x, pos.y, pos.z, lastPos.x, lastPos.y, lastPos.z)
	--lastPos = pos
	--if (dist > 0.02) then return end

	--local save = {}
  --save.nodeCount = #v.data.nodes
  --save.beamCount = #v.data.beams

  --[[save.hydros = {}
  for _, h in pairs(hydros.hydros) do
    table.insert(save.hydros, h.state)
  end]]

  --[[save.nodes = {}
  for _, node in pairs(v.data.nodes) do
    local d = {
      vec3(obj:getNodePosition(node.cid)):toTable()
    }
    if math.abs(obj:getOriginalNodeMass(node.cid) - obj:getNodeMass(node.cid)) > 0.1 then
      table.insert(d, obj:getNodeMass(node.cid))
    end
    save.nodes[node.cid + 1] = d
  end]]

  --[[save.beams = {}
  for _, beam in pairs(v.data.beams) do
    local d = {
      obj:getBeamRestLength(beam.cid),
      obj:beamIsBroken(beam.cid),
      obj:getBeamDeformation(beam.cid)
    }
    save.beams[beam.cid + 1] = d
  end]]

	obj:queueGameEngineLua("nodesGE.sendNodes(\'"..jsonEncode(save).."\', "..obj:getID()..")") -- Send it to GE lua
end



local function applyNodes(data)

	--obj:requestReset(RESET_PHYSICS)
	local save = jsonDecode(data)
	-- The RECEIVE side applies regardless of the local syncFullDeformation toggle, so a peer with the
	-- (experimental, default-off) feature on -- or a truncated/crafted 'Xn:' packet -- reaches here.
	-- A nil/short payload would make pairs(save.nodes) FATAL this vehicle's VE VM. Guard the shape.
	if type(save) ~= "table" or type(save.nodes) ~= "table" or type(save.beams) ~= "table" then return end

  -- (debug print removed: this path now runs continuously for deformation sync)
  --importPersistentData(save.luaState)

  --[[for k, h in pairs(save.hydros) do
    hydros.hydros[k].state = h
  end]]

  for cid, node in pairs(save.nodes) do
    cid = tonumber(cid) - 1
    obj:setNodePosition(cid, vec3(node[1]):toFloat3())
    if #node > 1 then
      obj:setNodeMass(cid, node[2])
    end
  end

  for cid, beam in pairs(save.beams) do
		cid = tonumber(cid) - 1
		if beam[2] == true then
			obj:breakBeam(cid)
			-- beamstate.beamBroken is damage-system bookkeeping (the beam already broke above via
			-- obj:breakBeam). Guard it the same way as beamstate.beamDeformed below: if BeamNG 0.3x
			-- removed/renamed it, an unguarded nil call would FATAL-loop the receiver's VE VM.
			if beamstate.beamBroken then beamstate.beamBroken(cid,1) end
		else
			obj:setBeamLength(cid, beam[1])
			if (beam[3] or 0) > 0 then
			--print('deformed: ' .. tostring(cid) .. ' = ' .. tostring(beam[3]))
			-- beamstate.beamDeformed was removed in BeamNG 0.3x (only the onBeamDeformed callback
			-- remains). Calling a nil field FATAL-killed the receiver's VE VM once p13h21 made
			-- getNodes actually send data. The deformed SHAPE still applies via setBeamLength above;
			-- this guard just skips the (now-absent) damage-system bookkeeping instead of crashing.
			if beamstate.beamDeformed then beamstate.beamDeformed(cid, beam[3]) end
			end
		end
  end


  --[[if not decodedData or decodedData.nodeCount ~= #v.data.nodes then --or decodedData.beamCount ~= #v.data.beams then
    log("E", "nodesVE", "unable to use nodes data.")
    return
  end]]
  -- (debug print removed)
  --[[for k, h in pairs(decodedData.hydros) do
    hydros.hydros[k].state = h
  end]]

  --[[for cid, node in pairs(decodedData.nodes) do
    cid = tonumber(cid) - 1
    obj:setNodePosition(cid, vec3(node[1]):toFloat3())
    if #node > 1 then
      obj:setNodeMass(cid, node[2])
    end
  end]]

  --[[for cid, beam in pairs(decodedData.beams) do
    cid = tonumber(cid) - 1
    obj:setBeamLength(cid, beam[1])
    if beam[2] == true then
      obj:breakBeam(cid)
    end
    if beam[3] > 0 then
      -- deformation: do not call c++ at all, its just used on the lua side anyways
      --print('deformed: ' .. tostring(cid) .. ' = ' .. tostring(beam[3]))
      beamDeformed(cid, beam[3])
    end
  end]]

	--[[for cid, node in pairs(decodedData.nodes) do
		cid = tonumber(cid) - 1

		local beam = v.data.beams[cid]
		local beamPrecompression = beam.beamPrecompression or 1
		local deformLimit = type(beam.deformLimit) == 'number' and beam.deformLimit or math.huge
		obj:setBeam(-1, beam.id1, beam.id2, beam.beamStrength, beam.beamSpring,
			beam.beamDamp, type(beam.dampCutoffHz) == 'number' and beam.dampCutoffHz or 0,
			beam.beamDeform, deformLimit, type(beam.deformLimitExpansion) == 'number' and beam.deformLimitExpansion or deformLimit,
			beamPrecompression
		)
		--print(dump(node))
		obj:setNodePosition(cid, vec3(node[1]):toFloat3())
		if #node > 1 then
			obj:setNodeMass(cid, node[2])
		end

	end]]
  -- (debug print removed)
end



local function applyBreakGroups(data)
	local justBrokenRemote = jsonDecode(data)

	if type(justBrokenRemote) ~= 'table' then
		log('W', 'applyBreakGroups', 'Received invalid data: ' .. tostring(data))
		return
	end

	for _, g in pairs(justBrokenRemote) do
		beamstate.breakBreakGroup(g)
	end
end

local function getBreakGroups()
	local breakGroupArray = {}

	for g in pairs(justBrokenBreakGroups) do
		table.insert(breakGroupArray, g)
	end
	justBrokenBreakGroups = {}

	if #breakGroupArray == 0 then
		return
	end

	obj:queueGameEngineLua("nodesGE.sendBreakGroups(\'"..jsonEncode(breakGroupArray).."\', "..obj:getID()..")") -- Send it to GE lua
end

local function onBreakGroupBroken(g)
	justBrokenBreakGroups[g] = true
	propsfunction(g)
end

local function onReset()
	if props.hidePropsInBreakGroup ~= onBreakGroupBroken then
		propsfunction = props.hidePropsInBreakGroup
		props.hidePropsInBreakGroup = onBreakGroupBroken
	end
end


M.distance   = distance
M.applyNodes = applyNodes
M.getNodes   = getNodes

M.applyBreakGroups = applyBreakGroups
M.getBreakGroups   = getBreakGroups

M.onExtensionLoaded = onReset
M.onReset           = onReset

return M
