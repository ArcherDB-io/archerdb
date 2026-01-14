package types

import (
	"sync"
	"time"
)

// ============================================================================
// Topology Types (F5.1 Smart Client Topology Discovery)
// ============================================================================

// MaxShards is the maximum number of shards supported.
const MaxShards = 256

// MaxReplicasPerShard is the maximum number of replicas per shard.
const MaxReplicasPerShard = 6

// ShardStatus indicates the current status of a shard.
type ShardStatus uint8

const (
	// ShardActive indicates the shard is active and accepting requests.
	ShardActive ShardStatus = 0
	// ShardSyncing indicates the shard is syncing data (read-only).
	ShardSyncing ShardStatus = 1
	// ShardUnavailable indicates the shard is unavailable.
	ShardUnavailable ShardStatus = 2
	// ShardMigrating indicates the shard is being migrated during resharding.
	ShardMigrating ShardStatus = 3
	// ShardDecommissioning indicates the shard is being decommissioned.
	ShardDecommissioning ShardStatus = 4
)

// String returns the string representation of the shard status.
func (s ShardStatus) String() string {
	switch s {
	case ShardActive:
		return "active"
	case ShardSyncing:
		return "syncing"
	case ShardUnavailable:
		return "unavailable"
	case ShardMigrating:
		return "migrating"
	case ShardDecommissioning:
		return "decommissioning"
	default:
		return "unknown"
	}
}

// ShardInfo contains information about a single shard.
type ShardInfo struct {
	// ID is the shard identifier (0 to num_shards-1).
	ID uint32
	// Primary is the primary/leader node address.
	Primary string
	// Replicas are the replica node addresses.
	Replicas []string
	// Status is the current shard status.
	Status ShardStatus
	// EntityCount is the approximate number of entities in the shard.
	EntityCount uint64
	// SizeBytes is the approximate size of the shard in bytes.
	SizeBytes uint64
}

// TopologyResponse contains the cluster topology information.
type TopologyResponse struct {
	// Version is the topology version number (increments on changes).
	Version uint64
	// ClusterID is the cluster identifier.
	ClusterID Uint128
	// NumShards is the number of shards in the cluster.
	NumShards uint32
	// ReshardingStatus indicates resharding state (0=idle, 1=preparing, 2=migrating, 3=finalizing).
	ReshardingStatus uint8
	// Shards contains information about each shard.
	Shards []ShardInfo
	// LastChangeNs is the timestamp of the last topology change (nanoseconds since epoch).
	LastChangeNs int64
}

// TopologyChangeType indicates the type of topology change.
type TopologyChangeType uint8

const (
	// TopologyChangeLeader indicates a shard leader changed (failover).
	TopologyChangeLeader TopologyChangeType = 0
	// TopologyChangeReplicaAdded indicates a replica was added to a shard.
	TopologyChangeReplicaAdded TopologyChangeType = 1
	// TopologyChangeReplicaRemoved indicates a replica was removed from a shard.
	TopologyChangeReplicaRemoved TopologyChangeType = 2
	// TopologyChangeReshardingStarted indicates resharding has started.
	TopologyChangeReshardingStarted TopologyChangeType = 3
	// TopologyChangeReshardingCompleted indicates resharding has completed.
	TopologyChangeReshardingCompleted TopologyChangeType = 4
	// TopologyChangeStatusChange indicates a shard status changed.
	TopologyChangeStatusChange TopologyChangeType = 5
)

// TopologyChangeNotification represents a topology change event.
type TopologyChangeNotification struct {
	// NewVersion is the new topology version.
	NewVersion uint64
	// OldVersion is the previous topology version.
	OldVersion uint64
	// ChangeType is the type of change.
	ChangeType TopologyChangeType
	// AffectedShard is the shard affected by the change.
	AffectedShard uint32
	// TimestampNs is the timestamp of the change (nanoseconds since epoch).
	TimestampNs int64
}

// TopologyCache provides thread-safe caching of cluster topology.
type TopologyCache struct {
	mu           sync.RWMutex
	topology     *TopologyResponse
	lastRefresh  time.Time
	refreshCount uint64
	version      uint64
	onChange     []func(TopologyChangeNotification)
}

// NewTopologyCache creates a new topology cache.
func NewTopologyCache() *TopologyCache {
	return &TopologyCache{
		onChange: make([]func(TopologyChangeNotification), 0),
	}
}

// Get returns the cached topology (may be nil if not yet fetched).
func (tc *TopologyCache) Get() *TopologyResponse {
	tc.mu.RLock()
	defer tc.mu.RUnlock()
	return tc.topology
}

// GetVersion returns the current cached topology version.
func (tc *TopologyCache) GetVersion() uint64 {
	tc.mu.RLock()
	defer tc.mu.RUnlock()
	return tc.version
}

