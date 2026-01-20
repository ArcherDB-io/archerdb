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
}

/**
 * Result of batch UUID lookup (F1.3.4).
 */
export type QueryUuidBatchResult = {
  found_count: number
  not_found_count: number
  not_found_indices: number[]
  events: GeoEvent[]
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
 * Hole descriptor for polygon with holes.
 * Each hole is an array of vertices forming an exclusion zone.
 */
export type PolygonHole = {
  /**
   * Hole vertices in clockwise winding order.
   * Minimum 3 vertices per hole.
   */
  vertices: PolygonVertex[]
}

/**
 * Filter for polygon queries.
 * Returns events within a polygon region, excluding any holes.
 */
export type QueryPolygonFilter = {
  /**
   * Outer ring vertices in counter-clockwise winding order.
   * Minimum 3 vertices, maximum 10,000 vertices.
   */
  vertices: PolygonVertex[]

  /**
   * Hole rings (exclusion zones) within the polygon.
   * Each hole uses clockwise winding order.
   * Maximum 100 holes, minimum 3 vertices per hole.
   * Optional - omit for simple polygons without holes.
   */
  holes?: PolygonHole[]

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
   * Reserved for alignment (must be 0).
   * @internal
   */
  _reserved_align: number

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
 * Wire format header for query responses (16 bytes).
 * Matches QueryResponse struct in geo_state_machine.zig.
 *
 * The server sends this header followed by an array of GeoEvent records.
 */
export type QueryResponse = {
  /** Number of events in response (u32) */
  count: number
  /** More results available beyond limit */
  has_more: boolean
  /** Result set was truncated */
  partial_result: boolean
}

/**
 * Flag bit positions in the QueryResponse flags byte (legacy).
 */
export const QUERY_RESPONSE_FLAG_HAS_MORE = 0x01
export const QUERY_RESPONSE_FLAG_PARTIAL_RESULT = 0x02

/**
 * Size of QueryResponse header in bytes.
 */
export const QUERY_RESPONSE_HEADER_SIZE = 16

/**
 * Parse QueryResponse header from raw bytes.
 *
 * @param data - At least 8 bytes of response data
 * @returns Parsed QueryResponse header
 * @throws Error if data is less than 8 bytes
 */
export function parseQueryResponse(data: Uint8Array): QueryResponse {
  if (data.length < QUERY_RESPONSE_HEADER_SIZE) {
    throw new Error(`QueryResponse requires ${QUERY_RESPONSE_HEADER_SIZE} bytes, got ${data.length}`)
  }

  const view = new DataView(data.buffer, data.byteOffset, data.byteLength)
  const count = view.getUint32(0, true) // little-endian

  return {
    count,
    has_more: view.getUint8(4) !== 0,
    partial_result: view.getUint8(5) !== 0,
  }
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
  insert_events = 146,      // vsr_operations_reserved (128) + 18
  upsert_events = 147,      // vsr_operations_reserved (128) + 19
  delete_entities = 148,    // vsr_operations_reserved (128) + 20
  query_uuid = 149,         // vsr_operations_reserved (128) + 21
  query_radius = 150,       // vsr_operations_reserved (128) + 22
  query_polygon = 151,      // vsr_operations_reserved (128) + 23
  archerdb_ping = 152,      // vsr_operations_reserved (128) + 24
  archerdb_get_status = 153, // vsr_operations_reserved (128) + 25
  query_latest = 154,       // vsr_operations_reserved (128) + 26
  cleanup_expired = 155,    // vsr_operations_reserved (128) + 27
  query_uuid_batch = 156,   // vsr_operations_reserved (128) + 28
  get_topology = 157,       // vsr_operations_reserved (128) + 29
  ttl_set = 158,            // vsr_operations_reserved (128) + 30
  ttl_extend = 159,         // vsr_operations_reserved (128) + 31
  ttl_clear = 160,          // vsr_operations_reserved (128) + 32
}

/**
 * Server status response from archerdb_get_status operation.
 * Matches StatusResponse in geo_state_machine.zig (64 bytes).
 */
export type StatusResponse = {
  /** Number of entities in RAM index */
  ram_index_count: bigint
  /** Total RAM index capacity */
  ram_index_capacity: bigint
  /** Load factor as percentage * 100 (e.g., 7000 = 70%) */
  ram_index_load_pct: number
  /** Number of tombstone entries */
  tombstone_count: bigint
  /** Total TTL expirations processed */
  ttl_expirations: bigint
  /** Total deletions processed */
  deletion_count: bigint
}

/**
 * Result of cleanup_expired operation.
 *
 * Per client-protocol/spec.md cleanup_expired (0x30) response format:
 * - entries_scanned: u64 - Number of index entries examined
 * - entries_removed: u64 - Number of expired entries cleaned up
 */
export type CleanupResult = {
  /** Number of index entries examined */
  entries_scanned: bigint
  /** Number of expired entries cleaned up */
  entries_removed: bigint
}

/**
 * Wire format size of CleanupResult response (16 bytes: 2x u64).
 */
export const CLEANUP_RESULT_SIZE = 16

/**
 * Check if any entries were removed during cleanup.
 */
export function hasCleanupRemovals(result: CleanupResult): boolean {
  return result.entries_removed > 0n
}

/**
 * Calculate the percentage of scanned entries that were expired.
 *
 * @param result - CleanupResult from cleanup_expired operation
 * @returns Expiration ratio (0.0 to 1.0), or 0.0 if no entries scanned
 */
export function getCleanupExpirationRatio(result: CleanupResult): number {
  if (result.entries_scanned === 0n) {
    return 0.0
  }
  return Number(result.entries_removed) / Number(result.entries_scanned)
}

// ============================================================================
// TTL Operations (v2.1 Manual TTL Support)
// ============================================================================

/**
 * Result codes for TTL operations.
 * Maps to TtlOperationResult enum in ttl.zig
 */
export enum TtlOperationResult {
  success = 0,
  entity_not_found = 1,
  invalid_ttl = 2,
  not_permitted = 3,
  entity_immutable = 4,
}

/**
 * Request to set an absolute TTL for an entity.
 * Wire format: 64 bytes
 */
export type TtlSetRequest = {
  /**
   * Entity UUID to set TTL for.
   */
  entity_id: bigint

  /**
   * Absolute TTL in seconds (0 = never expires).
   */
  ttl_seconds: number

  /**
   * Reserved flags (must be 0).
   */
  flags: number
}

/**
 * Response from a TTL set operation.
 * Wire format: 64 bytes
 */
export type TtlSetResponse = {
  /**
   * Entity UUID that was modified.
   */
  entity_id: bigint

  /**
   * Previous TTL value in seconds.
   */
  previous_ttl_seconds: number

  /**
   * New TTL value in seconds.
   */
  new_ttl_seconds: number

  /**
   * Operation result code.
   */
  result: TtlOperationResult
}

/**
 * Request to extend an entity's TTL by a relative amount.
 * Wire format: 64 bytes
 */
export type TtlExtendRequest = {
  /**
   * Entity UUID to extend TTL for.
   */
  entity_id: bigint

  /**
   * Number of seconds to extend the TTL by.
   */
  extend_by_seconds: number

  /**
   * Reserved flags (must be 0).
   */
  flags: number
}

/**
 * Response from a TTL extend operation.
 * Wire format: 64 bytes
 */
export type TtlExtendResponse = {
  /**
   * Entity UUID that was modified.
   */
  entity_id: bigint

  /**
   * Previous TTL value in seconds.
   */
  previous_ttl_seconds: number

  /**
   * New TTL value in seconds.
   */
  new_ttl_seconds: number

  /**
   * Operation result code.
   */
  result: TtlOperationResult
}

/**
 * Request to clear an entity's TTL (make it never expire).
 * Wire format: 64 bytes
 */
export type TtlClearRequest = {
  /**
   * Entity UUID to clear TTL for.
   */
  entity_id: bigint

  /**
   * Reserved flags (must be 0).
   */
  flags: number
}

/**
 * Response from a TTL clear operation.
 * Wire format: 64 bytes
 */
export type TtlClearResponse = {
  /**
   * Entity UUID that was modified.
   */
  entity_id: bigint

  /**
   * Previous TTL value in seconds.
   */
  previous_ttl_seconds: number

  /**
   * Operation result code.
   */
  result: TtlOperationResult
}

// ============================================================================
// S2 Cell ID Computation (Simplified)
// ============================================================================

/**
 * Computes S2 cell ID at level 30 (7.5mm precision).
 * This is a simplified implementation for client-side composite ID generation.
 *
 * @param lat_nano - Latitude in nanodegrees
 * @param lon_nano - Longitude in nanodegrees
 * @returns S2 cell ID as bigint (u64)
 */
export function computeS2CellId(lat_nano: bigint, lon_nano: bigint): bigint {
  // Convert to radians
  const lat = Number(lat_nano) / 1e9 * Math.PI / 180
  const lon = Number(lon_nano) / 1e9 * Math.PI / 180

  // Convert to S2 point (unit sphere)
  const cos_lat = Math.cos(lat)
  const x = cos_lat * Math.cos(lon)
  const y = cos_lat * Math.sin(lon)
  const z = Math.sin(lat)

  // Determine face (0-5) based on largest absolute coordinate
  let face: number
  const ax = Math.abs(x), ay = Math.abs(y), az = Math.abs(z)
  if (ax >= ay && ax >= az) {
    face = x > 0 ? 0 : 3
  } else if (ay >= ax && ay >= az) {
    face = y > 0 ? 1 : 4
  } else {
    face = z > 0 ? 2 : 5
  }

  // Project to face coordinates (u, v) in [-1, 1]
  let u: number, v: number
  switch (face) {
    case 0: u = y / x; v = z / x; break
    case 1: u = -x / y; v = z / y; break
    case 2: u = -x / z; v = -y / z; break
    case 3: u = z / x; v = y / x; break
    case 4: u = z / y; v = -x / y; break
    case 5: u = -y / z; v = -x / z; break
    default: u = 0; v = 0
  }

  // Apply quadratic transform for better cell uniformity
  const stFromUV = (uv: number): number => {
    if (uv >= 0) {
      return 0.5 * Math.sqrt(1 + 3 * uv)
    } else {
      return 1 - 0.5 * Math.sqrt(1 - 3 * uv)
    }
  }
  const s = stFromUV(u)
  const t = stFromUV(v)

  // Convert to integer coordinates at level 30
  const level = 30
  const maxSize = 1 << level
  const i = Math.min(maxSize - 1, Math.max(0, Math.floor(s * maxSize)))
  const j = Math.min(maxSize - 1, Math.max(0, Math.floor(t * maxSize)))

  // Build cell ID using Hilbert curve interleaving
  // Face bits (3 bits) + pos bits (60 bits) + 1 bit
  let cellId = BigInt(face) << 61n

  // Interleave i and j bits (simplified - not full Hilbert curve)
  for (let k = level - 1; k >= 0; k--) {
    const iBit = (i >> k) & 1
    const jBit = (j >> k) & 1
    const bits = (iBit << 1) | jBit
    cellId |= BigInt(bits) << BigInt(2 * k + 1)
  }

  // Set the sentinel bit
  cellId |= 1n

  return cellId
}

/**
 * Creates a composite ID from S2 cell ID and timestamp.
 *
 * @param s2CellId - S2 cell ID (upper 64 bits)
 * @param timestamp - Timestamp in nanoseconds (lower 64 bits)
 * @returns Composite ID as u128
 */
export function packCompositeId(s2CellId: bigint, timestamp: bigint): bigint {
  return (s2CellId << 64n) | timestamp
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
 *
 * NOTE: This assumes production config with 10MB message_size_max.
 * With the default 1MB message_size_max, the effective limit is ~8,180 events.
 * The server returns actual limits during client registration (batch_size_limit).
 * For production deployments, configure message_size_max = 10MB in server config.
 */
export const QUERY_LIMIT_MAX = 81_000

/**
 * Maximum events per batch.
 *
 * NOTE: This assumes production config with 10MB message_size_max.
 * With the default 1MB message_size_max, the effective limit is ~8,180 events.
 * The server returns actual limits during client registration (batch_size_limit).
 * For production deployments, configure message_size_max = 10MB in server config.
 */
export const BATCH_SIZE_MAX = 10_000

/**
 * Maximum polygon vertices.
 */
export const POLYGON_VERTICES_MAX = 10_000

/**
 * Maximum holes per polygon.
 */
export const POLYGON_HOLES_MAX = 100

/**
 * Minimum vertices per hole (must form a valid ring).
 */
export const POLYGON_HOLE_VERTICES_MIN = 3

/**
 * Safe batch size limit for default 1MB message configuration.
 * Use this if connecting to a server with default configuration.
 */
export const BATCH_SIZE_MAX_DEFAULT = 8_000

/**
 * Safe query limit for default 1MB message configuration.
 * Use this if connecting to a server with default configuration.
 */
export const QUERY_LIMIT_MAX_DEFAULT = 8_000

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
 * Also computes the composite ID (S2 cell | timestamp) client-side.
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

  const lat_nano = degreesToNano(options.latitude)
  const lon_nano = degreesToNano(options.longitude)

  // Create event with id=0 per wire format spec.
  // Call prepareGeoEvent() before sending to generate the composite ID.
  return {
    id: 0n,
    entity_id: options.entity_id,
    correlation_id: options.correlation_id ?? 0n,
    user_data: options.user_data ?? 0n,
    lat_nano,
    lon_nano,
    group_id: options.group_id ?? 0n,
    timestamp: 0n, // Server validates this must be 0 for non-imported events
    altitude_mm: options.altitude_m !== undefined ? metersToMm(options.altitude_m) : 0,
    velocity_mms: options.velocity_mps !== undefined ? metersToMm(options.velocity_mps) : 0,
    ttl_seconds: options.ttl_seconds ?? 0,
    accuracy_mm: options.accuracy_m !== undefined ? metersToMm(options.accuracy_m) : 0,
    heading_cdeg: options.heading !== undefined ? headingToCentidegrees(options.heading) : 0,
    flags: options.flags ?? GeoEventFlags.none,
  }
}

/**
 * Prepares a GeoEvent for sending by generating a composite ID.
 *
 * The composite ID encodes the S2 cell (from coordinates) and current timestamp.
 * This should be called just before sending the event to the server.
 *
 * @param event - The GeoEvent to prepare (modified in place)
 * @returns The same event with id field populated
 *
 * @example
 * ```typescript
 * const event = createGeoEvent({ entity_id: id(), latitude: 37.7749, longitude: -122.4194 })
 * prepareGeoEvent(event) // Sets event.id
 * await client.upsert([event])
 * ```
 */
export function prepareGeoEvent(event: GeoEvent): GeoEvent {
  if (event.id !== 0n) {
    // Already prepared
    return event
  }

  // Compute timestamp for composite ID (nanoseconds since Unix epoch)
  const now_ns = BigInt(Date.now()) * 1_000_000n

  // Compute S2 cell ID and composite ID from coordinates
  const s2CellId = computeS2CellId(event.lat_nano, event.lon_nano)
  event.id = packCompositeId(s2CellId, now_ns)

  return event
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
   * Outer ring vertices as [lat, lon] pairs in degrees.
   * Counter-clockwise winding order.
   */
  vertices: Array<[number, number]>

  /**
   * Hole rings (exclusion zones) as arrays of [lat, lon] pairs.
   * Each hole should use clockwise winding order.
   * Maximum 100 holes, minimum 3 vertices per hole.
   * Optional - omit for simple polygons without holes.
   *
   * @example
   * ```typescript
   * // Polygon with one rectangular hole
   * const result = await client.queryPolygon({
   *   vertices: [[0, 0], [0, 10], [10, 10], [10, 0]],  // Outer ring (CCW)
   *   holes: [
   *     [[2, 2], [2, 4], [4, 4], [4, 2]]  // Hole (CW)
   *   ],
   *   limit: 1000,
   * })
   * ```
   */
  holes?: Array<Array<[number, number]>>

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
  // Validate outer ring
  if (options.vertices.length < 3) {
    throw new Error(`Polygon must have at least 3 vertices, got ${options.vertices.length}`)
  }
  if (options.vertices.length > POLYGON_VERTICES_MAX) {
    throw new Error(`Polygon exceeds maximum ${POLYGON_VERTICES_MAX} vertices, got ${options.vertices.length}`)
  }

  // Convert outer ring vertices
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

  // Validate and convert holes (if present)
  let holes: PolygonHole[] | undefined = undefined
  if (options.holes && options.holes.length > 0) {
    if (options.holes.length > POLYGON_HOLES_MAX) {
      throw new Error(`Polygon exceeds maximum ${POLYGON_HOLES_MAX} holes, got ${options.holes.length}`)
    }

    let totalHoleVertices = 0
    holes = options.holes.map((holeVertices, holeIndex) => {
      if (holeVertices.length < POLYGON_HOLE_VERTICES_MIN) {
        throw new Error(`Hole ${holeIndex} must have at least ${POLYGON_HOLE_VERTICES_MIN} vertices, got ${holeVertices.length}`)
      }

      totalHoleVertices += holeVertices.length

      const holePolygonVertices: PolygonVertex[] = holeVertices.map(([lat, lon], vertexIndex) => {
        if (!isValidLatitude(lat)) {
          throw new Error(`Invalid latitude at hole ${holeIndex} vertex ${vertexIndex}: ${lat}`)
        }
        if (!isValidLongitude(lon)) {
          throw new Error(`Invalid longitude at hole ${holeIndex} vertex ${vertexIndex}: ${lon}`)
        }
        return {
          lat_nano: degreesToNano(lat),
          lon_nano: degreesToNano(lon),
        }
      })

      return { vertices: holePolygonVertices }
    })

    // Check total vertex count (outer + all holes)
    const totalVertices = options.vertices.length + totalHoleVertices
    if (totalVertices > POLYGON_VERTICES_MAX) {
      throw new Error(`Total vertices (outer + holes) exceeds maximum ${POLYGON_VERTICES_MAX}, got ${totalVertices}`)
    }
  }

  return {
    vertices,
    holes,
    limit: options.limit ?? 1000,
    timestamp_min: options.timestamp_min ?? 0n,
    timestamp_max: options.timestamp_max ?? 0n,
    group_id: options.group_id ?? 0n,
  }
}

// ============================================================================
// Sharding Strategy (per add-jump-consistent-hash spec)
// Algorithm for distributing entities across shards
// ============================================================================

/**
 * Strategy for distributing entities across shards.
 *
 * Different strategies offer different trade-offs:
 * - modulo: Simple, requires power-of-2 shard counts, moves most data on resize
 * - virtual_ring: Consistent hashing with O(log N) lookup and memory cost
 * - jump_hash: Google's algorithm - O(1) memory, O(log N) compute, optimal movement
 */
export enum ShardingStrategy {
  /** Simple hash % shards. Requires power-of-2 shard counts. */
  modulo = 0,
  /** Consistent hashing with virtual nodes. */
  virtual_ring = 1,
  /** Google's Jump Consistent Hash (default, recommended). */
  jump_hash = 2,
}

/**
 * Check if a sharding strategy requires power-of-2 shard counts.
 */
export function shardingStrategyRequiresPowerOfTwo(
  strategy: ShardingStrategy
): boolean {
  return strategy === ShardingStrategy.modulo
}

/**
 * Parse sharding strategy from string.
 */
export function parseShardingStrategy(s: string): ShardingStrategy | null {
  switch (s.toLowerCase()) {
    case 'modulo':
      return ShardingStrategy.modulo
    case 'virtual_ring':
      return ShardingStrategy.virtual_ring
    case 'jump_hash':
      return ShardingStrategy.jump_hash
    default:
      return null
  }
}

/**
 * Convert sharding strategy to string.
 */
export function shardingStrategyToString(strategy: ShardingStrategy): string {
  switch (strategy) {
    case ShardingStrategy.modulo:
      return 'modulo'
    case ShardingStrategy.virtual_ring:
      return 'virtual_ring'
    case ShardingStrategy.jump_hash:
      return 'jump_hash'
  }
}

// ============================================================================
// Geo-Sharding Types (v2.2)
// Geographic partitioning for data locality
// ============================================================================

/**
 * Policy for assigning entities to geographic regions.
 */
export enum GeoShardPolicy {
  /** No geo-sharding - all entities in single region */
  none = 0,
  /** Route based on entity's lat/lon coordinates to nearest region */
  by_entity_location = 1,
  /** Route based on entity_id prefix mapping to regions */
  by_entity_id_prefix = 2,
  /** Application explicitly specifies target region per entity */
  explicit = 3,
}

/**
 * A geographic region in the geo-sharding topology.
 */
export type GeoRegion = {
  /** Unique identifier for this region (max 16 characters) */
  region_id: string
  /** Human-readable name for the region */
  name: string
  /** Endpoint address for this region */
  endpoint: string
  /** Center latitude in nanodegrees for by_entity_location routing */
  center_lat_nano: bigint
  /** Center longitude in nanodegrees for by_entity_location routing */
  center_lon_nano: bigint
  /** Priority for routing (lower = higher priority for ties) */
  priority: number
  /** Whether this region is currently active */
  is_active: boolean
}

/**
 * Configuration for geo-sharding behavior.
 */
export type GeoShardConfig = {
  /** The geo-sharding policy to use */
  policy: GeoShardPolicy
  /** Available regions for routing */
  regions: GeoRegion[]
  /** Default region ID when routing cannot determine target */
  default_region_id: string
  /** Whether to allow cross-region query aggregation */
  allow_cross_region_queries: boolean
}

/**
 * Metadata tracking which region owns an entity.
 */
export type EntityRegionMetadata = {
  /** The entity ID */
  entity_id: bigint
  /** The region ID that owns this entity */
  region_id: string
  /** Timestamp when entity was assigned to this region (nanoseconds) */
  assigned_timestamp: bigint
  /** Whether this assignment was explicit or computed */
  is_explicit: boolean
}

/**
 * Result of a cross-region query aggregation.
 */
export type CrossRegionQueryResult = {
  /** Aggregated events from all regions */
  events: GeoEvent[]
  /** Per-region result counts */
  region_results: Map<string, number>
  /** Regions that failed during the query */
  region_errors: Map<string, string>
  /** Whether more results are available */
  has_more: boolean
  /** Total latency in milliseconds */
  total_latency_ms: number
}

/**
 * Creates a GeoRegion with center coordinates in degrees.
 */
export function createGeoRegion(
  region_id: string,
  name: string,
  endpoint: string,
  center_latitude: number,
  center_longitude: number,
  priority: number = 0,
): GeoRegion {
  return {
    region_id,
    name,
    endpoint,
    center_lat_nano: degreesToNano(center_latitude),
    center_lon_nano: degreesToNano(center_longitude),
    priority,
    is_active: true,
  }
}

// ============================================================================
// Conflict Resolution Types (v2.2)
// Active-Active Replication Support
// ============================================================================

/**
 * Policy for resolving write conflicts in active-active replication.
 */
export enum ConflictResolutionPolicy {
  /** Highest timestamp wins (default) */
  last_writer_wins = 0,
  /** Primary region write takes precedence */
  primary_wins = 1,
  /** Application-provided resolution function */
  custom_hook = 2,
}

/**
 * Vector clock for tracking causality in distributed systems.
 */
export type VectorClock = {
  /** Clock entries keyed by region ID */
  entries: Map<string, bigint>
}

/**
 * Creates an empty vector clock.
 */
export function createVectorClock(): VectorClock {
  return { entries: new Map() }
}

/**
 * Increments the timestamp for a region in the vector clock.
 */
export function incrementVectorClock(clock: VectorClock, region_id: string): bigint {
  const current = clock.entries.get(region_id) ?? 0n
  const newValue = current + 1n
  clock.entries.set(region_id, newValue)
  return newValue
}

/**
 * Merges another vector clock into this one (takes max of each entry).
 */
export function mergeVectorClocks(clock: VectorClock, other: VectorClock): void {
  for (const [region_id, timestamp] of other.entries) {
    const current = clock.entries.get(region_id) ?? 0n
    if (timestamp > current) {
      clock.entries.set(region_id, timestamp)
    }
  }
}

/**
 * Compares two vector clocks.
 * Returns: -1 if a < b, 0 if concurrent, 1 if a > b
 */
export function compareVectorClocks(a: VectorClock, b: VectorClock): number {
  let aGreater = false
  let bGreater = false

  // Check all entries in a
  for (const [region_id, ts] of a.entries) {
    const bTs = b.entries.get(region_id) ?? 0n
    if (ts > bTs) aGreater = true
    if (ts < bTs) bGreater = true
  }

  // Check entries only in b
  for (const [region_id, ts] of b.entries) {
    if (!a.entries.has(region_id) && ts > 0n) {
      bGreater = true
    }
  }

  if (aGreater && !bGreater) return 1
  if (bGreater && !aGreater) return -1
  return 0 // Concurrent
}

/**
 * Returns true if the clocks are concurrent (neither happened before the other).
 */
export function areConcurrent(a: VectorClock, b: VectorClock): boolean {
  return compareVectorClocks(a, b) === 0
}

/**
 * Information about a detected conflict.
 */
export type ConflictInfo = {
  /** The entity ID with the conflict */
  entity_id: bigint
  /** Vector clock of the local write */
  local_clock: VectorClock
  /** Vector clock of the remote write */
  remote_clock: VectorClock
  /** Region ID where local write originated */
  local_region: string
  /** Region ID where remote write originated */
  remote_region: string
  /** Timestamp of the local write (nanoseconds) */
  local_timestamp: bigint
  /** Timestamp of the remote write (nanoseconds) */
  remote_timestamp: bigint
}

/**
 * Result of conflict resolution.
 */
export type ConflictResolution = {
  /** The winning region ID */
  winning_region: string
  /** The policy used for resolution */
  policy: ConflictResolutionPolicy
  /** The merged vector clock after resolution */
  merged_clock: VectorClock
  /** Whether the local write won */
  local_wins: boolean
}

/**
 * Statistics about conflict resolution.
 */
export type ConflictStats = {
  /** Total conflicts detected */
  total_conflicts: bigint
  /** Conflicts resolved by last-writer-wins */
  last_writer_wins_count: bigint
  /** Conflicts resolved by primary-wins */
  primary_wins_count: bigint
  /** Conflicts resolved by custom hook */
  custom_hook_count: bigint
  /** Timestamp of last conflict (nanoseconds) */
  last_conflict_timestamp: bigint
}

/**
 * Entry in the conflict audit log.
 */
export type ConflictAuditEntry = {
  /** Unique ID for this audit entry */
  audit_id: bigint
  /** The entity ID with the conflict */
  entity_id: bigint
  /** Timestamp when conflict was detected (nanoseconds) */
  detected_timestamp: bigint
  /** The winning region ID */
  winning_region: string
  /** The losing region ID */
  losing_region: string
  /** The resolution policy used */
  policy: ConflictResolutionPolicy
  /** Serialized winning write data (for auditing) */
  winning_data?: Uint8Array
  /** Serialized losing write data (for auditing) */
  losing_data?: Uint8Array
}

// ============================================================================
// GeoJSON/WKT Protocol Support (per add-geojson-wkt-protocol spec)
// ============================================================================

/**
 * Error class for GeoJSON/WKT parsing failures.
 */
export class GeoFormatError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'GeoFormatError'
  }
}

