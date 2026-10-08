<!-- LAN: pause-menu rail button "Maps" -> the BeamMP menu's map switcher page. Same redirect pattern as
     BeamMPPauseServerDetailsRedirect.vue: the pause card column is too narrow for a preview grid, so the
     button hands over to the full-width route and the view's "Resume" button returns to the game. -->
<template>
</template>

<script setup>
import { onMounted } from "vue"
import { BEAMMP_MAPS_ROUTE_NAME } from "../shared/constants.js"

onMounted(() => {
  if (window.bngVue && typeof window.bngVue.gotoGameState === "function") {
    window.bngVue.gotoGameState(BEAMMP_MAPS_ROUTE_NAME)
  }
})
</script>