// Update updates the cached topology and notifies subscribers if version changed.
func (tc *TopologyCache) Update(topology *TopologyResponse) {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	oldVersion := tc.version
	tc.topology = topology
	tc.version = topology.Version
	tc.lastRefresh = time.Now()
	tc.refreshCount++

	// Notify subscribers if version changed
	if topology.Version != oldVersion && oldVersion != 0 {
		notification := TopologyChangeNotification{
			NewVersion:  topology.Version,
			OldVersion:  oldVersion,
			TimestampNs: time.Now().UnixNano(),
		}
		for _, fn := range tc.onChange {
			if fn != nil { // Skip unregistered callbacks
				go fn(notification) // Non-blocking notification
			}
		}
	}
}

// Invalidate marks the cache as stale, forcing a refresh on next access.
func (tc *TopologyCache) Invalidate() {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	tc.version = 0
}

// LastRefresh returns the time of the last topology refresh.
func (tc *TopologyCache) LastRefresh() time.Time {
	tc.mu.RLock()
	defer tc.mu.RUnlock()
	return tc.lastRefresh
}

// RefreshCount returns the number of times the cache has been refreshed.
func (tc *TopologyCache) RefreshCount() uint64 {
	tc.mu.RLock()
	defer tc.mu.RUnlock()
	return tc.refreshCount
}

// OnChange registers a callback to be invoked when topology changes.
// Returns a function to unregister the callback.
func (tc *TopologyCache) OnChange(fn func(TopologyChangeNotification)) func() {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	tc.onChange = append(tc.onChange, fn)
	idx := len(tc.onChange) - 1
	return func() {
		tc.mu.Lock()
		defer tc.mu.Unlock()
		// Remove callback by setting to nil (preserves indices)
		if idx < len(tc.onChange) {
			tc.onChange[idx] = nil
		}
	}
}

// ComputeShard returns the shard ID for a given entity ID.
// Uses consistent hashing: shard = hash(entity_id) % num_shards
func (tc *TopologyCache) ComputeShard(entityID Uint128) uint32 {
	tc.mu.RLock()
	defer tc.mu.RUnlock()

	if tc.topology == nil || tc.topology.NumShards == 0 {
		return 0
	}

	// Use XOR folding of the 128-bit ID to get a 64-bit hash
	bytes := entityID.Bytes()
	lo := uint64(bytes[0]) | uint64(bytes[1])<<8 | uint64(bytes[2])<<16 | uint64(bytes[3])<<24 |
		uint64(bytes[4])<<32 | uint64(bytes[5])<<40 | uint64(bytes[6])<<48 | uint64(bytes[7])<<56
	hi := uint64(bytes[8]) | uint64(bytes[9])<<8 | uint64(bytes[10])<<16 | uint64(bytes[11])<<24 |
		uint64(bytes[12])<<32 | uint64(bytes[13])<<40 | uint64(bytes[14])<<48 | uint64(bytes[15])<<56
	hash := lo ^ hi

	return uint32(hash % uint64(tc.topology.NumShards))
}

// GetShardPrimary returns the primary address for a given shard.
func (tc *TopologyCache) GetShardPrimary(shardID uint32) string {
	tc.mu.RLock()
	defer tc.mu.RUnlock()

	if tc.topology == nil || int(shardID) >= len(tc.topology.Shards) {
		return ""
	}

	return tc.topology.Shards[shardID].Primary
}

// GetAllShardPrimaries returns all shard primary addresses.
func (tc *TopologyCache) GetAllShardPrimaries() []string {
	tc.mu.RLock()
	defer tc.mu.RUnlock()

	if tc.topology == nil {
		return nil
	}

	primaries := make([]string, len(tc.topology.Shards))
	for i, shard := range tc.topology.Shards {
		primaries[i] = shard.Primary
	}
	return primaries
}

// IsResharding returns true if the cluster is currently resharding.
func (tc *TopologyCache) IsResharding() bool {
	tc.mu.RLock()
	defer tc.mu.RUnlock()
	return tc.topology != nil && tc.topology.ReshardingStatus != 0
}

// GetActiveShards returns the list of active shard IDs.
func (tc *TopologyCache) GetActiveShards() []uint32 {
	tc.mu.RLock()
	defer tc.mu.RUnlock()

	if tc.topology == nil {
		return nil
	}

	active := make([]uint32, 0, len(tc.topology.Shards))
	for _, shard := range tc.topology.Shards {
		if shard.Status == ShardActive {
			active = append(active, shard.ID)
		}
	}
	return active
}

// GetShardCount returns the number of shards in the cluster.
func (tc *TopologyCache) GetShardCount() uint32 {
	tc.mu.RLock()
	defer tc.mu.RUnlock()

	if tc.topology == nil {
		return 0
	}
	return tc.topology.NumShards
}

