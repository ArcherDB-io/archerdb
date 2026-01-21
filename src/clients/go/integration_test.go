package archerdb

import (
	"os"
	"testing"
	"time"

	"github.com/archerdb/archerdb-go/pkg/types"
)

func TestInsertQueryDeleteRoundTrip(t *testing.T) {
	if os.Getenv("ARCHERDB_INTEGRATION") != "1" {
		t.Skip("Set ARCHERDB_INTEGRATION=1 to run integration tests")
	}

	address := os.Getenv("ARCHERDB_ADDRESS")
	if address == "" {
		address = "127.0.0.1:3001"
	}

	config := GeoClientConfig{
		ClusterID: types.ToUint128(0),
		Addresses: []string{address},
	}
	client, err := NewGeoClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close()

	entityID := types.ID()
	lat := 37.7749
	lon := -122.4194
	event := types.GeoEvent{
		EntityID:   entityID,
		LatNano:    types.DegreesToNano(lat),
		LonNano:    types.DegreesToNano(lon),
		Timestamp:  0,
		TTLSeconds: 60,
	}

	// 1. Insert
	errors, err := client.InsertEvents([]types.GeoEvent{event})
	if err != nil {
		t.Fatalf("InsertEvents failed: %v", err)
	}
	if len(errors) > 0 {
		t.Fatalf("InsertEvents returned errors: %v", errors)
	}

	// 2. Query UUID
	// Wait a bit for propagation if needed
	var found *types.GeoEvent
	for i := 0; i < 10; i++ {
		found, err = client.GetLatestByUUID(entityID)
		if err != nil {
			t.Fatalf("GetLatestByUUID failed: %v", err)
		}
		if found != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	if found == nil {
		t.Fatalf("GetLatestByUUID returned nil (not found)")
	}
	// Need to check if EntityID matches. Uint128 might need comparison method or Bytes() check.
	if found.EntityID.Bytes() != entityID.Bytes() {
		t.Errorf("Expected EntityID %v, got %v", entityID, found.EntityID)
	}

	// 3. Query Radius
	radiusFilter := types.QueryRadiusFilter{
		CenterLatNano: types.DegreesToNano(lat),
		CenterLonNano: types.DegreesToNano(lon),
		RadiusMM:      2000 * 1000,
		Limit:         5,
	}
	radiusResult, err := client.QueryRadius(radiusFilter)
	if err != nil {
		t.Fatalf("QueryRadius failed: %v", err)
	}
	if len(radiusResult.Events) == 0 {
		t.Errorf("QueryRadius returned 0 events")
	}

	// 4. Delete
	deleteBatch := []types.Uint128{entityID}
	deleteResult, err := client.DeleteEntities(deleteBatch)
	if err != nil {
		t.Fatalf("DeleteEntities failed: %v", err)
	}
	if deleteResult.DeletedCount != 1 {
		t.Errorf("Expected DeletedCount 1, got %d", deleteResult.DeletedCount)
	}

	// 5. Verify Delete
	foundAfterDelete, err := client.GetLatestByUUID(entityID)
	if err != nil {
		t.Fatalf("GetLatestByUUID failed: %v", err)
	}
	if foundAfterDelete != nil {
		t.Errorf("Entity should be deleted, but was found")
	}
}
