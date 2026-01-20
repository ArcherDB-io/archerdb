package archerdb

import (
	"fmt"
	"net"
	"os"
	"testing"
	"time"

	"github.com/archerdb/archerdb-go/pkg/types"
)

// isServerAvailable checks if an ArcherDB server is running at the given address.
func isServerAvailable(address string) bool {
	conn, err := net.DialTimeout("tcp", address, 1*time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func TestGeoClientWiring(t *testing.T) {
	// Integration tests require ARCHERDB_INTEGRATION env var to be set
	// This prevents accidentally running against non-ArcherDB services on the same port
	serverAddr := os.Getenv("ARCHERDB_ADDRESS")
	if serverAddr == "" {
		serverAddr = "127.0.0.1:3001"
	}
	if os.Getenv("ARCHERDB_INTEGRATION") == "" {
		t.Skip("Skipping integration test: set ARCHERDB_INTEGRATION=1 to run against server at " + serverAddr)
	}

	// Create client connecting to local cluster
	config := GeoClientConfig{
		ClusterID: types.ToUint128(0),
		Addresses: []string{serverAddr},
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

	// Test 1b: Multi-batch insert (small batch size override for test)
	t.Run("InsertEventsMultiBatch", func(t *testing.T) {
		concrete, ok := client.(*geoClient)
		if !ok {
			t.Fatalf("Expected geoClient implementation, got %T", client)
		}

		events := make([]types.GeoEvent, 0, 3)
		for i := 0; i < 3; i++ {
			event, err := types.NewGeoEvent(types.GeoEventOptions{
				EntityID:  types.ID(),
				Latitude:  37.7749 + float64(i)*0.0001,
				Longitude: -122.4194 - float64(i)*0.0001,
				TTLSeconds: 86400,
			})
			if err != nil {
				t.Fatalf("Failed to create event: %v", err)
			}
			events = append(events, event)
		}

		for i := range events {
			types.PrepareGeoEvent(&events[i])
		}

		errors, err := submitInsertBatches(events, 2, func(chunk []types.GeoEvent) ([]types.InsertGeoEventsError, error) {
			return concrete.withRetry(func() ([]types.InsertGeoEventsError, error) {
				return concrete.submitInsertEventsOnce(chunk, types.GeoOperationInsertEvents)
			})
		})
		if err != nil {
			t.Fatalf("submitInsertBatches failed: %v", err)
		}
		if len(errors) > 0 {
			t.Fatalf("Expected no errors, got %d: %+v", len(errors), errors)
		}
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
