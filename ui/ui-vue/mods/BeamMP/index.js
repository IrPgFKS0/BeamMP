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


// LAN: bottom info-bar version badge. Upstream 4.22 removed the old bottom-left "BeamMP vX" info-bar
// injection (the version now only shows inside the BeamMP menu sidebar) -- but at-a-glance build
// identification from the MAIN menu has repeatedly mattered on this LAN, so re-add a small badge in
// the game's info-bar (the same wrapper upstream's margin observer reads). Data comes from the
// onBeamMPInfo hook; we also poke Lua once so it shows without opening the BeamMP menu.
const LAN_BADGE_ID = "beammp-lan-version-badge"
function upsertLanVersionBadge(data) {
  try {
    const bar = document.querySelector("#vue-app > div.vue-app-main > div.app-infobar-wrapper")
    if (!bar) return
    let el = document.getElementById(LAN_BADGE_ID)
    if (!el) {
      el = document.createElement("div")
      el.id = LAN_BADGE_ID
      el.style.cssText = "display:inline-flex;align-items:center;margin-left:0.5em;padding:0.15em 0.6em;" +
        "background:rgba(0,0,0,0.65);border-radius:0.25em;font-size:0.85em;color:#fff;white-space:nowrap;"
      bar.appendChild(el)
    }
    el.textContent = "BeamMP v" + (data?.beammpGameVer || "?") + " · launcher " + (data?.beammpLauncherVer || "?")
  } catch (e) { /* the badge is cosmetic -- never let it break the mod */ }
}
function removeLanVersionBadge() {
  const el = document.getElementById(LAN_BADGE_ID)
  if (el && el.parentNode) el.parentNode.removeChild(el)
}

export async function onLoad() {
  events.on("onBeamMPShowVueDialog", showBeamMPDialog)
  events.on("onBeamMPInfo", upsertLanVersionBadge) // LAN version badge feed
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
    icon: "personSolid",
    //componentName: `${MOD_ROOT}/cards/BeamMPPauseMainCard.vue`,
    componentName: `${MOD_ROOT}/cards/BeamMPPausePlayersCard.vue`,
  })
  await lua.extensions.ui_pause_actions.registerModButton({
    id: "beammp-pause-server-details	",
    tabId: TAB_ID,
    label: $translate.instant("ui.common.beammp.serverDetails"),
    icon: "personSolid",
    componentName: `${MOD_ROOT}/cards/BeamMPPauseServerDetailsRedirect.vue`,
  })
}

export async function onUnload() {
  events.off("onBeamMPShowVueDialog", showBeamMPDialog)
  events.off("onBeamMPInfo", upsertLanVersionBadge) // LAN version badge cleanup
  removeLanVersionBadge()

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
