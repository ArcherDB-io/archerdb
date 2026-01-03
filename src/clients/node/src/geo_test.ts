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
  RetryExhausted,
  OperationTimeout,
  ClusterUnavailable,
  ViewChangeInProgress,
  NotPrimary,
  ConnectionFailed,
  TLSError,
  PolygonTooComplex,
  QueryResultTooLarge,

  // Batch helpers
  splitBatch,

  // Internal exports for testing retry logic
  _testExports,
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
// Split Batch Helper Tests
// ============================================================================

function test_splitBatch_basic() {
  const items = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

  // Split into chunks of 3
  const chunks = splitBatch(items, 3)

  assert.strictEqual(chunks.length, 4)
  assert.deepStrictEqual(chunks[0], [1, 2, 3])
  assert.deepStrictEqual(chunks[1], [4, 5, 6])
  assert.deepStrictEqual(chunks[2], [7, 8, 9])
  assert.deepStrictEqual(chunks[3], [10])

  console.log('✓ splitBatch_basic')
}

function test_splitBatch_exactDivision() {
  const items = [1, 2, 3, 4, 5, 6]

  // Exact division
  const chunks = splitBatch(items, 2)

  assert.strictEqual(chunks.length, 3)
  assert.deepStrictEqual(chunks[0], [1, 2])
  assert.deepStrictEqual(chunks[1], [3, 4])
  assert.deepStrictEqual(chunks[2], [5, 6])

  console.log('✓ splitBatch_exactDivision')
}

function test_splitBatch_emptyArray() {
  const items: number[] = []

  const chunks = splitBatch(items, 3)

  assert.strictEqual(chunks.length, 0)

  console.log('✓ splitBatch_emptyArray')
}

function test_splitBatch_singleChunk() {
  const items = [1, 2, 3]

  // Chunk size larger than array
  const chunks = splitBatch(items, 10)

  assert.strictEqual(chunks.length, 1)
  assert.deepStrictEqual(chunks[0], [1, 2, 3])

  console.log('✓ splitBatch_singleChunk')
}

function test_splitBatch_chunkSizeOne() {
  const items = [1, 2, 3]

  const chunks = splitBatch(items, 1)

  assert.strictEqual(chunks.length, 3)
  assert.deepStrictEqual(chunks[0], [1])
  assert.deepStrictEqual(chunks[1], [2])
  assert.deepStrictEqual(chunks[2], [3])

  console.log('✓ splitBatch_chunkSizeOne')
}

function test_splitBatch_zeroChunkSize_throws() {
  const items = [1, 2, 3]

  assert.throws(() => {
    splitBatch(items, 0)
  }, /chunkSize must be greater than 0/)

  console.log('✓ splitBatch_zeroChunkSize_throws')
}

function test_splitBatch_negativeChunkSize_throws() {
  const items = [1, 2, 3]

  assert.throws(() => {
    splitBatch(items, -1)
  }, /chunkSize must be greater than 0/)

  console.log('✓ splitBatch_negativeChunkSize_throws')
}

function test_splitBatch_defaultChunkSize() {
  // Create an array of 2500 items
  const items = Array.from({ length: 2500 }, (_, i) => i)

  // Use default chunk size (1000)
  const chunks = splitBatch(items)

  assert.strictEqual(chunks.length, 3)
  assert.strictEqual(chunks[0].length, 1000)
  assert.strictEqual(chunks[1].length, 1000)
  assert.strictEqual(chunks[2].length, 500)

  console.log('✓ splitBatch_defaultChunkSize')
}

// ============================================================================
// Partial Failure Scenario Tests (F5.3.9)
// ============================================================================

// --- Error Classification Tests ---

function test_isRetryableError_retryableErrors() {
  const { isRetryableError } = _testExports

  // Retryable ArcherDB errors
  assert.strictEqual(isRetryableError(new OperationTimeout('timeout')), true)
  assert.strictEqual(isRetryableError(new ClusterUnavailable('unavailable')), true)
  assert.strictEqual(isRetryableError(new ViewChangeInProgress('view change')), true)
  assert.strictEqual(isRetryableError(new NotPrimary('not primary')), true)
  assert.strictEqual(isRetryableError(new ConnectionFailed('failed')), true)

  console.log('✓ isRetryableError_retryableErrors')
}

