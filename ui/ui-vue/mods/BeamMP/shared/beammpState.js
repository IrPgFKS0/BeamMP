import { computed, ref } from "vue"

const DEFAULT_FILTERS = {
  searchText: "",
  playerCountMin: 0,
  playerCountMax: 64,
  sliderMaxModSize: 80530,
  selectedMaps: [],
  selectedServerVersions: [],
  selectedTags: [],
  selectedServerLocations: [],
  matchAll: true,
}

const tagThemes = {
  Freeroam: "",
  Roleplay: "",
  Economy: "",
  Traffic: "",
  Drift: "",
  Crawling: "",
  Touge: "",
  Offroad: "",
  Challenge: "",
  "Gamemode:Racing": "",
  "Gamemode:Rally": "",
  "Gamemode:Drag": "",
  "Gamemode:Derby": "",
  "Gamemode:Infection": "",
  "Gamemode:Cops-Robbers": "",
  "Gamemode:Delivery": "",
  "Gamemode:Sumo": "",
  Scenarios: "",
  Events: "",
  Modded: "",
  Vanilla: "",
  Moderated: "",
}

const state = {
  isReady: ref(false),
  tosAccepted: ref(localStorage.getItem("tosAccepted") === "true"),
  launcherConnected: ref(false),
  loggedIn: ref(false),
  loginError: ref(""),
  auth: ref({}),
  beammpMetrics: ref({
    players: "...",
    servers: "...",
    beammpGameVer: "...",
    beammpLauncherVer: "...",
  }),
  servers: ref([]),
  loadingOverlayVisible: ref(false),
  loadingStatus: ref(""),
  downloadingMods: ref([]),
  selectedServerId: ref(""),
  securityPromptVisible: ref(false),
  securityPromptMessage: ref(""),
  filters: ref(loadFilters()),
  favorites: ref([]),
  recents: ref(loadRecents()),
  view: ref("servers"),
}

let listenersReady = false

function bngApi() {
  return window.bngApi
}

function engineLua(command, callback) {
  const api = bngApi()
  if (!api?.engineLua) return
  api.engineLua(command, callback)
}

function luaCall(command) {
  return new Promise(resolve => {
    engineLua(command, data => resolve(data))
  })
}

function encodeBase64(input) {
  return btoa(new TextEncoder().encode(input).reduce((acc, byte) => acc + String.fromCharCode(byte), ""))
}

function decodeBase64(input) {
  return new TextDecoder().decode(Uint8Array.from(atob(input), c => c.charCodeAt(0)))
}

function loadRecents() {
  const encoded = localStorage.getItem("recents")
  if (!encoded) return []
  try {
    return JSON.parse(decodeBase64(encoded))
  } catch {
    try {
      return JSON.parse(encoded)
    } catch {
      return []
    }
  }
}

function saveRecents() {
  localStorage.setItem("recents", encodeBase64(JSON.stringify(state.recents.value)))
}

function loadFilters() {
  const fromStorage = JSON.parse(localStorage.getItem("serverListOptions") || "null")
  const merged = {
    ...DEFAULT_FILTERS,
    ...(fromStorage || {}),
  }
  if (!Array.isArray(merged.selectedMaps)) merged.selectedMaps = []
  if (!Array.isArray(merged.selectedServerVersions)) merged.selectedServerVersions = []
  if (!Array.isArray(merged.selectedTags)) merged.selectedTags = []
  if (!Array.isArray(merged.selectedServerLocations)) merged.selectedServerLocations = []
  return merged
}

function saveFilters() {
  localStorage.setItem("serverListOptions", JSON.stringify(state.filters.value))
}

function stripCustomFormatting(name = "") {
  return name.replace(/\^[0-9a-frlmnop*]/gi, "")
}

function smoothMapName(map = "") {
  if (!map) return ""
  const stripped = map.replace("/info.json", "").split("/").pop()
  return String(stripped || "")
    .replace(/_/g, " ")
    .replace(/-/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, m => m.toUpperCase())
}

