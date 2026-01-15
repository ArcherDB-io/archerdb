// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

//! The official ArcherDB client for Rust.
//!
//! ArcherDB is a high-performance geospatial database for real-time location tracking.
//! This client provides an async interface for inserting, querying, and managing
//! geospatial events.
//!
//! # Example
//!
//! ```no_run
//! use archerdb::{GeoClient, GeoEvent, GeoEventOptions};
//!
//! # async fn example() -> Result<(), Box<dyn std::error::Error>> {
//! // Connect to ArcherDB
//! let client = GeoClient::new(0, "127.0.0.1:3000")?;
//!
//! // Create a geospatial event
//! let event = GeoEvent::from_options(GeoEventOptions {
//!     entity_id: archerdb::id(),
//!     latitude: 37.7749,
//!     longitude: -122.4194,
//!     group_id: 1,
//!     ttl_seconds: 86400,
//!     ..Default::default()
//! })?;
//!
//! // Insert the event
//! let results = client.insert_events(&[event]).await?;
//! assert!(results.is_empty()); // Empty means success
//!
//! // Query events in a radius
//! let query = archerdb::RadiusQuery::new(37.7749, -122.4194, 1000.0, 100)?;
//! let result = client.query_radius(&query).await?;
//! println!("Found {} events", result.events.len());
//! # Ok(())
//! # }
//! ```

#![warn(missing_docs)]
#![allow(non_camel_case_types)]

mod arch_client;
mod conversions;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

pub use arch_client::{
    geo_event_t, insert_geo_events_result_t, query_radius_filter_t,
    query_polygon_filter_t, query_uuid_filter_t, query_latest_filter_t,
    GEO_EVENT_FLAGS, INSERT_GEO_EVENT_RESULT,
};

// ============================================================================
// Constants
// ============================================================================

/// Maximum latitude value in degrees
pub const LAT_MAX: f64 = 90.0;
/// Maximum longitude value in degrees
pub const LON_MAX: f64 = 180.0;
/// Nanodegrees per degree for coordinate conversion
pub const NANODEGREES_PER_DEGREE: i64 = 1_000_000_000;
/// Millimeters per meter for unit conversion
pub const MM_PER_METER: i64 = 1000;
/// Centidegrees per degree for heading conversion
pub const CENTIDEGREES_PER_DEGREE: i64 = 100;
/// Maximum events per batch
pub const BATCH_SIZE_MAX: usize = 10_000;
/// Maximum query result limit
pub const QUERY_LIMIT_MAX: usize = 81_000;
/// Maximum polygon vertices
pub const POLYGON_VERTICES_MAX: usize = 10_000;
/// Maximum polygon holes
pub const POLYGON_HOLES_MAX: usize = 100;
/// Minimum vertices per hole
pub const POLYGON_HOLE_VERTICES_MIN: usize = 3;

// ============================================================================
// GeoEvent Flags
// ============================================================================

bitflags::bitflags! {
    /// Flags for GeoEvent status.
    #[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
    pub struct GeoEventFlags: u16 {
        /// Event is part of a linked chain
        const LINKED = 1 << 0;
        /// Event was imported with client-provided timestamp
        const IMPORTED = 1 << 1;
        /// Entity is stationary (not moving)
        const STATIONARY = 1 << 2;
        /// GPS accuracy below threshold
        const LOW_ACCURACY = 1 << 3;
        /// Entity is offline/unreachable
        const OFFLINE = 1 << 4;
        /// Entity has been deleted (GDPR compliance)
        const DELETED = 1 << 5;
    }
}

// ============================================================================
// Result Codes
// ============================================================================

/// Result codes for GeoEvent insert operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum InsertGeoEventResult {
    /// Operation succeeded
    Ok = 0,
    /// Linked event in chain failed
    LinkedEventFailed = 1,
    /// Linked event chain left open
    LinkedEventChainOpen = 2,
    /// Timestamp must be zero for non-imported events
    TimestampMustBeZero = 3,
    /// Reserved field must be zero
    ReservedField = 4,
    /// Reserved flag must be zero
    ReservedFlag = 5,
    /// Event ID must not be zero
    IdMustNotBeZero = 6,
    /// Entity ID must not be zero
    EntityIdMustNotBeZero = 7,
    /// Coordinates are invalid
    InvalidCoordinates = 8,
    /// Latitude out of range
    LatOutOfRange = 9,
    /// Longitude out of range
    LonOutOfRange = 10,
    /// Event exists with different entity ID
    ExistsWithDifferentEntityId = 11,
    /// Event exists with different coordinates
    ExistsWithDifferentCoordinates = 12,
    /// Event already exists
    Exists = 13,
    /// Heading value out of range
    HeadingOutOfRange = 14,
    /// TTL value is invalid
    TtlInvalid = 15,
    /// Entity ID must not be INT_MAX
    EntityIdMustNotBeIntMax = 16,
}


