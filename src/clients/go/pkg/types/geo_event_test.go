package types

import (
	"math"
	"testing"
)

// ============================================================================
// Constants Tests
// ============================================================================

func TestConstants(t *testing.T) {
	// Verify constants match spec values
	if LatMax != 90.0 {
		t.Errorf("LatMax = %v, want 90.0", LatMax)
	}
	if LonMax != 180.0 {
		t.Errorf("LonMax = %v, want 180.0", LonMax)
	}
	if NanodegreesPerDegree != 1_000_000_000 {
		t.Errorf("NanodegreesPerDegree = %v, want 1e9", NanodegreesPerDegree)
	}
	if MmPerMeter != 1000 {
		t.Errorf("MmPerMeter = %v, want 1000", MmPerMeter)
	}
	if CentidegreesPerDegree != 100 {
		t.Errorf("CentidegreesPerDegree = %v, want 100", CentidegreesPerDegree)
	}
	if BatchSizeMax != 10_000 {
		t.Errorf("BatchSizeMax = %v, want 10000", BatchSizeMax)
	}
	if QueryLimitMax != 81_000 {
		t.Errorf("QueryLimitMax = %v, want 81000", QueryLimitMax)
	}
	if PolygonVerticesMax != 10_000 {
		t.Errorf("PolygonVerticesMax = %v, want 10000", PolygonVerticesMax)
	}
	if PolygonHolesMax != 100 {
		t.Errorf("PolygonHolesMax = %v, want 100", PolygonHolesMax)
	}
	if PolygonHoleVerticesMin != 3 {
		t.Errorf("PolygonHoleVerticesMin = %v, want 3", PolygonHoleVerticesMin)
	}
}

// ============================================================================
// Coordinate Conversion Tests
// ============================================================================

func TestDegreesToNano(t *testing.T) {
	tests := []struct {
		name     string
		degrees  float64
		expected int64
	}{
		{"positive latitude", 37.7749, 37_774_900_000},
		{"negative longitude", -122.4194, -122_419_400_000},
		{"max latitude", 90.0, 90_000_000_000},
		{"min latitude", -90.0, -90_000_000_000},
		{"max longitude", 180.0, 180_000_000_000},
		{"min longitude", -180.0, -180_000_000_000},
		{"zero", 0.0, 0},
		{"small positive", 0.000000001, 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := DegreesToNano(tt.degrees)
			if result != tt.expected {
				t.Errorf("DegreesToNano(%v) = %v, want %v", tt.degrees, result, tt.expected)
			}
		})
	}
}

func TestNanoToDegrees(t *testing.T) {
	tests := []struct {
		name     string
		nano     int64
		expected float64
	}{
		{"San Francisco lat", 37_774_900_000, 37.7749},
		{"negative longitude", -122_419_400_000, -122.4194},
		{"max lat", 90_000_000_000, 90.0},
		{"zero", 0, 0.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := NanoToDegrees(tt.nano)
			if result != tt.expected {
				t.Errorf("NanoToDegrees(%v) = %v, want %v", tt.nano, result, tt.expected)
			}
		})
	}
}

func TestDegreesNanoRoundTrip(t *testing.T) {
	// Test that converting to nano and back gives the original value
	testValues := []float64{0, 37.7749, -122.4194, 90, -90, 180, -180, 45.5, -45.5}

	for _, v := range testValues {
		nano := DegreesToNano(v)
		back := NanoToDegrees(nano)
		if back != v {
			t.Errorf("Round trip failed: %v -> %v -> %v", v, nano, back)
		}
	}
}

func TestMetersToMM(t *testing.T) {
	tests := []struct {
		name     string
		meters   float64
		expected int32
	}{
		{"1 meter", 1.0, 1000},
		{"5.5 meters", 5.5, 5500},
		{"0 meters", 0, 0},
		{"1 km", 1000.0, 1_000_000},
		{"small value", 0.001, 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := MetersToMM(tt.meters)
			if result != tt.expected {
				t.Errorf("MetersToMM(%v) = %v, want %v", tt.meters, result, tt.expected)
			}
		})
	}
}