function formatBytes(bytes = 0, decimals = 2) {
  if (!bytes) return "0 Bytes"
  const k = 1024
  const dm = decimals < 0 ? 0 : decimals
  const sizes = ["Bytes", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`
}

function normalizeServer(server) {
  return {
    ...server,
    strippedName: stripCustomFormatting(server?.sname || ""),
    mapName: smoothMapName(server?.map || ""),
    id: `${server?.ip}:${server?.port}`,
    tagsList: formatServerTags(server?.tags || ""),
  }
}

function modList(mods = "") {
  if (!mods) return []
  return mods
    .split(";")
    .map(m => m.trim())
    .filter(Boolean)
    .map(m => m.split("/").pop().replace(".zip", ""))
    .sort((a, b) => a.localeCompare(b))
}

function formatRawTag(rawTag) {
  const parts = rawTag.trim().split(":")
  return {
    raw: rawTag.trim(),
    text: parts[1] || rawTag.trim(),
    prefix: parts[0],
    theme: tagThemes[rawTag.trim()] ?? null,
  }
}

function formatServerTags(commaList = "") {
  return commaList
    .split(",")
    .map(tag => tag.trim())
    .filter(Boolean)
    .map(formatRawTag)
}

function applyFilters(items, view) {
  const f = state.filters.value
  const tags = (f.selectedTags || []).map(tag => String(tag.raw || tag).toLowerCase())
  const maps = f.selectedMaps || []
  const versions = f.selectedServerVersions || []
  const locations = f.selectedServerLocations || []

  return items.filter(server => {
    if (view === "official" && !server.official) return false
    if (view === "featured" && !server.featured) return false
    if (view === "partner" && !server.partner) return false

    if (view === "favorites" && !isFavorite(server)) return false
    if (view === "recent" && !isRecent(server)) return false

    if (f.searchText && !server.strippedName.toLowerCase().includes(f.searchText.toLowerCase())) return false

    const checks = []

    checks.push(Number(server.players || 0) >= Number(f.playerCountMin || 0))
    checks.push(Number(server.players || 0) <= Number(f.playerCountMax || 9999))

    if (server.modstotalsize) {
      checks.push((Number(f.sliderMaxModSize) * 1048576) >= Number(server.modstotalsize))
    }

    if (maps.length > 0) {
      checks.push(maps.includes(server.mapName))
    }

    if (versions.length > 0) {
      checks.push(versions.includes(`v${server.version}`))
    }

    if (locations.length > 0) {
      checks.push(locations.includes(server.location))
    }

    if (tags.length > 0) {
      const lowerTags = (server.tags || "").toLowerCase().split(",").map(t => t.trim())
      const matched = tags.filter(tag => lowerTags.includes(tag)).length
      checks.push(f.matchAll ? matched === tags.length : matched > 0)
    }

    return checks.every(Boolean)
  })
}

function readServerList(data) {
  const list = Array.isArray(data) ? data : []
  state.servers.value = list.map(normalizeServer)
  if (state.selectedServerId.value) {
    const exists = state.servers.value.some(server => server.id === state.selectedServerId.value)
    if (!exists) state.selectedServerId.value = ""
  }
}

function isFavorite(server) {
  return state.favorites.value.some(f => `${f.ip}:${f.port}` === server.id)
}

function isRecent(server) {
  return state.recents.value.some(r => `${r.ip}:${r.port}` === server.id)
}

function addRecent(server) {
  if (!server) return
  const trimmed = state.recents.value.filter(r => !(r.ip === server.ip && r.port === server.port))
  trimmed.push({
    ip: server.ip,
    port: server.port,
    sname: server.sname,
    strippedName: server.strippedName,
    addTime: Date.now(),
  })
  state.recents.value = trimmed.slice(-50)
  saveRecents()
}

function saveFavorites() {
  const encoded = encodeBase64(JSON.stringify(state.favorites.value))
  engineLua(`MPConfig.setFavorites('${encoded}')`)
}

async function loadFavorites() {
  const data = await luaCall("MPConfig.getFavorites()")
  if (!data) {
    state.favorites.value = []
    return
  }
  if (typeof data === "object" && Object.keys(data).length === 0) {
    state.favorites.value = []
    return
  }
  state.favorites.value = Array.isArray(data) ? data : []
}

function addFavorite(server) {
  if (!server) return
  const exists = state.favorites.value.some(f => f.ip === server.ip && f.port === server.port)
  if (exists) return
  state.favorites.value = [...state.favorites.value, {
    ip: server.ip,
    port: server.port,
    sname: server.sname,
    strippedName: server.strippedName,
    location: server.location,
    map: server.map,
    tags: server.tags,
    addTime: Date.now(),
    custom: Boolean(server.custom),
  }]
  saveFavorites()
}

function removeFavorite(server) {
  state.favorites.value = state.favorites.value.filter(f => !(f.ip === server.ip && f.port === server.port))
  saveFavorites()
}

function selectServer(serverId) {
  state.selectedServerId.value = state.selectedServerId.value === serverId ? "" : serverId
}

async function refreshConnectionState() {
  state.loggedIn.value = Boolean(await luaCall("MPCoreNetwork.isLoggedIn()"))
  state.launcherConnected.value = Boolean(await luaCall("MPCoreNetwork.isLauncherConnected()"))
}

async function requestServerList() {
  engineLua("MPCoreNetwork.requestServerList()")
}

async function connectToLauncher() {
  engineLua("MPCoreNetwork.connectToLauncher()")
}

async function login(username, password) {
  state.loginError.value = ""
  if (!username || !password) {
    state.loginError.value = "Missing credentials"
    return
  }
  const api = bngApi()
  const credentials = { username: username.trim(), password: password.trim() }
  engineLua(`MPCoreNetwork.login(${api.serializeToLua(credentials)})`)
}

async function guestLogin() {
  state.loginError.value = ""
  engineLua("MPCoreNetwork.login()")
}

async function logout() {
  engineLua("MPCoreNetwork.logout()")
  state.loggedIn.value = false
  state.auth.value = {}
}

async function connectToServer(ip, port, name = "", skipModWarning = false) {
  const useIp = (ip || "127.0.0.1").trim()
  const usePort = Number(port || "30814")
  state.loadingOverlayVisible.value = true
  state.loadingStatus.value = ""
  state.downloadingMods.value = []
  engineLua(`MPCoreNetwork.connectToServer(\"${useIp}\", ${usePort}, \"${name || ""}\", ${skipModWarning ? "true" : "false"})`)
}

function closeLoadingOverlay() {
  state.loadingOverlayVisible.value = false
  state.loadingStatus.value = ""
  state.downloadingMods.value = []
  engineLua("MPCoreNetwork.leaveServer()")
}

function showSecurityPrompt(message = "") {
  state.securityPromptMessage.value = message || ""
  state.securityPromptVisible.value = true
}

function approveSecurityPrompt() {
  state.securityPromptVisible.value = false
  state.securityPromptMessage.value = ""
  engineLua("MPCoreNetwork.approveModDownload()")
}

function rejectSecurityPrompt() {
  state.securityPromptVisible.value = false
  state.securityPromptMessage.value = ""
  engineLua("MPCoreNetwork.rejectModDownload()")
  state.loadingOverlayVisible.value = false
}

async function directConnectFromClipboard() {
  return await luaCall("getClipboard()")
}

function openExternal(url) {
  if (!url) return
  engineLua(`MPCoreNetwork.openURL(\"${url}\")`)
}

async function getLauncherVersion() {
  return await luaCall("MPCoreNetwork.getLauncherVersion()")
}

function acceptTos() {
  localStorage.setItem("tosAccepted", "true")
  state.tosAccepted.value = true
  engineLua("MPConfig.acceptTos()")
}

function setView(viewName) {
  state.view.value = viewName
}

function updateFilter(patch) {
  state.filters.value = {
    ...state.filters.value,
    ...patch,
  }
  saveFilters()
}

function resetFilters() {
  state.filters.value = {
    ...DEFAULT_FILTERS,
  }
  saveFilters()
}

function clearRecents() {
  state.recents.value = []
  localStorage.removeItem("recents")
}

function onLoadingInfo(payload) {
  const message = payload?.message || ""
  if (!message) return

  if (message.startsWith("Downloading Resource")) {
    const regex = /Downloading Resource (\d+\/\d+): (.+?) \((\d+\.\d+)%\)(?: at (.+))?/
    const match = message.match(regex)
    if (!match) return

    const [_, number, name, progress, speed] = match
    const next = [...state.downloadingMods.value]
    const existing = next.find(m => m.name === name)
    if (existing) {
      existing.progress = Number(progress)
      existing.speed = speed || "..."
    } else {
      next.unshift({ number, name, progress: Number(progress), speed: speed || "..." })
    }
    state.downloadingMods.value = next
    return
  }

  if (message === "done") {
    state.loadingStatus.value = "Done"
    return
  }

  state.loadingStatus.value = message
}

function ensureListeners(events) {
  if (listenersReady) return
  listenersReady = true

  events.on("onServerListReceived", data => readServerList(data))
  events.on("LoadingInfo", payload => onLoadingInfo(payload))
  events.on("LoggedIn", () => {
    state.loggedIn.value = true
    state.loginError.value = ""
  })
  events.on("actuallyLoggedIn", data => {
    state.loggedIn.value = Boolean(data)
  })
  events.on("LoginError", data => {
    state.loginError.value = String(data || "Login failed")
  })
  events.on("onLauncherConnected", () => {
    state.launcherConnected.value = true
  })
  events.on("LauncherConnectionLost", () => {
    state.launcherConnected.value = false
  })
  events.on("authReceived", data => {
    state.auth.value = data || {}
  })
  events.on("onServerJoined", () => {
    state.loadingOverlayVisible.value = false
  })
  events.on("DownloadSecurityPrompt", data => {
    showSecurityPrompt(data?.message || "")
  })
}

const availableTags = computed(() => {
  const tags = new Set()
  state.servers.value.forEach(server => {
    formatServerTags(server.tags || "").forEach(tag => tags.add(tag.raw))
  })
  return [...tags].sort((a, b) => a.localeCompare(b)).map(tag => formatRawTag(tag))
})

const availableMaps = computed(() => {
  const maps = new Set()
  state.servers.value.forEach(server => {
    if (server.mapName) maps.add(server.mapName)
  })
  return [...maps].sort((a, b) => a.localeCompare(b))
})

const availableVersions = computed(() => {
  const versions = new Set()
  state.servers.value.forEach(server => versions.add(`v${server.version}`))
  return [...versions].sort((a, b) => a.localeCompare(b))
})

const availableLocations = computed(() => {
  const locations = new Set()
  state.servers.value.forEach(server => {
    if (server.location) locations.add(server.location)
  })
  return [...locations].sort((a, b) => a.localeCompare(b))
})

const selectedServer = computed(() => state.servers.value.find(s => s.id === state.selectedServerId.value) || null)

const visibleServers = computed(() => {
  const byFilter = applyFilters(state.servers.value, state.view.value)
  if (state.view.value === "recent") {
    const recentMap = Object.fromEntries(state.recents.value.map(r => [`${r.ip}:${r.port}`, r.addTime || 0]))
    return [...byFilter].sort((a, b) => (recentMap[b.id] || 0) - (recentMap[a.id] || 0))
  }
  return byFilter
})

export function useBeamMPState(events) {
  if (events) ensureListeners(events)

  return {
    state,
    acceptTos,
    addFavorite,
    addRecent,
    availableLocations,
    availableMaps,
    availableTags,
    availableVersions,
    clearRecents,
    closeLoadingOverlay,
    connectToLauncher,
    connectToServer,
    directConnectFromClipboard,
    formatBytes,
    getLauncherVersion,
    guestLogin,
    isFavorite,
    isRecent,
    loadFavorites,
    login,
    logout,
    modList,
    openExternal,
    refreshConnectionState,
    removeFavorite,
    requestServerList,
    resetFilters,
    approveSecurityPrompt,
    rejectSecurityPrompt,
    selectServer,
    selectedServer,
    showSecurityPrompt,
    setView,
    smoothMapName,
    updateFilter,
    visibleServers,
  }
}
