<template>
  <ToolboxCard>
    <div class="body">
      <div>
        <BngCardHeading type="ribbon">{{ displayName }}</BngCardHeading>
        <template v-if="!isLoading">
          <strong>{{ config.Configuration || config.Name }}</strong>
          <div v-if="model.Years?.min || model.Years?.max" class="years">
            {{ model.Years.min || model.Years.max }} - {{ model.Years.max || model.Years.min }}
          </div>
        </template>
        <div v-else class="text">Loading vehicle...</div>
      </div>
      <img :src="logoUrl" alt="" />
    </div>
    <div class="actions">
      <BngButton v-if="props.showRouteButton" @click="openToolbox">Open route screen</BngButton>
    </div>
  </ToolboxCard>
</template>

<script setup>
import { computed } from "vue"
import { BngCardHeading, BngButton } from "@/common/components/base"
import { lua } from "@/bridge"
import { getAssetURL, getURL } from "@/utils"
import { TOOLBOX_ROUTE_NAME } from "../shared/constants.js"
import { useVehicle } from "../shared/useVehicle.js"
import ToolboxCard from "../shared/ToolboxCard.vue"

const props = defineProps({
  showRouteButton: {
    type: Boolean,
    default: true,
  },
})

const openToolbox = () => lua.extensions.ui_router.push(TOOLBOX_ROUTE_NAME)
const { config, displayName, isLoading, model } = useVehicle()

const LOGO_DIR = getAssetURL("images/brands")
const MISSING = getAssetURL("images/missingTexture.png")
const AVAILABLE_LOGOS = new Set([
  "autobello", "bruckell", "bruckell_old", "burnside", "cherrier", "civetta",
  "etk", "fpu", "gavril", "hirochi", "hirochi_heavy", "ibishu", "sp",
])
const LOGO_OVERRIDES = {
  bruckell: {
    "nine": "bruckell_old",
  },
  hirochi: {
    "ht-55": "hirochi_heavy",
    "wl-40": "hirochi_heavy",
  },
}

const logoName = computed(() => {
  const brand = (model.value.Brand || "").trim().toLowerCase()
  const modelName = (model.value.Name || "").trim().toLowerCase()
  return LOGO_OVERRIDES[brand]?.[modelName] || brand
})
const logoUrl = computed(() => AVAILABLE_LOGOS.has(logoName.value)
  ? getURL(`${LOGO_DIR}/${logoName.value}.png`)
  : MISSING
)
</script>

<style lang="scss" scoped>
.body {
  display: flex;
  justify-content: space-between;
  gap: 1rem;

  > div {
    min-width: 0;
  }

  img {
    width: 5em;
    height: 5em;
    object-fit: contain;
  }
}

.text {
  display: block;
  min-height: 4em;
  line-height: 1.4;
}

.years {
  color: var(--bng-orange-300);
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}
</style>