func TestMMToMeters(t *testing.T) {
	tests := []struct {
		name     string
		mm       int32
		expected float64
	}{
		{"1000mm", 1000, 1.0},
		{"5500mm", 5500, 5.5},
		{"0mm", 0, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := MMToMeters(tt.mm)
			if result != tt.expected {
				t.Errorf("MMToMeters(%v) = %v, want %v", tt.mm, result, tt.expected)
			}
		})
	}
}

func TestHeadingToCentidegrees(t *testing.T) {
	tests := []struct {
		name     string
		degrees  float64
		expected uint16
	}{
		{"North", 0, 0},
		{"East", 90, 9000},
		{"South", 180, 18000},
		{"West", 270, 27000},
		{"Full circle", 360, 36000},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := HeadingToCentidegrees(tt.degrees)
			if result != tt.expected {
				t.Errorf("HeadingToCentidegrees(%v) = %v, want %v", tt.degrees, result, tt.expected)
			}
		})
	}
}

func TestCentidegreesToHeading(t *testing.T) {
	tests := []struct {
		name     string
		cdeg     uint16
		expected float64
	}{
		{"North", 0, 0},
		{"East", 9000, 90},
		{"South", 18000, 180},
		{"West", 27000, 270},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := CentidegreesToHeading(tt.cdeg)
			if result != tt.expected {
				t.Errorf("CentidegreesToHeading(%v) = %v, want %v", tt.cdeg, result, tt.expected)
			}
		})
	}
}

// ============================================================================
// Coordinate Validation Tests
// ============================================================================

func TestIsValidLatitude(t *testing.T) {
	validLats := []float64{0, 90, -90, 45.5, -45.5, 89.999999}
	invalidLats := []float64{90.1, -90.1, 180, -180, 1000}

	for _, lat := range validLats {
		if !IsValidLatitude(lat) {
			t.Errorf("IsValidLatitude(%v) = false, want true", lat)
		}
	}

	for _, lat := range invalidLats {
		if IsValidLatitude(lat) {
			t.Errorf("IsValidLatitude(%v) = true, want false", lat)
		}
	}
}

func TestIsValidLongitude(t *testing.T) {
	validLons := []float64{0, 180, -180, 90, -90, 179.999999}
	invalidLons := []float64{180.1, -180.1, 360, -360}

	for _, lon := range validLons {
		if !IsValidLongitude(lon) {
			t.Errorf("IsValidLongitude(%v) = false, want true", lon)
		}
	}

	for _, lon := range invalidLons {
		if IsValidLongitude(lon) {
			t.Errorf("IsValidLongitude(%v) = true, want false", lon)
		}
	}
}

// ============================================================================
// GeoEvent Creation Tests
// ============================================================================

func TestNewGeoEvent(t *testing.T) {
	entityID := ID()

	event, err := NewGeoEvent(GeoEventOptions{
		EntityID:    entityID,
		Latitude:    37.7749,
		Longitude:   -122.4194,
		VelocityMPS: 15.5,
		Heading:     90,
		AccuracyM:   5,
		TTLSeconds:  86400,
	})

	if err != nil {
		t.Fatalf("NewGeoEvent failed: %v", err)
	}

	if event.EntityID != entityID {
		t.Errorf("EntityID = %v, want %v", event.EntityID, entityID)
	}
	if event.LatNano != 37_774_900_000 {
		t.Errorf("LatNano = %v, want 37774900000", event.LatNano)
	}
	if event.LonNano != -122_419_400_000 {
		t.Errorf("LonNano = %v, want -122419400000", event.LonNano)
	}
	if event.VelocityMMS != 15500 {
		t.Errorf("VelocityMMS = %v, want 15500", event.VelocityMMS)
	}
	if event.HeadingCdeg != 9000 {
		t.Errorf("HeadingCdeg = %v, want 9000", event.HeadingCdeg)
	}
	if event.AccuracyMM != 5000 {
		t.Errorf("AccuracyMM = %v, want 5000", event.AccuracyMM)
	}
	if event.TTLSeconds != 86400 {
		t.Errorf("TTLSeconds = %v, want 86400", event.TTLSeconds)
	}
}

func TestNewGeoEvent_InvalidLatitude(t *testing.T) {
	_, err := NewGeoEvent(GeoEventOptions{
		EntityID:  ID(),
		Latitude:  91, // Invalid
		Longitude: 0,
	})

	if err == nil {
		t.Error("Expected error for invalid latitude, got nil")
	}
}

