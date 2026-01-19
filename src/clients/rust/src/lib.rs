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

/// Geo-routing support for multi-region deployments.
pub mod geo_routing;

use std::collections::HashMap;
use std::mem;
use std::os::raw::{c_char, c_void};
use std::pin::Pin;
use std::slice;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use futures_channel::oneshot;

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
/// Maximum UUIDs per batch UUID lookup
pub const QUERY_UUID_BATCH_MAX: usize = 10_000;
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

/// Result of a batch UUID lookup.
#[derive(Debug, Clone, Default)]
pub struct QueryUuidBatchResult {
    /// Number of entities found
    pub found_count: u32,
    /// Number of entities not found
    pub not_found_count: u32,
    /// Indices of missing entity IDs in the input slice
    pub not_found_indices: Vec<u16>,
    /// Events for found entities (ordered by input slice, excluding missing)
    pub events: Vec<GeoEvent>,
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
// GeoClient
// ============================================================================

#[repr(C)]
#[derive(Clone, Copy)]
struct HoleDescriptor {
    vertex_count: u32,
    reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct TtlSetRequestRaw {
    entity_id: u128,
    ttl_seconds: u32,
    flags: u32,
    reserved: [u8; 40],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct TtlSetResponseRaw {
    entity_id: u128,
    previous_ttl_seconds: u32,
    new_ttl_seconds: u32,
    result: u8,
    _padding: [u8; 3],
    reserved: [u8; 32],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct TtlExtendRequestRaw {
    entity_id: u128,
    extend_by_seconds: u32,
    flags: u32,
    reserved: [u8; 40],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct TtlExtendResponseRaw {
    entity_id: u128,
    previous_ttl_seconds: u32,
    new_ttl_seconds: u32,
    result: u8,
    _padding: [u8; 3],
    reserved: [u8; 32],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct TtlClearRequestRaw {
    entity_id: u128,
    flags: u32,
    reserved: [u8; 44],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct TtlClearResponseRaw {
    entity_id: u128,
    previous_ttl_seconds: u32,
    result: u8,
    _padding: [u8; 3],
    reserved: [u8; 36],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct StatusResponseRaw {
    ram_index_count: u64,
    ram_index_capacity: u64,
    ram_index_load_pct: u32,
    _padding: u32,
    tombstone_count: u64,
    ttl_expirations: u64,
    deletion_count: u64,
    reserved: [u8; 16],
}

struct AlignedBytes {
    storage: Vec<u128>,
    len: usize,
}

impl AlignedBytes {
    fn new(len: usize) -> Self {
        let words = if len == 0 { 0 } else { (len + 15) / 16 };
        AlignedBytes {
            storage: vec![0u128; words],
            len,
        }
    }

    #[cfg(test)]
    fn as_slice(&self) -> &[u8] {
        unsafe { slice::from_raw_parts(self.storage.as_ptr() as *const u8, self.len) }
    }

    fn as_mut_slice(&mut self) -> &mut [u8] {
        unsafe { slice::from_raw_parts_mut(self.storage.as_mut_ptr() as *mut u8, self.len) }
    }

    fn ptr(&self) -> *mut c_void {
        if self.len == 0 {
            std::ptr::null_mut()
        } else {
            self.storage.as_ptr() as *mut c_void
        }
    }

    fn len(&self) -> usize {
        self.len
    }
}

enum RequestData {
    Bytes(AlignedBytes),
    GeoEvents(Vec<arch_client::geo_event_t>),
    U128(Vec<u128>),
    QueryRadius(Box<arch_client::query_radius_filter_t>),
    QueryLatest(Box<arch_client::query_latest_filter_t>),
    QueryUuid(Box<arch_client::query_uuid_filter_t>),
    TtlSet(Box<TtlSetRequestRaw>),
    TtlExtend(Box<TtlExtendRequestRaw>),
    TtlClear(Box<TtlClearRequestRaw>),
}

impl RequestData {
    fn data_ptr(&self) -> *mut c_void {
        match self {
            RequestData::Bytes(bytes) => bytes.ptr(),
            RequestData::GeoEvents(events) => {
                if events.is_empty() {
                    std::ptr::null_mut()
                } else {
                    events.as_ptr() as *mut c_void
                }
            }
            RequestData::U128(ids) => {
                if ids.is_empty() {
                    std::ptr::null_mut()
                } else {
                    ids.as_ptr() as *mut c_void
                }
            }
            RequestData::QueryRadius(filter) => &**filter as *const _ as *mut c_void,
            RequestData::QueryLatest(filter) => &**filter as *const _ as *mut c_void,
            RequestData::QueryUuid(filter) => &**filter as *const _ as *mut c_void,
            RequestData::TtlSet(request) => &**request as *const _ as *mut c_void,
            RequestData::TtlExtend(request) => &**request as *const _ as *mut c_void,
            RequestData::TtlClear(request) => &**request as *const _ as *mut c_void,
        }
    }

    fn data_len(&self) -> u32 {
        match self {
            RequestData::Bytes(bytes) => bytes.len() as u32,
            RequestData::GeoEvents(events) => {
                (events.len() * mem::size_of::<arch_client::geo_event_t>()) as u32
            }
            RequestData::U128(ids) => (ids.len() * mem::size_of::<u128>()) as u32,
            RequestData::QueryRadius(_) => mem::size_of::<arch_client::query_radius_filter_t>() as u32,
            RequestData::QueryLatest(_) => mem::size_of::<arch_client::query_latest_filter_t>() as u32,
            RequestData::QueryUuid(_) => mem::size_of::<arch_client::query_uuid_filter_t>() as u32,
            RequestData::TtlSet(_) => mem::size_of::<TtlSetRequestRaw>() as u32,
            RequestData::TtlExtend(_) => mem::size_of::<TtlExtendRequestRaw>() as u32,
            RequestData::TtlClear(_) => mem::size_of::<TtlClearRequestRaw>() as u32,
        }
    }
}

struct Request {
    sender: oneshot::Sender<Completion>,
    packet: arch_client::arch_packet_t,
    data: RequestData,
}

struct Completion {
    status: u8,
    data: Vec<u8>,
}

unsafe extern "C" fn on_completion(
    _context: usize,
    packet: *mut arch_client::arch_packet_t,
    _timestamp: u64,
    result_ptr: *const u8,
    result_len: u32,
) {
    if packet.is_null() {
        return;
    }

    let request_ptr = (*packet).user_data as *mut Request;
    if request_ptr.is_null() {
        return;
    }

    let request = Box::from_raw(request_ptr);
    let reply = if !result_ptr.is_null() && result_len > 0 {
        let bytes = slice::from_raw_parts(result_ptr, result_len as usize);
        bytes.to_vec()
    } else {
        Vec::new()
    };

    let status = (*packet).status;
    let _ = request.sender.send(Completion { status, data: reply });
}

/// ArcherDB geospatial client.
pub struct GeoClient {
    client: Pin<Box<arch_client::arch_client_t>>,
    closed: AtomicBool,
    cluster_id: u128,
    addresses: Vec<String>,
}

impl GeoClient {
    /// Creates a new GeoClient.
    pub fn new(cluster_id: u128, addresses: &str) -> Result<Self, GeoError> {
        let mut client = Box::pin(arch_client::arch_client_t { opaque: [0u64; 4] });
        let cluster_bytes = cluster_id.to_le_bytes();
        let address_bytes = addresses.as_bytes();

        let status = unsafe {
            arch_client::arch_client_init(
                client.as_mut().get_unchecked_mut(),
                &cluster_bytes,
                address_bytes.as_ptr() as *const c_char,
                address_bytes.len() as u32,
                0,
                Some(on_completion),
            )
        };

        if status != arch_client::ARCH_INIT_STATUS_ARCH_INIT_SUCCESS {
            return Err(GeoError::Connection(format!(
                "arch_client_init failed: {}",
                status
            )));
        }

        Ok(GeoClient {
            client,
            closed: AtomicBool::new(false),
            cluster_id,
            addresses: addresses.split(',').map(|s| s.trim().to_string()).collect(),
        })
    }

    /// Returns the configured cluster ID.
    pub fn cluster_id(&self) -> u128 {
        self.cluster_id
    }

    /// Returns the configured replica address list.
    pub fn addresses(&self) -> &[String] {
        &self.addresses
    }

    fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    async fn submit_request(&self, operation: u8, data: RequestData) -> Result<Vec<u8>, GeoError> {
        if self.is_closed() {
            return Err(GeoError::Connection("client has been closed".into()));
        }

        let (sender, receiver) = oneshot::channel();
        let packet = arch_client::arch_packet_t {
            user_data: std::ptr::null_mut(),
            data: std::ptr::null_mut(),
            data_size: 0,
            user_tag: 0,
            operation,
            status: 0,
            opaque: [0u8; 64],
        };

        let request = Box::new(Request { sender, packet, data });
        let request_ptr = Box::into_raw(request);

        unsafe {
            let request_ref = &mut *request_ptr;
            request_ref.packet.user_data = request_ptr as *mut c_void;
            request_ref.packet.data = request_ref.data.data_ptr();
            request_ref.packet.data_size = request_ref.data.data_len();
            request_ref.packet.operation = operation;
            request_ref.packet.user_tag = 0;

            let client_ptr = self.client.as_ref().get_ref() as *const _ as *mut arch_client::arch_client_t;
            let status = arch_client::arch_client_submit(client_ptr, &mut request_ref.packet);
            if status != arch_client::ARCH_CLIENT_STATUS_ARCH_CLIENT_OK {
                let _ = Box::from_raw(request_ptr);
                return Err(GeoError::Connection("client has been closed".into()));
            }
        }

        let completion = receiver
            .await
            .map_err(|_| GeoError::Connection("request canceled".into()))?;

        if completion.status != arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_OK {
            return Err(map_packet_status(completion.status));
        }

        Ok(completion.data)
    }

    /// Inserts geospatial events.
    pub async fn insert_events(&self, events: &[GeoEvent]) -> Result<Vec<InsertError>, GeoError> {
        if events.is_empty() {
            return Ok(Vec::new());
        }
        if events.len() > BATCH_SIZE_MAX {
            return Err(GeoError::Server(format!(
                "batch exceeds maximum size of {}",
                BATCH_SIZE_MAX
            )));
        }

        let mut payload = Vec::with_capacity(events.len());
        for event in events {
            let mut prepared = *event;
            prepared.prepare();
            payload.push(prepared.into());
        }

        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_INSERT_EVENTS,
                RequestData::GeoEvents(payload),
            )
            .await?;
        parse_insert_results(&reply)
    }

    /// Upserts geospatial events.
    pub async fn upsert_events(&self, events: &[GeoEvent]) -> Result<Vec<InsertError>, GeoError> {
        if events.is_empty() {
            return Ok(Vec::new());
        }
        if events.len() > BATCH_SIZE_MAX {
            return Err(GeoError::Server(format!(
                "batch exceeds maximum size of {}",
                BATCH_SIZE_MAX
            )));
        }

        let mut payload = Vec::with_capacity(events.len());
        for event in events {
            let mut prepared = *event;
            prepared.prepare();
            payload.push(prepared.into());
        }

        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_UPSERT_EVENTS,
                RequestData::GeoEvents(payload),
            )
            .await?;
        parse_insert_results(&reply)
    }

    /// Deletes entities by ID.
    pub async fn delete_entities(&self, entity_ids: &[u128]) -> Result<DeleteResult, GeoError> {
        if entity_ids.is_empty() {
            return Ok(DeleteResult::default());
        }
        if entity_ids.len() > BATCH_SIZE_MAX {
            return Err(GeoError::Server(format!(
                "batch exceeds maximum size of {}",
                BATCH_SIZE_MAX
            )));
        }

        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_DELETE_ENTITIES,
                RequestData::U128(entity_ids.to_vec()),
            )
            .await?;
        parse_delete_results(&reply, entity_ids.len())
    }

    /// Gets the latest event for an entity.
    pub async fn get_latest_by_uuid(&self, entity_id: u128) -> Result<Option<GeoEvent>, GeoError> {
        let filter = arch_client::query_uuid_filter_t {
            entity_id,
            reserved: [0u8; 16],
        };

        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_QUERY_UUID,
                RequestData::QueryUuid(Box::new(filter)),
            )
            .await?;
        parse_query_uuid_response(&reply)
    }

    /// Batch lookup of latest events for multiple entities.
    pub async fn get_latest_by_uuid_batch(
        &self,
        entity_ids: &[u128],
    ) -> Result<HashMap<u128, GeoEvent>, GeoError> {
        let result = self.query_uuid_batch(entity_ids).await?;
        let mut not_found = vec![false; entity_ids.len()];
        for idx in &result.not_found_indices {
            let idx = *idx as usize;
            if idx < not_found.len() {
                not_found[idx] = true;
            }
        }

        let mut events = HashMap::new();
        let mut event_index = 0usize;
        for (i, entity_id) in entity_ids.iter().enumerate() {
            if not_found[i] {
                continue;
            }
            if event_index < result.events.len() {
                events.insert(*entity_id, result.events[event_index]);
                event_index += 1;
            }
        }

        Ok(events)
    }

    /// Batch lookup of latest events with not-found indices.
    pub async fn query_uuid_batch(
        &self,
        entity_ids: &[u128],
    ) -> Result<QueryUuidBatchResult, GeoError> {
        if entity_ids.is_empty() {
            return Ok(QueryUuidBatchResult::default());
        }
        if entity_ids.len() > QUERY_UUID_BATCH_MAX {
            return Err(GeoError::Server(format!(
                "batch exceeds maximum size of {}",
                QUERY_UUID_BATCH_MAX
            )));
        }

        let data = encode_query_uuid_batch_request(entity_ids);
        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_QUERY_UUID_BATCH,
                RequestData::Bytes(data),
            )
            .await?;
        parse_query_uuid_batch_response(&reply)
    }

    /// Queries events within a radius.
    pub async fn query_radius(&self, query: &RadiusQuery) -> Result<QueryResult, GeoError> {
        if query.limit as usize > QUERY_LIMIT_MAX {
            return Err(GeoError::Server(format!(
                "limit {} exceeds maximum {}",
                query.limit, QUERY_LIMIT_MAX
            )));
        }

        let filter = arch_client::query_radius_filter_t {
            center_lat_nano: query.center_lat_nano,
            center_lon_nano: query.center_lon_nano,
            radius_mm: query.radius_mm,
            limit: query.limit,
            timestamp_min: query.timestamp_min,
            timestamp_max: query.timestamp_max,
            group_id: query.group_id,
            reserved: [0u8; 80],
        };

        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_QUERY_RADIUS,
                RequestData::QueryRadius(Box::new(filter)),
            )
            .await?;
        parse_query_response(&reply, query.limit)
    }

    /// Queries events within a polygon.
    pub async fn query_polygon(&self, query: &PolygonQuery) -> Result<QueryResult, GeoError> {
        if query.limit as usize > QUERY_LIMIT_MAX {
            return Err(GeoError::Server(format!(
                "limit {} exceeds maximum {}",
                query.limit, QUERY_LIMIT_MAX
            )));
        }
        if query.vertices.len() < 3 {
            return Err(GeoError::InvalidPolygon(
                "polygon must have at least 3 vertices".into(),
            ));
        }
        if query.vertices.len() > POLYGON_VERTICES_MAX {
            return Err(GeoError::InvalidPolygon(format!(
                "polygon exceeds maximum {} vertices",
                POLYGON_VERTICES_MAX
            )));
        }
        if query.holes.len() > POLYGON_HOLES_MAX {
            return Err(GeoError::InvalidPolygon(format!(
                "polygon exceeds maximum {} holes",
                POLYGON_HOLES_MAX
            )));
        }

        validate_polygon_query(query)?;

        for hole in &query.holes {
            if hole.vertices.len() < POLYGON_HOLE_VERTICES_MIN {
                return Err(GeoError::InvalidPolygon(format!(
                    "hole must have at least {} vertices",
                    POLYGON_HOLE_VERTICES_MIN
                )));
            }
            let hole_vertices: Vec<(f64, f64)> = hole
                .vertices
                .iter()
                .map(|v| (nano_to_degrees(v.lat_nano), nano_to_degrees(v.lon_nano)))
                .collect();
            if let Err(err) = validate_polygon_no_self_intersection(&hole_vertices, true) {
                return Err(GeoError::InvalidPolygon(err.message));
            }
        }

        let request_bytes = encode_polygon_query(query)?;
        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_QUERY_POLYGON,
                RequestData::Bytes(request_bytes),
            )
            .await?;
        parse_query_response(&reply, query.limit)
    }