function test_isRetryableError_nonRetryableErrors() {
  const { isRetryableError } = _testExports

  // Non-retryable ArcherDB errors
  assert.strictEqual(isRetryableError(new InvalidCoordinates('bad coords')), false)
  assert.strictEqual(isRetryableError(new BatchTooLarge('too big')), false)
  assert.strictEqual(isRetryableError(new InvalidEntityId('bad id')), false)
  assert.strictEqual(isRetryableError(new TLSError('tls failed')), false)
  assert.strictEqual(isRetryableError(new PolygonTooComplex('too complex')), false)
  assert.strictEqual(isRetryableError(new QueryResultTooLarge('too large')), false)

  console.log('✓ isRetryableError_nonRetryableErrors')
}

function test_isRetryableError_networkErrors() {
  const { isRetryableError } = _testExports

  // Network errors (generic Error with specific messages)
  assert.strictEqual(isRetryableError(new Error('Connection timeout')), true)
  assert.strictEqual(isRetryableError(new Error('ECONNRESET')), true)
  assert.strictEqual(isRetryableError(new Error('ECONNREFUSED')), true)
  assert.strictEqual(isRetryableError(new Error('EPIPE')), true)
  assert.strictEqual(isRetryableError(new Error('network error')), true)

  // Non-network generic errors
  assert.strictEqual(isRetryableError(new Error('some other error')), false)
  assert.strictEqual(isRetryableError(new Error('invalid data')), false)

  console.log('✓ isRetryableError_networkErrors')
}

// --- Backoff Calculation Tests ---

function test_calculateRetryDelay_schedule() {
  const { calculateRetryDelay } = _testExports

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 100,
    max_backoff_ms: 1600,
    total_timeout_ms: 30000,
    jitter: false, // Disable jitter for deterministic testing
  }

  // First attempt is immediate
  assert.strictEqual(calculateRetryDelay(1, config), 0)

  // Subsequent attempts follow exponential backoff
  // attempt 2: 100 * 2^0 = 100
  assert.strictEqual(calculateRetryDelay(2, config), 100)
  // attempt 3: 100 * 2^1 = 200
  assert.strictEqual(calculateRetryDelay(3, config), 200)
  // attempt 4: 100 * 2^2 = 400
  assert.strictEqual(calculateRetryDelay(4, config), 400)
  // attempt 5: 100 * 2^3 = 800
  assert.strictEqual(calculateRetryDelay(5, config), 800)
  // attempt 6: 100 * 2^4 = 1600
  assert.strictEqual(calculateRetryDelay(6, config), 1600)

  console.log('✓ calculateRetryDelay_schedule')
}

function test_calculateRetryDelay_maxBackoff() {
  const { calculateRetryDelay } = _testExports

  const config = {
    enabled: true,
    max_retries: 10,
    base_backoff_ms: 100,
    max_backoff_ms: 500, // Capped at 500ms
    total_timeout_ms: 30000,
    jitter: false,
  }

  // Should cap at max_backoff_ms
  // attempt 5: 100 * 2^3 = 800, but capped to 500
  assert.strictEqual(calculateRetryDelay(5, config), 500)
  // attempt 6 and beyond stay capped
  assert.strictEqual(calculateRetryDelay(6, config), 500)
  assert.strictEqual(calculateRetryDelay(10, config), 500)

  console.log('✓ calculateRetryDelay_maxBackoff')
}

function test_calculateRetryDelay_jitter() {
  const { calculateRetryDelay } = _testExports

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 100,
    max_backoff_ms: 1600,
    total_timeout_ms: 30000,
    jitter: true, // Enable jitter
  }

  // With jitter, delay should be base_delay + random(0, base_delay/2)
  // For attempt 2 with base_delay 100: should be 100-150ms
  const delays: number[] = []
  for (let i = 0; i < 100; i++) {
    delays.push(calculateRetryDelay(2, config))
  }

  // All delays should be within expected range
  const minDelay = Math.min(...delays)
  const maxDelay = Math.max(...delays)

  assert(minDelay >= 100, `Min delay ${minDelay} should be >= 100`)
  assert(maxDelay <= 150, `Max delay ${maxDelay} should be <= 150`)
  // With 100 samples, we should see some variation
  assert(maxDelay > minDelay, 'Jitter should cause variation in delays')

  console.log('✓ calculateRetryDelay_jitter')
}

