<!-- LAN: seamless map switcher (p13h103). Replaces the imgui popup that "/maps" used to open.
     Data: ONE snapshot from MPCoreNetwork.getMapSwitcherState() (maps with previews, the current level, a
     loopback "you are the host" hint); the switch is MPCoreNetwork.requestMapSwitch(name), which sends the
     same "/map <name>" chat line the old picker sent -- the server still decides who may switch. Progress
     arrives through the `onBeamMPMapSwitchState` hook (requested -> switching -> done | failed | denied). -->
<template>
  <section class="beammp-maps">
    <header class="page-header">
      <div>
        <span class="eyebrow">{{ tr("ui.beammp.maps.eyebrow", "BeamMP session") }}</span>
        <h2>{{ tr("ui.beammp.maps.title", "Maps") }}</h2>
      </div>
      <div v-if="snapshot.inSession" class="header-chips">
        <span v-if="currentTitle" class="chip chip--current">
          {{ tr("ui.beammp.maps.current", "Current map") }}: <strong>{{ currentTitle }}</strong>
        </span>
        <span class="chip" :class="snapshot.isHost ? 'chip--host' : 'chip--client'">
          {{ snapshot.isHost ? tr("ui.beammp.maps.hostHint", "You are hosting -- a switch applies to everyone") : tr("ui.beammp.maps.clientHint", "The server decides who may switch (host or admin)") }}
        </span>
      </div>
    </header>

    <div v-if="loading" class="status-panel">{{ tr("ui.beammp.maps.loading", "Loading maps...") }}</div>

    <div v-else-if="!snapshot.inSession" class="status-panel status-panel--warning">
      {{ tr("ui.beammp.maps.noSession", "Join a server first -- this page switches the map of the session you are in.") }}
    </div>

    <template v-else>
      <div v-if="banner" class="status-panel" :class="bannerClass" role="status">{{ banner }}</div>
      <div v-if="snapshot.error" class="status-panel status-panel--warning">{{ snapshot.error }}</div>

      <div class="toolbar">
        <BngInput v-model="query" class="search" :placeholder="tr('ui.beammp.maps.search', 'Search maps')" />
        <span class="count">{{ filtered.length }} / {{ snapshot.maps.length }}</span>
        <BngButton :accent="ACCENTS.secondary" @click="refresh">{{ tr("ui.beammp.maps.refresh", "Refresh") }}</BngButton>
      </div>

      <div class="layout">
        <div class="grid" role="list">
          <button
            v-for="m in filtered"
            :key="m.name"
            type="button"
            class="tile"
            role="listitem"
            :class="{ 'tile--selected': m.name === selectedName, 'tile--current': m.name === snapshot.current }"
            :title="m.path || m.name"
            @click="selectedName = m.name"
            @dblclick="askSwitch(m)"
          >
            <div class="tile-image">
              <BngImage v-if="m.preview" class="preview" :src="m.preview" />
              <div v-else class="preview preview--none"><BngIcon :type="icons.map" /></div>
              <span v-if="m.name === snapshot.current" class="badge badge--current">{{ tr("ui.beammp.maps.currentBadge", "Current") }}</span>
              <span class="badge badge--source" :class="{ 'badge--mod': !m.official }">
                {{ m.official ? tr("ui.beammp.maps.official", "BeamNG") : tr("ui.beammp.maps.mod", "Mod") }}
              </span>
            </div>
            <div class="tile-title">{{ m.title }}</div>
            <div class="tile-sub">{{ m.name }}</div>
          </button>
          <div v-if="!filtered.length" class="muted empty">{{ tr("ui.beammp.maps.noMatch", "No map matches your search.") }}</div>
        </div>

        <aside v-if="selected" class="panel details">
          <BngImage v-if="selected.preview" class="details-preview" :src="selected.preview" />
          <div v-else class="details-preview details-preview--none"><BngIcon :type="icons.map" /></div>
          <h3>{{ selected.title }}</h3>
          <dl>
            <div><dt>{{ tr("ui.beammp.maps.level", "Level") }}</dt><dd>{{ selected.name }}</dd></div>
            <div><dt>{{ tr("ui.beammp.maps.source", "Source") }}</dt><dd>{{ selected.source }}</dd></div>
            <div v-if="selected.path"><dt>{{ tr("ui.beammp.maps.path", "Path") }}</dt><dd class="mono">{{ selected.path }}</dd></div>
          </dl>
          <div class="actions">
            <BngButton :accent="ACCENTS.main" :disabled="!canSwitch" @click="askSwitch(selected)">{{ switchLabel }}</BngButton>
          </div>
          <p class="muted hint">
            {{ snapshot.isHost ? tr("ui.beammp.maps.hostNote", "Every connected player loads the new map in place; cars are re-spawned on it.") : tr("ui.beammp.maps.clientNote", "If the server does not allow you to switch, its answer shows here.") }}
          </p>
        </aside>
        <aside v-else class="panel details muted">{{ tr("ui.beammp.maps.select", "Select a map to see its details.") }}</aside>
      </div>

      <div class="actions page-actions">
        <BngButton @click="resume">{{ tr("ui.beammp.maps.resume", "Resume") }}</BngButton>
      </div>
    </template>
  </section>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from "vue"
