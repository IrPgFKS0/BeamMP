-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPConfig API - This script sets Default settings if not present and handles session specific data.
-- Author of this documentation is Titch2000
-- @module MPConfig
-- @usage local nickname = getNickname() -- internal access
-- @usage local nickname = MPConfig.getNickname() -- external access


local M = {}

-- MP VARIABLES
local Nickname = ""
local PlayerServerID = -1

--- Returns a table of all to the disk saved unicycle configs
-- @treturn[1] table eg. {"MyFavConfig": "MyFavConfig.pc"}
-- @usage INTERNAL ONLY / GAME SPECIFIC
local function getUnicycleConfigs()
	-- Load the unicycle configurations:
	local pcfiles = FS:findFiles("/vehicles/unicycle/", "*.pc", 0, true, false)
	local pcFileRegex = "^/vehicles/unicycle/(.*)%.pc"
	local tmp = {}

	for _, filename in ipairs(pcfiles) do
		local file = filename:match(pcFileRegex)
		if file ~= "beammp_default" then
			tmp[file] = file..'.pc'
		end
	end

	if tmp ~= settings.getValue('unicycleConfigs') then settings.setValue('unicycleConfigs', tmp) end -- multiplayer.partial ui will read this value
	return tmp
end

--- Sets a new default Unicycle
-- @tparam string configFileName eg. "MyFavConfig" not "MyFavConfig.pc"
-- @treturn[1] true if Success
-- @treturn[2] nil if Failure
local function setDefaultUnicycle(configFileName)
	local configFileName = configFileName .. ".pc"
	local handle = io.open("vehicles/unicycle/" .. configFileName, "r")
	if handle == nil then
		log('I', "setDefaultUnicycle", 'Cannot open "vehicles/unicycle/' .. configFileName .. '" in read mode.')
		return nil
	end
	local newconfig = handle:read("*all")
	handle:close()
	
	local handle = io.open("vehicles/unicycle/beammp_default.pc", "w")
	if handle == nil then
		log('I', "setDefaultUnicycle", 'Cannot open "vehicles/unicycle/beammp_default.pc" in write mode.')
		return nil
	end
	handle:write(newconfig)
	handle:close()
	return true
end