// --- Retry Logic Tests ---

async function test_withRetry_success() {
  const { withRetry } = _testExports

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 10, // Short for testing
    max_backoff_ms: 100,
    total_timeout_ms: 1000,
    jitter: false,
  }

  let attempts = 0
  const result = await withRetry(async () => {
    attempts++
    return 'success'
  }, config)

  assert.strictEqual(result, 'success')
  assert.strictEqual(attempts, 1) // Should succeed on first try

  console.log('✓ withRetry_success')
}

async function test_withRetry_eventualSuccess() {
  const { withRetry } = _testExports

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 10,
    max_backoff_ms: 100,
    total_timeout_ms: 5000,
    jitter: false,
  }

  let attempts = 0
  const result = await withRetry(async () => {
    attempts++
    if (attempts < 3) {
      throw new ConnectionFailed('simulated failure')
    }
    return 'success after retries'
  }, config)

  assert.strictEqual(result, 'success after retries')
  assert.strictEqual(attempts, 3) // Failed twice, succeeded on third

  console.log('✓ withRetry_eventualSuccess')
}

async function test_withRetry_exhaustion() {
  const { withRetry } = _testExports

  const config = {
    enabled: true,
    max_retries: 3,
    base_backoff_ms: 10,
    max_backoff_ms: 100,
    total_timeout_ms: 5000,
    jitter: false,
  }

  let attempts = 0
  let threw = false
  try {
    await withRetry(async () => {
      attempts++
      throw new ClusterUnavailable('always fails')
    }, config)
  } catch (e) {
    threw = true
    assert(e instanceof RetryExhausted)
    assert.strictEqual(e.attempts, 4) // max_retries + 1 = 4
    assert(e.lastError instanceof ClusterUnavailable)
  }

  assert(threw, 'Should throw RetryExhausted')
  assert.strictEqual(attempts, 4) // All 4 attempts made

  console.log('✓ withRetry_exhaustion')
}

async function test_withRetry_nonRetryableError() {
  const { withRetry } = _testExports

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 10,
    max_backoff_ms: 100,
    total_timeout_ms: 5000,
    jitter: false,
  }

  let attempts = 0
  let threw = false
  try {
    await withRetry(async () => {
      attempts++
      throw new InvalidCoordinates('bad coordinates')
    }, config)
  } catch (e) {
    threw = true
    assert(e instanceof InvalidCoordinates)
    assert.strictEqual(e.message, 'bad coordinates')
  }

  assert(threw, 'Should throw immediately without retry')
  assert.strictEqual(attempts, 1) // No retries for non-retryable errors

  console.log('✓ withRetry_nonRetryableError')
}

async function test_withRetry_totalTimeout() {
  const { withRetry } = _testExports

  const config = {
    enabled: true,
    max_retries: 100, // Many retries allowed
    base_backoff_ms: 50,
    max_backoff_ms: 100,
    total_timeout_ms: 200, // But short total timeout
    jitter: false,
  }

  let attempts = 0
  let threw = false
  const startTime = Date.now()

  try {
    await withRetry(async () => {
      attempts++
      throw new OperationTimeout('simulated timeout')
    }, config)
  } catch (e) {
    threw = true
    assert(e instanceof RetryExhausted)
  }

  const elapsed = Date.now() - startTime

  assert(threw, 'Should throw RetryExhausted')
  // Should stop due to total timeout, not max_retries
  assert(attempts < 100, `Should stop early due to timeout (attempts: ${attempts})`)
  // Elapsed time should be around total_timeout_ms
  assert(elapsed >= 150, `Elapsed time ${elapsed}ms should be >= 150ms`)
  assert(elapsed < 500, `Elapsed time ${elapsed}ms should be < 500ms`)

  console.log('✓ withRetry_totalTimeout')
}

