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
  prepareGeoEvent,
  createRadiusQuery,
  createPolygonQuery,

  // Jump Hash (source of truth: src/sharding.zig)
  jumpHash,
  computeShardKey,
  getShardForEntity,
  ShardingStrategy,

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
  PolygonTooComplex,
  QueryResultTooLarge,
  CircuitBreakerOpen,

  // Circuit Breaker
  CircuitBreaker,
  CircuitState,

  // Cleanup types and helpers
  CleanupResult,
  hasCleanupRemovals,
  getCleanupExpirationRatio,
  CLEANUP_RESULT_SIZE,

  // Batch helpers
  splitBatch,
  submitMultiBatch,

  // Internal exports for testing retry logic
  _testExports,
} from './geo_client'

// Polygon validation imports (from geo.ts)
import {
  PolygonValidationError,
  segmentsIntersect,
  validatePolygonNoSelfIntersection,
} from './geo'

// Observability imports (from separate module)
import {
  LogLevel,
  SDKLogger,
  ConsoleLogger,
  NullLogger,
  configureLogging,
  getLogger,
  MetricLabels,
  Counter,
  Gauge,
  Histogram,
  SDKMetrics,
  getMetrics,
  resetMetrics,
  ConnectionState,
  HealthStatus,
  HealthTracker,
  RequestTimer,
} from './observability'

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
  // ID should be 0 until prepareGeoEvent is called
  assert.strictEqual(event.id, 0n)
  assert.strictEqual(event.timestamp, 0n) // Server-assigned (timestamp field, not the ID timestamp component)
  assert.strictEqual(event.flags, GeoEventFlags.none)

  console.log('✓ createGeoEvent')
}

function test_prepareGeoEvent() {
  const event = createGeoEvent({
    entity_id: id(),
    latitude: 37.7749,
    longitude: -122.4194,
  })

  // Before prepare, id should be 0
  assert.strictEqual(event.id, 0n)

  // Prepare the event
  prepareGeoEvent(event)

  // After prepare, id should be a non-zero composite key (S2 cell ID + timestamp)
  assert.notStrictEqual(event.id, 0n)

  // Calling prepare again should not change the ID (already prepared)
  const originalId = event.id
  prepareGeoEvent(event)
  assert.strictEqual(event.id, originalId)

  console.log('✓ prepareGeoEvent')
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
  assert.strictEqual(GeoOperation.cleanup_expired, 155) // 128 + 27

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
// TTL Cleanup Tests (cleanup_expired per client-protocol/spec.md)
// ============================================================================

function test_CleanupResult_type() {
  const result: CleanupResult = {
    entries_scanned: 100n,
    entries_removed: 25n,
  }

  assert.strictEqual(result.entries_scanned, 100n)
  assert.strictEqual(result.entries_removed, 25n)

  console.log('✓ CleanupResult_type')
}

function test_CleanupResult_helpers() {
  const resultWithRemovals: CleanupResult = {
    entries_scanned: 100n,
    entries_removed: 25n,
  }

  const resultWithoutRemovals: CleanupResult = {
    entries_scanned: 100n,
    entries_removed: 0n,
  }

  const emptyResult: CleanupResult = {
    entries_scanned: 0n,
    entries_removed: 0n,
  }

  // Test hasCleanupRemovals
  assert.strictEqual(hasCleanupRemovals(resultWithRemovals), true)
  assert.strictEqual(hasCleanupRemovals(resultWithoutRemovals), false)
  assert.strictEqual(hasCleanupRemovals(emptyResult), false)

  // Test getCleanupExpirationRatio
  assert(Math.abs(getCleanupExpirationRatio(resultWithRemovals) - 0.25) < 0.0001)
  assert.strictEqual(getCleanupExpirationRatio(resultWithoutRemovals), 0.0)
  assert.strictEqual(getCleanupExpirationRatio(emptyResult), 0.0) // No division by zero

  console.log('✓ CleanupResult_helpers')
}

function test_CleanupResult_wireFormatSize() {
  // Per spec: cleanup response is 16 bytes (2x u64)
  assert.strictEqual(CLEANUP_RESULT_SIZE, 16)

  console.log('✓ CleanupResult_wireFormatSize')
}

async function test_GeoClient_cleanupExpired() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  // Test cleanup with default batch size (0 = scan all)
  const result = await client.cleanupExpired()
  assert.strictEqual(result.entries_scanned, 0n)
  assert.strictEqual(result.entries_removed, 0n)

  // Test cleanup with explicit batch size
  const resultWithBatch = await client.cleanupExpired(1000)
  assert.strictEqual(resultWithBatch.entries_scanned, 0n)
  assert.strictEqual(resultWithBatch.entries_removed, 0n)

  client.destroy()

  console.log('✓ GeoClient_cleanupExpired')
}

async function test_GeoClient_cleanupExpired_negativeBatch() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  let threw = false
  try {
    await client.cleanupExpired(-1)
  } catch (e) {
    threw = true
    assert(e instanceof Error)
    assert(e.message.includes('non-negative'))
  }
  assert(threw, 'Should throw for negative batch size')

  client.destroy()

  console.log('✓ GeoClient_cleanupExpired_negativeBatch')
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

// =====================================================================
// Multi-Batch Submit Tests
// =====================================================================

