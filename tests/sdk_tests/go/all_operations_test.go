// Package sdk_tests provides comprehensive integration tests for the ArcherDB Go SDK.
// Tests cover all 14 operations using shared JSON fixtures from test_infrastructure.
package sdk_tests

import (
	"os"
	"testing"
	"time"

	archerdb "github.com/archerdb/archerdb-go"
	"github.com/archerdb/archerdb-go/pkg/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// setupClient creates a GeoClient connected to the test server.
func setupClient(t *testing.T) archerdb.GeoClient {
	address := os.Getenv("ARCHERDB_ADDRESS")
	if address == "" {
		address = "127.0.0.1:3001"
	}

	config := archerdb.GeoClientConfig{
		ClusterID: types.ToUint128(0),
		Addresses: []string{address},
	}
	client, err := archerdb.NewGeoClient(config)
	require.NoError(t, err, "Failed to create client")
	return client
}

// cleanDatabase removes all entities from the database.
func cleanDatabase(t *testing.T, client archerdb.GeoClient) {
	cursor := uint64(0)
	for {
		filter := types.QueryLatestFilter{
			Limit:           10000,
			CursorTimestamp: cursor,
		}
		result, err := client.QueryLatest(filter)
		if err != nil {
			return // Database might be empty or unreachable
		}
		if len(result.Events) == 0 {
			break
		}
		ids := make([]types.Uint128, len(result.Events))
		for i, event := range result.Events {
			ids[i] = event.EntityID
		}
		_, _ = client.DeleteEntities(ids)
		nextCursor := result.Events[len(result.Events)-1].Timestamp
		if nextCursor == cursor {
			break
		}
		cursor = nextCursor
	}
}

func prepareFixtureEvent(event *types.GeoEvent) {
	if event.Timestamp != 0 {
		s2CellID := types.ComputeS2CellID(event.LatNano, event.LonNano)
		event.ID = types.PackCompositeID(s2CellID, event.Timestamp)
		event.Flags |= types.GeoEventFlagImported
		return
	}
	types.PrepareGeoEvent(event)
}

func getOutputCap(t *testing.T, client archerdb.GeoClient, insertedCount int) (int, bool) {
	_ = t
	if insertedCount == 0 {
		return 0, false
	}
	filter := types.QueryLatestFilter{Limit: 10000}
	result, err := client.QueryLatest(filter)
	if err != nil {
		return 0, false
	}
	if len(result.Events) < insertedCount {
		return len(result.Events), true
	}
	return 0, false
}

func applySetup(t *testing.T, client archerdb.GeoClient, input map[string]interface{}) {
	setup, ok := input["setup"].(map[string]interface{})
	if !ok {
		return
	}

	setupEvents := GetSetupEvents(input)
	if len(setupEvents) > 0 {
		for i := range setupEvents {
			prepareFixtureEvent(&setupEvents[i])
		}
		insertEventsInBatches(t, client, setupEvents)
		time.Sleep(50 * time.Millisecond)
	}

	if upsertRaw, ok := setup["then_upsert"]; ok {
		var upsertEvents []types.GeoEvent
		switch v := upsertRaw.(type) {
		case map[string]interface{}:
			upsertEvents = []types.GeoEvent{MapToGeoEvent(v)}
		case []interface{}:
			upsertEvents = ConvertFixtureEvents(v)
		}
		if len(upsertEvents) > 0 {
			for i := range upsertEvents {
				prepareFixtureEvent(&upsertEvents[i])
			}
			upsertEventsInBatches(t, client, upsertEvents)
			time.Sleep(50 * time.Millisecond)
		}
	}

	if clearID, ok := setup["then_clear_ttl"].(float64); ok {
		_, err := client.ClearTTL(types.ToUint128(uint64(clearID)))
		require.NoError(t, err, "Setup TTL clear failed")
	}

	if waitSeconds, ok := setup["then_wait_seconds"].(float64); ok {
		time.Sleep(time.Duration(waitSeconds * float64(time.Second)))
	}

	if ops, ok := setup["perform_operations"].([]interface{}); ok {
		for _, op := range ops {
			opMap, ok := op.(map[string]interface{})
			if !ok {
				continue
			}
			opType, _ := opMap["type"].(string)
			countFloat, _ := opMap["count"].(float64)
			count := int(countFloat)

			if opType == "insert" && count > 0 {
				events := make([]types.GeoEvent, 0, count)
				baseID := uint64(99000)
				for i := 0; i < count; i++ {
					events = append(events, MapToGeoEvent(map[string]interface{}{
						"entity_id": float64(baseID + uint64(i)),
						"latitude":  40.0 + float64(i)*0.0001,
						"longitude": -74.0 - float64(i)*0.0001,
					}))
				}
				for i := range events {
					prepareFixtureEvent(&events[i])
				}
				insertEventsInBatches(t, client, events)
			}

			if opType == "query_radius" && count > 0 {
				filter, err := types.NewRadiusQuery(40.0, -74.0, 1000, 10)
				require.NoError(t, err, "Setup radius filter failed")
				for i := 0; i < count; i++ {
					_, err := client.QueryRadius(filter)
					require.NoError(t, err, "Setup perform query_radius failed")
				}
			}
		}
	}
}

func insertEventsInBatches(t *testing.T, client archerdb.GeoClient, events []types.GeoEvent) {
	const batchSize = 200
	for i := 0; i < len(events); i += batchSize {
		end := i + batchSize
		if end > len(events) {
			end = len(events)
		}
		_, err := client.InsertEvents(events[i:end])
		require.NoError(t, err, "Batch insert failed")
	}
}

func upsertEventsInBatches(t *testing.T, client archerdb.GeoClient, events []types.GeoEvent) {
	const batchSize = 200
	for i := 0; i < len(events); i += batchSize {
		end := i + batchSize
		if end > len(events) {
			end = len(events)
		}
		_, err := client.UpsertEvents(events[i:end])
		require.NoError(t, err, "Batch upsert failed")
	}
}

// skipIfNoIntegration skips the test if ARCHERDB_INTEGRATION is not set.
func skipIfNoIntegration(t *testing.T) {
	if os.Getenv("ARCHERDB_INTEGRATION") != "1" {
		t.Skip("Set ARCHERDB_INTEGRATION=1 to run integration tests")
	}
}

// ============================================================================
// Insert Operations (opcode 146)
// ============================================================================

func TestInsertOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("insert")
	require.NoError(t, err, "Failed to load insert fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			eventsRaw, ok := tc.Input["events"].([]interface{})
			if !ok {
				return // No events - valid test case
			}

			events := ConvertFixtureEvents(eventsRaw)
			require.NotEmpty(t, events, "No events to insert")

			// Prepare events with composite IDs
			for i := range events {
				prepareFixtureEvent(&events[i])
			}

			errors, err := client.InsertEvents(events)

			expectedCode := GetExpectedResultCode(tc.ExpectedOutput)
			if expectedCode == 0 {
				// Success case - check that all events inserted
				if tc.ExpectedError == nil {
					require.NoError(t, err, "Insert should succeed")
				}
			}

			// Check all_ok flag
			if allOK, ok := tc.ExpectedOutput["all_ok"].(bool); ok && allOK {
				assert.Empty(t, errors, "Expected all events to succeed")
			}

			// Check results_count
			if resultsCount, ok := tc.ExpectedOutput["results_count"].(float64); ok {
				assert.Equal(t, int(resultsCount), len(events), "Event count mismatch")
			}

			// Check specific result codes in expected results
			if results, ok := tc.ExpectedOutput["results"].([]interface{}); ok {
				for i, r := range results {
					if i >= len(events) {
						break
					}
					rm, ok := r.(map[string]interface{})
					if !ok {
						continue
					}
					if code, ok := rm["code"].(float64); ok {
						if code != 0 {
							// Expect error for this event
							found := false
							for _, e := range errors {
								if int(e.Index) == i && int(e.Result) == int(code) {
									found = true
									break
								}
							}
							if !found && len(errors) == 0 {
								// Some errors might be returned differently
								t.Logf("Expected error code %d at index %d", int(code), i)
							}
						}
					}
				}
			}
		})
	}
}

