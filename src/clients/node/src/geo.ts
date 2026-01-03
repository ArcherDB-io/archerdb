///////////////////////////////////////////////////////
// ArcherDB Node.js SDK - Geospatial Types           //
// Provides TypeScript types for GeoEvent operations //
///////////////////////////////////////////////////////

/**
 * GeoEvent flags for event status and metadata.
 * Maps to GeoEventFlags packed struct in geo_event.zig
 */
export enum GeoEventFlags {
  none = 0,

  /**
   * Event is part of a linked chain (all succeed or fail together)
   */
  linked = (1 << 0),

  /**
   * Event was imported with client-provided timestamp
   */
  imported = (1 << 1),

  /**
   * Entity is not moving (stationary)
   */
  stationary = (1 << 2),

  /**
   * GPS accuracy below threshold
   */
  low_accuracy = (1 << 3),

  /**
   * Entity is offline/unreachable
   */
  offline = (1 << 4),

  /**
   * Entity has been deleted (GDPR compliance)
   */
  deleted = (1 << 5),
}

/**
 * GeoEvent - 128-byte geospatial event record.
 *
 * Represents a single location update for a moving entity (vehicle, device, person).
 * Coordinates are stored in nanodegrees (10^-9 degrees) for sub-millimeter precision.
 *
 * @example
 * ```typescript
 * const event: GeoEvent = {
 *   id: 0n,  // Set to 0 for server-assigned composite ID
 *   entity_id: archerdb.id(),  // Generate unique entity UUID
 *   correlation_id: tripId,    // Trip/session correlation
 *   user_data: 0n,             // Application-specific data
 *   lat_nano: BigInt(Math.round(37.7749 * 1e9)),   // San Francisco lat
 *   lon_nano: BigInt(Math.round(-122.4194 * 1e9)), // San Francisco lon
 *   group_id: fleetId,         // Fleet grouping
 *   timestamp: 0n,             // Server-assigned
 *   altitude_mm: 0,            // Sea level
 *   velocity_mms: 0,           // Stationary
 *   ttl_seconds: 86400,        // 24-hour TTL
 *   accuracy_mm: 5000,         // 5m GPS accuracy
 *   heading_cdeg: 0,           // North
 *   flags: GeoEventFlags.none,
 * }
 * ```
 */
export type GeoEvent = {
  /**
   * Composite key: [S2 Cell ID (upper 64) | Timestamp (lower 64)]
   * Set to 0 for server-assigned ID, or provide for imported events.
   */
  id: bigint

  /**
   * UUID identifying the moving entity (vehicle, device, person).
   * Use `archerdb.id()` to generate a sortable UUID.
   */
  entity_id: bigint

  /**
   * UUID for trip/session/job correlation across events.
   * Use 0n if not tracking correlations.
   */
  correlation_id: bigint

  /**
   * Opaque application metadata (foreign key to sidecar database).
   */
  user_data: bigint

  /**
   * Latitude in nanodegrees (10^-9 degrees).
   * Valid range: -90,000,000,000 to +90,000,000,000
   *
   * Convert from degrees: `BigInt(Math.round(latitude * 1e9))`
   */
  lat_nano: bigint

  /**
   * Longitude in nanodegrees (10^-9 degrees).
   * Valid range: -180,000,000,000 to +180,000,000,000
   *
   * Convert from degrees: `BigInt(Math.round(longitude * 1e9))`
   */
  lon_nano: bigint

  /**
   * Fleet/region grouping identifier.
   * Use 0n for ungrouped events.
   */
  group_id: bigint

  /**
   * Event timestamp in nanoseconds since Unix epoch.
   * Set to 0n for server-assigned timestamp.
   */
  timestamp: bigint

  /**
   * Altitude in millimeters above WGS84 ellipsoid.
   * Positive values are above, negative below.
   */
  altitude_mm: number

  /**
   * Speed in millimeters per second.
   */
  velocity_mms: number

  /**
   * Time-to-live in seconds (0 = never expires).
   */
  ttl_seconds: number

  /**
   * GPS accuracy radius in millimeters.
   */
  accuracy_mm: number

  /**
   * Heading in centidegrees (0-36000, where 0=North, 9000=East).
   */
  heading_cdeg: number

  /**
   * Packed status flags.
   */
  flags: number
}

