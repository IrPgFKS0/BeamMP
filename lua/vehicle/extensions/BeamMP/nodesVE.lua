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

-- ==== #245 chunked full-deformation transport (used by getNodes below) ====
-- The legacy path ships ONE ~100KB blob through the GE VM + the game<->launcher TCP stream. That
-- (a) busy-blocks the GE thread in sendData's partial-send completion loop and (b) head-of-line
-- blocks every packet queued behind it on the TCP proxy -- positions included -- which caused the
-- 2026-07-08 ghost-drift storm with syncFullDeformation on. With the direct vehicle socket ON we
-- instead split the snapshot into small UDP datagrams sent straight from this VE (positionVE.dvSend)
-- and paced a few per frame, so positions interleave freely. nodesGE reassembles ('Xd') and DISCARDS
-- any incomplete snapshot -- full snapshots are latest-wins at SNAPSHOT granularity (the next 2Hz one
-- self-corrects), so UDP loss can never apply torn deformation.
local DF_CHUNK = 1000          -- payload bytes per datagram: fits one MTU with headers, far under the launcher's 10240 recv buffer
local DF_CHUNKS_PER_FRAME = 6  -- drained per updateGFX call: a ~100KB snapshot spreads over ~0.3-0.6s
local DF_MAX_CHUNKS = 256      -- sanity cap (~256KB snapshot); bigger = skip with a one-shot warning
local dfGen = 0                -- snapshot generation (per VM load); the receiver keeps only the newest
local dfOut = nil              -- in-flight outbound snapshot: {gen, parts array, next index}
local dfWarnedSize = false
local dfDiagged = false

local function getNodes()

  -- TODO: color
  local save = {}
  -- Counts let the receiver reject a snapshot taken from a DIFFERENT configuration (the owner
  -- edited/swapped the vehicle and this 2Hz snapshot raced the ghost's reload) -- see applyNodes.
  save.nodeCount = #v.data.nodes
  save.beamCount = #v.data.beams
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

	local payload = jsonEncode(save)
	-- #245 chunked path (see the block comment above DF_CHUNK). One snapshot in flight at a time:
	-- if the previous one is still draining, skip this 2Hz tick -- that IS the rate limiter.
	if positionVE and positionVE.dvIsActive and positionVE.dvIsActive() and positionVE.dvSend then
		if dfOut then return end
		local n = math.ceil(#payload / DF_CHUNK)
		if n > DF_MAX_CHUNKS then
			if not dfWarnedSize then dfWarnedSize = true; log('W', 'nodesVE', 'chunked deformation: snapshot too large ('..#payload..' bytes > '..(DF_MAX_CHUNKS*DF_CHUNK)..'), skipping sends') end
			return
		end
		dfGen = dfGen + 1
		local parts = {}
		for i = 1, n do
			parts[i] = payload:sub((i - 1) * DF_CHUNK + 1, i * DF_CHUNK)
		end
		dfOut = { gen = dfGen, parts = parts, next = 1 }
		if not dfDiagged then dfDiagged = true; log('I', 'dvSocket', 'chunked deformation: sending gen='..dfGen..' as '..n..' chunks ('..#payload..' bytes); further snapshots silent') end
		return
	end
	obj:queueGameEngineLua("nodesGE.sendNodes(\'"..payload.."\', "..obj:getID()..")") -- legacy single-blob GE path (direct socket off)
end

-- Drain the in-flight chunked snapshot a few datagrams per frame (#245). Near-zero cost when idle.
-- Wire format: 'Xd:<sid>:<gen>,<i>,<n>:<bytes>' (dvSend prepends 'Xd:<sid>:'); parsed by nodesGE 'd'.
local function updateGFX(dt)
	if not dfOut then return end
	local o = dfOut
	local n = #o.parts
	for _ = 1, DF_CHUNKS_PER_FRAME do
		local i = o.next
		if i > n then break end
		if not (positionVE and positionVE.dvSend and positionVE.dvSend('Xd', o.gen..','..i..','..n..':'..o.parts[i])) then
			dfOut = nil -- toggle went off / socket died mid-drain: drop the snapshot (the next one re-sends everything)
			return
		end
		o.next = i + 1
	end
	if o.next > n then dfOut = nil end
end



local function applyNodes(data)

	--obj:requestReset(RESET_PHYSICS)
	local save = jsonDecode(data)
	-- The RECEIVE side applies regardless of the local syncFullDeformation toggle, so a peer with the
	-- (experimental, default-off) feature on -- or a truncated/crafted 'Xn:' packet -- reaches here.
	-- A nil/short payload would make pairs(save.nodes) FATAL this vehicle's VE VM. Guard the shape.
	if type(save) ~= "table" or type(save.nodes) ~= "table" or type(save.beams) ~= "table" then return end
	-- Reject a snapshot from a DIFFERENT configuration: a vehicle EDIT reloads/replaces the ghost,
	-- and a 2Hz snapshot serialized before the owner's edit can arrive after it -- its cids would
	-- then go out-of-range straight into engine calls (setNodePosition/breakBeam). Counts are exact
	-- and cheap; a mismatched snapshot is stale by definition, the next one (<=0.5s) will match.
	if (save.nodeCount and save.nodeCount ~= #v.data.nodes)
		or (save.beamCount and save.beamCount ~= #v.data.beams) then return end

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
M.updateGFX        = updateGFX -- #245: drains the chunked deformation snapshot (no-op unless one is in flight)

M.onExtensionLoaded = onReset
M.onReset           = onReset

return M
