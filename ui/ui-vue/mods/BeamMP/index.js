// BeamMP New UI?
// import bridge and route definitions
import { useBridge } from "@/bridge"
import { ROUTE_SOURCE_ID, routeRecords } from "./routes.js"
import { BEAMMP_ROUTE_NAME } from "./shared/constants.js"
import { $translate } from "@/services/translation"
import { ACCENTS } from "@/common/components/base"
import { openConfirmation } from "@/services/popup"

// get lua and events interfaces
const { api, lua, events } = useBridge()
// note: here we use "low-level" events from the bridge because this file is not a Vue component
//       so, never forget to unsubscribe from events when the mod is unloaded

// mod root directory
const MOD_ROOT = "/ui/ui-vue/mods/BeamMP"

// title for the button and tabs
const TITLE = "BeamMP"
const TITLE_translationId = 'ui.common.beammp.title'

// 1 and 2. Register a Main Menu button. `addButton` is a function.
function addBeamMPMainMenuButton(addButton) {
  addButton({
    // Old Angular-compatible menu button shape.
    //translateid: TITLE_translationId,
    //icon: `${MOD_ROOT}/icons/account-multiple.svg`,
    //targetState: BEAMMP_ROUTE_NAME,

    // New Vue Way
    // main menu button title
    title: TITLE,
    // main menu button icon (must be a valid icon id from the bngIcons.js)
    iconId: "peopleOutline",
    // route to open when the button is pressed
    action: BEAMMP_ROUTE_NAME,
  })
}

// Vue records include component objects, while Lua only needs the serialisable route configuration.
function toLuaRoutes(records) {
  return records.map(record => ({
    name: record.name,
    path: record.path,
    meta: record.meta,
    ...(record.children ? { children: toLuaRoutes(record.children) } : {}),
  }))
}

// Register the Vue matcher first, then expose the same route to Lua navigation.
async function registerRoutes() {
  window.bngRoutes.add([{ path: ROUTE_SOURCE_ID, routes: routeRecords }])
  const result = await lua.extensions.ui_router_routeManager.registerModRoutes(
    ROUTE_SOURCE_ID,
    toLuaRoutes(routeRecords),
  )
  if (!result?.success) {
    window.bngRoutes.remove([ROUTE_SOURCE_ID])
    console.error("Failed to register BeamMP route", result?.errors)
  }
  return result
}

// Remove the Vue matcher first so navigation cannot target a stale component.
async function unregisterRoutes() {
  window.bngRoutes.remove([ROUTE_SOURCE_ID])
  await lua.extensions.ui_router_routeManager.unregisterModRoutes(
    ROUTE_SOURCE_ID,
    { fallbackRoute: "menu" },
  )
}

// convenience ID for for example #3
const TAB_ID = "beammp"
let activeBeamMPDialog = null

async function showBeamMPDialog(options = {}) {
  if (activeBeamMPDialog) return

  activeBeamMPDialog = openConfirmation(
    options.title || $translate.instant("ui.beammp.mdDialog.disconnectGeneric"),
    options.text || "",
    [
      {
        label: options.okText || $translate.instant("ui.beammp.mdDialog.returnToMenu"),
        value: "returnToMenu",
        extras: { default: true, confirm: true, accent: ACCENTS.main },
      },
      {
        label: $translate.instant("ui.beammp.mdDialog.continueOffline"),
        value: "continueOffline",
        extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text },
      },
    ],
  )

  try {
    const result = await activeBeamMPDialog
    if (result === "returnToMenu") {
      api.engineLua(
        options.okLua
        || "if MPCoreNetwork and MPCoreNetwork.leaveServer then MPCoreNetwork.leaveServer(true) end",
      )
    }
  } finally {
    activeBeamMPDialog = null
  }
}