// ============================================================================
// Shard Router (F5.1.4 Shard-Aware Routing)
// ============================================================================

// ShardRoutingError indicates a routing failure.
type ShardRoutingError struct {
	ShardID uint32
	Message string
}

func (e ShardRoutingError) Error() string {
	return e.Message
}

// NotShardLeaderError indicates the request was sent to a non-leader node.
type NotShardLeaderError struct {
	ShardID    uint32
	LeaderHint string
}

func (e NotShardLeaderError) Error() string {
	if e.LeaderHint != "" {
		return "not shard leader, hint: " + e.LeaderHint
	}
	return "not shard leader for shard " + string(rune(e.ShardID))
}

// ShardRouter provides shard-aware request routing.
type ShardRouter struct {
	cache           *TopologyCache
	refreshCallback func() error
}

// NewShardRouter creates a new shard router.
func NewShardRouter(cache *TopologyCache, refreshCallback func() error) *ShardRouter {
	return &ShardRouter{
		cache:           cache,
		refreshCallback: refreshCallback,
	}
}

// RouteByEntityID returns the shard ID and primary address for an entity.
func (r *ShardRouter) RouteByEntityID(entityID Uint128) (shardID uint32, primary string, err error) {
	shardID = r.cache.ComputeShard(entityID)
	primary = r.cache.GetShardPrimary(shardID)

	if primary == "" {
		return 0, "", ShardRoutingError{
			ShardID: shardID,
			Message: "no primary address for shard",
		}
	}

	return shardID, primary, nil
}

// HandleNotShardLeader handles a not_shard_leader error by refreshing topology.
// Returns true if topology was refreshed and retry should be attempted.
func (r *ShardRouter) HandleNotShardLeader(err error) bool {
	if _, ok := err.(NotShardLeaderError); ok {
		if r.refreshCallback != nil {
			if refreshErr := r.refreshCallback(); refreshErr == nil {
				return true // Retry after refresh
			}
		}
	}
	return false
}

// GetAllPrimaries returns addresses of all shard primaries for scatter-gather.
func (r *ShardRouter) GetAllPrimaries() []string {
	return r.cache.GetAllShardPrimaries()
}

// ============================================================================
// Scatter-Gather Query Support (F5.1.5)
// ============================================================================

// ScatterGatherResult holds results from a scatter-gather query.
type ScatterGatherResult struct {
	// Events contains merged results from all shards.
	Events []GeoEvent
	// ShardResults contains per-shard result counts.
	ShardResults map[uint32]int
	// PartialFailures contains shards that failed during query.
	PartialFailures map[uint32]error
	// HasMore indicates if more results are available.
	HasMore bool
}

// ScatterGatherConfig configures scatter-gather query behavior.
type ScatterGatherConfig struct {
	// MaxConcurrency limits parallel shard queries (0 = unlimited).
	MaxConcurrency int
	// AllowPartialResults returns partial results even if some shards fail.
	AllowPartialResults bool
	// Timeout per-shard query timeout.
	Timeout time.Duration
}

// DefaultScatterGatherConfig returns sensible defaults.
func DefaultScatterGatherConfig() ScatterGatherConfig {
	return ScatterGatherConfig{
		MaxConcurrency:      0, // Unlimited
		AllowPartialResults: true,
		Timeout:             30 * time.Second,
	}
}

// MergeResults merges results from multiple shards.
// Deduplicates by entity ID and applies the limit.
func MergeResults(results []QueryResult, limit int) ScatterGatherResult {
	// Use map to deduplicate by entity ID
	seen := make(map[Uint128]GeoEvent)
	shardResults := make(map[uint32]int)
	var hasMore bool

	for i, result := range results {
		shardResults[uint32(i)] = len(result.Events)
		if result.HasMore {
			hasMore = true
		}
		for _, event := range result.Events {
			// Keep the most recent event for each entity
			if existing, ok := seen[event.EntityID]; !ok || event.Timestamp > existing.Timestamp {
				seen[event.EntityID] = event
			}
		}
	}

	// Convert map to slice and sort by timestamp (most recent first)
	events := make([]GeoEvent, 0, len(seen))
	for _, event := range seen {
		events = append(events, event)
	}

	// Sort by timestamp descending
	for i := 0; i < len(events)-1; i++ {
		for j := i + 1; j < len(events); j++ {
			if events[j].Timestamp > events[i].Timestamp {
				events[i], events[j] = events[j], events[i]
			}
		}
	}

	// Apply limit
	if limit > 0 && len(events) > limit {
		events = events[:limit]
		hasMore = true
	}

	return ScatterGatherResult{
		Events:       events,
		ShardResults: shardResults,
		HasMore:      hasMore,
	}
}