async function test_submitMultiBatch_retriesFailedBatchOnly() {
  const { withRetry } = _testExports
  const attempts: Record<number, number> = {}
  const retryConfig = {
    enabled: true,
    max_retries: 1,
    base_backoff_ms: 0,
    max_backoff_ms: 0,
    total_timeout_ms: 1000,
    jitter: false,
  }

  const submit = async (_op: GeoOperation, batch: number[]) => {
    return withRetry(async () => {
      const key = batch[0]
      attempts[key] = (attempts[key] ?? 0) + 1
      if (key === 3 && attempts[key] === 1) {
        throw new OperationTimeout('timeout')
      }
      return []
    }, retryConfig)
  }

  const errors = await submitMultiBatch(
    GeoOperation.insert_events,
    [1, 2, 3, 4],
    submit,
    2
  )

  assert.strictEqual(errors.length, 0)
  assert.strictEqual(attempts[1], 1)
  assert.strictEqual(attempts[3], 2)

  console.log('✓ submitMultiBatch_retriesFailedBatchOnly')
}

function test_submitMultiBatch_offsetsIndices() {
  const submit = async (_op: GeoOperation, _batch: number[]) => {
    return [{ index: 0, result: InsertGeoEventError.invalid_coordinates }]
  }

  return submitMultiBatch(
    GeoOperation.insert_events,
    [1, 2, 3],
    submit,
    2
  ).then(errors => {
    assert.strictEqual(errors.length, 2)
    assert.strictEqual(errors[0].index, 0)
    assert.strictEqual(errors[1].index, 2)
    console.log('✓ submitMultiBatch_offsetsIndices')
  })
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

async function test_insertEvents_multiBatch_integration() {
  if (process.env.ARCHERDB_INTEGRATION !== '1') {
    console.log('SKIP: insertEvents_multiBatch_integration (set ARCHERDB_INTEGRATION=1)')
    return
  }

  const address = process.env.ARCHERDB_ADDRESS ?? '127.0.0.1:3001'
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: [address],
  })

  try {
    const events = [
      prepareGeoEvent(createGeoEvent({ entity_id: 1n, latitude: 37.7749, longitude: -122.4194 })),
      prepareGeoEvent(createGeoEvent({ entity_id: 2n, latitude: 37.7750, longitude: -122.4195 })),
      prepareGeoEvent(createGeoEvent({ entity_id: 3n, latitude: 37.7751, longitude: -122.4196 })),
    ]

    const submit = (op: GeoOperation, batch: GeoEvent[]) => (
      (client as any)._submitBatch(op, batch)
    )
    const errors = await submitMultiBatch(
      GeoOperation.insert_events,
      events,
      submit,
      2
    )

    assert.strictEqual(errors.length, 0)
    console.log('✓ insertEvents_multiBatch_integration')
  } finally {
    client.destroy()
  }
}

async function test_insert_query_delete_integration() {
  if (process.env.ARCHERDB_INTEGRATION !== '1') {
    console.log('SKIP: insert_query_delete_integration (set ARCHERDB_INTEGRATION=1)')
    return
  }

  const address = process.env.ARCHERDB_ADDRESS ?? '127.0.0.1:3001'
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: [address],
  })

  try {
    const entityId = id()
    const lat = 37.7749
    const lon = -122.4194

    // 1. Insert
    const event = createGeoEvent({
      entity_id: entityId,
      latitude: lat,
      longitude: lon,
      ttl_seconds: 60,
    })

    const insertErrors = await client.insertEvents([event])
    assert.strictEqual(insertErrors.length, 0, 'Insert should succeed')

    // 2. Query UUID
    let found: GeoEvent | null = null
    for (let i = 0; i < 10; i++) {
        found = await client.getLatestByUuid(entityId)
        if (found) {
            break
        }
        await new Promise(resolve => setTimeout(resolve, 100))
    }
    
    assert(found, 'Entity should be found')
    assert.strictEqual(found!.entity_id, entityId)

    // 3. Query Radius
    const radiusResult = await client.queryRadius({
        latitude: lat,
        longitude: lon,
        radius_m: 2000,
        limit: 5
    })
    assert(radiusResult.events.length > 0, 'Radius query should find events')

    // 4. Delete
    const deleteResult = await client.deleteEntities([entityId])
    assert.strictEqual(deleteResult.deleted_count, 1)

    // 5. Verify Delete
    const resultAfter = await client.getLatestByUuid(entityId)
    assert.strictEqual(resultAfter, null, 'Entity should be deleted')

    console.log('✓ insert_query_delete_integration')
  } finally {
    client.destroy()
  }
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
// Observability Tests (per client-sdk/spec.md)
// ============================================================================

function test_NullLogger() {
  const logger = new NullLogger()
  // Should not throw
  logger.debug('debug message')
  logger.info('info message')
  logger.warn('warn message')
  logger.error('error message')
  console.log('✓ NullLogger')
}

function test_ConsoleLogger() {
  // Create a logger but don't actually log (we can't capture console output easily)
  const logger = new ConsoleLogger('test', LogLevel.ERROR)
  // These should not produce output (level is ERROR)
  logger.debug('should not appear')
  logger.info('should not appear')
  logger.warn('should not appear')
  // Only ERROR level would appear, but we won't actually call it to avoid noise
  console.log('✓ ConsoleLogger')
}

function test_configureLogging() {
  // Test with custom logger
  const customLogger = new NullLogger()
  configureLogging({ logger: customLogger })
  const logger1 = getLogger()
  assert.strictEqual(logger1, customLogger)

  // Test with debug flag
  configureLogging({ debug: true })
  const logger2 = getLogger()
  assert(logger2 instanceof ConsoleLogger)

  // Reset to null logger for other tests
  configureLogging({ logger: new NullLogger() })
  console.log('✓ configureLogging')
}

function test_Counter_inc() {
  const counter = new Counter('test_counter', 'Test counter')

  // Initial value is 0
  assert.strictEqual(counter.get(), 0)

  // Increment
  counter.inc()
  assert.strictEqual(counter.get(), 1)

  // Increment by value
  counter.inc(undefined, 5)
  assert.strictEqual(counter.get(), 6)

  console.log('✓ Counter_inc')
}

