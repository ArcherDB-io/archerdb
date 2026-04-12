// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package types

/*
#include "../native/arch_client.h"
*/
import "C"
import (
	"fmt"
	"math"
	"time"
	"unsafe"
)

// ============================================================================
// Constants
// ============================================================================

const (
	// Coordinate bounds (degrees)

	// LatMax is the maximum valid latitude in degrees (+90 = North Pole).
	LatMax float64 = 90.0
	// LonMax is the maximum valid longitude in degrees (+180 = International Date Line).
	LonMax float64 = 180.0

	// Conversion factors for unit transformations

	// NanodegreesPerDegree is the conversion factor from degrees to nanodegrees.
	// Example: 37.7749 degrees = 37,774,900,000 nanodegrees
	NanodegreesPerDegree int64 = 1_000_000_000

	// MmPerMeter is the conversion factor from meters to millimeters.
	MmPerMeter int64 = 1000

	// CentidegreesPerDegree is the conversion factor from degrees to centidegrees.
	// Used for heading: 90 degrees = 9000 centidegrees
	CentidegreesPerDegree int64 = 100

	// API limits (production config with 10MB message_size_max)

	// BatchSizeMax is the maximum number of events in a single insert/upsert batch.
	BatchSizeMax int = 10_000

	// QueryUUIDBatchMax is the maximum number of UUIDs in a batch lookup.
	QueryUUIDBatchMax int = 10_000

	// QueryLimitMax is the maximum number of results for a single query.
	QueryLimitMax int = 81_000

	// PolygonVerticesMax is the maximum vertices in a polygon query boundary.
	PolygonVerticesMax int = 10_000

	// Polygon hole limits

	// PolygonHolesMax is the maximum number of holes (exclusion zones) in a polygon.
	PolygonHolesMax int = 100

	// PolygonHoleVerticesMin is the minimum vertices required for a valid hole.
	PolygonHoleVerticesMin int = 3

	// Safe limits for default 1MB message configuration

	// BatchSizeMaxDefault is the recommended batch size for default configuration.
	BatchSizeMaxDefault int = 8_000

	// QueryLimitMaxDefault is the recommended query limit for default configuration.
	QueryLimitMaxDefault int = 8_000
)

// ============================================================================
// GeoEvent Flags
// ============================================================================

// GeoEventFlags are status flags for GeoEvent records.
// Maps to GeoEventFlags in geo_event.zig
type GeoEventFlags uint16

const (
	GeoEventFlagNone        GeoEventFlags = 0
	GeoEventFlagLinked      GeoEventFlags = 1 << 0 // Event is part of a linked chain
	GeoEventFlagImported    GeoEventFlags = 1 << 1 // Event was imported with client-provided timestamp
	GeoEventFlagStationary  GeoEventFlags = 1 << 2 // Entity is not moving
	GeoEventFlagLowAccuracy GeoEventFlags = 1 << 3 // GPS accuracy below threshold
	GeoEventFlagOffline     GeoEventFlags = 1 << 4 // Entity is offline/unreachable
	GeoEventFlagDeleted     GeoEventFlags = 1 << 5 // Entity has been deleted (GDPR compliance)
)

// ============================================================================
// Operation Codes
// ============================================================================

// GeoOperation represents ArcherDB geospatial operation codes.
// Maps to Operation enum in archerdb.zig
type GeoOperation uint8

const (
	GeoOperationInsertEvents    GeoOperation = 146 // vsr_operations_reserved (128) + 18
	GeoOperationUpsertEvents    GeoOperation = 147 // vsr_operations_reserved (128) + 19
	GeoOperationDeleteEntities  GeoOperation = 148 // vsr_operations_reserved (128) + 20
	GeoOperationQueryUUID       GeoOperation = 149 // vsr_operations_reserved (128) + 21
	GeoOperationQueryRadius     GeoOperation = 150 // vsr_operations_reserved (128) + 22
	GeoOperationQueryPolygon    GeoOperation = 151 // vsr_operations_reserved (128) + 23
	GeoOperationPing            GeoOperation = 152 // vsr_operations_reserved (128) + 24
	GeoOperationGetStatus       GeoOperation = 153 // vsr_operations_reserved (128) + 25
	GeoOperationQueryLatest     GeoOperation = 154 // vsr_operations_reserved (128) + 26
	GeoOperationCleanupExpired  GeoOperation = 155 // vsr_operations_reserved (128) + 27
	GeoOperationQueryUUIDBatch  GeoOperation = 156 // vsr_operations_reserved (128) + 28
	GeoOperationGetTopology     GeoOperation = 157 // vsr_operations_reserved (128) + 29
	GeoOperationTTLSet          GeoOperation = 158 // vsr_operations_reserved (128) + 30
	GeoOperationTTLExtend       GeoOperation = 159 // vsr_operations_reserved (128) + 31
	GeoOperationTTLClear        GeoOperation = 160 // vsr_operations_reserved (128) + 32
)