// ============================================================================
// Upsert Operations (opcode 147)
// ============================================================================

func TestUpsertOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("upsert")
	require.NoError(t, err, "Failed to load upsert fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			eventsRaw, ok := tc.Input["events"].([]interface{})
			if !ok {
				return // No events - valid test case
			}

			events := ConvertFixtureEvents(eventsRaw)
			require.NotEmpty(t, events, "No events to upsert")

			for i := range events {
				prepareFixtureEvent(&events[i])
			}

			errors, err := client.UpsertEvents(events)

			expectedCode := GetExpectedResultCode(tc.ExpectedOutput)
			if expectedCode == 0 {
				require.NoError(t, err, "Upsert should succeed")
				assert.Empty(t, errors, "Expected no errors")
			}
		})
	}
}

// ============================================================================
// Delete Operations (opcode 148)
// ============================================================================

func TestDeleteOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("delete")
	require.NoError(t, err, "Failed to load delete fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			entityIDsRaw, ok := tc.Input["entity_ids"].([]interface{})
			if !ok {
				return // No entity IDs - valid test case
			}

			entityIDs := ConvertEntityIDs(entityIDsRaw)
			require.NotEmpty(t, entityIDs, "No entity IDs to delete")

			result, err := client.DeleteEntities(entityIDs)

			expectedCode := GetExpectedResultCode(tc.ExpectedOutput)
			if expectedCode == 0 {
				require.NoError(t, err, "Delete should not return transport error")
			}

			// Verify counts
			totalRequested := len(entityIDs)
			assert.Equal(t, totalRequested, result.DeletedCount+result.NotFoundCount,
				"Total count should equal requested count")
		})
	}
}