function test_Counter_labels() {
  const counter = new Counter('test_counter', 'Test counter')

  const labels1: MetricLabels = { operation: 'query', status: 'success' }
  const labels2: MetricLabels = { operation: 'query', status: 'error' }

  counter.inc(labels1)
  counter.inc(labels1)
  counter.inc(labels2)

  assert.strictEqual(counter.get(labels1), 2)
  assert.strictEqual(counter.get(labels2), 1)

  console.log('✓ Counter_labels')
}

function test_Gauge_operations() {
  const gauge = new Gauge('test_gauge', 'Test gauge')

  // Initial value is 0
  assert.strictEqual(gauge.get(), 0)

  // Set
  gauge.set(10)
  assert.strictEqual(gauge.get(), 10)

  // Inc
  gauge.inc(5)
  assert.strictEqual(gauge.get(), 15)

  // Dec
  gauge.dec(3)
  assert.strictEqual(gauge.get(), 12)

  console.log('✓ Gauge_operations')
}

function test_Histogram_observe() {
  const hist = new Histogram('test_histogram', 'Test histogram')

  // Initial state
  assert.strictEqual(hist.getCount(), 0)
  assert.strictEqual(hist.getSum(), 0)

  // Observe values
  hist.observe(0.1)
  hist.observe(0.5)
  hist.observe(1.0)

  assert.strictEqual(hist.getCount(), 3)
  assert(Math.abs(hist.getSum() - 1.6) < 0.0001)

  console.log('✓ Histogram_observe')
}

function test_SDKMetrics_recordRequest() {
  const metrics = new SDKMetrics()

  metrics.recordRequest('query_radius', 'success', 0.05)
  metrics.recordRequest('query_radius', 'success', 0.03)
  metrics.recordRequest('query_radius', 'error', 0.1)

  // Check request count
  const successLabels: MetricLabels = { operation: 'query_radius', status: 'success' }
  const errorLabels: MetricLabels = { operation: 'query_radius', status: 'error' }

  assert.strictEqual(metrics.requestsTotal.get(successLabels), 2)
  assert.strictEqual(metrics.requestsTotal.get(errorLabels), 1)

  console.log('✓ SDKMetrics_recordRequest')
}

function test_SDKMetrics_prometheusExport() {
  const metrics = new SDKMetrics()
  metrics.recordRequest('insert', 'success', 0.01)
  metrics.recordConnectionOpened()

  const output = metrics.toPrometheus()

  assert(output.includes('archerdb_client_requests_total'))
  assert(output.includes('archerdb_client_connections_active'))
  assert(output.includes('# HELP'))
  assert(output.includes('# TYPE'))

  console.log('✓ SDKMetrics_prometheusExport')
}

function test_getMetrics_singleton() {
  resetMetrics()
  const metrics1 = getMetrics()
  const metrics2 = getMetrics()

  assert.strictEqual(metrics1, metrics2)

  console.log('✓ getMetrics_singleton')
}

function test_retryMetrics() {
  const metrics = new SDKMetrics()

  // Record retries
  metrics.recordRetry()
  metrics.recordRetry()
  metrics.recordRetry()

  assert.strictEqual(metrics.retriesTotal.get(), 3)

  console.log('✓ retryMetrics')
}

function test_retryMetrics_prometheusExport() {
  const metrics = new SDKMetrics()
  metrics.recordRetry()
  metrics.recordRetryExhausted()
  metrics.recordPrimaryDiscovery()

  const output = metrics.toPrometheus()

  assert(output.includes('archerdb_client_retries_total'))
  assert(output.includes('archerdb_client_retry_exhausted_total'))
  assert(output.includes('archerdb_client_primary_discoveries_total'))

  console.log('✓ retryMetrics_prometheusExport')
}

// ============================================================================
// Retry Metrics Integration Tests (per client-retry/spec.md)
// ============================================================================

async function test_withRetry_recordsMetricsOnRetry() {
  const { withRetry } = _testExports

  // Reset metrics for this test
  resetMetrics()

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 1, // Fast tests
    max_backoff_ms: 10,
    total_timeout_ms: 30000,
    jitter: false,
  }

  let attempts = 0
  const result = await withRetry(async () => {
    attempts++
    if (attempts < 3) {
      throw new ClusterUnavailable('temporary failure')
    }
    return 'success'
  }, config)

  assert.strictEqual(result, 'success')
  assert.strictEqual(attempts, 3)

  const metrics = getMetrics()
  // 2 retries recorded (first 2 failures led to retries)
  assert.strictEqual(metrics.retriesTotal.get(), 2)
  // No exhaustion - we succeeded
  assert.strictEqual(metrics.retryExhaustedTotal.get(), 0)

  console.log('✓ withRetry_recordsMetricsOnRetry')
}

async function test_withRetry_recordsExhaustionMetric() {
  const { withRetry } = _testExports

  // Reset metrics for this test
  resetMetrics()

  const config = {
    enabled: true,
    max_retries: 3,
    base_backoff_ms: 1, // Fast tests
    max_backoff_ms: 10,
    total_timeout_ms: 30000,
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
  }

  assert(threw, 'Should throw RetryExhausted')
  assert.strictEqual(attempts, 4) // Initial + 3 retries

  const metrics = getMetrics()
  // 3 retries recorded
  assert.strictEqual(metrics.retriesTotal.get(), 3)
  // Exhaustion recorded
  assert.strictEqual(metrics.retryExhaustedTotal.get(), 1)

  console.log('✓ withRetry_recordsExhaustionMetric')
}

