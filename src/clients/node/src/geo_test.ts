///////////////////////////////////////////////////////
// ArcherDB Node.js SDK - GeoClient Tests            //
// Note: These tests use the skeleton implementation //
// and don't require the native binding.             //
///////////////////////////////////////////////////////

import assert from 'assert'
import { randomFillSync } from 'node:crypto'
import {
  // Types
  GeoEvent,
  GeoEventFlags,
  GeoOperation,
  InsertGeoEventError,
  DeleteEntityError,
  QueryRadiusFilter,
  QueryPolygonFilter,
  PolygonVertex,
  QueryLatestFilter,
  QueryResult,

  // Helpers
  degreesToNano,
  nanoToDegrees,
  metersToMm,
  mmToMeters,
  headingToCentidegrees,
  centidegreesToHeading,
  isValidLatitude,
  isValidLongitude,
  createGeoEvent,
  createRadiusQuery,
  createPolygonQuery,

  // Constants
  LAT_MAX,
  LON_MAX,
  BATCH_SIZE_MAX,
  QUERY_LIMIT_MAX,
  POLYGON_VERTICES_MAX,

  // Client
  GeoClient,
  GeoEventBatch,
  DeleteEntityBatch,
  createGeoClient,

  // Errors
  InvalidCoordinates,
  BatchTooLarge,
  InvalidEntityId,
} from './geo_client'

// Local ID generation (copied from index.ts to avoid loading native binding)
let idLastTimestamp = 0
const idLastBuffer = new DataView(new ArrayBuffer(16))
const idLastBufferArray = new Uint8Array(
    idLastBuffer.buffer, idLastBuffer.byteOffset, idLastBuffer.byteLength
)

function id(): bigint {
  let timestamp = Date.now()
  if (timestamp <= idLastTimestamp) {
    timestamp = idLastTimestamp
  } else {
    idLastTimestamp = timestamp
    randomFillSync(idLastBufferArray)
  }

  const littleEndian = true
  const randomLo32 = idLastBuffer.getUint32(0, littleEndian) + 1
  const randomHi32 = idLastBuffer.getUint32(4, littleEndian) + (randomLo32 > 0xFFFFFFFF ? 1 : 0)
  const randomHi16 = idLastBuffer.getUint16(8, littleEndian) + (randomHi32 > 0xFFFFFFFF ? 1 : 0)
  if (randomHi16 > 0xFFFF) {
    throw new Error('random bits overflow on monotonic increment')
  }

  idLastBuffer.setUint32(0, randomLo32 & 0xFFFFFFFF, littleEndian)
  idLastBuffer.setUint32(4, randomHi32 & 0xFFFFFFFF, littleEndian)
  idLastBuffer.setUint16(8, randomHi16, littleEndian)
  idLastBuffer.setUint16(10, timestamp & 0xFFFF, littleEndian)
  idLastBuffer.setUint32(12, (timestamp / 0x10000) | 0, littleEndian)

  const lo = idLastBuffer.getBigUint64(0, littleEndian)
  const hi = idLastBuffer.getBigUint64(8, littleEndian)
  return (hi << 64n) | lo
}

// ============================================================================
// Coordinate Conversion Tests
// ============================================================================

function test_degreesToNano() {
  // Test positive latitude
  assert.strictEqual(degreesToNano(37.7749), 37774900000n)

  // Test negative longitude
  assert.strictEqual(degreesToNano(-122.4194), -122419400000n)

  // Test edge cases
  assert.strictEqual(degreesToNano(90), 90000000000n)
  assert.strictEqual(degreesToNano(-90), -90000000000n)
  assert.strictEqual(degreesToNano(180), 180000000000n)
  assert.strictEqual(degreesToNano(-180), -180000000000n)

  // Test zero
  assert.strictEqual(degreesToNano(0), 0n)

  console.log('✓ degreesToNano')
}

function test_nanoToDegrees() {
  // Test round-trip conversion
  const lat = 37.7749
  const nano = degreesToNano(lat)
  const back = nanoToDegrees(nano)
  assert.strictEqual(back, lat)

  // Test edge values
  assert.strictEqual(nanoToDegrees(90000000000n), 90)
  assert.strictEqual(nanoToDegrees(-90000000000n), -90)

  console.log('✓ nanoToDegrees')
}

function test_metersToMm() {
  assert.strictEqual(metersToMm(1), 1000)
  assert.strictEqual(metersToMm(5.5), 5500)
  assert.strictEqual(metersToMm(0), 0)
  assert.strictEqual(metersToMm(1000), 1000000) // 1 km

  console.log('✓ metersToMm')
}

function test_mmToMeters() {
  assert.strictEqual(mmToMeters(1000), 1)
  assert.strictEqual(mmToMeters(5500), 5.5)
  assert.strictEqual(mmToMeters(0), 0)

  console.log('✓ mmToMeters')
}

