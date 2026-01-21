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
	// Coordinate bounds
	LatMax float64 = 90.0
	LonMax float64 = 180.0

	// Conversion factors
	NanodegreesPerDegree   int64 = 1_000_000_000
	MmPerMeter             int64 = 1000
	CentidegreesPerDegree  int64 = 100

	// Limits per spec (assumes production config with 10MB message_size_max)
	BatchSizeMax       int = 10_000
	QueryUUIDBatchMax  int = 10_000
	QueryLimitMax      int = 81_000
	PolygonVerticesMax int = 10_000

	// Polygon hole limits (per spec)
	PolygonHolesMax        int = 100
	PolygonHoleVerticesMin int = 3

	// Safe limits for default 1MB message configuration
	BatchSizeMaxDefault   int = 8_000
	QueryLimitMaxDefault  int = 8_000
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
// Matches StatusResponse in geo_state_machine.zig (64 bytes).
type StatusResponse struct {
	RAMIndexCount    uint64 // Number of entities in RAM index
	RAMIndexCapacity uint64 // Total RAM index capacity
	RAMIndexLoadPct  uint32 // Load factor as percentage * 100 (e.g., 7000 = 70%)
	TombstoneCount   uint64 // Number of tombstone entries
	TTLExpirations   uint64 // Total TTL expirations processed
	DeletionCount    uint64 // Total deletions processed
}

// LoadFactor returns the load factor as a decimal (e.g., 0.70).
func (s *StatusResponse) LoadFactor() float64 {
	return float64(s.RAMIndexLoadPct) / 10000.0
}

// ============================================================================
// Coordinate Conversion Helpers
// ============================================================================

// DegreesToNano converts degrees to nanodegrees.
func DegreesToNano(degrees float64) int64 {
	return int64(degrees * float64(NanodegreesPerDegree))
}

// NanoToDegrees converts nanodegrees to degrees.
func NanoToDegrees(nano int64) float64 {
	return float64(nano) / float64(NanodegreesPerDegree)
}

// MetersToMM converts meters to millimeters.
func MetersToMM(meters float64) int32 {
	return int32(math.Round(meters * float64(MmPerMeter)))
}

// MMToMeters converts millimeters to meters.
func MMToMeters(mm int32) float64 {
	return float64(mm) / float64(MmPerMeter)
}

// HeadingToCentidegrees converts heading from degrees (0-360) to centidegrees (0-36000).
func HeadingToCentidegrees(degrees float64) uint16 {
	return uint16(degrees * float64(CentidegreesPerDegree))
}

// CentidegreesToHeading converts heading from centidegrees to degrees.
func CentidegreesToHeading(cdeg uint16) float64 {
	return float64(cdeg) / float64(CentidegreesPerDegree)
}

// IsValidLatitude checks if latitude is in valid range (-90 to +90).
func IsValidLatitude(lat float64) bool {
	return lat >= -LatMax && lat <= LatMax
}

// IsValidLongitude checks if longitude is in valid range (-180 to +180).
func IsValidLongitude(lon float64) bool {
	return lon >= -LonMax && lon <= LonMax
}

// ============================================================================
// Builder Functions
// ============================================================================

// GeoEventOptions contains user-friendly options for creating GeoEvents.
type GeoEventOptions struct {
	EntityID      Uint128
	Latitude      float64 // Degrees (-90 to +90)
	Longitude     float64 // Degrees (-180 to +180)
	CorrelationID Uint128
	UserData      Uint128
	GroupID       uint64  // Fleet/region grouping identifier
	AltitudeM     float64 // Meters
	VelocityMPS   float64 // Meters per second
	TTLSeconds    uint32
	AccuracyM     float64 // Meters
	Heading       float64 // Degrees (0-360)
	Flags         GeoEventFlags
}

// NewGeoEvent creates a GeoEvent from user-friendly options.
// Handles unit conversions automatically (degrees to nanodegrees, meters to mm).
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
// vertices: outer boundary vertices in [lat, lon] format, CCW winding order
// holes: optional list of holes, each hole is a list of [lat, lon] vertices in CW winding order
// limit: maximum number of results to return
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

// Latitude returns the latitude in degrees.
func (e *GeoEvent) Latitude() float64 {
	return NanoToDegrees(e.LatNano)
}

// Longitude returns the longitude in degrees.
func (e *GeoEvent) Longitude() float64 {
	return NanoToDegrees(e.LonNano)
}

// Heading returns the heading in degrees.
func (e *GeoEvent) Heading() float64 {
	return CentidegreesToHeading(e.HeadingCdeg)
}

// Altitude returns the altitude in meters.
func (e *GeoEvent) Altitude() float64 {
	return MMToMeters(e.AltitudeMM)
}

// ============================================================================
// S2 Cell ID Computation
// ============================================================================

const (
	s2Level = 30 // Maximum precision level for S2 cells
)

// ComputeS2CellID computes an S2 cell ID from latitude/longitude in nanodegrees.
// Uses level 30 for maximum precision (~7.5mm resolution).
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

// PackCompositeID creates a composite ID from S2 cell ID and timestamp.
// Format: [S2 Cell ID (upper 64 bits) | Timestamp (lower 64 bits)]
// Layout: [timestamp (lo), s2CellID (hi)] in little-endian
func PackCompositeID(s2CellID uint64, timestamp uint64) Uint128 {
	values := [2]uint64{timestamp, s2CellID}
	return *(*Uint128)(unsafe.Pointer(&values[0]))
}

// PrepareGeoEvent prepares a GeoEvent for submission by computing its composite ID.
// This must be called before submitting events to the server.
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
