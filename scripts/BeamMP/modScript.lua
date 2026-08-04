-- Copyright (C) 2026 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

local ver = split(beamng_versionb, ".")
local majorVer = tonumber(ver[2])
-- LAN fork version policy (2026-07-30): 0.39 is the validated target; 0.38 still works (the
-- 0.39-compat changes are guarded/fallback'd). Stock BeamMP hard-DEACTIVATES the whole mod on any
-- other game version -- which is exactly how MP silently died here the day Steam auto-installed
-- 0.39 (versionCheck deactivated the mod before a single fork Lua line ran; the launcher's
-- EnableMP() re-activation was undone at every boot). For a self-maintained LAN fork, a LOUD
-- warning beats bricking: on an unknown future version we warn + toast and LOAD ANYWAY, letting
-- the fork's own guards degrade gracefully until it's validated and this list is extended.
local compatibleVersions = { [38] = true, [39] = true }
if not compatibleVersions[majorVer] then
	log('W', 'versionCheck', 'BeamMP LAN fork has NOT been validated on BeamNG.drive '..beamng_versionb..' -- loading anyway (LAN policy: warn, never auto-deactivate). Expect issues until the fork is updated.')
	guihooks.trigger("toastrMsg", {type="warning", title="BeamMP LAN fork", msg="Not yet validated on BeamNG "..beamng_versionb.." — loading anyway; expect issues until the fork is updated."})
else
	log('M', 'versionCheck', 'BeamMP is compatible with the current version.')
end

load("MPNetworkHelpers")
setExtensionUnloadMode("MPNetworkHelpers", "manual")

load("beammp/multiplayer")
setExtensionUnloadMode("beammp/multiplayer", "manual")

load("MPDebug")
setExtensionUnloadMode("MPDebug", "manual")

load("UI")
setExtensionUnloadMode("UI", "manual")

load("MPModManager")
setExtensionUnloadMode("MPModManager", "manual")

load("MPCoreNetwork")
setExtensionUnloadMode("MPCoreNetwork", "manual")

load("MPConfig")
setExtensionUnloadMode("MPConfig", "manual")

load("MPGameNetwork")
setExtensionUnloadMode("MPGameNetwork", "manual")

load("MPVehicleGE")
setExtensionUnloadMode("MPVehicleGE", "manual")

load("MPInputsGE")
setExtensionUnloadMode("MPInputsGE", "manual")

load("MPElectricsGE")
setExtensionUnloadMode("MPElectricsGE", "manual")

load("MPWeaponsGE")
setExtensionUnloadMode("MPWeaponsGE", "manual")

load("positionGE")
setExtensionUnloadMode("positionGE", "manual")

load("MPPowertrainGE")
setExtensionUnloadMode("MPPowertrainGE", "manual")

load("MPUpdatesGE")
setExtensionUnloadMode("MPUpdatesGE", "manual")

load("nodesGE")
setExtensionUnloadMode("nodesGE", "manual")

load("MPControllerGE")
setExtensionUnloadMode("MPControllerGE", "manual")

-- load this file last so it can reference the others
load("MPHelpers")
setExtensionUnloadMode("MPHelpers", "manual")

extensions.core_input_categories.beammp = { order = 999, icon = "settings", title = "BeamMP", desc = "BeamMP Controls" } --inject BeamMP input category at bottom of input categories list