    /// Queries the latest events.
    pub async fn query_latest(&self, query: &LatestQuery) -> Result<QueryResult, GeoError> {
        if query.limit as usize > QUERY_LIMIT_MAX {
            return Err(GeoError::Server(format!(
                "limit {} exceeds maximum {}",
                query.limit, QUERY_LIMIT_MAX
            )));
        }

        let filter = arch_client::query_latest_filter_t {
            limit: query.limit,
            _reserved_align: 0,
            group_id: query.group_id,
            cursor_timestamp: query.cursor_timestamp,
            reserved: [0u8; 104],
        };

        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_QUERY_LATEST,
                RequestData::QueryLatest(Box::new(filter)),
            )
            .await?;
        parse_query_response(&reply, query.limit)
    }

    /// Sets the TTL for an entity.
    pub async fn set_ttl(&self, entity_id: u128, ttl_seconds: u32) -> Result<TtlSetResponse, GeoError> {
        let request = TtlSetRequestRaw {
            entity_id,
            ttl_seconds,
            flags: 0,
            reserved: [0u8; 40],
        };
        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_TTL_SET,
                RequestData::TtlSet(Box::new(request)),
            )
            .await?;

        if reply.len() < mem::size_of::<TtlSetResponseRaw>() {
            return Err(GeoError::Server("invalid TTL set response".into()));
        }
        let raw: TtlSetResponseRaw = read_struct(&reply);
        Ok(TtlSetResponse {
            entity_id: raw.entity_id,
            previous_ttl_seconds: raw.previous_ttl_seconds,
            new_ttl_seconds: raw.new_ttl_seconds,
            result: TtlOperationResult::from(raw.result),
        })
    }

    /// Extends the TTL for an entity.
    pub async fn extend_ttl(
        &self,
        entity_id: u128,
        extend_by_seconds: u32,
    ) -> Result<TtlExtendResponse, GeoError> {
        let request = TtlExtendRequestRaw {
            entity_id,
            extend_by_seconds,
            flags: 0,
            reserved: [0u8; 40],
        };
        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_TTL_EXTEND,
                RequestData::TtlExtend(Box::new(request)),
            )
            .await?;

        if reply.len() < mem::size_of::<TtlExtendResponseRaw>() {
            return Err(GeoError::Server("invalid TTL extend response".into()));
        }
        let raw: TtlExtendResponseRaw = read_struct(&reply);
        Ok(TtlExtendResponse {
            entity_id: raw.entity_id,
            previous_ttl_seconds: raw.previous_ttl_seconds,
            new_ttl_seconds: raw.new_ttl_seconds,
            result: TtlOperationResult::from(raw.result),
        })
    }

    /// Clears the TTL for an entity.
    pub async fn clear_ttl(&self, entity_id: u128) -> Result<TtlClearResponse, GeoError> {
        let request = TtlClearRequestRaw {
            entity_id,
            flags: 0,
            reserved: [0u8; 44],
        };
        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_TTL_CLEAR,
                RequestData::TtlClear(Box::new(request)),
            )
            .await?;

        if reply.len() < mem::size_of::<TtlClearResponseRaw>() {
            return Err(GeoError::Server("invalid TTL clear response".into()));
        }
        let raw: TtlClearResponseRaw = read_struct(&reply);
        Ok(TtlClearResponse {
            entity_id: raw.entity_id,
            previous_ttl_seconds: raw.previous_ttl_seconds,
            result: TtlOperationResult::from(raw.result),
        })
    }

    /// Pings the server.
    pub async fn ping(&self) -> Result<bool, GeoError> {
        let mut payload = AlignedBytes::new(1);
        payload.as_mut_slice()[0] = 0;
        let _ = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_ARCHERDB_PING,
                RequestData::Bytes(payload),
            )
            .await?;
        Ok(true)
    }

    /// Gets server status.
    pub async fn get_status(&self) -> Result<StatusResponse, GeoError> {
        let mut payload = AlignedBytes::new(1);
        payload.as_mut_slice()[0] = 0;
        let reply = self
            .submit_request(
                arch_client::ARCH_OPERATION_ARCH_OPERATION_ARCHERDB_GET_STATUS,
                RequestData::Bytes(payload),
            )
            .await?;

        if reply.len() < mem::size_of::<StatusResponseRaw>() {
            return Ok(StatusResponse::default());
        }

        let raw: StatusResponseRaw = read_struct(&reply);
        Ok(StatusResponse {
            ram_index_count: raw.ram_index_count,
            ram_index_capacity: raw.ram_index_capacity,
            ram_index_load_pct: raw.ram_index_load_pct,
            tombstone_count: raw.tombstone_count,
            ttl_expirations: raw.ttl_expirations,
            deletion_count: raw.deletion_count,
        })
    }
}

impl Drop for GeoClient {
    fn drop(&mut self) {
        if !self.closed.swap(true, Ordering::SeqCst) {
            unsafe {
                let client_ptr = self.client.as_mut().get_unchecked_mut();
                let _ = arch_client::arch_client_deinit(client_ptr);
            }
        }
    }
}