// ============================================================================
// Result Codes
// ============================================================================

// InsertGeoEventResult represents result codes for GeoEvent insert operations.
// Maps to InsertGeoEventResult in geo_state_machine.zig
type InsertGeoEventResult uint8

const (
	InsertResultOK                          InsertGeoEventResult = 0
	InsertResultLinkedEventFailed           InsertGeoEventResult = 1
	InsertResultLinkedEventChainOpen        InsertGeoEventResult = 2
	InsertResultTimestampMustBeZero         InsertGeoEventResult = 3
	InsertResultReservedField               InsertGeoEventResult = 4
	InsertResultReservedFlag                InsertGeoEventResult = 5
	InsertResultIDMustNotBeZero             InsertGeoEventResult = 6
	InsertResultEntityIDMustNotBeZero       InsertGeoEventResult = 7
	InsertResultInvalidCoordinates          InsertGeoEventResult = 8
	InsertResultLatOutOfRange               InsertGeoEventResult = 9
	InsertResultLonOutOfRange               InsertGeoEventResult = 10
	InsertResultExistsWithDifferentEntityID InsertGeoEventResult = 11
	InsertResultExistsWithDifferentCoords   InsertGeoEventResult = 12
	InsertResultExists                      InsertGeoEventResult = 13
	InsertResultHeadingOutOfRange           InsertGeoEventResult = 14
	InsertResultTTLInvalid                  InsertGeoEventResult = 15
)

// DeleteEntityResult represents result codes for entity delete operations.
type DeleteEntityResult uint8

const (
	DeleteResultOK                    DeleteEntityResult = 0
	DeleteResultLinkedEventFailed     DeleteEntityResult = 1
	DeleteResultEntityIDMustNotBeZero DeleteEntityResult = 2
	DeleteResultEntityNotFound        DeleteEntityResult = 3
)

// TtlOperationResult represents result codes for TTL operations.
// Maps to TtlOperationResult in ttl.zig
type TtlOperationResult uint8

const (
	TtlResultSuccess        TtlOperationResult = 0
	TtlResultEntityNotFound TtlOperationResult = 1
	TtlResultInvalidTTL     TtlOperationResult = 2
	TtlResultNotPermitted   TtlOperationResult = 3
	TtlResultEntityImmutable TtlOperationResult = 4
)

// ============================================================================
// TTL Request/Response Types
// ============================================================================

// TtlSetRequest is the request type for setting an absolute TTL.
// Wire format: 64 bytes total, must match server's TtlSetRequest.
type TtlSetRequest struct {
	EntityID   Uint128    // 16 bytes
	TTLSeconds uint32     // 4 bytes
	Flags      uint32     // 4 bytes
	Reserved   [40]uint8  // 40 bytes padding
}

// TtlSetResponse is the response type for TTL set operations.
// Wire format: 64 bytes total, must match server's TtlSetResponse.
type TtlSetResponse struct {
	EntityID           Uint128             // 16 bytes
	PreviousTTLSeconds uint32              // 4 bytes
	NewTTLSeconds      uint32              // 4 bytes
	Result             TtlOperationResult  // 1 byte
	Padding            [3]uint8            // 3 bytes
	Reserved           [32]uint8           // 32 bytes padding
}

// TtlExtendRequest is the request type for extending an entity's TTL.
// Wire format: 64 bytes total, must match server's TtlExtendRequest.
type TtlExtendRequest struct {
	EntityID         Uint128    // 16 bytes
	ExtendBySeconds  uint32     // 4 bytes
	Flags            uint32     // 4 bytes
	Reserved         [40]uint8  // 40 bytes padding
}