/// Result codes for TTL operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TtlOperationResult {
    /// Operation succeeded
    Success = 0,
    /// Entity not found
    EntityNotFound = 1,
    /// Invalid TTL value
    InvalidTtl = 2,
    /// Operation not permitted
    NotPermitted = 3,
    /// Entity is immutable
    EntityImmutable = 4,
}

impl From<u8> for TtlOperationResult {
    fn from(value: u8) -> Self {
        match value {
            0 => TtlOperationResult::Success,
            1 => TtlOperationResult::EntityNotFound,
            2 => TtlOperationResult::InvalidTtl,
            3 => TtlOperationResult::NotPermitted,
            4 => TtlOperationResult::EntityImmutable,
            _ => TtlOperationResult::Success,
        }
    }
}

// ============================================================================
// GeoEvent
// ============================================================================

/// A 128-byte geospatial event record.
///
/// This is the core data structure for location tracking in ArcherDB.
/// Coordinates are stored in nanodegrees (10^-9 degrees) for sub-millimeter precision.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct GeoEvent {
    /// Composite key: [S2 Cell ID (upper 64) | Timestamp (lower 64)]
    pub id: u128,
    /// UUID identifying the moving entity (vehicle, device, person)
    pub entity_id: u128,
    /// UUID for trip/session/job correlation across events
    pub correlation_id: u128,
    /// Opaque application metadata
    pub user_data: u128,
    /// Latitude in nanodegrees (10^-9 degrees)
    pub lat_nano: i64,
    /// Longitude in nanodegrees (10^-9 degrees)
    pub lon_nano: i64,
    /// Fleet/region grouping identifier
    pub group_id: u64,
    /// Event timestamp in nanoseconds since Unix epoch
    pub timestamp: u64,
    /// Altitude in millimeters above WGS84 ellipsoid
    pub altitude_mm: i32,
    /// Speed in millimeters per second
    pub velocity_mms: u32,
    /// Time-to-live in seconds (0 = never expires)
    pub ttl_seconds: u32,
    /// GPS accuracy radius in millimeters
    pub accuracy_mm: u32,
    /// Heading in centidegrees (0-36000, where 0=North, 9000=East)
    pub heading_cdeg: u16,
    /// Status flags
    pub flags: GeoEventFlags,
    /// Reserved for future use (must be zero)
    pub reserved: [u8; 12],
}

impl GeoEvent {
    /// Creates a GeoEvent from user-friendly options.
    pub fn from_options(opts: GeoEventOptions) -> Result<Self, GeoError> {
        if !is_valid_latitude(opts.latitude) {
            return Err(GeoError::InvalidLatitude(opts.latitude));
        }
        if !is_valid_longitude(opts.longitude) {
            return Err(GeoError::InvalidLongitude(opts.longitude));
        }

        Ok(GeoEvent {
            id: 0,
            entity_id: opts.entity_id,
            correlation_id: opts.correlation_id,
            user_data: opts.user_data,
            lat_nano: degrees_to_nano(opts.latitude),
            lon_nano: degrees_to_nano(opts.longitude),
            group_id: opts.group_id,
            timestamp: 0,
            altitude_mm: meters_to_mm(opts.altitude_m),
            velocity_mms: (opts.velocity_mps * MM_PER_METER as f64).round() as u32,
            ttl_seconds: opts.ttl_seconds,
            accuracy_mm: (opts.accuracy_m * MM_PER_METER as f64).round() as u32,
            heading_cdeg: heading_to_centidegrees(opts.heading),
            flags: opts.flags,
            reserved: [0; 12],
        })
    }

    /// Returns the latitude in degrees.
    pub fn latitude(&self) -> f64 {
        nano_to_degrees(self.lat_nano)
    }