function test_headingConversions() {
  // North
  assert.strictEqual(headingToCentidegrees(0), 0)
  // East
  assert.strictEqual(headingToCentidegrees(90), 9000)
  // South
  assert.strictEqual(headingToCentidegrees(180), 18000)
  // West
  assert.strictEqual(headingToCentidegrees(270), 27000)
  // Full circle
  assert.strictEqual(headingToCentidegrees(360), 36000)

  // Reverse
  assert.strictEqual(centidegreesToHeading(9000), 90)
  assert.strictEqual(centidegreesToHeading(18000), 180)

  console.log('✓ headingConversions')
}

function test_coordinateValidation() {
  // Valid latitudes
  assert.strictEqual(isValidLatitude(0), true)
  assert.strictEqual(isValidLatitude(90), true)
  assert.strictEqual(isValidLatitude(-90), true)
  assert.strictEqual(isValidLatitude(45.5), true)

  // Invalid latitudes
  assert.strictEqual(isValidLatitude(90.1), false)
  assert.strictEqual(isValidLatitude(-90.1), false)
  assert.strictEqual(isValidLatitude(180), false)

  // Valid longitudes
  assert.strictEqual(isValidLongitude(0), true)
  assert.strictEqual(isValidLongitude(180), true)
  assert.strictEqual(isValidLongitude(-180), true)
  assert.strictEqual(isValidLongitude(122.4), true)

  // Invalid longitudes
  assert.strictEqual(isValidLongitude(180.1), false)
  assert.strictEqual(isValidLongitude(-180.1), false)

  console.log('✓ coordinateValidation')
}

// ============================================================================
// GeoEvent Creation Tests
// ============================================================================

function test_createGeoEvent() {
  const entityId = id()

  const event = createGeoEvent({
    entity_id: entityId,
    latitude: 37.7749,
    longitude: -122.4194,
    velocity_mps: 15.5,
    heading: 90,
    accuracy_m: 5,
    ttl_seconds: 86400,
    group_id: 100n,
  })

  assert.strictEqual(event.entity_id, entityId)
  assert.strictEqual(event.lat_nano, 37774900000n)
  assert.strictEqual(event.lon_nano, -122419400000n)
  assert.strictEqual(event.velocity_mms, 15500)
  assert.strictEqual(event.heading_cdeg, 9000)
  assert.strictEqual(event.accuracy_mm, 5000)
  assert.strictEqual(event.ttl_seconds, 86400)
  assert.strictEqual(event.group_id, 100n)
  assert.strictEqual(event.id, 0n) // Server-assigned
  assert.strictEqual(event.timestamp, 0n) // Server-assigned
  assert.strictEqual(event.flags, GeoEventFlags.none)

  console.log('✓ createGeoEvent')
}

function test_createGeoEvent_invalidCoordinates() {
  let threw = false

  // Invalid latitude
  try {
    createGeoEvent({
      entity_id: id(),
      latitude: 91, // Out of range
      longitude: 0,
    })
  } catch (e) {
    threw = true
    assert(e instanceof Error)
    assert(e.message.includes('Invalid latitude'))
  }
  assert(threw, 'Should throw for invalid latitude')

  // Invalid longitude
  threw = false
  try {
    createGeoEvent({
      entity_id: id(),
      latitude: 0,
      longitude: 181, // Out of range
    })
  } catch (e) {
    threw = true
    assert(e instanceof Error)
    assert(e.message.includes('Invalid longitude'))
  }
  assert(threw, 'Should throw for invalid longitude')

  console.log('✓ createGeoEvent_invalidCoordinates')
}

// ============================================================================
// Query Builder Tests
// ============================================================================

function test_createRadiusQuery() {
  const filter = createRadiusQuery({
    latitude: 37.7749,
    longitude: -122.4194,
    radius_m: 1000,
    limit: 500,
    group_id: 42n,
  })

  assert.strictEqual(filter.center_lat_nano, 37774900000n)
  assert.strictEqual(filter.center_lon_nano, -122419400000n)
  assert.strictEqual(filter.radius_mm, 1000000) // 1000m = 1000000mm
  assert.strictEqual(filter.limit, 500)
  assert.strictEqual(filter.group_id, 42n)
  assert.strictEqual(filter.timestamp_min, 0n)
  assert.strictEqual(filter.timestamp_max, 0n)

  console.log('✓ createRadiusQuery')
}

function test_createRadiusQuery_defaults() {
  const filter = createRadiusQuery({
    latitude: 0,
    longitude: 0,
    radius_m: 100,
  })

  assert.strictEqual(filter.limit, 1000) // Default
  assert.strictEqual(filter.group_id, 0n) // Default (no filter)

  console.log('✓ createRadiusQuery_defaults')
}