// TtlExtendResponse is the response type for TTL extend operations.
// Wire format: 64 bytes total, must match server's TtlExtendResponse.
type TtlExtendResponse struct {
	EntityID           Uint128             // 16 bytes
	PreviousTTLSeconds uint32              // 4 bytes
	NewTTLSeconds      uint32              // 4 bytes
	Result             TtlOperationResult  // 1 byte
	Padding            [3]uint8            // 3 bytes
	Reserved           [32]uint8           // 32 bytes padding
}

// TtlClearRequest is the request type for clearing an entity's TTL.
// Wire format: 64 bytes total, must match server's TtlClearRequest.
type TtlClearRequest struct {
	EntityID Uint128    // 16 bytes
	Flags    uint32     // 4 bytes
	Reserved [44]uint8  // 44 bytes padding
}

// TtlClearResponse is the response type for TTL clear operations.
// Wire format: 64 bytes total, must match server's TtlClearResponse.
type TtlClearResponse struct {
	EntityID           Uint128             // 16 bytes
	PreviousTTLSeconds uint32              // 4 bytes
	Result             TtlOperationResult  // 1 byte
	Padding            [3]uint8            // 3 bytes
	Reserved           [36]uint8           // 36 bytes padding
}

// ============================================================================
// GeoEvent - Core Data Structure
// ============================================================================

// GeoEvent represents a 128-byte geospatial event record.
//
// This is the core data structure for location tracking in ArcherDB.
// Coordinates are stored in nanodegrees (10^-9 degrees) for sub-millimeter precision.
//
// Example:
//
//	event := types.GeoEvent{
//	    EntityID:     types.ID(),
//	    LatNano:      37774900000,  // 37.7749 degrees
//	    LonNano:      -122419400000, // -122.4194 degrees
//	    GroupID:      fleetID,
//	    TTLSeconds:   86400,        // 24-hour TTL
//	}
type GeoEvent struct {
	// ID is the composite key: [S2 Cell ID (upper 64) | Timestamp (lower 64)]
	// Set to zero Uint128 for server-assigned ID, or provide for imported events.
	ID Uint128

	// EntityID is the UUID identifying the moving entity (vehicle, device, person).
	// Use types.ID() to generate a sortable UUID.
	EntityID Uint128

	// CorrelationID is a UUID for trip/session/job correlation across events.
	// Use zero Uint128 if not tracking correlations.
	CorrelationID Uint128

	// UserData is opaque application metadata (foreign key to sidecar database).
	UserData Uint128

	// LatNano is the latitude in nanodegrees (10^-9 degrees).
	// Valid range: -90,000,000,000 to +90,000,000,000
	LatNano int64

	// LonNano is the longitude in nanodegrees (10^-9 degrees).
	// Valid range: -180,000,000,000 to +180,000,000,000
	LonNano int64

	// GroupID is the fleet/region grouping identifier.
	// Use 0 for ungrouped events.
	GroupID uint64

	// Timestamp is the event timestamp in nanoseconds since Unix epoch.
	// Set to 0 for server-assigned timestamp.
	Timestamp uint64

	// AltitudeMM is the altitude in millimeters above WGS84 ellipsoid.
	AltitudeMM int32

	// VelocityMMS is the speed in millimeters per second.
	VelocityMMS uint32

	// TTLSeconds is the time-to-live in seconds (0 = never expires).
	TTLSeconds uint32

	// AccuracyMM is the GPS accuracy radius in millimeters.
	AccuracyMM uint32

	// HeadingCdeg is the heading in centidegrees (0-36000, where 0=North, 9000=East).
	HeadingCdeg uint16

	// Flags contains packed status flags.
	Flags GeoEventFlags

	// Reserved for future use (must be zero).
	// This ensures 128-byte struct alignment with the server.
	Reserved [12]byte
}

// ============================================================================
// Result Types
// ============================================================================

// InsertGeoEventsError represents a per-event result for batch insert operations.
type InsertGeoEventsError struct {
	Index  uint32
	Result InsertGeoEventResult
}

// DeleteEntitiesError represents a per-entity result for batch delete operations.
type DeleteEntitiesError struct {
	Index  uint32
	Result DeleteEntityResult
}

// ============================================================================
// Query Filters
// ============================================================================