async function test_withRetry_disabled() {
  const { withRetry } = _testExports

  const config = {
    enabled: false, // Retry disabled
    max_retries: 5,
    base_backoff_ms: 10,
    max_backoff_ms: 100,
    total_timeout_ms: 5000,
    jitter: false,
  }

  let attempts = 0
  let threw = false
  try {
    await withRetry(async () => {
      attempts++
      throw new ClusterUnavailable('fails')
    }, config)
  } catch (e) {
    threw = true
    assert(e instanceof ClusterUnavailable)
  }

  assert(threw, 'Should throw original error')
  assert.strictEqual(attempts, 1) // No retries when disabled

  console.log('✓ withRetry_disabled')
}

// --- Partial Batch Retry Pattern Tests ---

async function test_partialBatchRetryPattern() {
  // This tests the recommended pattern from the spec:
  // When a large batch times out, split and retry smaller chunks

  const largeEventList = Array.from({ length: 5000 }, (_, i) => ({
    id: BigInt(i),
    data: `event-${i}`,
  }))

  // Simulate: first batch times out, then smaller batches succeed
  let submitCount = 0
  const mockSubmit = async (events: typeof largeEventList) => {
    submitCount++
    if (events.length > 1000 && submitCount === 1) {
      // First large batch times out
      throw new OperationTimeout('batch too large, timeout')
    }
    // Smaller batches succeed
    return events.map(e => ({ id: e.id, result: 'ok' }))
  }

  // Pattern implementation
  let results: { id: bigint; result: string }[] = []
  try {
    results = await mockSubmit(largeEventList)
  } catch (e) {
    if (e instanceof OperationTimeout) {
      // Split into smaller batches and retry
      const chunks = splitBatch(largeEventList, 1000)
      for (const chunk of chunks) {
        const chunkResults = await mockSubmit(chunk)
        results.push(...chunkResults)
      }
    } else {
      throw e
    }
  }

  // All events should have been processed
  assert.strictEqual(results.length, 5000)
  // Should have made 6 total submissions (1 failed + 5 chunk retries)
  assert.strictEqual(submitCount, 6)

  console.log('✓ partialBatchRetryPattern')
}

// --- RetryExhausted Error Tests ---

function test_RetryExhausted_properties() {
  const lastError = new ClusterUnavailable('final failure')
  const error = new RetryExhausted(5, lastError)

  assert.strictEqual(error.code, 5001)
  assert.strictEqual(error.retryable, false)
  assert.strictEqual(error.attempts, 5)
  assert.strictEqual(error.lastError, lastError)
  assert(error.message.includes('5 retry attempts'))
  assert(error.message.includes('final failure'))

  console.log('✓ RetryExhausted_properties')
}

// ============================================================================
// Run All Tests
// ============================================================================

async function runTests() {
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

  // Split batch helper tests
  test_splitBatch_basic()
  test_splitBatch_exactDivision()
  test_splitBatch_emptyArray()
  test_splitBatch_singleChunk()
  test_splitBatch_chunkSizeOne()
  test_splitBatch_zeroChunkSize_throws()
  test_splitBatch_negativeChunkSize_throws()
  test_splitBatch_defaultChunkSize()

  // =========================================
  // Partial Failure Scenario Tests (F5.3.9)
  // =========================================
  console.log('\n--- Partial Failure Scenario Tests ---\n')

  // Error classification tests
  test_isRetryableError_retryableErrors()
  test_isRetryableError_nonRetryableErrors()
  test_isRetryableError_networkErrors()

  // Backoff calculation tests
  test_calculateRetryDelay_schedule()
  test_calculateRetryDelay_maxBackoff()
  test_calculateRetryDelay_jitter()

  // Retry logic tests (async)
  await test_withRetry_success()
  await test_withRetry_eventualSuccess()
  await test_withRetry_exhaustion()
  await test_withRetry_nonRetryableError()
  await test_withRetry_totalTimeout()
  await test_withRetry_disabled()

  // Partial batch retry pattern test (async)
  await test_partialBatchRetryPattern()

  // RetryExhausted error tests
  test_RetryExhausted_properties()

  console.log('\n=== All tests passed! ===\n')
}

// Run tests when module is executed directly
runTests()
