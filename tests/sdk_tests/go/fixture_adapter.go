// Package sdk_tests provides integration tests for the ArcherDB Go SDK.
// Tests validate all 14 operations against shared JSON fixtures from test_infrastructure.
package sdk_tests

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/archerdb/archerdb-go/pkg/types"
)

// Fixture represents a test fixture file structure.
type Fixture struct {
	Operation   string     `json:"operation"`
	Version     string     `json:"version"`
	Description string     `json:"description"`
	Cases       []TestCase `json:"cases"`
}

// TestCase represents a single test case within a fixture.
type TestCase struct {
	Name           string                 `json:"name"`
	Description    string                 `json:"description"`
	Tags           []string               `json:"tags"`
	Input          map[string]interface{} `json:"input"`
	ExpectedOutput map[string]interface{} `json:"expected_output"`
	ExpectedError  *string                `json:"expected_error"`
}

// LoadFixture loads a fixture file by operation name.
// Fixtures are located in test_infrastructure/fixtures/v1/{operation}.json
func LoadFixture(operation string) (*Fixture, error) {
	// Path relative to test file location
	path := filepath.Join("..", "..", "..", "test_infrastructure", "fixtures", "v1", operation+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var fixture Fixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		return nil, err
	}
	return &fixture, nil
}

// GenerateEntityID generates a deterministic entity ID from a test name.
// Uses SHA256 hash of test name combined with timestamp for uniqueness.
func GenerateEntityID(testName string) types.Uint128 {
	hash := sha256.Sum256([]byte(testName))
	timestamp := time.Now().UnixNano()
	hi := binary.BigEndian.Uint64(hash[:8])
	lo := uint64(timestamp)
	// Build bytes array and convert to Uint128
	var bytes [16]byte
	binary.LittleEndian.PutUint64(bytes[:8], lo)
	binary.LittleEndian.PutUint64(bytes[8:], hi)
	return types.BytesToUint128(bytes)
}

// ConvertFixtureEvents converts fixture JSON events to SDK GeoEvent slice.
// Handles the type conversion from map[string]interface{} to types.GeoEvent.
func ConvertFixtureEvents(input []interface{}) []types.GeoEvent {
	events := make([]types.GeoEvent, 0, len(input))
	for _, item := range input {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		event := MapToGeoEvent(m)
		events = append(events, event)
	}
	return events
}

// MapToGeoEvent converts a map from fixture JSON to a GeoEvent.
func MapToGeoEvent(m map[string]interface{}) types.GeoEvent {
	var event types.GeoEvent

	// Entity ID (required)
	if v, ok := m["entity_id"].(float64); ok {
		event.EntityID = types.ToUint128(uint64(v))
	}

	// Coordinates (required)
	if v, ok := m["latitude"].(float64); ok {
		event.LatNano = types.DegreesToNano(v)
	}
	if v, ok := m["longitude"].(float64); ok {
		event.LonNano = types.DegreesToNano(v)
	}

	// Optional fields
	if v, ok := m["correlation_id"].(float64); ok {
		event.CorrelationID = types.ToUint128(uint64(v))
	}
	if v, ok := m["user_data"].(float64); ok {
		event.UserData = types.ToUint128(uint64(v))
	}
	if v, ok := m["group_id"].(float64); ok {
		event.GroupID = uint64(v)
	}
	if v, ok := m["altitude_m"].(float64); ok {
		event.AltitudeMM = types.MetersToMM(v)
	}
	if v, ok := m["velocity_mps"].(float64); ok {
		event.VelocityMMS = uint32(v * 1000)
	}
	if v, ok := m["ttl_seconds"].(float64); ok {
		event.TTLSeconds = uint32(v)
	}
	if v, ok := m["accuracy_m"].(float64); ok {
		event.AccuracyMM = uint32(v * 1000)
	}
	if v, ok := m["heading"].(float64); ok {
		event.HeadingCdeg = types.HeadingToCentidegrees(v)
	}
	if v, ok := m["flags"].(float64); ok {
		event.Flags = types.GeoEventFlags(uint16(v))
	}
	// Timestamp (in fixture: seconds, in SDK: nanoseconds)
	if v, ok := m["timestamp"].(float64); ok {
		event.Timestamp = uint64(v) * 1_000_000_000 // Convert seconds to nanoseconds
	}

	return event
}

