-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPUpdatesGE API.
--- Author of this documentation is Titch
--- @module MPUpdatesGE
--- @usage onPlayerConnect() -- internal access
--- @usage MPUpdatesGE.onPlayerConnect() -- external access


local M = {}


-- Tickrate - how often data is being sent from the client, in seconds.
-- LAN-only build: these are cranked up for aggressive, low-latency sync. On a
-- LAN there is effectively unlimited bandwidth and sub-millisecond latency, so
-- we send far more often than the stock (internet-tuned) values. The effective
-- rate is still capped by the game's frame rate, since onUpdate() runs once per
-- rendered frame -- e.g. position can only truly hit 100 Hz at >=100 FPS.
local nodesTimer = 0
local nodesTickrate = 1/30      -- stock 1/15  (break groups: which parts detached)

-- (The experimental full-deformation sync timer that lived here was REMOVED 2026-07-09 along with
-- the whole feature -- intrinsically too CPU-heavy; see nodesVE/nodesGE headers.)

local positionTimer = 0
local positionTickrate = 1/100  -- stock 0.020 (50 Hz) -> 100 Hz

-- Non-driven owned vehicles (AI/traffic/parked) are sent at this LOW fixed rate, decoupled
-- from the driven car's physRateSendHz. Before this they streamed at the full position tick
-- (~FPS 60-90Hz) because physRateSendHz only throttled the driven car -- N spawned vehicles
-- then flooded the relay (~370 pos/s with 7 cars) and starved every ghost into drift. The
-- driven car is unaffected (full rate); only the extras ride this. Raise/lower to taste.
local trafficTimer = 0
local trafficTickrate = 1/12    -- 12 Hz for non-driven owned vehicles

local inputsTimer = 0
local inputsTickrate = 1/60     -- stock 1/30

local electricsTimer = 0
local electricsTickrate = 1/30  -- stock 1/15

local powertrainTimer = 0
local powertrainTickrate = 1/20 -- stock 1/10

local controllerTimer = 0
local controllerTickrate = 1/30 -- stock 1/15

 -- This doesn't do anything because the data isn't queued on the receiving end
local function onPlayerConnect()
	MPElectricsGE.tick()
	nodesGE.tick()
	positionGE.tick(true) -- one-shot: include non-driven owned vehicles
	MPInputsGE.tick()
	MPPowertrainGE.tick()
end


--- onUpdate is a game eventloop function. It is called each frame by the game engine.
-- This is the main processing thread of BeamMP in the game
-- @param dt float
local function onUpdate(dt)
	if MPGameNetwork and MPGameNetwork.launcherConnected() then
		nodesTimer = nodesTimer + dt
		if nodesTimer >= nodesTickrate then
			nodesTimer = (nodesTimer - nodesTickrate) % nodesTickrate
			nodesGE.tick() -- Comment this line to disable nodes synchronization
		end

		positionTimer = positionTimer + dt
		trafficTimer = trafficTimer + dt
		if positionTimer >= positionTickrate then
			positionTimer = (positionTimer - positionTickrate) % positionTickrate
			-- Non-driven owned vehicles ride trafficTickrate, not the per-frame position tick.
			local sendTraffic = false
			if trafficTimer >= trafficTickrate then
				trafficTimer = (trafficTimer - trafficTickrate) % trafficTickrate
				sendTraffic = true
			end
			positionGE.tick(sendTraffic) -- Comment this line to disable position synchronization
		end

		inputsTimer = inputsTimer + dt
		if inputsTimer >= inputsTickrate then
			inputsTimer = (inputsTimer - inputsTickrate) % inputsTickrate
			MPInputsGE.tick() -- Comment this line to disable inputs synchronization
		end

		electricsTimer = electricsTimer + dt
		if electricsTimer >= electricsTickrate then
			electricsTimer = (electricsTimer - electricsTickrate) % electricsTickrate
			MPElectricsGE.tick() -- Comment this line to disable electrics synchronization
		end
		
		powertrainTimer = powertrainTimer + dt
		if powertrainTimer >= powertrainTickrate then
			powertrainTimer = (powertrainTimer - powertrainTickrate) % powertrainTickrate
			MPPowertrainGE.tick() -- Comment this line to disable powertrain synchronization
		end
		
		controllerTimer = controllerTimer + dt
		if controllerTimer >= controllerTickrate then
			controllerTimer = (controllerTimer - controllerTickrate) % controllerTickrate
			MPControllerGE.tick() -- Comment this line to disable controller synchronization
		end
	end
end



M.onPlayerConnect = onPlayerConnect
M.onUpdate        = onUpdate
M.onInit = function() setExtensionUnloadMode(M, "manual") end


return M
