# Constants Review for ArcherDB (F0.4.1)

This document analyzes TigerBeetle's `src/constants.zig` and identifies values to
keep, modify, or add for ArcherDB's geospatial workload.

## Values to KEEP UNCHANGED

These constants are critical for VSR consensus, cluster safety, and storage format
compatibility with TigerBeetle's proven architecture.

### 1. Replica Configuration
| Constant | Value | Rationale |
|----------|-------|-----------|
| `replicas_max` | 6 | Max cluster size (proven) |
| `standbys_max` | 6 | Standby nodes for failover |
| `members_max` | 12 | Total members |
| `vsr_operations_reserved` | 128 | Protocol boundary |

### 2. VSR Protocol Constants
- `vsr_checkpoint_ops` - Derived from journal size (keep formula)
- `quorum_replication_max` - Flexible Paxos quorum
- `view_change_headers_suffix_max` - View change protocol
- `view_headers_max` - DVC/SV message sizing

### 3. Pipeline Constants
| Constant | Value | Rationale |
|----------|-------|-----------|
| `pipeline_prepare_queue_max` | 8 | In-flight prepares |
| `pipeline_request_queue_max` | derived | Request queuing |

### 4. Network/TCP Settings
All TCP settings should remain unchanged:
- `tcp_keepalive`, `tcp_keepidle`, `tcp_keepintvl`, `tcp_keepcnt`
- `tcp_nodelay`, `tcp_rcvbuf`
- `connection_delay_min_ms`, `connection_delay_max_ms`
- `tcp_backlog`

### 5. Storage Fundamentals
| Constant | Value | Rationale |
|----------|-------|-----------|
| `sector_size` | 4096 | Disk alignment |
| `direct_io` | true | Production setting |
| `superblock_copies` | 4 | Redundancy |

### 6. LSM Tree Configuration
Keep all LSM constants - they're tuned for TigerBeetle's workload and work well:
- `lsm_levels` = 7
- `lsm_growth_factor` = 8
- `lsm_compaction_ops` = 32
- `lsm_snapshots_max` = 32
- `lsm_manifest_*` settings
- `lsm_table_coalescing_threshold_percent`
- All compaction IOPS settings

### 7. Clock Synchronization
- `clock_offset_tolerance_max_ms`
- `clock_epoch_max_ms`
- `clock_synchronization_window_*_ms`

### 8. Grid and IOPS
- `grid_iops_read_max`, `grid_iops_write_max`
- `grid_repair_*` settings
- `grid_scrubber_*` settings
- `grid_cache_size_default`

## Values to MODIFY for ArcherDB

### 1. Message Size (Cluster-level - FORMAT BREAKING)

| Constant | TigerBeetle | ArcherDB | Rationale |
|----------|-------------|----------|-----------|
| `message_size_max` | 1 MiB | 10 MiB* | 10K events/batch @ 128 bytes |

**DECISION NEEDED**: The spec suggests 10 MiB, but this significantly impacts:
- WAL size: `journal_slot_count × message_size_max`
- Memory usage for message pools
- Network packet sizes

**Recommendation**: Start with 1 MiB (TigerBeetle default), can support ~7,800 events/batch.
Increase only if throughput testing shows it's needed.

### 2. Journal Slot Count (Cluster-level - FORMAT BREAKING)

| Constant | TigerBeetle | ArcherDB | Rationale |
|----------|-------------|----------|-----------|
| `journal_slot_count` | 1024 | 8192 | 8ms retention @ 1M ops/sec |

See `docs/journal_sizing.md` for detailed analysis.

### 3. Cache Configurations (Process-level)

ArcherDB keeps a single GeoEvent cache (`cache_geo_events_size_default`). Legacy TigerBeetle caches were removed.

## Values to ADD for ArcherDB

### 1. GeoEvent Constants (Cluster-level)
```zig
/// Size of GeoEvent struct (cache-aligned)
pub const geo_event_size = 128;

/// Maximum events per batch
/// (message_size_max - header - margin) / geo_event_size
pub const batch_events_max = 7_800; // Conservative for 1 MiB message

comptime {
    assert(@sizeOf(GeoEvent) == geo_event_size);
}
```

### 2. S2 Spatial Indexing Constants (Cluster-level)
```zig
/// S2 cell level for storage indexing (max precision)
pub const s2_cell_level = 30;

/// Maximum cells in RegionCoverer result for queries
pub const s2_max_cells = 16;

/// Minimum S2 cell level for query covering (coarse)
pub const s2_cover_min_level = 10;

/// Maximum S2 cell level for query covering
pub const s2_cover_max_level = 18;

/// Scratch buffer size for polygon covering (per query)
pub const s2_scratch_size = 1 * MiB;
```

### 3. Index Constants (Cluster-level)
```zig
/// Index entry size (cache-line aligned)
pub const index_entry_size = 64;

/// Index load factor target (70%)
pub const index_load_factor_percent = 70;

/// Number of logical shards for index partitioning
/// shard_id = hash(entity_id) % shard_count
pub const shard_count = 256;

comptime {
    // Shard count must be power of 2 for efficient modulo
    assert(shard_count > 0 and (shard_count & (shard_count - 1)) == 0);
}
```

### 4. Query Limits (Cluster-level)
```zig
/// Maximum events in query result
pub const query_result_max = 81_000;

/// Maximum polygon vertices
pub const polygon_vertices_max = 10_000;

/// Maximum radius in meters
pub const radius_max_meters = 1_000_000;

/// Maximum concurrent spatial queries
pub const max_concurrent_queries = 100;

comptime {
    // Result must fit in message
    assert(query_result_max * geo_event_size < message_body_size_max);
}
```

### 5. TTL Constants (Process-level)
```zig
/// Interval between background TTL cleanup sweeps (ms)
pub const ttl_check_interval_ms = 60_000; // 1 minute

/// Maximum expired entries to clean per sweep
pub const ttl_batch_size = 10_000;
```

## Configuration Categories Summary

### Cluster-level (must match across replicas, format-breaking)
- `journal_slot_count`
- `message_size_max`
- `geo_event_size`
- `s2_cell_level`
- `index_entry_size`
- `shard_count`
- All query limits

### Process-level (can vary per replica)
- `cache_geo_events_size_default`
- `ttl_check_interval_ms`
- `ttl_batch_size`
- Storage size limits
- Network timeouts

## Implementation Plan

1. **F0.4.2**: Add S2 spatial constants
2. **F0.4.3**: Add index constants
3. **F0.4.4**: Add TTL constants
4. **F0.4.5**: Verify comptime assertions pass

Note: Full journal_slot_count change to 8192 may be deferred until F1 state machine
integration, when we can properly test throughput. For F0, keeping TigerBeetle
defaults ensures all existing tests pass.
