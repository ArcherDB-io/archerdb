// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package types

import (
	"encoding/binary"
	"math"
)

// ============================================================================
// Sharding Strategy (per add-jump-consistent-hash spec)
// Algorithm for distributing entities across shards
// ============================================================================

// ShardingStrategy defines how entities are distributed across shards.
// Different strategies offer different trade-offs:
// - Modulo: Simple, requires power-of-2 shard counts, moves most data on resize
// - VirtualRing: Consistent hashing with O(log N) lookup and memory cost
// - JumpHash: Google's algorithm - O(1) memory, O(log N) compute, optimal movement
type ShardingStrategy uint8

const (
	// ShardingStrategyModulo uses simple hash % shards. Requires power-of-2 counts.
	ShardingStrategyModulo ShardingStrategy = 0
	// ShardingStrategyVirtualRing uses consistent hashing with virtual nodes.
	ShardingStrategyVirtualRing ShardingStrategy = 1
	// ShardingStrategyJumpHash uses Google's Jump Consistent Hash (default).
	ShardingStrategyJumpHash ShardingStrategy = 2
)

// String returns the string representation of the strategy.
func (s ShardingStrategy) String() string {
	switch s {
	case ShardingStrategyModulo:
		return "modulo"
	case ShardingStrategyVirtualRing:
		return "virtual_ring"
	case ShardingStrategyJumpHash:
		return "jump_hash"
	default:
		return "unknown"
	}
}

// RequiresPowerOfTwo returns true if this strategy requires power-of-2 shard counts.
func (s ShardingStrategy) RequiresPowerOfTwo() bool {
	return s == ShardingStrategyModulo
}

// ParseShardingStrategy parses a string into a ShardingStrategy.
func ParseShardingStrategy(str string) (ShardingStrategy, bool) {
	switch str {
	case "modulo":
		return ShardingStrategyModulo, true
	case "virtual_ring":
		return ShardingStrategyVirtualRing, true
	case "jump_hash":
		return ShardingStrategyJumpHash, true
	default:
		return 0, false
	}
}

// ============================================================================
// Geo-Sharding Types (v2.2)
// Geographic partitioning for data locality
// ============================================================================

// GeoShardPolicy defines how entities are assigned to geographic regions.
type GeoShardPolicy uint8

const (
	// GeoShardPolicyNone disables geo-sharding - all entities in single region.
	GeoShardPolicyNone GeoShardPolicy = 0
	// GeoShardPolicyByEntityLocation routes based on entity's lat/lon coordinates.
	GeoShardPolicyByEntityLocation GeoShardPolicy = 1
	// GeoShardPolicyByEntityIdPrefix routes based on entity_id prefix mapping.
	GeoShardPolicyByEntityIdPrefix GeoShardPolicy = 2
	// GeoShardPolicyExplicit allows application to specify target region per entity.
	GeoShardPolicyExplicit GeoShardPolicy = 3
)

// String returns the string representation of the policy.
func (p GeoShardPolicy) String() string {
	switch p {
	case GeoShardPolicyNone:
		return "none"
	case GeoShardPolicyByEntityLocation:
		return "by_entity_location"
	case GeoShardPolicyByEntityIdPrefix:
		return "by_entity_id_prefix"
	case GeoShardPolicyExplicit:
		return "explicit"
	default:
		return "unknown"
	}
}

// GeoRegion represents a geographic region in the geo-sharding topology.
type GeoRegion struct {
	// RegionID is the unique identifier (max 16 characters).
	RegionID string
	// Name is the human-readable name.
	Name string
	// Endpoint is the region's endpoint address.
	Endpoint string
	// CenterLatNano is the center latitude in nanodegrees.
	CenterLatNano int64
	// CenterLonNano is the center longitude in nanodegrees.
	CenterLonNano int64
	// Priority for routing (lower = higher priority for ties).
	Priority uint8
	// IsActive indicates if the region is currently accepting requests.
	IsActive bool
}

// CenterLatitude returns the center latitude in degrees.
func (r *GeoRegion) CenterLatitude() float64 {
	return float64(r.CenterLatNano) / 1e9
}

// CenterLongitude returns the center longitude in degrees.
func (r *GeoRegion) CenterLongitude() float64 {
	return float64(r.CenterLonNano) / 1e9
}

// SetCenter sets the center coordinates from degrees.
func (r *GeoRegion) SetCenter(latitude, longitude float64) {
	r.CenterLatNano = int64(latitude * 1e9)
	r.CenterLonNano = int64(longitude * 1e9)
}

// GeoShardConfig holds configuration for geo-sharding behavior.
type GeoShardConfig struct {
	// Policy is the geo-sharding policy to use.
	Policy GeoShardPolicy
	// Regions is the list of available regions.
	Regions []GeoRegion
	// DefaultRegionID is used when routing cannot determine target.
	DefaultRegionID string
	// AllowCrossRegionQueries enables cross-region query aggregation.
	AllowCrossRegionQueries bool
}

// NewGeoShardConfig creates a config with sensible defaults.
func NewGeoShardConfig() *GeoShardConfig {
	return &GeoShardConfig{
		Policy:                  GeoShardPolicyNone,
		Regions:                 make([]GeoRegion, 0),
		AllowCrossRegionQueries: true,
	}
}

// EntityRegionMetadata tracks which region owns an entity.
type EntityRegionMetadata struct {
	// EntityID is the entity identifier.
	EntityID Uint128
	// RegionID is the owning region.
	RegionID string
	// AssignedTimestamp is when the entity was assigned (nanoseconds).
	AssignedTimestamp uint64
	// IsExplicit indicates if assignment was explicit or computed.
	IsExplicit bool
}