async function test_withRetry_noMetricsOnSuccess() {
  const { withRetry } = _testExports

  // Reset metrics for this test
  resetMetrics()

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 100,
    max_backoff_ms: 1600,
    total_timeout_ms: 30000,
    jitter: false,
  }

  const result = await withRetry(async () => {
    return 'immediate success'
  }, config)

  assert.strictEqual(result, 'immediate success')

  const metrics = getMetrics()
  assert.strictEqual(metrics.retriesTotal.get(), 0)
  assert.strictEqual(metrics.retryExhaustedTotal.get(), 0)

  console.log('✓ withRetry_noMetricsOnSuccess')
}

async function test_withRetry_noMetricsOnNonRetryableError() {
  const { withRetry } = _testExports

  // Reset metrics for this test
  resetMetrics()

  const config = {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 100,
    max_backoff_ms: 1600,
    total_timeout_ms: 30000,
    jitter: false,
  }

  let threw = false
  try {
    await withRetry(async () => {
      throw new InvalidCoordinates('bad coordinates')
    }, config)
  } catch (e) {
    threw = true
    assert(e instanceof InvalidCoordinates)
  }

  assert(threw, 'Should throw InvalidCoordinates')

  const metrics = getMetrics()
  // Non-retryable errors don't trigger retry metrics
  assert.strictEqual(metrics.retriesTotal.get(), 0)
  assert.strictEqual(metrics.retryExhaustedTotal.get(), 0)

  console.log('✓ withRetry_noMetricsOnNonRetryableError')
}

function test_HealthTracker_initialState() {
  const tracker = new HealthTracker()
  const status = tracker.getStatus()

  assert.strictEqual(status.healthy, false)
  assert.strictEqual(status.state, ConnectionState.DISCONNECTED)

  console.log('✓ HealthTracker_initialState')
}

function test_HealthTracker_successTransitions() {
  const tracker = new HealthTracker()

  tracker.recordSuccess()
  const status = tracker.getStatus()

  assert.strictEqual(status.healthy, true)
  assert.strictEqual(status.state, ConnectionState.CONNECTED)
  assert(status.lastSuccessfulOpNs > 0)

  console.log('✓ HealthTracker_successTransitions')
}

function test_HealthTracker_failureThreshold() {
  const tracker = new HealthTracker(3)

  // Start connected
  tracker.recordSuccess()
  assert.strictEqual(tracker.getStatus().healthy, true)

  // First two failures: still healthy (below threshold)
  tracker.recordFailure()
  assert.strictEqual(tracker.getStatus().healthy, true)
  tracker.recordFailure()
  assert.strictEqual(tracker.getStatus().healthy, true)

  // Third failure: crosses threshold
  tracker.recordFailure()
  assert.strictEqual(tracker.getStatus().healthy, false)
  assert.strictEqual(tracker.getStatus().state, ConnectionState.FAILED)

  console.log('✓ HealthTracker_failureThreshold')
}

function test_HealthTracker_recovery() {
  const tracker = new HealthTracker(2)

  // Mark as failed
  tracker.recordFailure()
  tracker.recordFailure()
  assert.strictEqual(tracker.getStatus().state, ConnectionState.FAILED)

  // Recovery via success
  tracker.recordSuccess()
  assert.strictEqual(tracker.getStatus().healthy, true)
  assert.strictEqual(tracker.getStatus().state, ConnectionState.CONNECTED)
  assert.strictEqual(tracker.getStatus().consecutiveFailures, 0)

  console.log('✓ HealthTracker_recovery')
}

function test_HealthTracker_toJSON() {
  const tracker = new HealthTracker()
  tracker.recordSuccess()

  const json = tracker.toJSON()
  assert.strictEqual(json.healthy, true)
  assert.strictEqual(json.state, ConnectionState.CONNECTED)
  assert(typeof json.last_successful_operation_ns === 'number')
  assert.strictEqual(json.consecutive_failures, 0)

  console.log('✓ HealthTracker_toJSON')
}

function test_RequestTimer_success() {
  resetMetrics()
  const metrics = getMetrics()
  const timer = new RequestTimer('test_op', metrics)

  timer.success()

  const labels: MetricLabels = { operation: 'test_op', status: 'success' }
  assert.strictEqual(metrics.requestsTotal.get(labels), 1)

  console.log('✓ RequestTimer_success')
}

function test_RequestTimer_error() {
  resetMetrics()
  const metrics = getMetrics()
  const timer = new RequestTimer('test_op', metrics)

  timer.error()

  const labels: MetricLabels = { operation: 'test_op', status: 'error' }
  assert.strictEqual(metrics.requestsTotal.get(labels), 1)

  console.log('✓ RequestTimer_error')
}

// ============================================================================
// Circuit Breaker Tests (per client-retry/spec.md)
// ============================================================================

function test_CircuitBreaker_initialState() {
  const breaker = new CircuitBreaker('test-replica')

  assert.strictEqual(breaker.getState(), CircuitState.CLOSED)
  assert.strictEqual(breaker.isClosed, true)
  assert.strictEqual(breaker.isOpen, false)
  assert.strictEqual(breaker.isHalfOpen, false)

  console.log('✓ CircuitBreaker_initialState')
}

function test_CircuitBreaker_allowsRequestsWhenClosed() {
  const breaker = new CircuitBreaker('test-replica')

  for (let i = 0; i < 100; i++) {
    assert.strictEqual(breaker.allowRequest(), true)
  }

  console.log('✓ CircuitBreaker_allowsRequestsWhenClosed')
}

