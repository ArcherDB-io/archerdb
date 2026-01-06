/**
 * ArcherDB Radius Query Sample - Advanced Spatial Queries
 *
 * This sample demonstrates:
 * 1. Inserting events at known locations
 * 2. Performing radius queries with different parameters
 * 3. Pagination of results
 */
const process = require('process')

const { createGeoClient, createGeoEvent } = require('archerdb-node')

async function main() {
  const address = process.env.ARCHERDB_ADDRESS || '127.0.0.1:3001'

  const client = createGeoClient({
    clusterId: 0n,
    addresses: [address],
  })

  console.log(`Connected to ArcherDB at ${address}`)

  try {
    // Using Golden Gate Park as center
    const centerLat = 37.7694
    const centerLon = -122.4862

    const nowNs = BigInt(Date.now()) * 1000000n

    const batch = client.createBatch()
    const eventsData = [
      { lat: 37.7703, lon: -122.4862, dist: '~100m' },
      { lat: 37.7739, lon: -122.4862, dist: '~500m' },
      { lat: 37.7784, lon: -122.4862, dist: '~1km' },
      { lat: 37.7874, lon: -122.4862, dist: '~2km' },
      { lat: 37.7694, lon: -122.5412, dist: '~5km' },
    ]

    for (let i = 0; i < eventsData.length; i++) {
      const data = eventsData[i]
      batch.addFromOptions({
        entityId: BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER)),
        latitude: data.lat,
        longitude: data.lon,
        timestamp: nowNs + BigInt(i),
        groupId: 1n,
      })
    }

    await batch.commit()
    console.log(`Inserted ${eventsData.length} events at various distances\n`)

    // Query 1: Find everything within 200m
    let result = await client.queryRadius({
      latitude: centerLat,
      longitude: centerLon,
      radiusM: 200,
    })
    console.log(`Within 200m: ${result.events.length} events`)

    // Query 2: Find everything within 600m
    result = await client.queryRadius({
      latitude: centerLat,
      longitude: centerLon,
      radiusM: 600,
    })
    console.log(`Within 600m: ${result.events.length} events`)

    // Query 3: Find everything within 1.5km
    result = await client.queryRadius({
      latitude: centerLat,
      longitude: centerLon,
      radiusM: 1500,
    })
    console.log(`Within 1.5km: ${result.events.length} events`)

    // Query 4: Find everything within 3km
    result = await client.queryRadius({
      latitude: centerLat,
      longitude: centerLon,
      radiusM: 3000,
    })
    console.log(`Within 3km: ${result.events.length} events`)

    // Query 5: Find everything within 10km (should get all)
    result = await client.queryRadius({
      latitude: centerLat,
      longitude: centerLon,
      radiusM: 10000,
    })
    console.log(`Within 10km: ${result.events.length} events`)

    // Query with pagination
    console.log('\nPagination example (limit 2 per page):')
    result = await client.queryRadius({
      latitude: centerLat,
      longitude: centerLon,
      radiusM: 10000,
      limit: 2,
    })
    console.log(`  Page 1: ${result.events.length} events, hasMore=${result.hasMore}`)

    if (result.hasMore && result.cursor) {
      const result2 = await client.queryRadius({
        latitude: centerLat,
        longitude: centerLon,
        radiusM: 10000,
        limit: 2,
        timestampMax: result.cursor - 1n,
      })
      console.log(`  Page 2: ${result2.events.length} events, hasMore=${result2.hasMore}`)
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