// QueryUUIDFilter is a filter for UUID lookup queries.
// Wire format: 32 bytes total to match server's QueryUuidFilter.
type QueryUUIDFilter struct {
	EntityID Uint128    // 16 bytes
	Reserved [16]uint8  // 16 bytes padding
}

// QueryRadiusFilter is a filter for radius queries.
type QueryRadiusFilter struct {
	CenterLatNano int64
	CenterLonNano int64
	RadiusMM      uint32
	Limit         uint32
	TimestampMin  uint64
	TimestampMax  uint64
	GroupID       Uint128
	Reserved      [72]uint8 // Wire format padding to 128 bytes
}

// PolygonVertex represents a polygon vertex (lat/lon pair).
type PolygonVertex struct {
	LatNano int64
	LonNano int64
}

// PolygonHole represents a polygon hole (exclusion zone within the outer boundary).
// A hole is defined by a list of vertices in clockwise winding order.
// Points inside a hole are excluded from query results.
type PolygonHole struct {
	Vertices []PolygonVertex
}

// QueryPolygonFilter is a filter for polygon queries.
// A polygon can optionally have holes (exclusion zones). The outer boundary
// should be in counter-clockwise (CCW) winding order, while holes should
// be in clockwise (CW) winding order.
type QueryPolygonFilter struct {
	Vertices     []PolygonVertex
	Holes        []PolygonHole
	Limit        uint32
	TimestampMin uint64
	TimestampMax uint64
	GroupID      Uint128
}

// QueryLatestFilter is a filter for query_latest operation.
// Wire format: 128 bytes total, must match server's QueryLatestFilter exactly.
type QueryLatestFilter struct {
	Limit           uint32
	ReservedAlign   uint32    // Padding for 8-byte alignment
	GroupID         uint64    // Note: u64 (not Uint128) per wire format
	CursorTimestamp uint64
	Reserved        [104]uint8
}

// ============================================================================
// Response Types
// ============================================================================

// QueryUUIDBatchResult represents the wire format result for batch UUID lookup (16-byte header
// plus not-found indices and GeoEvents payload).
type QueryUUIDBatchResult struct {
	FoundCount      uint32
	NotFoundCount   uint32
	NotFoundIndices []uint16
	Events          []GeoEvent
}

// QueryResponse represents the wire format header for query responses (16 bytes).
// Matches QueryResponse struct in geo_state_machine.zig.
// The 16-byte size ensures GeoEvent results following the header are 16-byte aligned.
type QueryResponse struct {
	Count         uint32    // 4 bytes: Number of events in response
	HasMore       uint8     // 1 byte: 1 if more results available beyond limit
	PartialResult uint8     // 1 byte: 1 if result set was truncated
	Reserved      [10]uint8 // 10 bytes: Reserved for future flags
}

// QueryResult represents a query result with pagination support.
type QueryResult struct {
	Events  []GeoEvent
	HasMore bool
	Cursor  uint64 // Timestamp of last event for pagination
}

// DeleteResult represents the result of delete operations.
type DeleteResult struct {
	DeletedCount  int
	NotFoundCount int
}

// StatusResponse represents server status from archerdb_get_status operation.
// Matches StatusResponse in archerdb.zig (64 bytes).
type StatusResponse struct {
	RAMIndexCount    uint64 // Number of entities in RAM index
	RAMIndexCapacity uint64 // Total RAM index capacity
	RAMIndexLoadPct  uint32 // Load factor as percentage * 100 (e.g., 7000 = 70%)
	_padding         uint32 // Padding for alignment (matches Zig struct)
	TombstoneCount   uint64 // Number of tombstone entries
	TTLExpirations   uint64 // Total TTL expirations processed
	DeletionCount    uint64 // Total deletions processed
	Reserved         [16]byte // Reserved for future use
}

// PingRequest represents a ping request payload (8 bytes).
type PingRequest struct {
	PingData uint64
}

// StatusRequest represents a status request payload (8 bytes).
type StatusRequest struct {
	Reserved uint64
}

// PingResponse represents a pong response (4 bytes).
type PingResponse struct {
	Pong uint32
}

// LoadFactor returns the load factor as a decimal (e.g., 0.70).
func (s *StatusResponse) LoadFactor() float64 {
	return float64(s.RAMIndexLoadPct) / 10000.0
}

// ============================================================================
// Coordinate Conversion Helpers
// ============================================================================

