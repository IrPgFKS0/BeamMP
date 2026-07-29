<template>
  <div class="mods-card">
    <h3>BeamMP</h3>
    <p>{{ state.loggedIn.value ? "Account connected" : "Not logged in" }}</p>
    <p>Servers visible: {{ visibleServers.length }}</p>
    <BngButton @click="openRoute">Open Multiplayer Browser</BngButton>
  </div>
</template>

<script setup>
import { lua } from "@/bridge"
import { BngButton } from "@/common/components/base"
import { BEAMMP_ROUTE_NAME } from "../shared/constants.js"
import { useBeamMPState } from "../shared/beammpState.js"

const { state, visibleServers } = useBeamMPState()

function openRoute() {
  lua.extensions.ui_router.push(BEAMMP_ROUTE_NAME)
}
</script>

<style scoped>
.mods-card {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
  color: var(--bng-off-white);
}
</style>