    /// Returns the longitude in degrees.
    pub fn longitude(&self) -> f64 {
        nano_to_degrees(self.lon_nano)
    }

    /// Returns the heading in degrees.
    pub fn heading(&self) -> f64 {
        centidegrees_to_heading(self.heading_cdeg)
    }

    /// Returns the altitude in meters.
    pub fn altitude(&self) -> f64 {
        mm_to_meters(self.altitude_mm)
    }

    /// Prepares the event for submission by computing the composite ID.
    pub fn prepare(&mut self) {
        if self.id == 0 {
            let s2_cell_id = compute_s2_cell_id(self.lat_nano, self.lon_nano);
            let timestamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64;
            self.id = pack_composite_id(s2_cell_id, timestamp);
            self.timestamp = 0;
        }
    }
}

/// Options for creating a GeoEvent with user-friendly units.
#[derive(Debug, Clone, Default)]
pub struct GeoEventOptions {
    /// Entity UUID
    pub entity_id: u128,
    /// Latitude in degrees (-90 to +90)
    pub latitude: f64,
    /// Longitude in degrees (-180 to +180)
    pub longitude: f64,
    /// Correlation UUID
    pub correlation_id: u128,
    /// User data
    pub user_data: u128,
    /// Group ID
    pub group_id: u64,
    /// Altitude in meters
    pub altitude_m: f64,
    /// Velocity in meters per second
    pub velocity_mps: f64,
    /// TTL in seconds
    pub ttl_seconds: u32,
    /// Accuracy in meters
    pub accuracy_m: f64,
    /// Heading in degrees (0-360)
    pub heading: f64,
    /// Event flags
    pub flags: GeoEventFlags,
}

// ============================================================================
// Query Types
// ============================================================================

/// Filter for radius queries.
#[derive(Debug, Clone, Default)]
pub struct RadiusQuery {
    /// Center latitude in nanodegrees
    pub center_lat_nano: i64,
    /// Center longitude in nanodegrees
    pub center_lon_nano: i64,
    /// Radius in millimeters
    pub radius_mm: u32,
    /// Maximum results to return
    pub limit: u32,
    /// Minimum timestamp filter
    pub timestamp_min: u64,
    /// Maximum timestamp filter
    pub timestamp_max: u64,
    /// Group ID filter
    pub group_id: u64,
}

impl RadiusQuery {
    /// Creates a new RadiusQuery from user-friendly units.
    pub fn new(latitude: f64, longitude: f64, radius_m: f64, limit: u32) -> Result<Self, GeoError> {
        if !is_valid_latitude(latitude) {
            return Err(GeoError::InvalidLatitude(latitude));
        }
        if !is_valid_longitude(longitude) {
            return Err(GeoError::InvalidLongitude(longitude));
        }
        if radius_m <= 0.0 {
            return Err(GeoError::InvalidRadius(radius_m));
        }

        Ok(RadiusQuery {
            center_lat_nano: degrees_to_nano(latitude),
            center_lon_nano: degrees_to_nano(longitude),
            radius_mm: (radius_m * MM_PER_METER as f64).round() as u32,
            limit,
            timestamp_min: 0,
            timestamp_max: u64::MAX,
            group_id: 0,
        })
    }

    /// Sets the time range filter.
    pub fn with_time_range(mut self, min: u64, max: u64) -> Self {
        self.timestamp_min = min;
        self.timestamp_max = max;
        self
    }

    /// Sets the group ID filter.
    pub fn with_group(mut self, group_id: u64) -> Self {
        self.group_id = group_id;
        self
    }
}

/// A polygon vertex (lat/lon pair).
#[derive(Debug, Clone, Copy, Default)]
pub struct PolygonVertex {
    /// Latitude in nanodegrees
    pub lat_nano: i64,
    /// Longitude in nanodegrees
    pub lon_nano: i64,
}

impl PolygonVertex {
    /// Creates a vertex from degrees.
    pub fn from_degrees(latitude: f64, longitude: f64) -> Result<Self, GeoError> {
        if !is_valid_latitude(latitude) {
            return Err(GeoError::InvalidLatitude(latitude));
        }
        if !is_valid_longitude(longitude) {
            return Err(GeoError::InvalidLongitude(longitude));
        }
        Ok(PolygonVertex {
            lat_nano: degrees_to_nano(latitude),
            lon_nano: degrees_to_nano(longitude),
        })
    }
}

