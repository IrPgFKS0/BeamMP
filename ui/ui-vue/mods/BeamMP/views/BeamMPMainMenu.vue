<template>
  <div class="beammp-route" v-bng-blur>
    <header class="topbar">
      <BngButton
        class="back-button"
        :accent="ACCENTS.custom_old"
        :icon-left="icons.arrowSmallLeft"
        @click="goBack"
      >
        {{ $tt("ui.common.menu") }}
      </BngButton>

      <div class="metrics">
        <img src="../icons/account-multiple.svg" alt="" />
        <span>Players: {{ state.beammpMetrics.value.players }}</span>
        <img src="../icons/dns.svg" alt="" />
        <span>Servers: {{ state.beammpMetrics.value.servers }}</span>
      </div>
    </header>

    <main class="main-grid">
      <aside class="sidebar">
        <img src="/ui/modModules/multiplayer/beammp_new_cropped.png" alt="BeamMP" class="logo" />

        <button class="nav-btn" @click="gotoView('servers', '')">{{ $tt("ui.multiplayer.servers") }}</button>
        <button class="nav-btn" @click="gotoView('servers', 'official')">{{ $tt("ui.multiplayer.official") }}</button>
        <button class="nav-btn" @click="gotoView('servers', 'featured')">{{ $tt("ui.multiplayer.featured") }}</button>
        <button class="nav-btn" @click="gotoView('servers', 'partner')">{{ $tt("ui.multiplayer.partner") }}</button>
        <button class="nav-btn" @click="gotoView('servers', 'favorites')">{{ $tt("ui.multiplayer.favorites") }}</button>
        <button class="nav-btn" @click="gotoView('servers', 'recent')">{{ $tt("ui.multiplayer.recent") }}</button>
        <button class="nav-btn" @click="gotoRoute(BEAMMP_DIRECT_ROUTE_NAME)">{{ $tt("ui.multiplayer.direct_connect") }}</button>
        <button class="nav-btn" @click="gotoRoute(BEAMMP_TILES_ROUTE_NAME)">Tiles</button>

        <div class="spacer" />

        <button class="nav-btn secondary" @click="openExternal('https://forum.beammp.com')">{{ $tt("ui.multiplayer.forum") }}</button>
        <button class="nav-btn secondary" @click="openExternal('https://discord.gg/BeamMP')">{{ $tt("ui.multiplayer.discord") }}</button>
        <button class="nav-btn secondary" @click="openExternal('https://docs.beammp.com')">{{ $tt("ui.multiplayer.docs") }}</button>
        <button class="nav-btn secondary" @click="openExternal('https://github.com/BeamMP/')">{{ $tt("ui.multiplayer.github") }}</button>
      </aside>

      <section class="content">
        <RouterView />
      </section>
    </main>

    <div v-if="state.loadingOverlayVisible.value" class="loading-overlay">
      <div class="loading-card">
        <h2>{{ $tt("ui.multiplayer.connectingToServer") }}</h2>
        <p>{{ state.loadingStatus.value || $tt("ui.multiplayer.connecting") }}</p>

        <div v-if="state.downloadingMods.value.length" class="mods-list">
          <div v-for="mod in state.downloadingMods.value" :key="`${mod.number}:${mod.name}`" class="mod-row">
            <span>{{ mod.number }} - {{ mod.name }}</span>
            <small>{{ mod.speed }}</small>
          </div>
        </div>

        <BngButton @click="closeLoadingOverlay">{{ $tt("ui.common.cancel") }}</BngButton>
      </div>
    </div>

    <BeamMPModal
      :visible="state.securityPromptVisible.value"
      :title="$tt('ui.multiplayer.security.title')"
      :message="state.securityPromptMessage.value || $tt('ui.multiplayer.security.prompt')"
      :confirm-text="$tt('ui.multiplayer.security.accept_proceed')"
      :cancel-text="$tt('ui.multiplayer.security.no_return')"
      @confirm="approveSecurityPrompt"
      @cancel="rejectSecurityPrompt"
    />
  </div>
</template>

<script setup>
import { onMounted } from "vue"
import { RouterView, useRouter } from "vue-router"
import { useBridge } from "@/bridge"
import { BngButton, ACCENTS, icons } from "@/common/components/base"
import { vBngBlur } from "@/common/directives"
import {
  BEAMMP_DIRECT_ROUTE_NAME,
  BEAMMP_LAUNCHER_ROUTE_NAME,
  BEAMMP_LOGIN_ROUTE_NAME,
  BEAMMP_SERVERS_ROUTE_NAME,
  BEAMMP_TILES_ROUTE_NAME,
  BEAMMP_TOS_ROUTE_NAME,
} from "../shared/constants.js"
import { useBeamMPState } from "../shared/beammpState.js"
import BeamMPModal from "../shared/BeamMPModal.vue"

