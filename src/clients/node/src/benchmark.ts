import assert from 'assert'
import { createGeoClient } from '.'

const MAX_EVENTS = 50000
const MAX_REQUEST_BATCH_SIZE = 500

const client = createGeoClient({
  cluster_id: 0n,
  addresses: [process.env.ARCHERDB_ADDRESS || '127.0.0.1:3001'],
})

const BASE_LAT = 37.7749
const BASE_LON = -122.4194

const runBenchmark = async () => {
  let inserted = 0
  let maxInsertLatency = 0
  let sampleEntity: bigint | null = null

  const start = Date.now()

  while (inserted < MAX_EVENTS) {
    const batch = client.createBatch()
    const count = Math.min(MAX_REQUEST_BATCH_SIZE, MAX_EVENTS - inserted)

    for (let i = 0; i < count; i++) {
      const entity_id = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))
      if (sampleEntity === null) sampleEntity = entity_id

      batch.addFromOptions({
        entity_id,
        latitude: BASE_LAT + (inserted + i) * 0.00001,
        longitude: BASE_LON + (inserted + i) * 0.00001,
        group_id: 1n,
      })
    }

    const ms1 = Date.now()
    const errors = await batch.commit()
    const ms2 = Date.now()

    assert(errors.length === 0)
    maxInsertLatency = Math.max(maxInsertLatency, ms2 - ms1)
    inserted += count
  }

  const ms = Date.now() - start

  return {
    ms,
    maxInsertLatency,
    sampleEntity,
  }
}

const main = async () => {
  const benchmark = await runBenchmark()
  const throughput = Math.floor((1000 * MAX_EVENTS) / benchmark.ms)

  console.log('=============================')
  console.log(`events per second: ${throughput}`)
  console.log(`max batch insert latency = ${benchmark.maxInsertLatency}ms`)

  if (benchmark.sampleEntity) {
    const found = await client.getLatestByUuid(benchmark.sampleEntity)
    assert(found !== null)
  }

  const radiusResult = await client.queryRadius({
    latitude: BASE_LAT,
    longitude: BASE_LON,
    radius_m: 2000,
    limit: 100,
  })

  console.log(`radius query returned ${radiusResult.events.length} events`)
}

main().catch(error => {
  console.log(error)
}).finally(async () => {
  await client.destroy()
})
