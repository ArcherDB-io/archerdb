/**
 * ArcherDB Node.js SDK - Wire Format Compatibility Tests
 *
 * These tests verify that the Node.js SDK produces wire-compatible
 * output with other language SDKs by testing against canonical test cases.
 */

import assert from 'assert'
import * as fs from 'fs'
import * as path from 'path'

import {
  // Constants
  LAT_MAX,
  LON_MAX,
  NANODEGREES_PER_DEGREE,
  MM_PER_METER,
  CENTIDEGREES_PER_DEGREE,
  BATCH_SIZE_MAX,
  QUERY_LIMIT_MAX,
  POLYGON_VERTICES_MAX,
  // Enums
  GeoEventFlags,
  GeoOperation,
  InsertGeoEventError,
  DeleteEntityError,
  // Conversion helpers
  degreesToNano,
  nanoToDegrees,
  metersToMm,
  mmToMeters,
  headingToCentidegrees,
  centidegreesToHeading,
  isValidLatitude,
  isValidLongitude,
  // Builder functions
  createGeoEvent,
  createRadiusQuery,
  createPolygonQuery,
} from './geo'

// Test data types
interface TestData {
  constants: {
    LAT_MAX: number
    LON_MAX: number
    NANODEGREES_PER_DEGREE: number
    MM_PER_METER: number
    CENTIDEGREES_PER_DEGREE: number
    BATCH_SIZE_MAX: number
    QUERY_LIMIT_MAX: number
    POLYGON_VERTICES_MAX: number
  }
  operation_codes: Record<string, number>
  geo_event_flags: Record<string, number>
  insert_result_codes: Record<string, number>
  delete_result_codes: Record<string, number>
  coordinate_conversions: Array<{
    description: string
    degrees: number
    expected_nanodegrees: number
  }>
  distance_conversions: Array<{
    description: string
    meters: number
    expected_mm: number
  }>
  heading_conversions: Array<{
    description: string
    degrees: number
    expected_centidegrees: number
  }>
  geo_events: Array<{
    description: string
    input: {
      entity_id: number
      latitude: number
      longitude: number
      correlation_id?: number
      user_data?: number
      group_id?: number
      altitude_m?: number
      velocity_mps?: number
      ttl_seconds?: number
      accuracy_m?: number
      heading?: number
      flags?: number
    }
    expected: {
      entity_id: number
      lat_nano: number
      lon_nano: number
      id: number
      timestamp: number
      correlation_id: number
      user_data: number
      group_id: number
      altitude_mm: number
      velocity_mms: number
      ttl_seconds: number
      accuracy_mm: number
      heading_cdeg: number
      flags: number
    }
  }>
  radius_queries: Array<{
    description: string
    input: {
      latitude: number
      longitude: number
      radius_m: number
      limit?: number
      timestamp_min?: number
      timestamp_max?: number
      group_id?: number
    }
    expected: {
      center_lat_nano: number
      center_lon_nano: number
      radius_mm: number
      limit: number
      timestamp_min: number
      timestamp_max: number
      group_id: number
    }
  }>
  polygon_queries: Array<{
    description: string
    input: {
      vertices: [number, number][]
      limit?: number
      timestamp_min?: number
      timestamp_max?: number
      group_id?: number
    }
    expected: {
      vertices: Array<{ lat_nano: number; lon_nano: number }>
      limit: number
      timestamp_min: number
      timestamp_max: number
      group_id: number
    }
  }>
  validation_cases: {
    invalid_latitudes: number[]
    invalid_longitudes: number[]
    valid_boundary_latitudes: number[]
    valid_boundary_longitudes: number[]
  }
}

// Load test data
function loadTestData(): TestData {
  const testDataPath = path.join(__dirname, '../../test-data/wire-format-test-cases.json')
  const data = fs.readFileSync(testDataPath, 'utf-8')
  return JSON.parse(data) as TestData
}

let testData: TestData
let passed = 0
let failed = 0

function test(name: string, fn: () => void): void {
  try {
    fn()
    console.log(`  ✓ ${name}`)
    passed++
  } catch (e) {
    console.log(`  ✗ ${name}`)
    console.log(`    Error: ${e instanceof Error ? e.message : e}`)
    failed++
  }
}