/**
 * Output format for geographic data.
 */
export enum GeoFormat {
  /** Native nanodegree format */
  native = 0,
  /** GeoJSON format */
  geojson = 1,
  /** Well-Known Text format */
  wkt = 2,
}

/**
 * GeoJSON Point type.
 */
export type GeoJSONPoint = {
  type: 'Point'
  coordinates: [number, number] | [number, number, number]
}

/**
 * GeoJSON Polygon type.
 */
export type GeoJSONPolygon = {
  type: 'Polygon'
  coordinates: number[][][]
}

/**
 * Parses a GeoJSON Point to nanodegree coordinates.
 *
 * @param geojson - GeoJSON Point object or JSON string
 * @returns Tuple of [lat_nano, lon_nano]
 * @throws GeoFormatError if parsing fails
 *
 * @example
 * ```typescript
 * const [lat, lon] = parseGeoJSONPoint({
 *   type: 'Point',
 *   coordinates: [-122.4194, 37.7749]
 * })
 * ```
 */
export function parseGeoJSONPoint(
  geojson: GeoJSONPoint | string
): [bigint, bigint] {
  let obj: GeoJSONPoint

  if (typeof geojson === 'string') {
    try {
      obj = JSON.parse(geojson)
    } catch (e) {
      throw new GeoFormatError(`Invalid JSON: ${e}`)
    }
  } else {
    obj = geojson
  }

  if (!obj || typeof obj !== 'object') {
    throw new GeoFormatError('GeoJSON must be an object')
  }

  if (obj.type !== 'Point') {
    throw new GeoFormatError(`Expected type 'Point', got '${obj.type}'`)
  }

  if (!Array.isArray(obj.coordinates) || obj.coordinates.length < 2) {
    throw new GeoFormatError('Point must have coordinates [lon, lat]')
  }

  const [lon, lat] = obj.coordinates
  if (typeof lon !== 'number' || typeof lat !== 'number') {
    throw new GeoFormatError('Coordinates must be numbers')
  }

  validateCoordinates(lat, lon)

  return [degreesToNano(lat), degreesToNano(lon)]
}

