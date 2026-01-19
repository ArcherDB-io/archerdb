/**
 * ArcherDB Polygon Query Sample - Geofence Queries
 *
 * This sample demonstrates:
 * 1. Creating polygon-based geofences
 * 2. Querying events within polygon boundaries
 * 3. Comparing polygon vs radius queries
 */
const process = require('process')

const { createGeoClient } = require('archerdb-node')

async function main() {
  const address = process.env.ARCHERDB_ADDRESS || '127.0.0.1:3001'

  const client = createGeoClient({
    cluster_id: 0n,
    addresses: [address],
  })

  console.log(`Connected to ArcherDB at ${address}`)

  try {
    // Insert events in the San Francisco downtown area
    const batch = client.createBatch()
    const locations = [
      // Inside the polygon (downtown)
      { name: 'Transamerica Pyramid', lat: 37.7952, lon: -122.4028 },
      { name: 'Salesforce Tower', lat: 37.7897, lon: -122.3972 },
      { name: 'Embarcadero Center', lat: 37.7946, lon: -122.3984 },
      // Outside the polygon (other areas)
      { name: 'Golden Gate Bridge', lat: 37.8199, lon: -122.4783 },
      { name: 'Alcatraz', lat: 37.827, lon: -122.423 },
      { name: 'Twin Peaks', lat: 37.7544, lon: -122.4477 },
    ]

    for (let i = 0; i < locations.length; i++) {
      const loc = locations[i]
      batch.addFromOptions({
        entity_id: BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER)),
        latitude: loc.lat,
        longitude: loc.lon,
        group_id: 1n,
      })
      console.log(`  Added ${loc.name}: (${loc.lat.toFixed(4)}, ${loc.lon.toFixed(4)})`)
    }

    await batch.commit()
    console.log(`\nInserted ${locations.length} events\n`)

    // Define a polygon around downtown
    const downtownPolygon = [
      { latitude: 37.798, longitude: -122.405 }, // Northwest corner
      { latitude: 37.798, longitude: -122.39 }, // Northeast corner
      { latitude: 37.786, longitude: -122.39 }, // Southeast corner
      { latitude: 37.786, longitude: -122.405 }, // Southwest corner
    ]

    console.log('Querying downtown polygon:')
    console.log('  Vertices:', downtownPolygon.map((v) => `(${v.latitude}, ${v.longitude})`).join(', '))

    const result = await client.queryPolygon({
      vertices: downtownPolygon,
    })

    console.log(`\nFound ${result.events.length} events inside downtown geofence:`)
    for (const event of result.events) {
      // Find the name
      let name = 'Unknown'
      for (const loc of locations) {
        if (Math.abs(event.latitude - loc.lat) < 0.0001 && Math.abs(event.longitude - loc.lon) < 0.0001) {
          name = loc.name
          break
        }
      }
      console.log(`  ${name}: (${event.latitude.toFixed(4)}, ${event.longitude.toFixed(4)})`)
    }

    // Compare with radius query from center of polygon
    const centerLat = 37.792
    const centerLon = -122.3975
    const radiusM = 1000

    const resultRadius = await client.queryRadius({
      latitude: centerLat,
      longitude: centerLon,
      radius_m: radiusM,
    })

    console.log(`\nRadius query (1km from center): ${resultRadius.events.length} events`)
    console.log('(Radius queries cover circular areas; polygons allow precise boundaries)')

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