func TestNewGeoEvent_InvalidLongitude(t *testing.T) {
	_, err := NewGeoEvent(GeoEventOptions{
		EntityID:  ID(),
		Latitude:  0,
		Longitude: 181, // Invalid
	})

	if err == nil {
		t.Error("Expected error for invalid longitude, got nil")
	}
}

func TestGeoEventMethods(t *testing.T) {
	event, err := NewGeoEvent(GeoEventOptions{
		EntityID:  ID(),
		Latitude:  37.7749,
		Longitude: -122.4194,
		AltitudeM: 100.5,
		Heading:   90,
	})
	if err != nil {
		t.Fatalf("NewGeoEvent failed: %v", err)
	}

	if event.Latitude() != 37.7749 {
		t.Errorf("Latitude() = %v, want 37.7749", event.Latitude())
	}
	if event.Longitude() != -122.4194 {
		t.Errorf("Longitude() = %v, want -122.4194", event.Longitude())
	}
	if event.Heading() != 90 {
		t.Errorf("Heading() = %v, want 90", event.Heading())
	}
	if event.Altitude() != 100.5 {
		t.Errorf("Altitude() = %v, want 100.5", event.Altitude())
	}
}

// ============================================================================
// Query Builder Tests
// ============================================================================

func TestNewRadiusQuery(t *testing.T) {
	filter, err := NewRadiusQuery(37.7749, -122.4194, 1000, 500)
	if err != nil {
		t.Fatalf("NewRadiusQuery failed: %v", err)
	}

	if filter.CenterLatNano != 37_774_900_000 {
		t.Errorf("CenterLatNano = %v, want 37774900000", filter.CenterLatNano)
	}
	if filter.CenterLonNano != -122_419_400_000 {
		t.Errorf("CenterLonNano = %v, want -122419400000", filter.CenterLonNano)
	}
	if filter.RadiusMM != 1_000_000 {
		t.Errorf("RadiusMM = %v, want 1000000", filter.RadiusMM)
	}
	if filter.Limit != 500 {
		t.Errorf("Limit = %v, want 500", filter.Limit)
	}
}

func TestNewRadiusQuery_InvalidLatitude(t *testing.T) {
	_, err := NewRadiusQuery(91, 0, 1000, 100)
	if err == nil {
		t.Error("Expected error for invalid latitude")
	}
}

func TestNewRadiusQuery_InvalidLongitude(t *testing.T) {
	_, err := NewRadiusQuery(0, 181, 1000, 100)
	if err == nil {
		t.Error("Expected error for invalid longitude")
	}
}

func TestNewRadiusQuery_InvalidRadius(t *testing.T) {
	_, err := NewRadiusQuery(0, 0, 0, 100)
	if err == nil {
		t.Error("Expected error for zero radius")
	}

	_, err = NewRadiusQuery(0, 0, -100, 100)
	if err == nil {
		t.Error("Expected error for negative radius")
	}
}

func TestNewPolygonQuery(t *testing.T) {
	vertices := [][]float64{
		{0, 0},
		{0, 10},
		{10, 10},
		{10, 0},
	}

	filter, err := NewPolygonQuery(vertices, 100)
	if err != nil {
		t.Fatalf("NewPolygonQuery failed: %v", err)
	}

	if len(filter.Vertices) != 4 {
		t.Errorf("Vertices count = %v, want 4", len(filter.Vertices))
	}
	if filter.Vertices[0].LatNano != 0 {
		t.Errorf("Vertex[0].LatNano = %v, want 0", filter.Vertices[0].LatNano)
	}
	if filter.Vertices[1].LonNano != 10_000_000_000 {
		t.Errorf("Vertex[1].LonNano = %v, want 10000000000", filter.Vertices[1].LonNano)
	}
	if filter.Limit != 100 {
		t.Errorf("Limit = %v, want 100", filter.Limit)
	}
}

func TestNewPolygonQuery_TooFewVertices(t *testing.T) {
	vertices := [][]float64{{0, 0}, {0, 10}}

	_, err := NewPolygonQuery(vertices, 100)
	if err == nil {
		t.Error("Expected error for too few vertices")
	}
}