/**
 * Result codes for GeoEvent insert operations.
 * Maps to InsertGeoEventResult enum in geo_state_machine.zig
 */
export enum InsertGeoEventError {
  ok = 0,
  linked_event_failed = 1,
  linked_event_chain_open = 2,
  timestamp_must_be_zero = 3,
  reserved_field = 4,
  reserved_flag = 5,
  id_must_not_be_zero = 6,
  entity_id_must_not_be_zero = 7,
  invalid_coordinates = 8,
  lat_out_of_range = 9,
  lon_out_of_range = 10,
  exists_with_different_entity_id = 11,
  exists_with_different_coordinates = 12,
  exists = 13,
  heading_out_of_range = 14,
  ttl_invalid = 15,
}

/**
 * Result codes for entity delete operations.
 */
export enum DeleteEntityError {
  ok = 0,
  linked_event_failed = 1,
  entity_id_must_not_be_zero = 2,
  entity_not_found = 3,
}

/**
 * Per-event result for batch insert operations.
 */
export type InsertGeoEventsError = {
  index: number
  result: InsertGeoEventError
}

/**
 * Per-entity result for batch delete operations.
 */
export type DeleteEntitiesError = {
  index: number
  result: DeleteEntityError
}

/**
 * Filter for UUID lookup queries.
 * Returns the latest event for a specific entity.
 */
export type QueryUuidFilter = {
  /**
   * Entity UUID to look up.
   */
  entity_id: bigint

  /**
   * Maximum results to return (typically 1 for UUID lookups).
   */
  limit: number
}

/**
 * Filter for radius queries.
 * Returns events within a circular region.
 */
export type QueryRadiusFilter = {
  /**
   * Center latitude in nanodegrees.
   */
  center_lat_nano: bigint

  /**
   * Center longitude in nanodegrees.
   */
  center_lon_nano: bigint

  /**
   * Radius in millimeters.
   */
  radius_mm: number

  /**
   * Maximum results to return.
   */
  limit: number

  /**
   * Minimum timestamp (inclusive, 0 = no filter).
   */
  timestamp_min: bigint

  /**
   * Maximum timestamp (inclusive, 0 = no filter).
   */
  timestamp_max: bigint

  /**
   * Group ID filter (0 = no filter).
   */
  group_id: bigint
}

/**
 * Polygon vertex (lat/lon pair) for polygon queries.
 */
export type PolygonVertex = {
  /**
   * Latitude in nanodegrees.
   */
  lat_nano: bigint

  /**
   * Longitude in nanodegrees.
   */
  lon_nano: bigint
}

/**
 * Filter for polygon queries.
 * Returns events within a polygon region.
 */
export type QueryPolygonFilter = {
  /**
   * Polygon vertices in counter-clockwise winding order.
   * Minimum 3 vertices, maximum 10,000 vertices.
   */
  vertices: PolygonVertex[]

  /**
   * Maximum results to return.
   */
  limit: number

  /**
   * Minimum timestamp (inclusive, 0 = no filter).
   */
  timestamp_min: bigint

  /**
   * Maximum timestamp (inclusive, 0 = no filter).
   */
  timestamp_max: bigint

  /**
   * Group ID filter (0 = no filter).
   */
  group_id: bigint
}

/**
 * Filter for query_latest operation.
 * Returns the N most recent events globally or filtered by group_id.
 */
