<template>
  <section class="servers-wrap">
    <header class="toolbar">
      <input
        :value="state.filters.value.searchText"
        class="bng-input"
        :placeholder="$tt('ui.multiplayer.searchPlaceholder')"
        @input="onSearch"
      />
      <BngButton @click="requestServerList">{{ $tt("ui.multiplayer.refresh") }}</BngButton>
      <BngButton accent="secondary" @click="resetFilters">{{ $tt("ui.multiplayer.clearFilters") }}</BngButton>
      <BngButton v-if="state.view.value === 'recent'" accent="secondary" @click="clearRecents">{{ $tt("ui.multiplayer.clearRecent") }}</BngButton>
    </header>

    <div class="filters-grid">
      <label>
        Min players
        <input class="bng-input" type="number" :value="state.filters.value.playerCountMin" @input="event => updateNumber('playerCountMin', event)" />
      </label>
      <label>
        Max players
        <input class="bng-input" type="number" :value="state.filters.value.playerCountMax" @input="event => updateNumber('playerCountMax', event)" />
      </label>
      <label>
        Max mod MB
        <input class="bng-input" type="number" :value="state.filters.value.sliderMaxModSize" @input="event => updateNumber('sliderMaxModSize', event)" />
      </label>
      <label>
        Match all
        <input type="checkbox" :checked="state.filters.value.matchAll" @change="event => updateFilter({ matchAll: event.target.checked })" />
      </label>
    </div>

    <table class="servers-table">
      <thead>
        <tr>
          <th>{{ $tt("ui.multiplayer.location") }}</th>
          <th>{{ $tt("ui.multiplayer.description") }}</th>
          <th>{{ $tt("ui.multiplayer.map") }}</th>
          <th>{{ $tt("ui.multiplayer.players") }}</th>
        </tr>
      </thead>
      <tbody>
        <template v-for="server in visibleServers" :key="server.id">
          <tr
            class="server-row"
            :class="{ selected: state.selectedServerId.value === server.id }"
            @click="selectServer(server.id)"
          >
            <td>{{ server.location || "--" }}</td>
            <td>{{ server.strippedName }}</td>
            <td>{{ server.mapName }}</td>
            <td>{{ server.players }}/{{ server.maxplayers }}</td>
          </tr>
          <tr v-if="state.selectedServerId.value === server.id" class="details-row">
            <td colspan="4">
              <section class="details">
                <h3 class="server-title">{{ server.strippedName }}</h3>

                <div class="details-grid">
                  <section class="info-panel">
                    <h4 class="section-header">{{ $tt("ui.multiplayer.server.information") }}</h4>
                    <table class="description-table">
                      <tr>
                        <th>{{ $tt("ui.multiplayer.server.owner") }}</th>
                        <td>{{ server.owner || "" }}</td>
                      </tr>
                      <tr>
                        <th>{{ $tt("ui.multiplayer.server.map") }}</th>
                        <td>{{ server.mapName || "" }}</td>
                      </tr>
                      <tr>
                        <th>{{ $tt("ui.multiplayer.server.description") }}</th>
                        <td class="desc-cell">{{ server.sdesc || "" }}</td>
                      </tr>
                      <tr>
                        <th>{{ $tt("ui.multiplayer.server.tags") }}</th>
                        <td>
                          <span v-if="!server.tagsList.length">{{ $tt("ui.multiplayer.server.noTags") }}</span>
                          <div v-else class="tag-list-container">
                            <span v-for="tag in server.tagsList" :key="`${server.id}:${tag.raw}`" class="chip">{{ tag.text }}</span>
                          </div>
                        </td>
                      </tr>
                    </table>
                  </section>

                  <section class="players-panel">
                    <h4 class="section-header">{{ $tt("ui.multiplayer.server.playerList") }}</h4>
                    <div v-if="!playerNames(server).length" class="muted">{{ $tt("ui.multiplayer.server.noPlayers") }}</div>
                    <div v-else class="tag-list-container">
                      <span
                        v-for="playerName in playerNames(server)"
                        :key="`${server.id}:player:${playerName}`"
                        class="chip chip-player"
                      >
                        {{ playerName }}
                      </span>
                    </div>
                  </section>
                </div>

                <section class="mods mods-panel">
                  <h4 class="section-header">{{ $tt("ui.multiplayer.server.mods") }} ({{ modList(server.modlist).length }})</h4>
                  <div v-if="modList(server.modlist).length === 0">{{ $tt("ui.multiplayer.server.isUnmodded") }}</div>
                  <div v-else class="tag-list-container">
                    <span v-for="mod in modList(server.modlist)" :key="`${server.id}:${mod}`" class="chip">{{ mod }}</span>
                  </div>
                  <small>{{ $tt("ui.multiplayer.server.modsTotalFilesize") }} {{ formatBytes(server.modstotalsize) }}</small>
                </section>

                <div class="actions">
                  <BngButton @click.stop="join(server)">{{ $tt("ui.multiplayer.connect") }}</BngButton>
                  <BngButton v-if="!isFavorite(server)" accent="secondary" @click.stop="addFavorite(server)">{{ $tt("ui.multiplayer.addFavorite") }}</BngButton>
                  <BngButton v-else accent="secondary" @click.stop="removeFavorite(server)">{{ $tt("ui.multiplayer.removeFavorite") }}</BngButton>
                </div>
              </section>
            </td>
          </tr>
        </template>
      </tbody>
    </table>
  </section>