function test_CircuitBreaker_staysClosedUnderThreshold() {
  const breaker = new CircuitBreaker('test-replica', {
    failureThreshold: 0.5,
    minimumRequests: 10,
  })

  // 9 requests with 4 failures (44%) - under threshold
  for (let i = 0; i < 5; i++) {
    breaker.allowRequest()
    breaker.recordSuccess()
  }
  for (let i = 0; i < 4; i++) {
    breaker.allowRequest()
    breaker.recordFailure()
  }

  assert.strictEqual(breaker.isClosed, true)
  assert(Math.abs(breaker.failureRate - 4 / 9) < 0.01)

  console.log('✓ CircuitBreaker_staysClosedUnderThreshold')
}

function test_CircuitBreaker_opensAfterThresholdExceeded() {
  const breaker = new CircuitBreaker('test-replica', {
    failureThreshold: 0.5,
    minimumRequests: 10,
  })

  // 10 requests with 6 failures (60%) - exceeds threshold
  for (let i = 0; i < 4; i++) {
    breaker.allowRequest()
    breaker.recordSuccess()
  }
  for (let i = 0; i < 6; i++) {
    breaker.allowRequest()
    breaker.recordFailure()
  }

  assert.strictEqual(breaker.isOpen, true)

  console.log('✓ CircuitBreaker_opensAfterThresholdExceeded')
}

function test_CircuitBreaker_rejectsRequestsWhenOpen() {
  const breaker = new CircuitBreaker('test-replica')
  breaker.forceOpen()

  assert.strictEqual(breaker.allowRequest(), false)
  assert.strictEqual(breaker.allowRequest(), false)
  assert.strictEqual(breaker.allowRequest(), false)
  assert(breaker.rejectedRequests >= 3)

  console.log('✓ CircuitBreaker_rejectsRequestsWhenOpen')
}

async function test_CircuitBreaker_transitionsToHalfOpen() {
  const breaker = new CircuitBreaker('test-replica', {
    openDurationMs: 50, // Short for testing
  })
  breaker.forceOpen()

  // Wait for open duration
  await new Promise((resolve) => setTimeout(resolve, 100))

  // Should transition on next state check
  assert.strictEqual(breaker.getState(), CircuitState.HALF_OPEN)
  assert.strictEqual(breaker.isHalfOpen, true)

  console.log('✓ CircuitBreaker_transitionsToHalfOpen')
}

async function test_CircuitBreaker_successfulHalfOpenCloses() {
  const breaker = new CircuitBreaker('test-replica', {
    openDurationMs: 50,
    halfOpenRequests: 5,
  })
  breaker.forceOpen()

  await new Promise((resolve) => setTimeout(resolve, 100))

  // 5 successful requests in half-open
  for (let i = 0; i < 5; i++) {
    assert.strictEqual(breaker.allowRequest(), true)
    breaker.recordSuccess()
  }

  assert.strictEqual(breaker.isClosed, true)

  console.log('✓ CircuitBreaker_successfulHalfOpenCloses')
}

async function test_CircuitBreaker_failedHalfOpenReopens() {
  const breaker = new CircuitBreaker('test-replica', {
    openDurationMs: 50,
  })
  breaker.forceOpen()

  await new Promise((resolve) => setTimeout(resolve, 100))

  // First half-open request fails
  assert.strictEqual(breaker.allowRequest(), true)
  breaker.recordFailure()

  assert.strictEqual(breaker.isOpen, true)

  console.log('✓ CircuitBreaker_failedHalfOpenReopens')
}

async function test_CircuitBreaker_halfOpenLimitsRequests() {
  const breaker = new CircuitBreaker('test-replica', {
    openDurationMs: 50,
    halfOpenRequests: 5,
  })
  breaker.forceOpen()

  await new Promise((resolve) => setTimeout(resolve, 100))

  // Allow exactly 5 requests
  for (let i = 0; i < 5; i++) {
    assert.strictEqual(breaker.allowRequest(), true)
  }

  // 6th request rejected
  assert.strictEqual(breaker.allowRequest(), false)

  console.log('✓ CircuitBreaker_halfOpenLimitsRequests')
}

function test_CircuitBreaker_minimumRequestsRequired() {
  const breaker = new CircuitBreaker('test-replica', {
    minimumRequests: 10,
  })

  // 9 failures (100%) - under minimum
  for (let i = 0; i < 9; i++) {
    breaker.allowRequest()
    breaker.recordFailure()
  }

  assert.strictEqual(breaker.isClosed, true)

  // 10th failure opens circuit
  breaker.allowRequest()
  breaker.recordFailure()

  assert.strictEqual(breaker.isOpen, true)

  console.log('✓ CircuitBreaker_minimumRequestsRequired')
}

function test_CircuitBreaker_forceCloseResetsState() {
  const breaker = new CircuitBreaker('test-replica')
  breaker.forceOpen()
  assert.strictEqual(breaker.isOpen, true)

  breaker.forceClose()
  assert.strictEqual(breaker.isClosed, true)
  assert(Math.abs(breaker.failureRate - 0) < 0.01)

  console.log('✓ CircuitBreaker_forceCloseResetsState')
}

function test_CircuitBreaker_stateChangesTracked() {
  const breaker = new CircuitBreaker('test-replica')
  assert.strictEqual(breaker.stateChanges, 0)

  breaker.forceOpen()
  assert.strictEqual(breaker.stateChanges, 1)

  breaker.forceClose()
  assert.strictEqual(breaker.stateChanges, 2)

  console.log('✓ CircuitBreaker_stateChangesTracked')
}

function test_CircuitBreaker_perReplicaScope() {
  const breaker1 = new CircuitBreaker('replica-1')
  const breaker2 = new CircuitBreaker('replica-2')

  breaker1.forceOpen()

  // breaker2 should still be closed
  assert.strictEqual(breaker1.isOpen, true)
  assert.strictEqual(breaker2.isClosed, true)
  assert.strictEqual(breaker2.allowRequest(), true)

  console.log('✓ CircuitBreaker_perReplicaScope')
}