// LAN: bottom info-bar version badge, styled like 0.38. Upstream 4.22 dropped the injection (their
// last iteration lived in the deleted Angular modModules file, commit 380eb73d); this recreates it
// against 0.39's InfoBar: the badge is appended INTO the game's .info-bar-stats row, so it inherits
// the native font/size/line and sits immediately right of the game's version pill, separated by the
// same skewed orange divider the bar itself uses. Re-attached on a slow interval because the menu
// DOM remounts on route transitions. Cosmetic-only: every step is guarded.
const LAN_BADGE_ID = "beammp-lan-version-badge"
let lanBadgeInfo = null
let lanBadgeTimer = null
let lanBadgeLastPoke = 0
function lanBadgeAttach() {
  try {
    const stats =
      document.querySelector("#vue-app .app-infobar-wrapper .info-bar-stats")
      || document.querySelector("#vue-app .info-bar .info-bar-stats")
      || document.querySelector(".info-bar-stats")
    if (!stats) return
    const ver = lanBadgeInfo && lanBadgeInfo.beammpGameVer
    if (!ver) {
      // The menu app's module state resets on play->pause transitions, so the cached
      // version is gone on every Esc. NEVER render a "?" placeholder -- ask Lua for the
      // info (throttled) and only attach once the version is known; the badge then
      // appears fully-formed on the next tick after the event lands.
      const now = Date.now()
      if (now - lanBadgeLastPoke > 900) {
        lanBadgeLastPoke = now
        api.engineLua("if MPCoreNetwork and MPCoreNetwork.sendBeamMPInfo then MPCoreNetwork.sendBeamMPInfo() end")
      }
      return
    }
    let el = document.getElementById(LAN_BADGE_ID)
    if (!el) {
      el = document.createElement("span")
      el.id = LAN_BADGE_ID
      // flex:0 0 auto + nowrap: the "-LAN pNN" string is longer than stock and the bar is a flex
      // row -- without this it gets squeezed to "BeamMP v..." (same fix the 0.38 fork needed).
      el.style.cssText = "display:inline-flex;align-items:center;white-space:nowrap;flex:0 0 auto;"
      el.innerHTML =
        '<span class="divider" style="display:inline-block;width:.25rem;height:1.8em;margin:0 .2rem 0 .5rem;background-color:#f60;transform:skew(-23deg);"></span>' +
        '<span style="padding:0 .25em;">BeamMP&nbsp;v.<span id="beammp-lan-version-text" style="font-weight:600;"></span></span>'
      stats.appendChild(el)
    }
    const txt = document.getElementById("beammp-lan-version-text")
    if (txt) txt.textContent = String(ver)
  } catch (e) { /* cosmetic only -- never let the badge break the mod */ }
}
function upsertLanVersionBadge(data) {
  lanBadgeInfo = data || lanBadgeInfo
  lanBadgeAttach()
}
function removeLanVersionBadge() {
  if (lanBadgeTimer) { clearInterval(lanBadgeTimer); lanBadgeTimer = null }
  const el = document.getElementById(LAN_BADGE_ID)
  if (el && el.parentNode) el.parentNode.removeChild(el)
}

// LAN: "Sync environment to players" button injected into the pause menu's Environment
// digest (.pause-environment-digest), same DOM-injection pattern as the version badge --
// the game's pause components use scoped CSS an injected element can't join, so the
// button is styled inline. Only shown in an MP session (checked via Lua per attach);
// clicking runs the same one-shot push as the /syncenv chat command.
const ENV_SYNC_BTN_ID = "beammp-env-sync-btn"
let envSyncTimer = null
function envSyncBtnAttach() {
  try {
    const panel = document.querySelector(".pause-environment-digest")
    const existing = document.getElementById(ENV_SYNC_BTN_ID)
    if (!panel) {
      if (existing && existing.parentNode) existing.parentNode.removeChild(existing)
      return
    }
    if (existing) return
    api.engineLua("(MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession()) and true or false", inSession => {
      try {
        if (!inSession) return
        if (document.getElementById(ENV_SYNC_BTN_ID)) return
        const p = document.querySelector(".pause-environment-digest")
        if (!p) return
        const btn = document.createElement("button")
        btn.id = ENV_SYNC_BTN_ID
        btn.type = "button"
        btn.textContent = "Sync environment to players"
        btn.title = "One-time push of YOUR time of day / weather / wind to everyone in the session (same as /syncenv)"
        btn.style.cssText = "display:block;width:100%;margin-top:.6rem;padding:.55rem .75rem;border:1px solid rgba(255,255,255,.25);border-radius:4px;background:rgba(255,102,0,.18);color:#fff;font:inherit;font-weight:600;text-align:left;cursor:pointer;"
        btn.onmouseenter = () => { btn.style.background = "rgba(255,102,0,.38)" }
        btn.onmouseleave = () => { btn.style.background = "rgba(255,102,0,.18)" }
        btn.onclick = () => {
          api.engineLua("if MPConfig and MPConfig.sendEnvSync then MPConfig.sendEnvSync() end")
          btn.disabled = true
          const oldText = btn.textContent
          btn.textContent = "Environment pushed."
          setTimeout(() => { try { btn.disabled = false; btn.textContent = oldText } catch (e) { /* gone */ } }, 2500)
        }
        p.appendChild(btn)
      } catch (e) { /* cosmetic only -- never let the button break the pause menu */ }
    })
  } catch (e) { /* cosmetic only */ }
}
function removeEnvSyncBtn() {
  if (envSyncTimer) { clearInterval(envSyncTimer); envSyncTimer = null }
  const el = document.getElementById(ENV_SYNC_BTN_ID)
  if (el && el.parentNode) el.parentNode.removeChild(el)
}