func TestNewPolygonQuery_InvalidVertex(t *testing.T) {
	vertices := [][]float64{{91, 0}, {0, 10}, {10, 10}}

	_, err := NewPolygonQuery(vertices, 100)
	if err == nil {
		t.Error("Expected error for invalid vertex")
	}
}

func TestNewPolygonQuery_MalformedVertex(t *testing.T) {
	vertices := [][]float64{{0}, {0, 10}, {10, 10}} // First vertex has only 1 element

	_, err := NewPolygonQuery(vertices, 100)
	if err == nil {
		t.Error("Expected error for malformed vertex")
	}
}

func TestNewPolygonQuery_WithHole(t *testing.T) {
	outer := [][]float64{
		{0, 0},
		{0, 10},
		{10, 10},
		{10, 0},
	}
	hole := [][]float64{
		{2, 2},
		{2, 8},
		{8, 8},
		{8, 2},
	}

	filter, err := NewPolygonQuery(outer, 100, hole)
	if err != nil {
		t.Fatalf("NewPolygonQuery with hole failed: %v", err)
	}

	if len(filter.Vertices) != 4 {
		t.Errorf("Vertices count = %v, want 4", len(filter.Vertices))
	}
	if len(filter.Holes) != 1 {
		t.Errorf("Holes count = %v, want 1", len(filter.Holes))
	}
	if len(filter.Holes[0].Vertices) != 4 {
		t.Errorf("Hole vertices count = %v, want 4", len(filter.Holes[0].Vertices))
	}
}

func TestNewPolygonQuery_WithMultipleHoles(t *testing.T) {
	outer := [][]float64{
		{0, 0},
		{0, 20},
		{20, 20},
		{20, 0},
	}
	hole1 := [][]float64{
		{1, 1},
		{1, 5},
		{5, 5},
		{5, 1},
	}
	hole2 := [][]float64{
		{10, 10},
		{10, 15},
		{15, 15},
		{15, 10},
	}

	filter, err := NewPolygonQuery(outer, 100, hole1, hole2)
	if err != nil {
		t.Fatalf("NewPolygonQuery with multiple holes failed: %v", err)
	}

	if len(filter.Holes) != 2 {
		t.Errorf("Holes count = %v, want 2", len(filter.Holes))
	}
}

func TestNewPolygonQuery_TooFewHoleVertices(t *testing.T) {
	outer := [][]float64{
		{0, 0},
		{0, 10},
		{10, 10},
		{10, 0},
	}
	hole := [][]float64{
		{2, 2},
		{2, 8}, // Only 2 vertices
	}

	_, err := NewPolygonQuery(outer, 100, hole)
	if err == nil {
		t.Error("Expected error for hole with too few vertices")
	}
}

func TestNewPolygonQuery_InvalidHoleVertex(t *testing.T) {
	outer := [][]float64{
		{0, 0},
		{0, 10},
		{10, 10},
		{10, 0},
	}
	hole := [][]float64{
		{91, 0}, // Invalid latitude
		{2, 8},
		{8, 8},
	}

	_, err := NewPolygonQuery(outer, 100, hole)
	if err == nil {
		t.Error("Expected error for invalid hole vertex")
	}
}

// ============================================================================
// S2 Cell ID Tests
// ============================================================================

func TestComputeS2CellID(t *testing.T) {
	// Test that S2 cell IDs are computed and are non-zero
	latNano := DegreesToNano(37.7749)
	lonNano := DegreesToNano(-122.4194)

	cellID := ComputeS2CellID(latNano, lonNano)

	if cellID == 0 {
		t.Error("ComputeS2CellID returned 0")
	}

	// Test that different locations give different cell IDs
	latNano2 := DegreesToNano(40.7128)
	lonNano2 := DegreesToNano(-74.0060)

	cellID2 := ComputeS2CellID(latNano2, lonNano2)

	if cellID == cellID2 {
		t.Error("Different locations should have different cell IDs")
	}
}

func TestComputeS2CellID_EdgeCases(t *testing.T) {
	tests := []struct {
		name    string
		latNano int64
		lonNano int64
	}{
		{"origin", 0, 0},
		{"north pole", 90_000_000_000, 0},
		{"south pole", -90_000_000_000, 0},
		{"date line +", 0, 180_000_000_000},
		{"date line -", 0, -180_000_000_000},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cellID := ComputeS2CellID(tt.latNano, tt.lonNano)
			if cellID == 0 {
				t.Errorf("ComputeS2CellID returned 0 for %s", tt.name)
			}
		})
	}
}

