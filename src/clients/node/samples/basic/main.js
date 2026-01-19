/**
 * ArcherDB Basic Sample - Insert and Query Geospatial Events
 *
 * This sample demonstrates:
 * 1. Connecting to an ArcherDB cluster
 * 2. Inserting geo events with location data
 * 3. Querying events within a radius
 */
const process = require('process')

const { createGeoClient } = require('archerdb-node')

async function main() {
  const address = process.env.ARCHERDB_ADDRESS || '127.0.0.1:3001'

  // Connect to ArcherDB cluster
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: [address],
  })

  console.log(`Connected to ArcherDB at ${address}`)

  try {
    // San Francisco area coordinates
    const baseLat = 37.7749
    const baseLon = -122.4194

    // Insert events using a batch
    const batch = client.createBatch()
    const entityIds = []

    for (let i = 0; i < 5; i++) {
      // Slightly offset positions around SF
      const entityId = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))
      entityIds.push(entityId)

      batch.addFromOptions({
        entity_id: entityId,
        latitude: baseLat + i * 0.001, // ~111 meters apart
        longitude: baseLon + i * 0.001,
        group_id: 1n,
        accuracy_m: 10, // 10m accuracy
      })
    }

    const errors = await batch.commit()
    if (errors.length > 0) {
      console.error('Insert errors:', errors)
    } else {
      console.log(`Successfully inserted ${entityIds.length} events`)
    }

    // Query events within 1km radius of SF center
    const result = await client.queryRadius({
      latitude: baseLat,
      longitude: baseLon,
      radius_m: 1000,
      limit: 100,
    })

    console.log(`\nFound ${result.events.length} events within 1km of SF center:`)
    for (const event of result.events) {
      console.log(`  Entity ${event.entityId}: (${event.latitude.toFixed(4)}, ${event.longitude.toFixed(4)})`)
    }

    // Look up a specific entity
    if (entityIds.length > 0) {
      const found = await client.getLatestByUuid(entityIds[0])
      if (found) {
        console.log(`\nLatest position for entity ${entityIds[0]}:`)
        console.log(`  Location: (${found.latitude.toFixed(4)}, ${found.longitude.toFixed(4)})`)
        console.log(`  Timestamp: ${found.timestamp}`)
      }
    }

    console.log('\nok')
  } finally {
    await client.close()
  }
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e)
    process.exit(1)
  })
