package archerdb

import (
	"fmt"
	"testing"

	"github.com/archerdb/archerdb-go/pkg/types"
)

func TestGeoClientWiring(t *testing.T) {
	// Create client connecting to local cluster
	config := GeoClientConfig{
		ClusterID: types.ToUint128(0),
		Addresses: []string{"127.0.0.1:3001"},
	}

	client, err := NewGeoClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close()

	// Test 1: Insert a GeoEvent
	t.Run("InsertEvent", func(t *testing.T) {
		event, err := types.NewGeoEvent(types.GeoEventOptions{
			EntityID:  types.ID(),
			Latitude:  37.7749,
			Longitude: -122.4194,
			TTLSeconds: 86400,
		})
		if err != nil {
			t.Fatalf("Failed to create event: %v", err)
		}

		results, err := client.InsertEvents([]types.GeoEvent{event})
		if err != nil {
			t.Fatalf("InsertEvents failed: %v", err)
		}

		if len(results) > 0 {
			t.Errorf("Expected no errors, got %d: %+v", len(results), results)
		}

		fmt.Printf("Inserted event with entity_id=%s\n", event.EntityID.String())
	})

	// Test 2: Query by UUID
	t.Run("QueryUUID", func(t *testing.T) {
		// Insert a new event
		entityID := types.ID()
		event, err := types.NewGeoEvent(types.GeoEventOptions{
			EntityID:  entityID,
			Latitude:  40.7128,
			Longitude: -74.0060,
		})
		if err != nil {
			t.Fatalf("Failed to create event: %v", err)
		}

		_, err = client.InsertEvents([]types.GeoEvent{event})
		if err != nil {
			t.Fatalf("InsertEvents failed: %v", err)
		}

		// Query by UUID
		found, err := client.GetLatestByUUID(entityID)
		if err != nil {
			t.Fatalf("GetLatestByUUID failed: %v", err)
		}

		if found == nil {
			t.Error("Expected to find event, got nil")
		} else {
			fmt.Printf("Found event: lat=%.4f, lon=%.4f\n", found.Latitude(), found.Longitude())
		}
	})

	// Test 3: QueryLatest
	t.Run("QueryLatest", func(t *testing.T) {
		filter := types.QueryLatestFilter{
			Limit: 10,
		}

		result, err := client.QueryLatest(filter)
		if err != nil {
			t.Fatalf("QueryLatest failed: %v", err)
		}

		fmt.Printf("QueryLatest returned %d events, hasMore=%v\n", len(result.Events), result.HasMore)
	})

	fmt.Println("All Go SDK wiring tests passed!")
}