func TestPackCompositeID(t *testing.T) {
	s2CellID := uint64(0x1234567890ABCDEF)
	timestamp := uint64(1704067200_000_000_000)

	compositeID := PackCompositeID(s2CellID, timestamp)

	// Should be non-zero
	if compositeID == (Uint128{}) {
		t.Error("PackCompositeID returned zero")
	}
}

func TestPrepareGeoEvent(t *testing.T) {
	event, err := NewGeoEvent(GeoEventOptions{
		EntityID:  ID(),
		Latitude:  37.7749,
		Longitude: -122.4194,
	})
	if err != nil {
		t.Fatalf("NewGeoEvent failed: %v", err)
	}

	// Before prepare, ID should be zero
	if event.ID != (Uint128{}) {
		t.Error("Event ID should be zero before PrepareGeoEvent")
	}

	PrepareGeoEvent(&event)

	// After prepare, ID should be non-zero
	if event.ID == (Uint128{}) {
		t.Error("Event ID should be non-zero after PrepareGeoEvent")
	}

	// Timestamp field should be 0 (server-assigned)
	if event.Timestamp != 0 {
		t.Errorf("Timestamp = %v, want 0", event.Timestamp)
	}
}

// ============================================================================
// GeoEventFlags Tests
// ============================================================================

func TestGeoEventFlags(t *testing.T) {
	// Test individual flags
	if GeoEventFlagNone != 0 {
		t.Errorf("GeoEventFlagNone = %v, want 0", GeoEventFlagNone)
	}
	if GeoEventFlagLinked != 1 {
		t.Errorf("GeoEventFlagLinked = %v, want 1", GeoEventFlagLinked)
	}
	if GeoEventFlagImported != 2 {
		t.Errorf("GeoEventFlagImported = %v, want 2", GeoEventFlagImported)
	}
	if GeoEventFlagStationary != 4 {
		t.Errorf("GeoEventFlagStationary = %v, want 4", GeoEventFlagStationary)
	}

	// Test flag combinations
	combined := GeoEventFlagLinked | GeoEventFlagStationary
	if combined != 5 {
		t.Errorf("Combined flags = %v, want 5", combined)
	}
}

// ============================================================================
// GeoOperation Tests
// ============================================================================

func TestGeoOperationCodes(t *testing.T) {
	// Verify operation codes match archerdb.zig values
	// vsr_operations_reserved = 128
	if GeoOperationInsertEvents != 146 {
		t.Errorf("GeoOperationInsertEvents = %v, want 146", GeoOperationInsertEvents)
	}
	if GeoOperationUpsertEvents != 147 {
		t.Errorf("GeoOperationUpsertEvents = %v, want 147", GeoOperationUpsertEvents)
	}
	if GeoOperationDeleteEntities != 148 {
		t.Errorf("GeoOperationDeleteEntities = %v, want 148", GeoOperationDeleteEntities)
	}
	if GeoOperationQueryUUID != 149 {
		t.Errorf("GeoOperationQueryUUID = %v, want 149", GeoOperationQueryUUID)
	}
	if GeoOperationQueryRadius != 150 {
		t.Errorf("GeoOperationQueryRadius = %v, want 150", GeoOperationQueryRadius)
	}
	if GeoOperationQueryPolygon != 151 {
		t.Errorf("GeoOperationQueryPolygon = %v, want 151", GeoOperationQueryPolygon)
	}
	if GeoOperationQueryLatest != 154 {
		t.Errorf("GeoOperationQueryLatest = %v, want 154", GeoOperationQueryLatest)
	}
}

// ============================================================================
// Result Code Tests
// ============================================================================