/**
 * Parses a GeoJSON Polygon to nanodegree coordinates.
 *
 * @param geojson - GeoJSON Polygon object or JSON string
 * @returns Tuple of [exterior, holes] where each is an array of [lat_nano, lon_nano]
 * @throws GeoFormatError if parsing fails
 */
export function parseGeoJSONPolygon(
  geojson: GeoJSONPolygon | string
): [Array<[bigint, bigint]>, Array<Array<[bigint, bigint]>>] {
  let obj: GeoJSONPolygon

  if (typeof geojson === 'string') {
    try {
      obj = JSON.parse(geojson)
    } catch (e) {
      throw new GeoFormatError(`Invalid JSON: ${e}`)
    }
  } else {
    obj = geojson
  }

  if (!obj || typeof obj !== 'object') {
    throw new GeoFormatError('GeoJSON must be an object')
  }

  if (obj.type !== 'Polygon') {
    throw new GeoFormatError(`Expected type 'Polygon', got '${obj.type}'`)
  }

  if (!Array.isArray(obj.coordinates) || obj.coordinates.length < 1) {
    throw new GeoFormatError('Polygon must have at least one ring')
  }

  function parseRing(ring: number[][]): Array<[bigint, bigint]> {
    if (!Array.isArray(ring) || ring.length < 3) {
      throw new GeoFormatError(`Ring must have at least 3 vertices, got ${ring?.length ?? 0}`)
    }

    return ring.map((point, i) => {
      if (!Array.isArray(point) || point.length < 2) {
        throw new GeoFormatError(`Point ${i} must have [lon, lat]`)
      }
      const [lon, lat] = point
      if (typeof lon !== 'number' || typeof lat !== 'number') {
        throw new GeoFormatError(`Point ${i} coordinates must be numbers`)
      }
      validateCoordinates(lat, lon)
      return [degreesToNano(lat), degreesToNano(lon)] as [bigint, bigint]
    })
  }

  const exterior = parseRing(obj.coordinates[0])
  const holes = obj.coordinates.slice(1).map(parseRing)

  return [exterior, holes]
}

