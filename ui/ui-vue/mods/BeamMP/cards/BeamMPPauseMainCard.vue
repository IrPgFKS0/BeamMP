<template>
  <div class="card">
    <h3>{{ $tt("ui.playmodes.multiplayer") }}</h3>
    <p>{{ state.auth.value?.username || "Guest" }}</p>

    <div class="actions">
      <BngButton @click="resume">{{ $tt("ui.common.action.resume") }}</BngButton>
      <BngButton accent="secondary" @click="openBrowser">{{ $tt("ui.multiplayer.pauseMenu.serverDetails") }}</BngButton>
      <BngButton accent="secondary" @click="showLeaveConfirm = true">{{ $tt("ui.multiplayer.pauseMenu.disconnect") }}</BngButton>
      <BngButton accent="attention" @click="showQuitConfirm = true">{{ $tt("ui.multiplayer.pauseMenu.quitGame") }}</BngButton>
    </div>

    <BeamMPModal
      :visible="showLeaveConfirm"
      :title="$tt('ui.multiplayer.pauseMenu.areYouSure')"
      :message="$tt('ui.multiplayer.pauseMenu.disconnectConfirmation')"
      :confirm-text="$tt('ui.multiplayer.pauseMenu.disconnect')"
      :cancel-text="$tt('ui.common.cancel')"
      @confirm="confirmLeaveServer"
      @cancel="showLeaveConfirm = false"
    />

    <BeamMPModal
      :visible="showQuitConfirm"
      :title="$tt('ui.multiplayer.pauseMenu.areYouSure')"
      :message="$tt('ui.multiplayer.pauseMenu.quitToDesktopConfirmation')"
      :confirm-text="$tt('ui.multiplayer.pauseMenu.quitToDesktop')"
      :cancel-text="$tt('ui.common.cancel')"
      @confirm="confirmQuitGame"
      @cancel="showQuitConfirm = false"
    />
  </div>
</template>

<script setup>
import { ref } from "vue"
import { lua } from "@/bridge"
import { BngButton } from "@/common/components/base"
import { BEAMMP_ROUTE_NAME } from "../shared/constants.js"
import BeamMPModal from "../shared/BeamMPModal.vue"
import { useBeamMPState } from "../shared/beammpState.js"

const bngVue = window.bngVue || { gotoGameState() {} }
const { state } = useBeamMPState()
const showLeaveConfirm = ref(false)
const showQuitConfirm = ref(false)

function resume() {
  bngVue.gotoGameState("play")
}

function openBrowser() {
  lua.extensions.ui_router.push(BEAMMP_ROUTE_NAME)
}

function confirmLeaveServer() {
  showLeaveConfirm.value = false
  window.bngApi?.engineLua("MPCoreNetwork.leaveServer(true)")
}

function confirmQuitGame() {
  showQuitConfirm.value = false
  window.bngApi?.engineLua("quit()")
}
</script>

<style scoped>
.card {
  display: flex;
  flex-direction: column;
  gap: 0.55rem;
  color: var(--bng-off-white);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45rem;
}
</style>