func TestInsertGeoEventResultCodes(t *testing.T) {
	if InsertResultOK != 0 {
		t.Errorf("InsertResultOK = %v, want 0", InsertResultOK)
	}
	if InsertResultEntityIDMustNotBeZero != 7 {
		t.Errorf("InsertResultEntityIDMustNotBeZero = %v, want 7", InsertResultEntityIDMustNotBeZero)
	}
	if InsertResultInvalidCoordinates != 8 {
		t.Errorf("InsertResultInvalidCoordinates = %v, want 8", InsertResultInvalidCoordinates)
	}
	if InsertResultLatOutOfRange != 9 {
		t.Errorf("InsertResultLatOutOfRange = %v, want 9", InsertResultLatOutOfRange)
	}
	if InsertResultLonOutOfRange != 10 {
		t.Errorf("InsertResultLonOutOfRange = %v, want 10", InsertResultLonOutOfRange)
	}
}

func TestDeleteEntityResultCodes(t *testing.T) {
	if DeleteResultOK != 0 {
		t.Errorf("DeleteResultOK = %v, want 0", DeleteResultOK)
	}
	if DeleteResultEntityNotFound != 3 {
		t.Errorf("DeleteResultEntityNotFound = %v, want 3", DeleteResultEntityNotFound)
	}
}

// ============================================================================
// StatusResponse Tests
// ============================================================================

func TestStatusResponseLoadFactor(t *testing.T) {
	status := StatusResponse{
		RAMIndexLoadPct: 7000, // 70%
	}

	loadFactor := status.LoadFactor()
	expected := 0.70

	if math.Abs(loadFactor-expected) > 0.001 {
		t.Errorf("LoadFactor() = %v, want %v", loadFactor, expected)
	}
}

// ============================================================================
// ID Generation Tests
// ============================================================================

func TestIDGeneration(t *testing.T) {
	id1 := ID()
	id2 := ID()
	id3 := ID()

	// IDs should be unique
	if id1 == id2 || id2 == id3 || id1 == id3 {
		t.Error("Generated IDs should be unique")
	}

	// IDs should be non-zero
	zero := Uint128{}
	if id1 == zero || id2 == zero || id3 == zero {
		t.Error("Generated IDs should be non-zero")
	}
}

// ============================================================================
// Benchmark Tests
// ============================================================================

func BenchmarkDegreesToNano(b *testing.B) {
	for i := 0; i < b.N; i++ {
		DegreesToNano(37.7749)
	}
}

func BenchmarkComputeS2CellID(b *testing.B) {
	latNano := DegreesToNano(37.7749)
	lonNano := DegreesToNano(-122.4194)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ComputeS2CellID(latNano, lonNano)
	}
}

func BenchmarkNewGeoEvent(b *testing.B) {
	entityID := ID()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		NewGeoEvent(GeoEventOptions{
			EntityID:  entityID,
			Latitude:  37.7749,
			Longitude: -122.4194,
		})
	}
}

func BenchmarkPrepareGeoEvent(b *testing.B) {
	entityID := ID()
	event, _ := NewGeoEvent(GeoEventOptions{
		EntityID:  entityID,
		Latitude:  37.7749,
		Longitude: -122.4194,
	})

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		e := event
		e.ID = Uint128{} // Reset to trigger compute
		PrepareGeoEvent(&e)
	}
}

func BenchmarkIDGeneration(b *testing.B) {
	for i := 0; i < b.N; i++ {
		ID()
	}
}

func BenchmarkNewPolygonQuery_Simple(b *testing.B) {
	vertices := [][]float64{
		{0, 0},
		{0, 10},
		{10, 10},
		{10, 0},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		NewPolygonQuery(vertices, 100)
	}
}

func BenchmarkNewPolygonQuery_WithOneHole(b *testing.B) {
	vertices := [][]float64{
		{0, 0},
		{0, 10},
		{10, 10},
		{10, 0},
	}
	hole := [][]float64{
		{2, 2},
		{2, 8},
		{8, 8},
		{8, 2},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		NewPolygonQuery(vertices, 100, hole)
	}
}

func BenchmarkNewPolygonQuery_WithTenHoles(b *testing.B) {
	vertices := [][]float64{
		{0, 0},
		{0, 100},
		{100, 100},
		{100, 0},
	}

	// Create 10 holes
	var holes [][][]float64
	for i := 0; i < 10; i++ {
		offset := float64(i * 10)
		hole := [][]float64{
			{1 + offset, 1},
			{1 + offset, 5},
			{5 + offset, 5},
			{5 + offset, 1},
		}
		holes = append(holes, hole)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		NewPolygonQuery(vertices, 100, holes...)
	}
}