/**
 * Parses a WKT POINT to nanodegree coordinates.
 *
 * @param wkt - WKT string like "POINT(lon lat)"
 * @returns Tuple of [lat_nano, lon_nano]
 * @throws GeoFormatError if parsing fails
 *
 * @example
 * ```typescript
 * const [lat, lon] = parseWKTPoint('POINT(-122.4194 37.7749)')
 * ```
 */
export function parseWKTPoint(wkt: string): [bigint, bigint] {
  const trimmed = wkt.trim()
  if (!trimmed.toUpperCase().startsWith('POINT')) {
    throw new GeoFormatError('Invalid WKT POINT: must start with POINT')
  }

  const openParen = trimmed.indexOf('(')
  const closeParen = trimmed.lastIndexOf(')')
  if (openParen === -1 || closeParen === -1 || openParen >= closeParen) {
    throw new GeoFormatError('Invalid WKT POINT: missing parentheses')
  }

  const content = trimmed.slice(openParen + 1, closeParen).trim()
  const parts = content.split(/\s+/)
  if (parts.length < 2) {
    throw new GeoFormatError('POINT must have lon lat coordinates')
  }

  const lon = parseFloat(parts[0])
  const lat = parseFloat(parts[1])
  if (isNaN(lon) || isNaN(lat)) {
    throw new GeoFormatError('Invalid WKT POINT coordinates')
  }

  validateCoordinates(lat, lon)

  return [degreesToNano(lat), degreesToNano(lon)]
}

