package types

import (
	"sync"
	"testing"
	"time"
)

// TestShardStatus tests ShardStatus constants and String method
func TestShardStatus(t *testing.T) {
	tests := []struct {
		status ShardStatus
		value  uint8
		str    string
	}{
		{ShardActive, 0, "active"},
		{ShardSyncing, 1, "syncing"},
		{ShardUnavailable, 2, "unavailable"},
		{ShardMigrating, 3, "migrating"},
		{ShardDecommissioning, 4, "decommissioning"},
	}

	for _, tt := range tests {
		if uint8(tt.status) != tt.value {
			t.Errorf("ShardStatus %s = %d, want %d", tt.str, tt.status, tt.value)
		}
		if tt.status.String() != tt.str {
			t.Errorf("ShardStatus(%d).String() = %q, want %q", tt.value, tt.status.String(), tt.str)
		}
	}

	// Test unknown status
	if ShardStatus(99).String() != "unknown" {
		t.Error("Unknown ShardStatus should return 'unknown'")
	}
}

// TestTopologyChangeType tests TopologyChangeType constants
func TestTopologyChangeType(t *testing.T) {
	tests := []struct {
		changeType TopologyChangeType
		value      uint8
	}{
		{TopologyChangeLeader, 0},
		{TopologyChangeReplicaAdded, 1},
		{TopologyChangeReplicaRemoved, 2},
		{TopologyChangeReshardingStarted, 3},
		{TopologyChangeReshardingCompleted, 4},
		{TopologyChangeStatusChange, 5},
	}

	for _, tt := range tests {
		if uint8(tt.changeType) != tt.value {
			t.Errorf("TopologyChangeType = %d, want %d", tt.changeType, tt.value)
		}
	}
}

// TestTopologyCacheInitialState tests initial cache state
func TestTopologyCacheInitialState(t *testing.T) {
	cache := NewTopologyCache()

	if cache.Get() != nil {
		t.Error("Initial topology should be nil")
	}
	if cache.GetVersion() != 0 {
		t.Errorf("Initial version = %d, want 0", cache.GetVersion())
	}
	if cache.RefreshCount() != 0 {
		t.Errorf("Initial refresh count = %d, want 0", cache.RefreshCount())
	}
	if cache.IsResharding() {
		t.Error("Initial resharding status should be false")
	}
	if cache.GetShardCount() != 0 {
		t.Errorf("Initial shard count = %d, want 0", cache.GetShardCount())
	}
}

// TestTopologyCacheUpdate tests updating topology
func TestTopologyCacheUpdate(t *testing.T) {
	cache := NewTopologyCache()

	topology := &TopologyResponse{
		Version:   1,
		NumShards: 4,
		Shards: []ShardInfo{
			{ID: 0, Primary: "node0:3001", Status: ShardActive},
			{ID: 1, Primary: "node1:3001", Status: ShardActive},
			{ID: 2, Primary: "node2:3001", Status: ShardActive},
			{ID: 3, Primary: "node3:3001", Status: ShardActive},
		},
	}

	cache.Update(topology)

	if cache.GetVersion() != 1 {
		t.Errorf("Version = %d, want 1", cache.GetVersion())
	}
	if cache.GetShardCount() != 4 {
		t.Errorf("Shard count = %d, want 4", cache.GetShardCount())
	}
	if cache.RefreshCount() != 1 {
		t.Errorf("Refresh count = %d, want 1", cache.RefreshCount())
	}
	if cache.Get() == nil {
		t.Error("Topology should not be nil after update")
	}
}

// TestTopologyCacheComputeShard tests shard computation
func TestTopologyCacheComputeShard(t *testing.T) {
	cache := NewTopologyCache()

	// Test with empty topology
	entityID, _ := HexStringToUint128("123456789ABCDEF0")
	if cache.ComputeShard(entityID) != 0 {
		t.Error("ComputeShard should return 0 for empty topology")
	}

	// Update with topology
	cache.Update(&TopologyResponse{
		Version:   1,
		NumShards: 4,
		Shards: []ShardInfo{
			{ID: 0, Primary: "node0:3001"},
			{ID: 1, Primary: "node1:3001"},
			{ID: 2, Primary: "node2:3001"},
			{ID: 3, Primary: "node3:3001"},
		},
	})

	// Shard should be consistent
	shard1 := cache.ComputeShard(entityID)
	shard2 := cache.ComputeShard(entityID)
	if shard1 != shard2 {
		t.Error("ComputeShard should be consistent for same entity ID")
	}
	if shard1 >= 4 {
		t.Errorf("Shard ID = %d, should be < 4", shard1)
	}
}