function test_CircuitBreakerOpen_exception() {
  const ex = new CircuitBreakerOpen('test-circuit', CircuitState.OPEN)

  assert.strictEqual(ex.circuitName, 'test-circuit')
  assert.strictEqual(ex.circuitState, CircuitState.OPEN)
  assert.strictEqual(ex.code, 600)
  assert.strictEqual(ex.retryable, true)
  assert(ex.message.includes('test-circuit'))

  console.log('✓ CircuitBreakerOpen_exception')
}

function test_CircuitBreaker_defaultConfigMatchesSpec() {
  const breaker = new CircuitBreaker('test')

  // Access config through behavior - if 10 failures at 100% opens circuit,
  // it means minimumRequests is 10
  for (let i = 0; i < 9; i++) {
    breaker.allowRequest()
    breaker.recordFailure()
  }
  assert.strictEqual(breaker.isClosed, true) // Under 10 minimum

  breaker.allowRequest()
  breaker.recordFailure()
  assert.strictEqual(breaker.isOpen, true) // 10th request, 100% failure >= 50%

  console.log('✓ CircuitBreaker_defaultConfigMatchesSpec')
}

// ============================================================================
// Polygon Self-Intersection Validation Tests (add-polygon-validation spec)
// ============================================================================

function test_validTriangle() {
  const triangle: [number, number][] = [[0, 0], [1, 0], [0.5, 1]]
  const result = validatePolygonNoSelfIntersection(triangle, false)
  assert.strictEqual(result.length, 0)
  console.log('✓ validTriangle')
}

function test_validSquare() {
  const square: [number, number][] = [[0, 0], [1, 0], [1, 1], [0, 1]]
  const result = validatePolygonNoSelfIntersection(square, false)
  assert.strictEqual(result.length, 0)
  console.log('✓ validSquare')
}

function test_validConvexPentagon() {
  const pentagon: [number, number][] = []
  for (let i = 0; i < 5; i++) {
    const angle = (2 * Math.PI * i) / 5
    pentagon.push([Math.cos(angle), Math.sin(angle)])
  }
  const result = validatePolygonNoSelfIntersection(pentagon, false)
  assert.strictEqual(result.length, 0)
  console.log('✓ validConvexPentagon')
}

function test_bowtiePolygonIntersects() {
  const bowtie: [number, number][] = [[0, 0], [1, 1], [1, 0], [0, 1]]
  const result = validatePolygonNoSelfIntersection(bowtie, false)
  assert(result.length > 0, 'Bow-tie should have intersections')
  console.log('✓ bowtiePolygonIntersects')
}

function test_bowtieRaisesException() {
  const bowtie: [number, number][] = [[0, 0], [1, 1], [1, 0], [0, 1]]
  try {
    validatePolygonNoSelfIntersection(bowtie, true)
    assert.fail('Should have thrown PolygonValidationError')
  } catch (err) {
    assert(err instanceof PolygonValidationError, 'Should be PolygonValidationError')
    const e = err as PolygonValidationError
    assert(e.segment1_index >= 0 && e.segment1_index < 4)
    assert(e.segment2_index >= 0 && e.segment2_index < 4)
    assert(e.message.includes('self-intersects'))
  }
  console.log('✓ bowtieRaisesException')
}

function test_validConcavePolygon() {
  // L-shaped polygon (concave but valid)
  const lShape: [number, number][] = [
    [0, 0], [2, 0], [2, 1],
    [1, 1], [1, 2], [0, 2],
  ]
  const result = validatePolygonNoSelfIntersection(lShape, false)
  assert.strictEqual(result.length, 0)
  console.log('✓ validConcavePolygon')
}

function test_starPolygonIntersects() {
  // 5-pointed star (drawn without lifting pen) self-intersects
  const star: [number, number][] = []
  for (let i = 0; i < 5; i++) {
    const angle = Math.PI / 2 + (i * 4 * Math.PI) / 5
    star.push([Math.cos(angle), Math.sin(angle)])
  }
  const result = validatePolygonNoSelfIntersection(star, false)
  assert(result.length > 0, '5-pointed star should have intersections')
  console.log('✓ starPolygonIntersects')
}

function test_segmentsIntersectBasic() {
  // Clearly crossing segments
  assert(segmentsIntersect(
    [0, 0], [1, 1],  // Diagonal
    [0, 1], [1, 0],  // Opposite diagonal
  ))

  // Parallel segments (no intersection)
  assert(!segmentsIntersect(
    [0, 0], [1, 0],  // Horizontal
    [0, 1], [1, 1],  // Parallel horizontal
  ))

  // T-junction (endpoint touches)
  assert(segmentsIntersect(
    [0, 0.5], [1, 0.5],  // Horizontal
    [0.5, 0], [0.5, 0.5],  // Vertical ending at intersection
  ))

  console.log('✓ segmentsIntersectBasic')
}

function test_polygonValidationErrorAttributes() {
  const err = new PolygonValidationError(
    'Test error',
    1,
    3,
    [0.5, 0.5],
  )

  assert.strictEqual(err.segment1_index, 1)
  assert.strictEqual(err.segment2_index, 3)
  assert.deepStrictEqual(err.intersection_point, [0.5, 0.5])
  assert(err.message.includes('Test error'))
  assert.strictEqual(err.name, 'PolygonValidationError')
  console.log('✓ polygonValidationErrorAttributes')
}