import { useBridge } from "@/bridge"
import { ACCENTS, BngButton, BngIcon, BngImage, BngInput, icons } from "@/common/components/base"
import { confirmCancelButtons, openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"
import { useBeamMPState } from "../shared/beammpState.js"

const { api, events } = useBridge()
const bngVue = window.bngVue || { gotoGameState() {} }
const { extensionCall, state } = useBeamMPState(events)

// Translation with an English fallback: the game's $translate returns the KEY when a language lacks it,
// and the fork's LAN strings only ship in en-US.
function tr(key, fallback, vars) {
  let text = $translate.instant(key)
  if (!text || text === key) text = fallback
  if (vars) for (const [k, v] of Object.entries(vars)) text = text.split(`{${k}}`).join(String(v))
  return text
}

const EMPTY = { inSession: false, changing: false, phase: "idle", maps: [], current: "", currentPath: "", isHost: false, error: null }
const loading = ref(true)
const snapshot = ref({ ...EMPTY })
const query = ref("")
const selectedName = ref("")
const status = ref(null) // { phase, map, message } -- the last onBeamMPMapSwitchState payload (or a local refusal)

// Lua tables cross the bridge as arrays when they are sequences and as objects when empty
function asArray(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object") return Object.values(value)
  return []
}

function normalize(raw) {
  if (!raw || typeof raw !== "object") return { ...EMPTY }
  return {
    inSession: raw.inSession === true,
    changing: raw.changing === true,
    phase: raw.phase || "idle",
    current: raw.current || "",
    currentPath: raw.currentPath || "",
    isHost: raw.isHost === true,
    error: raw.error || null,
    maps: asArray(raw.maps).filter(m => m && m.name).map(m => ({
      name: String(m.name),
      title: String(m.title || m.name),
      preview: m.preview || "",
      official: m.official === true,
      source: String(m.source || ""),
      path: m.path || "",
    })),
  }
}

const filtered = computed(() => {
  const q = query.value.trim().toLowerCase()
  if (!q) return snapshot.value.maps
  return snapshot.value.maps.filter(m => m.title.toLowerCase().includes(q) || m.name.toLowerCase().includes(q) || m.source.toLowerCase().includes(q))
})

const selected = computed(() => snapshot.value.maps.find(m => m.name === selectedName.value) || null)
const currentTitle = computed(() => {
  const cur = snapshot.value.maps.find(m => m.name === snapshot.value.current)
  return cur ? cur.title : snapshot.value.current
})

const inFlight = computed(() => snapshot.value.changing || (status.value && (status.value.phase === "requested" || status.value.phase === "switching")))
const canSwitch = computed(() => snapshot.value.inSession && !inFlight.value && !!selected.value && selected.value.name !== snapshot.value.current)

const switchLabel = computed(() => {
  if (!selected.value) return tr("ui.beammp.maps.switch", "Switch map")
  if (selected.value.name === snapshot.value.current) return tr("ui.beammp.maps.alreadyCurrent", "Already the current map")
  if (inFlight.value) return tr("ui.beammp.maps.busy", "Switch in progress...")
  return tr("ui.beammp.maps.switchTo", "Switch to {map}", { map: selected.value.title })
})

const banner = computed(() => {
  const s = status.value
  if (!s) return snapshot.value.changing ? tr("ui.beammp.maps.switching", "Switching map to {map}... large maps can take a minute.", { map: snapshot.value.current || "" }) : ""
  const map = s.map || ""
  switch (s.phase) {
    case "requested": return tr("ui.beammp.maps.requested", "Switch to {map} requested -- waiting for the server...", { map })
    case "switching": return tr("ui.beammp.maps.switching", "Switching map to {map}... large maps can take a minute.", { map }) + (state.loadingStatus.value ? ` (${state.loadingStatus.value})` : "")
    case "done": return tr("ui.beammp.maps.done", "Map switched to {map}.", { map })
    case "failed": return tr("ui.beammp.maps.failed", "Map switch failed: {message}", { message: s.message || "" })
    case "denied": return tr("ui.beammp.maps.denied", "The server refused: {message}", { message: s.message || "" })
    case "refused": return tr("ui.beammp.maps.refused", "Not sent: {message}", { message: s.message || "" })
    default: return ""
  }
})

const bannerClass = computed(() => {
  const phase = status.value?.phase || (snapshot.value.changing ? "switching" : "")
  if (phase === "failed" || phase === "denied" || phase === "refused") return "status-panel--warning"
  if (phase === "done") return "status-panel--ok"
  return ""
})

async function refresh() {
  loading.value = true
  const raw = await extensionCall("MPCoreNetwork", "getMapSwitcherState")
  snapshot.value = normalize(raw)
  if (!selectedName.value || !snapshot.value.maps.some(m => m.name === selectedName.value)) {
    selectedName.value = snapshot.value.current && snapshot.value.maps.some(m => m.name === snapshot.value.current) ? snapshot.value.current : (snapshot.value.maps[0]?.name || "")
  }
  loading.value = false
}

async function askSwitch(m) {
  if (!m || !canSwitch.value || m.name !== selected.value?.name) return
  const confirmed = await openConfirmation(
    tr("ui.beammp.maps.confirmTitle", "Switch the server's map?"),
    tr("ui.beammp.maps.confirmText", "Every connected player will load {map}. Cars are re-spawned on the new map; large maps can take a minute.", { map: m.title }),
    confirmCancelButtons({ confirmLabel: tr("ui.beammp.maps.confirm", "Switch map") }),
  )
  if (confirmed !== true) return
  const res = await extensionCall("MPCoreNetwork", "requestMapSwitch", api.serializeToLua(m.name))
  if (res && res.ok === true) {
    status.value = { phase: "requested", map: m.title, message: "" }
  } else {
    status.value = { phase: "refused", map: m.title, message: (res && res.reason) || tr("ui.beammp.maps.noAnswer", "no answer from the game") }
  }
}

function onSwitchState(payload) {
  const p = payload && typeof payload === "object" ? payload : {}
  const known = snapshot.value.maps.find(m => m.name === p.map)
  status.value = { phase: p.phase || "idle", map: known ? known.title : (p.map || ""), message: p.message || "" }
  snapshot.value = { ...snapshot.value, changing: p.changing === true }
  if (p.phase === "done") refresh()
}

function onServerJoined() {
  refresh()
}

function resume() {
  bngVue.gotoGameState("play")
}

onMounted(() => {
  events.on("onBeamMPMapSwitchState", onSwitchState)
  events.on("onBeamMPServerJoined", onServerJoined)
  refresh()
})

onUnmounted(() => {
  events.off("onBeamMPMapSwitchState", onSwitchState)
  events.off("onBeamMPServerJoined", onServerJoined)
})
</script>

<style scoped lang="scss">
.beammp-maps {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  max-width: 80rem;
}

.page-header,
.toolbar,
.actions {
  display: flex;
  align-items: center;
}

.page-header {
  justify-content: space-between;
  gap: 1rem;
  padding: 0.25rem 0.2rem 0.7rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.14);

  h2 {
    margin: 0.15rem 0 0;
  }
}