// DegreesToNano converts degrees to nanodegrees (10^-9 degrees).
//
// Use for converting latitude/longitude from standard decimal degrees
// to ArcherDB's internal nanodegree representation.
//
// Example:
//
//	latNano := types.DegreesToNano(37.7749)  // San Francisco latitude
//	// latNano = 37774900000
func DegreesToNano(degrees float64) int64 {
	return int64(degrees * float64(NanodegreesPerDegree))
}

// NanoToDegrees converts nanodegrees back to decimal degrees.
//
// Example:
//
//	lat := types.NanoToDegrees(37774900000)
//	// lat = 37.7749
func NanoToDegrees(nano int64) float64 {
	return float64(nano) / float64(NanodegreesPerDegree)
}

// MetersToMM converts meters to millimeters.
//
// Use for altitude, radius, and accuracy values.
//
// Example:
//
//	radiusMM := types.MetersToMM(1000.5)  // 1 km radius
//	// radiusMM = 1000500
func MetersToMM(meters float64) int32 {
	return int32(math.Round(meters * float64(MmPerMeter)))
}

// MMToMeters converts millimeters back to meters.
func MMToMeters(mm int32) float64 {
	return float64(mm) / float64(MmPerMeter)
}

// HeadingToCentidegrees converts heading from degrees (0-360) to centidegrees (0-36000).
//
// Heading convention: 0 = North, 90 = East, 180 = South, 270 = West.
//
// Example:
//
//	heading := types.HeadingToCentidegrees(90.5)  // Heading East
//	// heading = 9050
func HeadingToCentidegrees(degrees float64) uint16 {
	return uint16(degrees * float64(CentidegreesPerDegree))
}

// CentidegreesToHeading converts centidegrees back to degrees.
func CentidegreesToHeading(cdeg uint16) float64 {
	return float64(cdeg) / float64(CentidegreesPerDegree)
}

// IsValidLatitude checks if latitude is within the valid range [-90, +90] degrees.
func IsValidLatitude(lat float64) bool {
	return lat >= -LatMax && lat <= LatMax
}

// IsValidLongitude checks if longitude is within the valid range [-180, +180] degrees.
func IsValidLongitude(lon float64) bool {
	return lon >= -LonMax && lon <= LonMax
}

// ============================================================================
// Builder Functions
// ============================================================================

// GeoEventOptions provides a user-friendly way to create GeoEvents.
//
// All units are in standard human-readable form. The SDK handles
// conversion to ArcherDB's internal units automatically.
//
// Example:
//
//	event, err := types.NewGeoEvent(types.GeoEventOptions{
//	    EntityID:  types.ID(),
//	    Latitude:  37.7749,      // Degrees
//	    Longitude: -122.4194,    // Degrees
//	    AltitudeM: 10.5,         // Meters above sea level
//	    Heading:   90.0,         // Degrees (East)
//	    GroupID:   fleetID,
//	    TTLSeconds: 86400,       // 24-hour TTL
//	})
type GeoEventOptions struct {
	// EntityID is the unique identifier for the entity (required).
	// Use types.ID() to generate a sortable UUID.
	EntityID Uint128

	// Latitude in decimal degrees (-90 to +90).
	// Positive = North, Negative = South.
	Latitude float64

	// Longitude in decimal degrees (-180 to +180).
	// Positive = East, Negative = West.
	Longitude float64

	// CorrelationID links events to a trip, session, or job (optional).
	CorrelationID Uint128

	// UserData is opaque application metadata (optional).
	// Use as a foreign key to reference data in your own database.
	UserData Uint128

	// GroupID groups entities by fleet, region, or tenant (optional).
	// Use 0 for ungrouped events.
	GroupID uint64

	// AltitudeM is the altitude in meters above WGS84 ellipsoid (optional).
	AltitudeM float64

	// VelocityMPS is the speed in meters per second (optional).
	VelocityMPS float64

	// TTLSeconds is the time-to-live in seconds (optional).
	// After this duration, the event is automatically expired.
	// Use 0 for no automatic expiration.
	TTLSeconds uint32

	// AccuracyM is the GPS accuracy radius in meters (optional).
	AccuracyM float64

	// Heading is the direction of travel in degrees (optional).
	// 0 = North, 90 = East, 180 = South, 270 = West.
	// Valid range: 0 to 360.
	Heading float64

	// Flags contains event status flags (optional).
	Flags GeoEventFlags
}