</template>

<script setup>
import { onMounted, watch } from "vue"
import { useRoute } from "vue-router"
import { BngButton } from "@/common/components/base"
import { useBeamMPState } from "../shared/beammpState.js"

const route = useRoute()
const {
  addFavorite,
  clearRecents,
  connectToServer,
  formatBytes,
  isFavorite,
  modList,
  removeFavorite,
  requestServerList,
  resetFilters,
  selectServer,
  setView,
  state,
  updateFilter,
  visibleServers,
} = useBeamMPState()

function updateNumber(key, event) {
  updateFilter({ [key]: Number(event.target.value || 0) })
}

function onSearch(event) {
  updateFilter({ searchText: event.target.value || "" })
}

function playerNames(server) {
  const list = String(server?.playerslist || "")
    .replace(/^Current players:\s*/i, "")
    .trim()
  if (!list) return []
  return list
    .split(/[;,]/)
    .map(name => name.trim())
    .filter(Boolean)
}

async function join(server) {
  if (!server) return
  await connectToServer(server.ip, server.port, server.sname)
}

function syncView() {
  const view = String(route.params.view || "servers")
  setView(view)
}

watch(() => route.params.view, syncView, { immediate: true })
onMounted(requestServerList)
</script>

<style scoped lang="scss">
.servers-wrap {
  display: flex;
  flex-direction: column;
  gap: 0.7rem;
}

.toolbar {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}

.filters-grid {
  display: grid;
  gap: 0.5rem;
  grid-template-columns: repeat(auto-fill, minmax(10rem, 1fr));

  label {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
  }
}

.servers-table {
  width: 100%;
  border-collapse: collapse;

  th,
  td {
    padding: 0.45rem;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    text-align: left;
  }
}

.server-row {
  cursor: pointer;

  &:hover {
    background: rgba(255, 255, 255, 0.06);
  }
}

.selected {
  background: rgba(var(--bng-orange-500-rgb), 0.25);
}

.details {
  margin: 0;
  padding: 0.8rem;
  border-radius: 0;
  background: rgba(17, 17, 17, 0.7);
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.details-row td {
  padding: 0 !important;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

.details-grid {
  display: grid;
  grid-template-columns: minmax(0, 2fr) minmax(0, 1fr);
  gap: 0.75rem;
}

.info-panel,
.players-panel,
.mods-panel {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: var(--bng-corners-1);
  padding: 0.65rem;
}

.server-title {
  margin: 0;
  font-size: 1.05rem;
}

.section-header {
  margin: 0 0 0.5rem;
  font-size: 0.95rem;
  color: var(--bng-cool-gray-100);
}

.description-table {
  width: 100%;
  border-collapse: collapse;

  th,
  td {
    padding: 0.22rem 0;
    border: 0;
    vertical-align: top;
  }

  th {
    width: 8rem;
    color: var(--bng-cool-gray-200);
    font-weight: 600;
  }
}

.desc-cell {
  white-space: pre-wrap;
  word-break: break-word;
}

.tag-list-container {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
}

.chip {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.15);
  border-radius: 999px;
  padding: 0.2rem 0.5rem;
  font-size: 0.82rem;
}

.chip-player {
  background: rgba(var(--bng-orange-500-rgb), 0.2);
  border-color: rgba(var(--bng-orange-500-rgb), 0.45);
}

.muted {
  color: var(--bng-cool-gray-300);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

@media (max-width: 980px) {
  .details-grid {
    grid-template-columns: 1fr;
  }
}
</style>