function assertEqual<T>(actual: T, expected: T, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`)
  }
}

function assertBigIntEqual(actual: bigint, expected: number | bigint, message: string): void {
  const expectedBigInt = typeof expected === 'bigint' ? expected : BigInt(expected)
  if (actual !== expectedBigInt) {
    throw new Error(`${message}: expected ${expectedBigInt}, got ${actual}`)
  }
}

// Test suites
function testConstants(): void {
  console.log('\nWire Format Constants:')

  test('LAT_MAX matches canonical value', () => {
    assertEqual(LAT_MAX, testData.constants.LAT_MAX, 'LAT_MAX')
  })

  test('LON_MAX matches canonical value', () => {
    assertEqual(LON_MAX, testData.constants.LON_MAX, 'LON_MAX')
  })

  test('NANODEGREES_PER_DEGREE matches canonical value', () => {
    assertBigIntEqual(NANODEGREES_PER_DEGREE, testData.constants.NANODEGREES_PER_DEGREE, 'NANODEGREES_PER_DEGREE')
  })

  test('MM_PER_METER matches canonical value', () => {
    assertEqual(MM_PER_METER, testData.constants.MM_PER_METER, 'MM_PER_METER')
  })

  test('CENTIDEGREES_PER_DEGREE matches canonical value', () => {
    assertEqual(CENTIDEGREES_PER_DEGREE, testData.constants.CENTIDEGREES_PER_DEGREE, 'CENTIDEGREES_PER_DEGREE')
  })

  test('BATCH_SIZE_MAX matches canonical value', () => {
    assertEqual(BATCH_SIZE_MAX, testData.constants.BATCH_SIZE_MAX, 'BATCH_SIZE_MAX')
  })

  test('QUERY_LIMIT_MAX matches canonical value', () => {
    assertEqual(QUERY_LIMIT_MAX, testData.constants.QUERY_LIMIT_MAX, 'QUERY_LIMIT_MAX')
  })

  test('POLYGON_VERTICES_MAX matches canonical value', () => {
    assertEqual(POLYGON_VERTICES_MAX, testData.constants.POLYGON_VERTICES_MAX, 'POLYGON_VERTICES_MAX')
  })
}

function testOperationCodes(): void {
  console.log('\nWire Format Operation Codes:')

  test('INSERT_EVENTS matches canonical value', () => {
    assertEqual(GeoOperation.insert_events, testData.operation_codes.INSERT_EVENTS, 'INSERT_EVENTS')
  })

  test('UPSERT_EVENTS matches canonical value', () => {
    assertEqual(GeoOperation.upsert_events, testData.operation_codes.UPSERT_EVENTS, 'UPSERT_EVENTS')
  })

  test('DELETE_ENTITIES matches canonical value', () => {
    assertEqual(GeoOperation.delete_entities, testData.operation_codes.DELETE_ENTITIES, 'DELETE_ENTITIES')
  })

  test('QUERY_UUID matches canonical value', () => {
    assertEqual(GeoOperation.query_uuid, testData.operation_codes.QUERY_UUID, 'QUERY_UUID')
  })

  test('QUERY_RADIUS matches canonical value', () => {
    assertEqual(GeoOperation.query_radius, testData.operation_codes.QUERY_RADIUS, 'QUERY_RADIUS')
  })

  test('QUERY_POLYGON matches canonical value', () => {
    assertEqual(GeoOperation.query_polygon, testData.operation_codes.QUERY_POLYGON, 'QUERY_POLYGON')
  })

  test('QUERY_LATEST matches canonical value', () => {
    assertEqual(GeoOperation.query_latest, testData.operation_codes.QUERY_LATEST, 'QUERY_LATEST')
  })
}

function testGeoEventFlags(): void {
  console.log('\nWire Format GeoEvent Flags:')

  test('NONE matches canonical value', () => {
    assertEqual(GeoEventFlags.none, testData.geo_event_flags.NONE, 'NONE')
  })

  test('LINKED matches canonical value', () => {
    assertEqual(GeoEventFlags.linked, testData.geo_event_flags.LINKED, 'LINKED')
  })

  test('IMPORTED matches canonical value', () => {
    assertEqual(GeoEventFlags.imported, testData.geo_event_flags.IMPORTED, 'IMPORTED')
  })

  test('STATIONARY matches canonical value', () => {
    assertEqual(GeoEventFlags.stationary, testData.geo_event_flags.STATIONARY, 'STATIONARY')
  })

  test('LOW_ACCURACY matches canonical value', () => {
    assertEqual(GeoEventFlags.low_accuracy, testData.geo_event_flags.LOW_ACCURACY, 'LOW_ACCURACY')
  })

  test('OFFLINE matches canonical value', () => {
    assertEqual(GeoEventFlags.offline, testData.geo_event_flags.OFFLINE, 'OFFLINE')
  })

  test('DELETED matches canonical value', () => {
    assertEqual(GeoEventFlags.deleted, testData.geo_event_flags.DELETED, 'DELETED')
  })
}

function testResultCodes(): void {
  console.log('\nWire Format Result Codes:')

  // Insert result codes
  test('Insert OK matches canonical value', () => {
    assertEqual(InsertGeoEventError.ok, testData.insert_result_codes.OK, 'OK')
  })

  test('Insert LINKED_EVENT_FAILED matches canonical value', () => {
    assertEqual(InsertGeoEventError.linked_event_failed, testData.insert_result_codes.LINKED_EVENT_FAILED, 'LINKED_EVENT_FAILED')
  })

  test('Insert INVALID_COORDINATES matches canonical value', () => {
    assertEqual(InsertGeoEventError.invalid_coordinates, testData.insert_result_codes.INVALID_COORDINATES, 'INVALID_COORDINATES')
  })

  test('Insert EXISTS matches canonical value', () => {
    assertEqual(InsertGeoEventError.exists, testData.insert_result_codes.EXISTS, 'EXISTS')
  })

  // Delete result codes
  test('Delete OK matches canonical value', () => {
    assertEqual(DeleteEntityError.ok, testData.delete_result_codes.OK, 'OK')
  })

  test('Delete ENTITY_NOT_FOUND matches canonical value', () => {
    assertEqual(DeleteEntityError.entity_not_found, testData.delete_result_codes.ENTITY_NOT_FOUND, 'ENTITY_NOT_FOUND')
  })
}

function testCoordinateConversions(): void {
  console.log('\nWire Format Coordinate Conversions:')

  for (const testCase of testData.coordinate_conversions) {
    test(`degreesToNano: ${testCase.description}`, () => {
      const result = degreesToNano(testCase.degrees)
      assertBigIntEqual(result, testCase.expected_nanodegrees, testCase.description)
    })
  }

  // Roundtrip test
  test('nanoToDegrees roundtrip maintains precision', () => {
    for (const testCase of testData.coordinate_conversions) {
      const nano = BigInt(testCase.expected_nanodegrees)
      const degrees = nanoToDegrees(nano)
      const backToNano = degreesToNano(degrees)
      assertBigIntEqual(backToNano, testCase.expected_nanodegrees, `Roundtrip: ${testCase.description}`)
    }
  })
}

function testDistanceConversions(): void {
  console.log('\nWire Format Distance Conversions:')

  for (const testCase of testData.distance_conversions) {
    test(`metersToMm: ${testCase.description}`, () => {
      const result = metersToMm(testCase.meters)
      assertEqual(result, testCase.expected_mm, testCase.description)
    })
  }
}

function testHeadingConversions(): void {
  console.log('\nWire Format Heading Conversions:')

  for (const testCase of testData.heading_conversions) {
    test(`headingToCentidegrees: ${testCase.description}`, () => {
      const result = headingToCentidegrees(testCase.degrees)
      assertEqual(result, testCase.expected_centidegrees, testCase.description)
    })
  }
}

function testGeoEvents(): void {
  console.log('\nWire Format GeoEvent Creation:')

  for (const testCase of testData.geo_events) {
    test(`createGeoEvent: ${testCase.description}`, () => {
      const input = testCase.input
      const expected = testCase.expected

      const event = createGeoEvent({
        entity_id: BigInt(input.entity_id),
        latitude: input.latitude,
        longitude: input.longitude,
        correlation_id: input.correlation_id !== undefined ? BigInt(input.correlation_id) : undefined,
        user_data: input.user_data !== undefined ? BigInt(input.user_data) : undefined,
        group_id: input.group_id !== undefined ? BigInt(input.group_id) : undefined,
        altitude_m: input.altitude_m,
        velocity_mps: input.velocity_mps,
        ttl_seconds: input.ttl_seconds,
        accuracy_m: input.accuracy_m,
        heading: input.heading,
        flags: input.flags,
      })

      assertBigIntEqual(event.entity_id, expected.entity_id, 'entity_id')
      assertBigIntEqual(event.lat_nano, expected.lat_nano, 'lat_nano')
      assertBigIntEqual(event.lon_nano, expected.lon_nano, 'lon_nano')
      assertBigIntEqual(event.id, expected.id, 'id')
      assertBigIntEqual(event.timestamp, expected.timestamp, 'timestamp')
      assertBigIntEqual(event.correlation_id, expected.correlation_id, 'correlation_id')
      assertBigIntEqual(event.user_data, expected.user_data, 'user_data')
      assertBigIntEqual(event.group_id, expected.group_id, 'group_id')
      assertEqual(event.altitude_mm, expected.altitude_mm, 'altitude_mm')
      assertEqual(event.velocity_mms, expected.velocity_mms, 'velocity_mms')
      assertEqual(event.ttl_seconds, expected.ttl_seconds, 'ttl_seconds')
      assertEqual(event.accuracy_mm, expected.accuracy_mm, 'accuracy_mm')
      assertEqual(event.heading_cdeg, expected.heading_cdeg, 'heading_cdeg')
      assertEqual(event.flags, expected.flags, 'flags')
    })
  }
}

function testRadiusQueries(): void {
  console.log('\nWire Format Radius Query Creation:')

  for (const testCase of testData.radius_queries) {
    test(`createRadiusQuery: ${testCase.description}`, () => {
      const input = testCase.input
      const expected = testCase.expected

      const query = createRadiusQuery({
        latitude: input.latitude,
        longitude: input.longitude,
        radius_m: input.radius_m,
        limit: input.limit,
        timestamp_min: input.timestamp_min !== undefined ? BigInt(input.timestamp_min) : undefined,
        timestamp_max: input.timestamp_max !== undefined ? BigInt(input.timestamp_max) : undefined,
        group_id: input.group_id !== undefined ? BigInt(input.group_id) : undefined,
      })

      assertBigIntEqual(query.center_lat_nano, expected.center_lat_nano, 'center_lat_nano')
      assertBigIntEqual(query.center_lon_nano, expected.center_lon_nano, 'center_lon_nano')
      assertEqual(query.radius_mm, expected.radius_mm, 'radius_mm')
      assertEqual(query.limit, expected.limit, 'limit')
      assertBigIntEqual(query.timestamp_min, expected.timestamp_min, 'timestamp_min')
      assertBigIntEqual(query.timestamp_max, expected.timestamp_max, 'timestamp_max')
      assertBigIntEqual(query.group_id, expected.group_id, 'group_id')
    })
  }
}

function testPolygonQueries(): void {
  console.log('\nWire Format Polygon Query Creation:')

  for (const testCase of testData.polygon_queries) {
    test(`createPolygonQuery: ${testCase.description}`, () => {
      const input = testCase.input
      const expected = testCase.expected

      // Convert JSON [lat, lon] arrays to tuples
      const vertices: Array<[number, number]> = input.vertices.map(
        (v: number[]) => [v[0], v[1]] as [number, number]
      )

      const query = createPolygonQuery({
        vertices,
        limit: input.limit,
        timestamp_min: input.timestamp_min !== undefined ? BigInt(input.timestamp_min) : undefined,
        timestamp_max: input.timestamp_max !== undefined ? BigInt(input.timestamp_max) : undefined,
        group_id: input.group_id !== undefined ? BigInt(input.group_id) : undefined,
      })

      assertEqual(query.vertices.length, expected.vertices.length, 'vertex count')
      for (let i = 0; i < expected.vertices.length; i++) {
        assertBigIntEqual(query.vertices[i].lat_nano, expected.vertices[i].lat_nano, `vertex ${i} lat_nano`)
        assertBigIntEqual(query.vertices[i].lon_nano, expected.vertices[i].lon_nano, `vertex ${i} lon_nano`)
      }
      assertEqual(query.limit, expected.limit, 'limit')
      assertBigIntEqual(query.timestamp_min, expected.timestamp_min, 'timestamp_min')
      assertBigIntEqual(query.timestamp_max, expected.timestamp_max, 'timestamp_max')
      assertBigIntEqual(query.group_id, expected.group_id, 'group_id')
    })
  }
}

function testValidation(): void {
  console.log('\nWire Format Validation:')

  test('Invalid latitudes are rejected', () => {
    for (const lat of testData.validation_cases.invalid_latitudes) {
      assert(!isValidLatitude(lat), `Latitude ${lat} should be invalid`)
    }
  })

  test('Invalid longitudes are rejected', () => {
    for (const lon of testData.validation_cases.invalid_longitudes) {
      assert(!isValidLongitude(lon), `Longitude ${lon} should be invalid`)
    }
  })

  test('Valid boundary latitudes are accepted', () => {
    for (const lat of testData.validation_cases.valid_boundary_latitudes) {
      assert(isValidLatitude(lat), `Latitude ${lat} should be valid`)
    }
  })

  test('Valid boundary longitudes are accepted', () => {
    for (const lon of testData.validation_cases.valid_boundary_longitudes) {
      assert(isValidLongitude(lon), `Longitude ${lon} should be valid`)
    }
  })
}

// Main
function main(): void {
  console.log('ArcherDB Node.js SDK - Wire Format Compatibility Tests')
  console.log('='.repeat(60))

  try {
    testData = loadTestData()
  } catch (e) {
    console.error('Failed to load test data:', e)
    process.exit(1)
  }

  testConstants()
  testOperationCodes()
  testGeoEventFlags()
  testResultCodes()
  testCoordinateConversions()
  testDistanceConversions()
  testHeadingConversions()
  testGeoEvents()
  testRadiusQueries()
  testPolygonQueries()
  testValidation()

  console.log('\n' + '='.repeat(60))
  console.log(`WIRE FORMAT COMPATIBILITY: ${passed} passed, ${failed} failed`)

  if (failed > 0) {
    process.exit(1)
  }
}

main()