.eyebrow {
  color: var(--bng-orange-300);
  font-size: 0.75rem;
  font-weight: 700;
  text-transform: uppercase;
}

.header-chips {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.5rem;
}

.chip {
  padding: 0.3rem 0.65rem;
  border-radius: var(--bng-corners-2);
  background: rgba(255, 255, 255, 0.08);
  color: var(--bng-off-white);
  font-size: 0.85rem;

  &--current {
    background: rgba(var(--bng-orange-500-rgb), 0.18);
  }

  &--host {
    color: var(--bng-add-green-300, #9be89b);
  }

  &--client {
    color: var(--bng-cool-gray-300);
  }
}

.toolbar {
  gap: 0.75rem;

  .search {
    flex: 1 1 auto;
    min-width: 12rem;
    max-width: 28rem;
  }

  .count {
    color: var(--bng-cool-gray-300);
    font-size: 0.85rem;
    white-space: nowrap;
  }
}

.layout {
  display: grid;
  grid-template-columns: minmax(0, 2fr) minmax(18rem, 1fr);
  gap: 0.75rem;
  align-items: start;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(12rem, 1fr));
  gap: 0.6rem;
}

.tile {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  padding: 0.35rem;
  border: 2px solid transparent;
  border-radius: var(--bng-corners-2);
  background: rgba(255, 255, 255, 0.06);
  color: var(--bng-off-white);
  cursor: pointer;
  text-align: left;
  font: inherit;

  &:hover,
  &:focus-visible {
    background: rgba(255, 255, 255, 0.12);
    outline: none;
  }

  &--selected {
    border-color: var(--bng-orange-500);
  }

  &--current .tile-title::after {
    content: " \2022";
    color: var(--bng-orange-300);
  }
}