export type QueryLatestFilter = {
  /**
   * Maximum results to return (default 1000, max 81000).
   */
  limit: number

  /**
   * Group ID filter (0 = all groups).
   */
  group_id: bigint

  /**
   * Cursor timestamp for pagination (0 = start from latest).
   */
  cursor_timestamp: bigint
}

/**
 * Query result with pagination support.
 */
export type QueryResult = {
  /**
   * Array of matching GeoEvents.
   */
  events: GeoEvent[]

  /**
   * True if more results are available.
   */
  has_more: boolean

  /**
   * Cursor for fetching next page (pass to next query).
   */
  cursor?: bigint
}

/**
 * Result structure for delete operations.
 */
export type DeleteResult = {
  /**
   * Number of entities successfully deleted.
   */
  deleted_count: number

  /**
   * Number of entity IDs not found.
   */
  not_found_count: number
}

/**
 * ArcherDB geospatial operations enum.
 * Maps to Operation enum in archerdb.zig
 */
export enum GeoOperation {
  insert_events = 146,   // vsr_operations_reserved (128) + 18
  upsert_events = 147,   // vsr_operations_reserved (128) + 19
  delete_entities = 148, // vsr_operations_reserved (128) + 20
  query_uuid = 149,      // vsr_operations_reserved (128) + 21
  query_radius = 150,    // vsr_operations_reserved (128) + 22
  query_polygon = 151,   // vsr_operations_reserved (128) + 23
  query_latest = 154,    // vsr_operations_reserved (128) + 26
}

// ============================================================================
// Coordinate Conversion Helpers
// ============================================================================

/**
 * Maximum latitude in degrees.
 */
export const LAT_MAX = 90.0

/**
 * Maximum longitude in degrees.
 */
export const LON_MAX = 180.0

/**
 * Nanodegrees per degree (10^9).
 */
export const NANODEGREES_PER_DEGREE = 1_000_000_000n

/**
 * Millimeters per meter.
 */
export const MM_PER_METER = 1000

/**
 * Centidegrees per degree.
 */
export const CENTIDEGREES_PER_DEGREE = 100

/**
 * Maximum results per query (spatial query limit).
 */
export const QUERY_LIMIT_MAX = 81_000

/**
 * Maximum events per batch.
 */
export const BATCH_SIZE_MAX = 10_000

/**
 * Maximum polygon vertices.
 */
export const POLYGON_VERTICES_MAX = 10_000

/**
 * Converts degrees to nanodegrees.
 *
 * @param degrees - Coordinate in degrees
 * @returns Coordinate in nanodegrees as BigInt
 *
 * @example
 * ```typescript
 * const lat = degreesToNano(37.7749)  // San Francisco latitude
 * // Returns 37774900000n
 * ```
 */
export function degreesToNano(degrees: number): bigint {
  return BigInt(Math.round(degrees * 1e9))
}

/**
 * Converts nanodegrees to degrees.
 *
 * @param nano - Coordinate in nanodegrees
 * @returns Coordinate in degrees
 *
 * @example
 * ```typescript
 * const lat = nanoToDegrees(37774900000n)
 * // Returns 37.7749
 * ```
 */
export function nanoToDegrees(nano: bigint): number {
  return Number(nano) / 1e9
}

/**
 * Converts meters to millimeters.
 *
 * @param meters - Distance in meters
 * @returns Distance in millimeters
 */
export function metersToMm(meters: number): number {
  return Math.round(meters * MM_PER_METER)
}

/**
 * Converts millimeters to meters.
 *
 * @param mm - Distance in millimeters
 * @returns Distance in meters
 */
export function mmToMeters(mm: number): number {
  return mm / MM_PER_METER
}

/**
 * Converts heading from degrees to centidegrees.
 *
 * @param degrees - Heading in degrees (0-360)
 * @returns Heading in centidegrees (0-36000)
 */
export function headingToCentidegrees(degrees: number): number {
  return Math.round(degrees * CENTIDEGREES_PER_DEGREE)
}