fn map_packet_status(status: u8) -> GeoError {
    match status {
        arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_TOO_MUCH_DATA => {
            GeoError::Server("maximum batch size exceeded".into())
        }
        arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_CLIENT_EVICTED => {
            GeoError::Connection("client evicted".into())
        }
        arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_CLIENT_RELEASE_TOO_LOW => {
            GeoError::Connection("client release too low".into())
        }
        arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_CLIENT_RELEASE_TOO_HIGH => {
            GeoError::Connection("client release too high".into())
        }
        arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_CLIENT_SHUTDOWN => {
            GeoError::Connection("client shutdown".into())
        }
        arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_INVALID_OPERATION => {
            GeoError::Server("invalid operation".into())
        }
        arch_client::ARCH_PACKET_STATUS_ARCH_PACKET_INVALID_DATA_SIZE => {
            GeoError::Server("invalid data size".into())
        }
        _ => GeoError::Server(format!("unknown packet status {}", status)),
    }
}

fn read_struct<T: Copy>(bytes: &[u8]) -> T {
    let size = mem::size_of::<T>();
    assert!(bytes.len() >= size);
    unsafe { std::ptr::read_unaligned(bytes.as_ptr() as *const T) }
}

fn write_struct<T: Copy>(dst: &mut [u8], value: &T) {
    let size = mem::size_of::<T>();
    assert!(dst.len() >= size);
    unsafe {
        std::ptr::copy_nonoverlapping(value as *const T as *const u8, dst.as_mut_ptr(), size);
    }
}

fn align_forward(offset: usize, align: usize) -> usize {
    let mask = align - 1;
    if offset & mask == 0 {
        offset
    } else {
        (offset + mask) & !mask
    }
}

fn encode_query_uuid_batch_request(entity_ids: &[u128]) -> AlignedBytes {
    let header_size = 8usize;
    let total_size = header_size + entity_ids.len() * 16;
    let mut buffer = AlignedBytes::new(total_size);
    let bytes = buffer.as_mut_slice();

    bytes[0..4].copy_from_slice(&(entity_ids.len() as u32).to_le_bytes());
    bytes[4..8].copy_from_slice(&0u32.to_le_bytes());

    let mut offset = header_size;
    for entity_id in entity_ids {
        bytes[offset..offset + 16].copy_from_slice(&entity_id.to_le_bytes());
        offset += 16;
    }

    buffer
}

fn encode_polygon_query(query: &PolygonQuery) -> Result<AlignedBytes, GeoError> {
    let header_size = mem::size_of::<arch_client::query_polygon_filter_t>();
    let vertex_size = mem::size_of::<arch_client::polygon_vertex_t>();
    let descriptor_size = mem::size_of::<HoleDescriptor>();

    let outer_vertices_size = query.vertices.len() * vertex_size;
    let mut hole_vertices_count = 0usize;
    for hole in &query.holes {
        hole_vertices_count += hole.vertices.len();
    }
    let hole_vertices_size = hole_vertices_count * vertex_size;
    let hole_descriptors_size = query.holes.len() * descriptor_size;
    let total_size = header_size + outer_vertices_size + hole_descriptors_size + hole_vertices_size;

    let header = arch_client::query_polygon_filter_t {
        vertex_count: query.vertices.len() as u32,
        hole_count: query.holes.len() as u32,
        limit: query.limit,
        _reserved_align: 0,
        timestamp_min: query.timestamp_min,
        timestamp_max: query.timestamp_max,
        group_id: query.group_id,
        reserved: [0u8; 88],
    };

    let mut buffer = AlignedBytes::new(total_size);
    let bytes = buffer.as_mut_slice();

    write_struct(&mut bytes[0..header_size], &header);
    let mut offset = header_size;

    for vertex in &query.vertices {
        let raw = arch_client::polygon_vertex_t {
            lat_nano: vertex.lat_nano,
            lon_nano: vertex.lon_nano,
        };
        write_struct(&mut bytes[offset..offset + vertex_size], &raw);
        offset += vertex_size;
    }

    for hole in &query.holes {
        let descriptor = HoleDescriptor {
            vertex_count: hole.vertices.len() as u32,
            reserved: 0,
        };
        write_struct(&mut bytes[offset..offset + descriptor_size], &descriptor);
        offset += descriptor_size;
    }

    for hole in &query.holes {
        for vertex in &hole.vertices {
            let raw = arch_client::polygon_vertex_t {
                lat_nano: vertex.lat_nano,
                lon_nano: vertex.lon_nano,
            };
            write_struct(&mut bytes[offset..offset + vertex_size], &raw);
            offset += vertex_size;
        }
    }

    Ok(buffer)
}

fn parse_insert_results(reply: &[u8]) -> Result<Vec<InsertError>, GeoError> {
    if reply.is_empty() {
        return Ok(Vec::new());
    }

    let result_size = mem::size_of::<arch_client::insert_geo_events_result_t>();
    if reply.len() % result_size != 0 {
        return Err(GeoError::Server("invalid insert result size".into()));
    }

    let mut results = Vec::with_capacity(reply.len() / result_size);
    for chunk in reply.chunks(result_size) {
        let raw: arch_client::insert_geo_events_result_t = read_struct(chunk);
        results.push(InsertError {
            index: raw.index,
            result: InsertGeoEventResult::from(raw.result as arch_client::INSERT_GEO_EVENT_RESULT),
        });
    }

    Ok(results)
}

fn parse_delete_results(reply: &[u8], requested: usize) -> Result<DeleteResult, GeoError> {
    if reply.is_empty() {
        return Ok(DeleteResult {
            deleted_count: requested,
            not_found_count: 0,
        });
    }

    let result_size = mem::size_of::<arch_client::delete_entities_result_t>();
    if reply.len() % result_size != 0 {
        return Err(GeoError::Server("invalid delete result size".into()));
    }

    let mut not_found = 0usize;
    for chunk in reply.chunks(result_size) {
        let raw: arch_client::delete_entities_result_t = read_struct(chunk);
        match raw.result {
            0 => {}
            3 => {
                not_found += 1;
            }
            _ => {
                return Err(GeoError::Server(format!(
                    "delete_entities failed with result {}",
                    raw.result
                )));
            }
        }
    }

    Ok(DeleteResult {
        deleted_count: requested.saturating_sub(not_found),
        not_found_count: not_found,
    })
}

fn parse_query_uuid_response(reply: &[u8]) -> Result<Option<GeoEvent>, GeoError> {
    if reply.len() < mem::size_of::<arch_client::query_uuid_response_t>() {
        return Ok(None);
    }

    let status = reply[0];
    if status == 200 {
        return Ok(None);
    }
    if status == 210 {
        return Err(GeoError::Server("entity expired due to TTL".into()));
    }
    if status != 0 {
        return Err(GeoError::Server(format!("query_uuid status {}", status)));
    }

    let header_size = mem::size_of::<arch_client::query_uuid_response_t>();
    let event_size = mem::size_of::<arch_client::geo_event_t>();
    if reply.len() < header_size + event_size {
        return Ok(None);
    }

    let event_bytes = &reply[header_size..header_size + event_size];
    let raw: arch_client::geo_event_t = read_struct(event_bytes);
    Ok(Some(GeoEvent::from(raw)))
}

fn parse_query_response(reply: &[u8], limit: u32) -> Result<QueryResult, GeoError> {
    if reply.is_empty() {
        return Ok(QueryResult::default());
    }

    let event_size = mem::size_of::<arch_client::geo_event_t>();
    let header_size = mem::size_of::<arch_client::query_response_t>();

    if reply.len() >= header_size && (reply.len() - header_size) % event_size == 0 {
        let header: arch_client::query_response_t = read_struct(&reply[0..header_size]);
        let count = header.count as usize;
        let has_more = header.has_more != 0;
        let payload = &reply[header_size..];

        if payload.len() / event_size != count {
            return Err(GeoError::Server(format!(
                "query response count {} does not match payload {}",
                count,
                payload.len() / event_size
            )));
        }

        let mut events = Vec::with_capacity(count);
        for chunk in payload.chunks(event_size).take(count) {
            let raw: arch_client::geo_event_t = read_struct(chunk);
            events.push(GeoEvent::from(raw));
        }

        let cursor = events.last().map(|event| event.timestamp).unwrap_or(0);
        return Ok(QueryResult {
            events,
            has_more,
            cursor,
        });
    }

    if reply.len() < event_size {
        return Ok(QueryResult::default());
    }
    if reply.len() % event_size != 0 {
        return Err(GeoError::Server("query response size is misaligned".into()));
    }

    let mut events = Vec::with_capacity(reply.len() / event_size);
    for chunk in reply.chunks(event_size) {
        let raw: arch_client::geo_event_t = read_struct(chunk);
        events.push(GeoEvent::from(raw));
    }

    let cursor = events.last().map(|event| event.timestamp).unwrap_or(0);
    let has_more = events.len() == limit as usize;
    Ok(QueryResult {
        events,
        has_more,
        cursor,
    })
}

fn parse_query_uuid_batch_response(reply: &[u8]) -> Result<QueryUuidBatchResult, GeoError> {
    if reply.is_empty() {
        return Ok(QueryUuidBatchResult::default());
    }

    const HEADER_SIZE: usize = 16;
    if reply.len() < HEADER_SIZE {
        return Err(GeoError::Server(format!(
            "query_uuid_batch response too small: {}",
            reply.len()
        )));
    }

    let found_count = u32::from_le_bytes(reply[0..4].try_into().unwrap());
    let not_found_count = u32::from_le_bytes(reply[4..8].try_into().unwrap());

    let indices_size = not_found_count as usize * 2;
    let indices_end = HEADER_SIZE + indices_size;
    let events_offset = align_forward(indices_end, 16);

    let event_size = mem::size_of::<arch_client::geo_event_t>();
    let events_size = found_count as usize * event_size;
    if reply.len() < events_offset + events_size {
        return Err(GeoError::Server(format!(
            "query_uuid_batch response truncated: {}",
            reply.len()
        )));
    }

    let mut not_found_indices = Vec::with_capacity(not_found_count as usize);
    for i in 0..not_found_count as usize {
        let start = HEADER_SIZE + i * 2;
        let end = start + 2;
        let index = u16::from_le_bytes(reply[start..end].try_into().unwrap());
        not_found_indices.push(index);
    }

    let mut events = Vec::with_capacity(found_count as usize);
    let payload = &reply[events_offset..events_offset + events_size];
    for chunk in payload.chunks(event_size).take(found_count as usize) {
        let raw: arch_client::geo_event_t = read_struct(chunk);
        events.push(GeoEvent::from(raw));
    }

    Ok(QueryUuidBatchResult {
        found_count,
        not_found_count,
        not_found_indices,
        events,
    })
}

// ============================================================================
// Sharding Strategy (per add-jump-consistent-hash spec)
// Algorithm for distributing entities across shards
// ============================================================================