// CrossRegionQueryResult holds results from a cross-region query.
type CrossRegionQueryResult struct {
	// Events contains aggregated events from all regions.
	Events []GeoEvent
	// RegionResults contains per-region result counts.
	RegionResults map[string]int
	// RegionErrors contains regions that failed during the query.
	RegionErrors map[string]error
	// HasMore indicates if more results are available.
	HasMore bool
	// TotalLatencyMs is the total query latency in milliseconds.
	TotalLatencyMs float64
}

// ============================================================================
// Geo-Sharding Router
// ============================================================================

// GeoShardRouter routes requests to appropriate regions.
type GeoShardRouter struct {
	config *GeoShardConfig
}

// NewGeoShardRouter creates a new router with the given config.
func NewGeoShardRouter(config *GeoShardConfig) *GeoShardRouter {
	return &GeoShardRouter{config: config}
}

// RouteByLocation returns the nearest region for given coordinates.
func (r *GeoShardRouter) RouteByLocation(latNano, lonNano int64) *GeoRegion {
	if r.config.Policy != GeoShardPolicyByEntityLocation || len(r.config.Regions) == 0 {
		return nil
	}

	var nearest *GeoRegion
	minDist := math.MaxFloat64

	for i := range r.config.Regions {
		region := &r.config.Regions[i]
		if !region.IsActive {
			continue
		}

		dist := haversineDistance(latNano, lonNano, region.CenterLatNano, region.CenterLonNano)
		if dist < minDist || (dist == minDist && nearest != nil && region.Priority < nearest.Priority) {
			minDist = dist
			nearest = region
		}
	}

	return nearest
}

// GetDefaultRegion returns the default region from config.
func (r *GeoShardRouter) GetDefaultRegion() *GeoRegion {
	for i := range r.config.Regions {
		if r.config.Regions[i].RegionID == r.config.DefaultRegionID {
			return &r.config.Regions[i]
		}
	}
	if len(r.config.Regions) > 0 {
		return &r.config.Regions[0]
	}
	return nil
}

// GetActiveRegions returns all active regions.
func (r *GeoShardRouter) GetActiveRegions() []*GeoRegion {
	var active []*GeoRegion
	for i := range r.config.Regions {
		if r.config.Regions[i].IsActive {
			active = append(active, &r.config.Regions[i])
		}
	}
	return active
}

// haversineDistance calculates the great-circle distance between two points.
func haversineDistance(lat1Nano, lon1Nano, lat2Nano, lon2Nano int64) float64 {
	const earthRadiusKm = 6371.0

	lat1 := float64(lat1Nano) / 1e9 * math.Pi / 180.0
	lon1 := float64(lon1Nano) / 1e9 * math.Pi / 180.0
	lat2 := float64(lat2Nano) / 1e9 * math.Pi / 180.0
	lon2 := float64(lon2Nano) / 1e9 * math.Pi / 180.0

	dLat := lat2 - lat1
	dLon := lon2 - lon1

	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1)*math.Cos(lat2)*math.Sin(dLon/2)*math.Sin(dLon/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))

	return earthRadiusKm * c
}

// ============================================================================
// Jump Consistent Hash (Google, 2014)
// Source of truth: src/sharding.zig - golden vectors MUST match exactly.
// Reference: https://research.google/pubs/pub44824/
// ============================================================================

// JumpHash implements Google's Jump Consistent Hash algorithm.
// O(1) memory, O(log n) compute, optimal 1/(n+1) key movement on resize.
//
// The algorithm uses a linear congruential generator (LCG) with specific
// constants to produce uniformly distributed bucket assignments.
//
// IMPORTANT: This implementation MUST produce identical results to
// src/sharding.zig jumpHash() for cross-SDK compatibility.
func JumpHash(key uint64, numBuckets uint32) uint32 {
	if numBuckets == 0 {
		return 0
	}

	var b int64 = -1
	var j int64 = 0

	for j < int64(numBuckets) {
		b = j
		// Linear congruential generator step
		key = key*2862933555777941757 + 1
		// Compute next jump
		j = int64(float64(b+1) * (float64(int64(1)<<31) / float64((key>>33)+1)))
	}

	return uint32(b)
}

// ComputeShardKey computes a 64-bit shard key from a 128-bit entity_id.
// Uses murmur3-inspired finalization for high-quality mixing.
//
// IMPORTANT: This implementation MUST produce identical results to
// src/sharding.zig computeShardKey() for cross-SDK compatibility.
func ComputeShardKey(entityID Uint128) uint64 {
	const c1 uint64 = 0xff51afd7ed558ccd
	const c2 uint64 = 0xc4ceb9fe1a85ec53

	// Extract low and high 64-bit values from Uint128 bytes (little-endian)
	bytes := entityID.Bytes()
	h1 := binary.LittleEndian.Uint64(bytes[0:8])  // Low 64 bits
	h2 := binary.LittleEndian.Uint64(bytes[8:16]) // High 64 bits

	// Finalization mix for h1
	h1 ^= h1 >> 33
	h1 *= c1
	h1 ^= h1 >> 33
	h1 *= c2
	h1 ^= h1 >> 33

	// Finalization mix for h2
	h2 ^= h2 >> 33
	h2 *= c1
	h2 ^= h2 >> 33
	h2 *= c2
	h2 ^= h2 >> 33

	return h1 ^ h2
}

// GetShardForEntity computes which shard an entity belongs to.
// Uses JumpHash with a computed shard key from the entity ID.
func GetShardForEntity(entityID Uint128, numShards uint32) uint32 {
	shardKey := ComputeShardKey(entityID)
	return JumpHash(shardKey, numShards)
}