function test_emptyOrSmallPolygon() {
  // Empty
  const empty: [number, number][] = []
  assert.strictEqual(validatePolygonNoSelfIntersection(empty, false).length, 0)

  // Single point
  const single: [number, number][] = [[0, 0]]
  assert.strictEqual(validatePolygonNoSelfIntersection(single, false).length, 0)

  // Two points (line)
  const line: [number, number][] = [[0, 0], [1, 1]]
  assert.strictEqual(validatePolygonNoSelfIntersection(line, false).length, 0)

  // Three points (triangle - minimum valid polygon)
  const triangle: [number, number][] = [[0, 0], [1, 0], [0, 1]]
  assert.strictEqual(validatePolygonNoSelfIntersection(triangle, false).length, 0)

  console.log('✓ emptyOrSmallPolygon')
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
  test_prepareGeoEvent()
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

  // =========================================
  // TTL Cleanup Tests (per client-protocol/spec.md)
  // =========================================
  console.log('\n--- TTL Cleanup Tests ---\n')

  test_CleanupResult_type()
  test_CleanupResult_helpers()
  test_CleanupResult_wireFormatSize()
  await test_GeoClient_cleanupExpired()
  await test_GeoClient_cleanupExpired_negativeBatch()

  // Split batch helper tests
  test_splitBatch_basic()
  test_splitBatch_exactDivision()
  test_splitBatch_emptyArray()
  test_splitBatch_singleChunk()
  test_splitBatch_chunkSizeOne()
  test_splitBatch_zeroChunkSize_throws()
  test_splitBatch_negativeChunkSize_throws()
  test_splitBatch_defaultChunkSize()
  await test_submitMultiBatch_retriesFailedBatchOnly()
  await test_submitMultiBatch_offsetsIndices()

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
  await test_insertEvents_multiBatch_integration()
  await test_insert_query_delete_integration()

  // RetryExhausted error tests
  test_RetryExhausted_properties()

  // =========================================
  // Circuit Breaker Tests (per client-retry/spec.md)
  // =========================================
  console.log('\n--- Circuit Breaker Tests ---\n')

  test_CircuitBreaker_initialState()
  test_CircuitBreaker_allowsRequestsWhenClosed()
  test_CircuitBreaker_staysClosedUnderThreshold()
  test_CircuitBreaker_opensAfterThresholdExceeded()
  test_CircuitBreaker_rejectsRequestsWhenOpen()
  await test_CircuitBreaker_transitionsToHalfOpen()
  await test_CircuitBreaker_successfulHalfOpenCloses()
  await test_CircuitBreaker_failedHalfOpenReopens()
  await test_CircuitBreaker_halfOpenLimitsRequests()
  test_CircuitBreaker_minimumRequestsRequired()
  test_CircuitBreaker_forceCloseResetsState()
  test_CircuitBreaker_stateChangesTracked()
  test_CircuitBreaker_perReplicaScope()
  test_CircuitBreakerOpen_exception()
  test_CircuitBreaker_defaultConfigMatchesSpec()

  // =========================================
  // Observability Tests (per client-sdk/spec.md)
  // =========================================
  console.log('\n--- Observability Tests ---\n')

  // Logging tests
  test_NullLogger()
  test_ConsoleLogger()
  test_configureLogging()

  // Metrics tests
  test_Counter_inc()
  test_Counter_labels()
  test_Gauge_operations()
  test_Histogram_observe()
  test_SDKMetrics_recordRequest()
  test_SDKMetrics_prometheusExport()
  test_getMetrics_singleton()
  test_retryMetrics()
  test_retryMetrics_prometheusExport()

  // Retry metrics integration tests (async)
  await test_withRetry_recordsMetricsOnRetry()
  await test_withRetry_recordsExhaustionMetric()
  await test_withRetry_noMetricsOnSuccess()
  await test_withRetry_noMetricsOnNonRetryableError()

  // Health check tests
  test_HealthTracker_initialState()
  test_HealthTracker_successTransitions()
  test_HealthTracker_failureThreshold()
  test_HealthTracker_recovery()
  test_HealthTracker_toJSON()

  // Request timer tests
  test_RequestTimer_success()
  test_RequestTimer_error()

  // =========================================
  // Polygon Validation Tests (per add-polygon-validation spec)
  // =========================================
  console.log('\n--- Polygon Validation Tests ---\n')

  test_validTriangle()
  test_validSquare()
  test_validConvexPentagon()
  test_bowtiePolygonIntersects()
  test_bowtieRaisesException()
  test_validConcavePolygon()
  test_starPolygonIntersects()
  test_segmentsIntersectBasic()
  test_polygonValidationErrorAttributes()
  test_emptyOrSmallPolygon()

  // Jump Hash Golden Vector Tests (source of truth: src/sharding.zig)
  console.log('\n--- JumpHash Golden Vector Tests ---\n')

  test_jumpHash_key0()
  test_jumpHash_keyDeadbeef()
  test_jumpHash_keyCafebabe()
  test_jumpHash_keyMaxU64()
  test_jumpHash_additionalKeys()
  test_jumpHash_determinism()
  test_computeShardKey_goldenVectors()
  test_computeShardKey_determinism()
  test_getShardForEntity_determinism()

  console.log('\n=== All tests passed! ===\n')
}

// ============================================================================
// Jump Hash Golden Vector Tests
// Source of truth: src/sharding.zig - these values MUST match exactly.
// ============================================================================

function test_jumpHash_key0(): void {
  console.log('Testing jumpHash key 0...')
  assert.strictEqual(jumpHash(0n, 1), 0)
  assert.strictEqual(jumpHash(0n, 10), 0)
  assert.strictEqual(jumpHash(0n, 100), 0)
  assert.strictEqual(jumpHash(0n, 256), 0)
  console.log('  PASS: key 0 always maps to bucket 0')
}