/**
 * Converts heading from centidegrees to degrees.
 *
 * @param cdeg - Heading in centidegrees (0-36000)
 * @returns Heading in degrees (0-360)
 */
export function centidegreesToHeading(cdeg: number): number {
  return cdeg / CENTIDEGREES_PER_DEGREE
}

/**
 * Validates latitude is within valid range.
 *
 * @param lat - Latitude in degrees
 * @returns True if valid
 */
export function isValidLatitude(lat: number): boolean {
  return lat >= -LAT_MAX && lat <= LAT_MAX
}

/**
 * Validates longitude is within valid range.
 *
 * @param lon - Longitude in degrees
 * @returns True if valid
 */
export function isValidLongitude(lon: number): boolean {
  return lon >= -LON_MAX && lon <= LON_MAX
}

// ============================================================================
// GeoEvent Builder (Convenience API)
// ============================================================================

/**
 * Options for creating a GeoEvent with user-friendly units.
 */
export interface GeoEventOptions {
  /**
   * Entity UUID (use `archerdb.id()` to generate).
   */
  entity_id: bigint

  /**
   * Latitude in degrees (-90 to +90).
   */
  latitude: number

  /**
   * Longitude in degrees (-180 to +180).
   */
  longitude: number

  /**
   * Correlation ID for trip/session tracking (optional).
   */
  correlation_id?: bigint

  /**
   * Application-specific metadata (optional).
   */
  user_data?: bigint

  /**
   * Fleet/region grouping (optional).
   */
  group_id?: bigint

  /**
   * Altitude in meters (optional).
   */
  altitude_m?: number

  /**
   * Speed in meters per second (optional).
   */
  velocity_mps?: number

  /**
   * Time-to-live in seconds (optional, 0 = never expires).
   */
  ttl_seconds?: number

  /**
   * GPS accuracy in meters (optional).
   */
  accuracy_m?: number

  /**
   * Heading in degrees 0-360 (optional, 0 = North).
   */
  heading?: number

  /**
   * Event flags (optional).
   */
  flags?: GeoEventFlags
}

/**
 * Creates a GeoEvent from user-friendly options.
 *
 * Handles unit conversions automatically:
 * - Degrees to nanodegrees
 * - Meters to millimeters
 * - Heading degrees to centidegrees
 *
 * @param options - Event options with user-friendly units
 * @returns GeoEvent ready for insertion
 *
 * @example
 * ```typescript
 * const event = createGeoEvent({
 *   entity_id: archerdb.id(),
 *   latitude: 37.7749,
 *   longitude: -122.4194,
 *   velocity_mps: 15.5,
 *   heading: 90,
 *   accuracy_m: 5,
 * })
 * ```
 */
export function createGeoEvent(options: GeoEventOptions): GeoEvent {
  if (!isValidLatitude(options.latitude)) {
    throw new Error(`Invalid latitude: ${options.latitude}. Must be between -90 and +90 degrees.`)
  }
  if (!isValidLongitude(options.longitude)) {
    throw new Error(`Invalid longitude: ${options.longitude}. Must be between -180 and +180 degrees.`)
  }

  return {
    id: 0n, // Server-assigned
    entity_id: options.entity_id,
    correlation_id: options.correlation_id ?? 0n,
    user_data: options.user_data ?? 0n,
    lat_nano: degreesToNano(options.latitude),
    lon_nano: degreesToNano(options.longitude),
    group_id: options.group_id ?? 0n,
    timestamp: 0n, // Server-assigned
    altitude_mm: options.altitude_m !== undefined ? metersToMm(options.altitude_m) : 0,
    velocity_mms: options.velocity_mps !== undefined ? metersToMm(options.velocity_mps) : 0,
    ttl_seconds: options.ttl_seconds ?? 0,
    accuracy_mm: options.accuracy_m !== undefined ? metersToMm(options.accuracy_m) : 0,
    heading_cdeg: options.heading !== undefined ? headingToCentidegrees(options.heading) : 0,
    flags: options.flags ?? GeoEventFlags.none,
  }
}

