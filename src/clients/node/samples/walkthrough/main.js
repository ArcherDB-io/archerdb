// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
// section:imports
/**
 * ArcherDB Entity Tracking Walkthrough
 *
 * This sample demonstrates:
 * 1. Tracking a moving entity over time
 * 2. Updating entity positions (upsert)
 * 3. Looking up entity by UUID
 * 4. Deleting entities
 * 5. Historical position queries
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
  console.log('='.repeat(50))

  try {
    // Create a unique entity ID for our tracked vehicle
    const entityId = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))
    console.log(`\n1. CREATING ENTITY: Vehicle ${entityId}`)

    // Simulate a vehicle route from SF Ferry Building to Fisherman's Wharf
    const route = [
      { name: 'Ferry Building', lat: 37.7955, lon: -122.3937 },
      { name: 'Pier 23', lat: 37.8005, lon: -122.4007 },
      { name: 'Pier 33', lat: 37.8087, lon: -122.4097 },
      { name: "Fisherman's Wharf", lat: 37.808, lon: -122.4177 },
    ]

    // Insert initial position
    console.log('\n2. INSERTING INITIAL POSITION')
    let batch = client.createBatch()
    batch.addFromOptions({
      entity_id: entityId,
      latitude: route[0].lat,
      longitude: route[0].lon,
      velocity_mps: 5, // 5 m/s
      heading: 315, // ~315 degrees (northwest)
      group_id: 1n,
    })
    await batch.commit()
    console.log(`   Inserted at ${route[0].name}: (${route[0].lat.toFixed(4)}, ${route[0].lon.toFixed(4)})`)

    // Look up the entity
    console.log('\n3. LOOKING UP ENTITY BY UUID')
    let found = await client.getLatestByUuid(entityId)
    if (found) {
      console.log(`   Found entity ${entityId}`)
      console.log(`   Position: (${found.latitude.toFixed(4)}, ${found.longitude.toFixed(4)})`)
      console.log(`   Velocity: ${found.velocityMms / 1000} m/s`)
    }

    // Update positions along the route
    console.log('\n4. UPDATING POSITIONS ALONG ROUTE')
    for (let i = 1; i < route.length; i++) {
      const stop = route[i]
      batch = client.createUpsertBatch()
      batch.addFromOptions({
        entity_id: entityId,
        latitude: stop.lat,
        longitude: stop.lon,
        velocity_mps: 5,
        heading: 315,
        group_id: 1n,
      })
      await batch.commit()
      console.log(`   Updated to ${stop.name}: (${stop.lat.toFixed(4)}, ${stop.lon.toFixed(4)})`)
    }

    // Query to verify latest position
    console.log('\n5. VERIFYING LATEST POSITION')
    found = await client.getLatestByUuid(entityId)
    if (found) {
      console.log(`   Latest position: (${found.latitude.toFixed(4)}, ${found.longitude.toFixed(4)})`)
      console.log(
        `   Expected: Fisherman's Wharf (${route[route.length - 1].lat.toFixed(4)}, ${route[route.length - 1].lon.toFixed(4)})`,
      )
    }

    // Query historical positions in the area
    console.log('\n6. QUERYING HISTORICAL POSITIONS IN AREA')
    const result = await client.queryRadius({
      latitude: 37.802,
      longitude: -122.4057,
      radius_m: 2000,
    })
    console.log(`   Found ${result.events.length} historical positions in 2km area`)

    // Delete the entity
    console.log('\n7. DELETING ENTITY')
    const deleteBatch = client.createDeleteBatch()
    deleteBatch.add(entityId)
    const deleteResult = await deleteBatch.commit()
    console.log(`   Deleted ${deleteResult.deletedCount} entities`)
    console.log(`   Not found: ${deleteResult.notFoundCount}`)

    // Verify deletion
    console.log('\n8. VERIFYING DELETION')
    found = await client.getLatestByUuid(entityId)
    if (found === null) {
      console.log('   Entity successfully deleted (not found)')
    } else {
      console.log('   Warning: Entity still found after deletion')
    }

    console.log('\n' + '='.repeat(50))
    console.log('Walkthrough complete!')
    console.log('ok')
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
// endsection:imports