// ConvertEntityIDs converts fixture entity_ids array to Uint128 slice.
func ConvertEntityIDs(input []interface{}) []types.Uint128 {
	ids := make([]types.Uint128, 0, len(input))
	for _, item := range input {
		if v, ok := item.(float64); ok {
			ids = append(ids, types.ToUint128(uint64(v)))
		}
	}
	return ids
}

// ConvertEntityIDRange converts an entity_ids_range specification to Uint128 slice.
func ConvertEntityIDRange(rangeSpec map[string]interface{}) []types.Uint128 {
	start := uint64(0)
	if v, ok := rangeSpec["start"].(float64); ok {
		start = uint64(v)
	}
	count := 0
	if v, ok := rangeSpec["count"].(float64); ok {
		count = int(v)
	}

	ids := make([]types.Uint128, 0, count)
	for i := 0; i < count; i++ {
		ids = append(ids, types.ToUint128(start+uint64(i)))
	}
	return ids
}

// GetSetupEvents extracts setup events from a test case input.
// Returns nil if no setup is defined.
func GetSetupEvents(input map[string]interface{}) []types.GeoEvent {
	setup, ok := input["setup"].(map[string]interface{})
	if !ok {
		return nil
	}

	// Check for insert_first (single event or array)
	if insertFirst, ok := setup["insert_first"]; ok {
		switch v := insertFirst.(type) {
		case map[string]interface{}:
			// Single event
			return []types.GeoEvent{MapToGeoEvent(v)}
		case []interface{}:
			// Array of events
			return ConvertFixtureEvents(v)
		}
	}

	// Check for insert_first_range (range generator)
	if rangeGen, ok := setup["insert_first_range"].(map[string]interface{}); ok {
		return generateRangeEvents(rangeGen)
	}

	// Check for insert_hotspot (hotspot generator)
	if hotspot, ok := setup["insert_hotspot"].(map[string]interface{}); ok {
		return generateHotspotEvents(hotspot)
	}

	// Check for insert_with_timestamps (events with explicit timestamps)
	if timestampEvents, ok := setup["insert_with_timestamps"].([]interface{}); ok {
		return ConvertFixtureEvents(timestampEvents)
	}

	return nil
}

// generateRangeEvents generates events from an insert_first_range specification.
func generateRangeEvents(rangeGen map[string]interface{}) []types.GeoEvent {
	startID := uint64(0)
	if v, ok := rangeGen["start_entity_id"].(float64); ok {
		startID = uint64(v)
	}
	count := 0
	if v, ok := rangeGen["count"].(float64); ok {
		count = int(v)
	}
	baseLat := 0.0
	if v, ok := rangeGen["base_latitude"].(float64); ok {
		baseLat = v
	}
	baseLon := 0.0
	if v, ok := rangeGen["base_longitude"].(float64); ok {
		baseLon = v
	}
	spreadM := 0.0
	if v, ok := rangeGen["spread_m"].(float64); ok {
		spreadM = v
	}

	events := make([]types.GeoEvent, 0, count)
	// Spread in degrees (approximate: 1 degree ~= 111km)
	spreadDeg := spreadM / 111000.0
	cols := 10
	if count < cols {
		cols = count
	}
	if cols <= 0 {
		cols = 1
	}
	rows := (count + cols - 1) / cols

	for i := 0; i < count; i++ {
		row := i / cols
		col := i % cols
		rowFrac := 0.5
		colFrac := 0.5
		if rows > 1 {
			rowFrac = float64(row) / float64(rows-1)
		}
		if cols > 1 {
			colFrac = float64(col) / float64(cols-1)
		}
		lat := baseLat + (rowFrac-0.5)*spreadDeg
		lon := baseLon + (colFrac-0.5)*spreadDeg

		event := types.GeoEvent{
			EntityID: types.ToUint128(startID + uint64(i)),
			LatNano:  types.DegreesToNano(lat),
			LonNano:  types.DegreesToNano(lon),
		}
		events = append(events, event)
	}
	return events
}