/// Strategy for distributing entities across shards.
///
/// Different strategies offer different trade-offs:
/// - `Modulo`: Simple, requires power-of-2 shard counts, moves most data on resize
/// - `VirtualRing`: Consistent hashing with O(log N) lookup and memory cost
/// - `JumpHash`: Google's algorithm - O(1) memory, O(log N) compute, optimal movement
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum ShardingStrategy {
    /// Simple modulo-based sharding: hash % num_shards.
    /// Requires power-of-2 shard counts for efficient computation.
    /// Moves ~(N-1)/N entities when adding one shard.
    Modulo = 0,

    /// Virtual node ring-based consistent hashing.
    /// Uses 150 virtual nodes per shard by default.
    /// Moves ~1/N entities when adding one shard.
    /// Has O(log N) lookup overhead and memory cost.
    VirtualRing = 1,

    /// Jump Consistent Hash (Google, 2014).
    /// O(1) memory, O(log N) compute, optimal 1/(N+1) movement.
    /// Default strategy - best balance of performance and movement.
    #[default]
    JumpHash = 2,
}

impl ShardingStrategy {
    /// Check if this strategy requires power-of-2 shard counts.
    pub fn requires_power_of_two(&self) -> bool {
        matches!(self, ShardingStrategy::Modulo)
    }

    /// Parse from string representation.
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "modulo" => Some(ShardingStrategy::Modulo),
            "virtual_ring" => Some(ShardingStrategy::VirtualRing),
            "jump_hash" => Some(ShardingStrategy::JumpHash),
            _ => None,
        }
    }

    /// Convert to string representation.
    pub fn as_str(&self) -> &'static str {
        match self {
            ShardingStrategy::Modulo => "modulo",
            ShardingStrategy::VirtualRing => "virtual_ring",
            ShardingStrategy::JumpHash => "jump_hash",
        }
    }
}

// ============================================================================
// Geo-Sharding Types (v2.2)
// Geographic partitioning for data locality
// ============================================================================

/// Policy for assigning entities to geographic regions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum GeoShardPolicy {
    /// No geo-sharding - all entities in single region.
    #[default]
    None = 0,
    /// Route based on entity's lat/lon coordinates to nearest region.
    ByEntityLocation = 1,
    /// Route based on entity_id prefix mapping to regions.
    ByEntityIdPrefix = 2,
    /// Application explicitly specifies target region per entity.
    Explicit = 3,
}

/// A geographic region in the geo-sharding topology.
#[derive(Debug, Clone, Default)]
pub struct GeoRegion {
    /// Unique identifier for this region (max 16 characters).
    pub region_id: String,
    /// Human-readable name for the region.
    pub name: String,
    /// Endpoint address for this region.
    pub endpoint: String,
    /// Center latitude in nanodegrees for by_entity_location routing.
    pub center_lat_nano: i64,
    /// Center longitude in nanodegrees for by_entity_location routing.
    pub center_lon_nano: i64,
    /// Priority for routing (lower = higher priority for ties).
    pub priority: u8,
    /// Whether this region is currently active.
    pub is_active: bool,
}

impl GeoRegion {
    /// Creates a new region with center coordinates in degrees.
    pub fn new(
        region_id: impl Into<String>,
        name: impl Into<String>,
        endpoint: impl Into<String>,
        center_latitude: f64,
        center_longitude: f64,
    ) -> Self {
        GeoRegion {
            region_id: region_id.into(),
            name: name.into(),
            endpoint: endpoint.into(),
            center_lat_nano: degrees_to_nano(center_latitude),
            center_lon_nano: degrees_to_nano(center_longitude),
            priority: 0,
            is_active: true,
        }
    }

    /// Returns the center latitude in degrees.
    pub fn center_latitude(&self) -> f64 {
        nano_to_degrees(self.center_lat_nano)
    }

    /// Returns the center longitude in degrees.
    pub fn center_longitude(&self) -> f64 {
        nano_to_degrees(self.center_lon_nano)
    }
}

/// Configuration for geo-sharding behavior.
#[derive(Debug, Clone, Default)]
pub struct GeoShardConfig {
    /// The geo-sharding policy to use.
    pub policy: GeoShardPolicy,
    /// Available regions for routing.
    pub regions: Vec<GeoRegion>,
    /// Default region ID when routing cannot determine target.
    pub default_region_id: String,
    /// Whether to allow cross-region query aggregation.
    pub allow_cross_region_queries: bool,
}

/// Metadata tracking which region owns an entity.
#[derive(Debug, Clone, Default)]
pub struct EntityRegionMetadata {
    /// The entity ID.
    pub entity_id: u128,
    /// The region ID that owns this entity.
    pub region_id: String,
    /// Timestamp when entity was assigned to this region (nanoseconds).
    pub assigned_timestamp: u64,
    /// Whether this assignment was explicit or computed.
    pub is_explicit: bool,
}

/// Result of a cross-region query aggregation.
#[derive(Debug, Clone, Default)]
pub struct CrossRegionQueryResult {
    /// Aggregated events from all regions.
    pub events: Vec<GeoEvent>,
    /// Per-region result counts.
    pub region_results: std::collections::HashMap<String, usize>,
    /// Regions that failed during the query.
    pub region_errors: std::collections::HashMap<String, String>,
    /// Whether more results are available.
    pub has_more: bool,
    /// Total latency in milliseconds.
    pub total_latency_ms: f64,
}

// ============================================================================
// Conflict Resolution Types (v2.2)
// Active-Active Replication Support
// ============================================================================

/// Policy for resolving write conflicts in active-active replication.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum ConflictResolutionPolicy {
    /// Highest timestamp wins (default).
    #[default]
    LastWriterWins = 0,
    /// Primary region write takes precedence.
    PrimaryWins = 1,
    /// Application-provided resolution function.
    CustomHook = 2,
}

/// Vector clock for tracking causality in distributed systems.
#[derive(Debug, Clone, Default)]
pub struct VectorClock {
    /// Clock entries keyed by region ID.
    pub entries: std::collections::HashMap<String, u64>,
}

impl VectorClock {
    /// Creates an empty vector clock.
    pub fn new() -> Self {
        VectorClock {
            entries: std::collections::HashMap::new(),
        }
    }

    /// Gets the timestamp for a region.
    pub fn get(&self, region_id: &str) -> u64 {
        *self.entries.get(region_id).unwrap_or(&0)
    }

    /// Sets the timestamp for a region.
    pub fn set(&mut self, region_id: impl Into<String>, timestamp: u64) {
        self.entries.insert(region_id.into(), timestamp);
    }

    /// Increments the timestamp for a region.
    pub fn increment(&mut self, region_id: &str) -> u64 {
        let entry = self.entries.entry(region_id.to_string()).or_insert(0);
        *entry += 1;
        *entry
    }

    /// Merges another vector clock into this one (takes max of each entry).
    pub fn merge(&mut self, other: &VectorClock) {
        for (region_id, &timestamp) in &other.entries {
            let entry = self.entries.entry(region_id.clone()).or_insert(0);
            if timestamp > *entry {
                *entry = timestamp;
            }
        }
    }

    /// Compares two vector clocks.
    /// Returns: -1 if self < other, 0 if concurrent, 1 if self > other
    pub fn compare(&self, other: &VectorClock) -> i8 {
        let mut self_greater = false;
        let mut other_greater = false;

        // Check entries in self
        for (region_id, &ts) in &self.entries {
            let other_ts = other.entries.get(region_id).copied().unwrap_or(0);
            if ts > other_ts {
                self_greater = true;
            }
            if ts < other_ts {
                other_greater = true;
            }
        }

        // Check entries only in other
        for (region_id, &ts) in &other.entries {
            if !self.entries.contains_key(region_id) && ts > 0 {
                other_greater = true;
            }
        }

        if self_greater && !other_greater {
            1
        } else if other_greater && !self_greater {
            -1
        } else {
            0 // Concurrent
        }
    }

    /// Returns true if the clocks are concurrent.
    pub fn is_concurrent(&self, other: &VectorClock) -> bool {
        self.compare(other) == 0
    }
}

/// Information about a detected conflict.
#[derive(Debug, Clone)]
pub struct ConflictInfo {
    /// The entity ID with the conflict.
    pub entity_id: u128,
    /// Vector clock of the local write.
    pub local_clock: VectorClock,
    /// Vector clock of the remote write.
    pub remote_clock: VectorClock,
    /// Region ID where local write originated.
    pub local_region: String,
    /// Region ID where remote write originated.
    pub remote_region: String,
    /// Timestamp of the local write (nanoseconds).
    pub local_timestamp: u64,
    /// Timestamp of the remote write (nanoseconds).
    pub remote_timestamp: u64,
}

/// Result of conflict resolution.
#[derive(Debug, Clone)]
pub struct ConflictResolution {
    /// The winning region ID.
    pub winning_region: String,
    /// The policy used for resolution.
    pub policy: ConflictResolutionPolicy,
    /// The merged vector clock after resolution.
    pub merged_clock: VectorClock,
    /// Whether the local write won.
    pub local_wins: bool,
}

/// Statistics about conflict resolution.
#[derive(Debug, Clone, Default)]
pub struct ConflictStats {
    /// Total conflicts detected.
    pub total_conflicts: u64,
    /// Conflicts resolved by last-writer-wins.
    pub last_writer_wins_count: u64,
    /// Conflicts resolved by primary-wins.
    pub primary_wins_count: u64,
    /// Conflicts resolved by custom hook.
    pub custom_hook_count: u64,
    /// Timestamp of last conflict (nanoseconds).
    pub last_conflict_timestamp: u64,
}

/// Entry in the conflict audit log.
#[derive(Debug, Clone)]
pub struct ConflictAuditEntry {
    /// Unique ID for this audit entry.
    pub audit_id: u64,
    /// The entity ID with the conflict.
    pub entity_id: u128,
    /// Timestamp when conflict was detected (nanoseconds).
    pub detected_timestamp: u64,
    /// The winning region ID.
    pub winning_region: String,
    /// The losing region ID.
    pub losing_region: String,
    /// The resolution policy used.
    pub policy: ConflictResolutionPolicy,
    /// Serialized winning write data (for auditing).
    pub winning_data: Option<Vec<u8>>,
    /// Serialized losing write data (for auditing).
    pub losing_data: Option<Vec<u8>>,
}

// ============================================================================
// GeoJSON/WKT Protocol Support (per add-geojson-wkt-protocol spec)
// ============================================================================

/// Error type for GeoJSON/WKT parsing failures.
#[derive(Debug, Clone)]
pub enum GeoFormatError {
    /// Invalid JSON structure
    InvalidJson(String),
    /// Wrong geometry type (expected Point or Polygon)
    WrongType(String),
    /// Missing required field
    MissingField(String),
    /// Invalid coordinates
    InvalidCoordinates(String),
    /// Latitude out of bounds
    LatitudeOutOfBounds(f64),
    /// Longitude out of bounds
    LongitudeOutOfBounds(f64),
    /// Invalid WKT format
    InvalidWkt(String),
    /// Polygon ring has too few vertices
    TooFewVertices(usize),
}

impl std::fmt::Display for GeoFormatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GeoFormatError::InvalidJson(msg) => write!(f, "invalid JSON: {}", msg),
            GeoFormatError::WrongType(msg) => write!(f, "wrong geometry type: {}", msg),
            GeoFormatError::MissingField(msg) => write!(f, "missing field: {}", msg),
            GeoFormatError::InvalidCoordinates(msg) => write!(f, "invalid coordinates: {}", msg),
            GeoFormatError::LatitudeOutOfBounds(lat) => write!(f, "latitude {} out of bounds [-90, 90]", lat),
            GeoFormatError::LongitudeOutOfBounds(lon) => write!(f, "longitude {} out of bounds [-180, 180]", lon),
            GeoFormatError::InvalidWkt(msg) => write!(f, "invalid WKT: {}", msg),
            GeoFormatError::TooFewVertices(n) => write!(f, "ring must have at least 3 vertices, got {}", n),
        }
    }
}