// TestTopologyCacheGetShardPrimary tests getting shard primaries
func TestTopologyCacheGetShardPrimary(t *testing.T) {
	cache := NewTopologyCache()

	// Empty topology
	if cache.GetShardPrimary(0) != "" {
		t.Error("Should return empty string for empty topology")
	}

	// Update topology
	cache.Update(&TopologyResponse{
		Version:   1,
		NumShards: 2,
		Shards: []ShardInfo{
			{ID: 0, Primary: "node0:3001"},
			{ID: 1, Primary: "node1:3001"},
		},
	})

	if cache.GetShardPrimary(0) != "node0:3001" {
		t.Errorf("Primary(0) = %q, want 'node0:3001'", cache.GetShardPrimary(0))
	}
	if cache.GetShardPrimary(1) != "node1:3001" {
		t.Errorf("Primary(1) = %q, want 'node1:3001'", cache.GetShardPrimary(1))
	}
	if cache.GetShardPrimary(99) != "" {
		t.Error("Invalid shard should return empty string")
	}
}

// TestTopologyCacheGetAllShardPrimaries tests getting all primaries
func TestTopologyCacheGetAllShardPrimaries(t *testing.T) {
	cache := NewTopologyCache()

	// Empty topology
	if cache.GetAllShardPrimaries() != nil {
		t.Error("Should return nil for empty topology")
	}

	// Update topology
	cache.Update(&TopologyResponse{
		Version:   1,
		NumShards: 3,
		Shards: []ShardInfo{
			{ID: 0, Primary: "node0:3001"},
			{ID: 1, Primary: "node1:3001"},
			{ID: 2, Primary: "node2:3001"},
		},
	})

	primaries := cache.GetAllShardPrimaries()
	if len(primaries) != 3 {
		t.Errorf("Primaries count = %d, want 3", len(primaries))
	}
	if primaries[0] != "node0:3001" {
		t.Errorf("Primary[0] = %q, want 'node0:3001'", primaries[0])
	}
}

// TestTopologyCacheIsResharding tests resharding detection
func TestTopologyCacheIsResharding(t *testing.T) {
	cache := NewTopologyCache()

	// No resharding
	cache.Update(&TopologyResponse{Version: 1, NumShards: 2, ReshardingStatus: 0})
	if cache.IsResharding() {
		t.Error("Should not be resharding with status 0")
	}

	// Resharding statuses 1-3
	for status := uint8(1); status <= 3; status++ {
		cache.Update(&TopologyResponse{Version: 2, NumShards: 2, ReshardingStatus: status})
		if !cache.IsResharding() {
			t.Errorf("Should be resharding with status %d", status)
		}
	}
}

// TestTopologyCacheGetActiveShards tests getting active shards
func TestTopologyCacheGetActiveShards(t *testing.T) {
	cache := NewTopologyCache()

	cache.Update(&TopologyResponse{
		Version:   1,
		NumShards: 4,
		Shards: []ShardInfo{
			{ID: 0, Status: ShardActive},
			{ID: 1, Status: ShardSyncing},
			{ID: 2, Status: ShardActive},
			{ID: 3, Status: ShardUnavailable},
		},
	})

	active := cache.GetActiveShards()
	if len(active) != 2 {
		t.Errorf("Active shards count = %d, want 2", len(active))
	}

	// Check expected shards
	expected := map[uint32]bool{0: true, 2: true}
	for _, id := range active {
		if !expected[id] {
			t.Errorf("Unexpected active shard: %d", id)
		}
	}
}

