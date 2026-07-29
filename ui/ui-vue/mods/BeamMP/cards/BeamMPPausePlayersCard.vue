<template>
  <div class="card">
    <h3>{{ $tt("ui.multiplayer.server.playerList") }} ({{ players.length }})</h3>

    <div v-if="!players.length" class="empty">{{ $tt("ui.multiplayer.server.noPlayers") }}</div>
    <div v-for="player in players" :key="`${player.id}:${player.name}`" class="player-row">
      <span class="id">{{ player.id }}</span>
      <span class="name">{{ player.name }}</span>
      <span class="ping">{{ player.ping || "?" }}ms</span>
      <BngButton accent="secondary" @click="copyName(player.name)">{{ $tt("ui.apps.multiplayer.playerlist.copyname") }}</BngButton>
      <BngButton accent="secondary" @click="openProfile(player.name)">{{ $tt("ui.apps.multiplayer.playerlist.openProfile") }}</BngButton>
    </div>
  </div>
</template>

<script setup>
import { onMounted, onUnmounted, ref } from "vue"
import { useBridge } from "@/bridge"
import { BngButton } from "@/common/components/base"

const { events } = useBridge()
const players = ref([])

function onPlayerList(payload) {
  try {
    const parsed = JSON.parse(payload)
    if (Array.isArray(parsed)) players.value = parsed
  } catch {
    players.value = []
  }
}

function onPlayerPings(payload) {
  try {
    const pings = JSON.parse(payload)
    players.value = players.value.map(player => ({
      ...player,
      ping: pings[player.name] ?? player.ping,
    }))
  } catch {
    // ignore malformed data
  }
}

function copyName(name) {
  window.bngApi?.engineLua(`setClipboard(\"${String(name || "").replace(/\"/g, "") }\")`)
}

function openProfile(name) {
  window.bngApi?.engineLua(`MPCoreNetwork.openURL(\"https://forum.beammp.com/u/${name}/summary\")`)
}

onMounted(() => {
  events.on("playerList", onPlayerList)
  events.on("playerPings", onPlayerPings)
  window.bngApi?.engineLua("UI.updatePlayersList()")
})

onUnmounted(() => {
  events.off("playerList", onPlayerList)
  events.off("playerPings", onPlayerPings)
})
</script>

<style scoped lang="scss">
.card {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
  color: var(--bng-off-white);
}

.player-row {
  display: grid;
  grid-template-columns: 3rem minmax(8rem, 1fr) 5rem auto auto;
  gap: 0.4rem;
  align-items: center;
  padding: 0.25rem 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

.id {
  color: var(--bng-add-green-400);
}

.ping {
  color: var(--bng-cool-gray-300);
}

.empty {
  color: var(--bng-cool-gray-300);
}
</style>