impl std::error::Error for GeoFormatError {}

/// Output format for geographic data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum GeoFormat {
    /// Native nanodegree format
    #[default]
    Native = 0,
    /// GeoJSON format
    GeoJson = 1,
    /// Well-Known Text format
    Wkt = 2,
}

/// Parses a GeoJSON Point to nanodegree coordinates.
///
/// # Arguments
/// * `json` - GeoJSON string: `{"type": "Point", "coordinates": [lon, lat]}`
///
/// # Returns
/// * `(lat_nano, lon_nano)` tuple on success
pub fn parse_geojson_point(json: &str) -> Result<(i64, i64), GeoFormatError> {
    // Simple JSON parsing without external dependencies
    let json = json.trim();

    // Find "type" field and check it's "Point"
    let type_pos = json.find("\"type\"")
        .ok_or_else(|| GeoFormatError::MissingField("type".into()))?;
    let after_type = &json[type_pos + 6..];

    // Extract type value
    let colon_pos = after_type.find(':')
        .ok_or_else(|| GeoFormatError::InvalidJson("missing colon after type".into()))?;
    let value_start = &after_type[colon_pos + 1..].trim_start();

    if !value_start.starts_with('"') {
        return Err(GeoFormatError::InvalidJson("type must be a string".into()));
    }

    let quote_end = value_start[1..].find('"')
        .ok_or_else(|| GeoFormatError::InvalidJson("unterminated type string".into()))?;
    let type_value = &value_start[1..quote_end + 1];

    if type_value != "Point" {
        return Err(GeoFormatError::WrongType(format!("expected 'Point', got '{}'", type_value)));
    }

    // Find and parse coordinates
    let coords = extract_coordinates_array(json)?;
    if coords.len() < 2 {
        return Err(GeoFormatError::InvalidCoordinates("Point must have [lon, lat]".into()));
    }

    let lon = coords[0];
    let lat = coords[1];
    validate_coordinates(lat, lon)?;

    Ok((degrees_to_nano(lat), degrees_to_nano(lon)))
}

/// Parses a GeoJSON Polygon to nanodegree coordinates.
///
/// # Arguments
/// * `json` - GeoJSON string with Polygon geometry
///
/// # Returns
/// * `(exterior, holes)` where exterior is the outer ring and holes is a vec of inner rings
pub fn parse_geojson_polygon(json: &str) -> Result<(Vec<(i64, i64)>, Vec<Vec<(i64, i64)>>), GeoFormatError> {
    let json = json.trim();

    // Find "type" field and check it's "Polygon"
    let type_pos = json.find("\"type\"")
        .ok_or_else(|| GeoFormatError::MissingField("type".into()))?;
    let after_type = &json[type_pos + 6..];

    let colon_pos = after_type.find(':')
        .ok_or_else(|| GeoFormatError::InvalidJson("missing colon after type".into()))?;
    let value_start = &after_type[colon_pos + 1..].trim_start();

    if !value_start.starts_with('"') {
        return Err(GeoFormatError::InvalidJson("type must be a string".into()));
    }

    let quote_end = value_start[1..].find('"')
        .ok_or_else(|| GeoFormatError::InvalidJson("unterminated type string".into()))?;
    let type_value = &value_start[1..quote_end + 1];

    if type_value != "Polygon" {
        return Err(GeoFormatError::WrongType(format!("expected 'Polygon', got '{}'", type_value)));
    }

    // Find coordinates array
    let coords_pos = json.find("\"coordinates\"")
        .ok_or_else(|| GeoFormatError::MissingField("coordinates".into()))?;
    let after_coords = &json[coords_pos + 13..];

    let colon_pos = after_coords.find(':')
        .ok_or_else(|| GeoFormatError::InvalidJson("missing colon after coordinates".into()))?;
    let array_start = &after_coords[colon_pos + 1..].trim_start();

    // Parse the nested arrays
    let rings = parse_polygon_coordinates(array_start)?;

    if rings.is_empty() {
        return Err(GeoFormatError::InvalidCoordinates("Polygon must have at least one ring".into()));
    }

    let exterior = rings[0].clone();
    let holes = if rings.len() > 1 {
        rings[1..].to_vec()
    } else {
        Vec::new()
    };

    Ok((exterior, holes))
}

/// Helper: Extract a simple coordinates array like [lon, lat] or [lon, lat, z]
fn extract_coordinates_array(json: &str) -> Result<Vec<f64>, GeoFormatError> {
    let coords_pos = json.find("\"coordinates\"")
        .ok_or_else(|| GeoFormatError::MissingField("coordinates".into()))?;
    let after_coords = &json[coords_pos + 13..];

    let colon_pos = after_coords.find(':')
        .ok_or_else(|| GeoFormatError::InvalidJson("missing colon after coordinates".into()))?;
    let array_start = &after_coords[colon_pos + 1..].trim_start();

    if !array_start.starts_with('[') {
        return Err(GeoFormatError::InvalidCoordinates("coordinates must be an array".into()));
    }

    // Find matching bracket
    let mut depth = 0;
    let mut end = 0;
    for (i, c) in array_start.char_indices() {
        match c {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    end = i;
                    break;
                }
            }
            _ => {}
        }
    }

    let coords_str = &array_start[1..end];

    // Parse numbers
    let mut result = Vec::new();
    for part in coords_str.split(',') {
        let trimmed = part.trim();
        if !trimmed.is_empty() {
            let num: f64 = trimmed.parse()
                .map_err(|_| GeoFormatError::InvalidCoordinates(format!("invalid number: {}", trimmed)))?;
            result.push(num);
        }
    }

    Ok(result)
}

/// Helper: Parse polygon coordinates [[[lon, lat], ...], [[lon, lat], ...], ...]
fn parse_polygon_coordinates(array_start: &str) -> Result<Vec<Vec<(i64, i64)>>, GeoFormatError> {
    if !array_start.starts_with('[') {
        return Err(GeoFormatError::InvalidCoordinates("coordinates must be an array".into()));
    }

    let mut rings = Vec::new();
    let mut depth = 0;
    let mut ring_start = 0;
    let chars: Vec<char> = array_start.chars().collect();

    // Skip the outer [
    for (i, c) in chars.iter().enumerate() {
        match c {
            '[' => {
                depth += 1;
                if depth == 2 {
                    ring_start = i;
                }
            }
            ']' => {
                depth -= 1;
                if depth == 1 {
                    // Parse this ring
                    let ring_str: String = chars[ring_start..=i].iter().collect();
                    let ring = parse_coordinate_ring(&ring_str)?;
                    if ring.len() < 3 {
                        return Err(GeoFormatError::TooFewVertices(ring.len()));
                    }
                    rings.push(ring);
                }
                if depth == 0 {
                    break;
                }
            }
            _ => {}
        }
    }

    Ok(rings)
}

/// Helper: Parse a coordinate ring [[lon, lat], [lon, lat], ...]
fn parse_coordinate_ring(ring_str: &str) -> Result<Vec<(i64, i64)>, GeoFormatError> {
    let ring_str = ring_str.trim();
    if !ring_str.starts_with('[') || !ring_str.ends_with(']') {
        return Err(GeoFormatError::InvalidCoordinates("ring must be an array".into()));
    }

    let inner = &ring_str[1..ring_str.len() - 1];
    let mut result = Vec::new();
    let mut depth = 0;
    let mut point_start = 0;
    let chars: Vec<char> = inner.chars().collect();

    for (i, c) in chars.iter().enumerate() {
        match c {
            '[' => {
                if depth == 0 {
                    point_start = i;
                }
                depth += 1;
            }
            ']' => {
                depth -= 1;
                if depth == 0 {
                    let point_str: String = chars[point_start..=i].iter().collect();
                    let coords = parse_point_array(&point_str)?;
                    if coords.len() < 2 {
                        return Err(GeoFormatError::InvalidCoordinates("point must have [lon, lat]".into()));
                    }
                    let lon = coords[0];
                    let lat = coords[1];
                    validate_coordinates(lat, lon)?;
                    result.push((degrees_to_nano(lat), degrees_to_nano(lon)));
                }
            }
            _ => {}
        }
    }

    Ok(result)
}

/// Helper: Parse a point array [lon, lat] or [lon, lat, z]
fn parse_point_array(point_str: &str) -> Result<Vec<f64>, GeoFormatError> {
    let point_str = point_str.trim();
    if !point_str.starts_with('[') || !point_str.ends_with(']') {
        return Err(GeoFormatError::InvalidCoordinates("point must be an array".into()));
    }

    let inner = &point_str[1..point_str.len() - 1];
    let mut result = Vec::new();
    for part in inner.split(',') {
        let trimmed = part.trim();
        if !trimmed.is_empty() {
            let num: f64 = trimmed.parse()
                .map_err(|_| GeoFormatError::InvalidCoordinates(format!("invalid number: {}", trimmed)))?;
            result.push(num);
        }
    }

    Ok(result)
}

/// Parses a WKT POINT to nanodegree coordinates.
///
/// # Arguments
/// * `wkt` - WKT string: `POINT(lon lat)` or `POINT(lon lat z)`
///
/// # Returns
/// * `(lat_nano, lon_nano)` tuple on success
pub fn parse_wkt_point(wkt: &str) -> Result<(i64, i64), GeoFormatError> {
    let wkt_upper = wkt.trim().to_uppercase();
    if !wkt_upper.starts_with("POINT") {
        return Err(GeoFormatError::InvalidWkt("expected POINT".into()));
    }

    // Extract content between parentheses
    let start = wkt.find('(').ok_or_else(|| GeoFormatError::InvalidWkt("missing opening parenthesis".into()))?;
    let end = wkt.rfind(')').ok_or_else(|| GeoFormatError::InvalidWkt("missing closing parenthesis".into()))?;

    if start >= end {
        return Err(GeoFormatError::InvalidWkt("invalid parentheses".into()));
    }

    let content = wkt[start + 1..end].trim();
    let parts: Vec<&str> = content.split_whitespace().collect();

    if parts.len() < 2 {
        return Err(GeoFormatError::InvalidWkt("POINT must have lon lat coordinates".into()));
    }

    let lon: f64 = parts[0].parse()
        .map_err(|_| GeoFormatError::InvalidWkt("invalid longitude".into()))?;
    let lat: f64 = parts[1].parse()
        .map_err(|_| GeoFormatError::InvalidWkt("invalid latitude".into()))?;

    validate_coordinates(lat, lon)?;

    Ok((degrees_to_nano(lat), degrees_to_nano(lon)))
}

