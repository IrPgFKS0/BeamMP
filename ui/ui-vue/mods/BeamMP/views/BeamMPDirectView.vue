<template>
  <section class="direct-wrap">
    <label>
      {{ $tt("ui.multiplayer.direct_connect.server_ip") }}
      <input v-model="ip" class="bng-input" type="text" />
    </label>

    <label>
      {{ $tt("ui.multiplayer.direct_connect.server_port") }}
      <input v-model="port" class="bng-input" type="text" />
    </label>

    <div class="actions">
      <BngButton accent="secondary" @click="pasteFromClipboard">{{ $tt("ui.multiplayer.pasteFromClipboard") }}</BngButton>
      <BngButton @click="connect">{{ $tt("ui.multiplayer.connect") }}</BngButton>
      <BngButton accent="secondary" @click="favorite">{{ $tt("ui.multiplayer.favorite") }}</BngButton>
    </div>
  </section>
</template>

<script setup>
import { ref } from "vue"
import { BngButton } from "@/common/components/base"
import { useBeamMPState } from "../shared/beammpState.js"

const ip = ref("")
const port = ref("30814")
const { addFavorite, connectToServer, directConnectFromClipboard } = useBeamMPState()

async function pasteFromClipboard() {
  const text = String(await directConnectFromClipboard() || "")
  if (!text.includes(".")) return
  const [nextIp, nextPort] = text.split(":")
  ip.value = nextIp || ip.value
  if (nextPort) port.value = nextPort
}

async function connect() {
  await connectToServer(ip.value || "127.0.0.1", port.value || "30814")
}

async function favorite() {
  if (!ip.value || !port.value) return
  addFavorite({
    ip: ip.value,
    port: port.value,
    sname: new Date().toLocaleString(),
    strippedName: new Date().toLocaleString(),
    custom: true,
    tags: "",
    map: "",
    location: "--",
  })
}
</script>

<style scoped>
.direct-wrap {
  max-width: 36rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.actions {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}

label {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
}
</style>