// ============================================================================
// Query Builder (Convenience API)
// ============================================================================

/**
 * Options for radius queries with user-friendly units.
 */
export interface RadiusQueryOptions {
  /**
   * Center latitude in degrees.
   */
  latitude: number

  /**
   * Center longitude in degrees.
   */
  longitude: number

  /**
   * Radius in meters.
   */
  radius_m: number

  /**
   * Maximum results (optional, default 1000).
   */
  limit?: number

  /**
   * Minimum timestamp filter (optional).
   */
  timestamp_min?: bigint

  /**
   * Maximum timestamp filter (optional).
   */
  timestamp_max?: bigint

  /**
   * Group ID filter (optional).
   */
  group_id?: bigint
}

/**
 * Creates a QueryRadiusFilter from user-friendly options.
 *
 * @param options - Query options with user-friendly units
 * @returns QueryRadiusFilter ready for query
 */
export function createRadiusQuery(options: RadiusQueryOptions): QueryRadiusFilter {
  if (!isValidLatitude(options.latitude)) {
    throw new Error(`Invalid latitude: ${options.latitude}`)
  }
  if (!isValidLongitude(options.longitude)) {
    throw new Error(`Invalid longitude: ${options.longitude}`)
  }
  if (options.radius_m <= 0) {
    throw new Error(`Invalid radius: ${options.radius_m}. Must be positive.`)
  }

  return {
    center_lat_nano: degreesToNano(options.latitude),
    center_lon_nano: degreesToNano(options.longitude),
    radius_mm: metersToMm(options.radius_m),
    limit: options.limit ?? 1000,
    timestamp_min: options.timestamp_min ?? 0n,
    timestamp_max: options.timestamp_max ?? 0n,
    group_id: options.group_id ?? 0n,
  }
}

/**
 * Options for polygon queries with user-friendly units.
 */
export interface PolygonQueryOptions {
  /**
   * Polygon vertices as [lat, lon] pairs in degrees.
   * Counter-clockwise winding order.
   */
  vertices: Array<[number, number]>

  /**
   * Maximum results (optional, default 1000).
   */
  limit?: number

  /**
   * Minimum timestamp filter (optional).
   */
  timestamp_min?: bigint

  /**
   * Maximum timestamp filter (optional).
   */
  timestamp_max?: bigint

  /**
   * Group ID filter (optional).
   */
  group_id?: bigint
}

/**
 * Creates a QueryPolygonFilter from user-friendly options.
 *
 * @param options - Query options with user-friendly units
 * @returns QueryPolygonFilter ready for query
 */
export function createPolygonQuery(options: PolygonQueryOptions): QueryPolygonFilter {
  if (options.vertices.length < 3) {
    throw new Error(`Polygon must have at least 3 vertices, got ${options.vertices.length}`)
  }
  if (options.vertices.length > POLYGON_VERTICES_MAX) {
    throw new Error(`Polygon exceeds maximum ${POLYGON_VERTICES_MAX} vertices, got ${options.vertices.length}`)
  }

  const vertices: PolygonVertex[] = options.vertices.map(([lat, lon], i) => {
    if (!isValidLatitude(lat)) {
      throw new Error(`Invalid latitude at vertex ${i}: ${lat}`)
    }
    if (!isValidLongitude(lon)) {
      throw new Error(`Invalid longitude at vertex ${i}: ${lon}`)
    }
    return {
      lat_nano: degreesToNano(lat),
      lon_nano: degreesToNano(lon),
    }
  })

  return {
    vertices,
    limit: options.limit ?? 1000,
    timestamp_min: options.timestamp_min ?? 0n,
    timestamp_max: options.timestamp_max ?? 0n,
    group_id: options.group_id ?? 0n,
  }
}