/// A polygon hole (exclusion zone).
#[derive(Debug, Clone, Default)]
pub struct PolygonHole {
    /// Vertices defining the hole boundary
    pub vertices: Vec<PolygonVertex>,
}

/// Filter for polygon queries.
#[derive(Debug, Clone, Default)]
pub struct PolygonQuery {
    /// Outer boundary vertices (CCW winding order)
    pub vertices: Vec<PolygonVertex>,
    /// Interior holes (CW winding order)
    pub holes: Vec<PolygonHole>,
    /// Maximum results to return
    pub limit: u32,
    /// Minimum timestamp filter
    pub timestamp_min: u64,
    /// Maximum timestamp filter
    pub timestamp_max: u64,
    /// Group ID filter
    pub group_id: u64,
}

impl PolygonQuery {
    /// Creates a new PolygonQuery from vertices in degrees.
    pub fn new(vertices: &[[f64; 2]], limit: u32) -> Result<Self, GeoError> {
        if vertices.len() < 3 {
            return Err(GeoError::InvalidPolygon("polygon must have at least 3 vertices".into()));
        }
        if vertices.len() > POLYGON_VERTICES_MAX {
            return Err(GeoError::InvalidPolygon(format!(
                "polygon exceeds maximum {} vertices",
                POLYGON_VERTICES_MAX
            )));
        }

        let poly_vertices: Result<Vec<_>, _> = vertices
            .iter()
            .map(|v| PolygonVertex::from_degrees(v[0], v[1]))
            .collect();

        Ok(PolygonQuery {
            vertices: poly_vertices?,
            holes: Vec::new(),
            limit,
            timestamp_min: 0,
            timestamp_max: u64::MAX,
            group_id: 0,
        })
    }

    /// Adds a hole to the polygon query.
    pub fn with_hole(mut self, hole_vertices: &[[f64; 2]]) -> Result<Self, GeoError> {
        if hole_vertices.len() < POLYGON_HOLE_VERTICES_MIN {
            return Err(GeoError::InvalidPolygon(format!(
                "hole must have at least {} vertices",
                POLYGON_HOLE_VERTICES_MIN
            )));
        }
        if self.holes.len() >= POLYGON_HOLES_MAX {
            return Err(GeoError::InvalidPolygon(format!(
                "exceeds maximum {} holes",
                POLYGON_HOLES_MAX
            )));
        }

        let vertices: Result<Vec<_>, _> = hole_vertices
            .iter()
            .map(|v| PolygonVertex::from_degrees(v[0], v[1]))
            .collect();

        self.holes.push(PolygonHole { vertices: vertices? });
        Ok(self)
    }

    /// Sets the time range filter.
    pub fn with_time_range(mut self, min: u64, max: u64) -> Self {
        self.timestamp_min = min;
        self.timestamp_max = max;
        self
    }

    /// Sets the group ID filter.
    pub fn with_group(mut self, group_id: u64) -> Self {
        self.group_id = group_id;
        self
    }
}

/// Filter for query_latest operations.
#[derive(Debug, Clone, Default)]
pub struct LatestQuery {
    /// Maximum results to return
    pub limit: u32,
    /// Group ID filter
    pub group_id: u64,
    /// Cursor timestamp for pagination
    pub cursor_timestamp: u64,
}

impl LatestQuery {
    /// Creates a new LatestQuery.
    pub fn new(limit: u32) -> Self {
        LatestQuery {
            limit,
            group_id: 0,
            cursor_timestamp: 0,
        }
    }

    /// Sets the group ID filter.
    pub fn with_group(mut self, group_id: u64) -> Self {
        self.group_id = group_id;
        self
    }

    /// Sets the cursor for pagination.
    pub fn with_cursor(mut self, cursor: u64) -> Self {
        self.cursor_timestamp = cursor;
        self
    }
}

// ============================================================================
// Response Types
// ============================================================================

/// Result of a query operation.
#[derive(Debug, Clone, Default)]
pub struct QueryResult {
    /// Events matching the query
    pub events: Vec<GeoEvent>,
    /// Whether more results are available
    pub has_more: bool,
    /// Cursor for pagination (timestamp of last event)
    pub cursor: u64,
}