// TestTopologyCacheInvalidate tests cache invalidation
func TestTopologyCacheInvalidate(t *testing.T) {
	cache := NewTopologyCache()

	cache.Update(&TopologyResponse{Version: 5, NumShards: 2})
	if cache.GetVersion() != 5 {
		t.Errorf("Version = %d, want 5", cache.GetVersion())
	}

	cache.Invalidate()
	if cache.GetVersion() != 0 {
		t.Errorf("Version after invalidate = %d, want 0", cache.GetVersion())
	}
}

// TestTopologyCacheOnChange tests change callbacks
func TestTopologyCacheOnChange(t *testing.T) {
	cache := NewTopologyCache()
	var mu sync.Mutex
	var notifications []TopologyChangeNotification

	callback := func(n TopologyChangeNotification) {
		mu.Lock()
		notifications = append(notifications, n)
		mu.Unlock()
	}

	unregister := cache.OnChange(callback)

	// First update (no notification - old version is 0)
	cache.Update(&TopologyResponse{Version: 1, NumShards: 2})
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	if len(notifications) != 0 {
		t.Errorf("Got %d notifications, want 0 for first update", len(notifications))
	}
	mu.Unlock()

	// Second update (should notify)
	cache.Update(&TopologyResponse{Version: 2, NumShards: 2})
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	if len(notifications) != 1 {
		t.Errorf("Got %d notifications, want 1", len(notifications))
	}
	if len(notifications) > 0 {
		if notifications[0].OldVersion != 1 || notifications[0].NewVersion != 2 {
			t.Errorf("Notification versions = %d -> %d, want 1 -> 2",
				notifications[0].OldVersion, notifications[0].NewVersion)
		}
	}
	mu.Unlock()

	// Unregister
	unregister()
	cache.Update(&TopologyResponse{Version: 3, NumShards: 2})
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	if len(notifications) != 1 {
		t.Errorf("Got %d notifications after unregister, want 1", len(notifications))
	}
	mu.Unlock()
}

// TestTopologyCacheThreadSafety tests concurrent access
func TestTopologyCacheThreadSafety(t *testing.T) {
	cache := NewTopologyCache()
	var wg sync.WaitGroup
	iterations := 100

	// Multiple readers
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				cache.Get()
				cache.GetVersion()
				entityID, _ := HexStringToUint128("12345")
				cache.ComputeShard(entityID)
			}
		}()
	}

	// Writer
	wg.Add(1)
	go func() {
		defer wg.Done()
		for j := 0; j < iterations; j++ {
			cache.Update(&TopologyResponse{Version: uint64(j), NumShards: 4})
		}
	}()

	wg.Wait()
	// If we get here without deadlock/panic, test passes
}

// TestShardRouterRouteByEntityID tests routing by entity ID
func TestShardRouterRouteByEntityID(t *testing.T) {
	cache := NewTopologyCache()
	cache.Update(&TopologyResponse{
		Version:   1,
		NumShards: 4,
		Shards: []ShardInfo{
			{ID: 0, Primary: "node0:3001"},
			{ID: 1, Primary: "node1:3001"},
			{ID: 2, Primary: "node2:3001"},
			{ID: 3, Primary: "node3:3001"},
		},
	})

	router := NewShardRouter(cache, nil)
	entityID, _ := HexStringToUint128("123456789ABCDEF0")

	shardID, primary, err := router.RouteByEntityID(entityID)
	if err != nil {
		t.Errorf("RouteByEntityID error: %v", err)
	}
	if shardID >= 4 {
		t.Errorf("Shard ID = %d, should be < 4", shardID)
	}
	if primary == "" {
		t.Error("Primary should not be empty")
	}
}

// TestShardRouterRouteByEntityIDNoPrimary tests routing error
func TestShardRouterRouteByEntityIDNoPrimary(t *testing.T) {
	cache := NewTopologyCache()
	cache.Update(&TopologyResponse{
		Version:   1,
		NumShards: 1,
		Shards: []ShardInfo{
			{ID: 0, Primary: ""}, // Empty primary
		},
	})

	router := NewShardRouter(cache, nil)
	entityIDEmpty, _ := HexStringToUint128("12345")
	_, _, err := router.RouteByEntityID(entityIDEmpty)

	if err == nil {
		t.Error("Expected ShardRoutingError for empty primary")
	}
	if _, ok := err.(ShardRoutingError); !ok {
		t.Errorf("Expected ShardRoutingError, got %T", err)
	}
}