function test_jumpHash_keyDeadbeef(): void {
  console.log('Testing jumpHash key 0xDEADBEEF...')
  assert.strictEqual(jumpHash(0xDEADBEEFn, 8), 5)
  assert.strictEqual(jumpHash(0xDEADBEEFn, 16), 5)
  assert.strictEqual(jumpHash(0xDEADBEEFn, 32), 16)
  assert.strictEqual(jumpHash(0xDEADBEEFn, 64), 16)
  assert.strictEqual(jumpHash(0xDEADBEEFn, 128), 87)
  assert.strictEqual(jumpHash(0xDEADBEEFn, 256), 87)
  console.log('  PASS: 0xDEADBEEF golden vectors match')
}

function test_jumpHash_keyCafebabe(): void {
  console.log('Testing jumpHash key 0xCAFEBABE...')
  assert.strictEqual(jumpHash(0xCAFEBABEn, 8), 5)
  assert.strictEqual(jumpHash(0xCAFEBABEn, 16), 5)
  assert.strictEqual(jumpHash(0xCAFEBABEn, 32), 5)
  assert.strictEqual(jumpHash(0xCAFEBABEn, 64), 46)
  assert.strictEqual(jumpHash(0xCAFEBABEn, 128), 85)
  assert.strictEqual(jumpHash(0xCAFEBABEn, 256), 85)
  console.log('  PASS: 0xCAFEBABE golden vectors match')
}

function test_jumpHash_keyMaxU64(): void {
  console.log('Testing jumpHash key max u64...')
  assert.strictEqual(jumpHash(0xFFFFFFFFFFFFFFFFn, 8), 7)
  assert.strictEqual(jumpHash(0xFFFFFFFFFFFFFFFFn, 16), 10)
  assert.strictEqual(jumpHash(0xFFFFFFFFFFFFFFFFn, 256), 248)
  console.log('  PASS: max u64 golden vectors match')
}

function test_jumpHash_additionalKeys(): void {
  console.log('Testing jumpHash additional keys...')
  assert.strictEqual(jumpHash(0x123456789ABCDEF0n, 8), 4)
  assert.strictEqual(jumpHash(0x123456789ABCDEF0n, 16), 4)
  assert.strictEqual(jumpHash(0x123456789ABCDEF0n, 256), 33)

  assert.strictEqual(jumpHash(0xFEDCBA9876543210n, 8), 1)
  assert.strictEqual(jumpHash(0xFEDCBA9876543210n, 16), 10)
  assert.strictEqual(jumpHash(0xFEDCBA9876543210n, 256), 143)
  console.log('  PASS: additional key golden vectors match')
}

function test_jumpHash_determinism(): void {
  console.log('Testing jumpHash determinism (1000 iterations)...')
  const testCases: Array<[bigint, number, number]> = [
    [0xDEADBEEFn, 16, 5],
    [0xCAFEBABEn, 64, 46],
    [0x123456789ABCDEF0n, 256, 33],
    [0xFFFFFFFFFFFFFFFFn, 8, 7],
  ]

  for (const [key, buckets, expected] of testCases) {
    for (let i = 0; i < 1000; i++) {
      const result = jumpHash(key, buckets)
      assert.strictEqual(result, expected,
        `Iteration ${i}: jumpHash(${key}, ${buckets}) = ${result}, want ${expected}`)
    }
  }
  console.log('  PASS: determinism verified over 1000 iterations')
}

function test_computeShardKey_goldenVectors(): void {
  console.log('Testing computeShardKey golden vectors...')

  // Entity ID 1
  assert.strictEqual(
    computeShardKey(0x00000000_00000000_00000000_00000001n),
    0xB456BCFC34C2CB2Cn
  )

  // Entity ID DEADBEEF/CAFEBABE pattern
  assert.strictEqual(
    computeShardKey(0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0n),
    0x683A5932FE04E714n
  )

  // Max entity ID
  assert.strictEqual(
    computeShardKey(0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFFn),
    0x0000000000000000n
  )

  // Symmetric entity ID
  assert.strictEqual(
    computeShardKey(0x12345678_ABCDEF00_12345678_ABCDEF00n),
    0x0000000000000000n
  )

  console.log('  PASS: computeShardKey golden vectors match')
}

function test_computeShardKey_determinism(): void {
  console.log('Testing computeShardKey determinism (1000 iterations)...')
  const testCases: Array<[bigint, bigint]> = [
    [0x00000000_00000000_00000000_00000001n, 0xB456BCFC34C2CB2Cn],
    [0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0n, 0x683A5932FE04E714n],
  ]

  for (const [entityId, expected] of testCases) {
    for (let i = 0; i < 1000; i++) {
      const result = computeShardKey(entityId)
      assert.strictEqual(result, expected,
        `Iteration ${i}: computeShardKey(${entityId}) = ${result}, want ${expected}`)
    }
  }
  console.log('  PASS: determinism verified over 1000 iterations')
}

function test_getShardForEntity_determinism(): void {
  console.log('Testing getShardForEntity determinism...')
  const entityId = 0xDEADBEEF_00000000_CAFEBABE_00000000n

  const shard1 = getShardForEntity(entityId, 16)
  const shard2 = getShardForEntity(entityId, 16)
  const shard3 = getShardForEntity(entityId, 16)

  assert.strictEqual(shard1, shard2)
  assert.strictEqual(shard2, shard3)
  assert.ok(shard1 < 16, `Shard ${shard1} should be < 16`)
  console.log('  PASS: getShardForEntity is deterministic')
}

// Run tests when module is executed directly
runTests()
