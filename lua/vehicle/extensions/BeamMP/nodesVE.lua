-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later
local M = {}

-- Break-group sync only. The experimental full node/beam deformation sync (getNodes/applyNodes,
-- 'Xn' blobs + the #245 'Xd' chunked variant) was REMOVED 2026-07-09: it never worked reliably
-- (two BeamNG 0.3x dead-API breaks, then transport stalls), and even with a fixed transport the
-- intrinsic cost is prohibitive -- serializing EVERY node+beam to ~100KB JSON at 2Hz per vehicle
-- in VE Lua, plus a full setNodePosition/setBeamLength apply pass on every receiver. nodesGE
-- silently discards 'Xn'/'Xd' packets from old peers that still send them.

local propsfunction = nil
local justBrokenBreakGroups = {}

local function distance( x1, y1, z1, x2, y2, z2 )
	local dx = x1 - x2
	local dy = y1 - y2
	local dz = z1 - z2
	return math.sqrt ( dx*dx + dy*dy + dz*dz)
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

M.applyBreakGroups = applyBreakGroups
M.getBreakGroups   = getBreakGroups

M.onExtensionLoaded = onReset
M.onReset           = onReset

return M