/**
 * Parses a WKT POLYGON to nanodegree coordinates.
 *
 * @param wkt - WKT string like "POLYGON((lon lat, lon lat, ...))"
 * @returns Tuple of [exterior, holes]
 * @throws GeoFormatError if parsing fails
 */
export function parseWKTPolygon(
  wkt: string
): [Array<[bigint, bigint]>, Array<Array<[bigint, bigint]>>] {
  const trimmed = wkt.trim()
  if (!trimmed.toUpperCase().startsWith('POLYGON')) {
    throw new GeoFormatError('Invalid WKT POLYGON: must start with POLYGON')
  }

  const outerStart = trimmed.indexOf('(')
  const outerEnd = trimmed.lastIndexOf(')')
  if (outerStart === -1 || outerEnd === -1 || outerStart >= outerEnd) {
    throw new GeoFormatError('Invalid WKT POLYGON: missing parentheses')
  }

  const content = trimmed.slice(outerStart + 1, outerEnd)

  // Find matching parentheses for each ring
  const rings: string[] = []
  let depth = 0
  let ringStart = 0
  for (let i = 0; i < content.length; i++) {
    if (content[i] === '(') {
      if (depth === 0) ringStart = i
      depth++
    } else if (content[i] === ')') {
      depth--
      if (depth === 0) {
        rings.push(content.slice(ringStart, i + 1))
      }
    }
  }

  if (rings.length === 0) {
    throw new GeoFormatError('POLYGON must have at least one ring')
  }

  function parseRing(ring: string): Array<[bigint, bigint]> {
    const ringTrimmed = ring.trim()
    if (!ringTrimmed.startsWith('(') || !ringTrimmed.endsWith(')')) {
      throw new GeoFormatError('Ring must be enclosed in parentheses')
    }

    const ringContent = ringTrimmed.slice(1, -1)
    const points = ringContent.split(',')

    if (points.length < 3) {
      throw new GeoFormatError(`Ring must have at least 3 vertices, got ${points.length}`)
    }

    return points.map((point, i) => {
      const parts = point.trim().split(/\s+/)
      if (parts.length < 2) {
        throw new GeoFormatError(`Invalid point at index ${i}`)
      }
      const lon = parseFloat(parts[0])
      const lat = parseFloat(parts[1])
      if (isNaN(lon) || isNaN(lat)) {
        throw new GeoFormatError(`Invalid coordinates at point ${i}`)
      }
      validateCoordinates(lat, lon)
      return [degreesToNano(lat), degreesToNano(lon)] as [bigint, bigint]
    })
  }

  const exterior = parseRing(rings[0])
  const holes = rings.slice(1).map(parseRing)

  return [exterior, holes]
}