// NewGeoEvent creates a GeoEvent from user-friendly options.
//
// Handles automatic unit conversions:
//   - Latitude/Longitude: degrees to nanodegrees
//   - Altitude/Accuracy: meters to millimeters
//   - Velocity: meters/second to millimeters/second
//   - Heading: degrees to centidegrees
//
// Returns an error if coordinates are outside valid ranges.
//
// Example:
//
//	event, err := types.NewGeoEvent(types.GeoEventOptions{
//	    EntityID:  types.ID(),
//	    Latitude:  37.7749,
//	    Longitude: -122.4194,
//	})
//	if err != nil {
//	    // Handle invalid coordinates
//	}
func NewGeoEvent(opts GeoEventOptions) (GeoEvent, error) {
	if !IsValidLatitude(opts.Latitude) {
		return GeoEvent{}, fmt.Errorf("invalid latitude: %f, must be between -90 and +90", opts.Latitude)
	}
	if !IsValidLongitude(opts.Longitude) {
		return GeoEvent{}, fmt.Errorf("invalid longitude: %f, must be between -180 and +180", opts.Longitude)
	}

	return GeoEvent{
		EntityID:      opts.EntityID,
		CorrelationID: opts.CorrelationID,
		UserData:      opts.UserData,
		LatNano:       DegreesToNano(opts.Latitude),
		LonNano:       DegreesToNano(opts.Longitude),
		GroupID:       opts.GroupID,
		AltitudeMM:    MetersToMM(opts.AltitudeM),
		VelocityMMS:   uint32(opts.VelocityMPS * float64(MmPerMeter)),
		TTLSeconds:    opts.TTLSeconds,
		AccuracyMM:    uint32(opts.AccuracyM * float64(MmPerMeter)),
		HeadingCdeg:   HeadingToCentidegrees(opts.Heading),
		Flags:         opts.Flags,
	}, nil
}

// NewRadiusQuery creates a QueryRadiusFilter from user-friendly units.
//
// Parameters:
//   - latitude: Center latitude in degrees (-90 to +90)
//   - longitude: Center longitude in degrees (-180 to +180)
//   - radiusM: Search radius in meters (must be positive)
//   - limit: Maximum number of results to return
//
// Example:
//
//	filter, err := types.NewRadiusQuery(37.7749, -122.4194, 1000, 100)
//	if err != nil {
//	    // Handle invalid parameters
//	}
//	results, err := client.QueryRadius(filter)
func NewRadiusQuery(latitude, longitude, radiusM float64, limit uint32) (QueryRadiusFilter, error) {
	if !IsValidLatitude(latitude) {
		return QueryRadiusFilter{}, fmt.Errorf("invalid latitude: %f", latitude)
	}
	if !IsValidLongitude(longitude) {
		return QueryRadiusFilter{}, fmt.Errorf("invalid longitude: %f", longitude)
	}
	if radiusM <= 0 {
		return QueryRadiusFilter{}, fmt.Errorf("invalid radius: %f, must be positive", radiusM)
	}

	return QueryRadiusFilter{
		CenterLatNano: DegreesToNano(latitude),
		CenterLonNano: DegreesToNano(longitude),
		RadiusMM:      uint32(radiusM * float64(MmPerMeter)),
		Limit:         limit,
	}, nil
}