// TestShardRouterHandleNotShardLeader tests leader error handling
func TestShardRouterHandleNotShardLeader(t *testing.T) {
	cache := NewTopologyCache()
	cache.Update(&TopologyResponse{Version: 1, NumShards: 2})

	refreshCalled := false
	router := NewShardRouter(cache, func() error {
		refreshCalled = true
		return nil
	})

	// Test with NotShardLeaderError
	err := NotShardLeaderError{ShardID: 1, LeaderHint: "node2:3001"}
	if !router.HandleNotShardLeader(err) {
		t.Error("Should return true for NotShardLeaderError")
	}
	if !refreshCalled {
		t.Error("Refresh callback should be called")
	}

	// Test with other error
	refreshCalled = false
	if router.HandleNotShardLeader(ShardRoutingError{}) {
		t.Error("Should return false for non-NotShardLeaderError")
	}
	if refreshCalled {
		t.Error("Refresh callback should not be called for other errors")
	}
}

// TestShardRouterGetAllPrimaries tests getting all primaries
func TestShardRouterGetAllPrimaries(t *testing.T) {
	cache := NewTopologyCache()
	cache.Update(&TopologyResponse{
		Version:   1,
		NumShards: 3,
		Shards: []ShardInfo{
			{ID: 0, Primary: "node0:3001"},
			{ID: 1, Primary: "node1:3001"},
			{ID: 2, Primary: "node2:3001"},
		},
	})

	router := NewShardRouter(cache, nil)
	primaries := router.GetAllPrimaries()

	if len(primaries) != 3 {
		t.Errorf("Primaries count = %d, want 3", len(primaries))
	}
}

// TestNotShardLeaderErrorMessage tests error message formatting
func TestNotShardLeaderErrorMessage(t *testing.T) {
	// With hint
	err := NotShardLeaderError{ShardID: 5, LeaderHint: "node5:3001"}
	if err.Error() == "" {
		t.Error("Error message should not be empty")
	}

	// Without hint
	err = NotShardLeaderError{ShardID: 5}
	if err.Error() == "" {
		t.Error("Error message should not be empty")
	}
}

// TestMergeResults tests result merging
func TestMergeResults(t *testing.T) {
	// Empty results
	result := MergeResults([]QueryResult{}, 100)
	if len(result.Events) != 0 {
		t.Error("Empty results should produce empty events")
	}

	// Single result
	entityID1, _ := HexStringToUint128("1")
	entityID2, _ := HexStringToUint128("2")
	events := []GeoEvent{
		{EntityID: entityID1, Timestamp: 1000},
		{EntityID: entityID2, Timestamp: 2000},
	}
	results := []QueryResult{{Events: events, HasMore: false}}
	merged := MergeResults(results, 0)

	if len(merged.Events) != 2 {
		t.Errorf("Events count = %d, want 2", len(merged.Events))
	}
	// Should be sorted by timestamp descending
	if merged.Events[0].Timestamp < merged.Events[1].Timestamp {
		t.Error("Events should be sorted by timestamp descending")
	}
}

// TestMergeResultsDeduplication tests entity deduplication
func TestMergeResultsDeduplication(t *testing.T) {
	// Same entity with different timestamps
	entityID, _ := HexStringToUint128("1")
	result1 := QueryResult{Events: []GeoEvent{{EntityID: entityID, Timestamp: 1000}}}
	result2 := QueryResult{Events: []GeoEvent{{EntityID: entityID, Timestamp: 2000}}}

	merged := MergeResults([]QueryResult{result1, result2}, 0)

	if len(merged.Events) != 1 {
		t.Errorf("Events count = %d, want 1 (deduplicated)", len(merged.Events))
	}
	if merged.Events[0].Timestamp != 2000 {
		t.Error("Should keep latest timestamp")
	}
}