/// Parses a WKT POLYGON to nanodegree coordinates.
///
/// # Arguments
/// * `wkt` - WKT string: `POLYGON((lon lat, lon lat, ...))` or with holes
///
/// # Returns
/// * `(exterior, holes)` where exterior is the outer ring and holes is a vec of inner rings
pub fn parse_wkt_polygon(wkt: &str) -> Result<(Vec<(i64, i64)>, Vec<Vec<(i64, i64)>>), GeoFormatError> {
    let wkt_upper = wkt.trim().to_uppercase();
    if !wkt_upper.starts_with("POLYGON") {
        return Err(GeoFormatError::InvalidWkt("expected POLYGON".into()));
    }

    // Find the outer parentheses of POLYGON(...)
    let outer_start = wkt.find('(').ok_or_else(|| GeoFormatError::InvalidWkt("missing opening parenthesis".into()))?;
    let outer_end = wkt.rfind(')').ok_or_else(|| GeoFormatError::InvalidWkt("missing closing parenthesis".into()))?;

    if outer_start >= outer_end {
        return Err(GeoFormatError::InvalidWkt("invalid parentheses".into()));
    }

    let content = &wkt[outer_start + 1..outer_end];

    // Parse rings - find matching parentheses pairs
    let mut rings = Vec::new();
    let mut depth = 0;
    let mut ring_start = 0;
    let chars: Vec<char> = content.chars().collect();

    for (i, c) in chars.iter().enumerate() {
        match c {
            '(' => {
                if depth == 0 {
                    ring_start = i;
                }
                depth += 1;
            }
            ')' => {
                depth -= 1;
                if depth == 0 {
                    let ring_str: String = chars[ring_start..=i].iter().collect();
                    rings.push(ring_str);
                }
            }
            _ => {}
        }
    }

    if rings.is_empty() {
        return Err(GeoFormatError::InvalidWkt("POLYGON must have at least one ring".into()));
    }

    fn parse_ring(ring_str: &str) -> Result<Vec<(i64, i64)>, GeoFormatError> {
        let ring_str = ring_str.trim();
        if !ring_str.starts_with('(') || !ring_str.ends_with(')') {
            return Err(GeoFormatError::InvalidWkt("ring must be enclosed in parentheses".into()));
        }

        let content = &ring_str[1..ring_str.len() - 1];
        let points: Vec<&str> = content.split(',').collect();

        if points.len() < 3 {
            return Err(GeoFormatError::TooFewVertices(points.len()));
        }

        let mut result = Vec::with_capacity(points.len());
        for point_str in points {
            let parts: Vec<&str> = point_str.trim().split_whitespace().collect();
            if parts.len() < 2 {
                return Err(GeoFormatError::InvalidWkt(format!("invalid point: {}", point_str)));
            }
            let lon: f64 = parts[0].parse()
                .map_err(|_| GeoFormatError::InvalidWkt("invalid longitude".into()))?;
            let lat: f64 = parts[1].parse()
                .map_err(|_| GeoFormatError::InvalidWkt("invalid latitude".into()))?;
            validate_coordinates(lat, lon)?;
            result.push((degrees_to_nano(lat), degrees_to_nano(lon)));
        }
        Ok(result)
    }

    let exterior = parse_ring(&rings[0])?;
    let holes: Result<Vec<_>, _> = rings[1..].iter().map(|r| parse_ring(r)).collect();

    Ok((exterior, holes?))
}

/// Converts nanodegree coordinates to a GeoJSON Point string.
///
/// # Arguments
/// * `lat_nano` - Latitude in nanodegrees
/// * `lon_nano` - Longitude in nanodegrees
///
/// # Returns
/// * GeoJSON Point as a JSON string
pub fn to_geojson_point(lat_nano: i64, lon_nano: i64) -> String {
    format!(
        r#"{{"type":"Point","coordinates":[{},{}]}}"#,
        nano_to_degrees(lon_nano),
        nano_to_degrees(lat_nano)
    )
}

/// Converts nanodegree coordinates to a GeoJSON Polygon string.
///
/// # Arguments
/// * `exterior` - Exterior ring as vec of (lat_nano, lon_nano)
/// * `holes` - Optional holes as vec of rings
///
/// # Returns
/// * GeoJSON Polygon as a JSON string
pub fn to_geojson_polygon(exterior: &[(i64, i64)], holes: Option<&[Vec<(i64, i64)>]>) -> String {
    fn ring_to_json(ring: &[(i64, i64)]) -> String {
        let points: Vec<String> = ring.iter()
            .map(|&(lat, lon)| format!("[{},{}]", nano_to_degrees(lon), nano_to_degrees(lat)))
            .collect();
        format!("[{}]", points.join(","))
    }

    let mut rings = vec![ring_to_json(exterior)];
    if let Some(holes) = holes {
        for hole in holes {
            rings.push(ring_to_json(hole));
        }
    }

    format!(
        r#"{{"type":"Polygon","coordinates":[{}]}}"#,
        rings.join(",")
    )
}

/// Converts nanodegree coordinates to a WKT POINT.
///
/// # Arguments
/// * `lat_nano` - Latitude in nanodegrees
/// * `lon_nano` - Longitude in nanodegrees
///
/// # Returns
/// * WKT POINT string
pub fn to_wkt_point(lat_nano: i64, lon_nano: i64) -> String {
    format!("POINT({} {})", nano_to_degrees(lon_nano), nano_to_degrees(lat_nano))
}

/// Converts nanodegree coordinates to a WKT POLYGON.
///
/// # Arguments
/// * `exterior` - Exterior ring as vec of (lat_nano, lon_nano)
/// * `holes` - Optional holes as vec of rings
///
/// # Returns
/// * WKT POLYGON string
pub fn to_wkt_polygon(exterior: &[(i64, i64)], holes: Option<&[Vec<(i64, i64)>]>) -> String {
    fn ring_to_wkt(ring: &[(i64, i64)]) -> String {
        let points: Vec<String> = ring.iter()
            .map(|&(lat, lon)| format!("{} {}", nano_to_degrees(lon), nano_to_degrees(lat)))
            .collect();
        format!("({})", points.join(", "))
    }

    let mut rings = vec![ring_to_wkt(exterior)];
    if let Some(holes) = holes {
        for hole in holes {
            rings.push(ring_to_wkt(hole));
        }
    }

    format!("POLYGON({})", rings.join(", "))
}

/// Validates latitude and longitude bounds.
fn validate_coordinates(lat: f64, lon: f64) -> Result<(), GeoFormatError> {
    if lat < -LAT_MAX || lat > LAT_MAX {
        return Err(GeoFormatError::LatitudeOutOfBounds(lat));
    }
    if lon < -LON_MAX || lon > LON_MAX {
        return Err(GeoFormatError::LongitudeOutOfBounds(lon));
    }
    Ok(())
}

// ============================================================================
// Polygon Validation (per add-polygon-validation spec)
// Self-intersection detection for polygon queries
// ============================================================================

/// Error indicating a polygon self-intersection.
#[derive(Debug, Clone)]
pub struct PolygonValidationError {
    /// Index of the first intersecting segment (0-based).
    pub segment1_index: usize,
    /// Index of the second intersecting segment (0-based).
    pub segment2_index: usize,
    /// Approximate intersection point (lat, lon) in degrees.
    pub intersection_point: (f64, f64),
    /// Human-readable error message.
    pub message: String,
}

impl std::fmt::Display for PolygonValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for PolygonValidationError {}

/// Intersection result from polygon validation.
#[derive(Debug, Clone)]
pub struct IntersectionInfo {
    /// Index of the first intersecting segment.
    pub segment1_index: usize,
    /// Index of the second intersecting segment.
    pub segment2_index: usize,
    /// Approximate intersection point (lat, lon) in degrees.
    pub intersection_point: (f64, f64),
}

/// Checks if two line segments intersect.
///
/// Uses the cross product method with proper handling of collinear cases.
///
/// # Arguments
/// * `p1`, `p2` - First segment endpoints (lat, lon)
/// * `p3`, `p4` - Second segment endpoints (lat, lon)
///
/// # Returns
/// * `true` if the segments intersect, `false` otherwise
pub fn segments_intersect(
    p1: (f64, f64),
    p2: (f64, f64),
    p3: (f64, f64),
    p4: (f64, f64),
) -> bool {
    fn cross_product(o: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
        (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
    }

    fn on_segment(p: (f64, f64), q: (f64, f64), r: (f64, f64)) -> bool {
        q.0 >= p.0.min(r.0) && q.0 <= p.0.max(r.0) &&
        q.1 >= p.1.min(r.1) && q.1 <= p.1.max(r.1)
    }

    let d1 = cross_product(p3, p4, p1);
    let d2 = cross_product(p3, p4, p2);
    let d3 = cross_product(p1, p2, p3);
    let d4 = cross_product(p1, p2, p4);

    // General case: segments cross
    if ((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0)) &&
       ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0)) {
        return true;
    }

    // Collinear cases
    const EPS: f64 = 1e-10;
    if d1.abs() < EPS && on_segment(p3, p1, p4) { return true; }
    if d2.abs() < EPS && on_segment(p3, p2, p4) { return true; }
    if d3.abs() < EPS && on_segment(p1, p3, p2) { return true; }
    if d4.abs() < EPS && on_segment(p1, p4, p2) { return true; }

    false
}

/// Validates that a polygon has no self-intersections.
///
/// Uses an O(n²) algorithm suitable for polygons with reasonable vertex counts.
/// For very large polygons, consider implementing a sweep line algorithm.
///
/// # Arguments
/// * `vertices` - Slice of (lat, lon) tuples in degrees
/// * `raise_on_error` - If true, returns Err on first intersection
///
/// # Returns
/// * `Ok(Vec<IntersectionInfo>)` - List of all intersections found (empty if valid)
/// * `Err(PolygonValidationError)` - First intersection if `raise_on_error` is true
///
/// # Example
/// ```
/// use archerdb::validate_polygon_no_self_intersection;
///
/// // Valid square
/// let square = vec![(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
/// let result = validate_polygon_no_self_intersection(&square, true);
/// assert!(result.is_ok());
///
/// // Self-intersecting bow-tie
/// let bowtie = vec![(0.0, 0.0), (1.0, 1.0), (1.0, 0.0), (0.0, 1.0)];
/// let result = validate_polygon_no_self_intersection(&bowtie, true);
/// assert!(result.is_err());
/// ```
pub fn validate_polygon_no_self_intersection(
    vertices: &[(f64, f64)],
    raise_on_error: bool,
) -> Result<Vec<IntersectionInfo>, PolygonValidationError> {
    // A triangle cannot self-intersect (3 vertices = 3 edges, need at least 4 for crossing)
    if vertices.len() < 4 {
        return Ok(Vec::new());
    }

    let mut intersections = Vec::new();
    let n = vertices.len();

    // Check all pairs of non-adjacent edges
    for i in 0..n {
        let p1 = vertices[i];
        let p2 = vertices[(i + 1) % n];

        // Start from i+2 to skip adjacent edges (they share a vertex)
        for j in (i + 2)..n {
            // Skip if edges share a vertex (adjacent edges)
            if j == (i + n - 1) % n {
                continue;
            }

            let p3 = vertices[j];
            let p4 = vertices[(j + 1) % n];

            if segments_intersect(p1, p2, p3, p4) {
                // Calculate approximate intersection point for error message
                let ix = (p1.0 + p2.0 + p3.0 + p4.0) / 4.0;
                let iy = (p1.1 + p2.1 + p3.1 + p4.1) / 4.0;
                let intersection = (ix, iy);

                if raise_on_error {
                    return Err(PolygonValidationError {
                        segment1_index: i,
                        segment2_index: j,
                        intersection_point: intersection,
                        message: format!(
                            "Polygon self-intersects: edge {}-{} crosses edge {}-{} near ({:.6}, {:.6})",
                            i, (i + 1) % n, j, (j + 1) % n, ix, iy
                        ),
                    });
                }

                intersections.push(IntersectionInfo {
                    segment1_index: i,
                    segment2_index: j,
                    intersection_point: intersection,
                });
            }
        }
    }

    Ok(intersections)
}