/// Error from an insert operation.
#[derive(Debug, Clone)]
pub struct InsertError {
    /// Index of the event in the batch
    pub index: u32,
    /// Result code
    pub result: InsertGeoEventResult,
}

/// Result of a delete operation.
#[derive(Debug, Clone, Default)]
pub struct DeleteResult {
    /// Number of entities deleted
    pub deleted_count: usize,
    /// Number of entities not found
    pub not_found_count: usize,
}

/// Response from TTL set operation.
#[derive(Debug, Clone)]
pub struct TtlSetResponse {
    /// Entity ID
    pub entity_id: u128,
    /// Previous TTL in seconds
    pub previous_ttl_seconds: u32,
    /// New TTL in seconds
    pub new_ttl_seconds: u32,
    /// Operation result
    pub result: TtlOperationResult,
}

/// Response from TTL extend operation.
#[derive(Debug, Clone)]
pub struct TtlExtendResponse {
    /// Entity ID
    pub entity_id: u128,
    /// Previous TTL in seconds
    pub previous_ttl_seconds: u32,
    /// New TTL in seconds
    pub new_ttl_seconds: u32,
    /// Operation result
    pub result: TtlOperationResult,
}

/// Response from TTL clear operation.
#[derive(Debug, Clone)]
pub struct TtlClearResponse {
    /// Entity ID
    pub entity_id: u128,
    /// Previous TTL in seconds
    pub previous_ttl_seconds: u32,
    /// Operation result
    pub result: TtlOperationResult,
}

/// Server status response.
#[derive(Debug, Clone, Default)]
pub struct StatusResponse {
    /// Number of entities in RAM index
    pub ram_index_count: u64,
    /// Total RAM index capacity
    pub ram_index_capacity: u64,
    /// Load factor as percentage * 100
    pub ram_index_load_pct: u32,
    /// Number of tombstone entries
    pub tombstone_count: u64,
    /// Total TTL expirations processed
    pub ttl_expirations: u64,
    /// Total deletions processed
    pub deletion_count: u64,
}

impl StatusResponse {
    /// Returns the load factor as a decimal (e.g., 0.70).
    pub fn load_factor(&self) -> f64 {
        self.ram_index_load_pct as f64 / 10000.0
    }
}

// ============================================================================
// Errors
// ============================================================================

/// Errors that can occur in ArcherDB operations.
#[derive(Debug, Clone)]
pub enum GeoError {
    /// Invalid latitude value
    InvalidLatitude(f64),
    /// Invalid longitude value
    InvalidLongitude(f64),
    /// Invalid radius value
    InvalidRadius(f64),
    /// Invalid polygon
    InvalidPolygon(String),
    /// Connection error
    Connection(String),
    /// Request timeout
    Timeout,
    /// Server error
    Server(String),
}

impl std::fmt::Display for GeoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GeoError::InvalidLatitude(lat) => write!(f, "invalid latitude: {}, must be between -90 and +90", lat),
            GeoError::InvalidLongitude(lon) => write!(f, "invalid longitude: {}, must be between -180 and +180", lon),
            GeoError::InvalidRadius(r) => write!(f, "invalid radius: {}, must be positive", r),
            GeoError::InvalidPolygon(msg) => write!(f, "invalid polygon: {}", msg),
            GeoError::Connection(msg) => write!(f, "connection error: {}", msg),
            GeoError::Timeout => write!(f, "request timeout"),
            GeoError::Server(msg) => write!(f, "server error: {}", msg),
        }
    }
}

impl std::error::Error for GeoError {}

// ============================================================================
// Coordinate Conversion Helpers
// ============================================================================

/// Converts degrees to nanodegrees.
pub fn degrees_to_nano(degrees: f64) -> i64 {
    (degrees * NANODEGREES_PER_DEGREE as f64).round() as i64
}

/// Converts nanodegrees to degrees.
pub fn nano_to_degrees(nano: i64) -> f64 {
    nano as f64 / NANODEGREES_PER_DEGREE as f64
}

/// Converts meters to millimeters.
pub fn meters_to_mm(meters: f64) -> i32 {
    (meters * MM_PER_METER as f64).round() as i32
}