local defaultSettings = {
	autoSyncVehicles = true, nameTagShowDistance = true, enableBlobs = true, showSpectators = true, licensePlateUsesPlayerName = true, nametagCharLimit = 32, showPlayerIDs = true, nameTagsHideBehindObjects = false,
	-- queue system
	enableSpawnQueue = true, enableQueueAuto = true, queueSkipUnicycle = true, queueApplySpeed = 2, queueApplyTimeout = 3, highlightQueuedPlayers = true,
	-- colors
	showBlobQueued = true, blobColorQueued = "#FF6400", showBlobIllegal = true, blobColorIllegal = "#000000", showBlobDeleted = true, blobColorDeleted = "#333333",

	-- ui app style selector
	useUiAppRedesign = 0, -- default: old style
	
	-- new chat menu
	enableNewChatMenu = false,

	-- show custom vehicles in vehicle selector
	showPcs = true,
	
	enablePosSmoother = false, -- experimental
	profilePosSync = false, -- experimental (LAN): log avg/max timing of applyPos (GE) + setVehiclePosRot/updateGFX (VE) every ~5s to beamng.log
	profLogFolder = "BeamMP_logs", -- LAN/debug: folder (under the BeamNG user folder) where MPConfig.collectProfilingLogs() writes the zipped beamng*.log bundle
	saveLogsAction = false, -- LAN/debug: transient trigger for the in-game "Save all logs" button. bngApi.engineLua isn't reliably in the options ng-click scope, so the button sets this via the settings path; onSettingsChanged runs MPConfig.saveLogs() and resets it (same pattern as unicycle_pc).
	physicsRateSend = true, -- LAN default-on (A/B verified): emit own-vehicle position from the VE physics step (~100Hz) instead of once per render frame, so low-FPS machines still send fresh data. Toggle off via the options checkbox if needed.
	physRateSendHz = 30, -- LAN (default 30 since p13h33): the physics-rate send rate in Hz, pushed to positionVE.setSendHz via refreshFlags (live). 100 oversubscribed the relay (~150 pkt/s cap) with 2 players -> growing latency -> remote tracking DEGRADED over a session (hardware-confirmed worse than stock 10Hz). 30 = ~60 pkt/s for 2 players, under the cap, and the predictor interpolates between updates so it looks smooth (no need for a high rate). 10 = exact stock. UI select 60/30/10 (the 100Hz option was removed -- it oversubscribes the relay with 2+ players; a saved 100 is migrated to 30 in positionGE.refreshFlags).
	mailboxApplyPos = true, -- LAN default-on (A/B verified): deliver incoming positions GE->VE via the engine mailbox (be:sendToMailbox) instead of queueLuaCommand; VE polls per frame. ~25-40% cheaper applyPos + removes the per-packet VE Lua-command compile. Falls back to the base64 queueLuaCommand path when off. Toggle off via the options checkbox if needed.
	optimizeMapMarkers = true, -- LAN default-on (perf): disable BeamNG's per-frame mission/POI marker processing (gameplay_markerInteraction.onPreRender) during MP -- a known FPS sink, useless for LAN driving. Restored on leave. Ported from Olrosse/BeamMP minimap_lag_workaround. Toggle off to keep vanilla freeroam markers.
	applyStallDiag = false, -- LAN/diagnostic (off by default): when a remote ghost FREEZES (positionVE.updateGFX stops applying received positions), log ONE 'posApplyStall' line naming the cause -- packets not reaching the VE (GE->VE delivery), rejected out-of-order (sender clock reset on respawn), the simSpeed-scaled VE timer racing past packetTimeout, or packets genuinely stopped. Pushed to positionVE.setApplyStallDiag via positionGE.refreshFlags (live). Off = zero per-frame work + no logs. Use /savelogs after a freeze and grep posApplyStall.
	syncFullDeformation = false, -- REMOVED 2026-07-09 (was: experimental full node/beam deformation sync). Intrinsically too CPU-heavy: ~100KB JSON of every node+beam at 2Hz per vehicle in VE Lua + a full apply pass on every receiver; transport fixes (#245 chunking) couldn't save it. Kept registered ONLY so old settings.json files don't warn (aiChaseIncludeSelf precedent); no code reads it.
	remoteFullProjectiles = false, -- LAN/weapons (default off, CPU saver): a weapon car another player DRIVES always fires full physics projectiles; this forces SPAWNED/AI remote weapon cars to fire full projectiles too instead of a light muzzle+sound replay. CPU-heavy with many guns -- enable only if all machines have headroom. Read GE-side in MPWeaponsGE.handleFire.
	autoSpawnMode = 0, -- LAN: auto-spawn on join. 0=off, 1=default car, 2=last used car
	showSyncStats = false, -- LAN: tiny on-screen overlay with synced vehicle count + net packet rates
	logSyncStats = false, -- LAN: also write the sync-health line to beamng.log every ~15s (review via /savelogs after a drift episode); toggle with /synclog
	directVehicleSocket = false, -- #245 EXPERIMENTAL (default OFF): own vehicles send POSITION + INPUTS straight to the launcher's direct UDP socket (launcherPort+2), bypassing the VE->GE Lua queue + the GE proxy (the measured send-side funnel). Pairs with the p13h34+ combined/launcher exe; SAFE anywhere -- the mod only leaves the GE path after the launcher ACKS the socket (no ack in 3s = one-shot log + revert), so an old launcher or blocked port can never eat a car silently. Slow-mo velocity scaling is skipped on the direct path (identical at normal speed). A/B against the profiler ('GE sendVehiclePosRot' drops toward 0 when active).
	allowEnvSync = true, -- LAN/consent (default ON so /syncenv works out of the box): apply environment pushes (/syncenv or the pause-menu button) from other players. Off = incoming pushes are ignored with a short toast naming who tried. Default ON (unlike chase consent) because an env change is mild, reversible and sender-attributed.
	allowRemoteAIChase = false, -- LAN/consent (default off, opt-in): allow OTHER players' AI/weapon cars to chase ME when I'm their nearest valid target. Your OWN cars chasing is unchanged (AI radial "Chase"); they target yourself + remote players who turned this on. Synced via MPVehicleGE chaseOptIn ('B'/C: relay). UI: "Allow other players' AI cars to chase me".
	aiChaseIncludeSelf = false, -- DEPRECATED: "include yourself as a target" is now AUTOMATIC in retargetLocalAICars (so BeamNG's "Chase"=chase-the-local-player works). Kept registered only to avoid an "unrecognized setting" warning on old configs; no longer read by code.
	showVramWarning = true, -- LAN: warn in chat when tracked VRAM use nears the card total (heavy-mod crash guard)
	defaultCameraFov = 0, -- REMOVED from the UI in p13h71 (user wants distance only). Kept registered so an existing settings.json holding it doesn't warn; no code reads it.
	defaultCameraDistance = 0, -- LAN: default ORBIT camera distance (meters) applied on vehicle switch/camera change/vehicle reset -- this is the lever the zoom keys actually move on the orbit cam, so it zooms OUT as well as in. 0 = off (each vehicle's own default, typically ~5m).

	-- Settings the mod reads/writes (or the options UI binds) but that were never registered
	-- here, so a settings.json holding them logged "Unrecognized setting name" on load. Defaults
	-- match each reader's fallback; the loader only fills a key when it's nil, so existing user
	-- values are preserved -- registering just stops the warning.
	skipOtherPlayersVehicles = false, -- spectate: skip other players' non-active vehicles when tabbing through
	queueAutoSkipRemote = false,      -- queue: auto-apply queued events for remote vehicles you tab into
	skipModSecurityWarning = false,   -- skip the "mods found" download confirmation prompt
	showAdvancedMPOptions = false,    -- options menu: reveal the advanced/LAN settings section
	mpLastVehicle = "",               -- JSON {model,config} of the last spawned car (autoSpawn mode 2)
	cullFarVehicles = false,          -- legacy: view-distance cull was removed; kept registered to silence
	fastApplyPos = false,             -- legacy/experimental position-apply toggle

	-- unicycle configurations
	unicycleConfigs = getUnicycleConfigs(), unicycleAutoSave = true,
	--unicycle_pc = nil, -- temp value introduced to share the user selected default unicycle config from the multiplayer.partial ui to MPConfig.setDefaultUnicycle()

	disableInstabilityPausing = true,

	refreshIngame = false,

	playerlistLeftclick = 0, -- 0 - queue events, 1 - switch camera, 2 - open forum, 3 - delete, 4 - restore, 5 - copy name

	launcherPort = 4444
}

--- Reads the user's saved settings straight off disk. The game's settings loader DROPS keys it
--- doesn't know about at boot (see onExtensionLoaded), so "value is nil" does NOT mean "the user
--- never set it" -- it usually means the loader threw their value away before we registered it.
local function readSavedSettings()
	-- The game keeps TWO files (lua/common/settings.lua): cloud-scoped keys in cloud/settings.json,
	-- local-scoped in settings.json. The six nametag keys h88 registered are cloud-scoped, so a
	-- refill that only read the local file could never restore them. Read both; local wins on overlap.
	local merged = {}
	for _, savedPath in ipairs({ settings.impl and settings.impl.pathCloud or '/settings/cloud/settings.json',
	                             settings.impl and settings.impl.pathLocal or '/settings/settings.json' }) do
		local ok, saved = pcall(jsonReadFile, savedPath)
		if ok and type(saved) == 'table' then
			for k, v in pairs(saved) do merged[k] = v end
		end
	end
	return merged
end

--- Upstream 4.22 registers the stock MP settings from /settings/mp_defaults.json instead of
--- hardcoding them in Lua (that file also carries the [scope, value] pair, so 'cloud' settings
--- register with the right scope). Kept as-is apart from the fork's restore rule: a dropped key
--- is refilled from the user's saved file first, and only falls back to the shipped default.
--- @tparam table savedValues Result of readSavedSettings()
--- @treturn number How many settings were restored from the user's file rather than defaulted.
local function loadMPDefaults(savedValues)
	savedValues = savedValues or {}
	local mpDefaults = jsonReadFile('/settings/mp_defaults.json')
	if not mpDefaults then
		log('W', 'loadMPDefaults', 'Unable to read /settings/mp_defaults.json')
		return 0
	end

	local restored = 0
	for settingName, settingDef in pairs(mpDefaults) do
		local settingType = settingDef[1]
		local defaultValue = settingDef[2]

		if settings.impl and settings.impl.defaults and settingType ~= nil then
			settings.impl.defaults[settingName] = { settingType, defaultValue }
		end
		if settings.impl and settings.impl.defaultValues and defaultValue ~= nil then
			settings.impl.defaultValues[settingName] = defaultValue
		end

		if defaultValue ~= nil and (settings.getValue(settingName) == nil or settingName == 'unicycleConfigs') then
			if savedValues[settingName] ~= nil and settingName ~= 'unicycleConfigs' then
				settings.setValue(settingName, savedValues[settingName])
				restored = restored + 1
			else
				settings.setValue(settingName, defaultValue)
			end
		end
	end
	return restored
end

-- Register the settings DEFAULTS at module load (not only in onExtensionLoaded below), so readers
-- that run before this extension's onExtensionLoaded -- e.g. positionGE reading physRateSendHz ~1s
-- into startup -- don't trip BeamNG's "Unrecognized setting name" warning. This ONLY seeds the
-- defaults registry; it never calls setValue, so saved user values are untouched (persistence is
-- handled in onExtensionLoaded). Guarded against the settings API not being ready yet / API churn.
if settings and settings.impl then
	for k, v in pairs(defaultSettings) do
		if settings.impl.defaults and settings.impl.defaults[k] == nil then settings.impl.defaults[k] = { 'local', v } end
		if settings.impl.defaultValues and settings.impl.defaultValues[k] == nil then settings.impl.defaultValues[k] = v end
	end
end

--- Called when the mod is loaded by the games modloader.
-- @usage INTERNAL ONLY / GAME SPECIFIC
local function onExtensionLoaded()
	-- The game's settings loader (lua/common/settings.lua upgradeSetting) DROPS any
	-- settings.json key that is not in its defaults registry at load time -- and it loads
	-- ~6s before this extension registers our keys ("Unrecognized setting name" x40 each
	-- boot). The values usually survive through a later merge, but that is a boot-order
	-- race: any save in the window rewrites the file without them (observed: keys written
	-- by one session vanished after the next). So when a key is nil in the live values,
	-- restore the USER'S SAVED value straight from the settings file before falling back
	-- to our default.
	local savedValues = readSavedSettings()
	-- upstream's stock settings (mp_defaults.json) first, then the fork's LAN-only ones below
	local restored = loadMPDefaults(savedValues)
	for k,v in pairs(defaultSettings) do
		if settings.getValue(k) == nil or k == 'unicycleConfigs' then
			if savedValues[k] ~= nil and k ~= 'unicycleConfigs' then
				settings.setValue(k, savedValues[k])
				restored = restored + 1
			else
				settings.setValue(k, v)
			end
		end
		-- Register each key in the game's settings defaults (settings.impl == lua/common/settings.lua,
		-- whose M.defaults is what the "Unrecognized setting name" check reads). {'local', v} is the
		-- game's [scope, value] default format. Guarded against settings-API churn between versions.
		if settings.impl and settings.impl.defaults then settings.impl.defaults[k] = { 'local', v } end
		if settings.impl and settings.impl.defaultValues then settings.impl.defaultValues[k] = v end
	end
	if restored > 0 then
		log('I', 'mpSettingsRestore', 'restored '..restored..' saved MP setting(s) the game loader had dropped')
	end

	if settings.getValue("queueWithLMB") ~= nil then
		settings.setValue("playerlistLeftclick", settings.getValue("queueWithLMB") and 0 or 1)
		settings.setValue("queueWithLMB", nil)
	end

	--dump(defaultSettings)
	settings.impl.invalidateCache()
end

--- Set the users Nickname variable for use by other aspects of the mod.
-- @tparam string x The users nickname that we have received.
-- @usage MPConfig.setNickname(`<nickname>`)
local function setNickname(x)
	log('M', 'setNickname', 'Nickname Set To: '..x)
	Nickname = x
end

--- Get the users Nickname.
-- @treturn string The users nickname.
-- @usage local nickname = MPConfig.getNickname()
local function getNickname()
	return Nickname
end

--- Sets the ID the server gave this Client, for use by other aspects of the mod.
-- @tparam number x The PlayerServerID that we have received.
-- @usage MPConfig.setPlayerServerID(`<players server ID>`)
local function setPlayerServerID(x)
	PlayerServerID = tonumber(x)
end

--- Get the PlayerServerID variable.
-- @treturn number The users server ID.
-- @usage local nickname = MPConfig.getPlayerServerID()
local function getPlayerServerID()
	return PlayerServerID
end

--- Check for old configuration files and move them to the new location if found.
-- @treturn boolean True if any files were moved, false otherwise.
-- @usage local updatedConfigs = MPConfig.checkForOldConfig()
local function checkForOldConfig()
	if not FS:directoryExists("BeamMP") then
		return false
	end

	if not FS:directoryExists("settings/BeamMP") then
		FS:directoryCreate("settings/BeamMP")
	end

	local movedfiles = false

	local oldfav = '/BeamMP/favorites.json'
	local newfav = '/settings/BeamMP/favorites.json'
	if FS:fileExists(oldfav) then
		FS:copyFile(oldfav, newfav)
		FS:removeFile(oldfav)
		movedfiles = true
	end

	local oldconf = '/BeamMP/config.json'
	local newconf = '/settings/BeamMP/config.json'
	if FS:fileExists(oldconf) then
		FS:copyFile(oldconf, newconf)
		FS:removeFile(oldconf)
		movedfiles = true
	end
	return movedfiles
end

--- Get the favorites from the favorites.json file.
-- @treturn table The favorites data.
-- @usage local favorites = MPConfig.getFavorites()
local function getFavorites()
	if not FS:directoryExists("settings/BeamMP") then
		if checkForOldConfig() then
			return getFavorites()
		else
			return nil
		end
	end

	local favs = nil
	local favsfile = '/settings/BeamMP/favorites.json'
	if FS:fileExists(favsfile) then
		favs = jsonReadFile(favsfile)
	else
		log('M', 'getFavorites', "Favs file doesn't exist")
	end
	
	local function sortByAgeDesc(a, b)
		return a.addTime > b.addTime
	end

	-- Sort the data table using the comparison function
	if favs then
		table.sort(favs, sortByAgeDesc)
	else
		log('E', 'getFavorites', 'Unable to read favorites from file or file is empty')
		favs = {} -- Initialize favs to an empty table to avoid further errors
	end

	local cleanedServers = {}

  -- Create a table to track which keys have already been added to the filtered data
  local addedKeys = {}

  -- Iterate over the input data table
  for i, server in ipairs(favs) do
    -- Get the value of the key for this object
    local serverKey = ''..server['ip']..':'..server['port']

    -- If the key has not been added to the filtered data yet, add the object and mark the key as added
    if not addedKeys[serverKey] then
      table.insert(cleanedServers, server)
      addedKeys[serverKey] = true
    end
  end

	return cleanedServers
end

--- Set the favorites in the favorites.json file.
-- @tparam string favstr The favorites data as a base64 encoded string.
-- @usage MPConfig.setFavorites(`<favorites table>`)
local function setFavorites(favstr)
	local favstr = MPHelpers.b64decode(favstr)
	if not FS:directoryExists("settings/BeamMP") then
		FS:directoryCreate("settings/BeamMP")
	end

	local favs = jsonDecode(favstr)
	local favsfile = '/settings/BeamMP/favorites.json'
	jsonWriteFile(favsfile, favs, true)
end

--- Get the configuration from the config.json file.
-- @treturn table The configuration data.
-- @usage local config = MPConfig.getConfig()
local function getConfig()
	if not FS:directoryExists("settings/BeamMP") then
		if checkForOldConfig() then
			return getConfig()
		else
			return nil
		end
	end

	local file = '/settings/BeamMP/config.json'
	if FS:fileExists(file) then
		return jsonReadFile(file)
	else
		log('M', 'getConfig', "Config file doesn't exist")
		return nil
	end
end

--- Set a configuration setting in the config.json file.
-- @tparam string settingName The name of the setting.
-- @param settingVal The value of the setting.
-- @usage MPConfig.setConfig(`<setting name>, <setting value>`)
local function setConfig(settingName, settingVal)
	local config = getConfig()
	if not config then config = {} end

	config[settingName] = settingVal

	local favsfile = '/settings/BeamMP/config.json'
	jsonWriteFile(favsfile, config, true)
end

--- Accept the BeamMP terms of service.
-- @usage INTERNAL ONLY / GAME SPECIFIC
local function acceptTos()
	local config = getConfig()
	if not config then config = {} end

	config.tos = true

	local favsfile = '/settings/BeamMP/config.json'
	jsonWriteFile(favsfile, config, true)
end

--- Serialize the data for saving.
-- @treturn table The serialized data.
-- @usage INTERNAL ONLY / GAME SPECIFIC
local function onSerialize()
	local data = {
		Nickname = Nickname,
		PlayerServerID = PlayerServerID
	}
	return data
end

--- Deserialize the data when loading.
-- @tparam table data The deserialized data.
-- @usage INTERNAL ONLY / GAME SPECIFIC
local function onDeserialized(data)
	Nickname = data.Nickname
	PlayerServerID = data.PlayerServerID
end

--- Multiplayer Options <-> Lua data bridge
-- @usage INTERNAL ONLY / GAME SPECIFIC
local function onSettingsChanged()
	local unicycle_pc = settings.getValue("unicycle_pc")
	if unicycle_pc ~= nil then
		setDefaultUnicycle(unicycle_pc)
		settings.setValue("unicycle_pc", nil) -- reset to prevent reapply on every setting change
		guihooks.trigger('toastrMsg', {type="info", title = "Unicycle", msg = MPTranslate("ui.options.multiplayer.unicycleOnSwitch") .. " " .. unicycle_pc, config = {timeOut = 3000}})
	end
	if settings.getValue("saveLogsAction") then
		settings.setValue("saveLogsAction", false) -- reset to prevent reapply on every setting change
		if M.saveLogs then M.saveLogs() end
	end
	if M.applyDefaultCamera then M.applyDefaultCamera() end -- LAN: apply the default-camera-distance slider live
	getUnicycleConfigs()
end

--- Collect the BeamNG log files (beamng.log + its rotations) into a single timestamped
--- zip, so everything needed for a profiling (profilePosSync) capture is gathered in one
--- correctly-zipped bundle with nothing missed. The output goes in the folder named by the
--- `profLogFolder` setting, created under the BeamNG user folder (the game sandboxes file
--- writes there -- arbitrary external drive paths aren't writable from Lua). Returns the
--- real on-disk path of the zip so the UI/console can show exactly where it landed.
-- @usage MPConfig.collectProfilingLogs()
local function collectProfilingLogs()
	local result
	local ok, err = pcall(function()
		local folder = settings.getValue("profLogFolder")
		if not folder or folder == "" then folder = "BeamMP_logs" end
		-- normalize to a relative folder under the user folder (no leading/trailing slash)
		folder = tostring(folder):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
		if folder == "" then folder = "BeamMP_logs" end
		if not FS:directoryExists(folder) then FS:directoryCreate(folder) end

		local zipPath = folder .. "/beamng_logs_" .. os.date("%Y%m%d-%H%M%S") .. ".zip"
		local zip = ZipArchive()
		if not zip:openArchiveName(zipPath, "w") then
			log('E', 'collectProfilingLogs', 'could not open zip for writing: ' .. zipPath)
			guihooks.trigger('toastrMsg', {type = "error", title = "Profiling logs",
				msg = "Couldn't create the zip (folder not writable?): " .. zipPath, config = {timeOut = 6000}})
			return
		end

		-- Explicit known log names (beamng.log + rotations) -- robust regardless of how
		-- many rotations exist. They live at the Lua FS root (the active version folder).
		local n = 0
		local names = {"beamng.log"}
		for i = 1, 9 do names[#names + 1] = "beamng." .. i .. ".log" end
		for _, name in ipairs(names) do
			if FS:fileExists("/" .. name) then
				zip:addFile("/" .. name, name)
				n = n + 1
			end
		end
		zip:close()

		result = zipPath -- return the FS path; show the real path in the toast/log
		local realPath = FS:getFileRealPath(zipPath) or zipPath
		log('I', 'collectProfilingLogs', 'zipped ' .. n .. ' log file(s) -> ' .. tostring(realPath))
		guihooks.trigger('toastrMsg', {type = (n > 0 and "success" or "warning"), title = "Profiling logs",
			msg = (n > 0 and (n .. " log file(s) zipped to:\n" .. tostring(realPath))
			              or "No beamng*.log files found to collect."), config = {timeOut = 9000}})
	end)
	if not ok then
		log('E', 'collectProfilingLogs', 'failed: ' .. tostring(err))
		guihooks.trigger('toastrMsg', {type = "error", title = "Profiling logs",
			msg = "Failed to collect logs: " .. tostring(err), config = {timeOut = 6000}})
	end
	return result
end

-- Best-effort machine name from env vars (COMPUTERNAME on Windows, HOSTNAME/HOST on Linux).
-- Usually "unknown" in BeamNG's sandboxed game env; the launcher patches the real hostname in.
local function getDeviceName()
	-- env vars only. BeamNG sandboxes io.popen (it logs a "Lua tried to open a process"
	-- warning) and the game env usually lacks these vars, so this commonly returns "unknown"
	-- -- the LAUNCHER patches the real hostname into mp_state.txt during the gather
	-- (GlobalHandler HandleSaveLogs), which is why we don't try popen here.
	local n = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or os.getenv("HOST")
	if not n or n == "" then return "unknown" end
	return (n:gsub("%s+$", ""))
end

-- LAN/debug: a one-shot snapshot of MP state (version, session, level, the toggles that
-- have bitten us before, players + vehicles). Pure read-only; every lookup is pcall-guarded
-- so a missing field never breaks log collection.
local function buildMpStateText()
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	local function tg(fn, d) local ok, v = pcall(fn); if ok and v ~= nil then return v else return d end end
	add("=== BeamMP MP state ===")
	add("time: " .. os.date("%Y-%m-%d %H:%M:%S"))
	add("mod version: " .. tostring(tg(function() return MPCoreNetwork.getModVersion() end, "?")))
	add("device: " .. getDeviceName())
	-- role: is the server running on THIS machine? Inferred from a loopback server IP -- the
	-- host self-hosts via 127.0.0.1, a pure client joins the host's LAN IP.
	local srv = tg(function() return MPCoreNetwork.getCurrentServer() end, nil)
	local sip = (type(srv) == "table") and srv.ip or nil
	local isHost = type(sip) == "string" and (sip == "localhost" or sip == "::1" or sip:match("^127%.") ~= nil)
	add("role: " .. (isHost and "SERVER HOST (server runs on this machine)" or "CLIENT (server is remote)")
		.. (sip and ("  [joined " .. tostring(sip) .. ":" .. tostring(type(srv) == "table" and srv.port or "?") .. "]") or ""))
	add("session: isMPSession=" .. tostring(tg(function() return MPCoreNetwork.isMPSession() end, "?"))
		.. " launcherConnected=" .. tostring(tg(function() return MPGameNetwork.launcherConnected() end, "?")))
	add("level: " .. tostring(tg(function() return getCurrentLevelIdentifier() end, "?")))
	for _, k in ipairs({ "showDebugOutput", "physicsRateSend", "physRateSendHz", "allowRemoteAIChase", "showVramWarning" }) do
		add("setting " .. k .. " = " .. tostring(tg(function() return settings.getValue(k) end, "?")))
	end
	local players = tg(function() return MPVehicleGE.getPlayers() end, {})
	add("players:")
	if type(players) == "table" then
		for id, p in pairs(players) do
			add(string.format("  - id %s  name '%s'  activeVeh %s",
				tostring(id), tostring(type(p) == "table" and p.name or p), tostring(type(p) == "table" and p.activeVehicleID)))
		end
	end
	-- getVehicles() is keyed by serverVehicleString and the values are the vehicle objects
	-- (with .jbeam/.ownerName/.isLocal) -- getVehicleMap() instead maps gameID->string, which
	-- is why the old dump showed jbeam/own as false.
	local vehs = tg(function() return MPVehicleGE.getVehicles() end, {})
	add("vehicles:")
	if type(vehs) == "table" then
		for sid, v in pairs(vehs) do
			if type(v) == "table" then
				add(string.format("  - serverID %s  jbeam %s  owner '%s'  local %s",
					tostring(sid), tostring(v.jbeam), tostring(v.ownerName), tostring(v.isLocal == true)))
			end
		end
	end
	return table.concat(lines, "\n")
end

-- LAN/debug: toggle verbose network-packet logging (showDebugOutput) from chat.
-- arg "on"/"off" sets explicitly; anything else toggles. Read live by MPGameNetwork.onUpdate.
local function setNetDebug(arg)
	local on
	if arg == "on" then on = true
	elseif arg == "off" then on = false
	else on = not (settings.getValue("showDebugOutput") == true) end
	settings.setValue("showDebugOutput", on)
	local m = "Network debug logging " .. (on and "ENABLED" or "disabled") .. " (showDebugOutput)"
	log('I', 'setNetDebug', m)
	guihooks.trigger('toastrMsg', { type = "info", title = "BeamMP", msg = m, config = { timeOut = 4000 } })
end

-- LAN/debug: print the MP-state snapshot to the GE console (~) and beamng.log.
local function printMpState()
	log('I', 'mpstate', "\n" .. buildMpStateText())
	guihooks.trigger('toastrMsg', { type = "info", title = "BeamMP MP state",
		msg = "MP state written to the GE console (~) and beamng.log.", config = { timeOut = 6000 } })
end

-- LAN/debug: gather EVERY log into one zip in the BeamMP Launcher folder -- BeamNG + BeamMP
-- + launcher, and the server log/state if the server runs on this machine. Writes
-- mp_state.txt for the launcher to include, signals the launcher over the game proxy
-- ("savelogs:<ts>", intercepted there and never forwarded to the server), and also makes the
-- local beamng*.log zip as a fallback. Both /savelogs and the in-game button call this.
local function saveLogs()
	pcall(function()
		if not FS:directoryExists("BeamMP_logs") then FS:directoryCreate("BeamMP_logs") end
		local h = io.open("BeamMP_logs/mp_state.txt", "w")
		if h then h:write(buildMpStateText()); h:close() end
	end)
	local ts = os.date("%Y%m%d-%H%M%S")
	local triggered = false
	pcall(function()
		if MPGameNetwork and MPGameNetwork.send and MPGameNetwork.launcherConnected and MPGameNetwork.launcherConnected() then
			MPGameNetwork.send("savelogs:" .. ts)
			triggered = true
		end
	end)
	pcall(collectProfilingLogs) -- local beamng*.log zip fallback (works even against an old launcher)
	local m = triggered
		and ("Gathering logs -> BeamMP_logs_" .. ts .. ".zip in your BeamMP Launcher folder (BeamNG + launcher + server-if-local).")
		or ("Launcher not connected -- wrote only a local beamng.log zip (see the BeamMP_logs folder).")
	log('I', 'saveLogs', m)
	guihooks.trigger('toastrMsg', { type = "success", title = "BeamMP savelogs", msg = m, config = { timeOut = 9000 } })
end

-- LAN: one-shot environment sync. /syncenv pushes the SENDER'S full environment state
-- (time of day, clouds, fog, wind, precipitation, gravity, temperature -- the game's own
-- core_environment.getState() snapshot) to every other player over the reliable 'B' relay
-- (sub-tag "E:", demuxed in MPWeaponsGE.handle). One-time adopt, no continuous sync.
-- Old-mod peers ignore the unknown sub-tag silently, so mixed versions are safe.
local function sendEnvSync()
	if not (MPGameNetwork and MPGameNetwork.launcherConnected and MPGameNetwork.launcherConnected()) then
		guihooks.trigger('toastrMsg', { type = "warning", title = "Environment sync",
			msg = "Not in a session -- nothing to sync to.", config = { timeOut = 4000 } })
		return
	end
	local ok, state = pcall(function() return core_environment.getState() end)
	if not ok or type(state) ~= 'table' then
		log('W', 'envSync', 'core_environment.getState() unavailable: ' .. tostring(state))
		guihooks.trigger('toastrMsg', { type = "error", title = "Environment sync",
			msg = "Could not read the environment state on this game version.", config = { timeOut = 5000 } })
		return
	end
	MPGameNetwork.send("BE:" .. jsonEncode({ from = getNickname(), env = state }))
	log('I', 'envSync', 'environment state pushed to other players')
	guihooks.trigger('toastrMsg', { type = "success", title = "Environment sync",
		msg = "Your environment (time of day, weather, wind...) was pushed to the other players.",
		config = { timeOut = 5000 } })
end

local function applyEnvSync(payload)
	local ok, data = pcall(jsonDecode, payload)
	if not ok or type(data) ~= 'table' or type(data.env) ~= 'table' then
		log('W', 'envSync', 'received unparseable env-sync payload')
		return
	end
	if settings.getValue("allowEnvSync") == false then -- consent: user opted out of adopting pushes
		log('I', 'envSync', 'ignored env push from ' .. tostring(data.from) .. ' (allowEnvSync off)')
		guihooks.trigger('toastrMsg', { type = "info", title = "Environment sync",
			msg = "Ignored an environment push from " .. tostring(data.from or "another player") .. " (disabled in your Multiplayer settings).",
			config = { timeOut = 4000 } })
		return
	end
	local applied = pcall(function() core_environment.setState(data.env, 2) end) -- 2s blend
	if applied then
		log('I', 'envSync', 'environment adopted from ' .. tostring(data.from))
		guihooks.trigger('toastrMsg', { type = "info", title = "Environment sync",
			msg = "Environment adopted from " .. tostring(data.from or "another player") .. ".",
			config = { timeOut = 5000 } })
	else
		log('W', 'envSync', 'core_environment.setState failed on this game version')
	end
end

-- LAN: default ORBIT camera distance (meters). The zoom keys on the orbit camera move
-- DISTANCE, so this is the lever that lets a default sit zoomed OUT as well as in.
-- Applied on vehicle switches / camera-mode changes / vehicle resets / slider moves;
-- 0 = off (vehicle default). (The p13h70 FOV slider was removed on user request --
-- distance is the wanted control; defaultCameraFov stays registered-but-inert.)
local function applyDefaultCamera()
	pcall(function()
		local veh = be:getPlayerVehicle(0)
		if not veh or not core_camera then return end
		local dist = tonumber(settings.getValue("defaultCameraDistance")) or 0
		if dist >= 1 then
			if dist > 50 then dist = 50 end
			local vid = veh:getID()
			-- Make ours the camera's OWN default first: the orbit cam's reset path is
			-- literally `camDist = defaultDistance` (orbit.lua), so setting the default
			-- means vehicle resets restore OUR distance natively -- no re-apply race
			-- (the p13h73 deferred re-apply hack is gone because of this).
			if core_camera.setDefaultDistance then core_camera.setDefaultDistance(vid, dist) end
			if core_camera.setDistance then core_camera.setDistance(vid, dist) end
		end
	end)
end

-- Events
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onExtensionLoaded = onExtensionLoaded
M.onSettingsChanged = onSettingsChanged
M.onVehicleSwitched = function(oldId, newId, player)
	if newId and newId ~= -1 then applyDefaultCamera() end
end
M.onCameraModeChanged = function() applyDefaultCamera() end
-- No onVehicleResetted hook needed: applyDefaultCamera sets the orbit cam's OWN
-- defaultDistance, and the camera's reset path restores exactly that value.

-- Functions
M.getPlayerServerID = getPlayerServerID
M.setPlayerServerID = setPlayerServerID
M.setDefaultUnicycle = setDefaultUnicycle

M.getNickname = getNickname
M.setNickname = setNickname

M.getFavorites = getFavorites
M.setFavorites = setFavorites
M.getConfig = getConfig
M.setConfig = setConfig
M.collectProfilingLogs = collectProfilingLogs
M.saveLogs = saveLogs
M.buildMpStateText = buildMpStateText
M.setNetDebug = setNetDebug
M.printMpState = printMpState
M.sendEnvSync = sendEnvSync   -- LAN: /syncenv chat command (UI.chatSend)
M.applyEnvSync = applyEnvSync -- LAN: receive side ('B' relay "E:" sub-tag via MPWeaponsGE.handle)
M.applyDefaultCamera = applyDefaultCamera

M.acceptTos = acceptTos
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