/// Validates a PolygonQuery for self-intersections.
///
/// # Arguments
/// * `query` - The polygon query to validate
///
/// # Returns
/// * `Ok(())` if the polygon is valid
/// * `Err(GeoError::InvalidPolygon)` if the polygon self-intersects
pub fn validate_polygon_query(query: &PolygonQuery) -> Result<(), GeoError> {
    // Convert vertices to degree tuples for validation
    let vertices: Vec<(f64, f64)> = query.vertices
        .iter()
        .map(|v| (nano_to_degrees(v.lat_nano), nano_to_degrees(v.lon_nano)))
        .collect();

    match validate_polygon_no_self_intersection(&vertices, true) {
        Ok(_) => Ok(()),
        Err(e) => Err(GeoError::InvalidPolygon(e.message)),
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

    // ========================================================================
    // Sub-Meter Precision Tests
    // ========================================================================
    // Per openspec/changes/add-submeter-precision/specs/data-model/spec.md
    //
    // ArcherDB uses nanodegrees (10^-9 degrees) stored as i64 for coordinates.
    // This provides approximately 0.1mm precision at the equator, which exceeds
    // modern GPS technologies including RTK GPS (1-2cm accuracy).

    #[test]
    fn test_submeter_exact_nanodegree_preservation() {
        // Per spec: "exact nanodegree values SHALL be preserved"
        // Test with high-precision coordinates (9 decimal places)
        let original_lat = 37.774929123_f64; // San Francisco
        let original_lon = -122.419415678_f64;

        // Convert to nanodegrees
        let lat_nano = degrees_to_nano(original_lat);
        let lon_nano = degrees_to_nano(original_lon);

        // Expected exact values
        assert_eq!(lat_nano, 37_774_929_123);
        assert_eq!(lon_nano, -122_419_415_678);

        // Convert back - should be exact within f64 precision
        let lat_back = nano_to_degrees(lat_nano);
        let lon_back = nano_to_degrees(lon_nano);

        assert!((lat_back - original_lat).abs() < 1e-9);
        assert!((lon_back - original_lon).abs() < 1e-9);
    }

    #[test]
    fn test_submeter_rtk_gps_precision_preserved() {
        // RTK GPS provides 1-2 cm accuracy
        // 2 cm ≈ 180 nanodegrees at the equator
        // Per spec: nanodegrees exceed RTK precision by ~100x
        const RTK_PRECISION_NANO: i64 = 180; // ~2cm in nanodegrees

        // Create two coordinates that differ by less than RTK precision
        let base_lat = 37.774929000_f64;
        let precise_lat = base_lat + (RTK_PRECISION_NANO / 2) as f64 / NANODEGREES_PER_DEGREE as f64;

        let base_nano = degrees_to_nano(base_lat);
        let precise_nano = degrees_to_nano(precise_lat);

        // Values should be different (we can distinguish sub-RTK precision)
        assert_ne!(base_nano, precise_nano);

        // The difference should be preserved
        let diff = precise_nano - base_nano;
        assert_eq!(diff, RTK_PRECISION_NANO / 2);
    }

    #[test]
    fn test_submeter_float64_maintains_9_decimal_precision() {
        // Float64 has 15-17 significant digits
        // GPS coordinates typically have max 8-9 significant digits

        let test_coords = [
            (37.774929123_f64, -122.419415678_f64), // San Francisco
            (35.689487654_f64, 139.691706789_f64),  // Tokyo
            (-33.868820123_f64, 151.209295456_f64), // Sydney
            (51.507350987_f64, -0.127758321_f64),   // London
        ];

        for (lat, lon) in test_coords {
            let lat_nano = degrees_to_nano(lat);
            let lon_nano = degrees_to_nano(lon);
            let lat_back = nano_to_degrees(lat_nano);
            let lon_back = nano_to_degrees(lon_nano);

            // Should maintain 9 decimal places precision
            assert!((lat_back - lat).abs() < 1e-9);
            assert!((lon_back - lon).abs() < 1e-9);
        }
    }

    #[test]
    fn test_submeter_boundary_coordinates_precision() {
        // Test poles and antimeridian
        let test_coords = [
            (90.0_f64, 0.0_f64),                         // North pole
            (-90.0_f64, 0.0_f64),                        // South pole
            (0.0_f64, 180.0_f64),                        // Antimeridian east
            (0.0_f64, -180.0_f64),                       // Antimeridian west
            (89.999999999_f64, 179.999999999_f64),       // Near boundaries
            (-89.999999999_f64, -179.999999999_f64),     // Near boundaries
        ];

        for (lat, lon) in test_coords {
            let lat_nano = degrees_to_nano(lat);
            let lon_nano = degrees_to_nano(lon);
            let lat_back = nano_to_degrees(lat_nano);
            let lon_back = nano_to_degrees(lon_nano);

            assert!((lat_back - lat).abs() < 1e-9);
            assert!((lon_back - lon).abs() < 1e-9);
        }
    }

    #[test]
    fn test_submeter_various_latitudes_precision() {
        // Per spec: At all latitudes, nanodegrees provide sub-millimeter precision
        let latitudes = [0, 30, 45, 60, 80, 89];

        for lat_deg in latitudes {
            let lat = lat_deg as f64 + 0.123456789;
            let lat_nano = degrees_to_nano(lat);
            let lat_back = nano_to_degrees(lat_nano);
            assert!((lat_back - lat).abs() < 1e-9);
        }
    }

    #[test]
    fn test_submeter_precision_constants() {
        // Verify precision constants are correct
        assert_eq!(NANODEGREES_PER_DEGREE, 1_000_000_000);
        assert_eq!(MM_PER_METER, 1000);
    }

    #[test]
    fn test_submeter_uwb_indoor_positioning_precision() {
        // UWB provides 10-30 cm accuracy
        // 30 cm ≈ 2,700 nanodegrees at the equator
        const UWB_PRECISION_CM: i64 = 30;
        const NANODEGREE_PRECISION_MM: f64 = 0.111;

        // Convert to nanodegrees: 30 cm = 300 mm = 300 / 0.111 ≈ 2703 nanodegrees
        let uwb_precision_nano = ((UWB_PRECISION_CM * 10) as f64 / NANODEGREE_PRECISION_MM) as i64;

        // Create coordinates that differ by 1/10th UWB precision
        let base_lat = 37.774929000_f64;
        let uwb_lat = base_lat + (uwb_precision_nano / 10) as f64 / NANODEGREES_PER_DEGREE as f64;

        let base_nano = degrees_to_nano(base_lat);
        let uwb_nano = degrees_to_nano(uwb_lat);

        // Values should be different
        assert_ne!(base_nano, uwb_nano);
    }

    // ========================================================================
    // GeoJSON/WKT Parsing Tests
    // ========================================================================

    #[test]
    fn test_parse_geojson_point() {
        let json = r#"{"type": "Point", "coordinates": [-122.4194, 37.7749]}"#;
        let (lat, lon) = parse_geojson_point(json).unwrap();
        assert_eq!(lat, 37_774_900_000);
        assert_eq!(lon, -122_419_400_000);
    }

    #[test]
    fn test_parse_geojson_point_with_altitude() {
        let json = r#"{"type": "Point", "coordinates": [-122.4194, 37.7749, 100]}"#;
        let (lat, lon) = parse_geojson_point(json).unwrap();
        assert_eq!(lat, 37_774_900_000);
        assert_eq!(lon, -122_419_400_000);
    }

    #[test]
    fn test_parse_geojson_point_invalid_type() {
        let json = r#"{"type": "Polygon", "coordinates": [[0, 0]]}"#;
        let result = parse_geojson_point(json);
        assert!(matches!(result, Err(GeoFormatError::WrongType(_))));
    }

    #[test]
    fn test_parse_geojson_point_invalid_lat() {
        let json = r#"{"type": "Point", "coordinates": [0, 91]}"#;
        let result = parse_geojson_point(json);
        assert!(matches!(result, Err(GeoFormatError::LatitudeOutOfBounds(_))));
    }

    #[test]
    fn test_parse_geojson_polygon() {
        let json = r#"{"type": "Polygon", "coordinates": [[[-122.4, 37.7], [-122.3, 37.7], [-122.3, 37.8], [-122.4, 37.7]]]}"#;
        let (exterior, holes) = parse_geojson_polygon(json).unwrap();
        assert_eq!(exterior.len(), 4);
        assert_eq!(holes.len(), 0);
    }

    #[test]
    fn test_parse_geojson_polygon_with_hole() {
        let json = r#"{
            "type": "Polygon",
            "coordinates": [
                [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
                [[2, 2], [4, 2], [4, 4], [2, 4], [2, 2]]
            ]
        }"#;
        let (exterior, holes) = parse_geojson_polygon(json).unwrap();
        assert_eq!(exterior.len(), 5);
        assert_eq!(holes.len(), 1);
        assert_eq!(holes[0].len(), 5);
    }

    #[test]
    fn test_parse_wkt_point() {
        let wkt = "POINT(-122.4194 37.7749)";
        let (lat, lon) = parse_wkt_point(wkt).unwrap();
        assert_eq!(lat, 37_774_900_000);
        assert_eq!(lon, -122_419_400_000);
    }

    #[test]
    fn test_parse_wkt_point_with_spaces() {
        let wkt = "POINT( -122.4194  37.7749 )";
        let (lat, lon) = parse_wkt_point(wkt).unwrap();
        assert_eq!(lat, 37_774_900_000);
        assert_eq!(lon, -122_419_400_000);
    }

    #[test]
    fn test_parse_wkt_point_lowercase() {
        let wkt = "point(0 0)";
        let (lat, lon) = parse_wkt_point(wkt).unwrap();
        assert_eq!(lat, 0);
        assert_eq!(lon, 0);
    }

    #[test]
    fn test_parse_wkt_polygon() {
        let wkt = "POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))";
        let (exterior, holes) = parse_wkt_polygon(wkt).unwrap();
        assert_eq!(exterior.len(), 5);
        assert_eq!(holes.len(), 0);
    }

    #[test]
    fn test_parse_wkt_polygon_with_hole() {
        let wkt = "POLYGON((0 0, 10 0, 10 10, 0 10, 0 0), (2 2, 4 2, 4 4, 2 4, 2 2))";
        let (exterior, holes) = parse_wkt_polygon(wkt).unwrap();
        assert_eq!(exterior.len(), 5);
        assert_eq!(holes.len(), 1);
        assert_eq!(holes[0].len(), 5);
    }

    #[test]
    fn test_to_geojson_point() {
        let lat_nano = 37_774_900_000i64;
        let lon_nano = -122_419_400_000i64;
        let geojson = to_geojson_point(lat_nano, lon_nano);
        assert!(geojson.contains(r#""type":"Point""#));
        assert!(geojson.contains("coordinates"));
        assert!(geojson.contains("-122.4194"));
        assert!(geojson.contains("37.7749"));
    }

    #[test]
    fn test_to_geojson_polygon() {
        let exterior = vec![
            (0i64, 0i64),
            (1_000_000_000i64, 0i64),
            (1_000_000_000i64, 1_000_000_000i64),
            (0i64, 0i64),
        ];
        let geojson = to_geojson_polygon(&exterior, None);
        assert!(geojson.contains(r#""type":"Polygon""#));
        assert!(geojson.contains("coordinates"));
    }

    #[test]
    fn test_to_wkt_point() {
        let lat_nano = 37_774_900_000i64;
        let lon_nano = -122_419_400_000i64;
        let wkt = to_wkt_point(lat_nano, lon_nano);
        assert!(wkt.starts_with("POINT("));
        assert!(wkt.ends_with(")"));
        // Roundtrip
        let (lat_back, lon_back) = parse_wkt_point(&wkt).unwrap();
        assert_eq!(lat_back, lat_nano);
        assert_eq!(lon_back, lon_nano);
    }

    #[test]
    fn test_to_wkt_polygon() {
        let exterior = vec![
            (0i64, 0i64),
            (1_000_000_000i64, 0i64),
            (1_000_000_000i64, 1_000_000_000i64),
            (0i64, 0i64),
        ];
        let wkt = to_wkt_polygon(&exterior, None);
        assert!(wkt.starts_with("POLYGON("));
        assert!(wkt.ends_with(")"));
    }

    #[test]
    fn test_roundtrip_geojson_point() {
        let original_lat = 37.7749f64;
        let original_lon = -122.4194f64;
        let lat_nano = degrees_to_nano(original_lat);
        let lon_nano = degrees_to_nano(original_lon);

        let geojson_str = to_geojson_point(lat_nano, lon_nano);
        let (parsed_lat, parsed_lon) = parse_geojson_point(&geojson_str).unwrap();

        assert_eq!(parsed_lat, lat_nano);
        assert_eq!(parsed_lon, lon_nano);
    }

    #[test]
    fn test_geo_format_enum() {
        assert_eq!(GeoFormat::Native as u8, 0);
        assert_eq!(GeoFormat::GeoJson as u8, 1);
        assert_eq!(GeoFormat::Wkt as u8, 2);
    }

    // ========================================================================
    // Polygon Self-Intersection Validation Tests (add-polygon-validation spec)
    // ========================================================================

    #[test]
    fn test_valid_triangle() {
        // Triangle cannot self-intersect (too few edges)
        let triangle = vec![(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)];
        let result = validate_polygon_no_self_intersection(&triangle, false);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 0);
    }

    #[test]
    fn test_valid_square() {
        // Simple square has no self-intersections
        let square = vec![(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
        let result = validate_polygon_no_self_intersection(&square, false);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 0);
    }

    #[test]
    fn test_valid_convex_pentagon() {
        // Convex pentagon has no self-intersections
        use std::f64::consts::PI;
        let pentagon: Vec<(f64, f64)> = (0..5)
            .map(|i| {
                let angle = 2.0 * PI * i as f64 / 5.0;
                (angle.cos(), angle.sin())
            })
            .collect();
        let result = validate_polygon_no_self_intersection(&pentagon, false);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 0);
    }

    #[test]
    fn test_bowtie_polygon_intersects() {
        // Bow-tie (figure-8) polygon has a self-intersection
        let bowtie = vec![(0.0, 0.0), (1.0, 1.0), (1.0, 0.0), (0.0, 1.0)];
        let result = validate_polygon_no_self_intersection(&bowtie, false);
        assert!(result.is_ok());
        let intersections = result.unwrap();
        assert!(!intersections.is_empty());
    }

    #[test]
    fn test_bowtie_raises_error() {
        // Bow-tie polygon returns Err when raise_on_error=true
        let bowtie = vec![(0.0, 0.0), (1.0, 1.0), (1.0, 0.0), (0.0, 1.0)];
        let result = validate_polygon_no_self_intersection(&bowtie, true);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.segment1_index < 4);
        assert!(err.segment2_index < 4);
        assert!(err.message.contains("self-intersects"));
    }

    #[test]
    fn test_valid_concave_polygon() {
        // Concave (non-convex) polygon without self-intersections (L-shape)
        let l_shape = vec![
            (0.0, 0.0), (2.0, 0.0), (2.0, 1.0),
            (1.0, 1.0), (1.0, 2.0), (0.0, 2.0),
        ];
        let result = validate_polygon_no_self_intersection(&l_shape, false);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 0);
    }

    #[test]
    fn test_star_polygon_intersects() {
        // 5-pointed star (drawn without lifting pen) self-intersects
        use std::f64::consts::PI;
        let star: Vec<(f64, f64)> = (0..5)
            .map(|i| {
                let angle = PI / 2.0 + i as f64 * 4.0 * PI / 5.0;
                (angle.cos(), angle.sin())
            })
            .collect();
        let result = validate_polygon_no_self_intersection(&star, false);
        assert!(result.is_ok());
        let intersections = result.unwrap();
        assert!(!intersections.is_empty());
    }

    #[test]
    fn test_segments_intersect_basic() {
        // Clearly crossing segments
        assert!(segments_intersect(
            (0.0, 0.0), (1.0, 1.0),  // Diagonal
            (0.0, 1.0), (1.0, 0.0),  // Opposite diagonal
        ));

        // Parallel segments (no intersection)
        assert!(!segments_intersect(
            (0.0, 0.0), (1.0, 0.0),  // Horizontal
            (0.0, 1.0), (1.0, 1.0),  // Parallel horizontal
        ));

        // T-junction (endpoint touches)
        assert!(segments_intersect(
            (0.0, 0.5), (1.0, 0.5),  // Horizontal
            (0.5, 0.0), (0.5, 0.5),  // Vertical ending at intersection
        ));
    }

    #[test]
    fn test_polygon_validation_error_attributes() {
        let err = PolygonValidationError {
            segment1_index: 1,
            segment2_index: 3,
            intersection_point: (0.5, 0.5),
            message: "Test error".to_string(),
        };

        assert_eq!(err.segment1_index, 1);
        assert_eq!(err.segment2_index, 3);
        assert_eq!(err.intersection_point, (0.5, 0.5));
        assert!(err.to_string().contains("Test error"));
    }

    #[test]
    fn test_empty_or_small_polygon() {
        // Empty
        let empty: Vec<(f64, f64)> = vec![];
        assert!(validate_polygon_no_self_intersection(&empty, false).is_ok());
        assert_eq!(validate_polygon_no_self_intersection(&empty, false).unwrap().len(), 0);

        // Single point
        let single = vec![(0.0, 0.0)];
        assert_eq!(validate_polygon_no_self_intersection(&single, false).unwrap().len(), 0);

        // Two points (line)
        let line = vec![(0.0, 0.0), (1.0, 1.0)];
        assert_eq!(validate_polygon_no_self_intersection(&line, false).unwrap().len(), 0);

        // Three points (triangle - minimum valid polygon)
        let triangle = vec![(0.0, 0.0), (1.0, 0.0), (0.0, 1.0)];
        assert_eq!(validate_polygon_no_self_intersection(&triangle, false).unwrap().len(), 0);
    }

    #[test]
    fn test_validate_polygon_query() {
        // Valid square query
        let valid_query = PolygonQuery::new(&[
            [0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0],
        ], 100).unwrap();
        assert!(validate_polygon_query(&valid_query).is_ok());

        // Invalid bow-tie query
        let invalid_query = PolygonQuery::new(&[
            [0.0, 0.0], [1.0, 1.0], [1.0, 0.0], [0.0, 1.0],
        ], 100).unwrap();
        assert!(validate_polygon_query(&invalid_query).is_err());
    }

    #[test]
    fn test_encode_query_uuid_batch_request() {
        let ids = [
            0x0102030405060708090a0b0c0d0e0f10u128,
            0x1112131415161718191a1b1c1d1e1f20u128,
        ];
        let buffer = encode_query_uuid_batch_request(&ids);
        let bytes = buffer.as_slice();

        assert_eq!(bytes.len(), 8 + ids.len() * 16);
        assert_eq!(u32::from_le_bytes(bytes[0..4].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(bytes[4..8].try_into().unwrap()), 0);
        assert_eq!(&bytes[8..24], &ids[0].to_le_bytes());
        assert_eq!(&bytes[24..40], &ids[1].to_le_bytes());
    }

    #[test]
    fn test_parse_query_uuid_batch_response() {
        let event1 = GeoEvent {
            entity_id: 1,
            lat_nano: 10,
            lon_nano: 20,
            ..Default::default()
        };
        let event2 = GeoEvent {
            entity_id: 2,
            lat_nano: 30,
            lon_nano: 40,
            ..Default::default()
        };
        let raw1: arch_client::geo_event_t = event1.into();
        let raw2: arch_client::geo_event_t = event2.into();

        let event_size = std::mem::size_of::<arch_client::geo_event_t>();
        let header_size = 16usize;
        let indices_size = 2usize;
        let indices_end = header_size + indices_size;
        let events_offset = align_forward(indices_end, 16);
        let total_size = events_offset + event_size * 2;

        let mut reply = vec![0u8; total_size];
        reply[0..4].copy_from_slice(&2u32.to_le_bytes());
        reply[4..8].copy_from_slice(&1u32.to_le_bytes());
        reply[header_size..header_size + 2].copy_from_slice(&1u16.to_le_bytes());

        unsafe {
            std::ptr::copy_nonoverlapping(
                &raw1 as *const _ as *const u8,
                reply[events_offset..].as_mut_ptr(),
                event_size,
            );
            std::ptr::copy_nonoverlapping(
                &raw2 as *const _ as *const u8,
                reply[events_offset + event_size..].as_mut_ptr(),
                event_size,
            );
        }

        let parsed = parse_query_uuid_batch_response(&reply).unwrap();
        assert_eq!(parsed.found_count, 2);
        assert_eq!(parsed.not_found_count, 1);
        assert_eq!(parsed.not_found_indices, vec![1]);
        assert_eq!(parsed.events.len(), 2);
        assert_eq!(parsed.events[0].entity_id, 1);
        assert_eq!(parsed.events[1].entity_id, 2);
    }
}