/// Converts millimeters to meters.
pub fn mm_to_meters(mm: i32) -> f64 {
    mm as f64 / MM_PER_METER as f64
}

/// Converts heading from degrees to centidegrees.
pub fn heading_to_centidegrees(degrees: f64) -> u16 {
    (degrees * CENTIDEGREES_PER_DEGREE as f64).round() as u16
}

/// Converts heading from centidegrees to degrees.
pub fn centidegrees_to_heading(cdeg: u16) -> f64 {
    cdeg as f64 / CENTIDEGREES_PER_DEGREE as f64
}

/// Checks if latitude is in valid range.
pub fn is_valid_latitude(lat: f64) -> bool {
    lat >= -LAT_MAX && lat <= LAT_MAX
}

/// Checks if longitude is in valid range.
pub fn is_valid_longitude(lon: f64) -> bool {
    lon >= -LON_MAX && lon <= LON_MAX
}

// ============================================================================
// S2 Cell ID Computation
// ============================================================================

const S2_LEVEL: u32 = 30;

/// Computes an S2 cell ID from latitude/longitude in nanodegrees.
pub fn compute_s2_cell_id(lat_nano: i64, lon_nano: i64) -> u64 {
    use std::f64::consts::PI;

    // Convert to radians
    let lat = (lat_nano as f64) / 1e9 * PI / 180.0;
    let lon = (lon_nano as f64) / 1e9 * PI / 180.0;

    // Convert to S2 point (unit sphere)
    let cos_lat = lat.cos();
    let x = cos_lat * lon.cos();
    let y = cos_lat * lon.sin();
    let z = lat.sin();

    // Determine face (0-5) based on largest absolute coordinate
    let ax = x.abs();
    let ay = y.abs();
    let az = z.abs();

    let (face, u, v) = if ax >= ay && ax >= az {
        if x > 0.0 {
            (0, y / x, z / x)
        } else {
            (3, -y / x, z / -x)
        }
    } else if ay >= ax && ay >= az {
        if y > 0.0 {
            (1, -x / y, z / y)
        } else {
            (4, x / -y, z / -y)
        }
    } else if z > 0.0 {
        (2, -x / z, -y / z)
    } else {
        (5, -x / -z, y / -z)
    };

    // Apply quadratic transform
    let s = uv_to_st(u);
    let t = uv_to_st(v);

    // Convert to integer coordinates
    let scale = (1u64 << S2_LEVEL) as f64;
    let i = (s * scale) as u64;
    let j = (t * scale) as u64;

    // Clamp to valid range
    let max_ij = (1u64 << S2_LEVEL) - 1;
    let i = i.min(max_ij);
    let j = j.min(max_ij);

    // Interleave bits to form position
    let pos = interleave(i, j);

    // Construct cell ID: face (3 bits) | position | sentinel bit
    (face as u64) << 61 | pos << 1 | 1
}

fn uv_to_st(u: f64) -> f64 {
    if u >= 0.0 {
        0.5 * (1.0 + 3.0 * u).sqrt()
    } else {
        1.0 - 0.5 * (1.0 - 3.0 * u).sqrt()
    }
}

fn interleave(i: u64, j: u64) -> u64 {
    let mut result = 0u64;
    for bit in 0..30 {
        result |= ((i >> bit) & 1) << (2 * bit + 1);
        result |= ((j >> bit) & 1) << (2 * bit);
    }
    result
}

/// Packs S2 cell ID and timestamp into a composite ID.
pub fn pack_composite_id(s2_cell_id: u64, timestamp: u64) -> u128 {
    ((s2_cell_id as u128) << 64) | (timestamp as u128)
}

// ============================================================================
// ID Generation
// ============================================================================

/// Generates a sortable UUID.
///
/// Uses timestamp-based ID generation similar to UUIDv7.
pub fn id() -> u128 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as u64;

    let counter = COUNTER.fetch_add(1, Ordering::SeqCst);
    ((timestamp as u128) << 64) | (counter as u128)
}

// ============================================================================
// GeoClient (Placeholder - requires native integration)
// ============================================================================

/// ArcherDB geospatial client.
///
/// Note: This is a placeholder implementation. The actual client requires
/// integration with the native arch_client library.
pub struct GeoClient {
    cluster_id: u128,
    addresses: Vec<String>,
}