const { events } = useBridge()
const router = useRouter()
const bngVue = window.bngVue || { goBack() {} }

const {
  state,
  closeLoadingOverlay,
  loadFavorites,
  openExternal,
  approveSecurityPrompt,
  rejectSecurityPrompt,
  refreshConnectionState,
  requestServerList,
  setView,
} = useBeamMPState(events)

function gotoRoute(name) {
  router.push({ name })
}

function gotoView(name, view) {
  setView(view || "servers")
  router.push({ name: BEAMMP_SERVERS_ROUTE_NAME, params: { view } })
}

async function goBack() {
  bngVue.goBack()
}

onMounted(async () => {
  await loadFavorites()
  await refreshConnectionState()
  await requestServerList()

  if (!state.tosAccepted.value) {
    router.replace({ name: BEAMMP_TOS_ROUTE_NAME })
    return
  }
  if (!state.launcherConnected.value) {
    router.replace({ name: BEAMMP_LAUNCHER_ROUTE_NAME })
    return
  }
  if (!state.loggedIn.value) {
    router.replace({ name: BEAMMP_LOGIN_ROUTE_NAME })
    return
  }

  router.replace({ name: BEAMMP_SERVERS_ROUTE_NAME })
})
</script>

<style scoped lang="scss">
.beammp-route {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  padding: 1rem;
  gap: 0.75rem;
  color: var(--bng-off-white);
  pointer-events: all;
  background:
    linear-gradient(120deg, rgba(22, 22, 22, 0.95), rgba(39, 39, 39, 0.88)),
    radial-gradient(circle at 85% 10%, rgba(var(--bng-orange-500-rgb), 0.22), transparent 35%);
}

.topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
}

.metrics {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  border-radius: var(--bng-corners-2);
  background: rgba(0, 0, 0, 0.35);

  img {
    width: 1rem;
    height: 1rem;
    filter: brightness(1.6);
  }
}

.main-grid {
  flex: 1;
  min-height: 0;
  display: grid;
  grid-template-columns: 16rem minmax(0, 1fr);
  gap: 0.75rem;
}

.sidebar {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  min-height: 0;
  overflow: auto;
  padding: 0.75rem;
  border: 1px solid rgba(var(--bng-orange-400-rgb), 0.35);
  border-radius: var(--bng-corners-2);
  background: rgba(0, 0, 0, 0.35);
}

.logo {
  width: 8.5rem;
  margin-bottom: 0.5rem;
}

.nav-btn {
  border: 1px solid rgba(255, 255, 255, 0.15);
  color: var(--bng-off-white);
  background: rgba(36, 36, 36, 0.75);
  border-radius: var(--bng-corners-1);
  text-align: left;
  padding: 0.45rem 0.6rem;
  cursor: pointer;

  &:hover {
    border-color: rgba(var(--bng-orange-500-rgb), 0.8);
    background: rgba(var(--bng-orange-500-rgb), 0.2);
  }
}

.secondary {
  opacity: 0.9;
}

.spacer {
  flex: 1;
}

.content {
  min-height: 0;
  overflow: auto;
  border: 1px solid rgba(var(--bng-orange-400-rgb), 0.35);
  border-radius: var(--bng-corners-2);
  background: rgba(0, 0, 0, 0.28);
  padding: 0.9rem;
}

.loading-overlay {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  background: rgba(0, 0, 0, 0.72);
}

.loading-card {
  width: min(44rem, 94vw);
  max-height: 80vh;
  overflow: auto;
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
  background: rgba(16, 16, 16, 0.95);
  border: 1px solid rgba(var(--bng-orange-500-rgb), 0.55);
  border-radius: var(--bng-corners-2);
  padding: 1rem;
}

.mods-list {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
}

.mod-row {
  display: flex;
  justify-content: space-between;
  gap: 0.5rem;
  background: rgba(255, 255, 255, 0.05);
  padding: 0.4rem 0.55rem;
  border-radius: var(--bng-corners-1);

  small {
    color: var(--bng-cool-gray-300);
  }
}

@media (max-width: 1000px) {
  .main-grid {
    grid-template-columns: 1fr;
  }
}
</style>