// NewPolygonQuery creates a QueryPolygonFilter from vertices in degrees.
//
// Parameters:
//   - vertices: Outer boundary vertices as [lat, lon] pairs in counter-clockwise order
//   - limit: Maximum number of results to return
//   - holes: Optional exclusion zones as [lat, lon] pairs in clockwise order
//
// Winding order is important:
//   - Outer boundary: counter-clockwise (CCW)
//   - Holes: clockwise (CW)
//
// Example:
//
//	// Query a rectangular area
//	vertices := [][]float64{
//	    {37.78, -122.42},  // NW corner
//	    {37.78, -122.40},  // NE corner
//	    {37.76, -122.40},  // SE corner
//	    {37.76, -122.42},  // SW corner
//	}
//	filter, err := types.NewPolygonQuery(vertices, 100)
//
//	// With a hole (exclusion zone)
//	hole := [][]float64{
//	    {37.775, -122.415},
//	    {37.770, -122.415},
//	    {37.770, -122.410},
//	    {37.775, -122.410},
//	}
//	filter, err := types.NewPolygonQuery(vertices, 100, hole)
func NewPolygonQuery(vertices [][]float64, limit uint32, holes ...[][]float64) (QueryPolygonFilter, error) {
	if len(vertices) < 3 {
		return QueryPolygonFilter{}, fmt.Errorf("polygon must have at least 3 vertices, got %d", len(vertices))
	}
	if len(vertices) > PolygonVerticesMax {
		return QueryPolygonFilter{}, fmt.Errorf("polygon exceeds maximum %d vertices, got %d", PolygonVerticesMax, len(vertices))
	}

	polyVertices := make([]PolygonVertex, len(vertices))
	for i, v := range vertices {
		if len(v) != 2 {
			return QueryPolygonFilter{}, fmt.Errorf("vertex %d must have 2 elements [lat, lon], got %d", i, len(v))
		}
		lat, lon := v[0], v[1]
		if !IsValidLatitude(lat) {
			return QueryPolygonFilter{}, fmt.Errorf("invalid latitude at vertex %d: %f", i, lat)
		}
		if !IsValidLongitude(lon) {
			return QueryPolygonFilter{}, fmt.Errorf("invalid longitude at vertex %d: %f", i, lon)
		}
		polyVertices[i] = PolygonVertex{
			LatNano: DegreesToNano(lat),
			LonNano: DegreesToNano(lon),
		}
	}

	// Process holes
	var polyHoles []PolygonHole
	if len(holes) > 0 {
		if len(holes) > PolygonHolesMax {
			return QueryPolygonFilter{}, fmt.Errorf("too many holes: %d exceeds maximum %d", len(holes), PolygonHolesMax)
		}

		polyHoles = make([]PolygonHole, len(holes))
		for holeIdx, holeVertices := range holes {
			if len(holeVertices) < PolygonHoleVerticesMin {
				return QueryPolygonFilter{}, fmt.Errorf("hole %d must have at least %d vertices, got %d",
					holeIdx, PolygonHoleVerticesMin, len(holeVertices))
			}

			holeVerts := make([]PolygonVertex, len(holeVertices))
			for i, v := range holeVertices {
				if len(v) != 2 {
					return QueryPolygonFilter{}, fmt.Errorf("hole %d vertex %d must have 2 elements [lat, lon], got %d",
						holeIdx, i, len(v))
				}
				lat, lon := v[0], v[1]
				if !IsValidLatitude(lat) {
					return QueryPolygonFilter{}, fmt.Errorf("invalid latitude at hole %d vertex %d: %f", holeIdx, i, lat)
				}
				if !IsValidLongitude(lon) {
					return QueryPolygonFilter{}, fmt.Errorf("invalid longitude at hole %d vertex %d: %f", holeIdx, i, lon)
				}
				holeVerts[i] = PolygonVertex{
					LatNano: DegreesToNano(lat),
					LonNano: DegreesToNano(lon),
				}
			}
			polyHoles[holeIdx] = PolygonHole{Vertices: holeVerts}
		}
	}

	return QueryPolygonFilter{
		Vertices: polyVertices,
		Holes:    polyHoles,
		Limit:    limit,
	}, nil
}

// Latitude returns the latitude in decimal degrees.
//
// Converts from internal nanodegree representation.
func (e *GeoEvent) Latitude() float64 {
	return NanoToDegrees(e.LatNano)
}

// Longitude returns the longitude in decimal degrees.
//
// Converts from internal nanodegree representation.
func (e *GeoEvent) Longitude() float64 {
	return NanoToDegrees(e.LonNano)
}

// Heading returns the heading in degrees (0-360).
//
// 0 = North, 90 = East, 180 = South, 270 = West.
// Converts from internal centidegree representation.
func (e *GeoEvent) Heading() float64 {
	return CentidegreesToHeading(e.HeadingCdeg)
}

// Altitude returns the altitude in meters above WGS84 ellipsoid.
//
// Converts from internal millimeter representation.
func (e *GeoEvent) Altitude() float64 {
	return MMToMeters(e.AltitudeMM)
}

// ============================================================================
// S2 Cell ID Computation
// ============================================================================

const (
	// s2Level is the S2 cell level used for spatial indexing.
	// Level 30 provides ~7.5mm resolution, the maximum precision.
	s2Level = 30
)

