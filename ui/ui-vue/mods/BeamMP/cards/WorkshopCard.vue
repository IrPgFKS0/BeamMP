<template>
  <ToolboxCard v-if="hasVehicle" class="jobs">
    <BngCardHeading type="ribbon">Workshop Jobs</BngCardHeading>

    <div v-if="isLoading" class="text">Checking the vehicle...</div>
    <template v-else-if="jobs.length">
      <div v-for="job in jobs" :key="job.id" class="job">
        <BngSwitch
          :model-value="selectedJobIds.includes(job.id)"
          @update:model-value="setJobSelected(job.id, $event)"
        >
          {{ job.title }}
        </BngSwitch>
        <span>{{ job.assessment }}</span>
      </div>

      <div class="quote">
        <strong>
          <BngCounter :number="totalPrice" type="float" :precision="2" :seconds="1" />
          <BngIcon :type="icons.beamCurrency" />
        </strong>
        <BngButton :disabled="!selectedJobs.length || applying" @click="applySelectedJobs">
          {{ applying ? "Working..." : "Service selected" }}
        </BngButton>
      </div>
    </template>
    <div v-else class="text">No maintenance jobs for this vehicle.</div>
  </ToolboxCard>
</template>

<script setup>
import { computed, onUnmounted, ref, watch } from "vue"
import { BngButton, BngCardHeading, BngCounter, BngIcon, BngSwitch, icons } from "@/common/components/base"
import { useTuningStore } from "@/modules/vehicleConfig/stores/tuningStore"
import ToolboxCard from "../shared/ToolboxCard.vue"
import { useVehicle } from "../shared/useVehicle.js"

const tuningStore = useTuningStore()
const { hasVehicle } = useVehicle()
const isLoading = ref(true)
const applying = ref(false)
const selectedJobIds = ref([])
let storeReady = false

const tuningData = computed(() => {
  const buckets = Array.isArray(tuningStore.buckets) ? tuningStore.buckets : []
  return buckets.flatMap(category => category.items.flatMap(subCategory => subCategory.items))
})

const jobs = computed(() => {
  const fields = tuningData.value
  // find out what is available in the vehicle
  const fuel = fields.filter(field => field.name.startsWith("$fuel"))
  const tyrePressure = fields.filter(field => field.name.startsWith("$tirepressure"))
  const oil = fields.filter(field => field.name.toLowerCase().includes("oil"))
  // find out what can we offer for that
  return [
    createJob("fuel", fuel, "Refill fuel", "Tank is full.", "Tank is getting low. Let's top it up.", 35.50, "max"),
    createJob("tyrePressure", tyrePressure, "Set tyre pressure", "Pressure looks good.", "Let's put the tyres back where they belong.", 20.25, "default"),
    createJob("oil", oil, "Change engine oil", "Oil looks good.", "Fresh oil will keep this engine happy.", 60.75, "default"),
  ].filter(Boolean)
})

const selectedJobs = computed(() => jobs.value.filter(job => selectedJobIds.value.includes(job.id)))
const totalPrice = computed(() => selectedJobs.value.reduce((total, job) => total + job.price, 0))

watch(jobs, currentJobs => {
  selectedJobIds.value = selectedJobIds.value.filter(id => currentJobs.some(job => job.id === id))
}, { immediate: true })

function createJob(id, fields, title, okay, needsService, price, target) {
  if (!fields.length) return undefined
  return {
    id,
    names: fields.map(field => field.name),
    title,
    assessment: getAssessment(fields.map(field => field.name), target, okay, needsService),
    price,
    target,
  }
}

function getAssessment(names, target, okay, needsService) {
  const needsWork = names.some(name => {
    const variable = tuningStore.tuningVariables[name]
    if (!variable) return true
    const targetValue = target === "max" ? variable.maxDis : variable.default
    const range = Math.max(variable.maxDis - variable.minDis, 1)
    return Math.abs(variable.valDis - targetValue) / range >= 0.05
  })
  return needsWork ? needsService : okay
}

function setJobSelected(id, selected) {
  selectedJobIds.value = selected
    ? [...selectedJobIds.value, id]
    : selectedJobIds.value.filter(jobId => jobId !== id)
}

const refreshJobs = async () => await tuningStore.requestInitialData()

async function applySelectedJobs() {
  const names = selectedJobs.value
    .flatMap(job => job.names.map(name => ({ name, target: job.target })))
    .filter(({ name }) => tuningStore.tuningVariables[name])
  if (!names.length) return

  applying.value = true
  try {
    for (const { name, target } of names) {
      const variable = tuningStore.tuningVariables[name]
      variable.valDis = target === "max" ? variable.maxDis : variable.default
      tuningStore.tuningVarChanged(name)
    }
    await tuningStore.apply()
    await refreshJobs()
  } finally {
    applying.value = false
  }
}

watch(hasVehicle, async available => {
  if (!available || storeReady) return
  storeReady = true
  try {
    await tuningStore.init()
    await refreshJobs()
  } finally {
    isLoading.value = false
  }
}, { immediate: true })

onUnmounted(() => {
  if (storeReady) {
    tuningStore.close()
    tuningStore.$dispose()
  }
})
</script>

<style lang="scss" scoped>
.jobs {
  gap: 0.75rem;
}

.job {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;

  span {
    color: var(--bng-cool-gray-300);
  }
}

.quote {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  padding-top: 0.5rem;
  border-top: 1px solid rgba(var(--bng-cool-gray-500-rgb), 0.5);

  strong {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 1.5rem;
  }
}

.text {
  color: var(--bng-cool-gray-300);
}
</style>
