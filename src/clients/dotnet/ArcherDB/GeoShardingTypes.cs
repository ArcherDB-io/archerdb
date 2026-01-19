// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

/////////////////////////////////////////////////////////////
// Sharding Strategy (per add-jump-consistent-hash spec)   //
// Algorithm for distributing entities across shards       //
/////////////////////////////////////////////////////////////

using System;
using System.Collections.Generic;

namespace ArcherDB;

/// <summary>
/// Strategy for distributing entities across shards.
/// <para>
/// Different strategies offer different trade-offs:
/// <list type="bullet">
///   <item><see cref="Modulo"/> - Simple, requires power-of-2 shard counts, moves most data on resize</item>
///   <item><see cref="VirtualRing"/> - Consistent hashing with O(log N) lookup and memory cost</item>
///   <item><see cref="JumpHash"/> - Google's algorithm - O(1) memory, O(log N) compute, optimal movement</item>
/// </list>
/// </para>
/// </summary>
public enum ShardingStrategy : byte
{
    /// <summary>
    /// Simple modulo-based sharding: hash % num_shards.
    /// Requires power-of-2 shard counts for efficient computation.
    /// Moves ~(N-1)/N entities when adding one shard.
    /// </summary>
    Modulo = 0,

    /// <summary>
    /// Virtual node ring-based consistent hashing.
    /// Uses 150 virtual nodes per shard by default.
    /// Moves ~1/N entities when adding one shard.
    /// Has O(log N) lookup overhead and memory cost.
    /// </summary>
    VirtualRing = 1,

    /// <summary>
    /// Jump Consistent Hash (Google, 2014).
    /// O(1) memory, O(log N) compute, optimal 1/(N+1) movement.
    /// Default strategy - best balance of performance and movement.
    /// </summary>
    JumpHash = 2,
}

/// <summary>
/// Extension methods for <see cref="ShardingStrategy"/>.
/// </summary>
public static class ShardingStrategyExtensions
{
    /// <summary>
    /// Check if this strategy requires power-of-2 shard counts.
    /// </summary>
    public static bool RequiresPowerOfTwo(this ShardingStrategy strategy)
    {
        return strategy == ShardingStrategy.Modulo;
    }

    /// <summary>
    /// Convert to string representation.
    /// </summary>
    public static string ToStrategyString(this ShardingStrategy strategy)
    {
        return strategy switch
        {
            ShardingStrategy.Modulo => "modulo",
            ShardingStrategy.VirtualRing => "virtual_ring",
            ShardingStrategy.JumpHash => "jump_hash",
            _ => "unknown",
        };
    }

    /// <summary>
    /// Parse from string representation.
    /// </summary>
    public static ShardingStrategy? ParseShardingStrategy(string str)
    {
        return str?.ToLowerInvariant() switch
        {
            "modulo" => ShardingStrategy.Modulo,
            "virtual_ring" => ShardingStrategy.VirtualRing,
            "jump_hash" => ShardingStrategy.JumpHash,
            _ => null,
        };
    }
}

/////////////////////////////////////////////////////////////
// Geo-Sharding Types (v2.2)                               //
// Geographic partitioning for data locality               //
/////////////////////////////////////////////////////////////

/// <summary>
/// Policy for assigning entities to geographic regions.
/// https://docs.archerdb.io/reference/geo-sharding#policy
/// </summary>
public enum GeoShardPolicy : byte
{
    /// <summary>
    /// No geo-sharding - all entities in single region.
    /// </summary>
    None = 0,

    /// <summary>
    /// Route based on entity's lat/lon coordinates to nearest region.
    /// </summary>
    ByEntityLocation = 1,

    /// <summary>
    /// Route based on entity_id prefix mapping to regions.
    /// </summary>
    ByEntityIdPrefix = 2,

    /// <summary>
    /// Application explicitly specifies target region per entity.
    /// </summary>
    Explicit = 3,
}