function test_createRadiusQuery_invalidRadius() {
  let threw = false
  try {
    createRadiusQuery({
      latitude: 0,
      longitude: 0,
      radius_m: 0, // Invalid
    })
  } catch (e) {
    threw = true
    assert(e instanceof Error)
    assert(e.message.includes('Invalid radius'))
  }
  assert(threw, 'Should throw for invalid radius')

  console.log('✓ createRadiusQuery_invalidRadius')
}

function test_createPolygonQuery() {
  const filter = createPolygonQuery({
    vertices: [
      [0, 0],
      [0, 10],
      [10, 10],
      [10, 0],
    ],
    limit: 100,
    group_id: 5n,
  })

  assert.strictEqual(filter.vertices.length, 4)
  assert.strictEqual(filter.vertices[0].lat_nano, 0n)
  assert.strictEqual(filter.vertices[0].lon_nano, 0n)
  assert.strictEqual(filter.vertices[1].lon_nano, 10000000000n)
  assert.strictEqual(filter.limit, 100)
  assert.strictEqual(filter.group_id, 5n)

  console.log('✓ createPolygonQuery')
}

function test_createPolygonQuery_tooFewVertices() {
  let threw = false
  try {
    createPolygonQuery({
      vertices: [
        [0, 0],
        [0, 10],
        // Only 2 vertices - need at least 3
      ],
    })
  } catch (e) {
    threw = true
    assert(e instanceof Error)
    assert(e.message.includes('at least 3 vertices'))
  }
  assert(threw, 'Should throw for too few vertices')

  console.log('✓ createPolygonQuery_tooFewVertices')
}

// ============================================================================
// Batch Tests
// ============================================================================

function test_GeoEventBatch_add() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  const batch = client.createBatch()

  assert.strictEqual(batch.count(), 0)
  assert.strictEqual(batch.isFull(), false)

  // Add an event
  batch.addFromOptions({
    entity_id: id(),
    latitude: 37.7749,
    longitude: -122.4194,
  })

  assert.strictEqual(batch.count(), 1)
  assert.strictEqual(batch.isFull(), false)

  client.destroy()
  console.log('✓ GeoEventBatch_add')
}

function test_GeoEventBatch_validation() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  const batch = client.createBatch()

  // Test invalid entity_id
  let threw = false
  try {
    batch.add({
      id: 0n,
      entity_id: 0n, // Invalid - must not be zero
      correlation_id: 0n,
      user_data: 0n,
      lat_nano: 0n,
      lon_nano: 0n,
      group_id: 0n,
      timestamp: 0n,
      altitude_mm: 0,
      velocity_mms: 0,
      ttl_seconds: 0,
      accuracy_mm: 0,
      heading_cdeg: 0,
      flags: 0,
    })
  } catch (e) {
    threw = true
    assert(e instanceof InvalidEntityId)
  }
  assert(threw, 'Should throw InvalidEntityId for zero entity_id')

  // Test invalid latitude
  threw = false
  try {
    batch.add({
      id: 0n,
      entity_id: id(),
      correlation_id: 0n,
      user_data: 0n,
      lat_nano: 91000000000n, // Out of range
      lon_nano: 0n,
      group_id: 0n,
      timestamp: 0n,
      altitude_mm: 0,
      velocity_mms: 0,
      ttl_seconds: 0,
      accuracy_mm: 0,
      heading_cdeg: 0,
      flags: 0,
    })
  } catch (e) {
    threw = true
    assert(e instanceof InvalidCoordinates)
  }
  assert(threw, 'Should throw InvalidCoordinates for out-of-range latitude')

  client.destroy()
  console.log('✓ GeoEventBatch_validation')
}

function test_GeoEventBatch_clear() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  const batch = client.createBatch()

  batch.addFromOptions({
    entity_id: id(),
    latitude: 0,
    longitude: 0,
  })

  assert.strictEqual(batch.count(), 1)

  batch.clear()

  assert.strictEqual(batch.count(), 0)

  client.destroy()
  console.log('✓ GeoEventBatch_clear')
}

function test_DeleteEntityBatch() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  const batch = client.createDeleteBatch()

  assert.strictEqual(batch.count(), 0)

  // Add entity IDs
  const id1 = id()
  const id2 = id()
  batch.add(id1)
  batch.add(id2)

  assert.strictEqual(batch.count(), 2)

  // Test invalid entity_id
  let threw = false
  try {
    batch.add(0n) // Invalid
  } catch (e) {
    threw = true
    assert(e instanceof InvalidEntityId)
  }
  assert(threw, 'Should throw InvalidEntityId for zero entity_id')

  client.destroy()
  console.log('✓ DeleteEntityBatch')
}