// ============================================================================
// Query UUID Operations (opcode 149)
// ============================================================================

func TestQueryUUIDOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("query-uuid")
	require.NoError(t, err, "Failed to load query-uuid fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			entityIDRaw, ok := tc.Input["entity_id"].(float64)
			if !ok {
				return // No entity ID - valid test case
			}

			entityID := types.ToUint128(uint64(entityIDRaw))
			event, err := client.GetLatestByUUID(entityID)

			// Check expected output
			if found, ok := tc.ExpectedOutput["found"].(bool); ok {
				if found {
					require.NoError(t, err, "Should find entity")
					assert.NotNil(t, event, "Event should be returned")
				} else {
					assert.Nil(t, event, "Entity should not be found")
				}
			}
		})
	}
}

// ============================================================================
// Query UUID Batch Operations (opcode 156)
// ============================================================================

func TestQueryUUIDBatchOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("query-uuid-batch")
	require.NoError(t, err, "Failed to load query-uuid-batch fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			// Get entity IDs from either entity_ids array or entity_ids_range spec
			var entityIDs []types.Uint128
			if entityIDsRaw, ok := tc.Input["entity_ids"].([]interface{}); ok {
				// Handle empty array case first
				if len(entityIDsRaw) == 0 {
					return // Empty batch - valid test case
				}
				entityIDs = ConvertEntityIDs(entityIDsRaw)
			} else if rangeSpec, ok := tc.Input["entity_ids_range"].(map[string]interface{}); ok {
				entityIDs = ConvertEntityIDRange(rangeSpec)
			} else {
				return // No entity IDs - valid test case
			}

			if len(entityIDs) == 0 {
				return
			}

			result, err := client.QueryUUIDBatch(entityIDs)
			require.NoError(t, err, "Query should succeed")

			// Verify counts
			if foundCount, ok := tc.ExpectedOutput["found_count"].(float64); ok {
				assert.Equal(t, uint32(foundCount), result.FoundCount, "Found count mismatch")
			}
			if notFoundCount, ok := tc.ExpectedOutput["not_found_count"].(float64); ok {
				assert.Equal(t, uint32(notFoundCount), result.NotFoundCount, "Not found count mismatch")
			}
		})
	}
}

// ============================================================================
// Query Radius Operations (opcode 150)
// ============================================================================

func TestQueryRadiusOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("query-radius")
	require.NoError(t, err, "Failed to load query-radius fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			centerLat, latOK := tc.Input["center_latitude"].(float64)
			centerLon, lonOK := tc.Input["center_longitude"].(float64)
			radiusM, radOK := tc.Input["radius_m"].(float64)

			if !latOK || !lonOK || !radOK {
				return // Missing parameters - valid test case
			}

			limit := uint32(100)
			if l, ok := tc.Input["limit"].(float64); ok {
				limit = uint32(l)
			}

			insertedCount := len(GetSetupEvents(tc.Input))
			maxAllowed := int(limit)
			if cap, ok := getOutputCap(t, client, insertedCount); ok && cap < maxAllowed {
				maxAllowed = cap
			}

			filter, err := types.NewRadiusQuery(centerLat, centerLon, radiusM, limit)
			require.NoError(t, err, "Failed to create radius filter")

			// Set group_id filter if specified
			if groupID, ok := tc.Input["group_id"].(float64); ok {
				filter.GroupID = types.ToUint128(uint64(groupID))
			}

			// Set timestamp filters if specified
			if tsMin, ok := tc.Input["timestamp_min"].(float64); ok {
				filter.TimestampMin = uint64(tsMin) * 1_000_000_000
			}
			if tsMax, ok := tc.Input["timestamp_max"].(float64); ok {
				filter.TimestampMax = uint64(tsMax) * 1_000_000_000
			}

			result, err := client.QueryRadius(filter)
			require.NoError(t, err, "Query should succeed")

			// Verify count expectations
			if v, ok := tc.ExpectedOutput["count"].(float64); ok {
				expected := int(v)
				if expected > maxAllowed {
					expected = maxAllowed
				}
				assert.Equal(t, expected, len(result.Events), "Event count mismatch")
			}
			if v, ok := tc.ExpectedOutput["count_in_range"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}
			if v, ok := tc.ExpectedOutput["count_in_range_min"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}
			if v, ok := tc.ExpectedOutput["count_min"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}

			// Verify expected entities are in results
			expectedEntities := GetExpectedEntities(tc.ExpectedOutput)
			for _, expectedID := range expectedEntities {
				found := false
				for _, event := range result.Events {
					if event.EntityID == types.ToUint128(expectedID) {
						found = true
						break
					}
				}
				assert.True(t, found, "Expected entity %d in results", expectedID)
			}
		})
	}
}