export async function onLoad() {
  events.on("onBeamMPShowVueDialog", showBeamMPDialog)
  events.on("onBeamMPInfo", upsertLanVersionBadge) // LAN version badge feed
  lanBadgeTimer = setInterval(lanBadgeAttach, 350) // re-attach across menu remounts (fast tick: the badge vanishes when Esc remounts the menu DOM, and a 2s tick left a visible gap)
  envSyncTimer = setInterval(envSyncBtnAttach, 700) // pause Environment digest button
  api.engineLua("if MPCoreNetwork and MPCoreNetwork.sendBeamMPInfo then MPCoreNetwork.sendBeamMPInfo() end")

  // Register the standalone route before advertising its Main Menu button.
  const routeResult = await registerRoutes()
  if (routeResult?.success) {
    // This event is sent when we're in the main menu.
    events.on("MainMenuButtons", addBeamMPMainMenuButton)
    // Broadcast this event in case we already were in main menu when the mod loaded
    events.emit("BroadcastMainMenuButtons")
  }

  // 3. A dedicated "BeamMP" pause tab.
  // tab must be registered before its buttons, so make sure to await for it
  await lua.extensions.ui_pause_actions.registerModTab({
    id: TAB_ID,
    label: TITLE,
    icon: "peopleOutline",
    //card2ComponentName: `${MOD_ROOT}/cards/BeamMPPausePlayersCard.vue`,
  })
  // then, register rail buttons for that tab
  await lua.extensions.ui_pause_actions.registerModButton({
    id: "beammp-pause-player-list",
    tabId: TAB_ID,
    label: $translate.instant("ui.common.beammp.playerList"),
    icon: "itemsTree",
    //componentName: `${MOD_ROOT}/cards/BeamMPPauseMainCard.vue`,
    componentName: `${MOD_ROOT}/cards/BeamMPPausePlayersCard.vue`,
  })
  await lua.extensions.ui_pause_actions.registerModButton({
    id: "beammp-pause-server-details	",
    tabId: TAB_ID,
    label: $translate.instant("ui.common.beammp.serverDetails"),
    icon: "globeSimplified",
    componentName: `${MOD_ROOT}/cards/BeamMPPauseServerDetailsRedirect.vue`,
  })
}

export async function onUnload() {
  events.off("onBeamMPShowVueDialog", showBeamMPDialog)
  events.off("onBeamMPInfo", upsertLanVersionBadge) // LAN version badge cleanup
  removeLanVersionBadge()
  removeEnvSyncBtn()

  // stop listening for the Main Menu button - this is important to do to avoid memory leaks
  events.off("MainMenuButtons", addBeamMPMainMenuButton)
  events.emit("BroadcastMainMenuButtons") // poke buttons to update

  // remove the standalone route
  await unregisterRoutes()

  // you can unregister buttons manually at any time like so:
  // await lua.extensions.ui_pause_actions.unregisterModButton("annas-toolbox-workshop")
  // await lua.extensions.ui_pause_actions.unregisterModButton("annas-toolbox-vehicle")

  // however, unregisterModTab already unregisters its buttons, so this call is enough for cleanup
  await lua.extensions.ui_pause_actions.unregisterModTab(TAB_ID)
}