// ============================================================================
// Client Tests
// ============================================================================

function test_GeoClient_lifecycle() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  assert.strictEqual(client.isConnected(), true)

  client.destroy()

  assert.strictEqual(client.isConnected(), false)

  console.log('✓ GeoClient_lifecycle')
}

function test_GeoClient_invalidConfig() {
  let threw = false
  try {
    createGeoClient({
      cluster_id: 0n,
      addresses: [], // No addresses
    })
  } catch (e) {
    threw = true
    assert(e instanceof Error)
    assert(e.message.includes('At least one replica address'))
  }
  assert(threw, 'Should throw for empty addresses')

  console.log('✓ GeoClient_invalidConfig')
}

// ============================================================================
// Constants Tests
// ============================================================================

function test_constants() {
  assert.strictEqual(LAT_MAX, 90.0)
  assert.strictEqual(LON_MAX, 180.0)
  assert.strictEqual(BATCH_SIZE_MAX, 10_000)
  assert.strictEqual(QUERY_LIMIT_MAX, 81_000)
  assert.strictEqual(POLYGON_VERTICES_MAX, 10_000)

  console.log('✓ constants')
}

// ============================================================================
// GeoOperation Enum Tests
// ============================================================================

function test_GeoOperation_values() {
  // Verify operation codes match archerdb.zig values
  // vsr_operations_reserved = 128
  assert.strictEqual(GeoOperation.insert_events, 146)  // 128 + 18
  assert.strictEqual(GeoOperation.upsert_events, 147)  // 128 + 19
  assert.strictEqual(GeoOperation.delete_entities, 148) // 128 + 20
  assert.strictEqual(GeoOperation.query_uuid, 149)     // 128 + 21
  assert.strictEqual(GeoOperation.query_radius, 150)   // 128 + 22
  assert.strictEqual(GeoOperation.query_polygon, 151)  // 128 + 23
  assert.strictEqual(GeoOperation.query_latest, 154)   // 128 + 26

  console.log('✓ GeoOperation_values')
}

// ============================================================================
// Error Type Tests
// ============================================================================

function test_InsertGeoEventError_values() {
  assert.strictEqual(InsertGeoEventError.ok, 0)
  assert.strictEqual(InsertGeoEventError.linked_event_failed, 1)
  assert.strictEqual(InsertGeoEventError.entity_id_must_not_be_zero, 7)
  assert.strictEqual(InsertGeoEventError.invalid_coordinates, 8)
  assert.strictEqual(InsertGeoEventError.lat_out_of_range, 9)
  assert.strictEqual(InsertGeoEventError.lon_out_of_range, 10)

  console.log('✓ InsertGeoEventError_values')
}

function test_DeleteEntityError_values() {
  assert.strictEqual(DeleteEntityError.ok, 0)
  assert.strictEqual(DeleteEntityError.entity_not_found, 3)

  console.log('✓ DeleteEntityError_values')
}

// ============================================================================
// ID Generation Tests
// ============================================================================

function test_id_generation() {
  const id1 = id()
  const id2 = id()
  const id3 = id()

  // IDs should be monotonically increasing
  assert(id2 > id1, 'IDs should be monotonically increasing')
  assert(id3 > id2, 'IDs should be monotonically increasing')

  // IDs should be positive
  assert(id1 > 0n, 'ID should be positive')

  // IDs should be valid u128
  assert(id1 < (2n ** 128n), 'ID should fit in u128')

  console.log('✓ id_generation')
}

// ============================================================================
// Run All Tests
// ============================================================================

function runTests() {
  console.log('\n=== ArcherDB Node.js SDK Tests ===\n')

  // Coordinate conversion tests
  test_degreesToNano()
  test_nanoToDegrees()
  test_metersToMm()
  test_mmToMeters()
  test_headingConversions()
  test_coordinateValidation()

  // GeoEvent creation tests
  test_createGeoEvent()
  test_createGeoEvent_invalidCoordinates()

  // Query builder tests
  test_createRadiusQuery()
  test_createRadiusQuery_defaults()
  test_createRadiusQuery_invalidRadius()
  test_createPolygonQuery()
  test_createPolygonQuery_tooFewVertices()

  // Batch tests
  test_GeoEventBatch_add()
  test_GeoEventBatch_validation()
  test_GeoEventBatch_clear()
  test_DeleteEntityBatch()

  // Client tests
  test_GeoClient_lifecycle()
  test_GeoClient_invalidConfig()

  // Constants tests
  test_constants()

  // Operation enum tests
  test_GeoOperation_values()

  // Error type tests
  test_InsertGeoEventError_values()
  test_DeleteEntityError_values()

  // ID generation tests
  test_id_generation()

  console.log('\n=== All tests passed! ===\n')
}

// Run tests when module is executed directly
runTests()