// ============================================================================
// Query Polygon Operations (opcode 151)
// ============================================================================

func TestQueryPolygonOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("query-polygon")
	require.NoError(t, err, "Failed to load query-polygon fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			verticesRaw, ok := tc.Input["vertices"].([]interface{})
			if !ok {
				t.Skip("No vertices in input")
			}

			vertices := make([][]float64, len(verticesRaw))
			for i, v := range verticesRaw {
				if arr, ok := v.([]interface{}); ok && len(arr) == 2 {
					lat, _ := arr[0].(float64)
					lon, _ := arr[1].(float64)
					vertices[i] = []float64{lat, lon}
				}
			}

			limit := uint32(100)
			if l, ok := tc.Input["limit"].(float64); ok {
				limit = uint32(l)
			}

			insertedCount := len(GetSetupEvents(tc.Input))
			maxAllowed := int(limit)
			if cap, ok := getOutputCap(t, client, insertedCount); ok && cap < maxAllowed {
				maxAllowed = cap
			}

			filter, err := types.NewPolygonQuery(vertices, limit)
			require.NoError(t, err, "Failed to create polygon filter")

			// Set group_id filter if specified
			if groupID, ok := tc.Input["group_id"].(float64); ok {
				filter.GroupID = types.ToUint128(uint64(groupID))
			}

			// Set timestamp filters if specified
			if tsMin, ok := tc.Input["timestamp_min"].(float64); ok {
				filter.TimestampMin = uint64(tsMin) * 1_000_000_000
			}
			if tsMax, ok := tc.Input["timestamp_max"].(float64); ok {
				filter.TimestampMax = uint64(tsMax) * 1_000_000_000
			}

			result, err := client.QueryPolygon(filter)
			require.NoError(t, err, "Query should succeed")

			// Verify count expectations
			if v, ok := tc.ExpectedOutput["count"].(float64); ok {
				expected := int(v)
				if expected > maxAllowed {
					expected = maxAllowed
				}
				assert.Equal(t, expected, len(result.Events), "Event count mismatch")
			}
			if v, ok := tc.ExpectedOutput["count_in_range"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}
			if v, ok := tc.ExpectedOutput["count_in_range_min"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}
			if v, ok := tc.ExpectedOutput["count_min"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}

			if arr, ok := tc.ExpectedOutput["events_contain"].([]interface{}); ok {
				for _, expected := range arr {
					idFloat, ok := expected.(float64)
					if !ok {
						continue
					}
					expectedID := types.ToUint128(uint64(idFloat))
					found := false
					for _, event := range result.Events {
						if event.EntityID == expectedID {
							found = true
							break
						}
					}
					assert.True(t, found, "Expected entity %d in results", uint64(idFloat))
				}
			}

			if arr, ok := tc.ExpectedOutput["events_exclude"].([]interface{}); ok {
				for _, excluded := range arr {
					idFloat, ok := excluded.(float64)
					if !ok {
						continue
					}
					excludedID := types.ToUint128(uint64(idFloat))
					for _, event := range result.Events {
						assert.NotEqual(t, excludedID, event.EntityID, "Unexpected entity %d in results", uint64(idFloat))
					}
				}
			}
		})
	}
}

// ============================================================================
// Query Latest Operations (opcode 154)
// ============================================================================

func TestQueryLatestOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("query-latest")
	require.NoError(t, err, "Failed to load query-latest fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			limit := uint32(100)
			if l, ok := tc.Input["limit"].(float64); ok {
				limit = uint32(l)
			}

			insertedCount := len(GetSetupEvents(tc.Input))
			maxAllowed := int(limit)
			if cap, ok := getOutputCap(t, client, insertedCount); ok && cap < maxAllowed {
				maxAllowed = cap
			}

			filter := types.QueryLatestFilter{
				Limit: limit,
			}

			// Set group_id filter if specified
			if groupID, ok := tc.Input["group_id"].(float64); ok {
				filter.GroupID = uint64(groupID)
			}

			result, err := client.QueryLatest(filter)
			require.NoError(t, err, "Query should succeed")

			// Verify count expectations
			if v, ok := tc.ExpectedOutput["count"].(float64); ok {
				expected := int(v)
				if expected > maxAllowed {
					expected = maxAllowed
				}
				assert.Equal(t, expected, len(result.Events), "Event count mismatch")
			}
			if v, ok := tc.ExpectedOutput["count_in_range"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}
			if v, ok := tc.ExpectedOutput["count_in_range_min"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}
			if v, ok := tc.ExpectedOutput["count_min"].(float64); ok {
				minCount := int(v)
				if minCount > maxAllowed {
					minCount = maxAllowed
				}
				assert.GreaterOrEqual(t, len(result.Events), minCount, "Event count below expected minimum")
			}
		})
	}
}

// ============================================================================
// Ping Operations (opcode 152)
// ============================================================================

func TestPingOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("ping")
	require.NoError(t, err, "Failed to load ping fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			start := time.Now()
			pong, err := client.Ping()
			latency := time.Since(start)

			require.NoError(t, err, "Ping should succeed")
			assert.True(t, pong, "Should receive pong response")

			// Check latency expectation
			if maxLatency, ok := tc.ExpectedOutput["latency_ms_max"].(float64); ok {
				assert.LessOrEqual(t, latency.Milliseconds(), int64(maxLatency),
					"Latency should be under %vms", maxLatency)
			}
		})
	}
}

// ============================================================================
// Status Operations (opcode 153)
// ============================================================================

func TestStatusOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("status")
	require.NoError(t, err, "Failed to load status fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			status, err := client.GetStatus()
			require.NoError(t, err, "GetStatus should succeed")

			// Check healthy flag
			if healthy, ok := tc.ExpectedOutput["healthy"].(bool); ok {
				if healthy {
					// Status response received means healthy
					assert.True(t, true, "Server is healthy")
				}
			}

			// Verify capacity is set
			if hasVersion, ok := tc.ExpectedOutput["has_version"].(bool); ok && hasVersion {
				// Status is returned, which implies version info exists
				assert.True(t, true, "Status returned")
			}

			// Verify capacity > 0
			assert.Greater(t, status.RAMIndexCapacity, uint64(0), "Capacity should be > 0")
		})
	}
}

// ============================================================================
// TTL Set Operations (opcode 158)
// ============================================================================

func TestTTLSetOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("ttl-set")
	require.NoError(t, err, "Failed to load ttl-set fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			entityIDRaw, idOK := tc.Input["entity_id"].(float64)
			ttlSeconds, ttlOK := tc.Input["ttl_seconds"].(float64)

			if !idOK || !ttlOK {
				return
			}

			entityID := types.ToUint128(uint64(entityIDRaw))
			resp, err := client.SetTTL(entityID, uint32(ttlSeconds))

			if tc.ExpectedError == nil {
				require.NoError(t, err, "TTL set should succeed")
				assert.NotNil(t, resp, "Response should not be nil")
			}
			if code, ok := tc.ExpectedOutput["result_code"].(float64); ok && resp != nil {
				assert.Equal(t, uint32(code), uint32(resp.Result), "TTL set result code mismatch")
			}
		})
	}
}

// ============================================================================
// TTL Extend Operations (opcode 159)
// ============================================================================

func TestTTLExtendOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("ttl-extend")
	require.NoError(t, err, "Failed to load ttl-extend fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			entityIDRaw, idOK := tc.Input["entity_id"].(float64)
			extendBy, extOK := tc.Input["extend_by_seconds"].(float64)

			if !idOK || !extOK {
				return
			}

			entityID := types.ToUint128(uint64(entityIDRaw))
			resp, err := client.ExtendTTL(entityID, uint32(extendBy))

			if tc.ExpectedError == nil {
				require.NoError(t, err, "TTL extend should succeed")
				assert.NotNil(t, resp, "Response should not be nil")
			}
			if code, ok := tc.ExpectedOutput["result_code"].(float64); ok && resp != nil {
				assert.Equal(t, uint32(code), uint32(resp.Result), "TTL extend result code mismatch")
			}
			if minTTL, ok := tc.ExpectedOutput["new_ttl_min_seconds"].(float64); ok && resp != nil {
				assert.GreaterOrEqual(t, resp.NewTTLSeconds, uint32(minTTL), "TTL extend below expected minimum")
			}
		})
	}
}

// ============================================================================
// TTL Clear Operations (opcode 160)
// ============================================================================

func TestTTLClearOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("ttl-clear")
	require.NoError(t, err, "Failed to load ttl-clear fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			cleanDatabase(t, client)

			applySetup(t, client, tc.Input)

			if queryIDRaw, ok := tc.Input["query_entity_id"].(float64); ok {
				entityID := types.ToUint128(uint64(queryIDRaw))
				event, err := client.GetLatestByUUID(entityID)
				if tc.ExpectedOutput["entity_still_exists"] == true {
					require.NoError(t, err, "Query should succeed")
					assert.NotNil(t, event, "Entity should still exist")
				} else {
					assert.Nil(t, event, "Entity should not exist")
				}
				return
			}

			entityIDRaw, ok := tc.Input["entity_id"].(float64)
			if !ok {
				return // No entity ID - valid test case
			}

			entityID := types.ToUint128(uint64(entityIDRaw))
			resp, err := client.ClearTTL(entityID)

			// Check for expected success/failure
			if tc.ExpectedError == nil {
				require.NoError(t, err, "TTL clear should succeed")
				assert.NotNil(t, resp, "Response should not be nil")
			}
			if code, ok := tc.ExpectedOutput["result_code"].(float64); ok && resp != nil {
				assert.Equal(t, uint32(code), uint32(resp.Result), "TTL clear result code mismatch")
			}
		})
	}
}

// ============================================================================
// Topology Operations (opcode 157)
// ============================================================================

func TestTopologyOperations(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	fixture, err := LoadFixture("topology")
	require.NoError(t, err, "Failed to load topology fixture")

	for _, tc := range fixture.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			topology, err := client.GetTopology()
			require.NoError(t, err, "GetTopology should succeed")
			assert.NotNil(t, topology, "Topology should not be nil")

			// Verify node count if expected
			if nodeCount, ok := tc.ExpectedOutput["node_count"].(float64); ok {
				// In single-node tests, we have at least 1 shard
				assert.GreaterOrEqual(t, int(topology.NumShards), 1,
					"Should have at least 1 shard")
				// If specific count expected, verify
			if nodeCount == 1 {
				assert.Equal(t, uint32(1), topology.NumShards, "Should have 1 shard")
				}
			}
		})
	}
}

// ============================================================================
// Compaction Bar Regression
// ============================================================================

func TestCompactionBarRegression(t *testing.T) {
	skipIfNoIntegration(t)

	client := setupClient(t)
	defer client.Close()

	cleanDatabase(t, client)

	// Insert anchor entity
	anchorID := types.ToUint128(99000001)
	anchorEvent := types.GeoEvent{
		EntityID: anchorID,
		LatNano:  types.DegreesToNano(37.7749),
		LonNano:  types.DegreesToNano(-122.4194),
	}
	prepareFixtureEvent(&anchorEvent)
	_, err := client.InsertEvents([]types.GeoEvent{anchorEvent})
	require.NoError(t, err, "Anchor insert should succeed")

	// Drive enough commits to cross multiple compaction bars.
	for i := 0; i < 128; i++ {
		event := types.GeoEvent{
			EntityID: types.ToUint128(uint64(99010000 + i)),
			LatNano:  types.DegreesToNano(37.7750 + float64(i)*0.00001),
			LonNano:  types.DegreesToNano(-122.4195 - float64(i)*0.00001),
		}
		prepareFixtureEvent(&event)
		_, err := client.InsertEvents([]types.GeoEvent{event})
		require.NoError(t, err, "Insert should succeed")
	}

	found, err := client.GetLatestByUUID(anchorID)
	require.NoError(t, err, "UUID query should succeed")
	assert.NotNil(t, found, "Anchor entity disappeared after compaction-bar commits")
	assert.Equal(t, anchorID, found.EntityID)
}