/**
 * Converts nanodegree coordinates to a GeoJSON Point.
 *
 * @param lat_nano - Latitude in nanodegrees
 * @param lon_nano - Longitude in nanodegrees
 * @returns GeoJSON Point object
 */
export function toGeoJSONPoint(lat_nano: bigint, lon_nano: bigint): GeoJSONPoint {
  return {
    type: 'Point',
    coordinates: [nanoToDegrees(lon_nano), nanoToDegrees(lat_nano)],
  }
}

/**
 * Converts nanodegree coordinates to a GeoJSON Polygon.
 *
 * @param exterior - Exterior ring as array of [lat_nano, lon_nano]
 * @param holes - Optional holes as arrays of [lat_nano, lon_nano]
 * @returns GeoJSON Polygon object
 */
export function toGeoJSONPolygon(
  exterior: Array<[bigint, bigint]>,
  holes?: Array<Array<[bigint, bigint]>>
): GeoJSONPolygon {
  function ringToCoords(ring: Array<[bigint, bigint]>): number[][] {
    return ring.map(([lat, lon]) => [nanoToDegrees(lon), nanoToDegrees(lat)])
  }

  const coordinates = [ringToCoords(exterior)]
  if (holes) {
    for (const hole of holes) {
      coordinates.push(ringToCoords(hole))
    }
  }

  return {
    type: 'Polygon',
    coordinates,
  }
}