impl GeoClient {
    /// Creates a new GeoClient.
    pub fn new(cluster_id: u128, addresses: &str) -> Result<Self, GeoError> {
        Ok(GeoClient {
            cluster_id,
            addresses: addresses.split(',').map(|s| s.trim().to_string()).collect(),
        })
    }

    /// Inserts geospatial events.
    pub async fn insert_events(&self, events: &[GeoEvent]) -> Result<Vec<InsertError>, GeoError> {
        // Placeholder - actual implementation requires native client
        let _ = (self.cluster_id, &self.addresses, events);
        Ok(Vec::new())
    }

    /// Upserts geospatial events.
    pub async fn upsert_events(&self, events: &[GeoEvent]) -> Result<Vec<InsertError>, GeoError> {
        let _ = events;
        Ok(Vec::new())
    }

    /// Deletes entities by ID.
    pub async fn delete_entities(&self, entity_ids: &[u128]) -> Result<DeleteResult, GeoError> {
        let _ = entity_ids;
        Ok(DeleteResult::default())
    }

    /// Gets the latest event for an entity.
    pub async fn get_latest_by_uuid(&self, entity_id: u128) -> Result<Option<GeoEvent>, GeoError> {
        let _ = entity_id;
        Ok(None)
    }

    /// Queries events within a radius.
    pub async fn query_radius(&self, query: &RadiusQuery) -> Result<QueryResult, GeoError> {
        let _ = query;
        Ok(QueryResult::default())
    }

    /// Queries events within a polygon.
    pub async fn query_polygon(&self, query: &PolygonQuery) -> Result<QueryResult, GeoError> {
        let _ = query;
        Ok(QueryResult::default())
    }

    /// Queries the latest events.
    pub async fn query_latest(&self, query: &LatestQuery) -> Result<QueryResult, GeoError> {
        let _ = query;
        Ok(QueryResult::default())
    }

    /// Sets the TTL for an entity.
    pub async fn set_ttl(&self, entity_id: u128, ttl_seconds: u32) -> Result<TtlSetResponse, GeoError> {
        Ok(TtlSetResponse {
            entity_id,
            previous_ttl_seconds: 0,
            new_ttl_seconds: ttl_seconds,
            result: TtlOperationResult::Success,
        })
    }

    /// Extends the TTL for an entity.
    pub async fn extend_ttl(&self, entity_id: u128, extend_by_seconds: u32) -> Result<TtlExtendResponse, GeoError> {
        Ok(TtlExtendResponse {
            entity_id,
            previous_ttl_seconds: 0,
            new_ttl_seconds: extend_by_seconds,
            result: TtlOperationResult::Success,
        })
    }

    /// Clears the TTL for an entity.
    pub async fn clear_ttl(&self, entity_id: u128) -> Result<TtlClearResponse, GeoError> {
        Ok(TtlClearResponse {
            entity_id,
            previous_ttl_seconds: 0,
            result: TtlOperationResult::Success,
        })
    }

    /// Pings the server.
    pub async fn ping(&self) -> Result<bool, GeoError> {
        Ok(true)
    }