.tile-image {
  position: relative;
  aspect-ratio: 16 / 9;
  overflow: hidden;
  border-radius: var(--bng-corners-1);
  background: rgba(0, 0, 0, 0.35);
}

.preview {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;

  &--none {
    display: grid;
    place-items: center;
    color: var(--bng-cool-gray-400);
    font-size: 2rem;
  }
}

.badge {
  position: absolute;
  bottom: 0.3rem;
  padding: 0.1rem 0.45rem;
  border-radius: var(--bng-corners-1);
  background: rgba(0, 0, 0, 0.65);
  color: var(--bng-off-white);
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;

  &--current {
    left: 0.3rem;
    background: var(--bng-orange-500);
  }

  &--source {
    right: 0.3rem;
  }

  &--mod {
    background: rgba(var(--bng-orange-500-rgb), 0.55);
  }
}

.tile-title {
  overflow: hidden;
  font-weight: 600;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tile-sub {
  color: var(--bng-cool-gray-400);
  font-size: 0.75rem;
  font-family: "Noto Sans Mono", monospace;
}

.panel,
.status-panel {
  padding: 0.8rem;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: var(--bng-corners-2);
  background: rgba(0, 0, 0, 0.25);
}

.status-panel--warning {
  border-color: rgba(var(--bng-orange-500-rgb), 0.6);
  background: rgba(var(--bng-orange-500-rgb), 0.12);
}

.status-panel--ok {
  border-color: rgba(120, 220, 120, 0.5);
  background: rgba(120, 220, 120, 0.1);
}

.details {
  position: sticky;
  top: 0;
  display: flex;
  flex-direction: column;
  gap: 0.6rem;

  h3 {
    margin: 0;
  }

  dl {
    display: grid;
    gap: 0.4rem;
    margin: 0;

    > div {
      display: grid;
      grid-template-columns: 5rem minmax(0, 1fr);
      gap: 0.5rem;
    }

    dt {
      color: var(--bng-cool-gray-300);
      font-size: 0.8rem;
      text-transform: uppercase;
    }

    dd {
      margin: 0;
      overflow-wrap: anywhere;
    }
  }
}

.details-preview {
  display: block;
  width: 100%;
  aspect-ratio: 16 / 9;
  border-radius: var(--bng-corners-1);
  object-fit: cover;

  &--none {
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.35);
    color: var(--bng-cool-gray-400);
    font-size: 3rem;
  }
}

.mono {
  font-family: "Noto Sans Mono", monospace;
  font-size: 0.8rem;
}

.muted {
  color: var(--bng-cool-gray-300);
}

.hint {
  margin: 0;
  font-size: 0.85rem;
}

.empty {
  grid-column: 1 / -1;
  padding: 1rem 0.25rem;
}

.actions {
  gap: 0.5rem;
}

.page-actions {
  padding-top: 0.25rem;
}
</style>