/**
 * Converts nanodegree coordinates to a WKT POINT.
 *
 * @param lat_nano - Latitude in nanodegrees
 * @param lon_nano - Longitude in nanodegrees
 * @returns WKT POINT string
 */
export function toWKTPoint(lat_nano: bigint, lon_nano: bigint): string {
  return `POINT(${nanoToDegrees(lon_nano)} ${nanoToDegrees(lat_nano)})`
}

/**
 * Converts nanodegree coordinates to a WKT POLYGON.
 *
 * @param exterior - Exterior ring as array of [lat_nano, lon_nano]
 * @param holes - Optional holes as arrays of [lat_nano, lon_nano]
 * @returns WKT POLYGON string
 */
export function toWKTPolygon(
  exterior: Array<[bigint, bigint]>,
  holes?: Array<Array<[bigint, bigint]>>
): string {
  function ringToWKT(ring: Array<[bigint, bigint]>): string {
    const points = ring.map(([lat, lon]) =>
      `${nanoToDegrees(lon)} ${nanoToDegrees(lat)}`
    )
    return `(${points.join(', ')})`
  }

  const rings = [ringToWKT(exterior)]
  if (holes) {
    for (const hole of holes) {
      rings.push(ringToWKT(hole))
    }
  }

  return `POLYGON(${rings.join(', ')})`
}

/**
 * Validates that latitude and longitude are within bounds.
 *
 * @internal
 */
function validateCoordinates(lat: number, lon: number): void {
  if (lat < -LAT_MAX || lat > LAT_MAX) {
    throw new GeoFormatError(`Latitude ${lat} out of bounds [-90, 90]`)
  }
  if (lon < -LON_MAX || lon > LON_MAX) {
    throw new GeoFormatError(`Longitude ${lon} out of bounds [-180, 180]`)
  }
}

// ============================================================================
// Polygon Validation (per add-polygon-validation spec)
// Self-intersection detection for polygon queries
// ============================================================================

/**
 * Error indicating a polygon self-intersection.
 */
export class PolygonValidationError extends Error {
  /** Index of the first intersecting segment (0-based) */
  readonly segment1_index: number
  /** Index of the second intersecting segment (0-based) */
  readonly segment2_index: number
  /** Approximate intersection point [lat, lon] in degrees */
  readonly intersection_point: [number, number]
  /** Repair suggestions for fixing the self-intersection */
  readonly repair_suggestions: string[]

  constructor(
    message: string,
    segment1_index: number = -1,
    segment2_index: number = -1,
    intersection_point: [number, number] = [0, 0],
    repair_suggestions: string[] = [],
  ) {
    super(message)
    this.name = 'PolygonValidationError'
    this.segment1_index = segment1_index
    this.segment2_index = segment2_index
    this.intersection_point = intersection_point
    this.repair_suggestions = repair_suggestions
  }