/// <summary>
/// A geographic region in the geo-sharding topology.
/// https://docs.archerdb.io/reference/geo-sharding#region
/// </summary>
public class GeoRegion
{
    /// <summary>
    /// Unique identifier for this region (max 16 characters).
    /// </summary>
    public string RegionId { get; set; } = "";

    /// <summary>
    /// Human-readable name for the region.
    /// </summary>
    public string Name { get; set; } = "";

    /// <summary>
    /// Endpoint address for this region.
    /// </summary>
    public string Endpoint { get; set; } = "";

    /// <summary>
    /// Center latitude in nanodegrees for by_entity_location routing.
    /// </summary>
    public long CenterLatNano { get; set; }

    /// <summary>
    /// Center longitude in nanodegrees for by_entity_location routing.
    /// </summary>
    public long CenterLonNano { get; set; }

    /// <summary>
    /// Priority for routing (lower = higher priority for ties).
    /// </summary>
    public byte Priority { get; set; }

    /// <summary>
    /// Whether this region is currently active.
    /// </summary>
    public bool IsActive { get; set; } = true;

    /// <summary>
    /// Gets the center latitude in degrees.
    /// </summary>
    public double CenterLatitude => CenterLatNano / 1_000_000_000.0;

    /// <summary>
    /// Gets the center longitude in degrees.
    /// </summary>
    public double CenterLongitude => CenterLonNano / 1_000_000_000.0;

    /// <summary>
    /// Sets the center coordinates from degrees.
    /// </summary>
    public void SetCenter(double latitude, double longitude)
    {
        CenterLatNano = (long)(latitude * 1_000_000_000);
        CenterLonNano = (long)(longitude * 1_000_000_000);
    }
}

/// <summary>
/// Configuration for geo-sharding behavior.
/// https://docs.archerdb.io/reference/geo-sharding#config
/// </summary>
public class GeoShardConfig
{
    /// <summary>
    /// The geo-sharding policy to use.
    /// </summary>
    public GeoShardPolicy Policy { get; set; } = GeoShardPolicy.None;

    /// <summary>
    /// Available regions for routing.
    /// </summary>
    public List<GeoRegion> Regions { get; set; } = new();

    /// <summary>
    /// Default region ID when routing cannot determine target.
    /// </summary>
    public string DefaultRegionId { get; set; } = "";

    /// <summary>
    /// Whether to allow cross-region query aggregation.
    /// </summary>
    public bool AllowCrossRegionQueries { get; set; } = true;
}

/// <summary>
/// Metadata tracking which region owns an entity.
/// https://docs.archerdb.io/reference/geo-sharding#entity-metadata
/// </summary>
public class EntityRegionMetadata
{
    /// <summary>
    /// The entity ID.
    /// </summary>
    public UInt128 EntityId { get; set; }

    /// <summary>
    /// The region ID that owns this entity.
    /// </summary>
    public string RegionId { get; set; } = "";

    /// <summary>
    /// Timestamp when entity was assigned to this region (nanoseconds).
    /// </summary>
    public ulong AssignedTimestamp { get; set; }

    /// <summary>
    /// Whether this assignment was explicit or computed.
    /// </summary>
    public bool IsExplicit { get; set; }
}

/// <summary>
/// Result of a cross-region query aggregation.
/// https://docs.archerdb.io/reference/geo-sharding#cross-region-query
/// </summary>
public class CrossRegionQueryResult
{
    /// <summary>
    /// Aggregated events from all regions.
    /// </summary>
    public List<GeoEvent> Events { get; set; } = new();

    /// <summary>
    /// Per-region result counts.
    /// </summary>
    public Dictionary<string, int> RegionResults { get; set; } = new();

    /// <summary>
    /// Regions that failed during the query.
    /// </summary>
    public Dictionary<string, string> RegionErrors { get; set; } = new();

    /// <summary>
    /// Whether more results are available.
    /// </summary>
    public bool HasMore { get; set; }

    /// <summary>
    /// Total latency in milliseconds.
    /// </summary>
    public double TotalLatencyMs { get; set; }
}