    /// Gets server status.
    pub async fn get_status(&self) -> Result<StatusResponse, GeoError> {
        Ok(StatusResponse::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_degrees_to_nano() {
        assert_eq!(degrees_to_nano(37.7749), 37_774_900_000);
        assert_eq!(degrees_to_nano(-122.4194), -122_419_400_000);
    }

    #[test]
    fn test_nano_to_degrees() {
        assert!((nano_to_degrees(37_774_900_000) - 37.7749).abs() < 1e-9);
        assert!((nano_to_degrees(-122_419_400_000) - (-122.4194)).abs() < 1e-9);
    }

    #[test]
    fn test_is_valid_latitude() {
        assert!(is_valid_latitude(0.0));
        assert!(is_valid_latitude(90.0));
        assert!(is_valid_latitude(-90.0));
        assert!(!is_valid_latitude(90.1));
        assert!(!is_valid_latitude(-90.1));
    }

    #[test]
    fn test_is_valid_longitude() {
        assert!(is_valid_longitude(0.0));
        assert!(is_valid_longitude(180.0));
        assert!(is_valid_longitude(-180.0));
        assert!(!is_valid_longitude(180.1));
        assert!(!is_valid_longitude(-180.1));
    }

    #[test]
    fn test_geo_event_from_options() {
        let event = GeoEvent::from_options(GeoEventOptions {
            entity_id: 12345,
            latitude: 37.7749,
            longitude: -122.4194,
            group_id: 1,
            ttl_seconds: 86400,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(event.entity_id, 12345);
        assert_eq!(event.lat_nano, 37_774_900_000);
        assert_eq!(event.lon_nano, -122_419_400_000);
        assert_eq!(event.group_id, 1);
        assert_eq!(event.ttl_seconds, 86400);
    }

    #[test]
    fn test_geo_event_invalid_latitude() {
        let result = GeoEvent::from_options(GeoEventOptions {
            latitude: 91.0,
            longitude: 0.0,
            ..Default::default()
        });
        assert!(matches!(result, Err(GeoError::InvalidLatitude(_))));
    }

    #[test]
    fn test_geo_event_invalid_longitude() {
        let result = GeoEvent::from_options(GeoEventOptions {
            latitude: 0.0,
            longitude: 181.0,
            ..Default::default()
        });
        assert!(matches!(result, Err(GeoError::InvalidLongitude(_))));
    }

    #[test]
    fn test_radius_query_new() {
        let query = RadiusQuery::new(37.7749, -122.4194, 1000.0, 100).unwrap();
        assert_eq!(query.center_lat_nano, 37_774_900_000);
        assert_eq!(query.center_lon_nano, -122_419_400_000);
        assert_eq!(query.radius_mm, 1_000_000);
        assert_eq!(query.limit, 100);
    }

    #[test]
    fn test_polygon_query_new() {
        let vertices = vec![
            [37.7749, -122.4194],
            [37.7850, -122.4094],
            [37.7650, -122.4094],
        ];
        let query = PolygonQuery::new(&vertices, 100).unwrap();
        assert_eq!(query.vertices.len(), 3);
        assert_eq!(query.limit, 100);
    }

    #[test]
    fn test_polygon_query_with_hole() {
        let vertices = vec![
            [37.7749, -122.4194],
            [37.7850, -122.4094],
            [37.7650, -122.4094],
        ];
        let hole = vec![
            [37.7700, -122.4150],
            [37.7750, -122.4100],
            [37.7650, -122.4100],
        ];
        let query = PolygonQuery::new(&vertices, 100)
            .unwrap()
            .with_hole(&hole)
            .unwrap();
        assert_eq!(query.vertices.len(), 3);
        assert_eq!(query.holes.len(), 1);
        assert_eq!(query.holes[0].vertices.len(), 3);
    }

    #[test]
    fn test_s2_cell_id_computation() {
        let cell_id = compute_s2_cell_id(37_774_900_000, -122_419_400_000);
        assert!(cell_id > 0);
    }

    #[test]
    fn test_id_generation() {
        let id1 = id();
        let id2 = id();
        assert_ne!(id1, id2);
        assert!(id2 > id1); // Should be monotonically increasing
    }

    #[test]
    fn test_geo_event_size() {
        assert_eq!(std::mem::size_of::<GeoEvent>(), 128);
    }

    #[test]
    fn test_insert_result_conversion() {
        assert_eq!(InsertGeoEventResult::from(0), InsertGeoEventResult::Ok);
        assert_eq!(InsertGeoEventResult::from(1), InsertGeoEventResult::LinkedEventFailed);
        assert_eq!(InsertGeoEventResult::from(8), InsertGeoEventResult::InvalidCoordinates);
    }

    #[test]
    fn test_ttl_result_conversion() {
        assert_eq!(TtlOperationResult::from(0), TtlOperationResult::Success);
        assert_eq!(TtlOperationResult::from(1), TtlOperationResult::EntityNotFound);
    }

    #[test]
    fn test_geo_event_flags() {
        let flags = GeoEventFlags::LINKED | GeoEventFlags::STATIONARY;
        assert!(flags.contains(GeoEventFlags::LINKED));
        assert!(flags.contains(GeoEventFlags::STATIONARY));
        assert!(!flags.contains(GeoEventFlags::OFFLINE));
    }

    #[test]
    fn test_status_response_load_factor() {
        let status = StatusResponse {
            ram_index_load_pct: 7000,
            ..Default::default()
        };
        assert!((status.load_factor() - 0.7).abs() < 1e-9);
    }
}