// ComputeS2CellID computes an S2 cell ID from coordinates in nanodegrees.
//
// S2 cells partition the Earth's surface into a hierarchical grid. ArcherDB
// uses level 30 cells (~7.5mm resolution) for maximum precision spatial indexing.
//
// This function is called internally by PrepareGeoEvent. Most users don't need
// to call it directly.
func ComputeS2CellID(latNano, lonNano int64) uint64 {
	// Convert to radians
	lat := float64(latNano) / 1e9 * math.Pi / 180.0
	lon := float64(lonNano) / 1e9 * math.Pi / 180.0

	// Convert to S2 point (unit sphere)
	cosLat := math.Cos(lat)
	x := cosLat * math.Cos(lon)
	y := cosLat * math.Sin(lon)
	z := math.Sin(lat)

	// Determine face (0-5) based on largest absolute coordinate
	ax, ay, az := math.Abs(x), math.Abs(y), math.Abs(z)
	var face int
	var u, v float64

	if ax >= ay && ax >= az {
		if x > 0 {
			face = 0
			u, v = y/x, z/x
		} else {
			face = 3
			u, v = -y/x, z/-x
		}
	} else if ay >= ax && ay >= az {
		if y > 0 {
			face = 1
			u, v = -x/y, z/y
		} else {
			face = 4
			u, v = x/-y, z/-y
		}
	} else {
		if z > 0 {
			face = 2
			u, v = -x/z, -y/z
		} else {
			face = 5
			u, v = -x/-z, y/-z
		}
	}

	// Apply quadratic transform (S2 uses this for better cell shape)
	s := uvToST(u)
	t := uvToST(v)

	// Convert to integer coordinates
	scale := float64(uint64(1) << s2Level)
	i := uint64(s * scale)
	j := uint64(t * scale)

	// Clamp to valid range
	maxIJ := uint64(1<<s2Level) - 1
	if i > maxIJ {
		i = maxIJ
	}
	if j > maxIJ {
		j = maxIJ
	}

	// Interleave bits to form position
	pos := interleave(i, j)

	// Construct cell ID: face (3 bits) | position | sentinel bit
	cellID := uint64(face)<<61 | pos<<1 | 1

	return cellID
}

// uvToST applies the quadratic transformation from UV to ST coordinates.
func uvToST(u float64) float64 {
	if u >= 0 {
		return 0.5 * math.Sqrt(1+3*u)
	}
	return 1.0 - 0.5*math.Sqrt(1-3*u)
}

// interleave interleaves the bits of two 30-bit integers into a 60-bit result.
func interleave(i, j uint64) uint64 {
	var result uint64
	for bit := uint(0); bit < 30; bit++ {
		result |= ((i >> bit) & 1) << (2*bit + 1)
		result |= ((j >> bit) & 1) << (2 * bit)
	}
	return result
}

// PackCompositeID creates a composite key from S2 cell ID and timestamp.
//
// The composite ID enables efficient spatial and temporal queries by encoding
// both location and time in a single sortable key.
//
// Format: [S2 Cell ID (upper 64 bits) | Timestamp (lower 64 bits)]
//
// This function is called internally. Most users don't need to call it directly.
func PackCompositeID(s2CellID uint64, timestamp uint64) Uint128 {
	values := [2]uint64{timestamp, s2CellID}
	return *(*Uint128)(unsafe.Pointer(&values[0]))
}

// PrepareGeoEvent prepares a GeoEvent for submission to the server.
//
// This function computes the composite ID from the event's coordinates and
// sets the appropriate timestamp. It is called automatically by InsertEvents
// and UpsertEvents, so most users don't need to call it directly.
//
// The composite ID combines:
//   - S2 cell ID (from coordinates) - enables spatial indexing
//   - Timestamp (current time) - enables temporal ordering
func PrepareGeoEvent(event *GeoEvent) {
	if event.ID == (Uint128{}) {
		// Compute S2 cell ID from coordinates
		s2CellID := ComputeS2CellID(event.LatNano, event.LonNano)
		// Use current time in nanoseconds
		timestamp := uint64(time.Now().UnixNano())
		// Pack into composite ID
		event.ID = PackCompositeID(s2CellID, timestamp)
		// Server requires timestamp field to be 0 for non-imported events
		event.Timestamp = 0
	}
}