  /** Get repair suggestions for fixing the self-intersection */
  getRepairSuggestions(): string[] {
    return this.repair_suggestions
  }
}

/**
 * Information about a detected self-intersection.
 */
export type IntersectionInfo = {
  /** Index of the first intersecting segment */
  segment1_index: number
  /** Index of the second intersecting segment */
  segment2_index: number
  /** Approximate intersection point [lat, lon] in degrees */
  intersection_point: [number, number]
}

/**
 * Checks if two line segments intersect.
 *
 * Uses the cross product method with proper handling of collinear cases.
 *
 * @param p1 - First segment start point [lat, lon]
 * @param p2 - First segment end point [lat, lon]
 * @param p3 - Second segment start point [lat, lon]
 * @param p4 - Second segment end point [lat, lon]
 * @returns true if the segments intersect, false otherwise
 */
export function segmentsIntersect(
  p1: [number, number],
  p2: [number, number],
  p3: [number, number],
  p4: [number, number],
): boolean {
  function crossProduct(
    o: [number, number],
    a: [number, number],
    b: [number, number],
  ): number {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
  }

  function onSegment(
    p: [number, number],
    q: [number, number],
    r: [number, number],
  ): boolean {
    return (
      q[0] >= Math.min(p[0], r[0]) && q[0] <= Math.max(p[0], r[0]) &&
      q[1] >= Math.min(p[1], r[1]) && q[1] <= Math.max(p[1], r[1])
    )
  }

  const d1 = crossProduct(p3, p4, p1)
  const d2 = crossProduct(p3, p4, p2)
  const d3 = crossProduct(p1, p2, p3)
  const d4 = crossProduct(p1, p2, p4)

  // General case: segments cross
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true
  }

  // Collinear cases
  const eps = 1e-10
  if (Math.abs(d1) < eps && onSegment(p3, p1, p4)) return true
  if (Math.abs(d2) < eps && onSegment(p3, p2, p4)) return true
  if (Math.abs(d3) < eps && onSegment(p1, p3, p2)) return true
  if (Math.abs(d4) < eps && onSegment(p1, p4, p2)) return true

  return false
}

/**
 * Validates that a polygon has no self-intersections.
 *
 * Uses an O(n²) algorithm suitable for polygons with reasonable vertex counts.
 * For very large polygons, consider using a sweep line algorithm.
 *
 * @param vertices - Array of [lat, lon] tuples in degrees
 * @param raiseOnError - If true, throws PolygonValidationError on first intersection
 * @returns Array of intersections found (empty if valid)
 * @throws PolygonValidationError if raiseOnError is true and polygon self-intersects
 *
 * @example
 * ```typescript
 * // Valid square
 * const square: [number, number][] = [[0, 0], [1, 0], [1, 1], [0, 1]]
 * const result = validatePolygonNoSelfIntersection(square)
 * // result is empty array
 *
 * // Self-intersecting bow-tie
 * const bowtie: [number, number][] = [[0, 0], [1, 1], [1, 0], [0, 1]]
 * // Throws PolygonValidationError with raiseOnError=true (default)
 * validatePolygonNoSelfIntersection(bowtie)
 * ```
 */
export function validatePolygonNoSelfIntersection(
  vertices: Array<[number, number]>,
  raiseOnError: boolean = true,
): IntersectionInfo[] {
  // A triangle cannot self-intersect (3 vertices = 3 edges, need at least 4 for crossing)
  if (vertices.length < 4) {
    return []
  }

  const intersections: IntersectionInfo[] = []
  const n = vertices.length

  // Check all pairs of non-adjacent edges
  for (let i = 0; i < n; i++) {
    const p1 = vertices[i]
    const p2 = vertices[(i + 1) % n]

    // Start from i+2 to skip adjacent edges (they share a vertex)
    for (let j = i + 2; j < n; j++) {
      // Skip if edges share a vertex (adjacent edges)
      if (j === (i + n - 1) % n) {
        continue
      }

      const p3 = vertices[j]
      const p4 = vertices[(j + 1) % n]

      if (segmentsIntersect(p1, p2, p3, p4)) {
        // Calculate approximate intersection point for error message
        const ix = (p1[0] + p2[0] + p3[0] + p4[0]) / 4
        const iy = (p1[1] + p2[1] + p3[1] + p4[1]) / 4
        const intersection: [number, number] = [ix, iy]

        if (raiseOnError) {
          // Generate repair suggestions
          const suggestions: string[] = []
          const v1_idx = (i + 1) % n
          const v2_idx = (j + 1) % n

          suggestions.push(
            `Try removing vertex ${v1_idx} at (${vertices[v1_idx][0].toFixed(6)}, ${vertices[v1_idx][1].toFixed(6)})`
          )
          suggestions.push(
            `Try removing vertex ${v2_idx} at (${vertices[v2_idx][0].toFixed(6)}, ${vertices[v2_idx][1].toFixed(6)})`
          )

          // Detect bow-tie pattern
          if (Math.abs(j - i) === 2) {
            suggestions.push(`Bow-tie pattern detected: try swapping vertices ${i + 1} and ${j}`)
          }

          suggestions.push('Ensure vertices are ordered consistently (clockwise or counter-clockwise)')

          throw new PolygonValidationError(
            `Polygon self-intersects: edge ${i}-${(i + 1) % n} crosses edge ${j}-${(j + 1) % n} near (${ix.toFixed(6)}, ${iy.toFixed(6)})`,
            i,
            j,
            intersection,
            suggestions,
          )
        }

        intersections.push({
          segment1_index: i,
          segment2_index: j,
          intersection_point: intersection,
        })
      }
    }
  }

  return intersections
}