// generateHotspotEvents generates events from an insert_hotspot specification.
// Returns a limited number of events (max 100) to stay within safe batch size limits.
func generateHotspotEvents(hotspot map[string]interface{}) []types.GeoEvent {
	centerLat := 0.0
	if v, ok := hotspot["center_latitude"].(float64); ok {
		centerLat = v
	}
	centerLon := 0.0
	if v, ok := hotspot["center_longitude"].(float64); ok {
		centerLon = v
	}
	count := 0
	if v, ok := hotspot["count"].(float64); ok {
		count = int(v)
	}
	startID := uint64(0)
	if v, ok := hotspot["start_entity_id"].(float64); ok {
		startID = uint64(v)
	}
	concentration := 0.95 // default 95%
	if v, ok := hotspot["concentration_percentage"].(float64); ok {
		concentration = v / 100.0
	}

	// Use full fixture count; batching handles large inserts in tests.

	events := make([]types.GeoEvent, 0, count)
	// Most events (concentration%) within ~500m, rest spread further
	nearSpreadDeg := 0.005 // ~500m
	farSpreadDeg := 0.05   // ~5km

	hotspotCount := int(float64(count) * concentration)
	if hotspotCount > count {
		hotspotCount = count
	}
	spreadCount := count - hotspotCount

	for i := 0; i < count; i++ {
		isNear := i < hotspotCount
		total := spreadCount
		idx := i - hotspotCount
		spread := farSpreadDeg
		if isNear {
			total = hotspotCount
			idx = i
			spread = nearSpreadDeg
		}
		if total <= 0 {
			total = 1
		}
		cols := 10
		if total < cols {
			cols = total
		}
		if cols <= 0 {
			cols = 1
		}
		rows := (total + cols - 1) / cols
		row := idx / cols
		col := idx % cols
		rowFrac := 0.5
		colFrac := 0.5
		if rows > 1 {
			rowFrac = float64(row) / float64(rows-1)
		}
		if cols > 1 {
			colFrac = float64(col) / float64(cols-1)
		}
		lat := centerLat + (rowFrac-0.5)*spread
		lon := centerLon + (colFrac-0.5)*spread

		event := types.GeoEvent{
			EntityID: types.ToUint128(startID + uint64(i)),
			LatNano:  types.DegreesToNano(lat),
			LonNano:  types.DegreesToNano(lon),
		}
		events = append(events, event)
	}
	return events
}

// GetExpectedResultCode extracts expected result_code from expected_output.
func GetExpectedResultCode(expected map[string]interface{}) int {
	if v, ok := expected["result_code"].(float64); ok {
		return int(v)
	}
	return 0
}

// GetExpectedCount extracts expected count from expected_output.
func GetExpectedCount(expected map[string]interface{}) int {
	if v, ok := expected["count"].(float64); ok {
		return int(v)
	}
	if v, ok := expected["count_in_range"].(float64); ok {
		return int(v)
	}
	if v, ok := expected["results_count"].(float64); ok {
		return int(v)
	}
	return -1
}

// GetExpectedEntities extracts expected entity IDs from events_contain.
func GetExpectedEntities(expected map[string]interface{}) []uint64 {
	if arr, ok := expected["events_contain"].([]interface{}); ok {
		ids := make([]uint64, 0, len(arr))
		for _, v := range arr {
			if id, ok := v.(float64); ok {
				ids = append(ids, uint64(id))
			}
		}
		return ids
	}
	return nil
}