// TestMergeResultsLimit tests result limiting
func TestMergeResultsLimit(t *testing.T) {
	var events []GeoEvent
	for i := 0; i < 10; i++ {
		entityID, _ := HexStringToUint128("A" + string(rune('0'+i)))
		events = append(events, GeoEvent{EntityID: entityID, Timestamp: uint64(i * 1000)})
	}
	results := []QueryResult{{Events: events}}

	merged := MergeResults(results, 5)

	if len(merged.Events) != 5 {
		t.Errorf("Events count = %d, want 5", len(merged.Events))
	}
	if !merged.HasMore {
		t.Error("HasMore should be true when limited")
	}
}

// TestMergeResultsShardTracking tests per-shard result tracking
func TestMergeResultsShardTracking(t *testing.T) {
	entityID1, _ := HexStringToUint128("1")
	entityID2, _ := HexStringToUint128("2")
	entityID3, _ := HexStringToUint128("3")
	results := []QueryResult{
		{Events: []GeoEvent{{EntityID: entityID1}}, HasMore: false},
		{Events: []GeoEvent{{EntityID: entityID2}, {EntityID: entityID3}}, HasMore: true},
	}

	merged := MergeResults(results, 0)

	if merged.ShardResults[0] != 1 {
		t.Errorf("ShardResults[0] = %d, want 1", merged.ShardResults[0])
	}
	if merged.ShardResults[1] != 2 {
		t.Errorf("ShardResults[1] = %d, want 2", merged.ShardResults[1])
	}
	if !merged.HasMore {
		t.Error("HasMore should be true when any shard has more")
	}
}

// TestScatterGatherConfigDefaults tests default configuration
func TestScatterGatherConfigDefaults(t *testing.T) {
	config := DefaultScatterGatherConfig()

	if config.MaxConcurrency != 0 {
		t.Errorf("MaxConcurrency = %d, want 0 (unlimited)", config.MaxConcurrency)
	}
	if !config.AllowPartialResults {
		t.Error("AllowPartialResults should be true")
	}
	if config.Timeout != 30*time.Second {
		t.Errorf("Timeout = %v, want 30s", config.Timeout)
	}
}

// TestMaxShardsConstant tests MAX_SHARDS constant
func TestMaxShardsConstant(t *testing.T) {
	if MaxShards != 256 {
		t.Errorf("MaxShards = %d, want 256", MaxShards)
	}
}

// TestMaxReplicasPerShardConstant tests MAX_REPLICAS_PER_SHARD constant
func TestMaxReplicasPerShardConstant(t *testing.T) {
	if MaxReplicasPerShard != 6 {
		t.Errorf("MaxReplicasPerShard = %d, want 6", MaxReplicasPerShard)
	}
}

// ============================================================================
// Integration Test Notes for Sharded Cluster (task 5.10)
// ============================================================================
//
// The following integration tests require a running sharded cluster:
//
// 1. TestShardedCluster_TopologyDiscovery
//    - Connect to sharded cluster
//    - Verify get_topology operation returns correct shard info
//    - Verify all shard primaries are reachable
//
// 2. TestShardedCluster_ShardRouting
//    - Insert entities with known IDs
//    - Verify entities are routed to correct shard via hash(entity_id) % shard_count
//    - Query entity by ID and verify it's retrieved from correct shard
//
// 3. TestShardedCluster_ScatterGatherQuery
//    - Insert entities across all shards
//    - Execute spatial query that spans all shards
//    - Verify results are merged correctly
//    - Verify per-shard result tracking
//
// 4. TestShardedCluster_LeaderFailover
//    - Connect to sharded cluster
//    - Kill shard leader
//    - Verify NOT_SHARD_LEADER (220) error triggers topology refresh
//    - Verify operations succeed after failover
//
// 5. TestShardedCluster_ReshardingInProgress
//    - Initiate resharding
//    - Verify RESHARDING_IN_PROGRESS (222) error is returned
//    - Verify operations succeed after resharding completes
//
// To run integration tests:
//   ARCHERDB_SHARDED_CLUSTER=127.0.0.1:3000 go test -tags=integration -v
//
