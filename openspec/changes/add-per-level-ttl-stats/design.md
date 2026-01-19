# Design: Per-Level TTL Statistics

## Context

The `add-ttl-aware-compaction` proposal adds expired ratio tracking (0.0-1.0) per LSM level via sampling during compaction. This is useful for compaction prioritization but doesn't provide absolute byte counts needed for capacity planning.

This proposal extends the same sampling mechanism to track **absolute byte counts** alongside ratios.

## Goals / Non-Goals

### Goals

1. **Absolute byte visibility**: Expose total and expired bytes per LSM level
2. **Zero additional I/O**: Reuse existing compaction sampling (no extra scans)
3. **Capacity planning support**: Enable alerts like "expired_bytes > 100GB"
4. **Consistent estimation**: Byte estimates match ratio estimates in accuracy

### Non-Goals

1. **Precise real-time counts**: Sampling-based estimation is sufficient
2. **Per-table granularity**: Level-based is enough for capacity planning
3. **Historical storage**: Prometheus handles time series; we expose point-in-time values

## Decisions

### Decision 1: Track Bytes Alongside Ratios During Sampling

**Choice**: Extend existing compaction sampling to track byte counts.

**Rationale**:
- **Zero additional overhead**: Already iterating values during compaction
- **Consistent accuracy**: Same sampling gives consistent ratio and byte estimates
- **Simple implementation**: Add two counters to existing sampling logic

**Implementation**:
```zig
// Extend BarStatistics (from add-ttl-aware-compaction):
pub const BarStatistics = struct {
    values_total: u64,
    values_expired: u64,
    // NEW: Byte tracking
    bytes_total: u64,       // Total bytes processed in this bar
    bytes_expired: u64,     // Bytes of expired values
};

// During compaction value iteration:
bar.stats.values_total += 1;
bar.stats.bytes_total += value.byte_size();  // NEW
if (value_expired) {
    bar.stats.values_expired += 1;
    bar.stats.bytes_expired += value.byte_size();  // NEW
}
```

### Decision 2: Track Level Totals for Denominator

**Choice**: Track total bytes per level (not just expired bytes).

**Rationale**:
- **Enables ratio verification**: `expired_bytes / total_bytes ≈ expired_ratio`
- **Useful standalone metric**: Total bytes per level is valuable for capacity planning
- **Low cost**: Only one additional u64 per level

**Implementation**:
```zig
// In ManifestLevel (extend existing expired_ratio tracking):
pub const ManifestLevel = struct {
    // Existing from add-ttl-aware-compaction:
    expired_ratio: f64 = 0.0,
    expired_ratio_sampled_at_op: u64 = 0,

    // NEW: Byte estimates
    estimated_total_bytes: u64 = 0,
    estimated_expired_bytes: u64 = 0,
};
```

### Decision 3: Use EMA for Byte Estimates (Same as Ratio)

**Choice**: Apply exponential moving average to byte estimates.

**Rationale**:
- **Consistency**: Same smoothing as ratio estimates
- **Stability**: Prevents metric jitter from individual bar variations
- **Simplicity**: Same update formula, just for bytes instead of ratios

**Update Formula**:
```zig
// After bar completes (same alpha as ratio):
const alpha: f64 = 0.2;
if (bar.stats.values_total > 0) {
    // Ratio update (existing):
    const sample_ratio = @as(f64, bar.stats.values_expired) / @as(f64, bar.stats.values_total);
    level.expired_ratio = alpha * sample_ratio + (1.0 - alpha) * level.expired_ratio;

    // Byte estimate update (NEW):
    // Scale sample to estimated level size using level table count
    const level_table_count = level.table_count();
    const bar_scale_factor = @as(f64, level_table_count);  // Approximate scaling

    // Update total bytes estimate
    const sample_total = @as(f64, bar.stats.bytes_total) * bar_scale_factor;
    level.estimated_total_bytes = @intFromFloat(
        alpha * sample_total + (1.0 - alpha) * @as(f64, level.estimated_total_bytes)
    );

    // Update expired bytes estimate
    const sample_expired = @as(f64, bar.stats.bytes_expired) * bar_scale_factor;
    level.estimated_expired_bytes = @intFromFloat(
        alpha * sample_expired + (1.0 - alpha) * @as(f64, level.estimated_expired_bytes)
    );
}
```

**Alternative Considered**:
- *Precise tracking via manifest*: Rejected - would require scanning all tables
- *Reset on each sample*: Rejected - causes metric instability

### Decision 4: Expose Two New Prometheus Metrics

**Choice**: Add `archerdb_lsm_bytes_by_level` and `archerdb_ttl_expired_bytes_by_level`.

**Rationale**:
- **Absolute values**: Enable threshold-based alerts
- **Ratio derivable**: `expired_bytes / total_bytes` should approximate `expired_ratio`
- **Standard naming**: Follows existing metric naming conventions

**Metric Definitions**:
```prometheus
# HELP archerdb_lsm_bytes_by_level Estimated total bytes per LSM level
# TYPE archerdb_lsm_bytes_by_level gauge
archerdb_lsm_bytes_by_level{level="1"} 1073741824
archerdb_lsm_bytes_by_level{level="2"} 8589934592
...

# HELP archerdb_ttl_expired_bytes_by_level Estimated expired bytes per LSM level
# TYPE archerdb_ttl_expired_bytes_by_level gauge
archerdb_ttl_expired_bytes_by_level{level="1"} 53687091
archerdb_ttl_expired_bytes_by_level{level="5"} 4294967296
...
```

## Architecture

### Component Changes

#### 1. Compaction Statistics (src/lsm/compaction.zig)

Add byte counters to BarStatistics:
```zig
pub const BarStatistics = struct {
    values_total: u64,
    values_expired: u64,        // From add-ttl-aware-compaction
    bytes_total: u64,           // NEW
    bytes_expired: u64,         // NEW
    values_dropped_tombstone: u64,
    values_output: u64,
};
```

#### 2. Level Byte Tracking (src/lsm/manifest_level.zig)

Add byte estimate fields:
```zig
// In ManifestLevel struct:
expired_ratio: f64 = 0.0,              // From add-ttl-aware-compaction
expired_ratio_sampled_at_op: u64 = 0,  // From add-ttl-aware-compaction
estimated_total_bytes: u64 = 0,        // NEW
estimated_expired_bytes: u64 = 0,      // NEW
```

#### 3. Metrics Exposure (src/archerdb/metrics.zig)

Add new metric definitions:
```zig
pub const archerdb_lsm_bytes_by_level = struct {
    pub const help = "Estimated total bytes per LSM level";
    pub const type_name = "gauge";
    pub const labels = &[_][]const u8{"level"};
};

pub const archerdb_ttl_expired_bytes_by_level = struct {
    pub const help = "Estimated expired bytes per LSM level";
    pub const type_name = "gauge";
    pub const labels = &[_][]const u8{"level"};
};
```

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Compaction Bar (Same as add-ttl-aware-compaction)            │
│    └─> Process values from level A → level B                    │
│        └─> For each value:                                      │
│            └─> Increment values_total, bytes_total              │
│            └─> If expired: increment values_expired, bytes_exp  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Bar Complete - Update Level Statistics                        │
│    └─> Update expired_ratio (existing)                          │
│    └─> Update estimated_total_bytes (NEW)                       │
│    └─> Update estimated_expired_bytes (NEW)                     │
│    └─> Scale by level table count for extrapolation             │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Metrics Exposition (/metrics endpoint)                        │
│    └─> archerdb_ttl_expired_ratio_by_level (existing)           │
│    └─> archerdb_lsm_bytes_by_level (NEW)                        │
│    └─> archerdb_ttl_expired_bytes_by_level (NEW)                │
└─────────────────────────────────────────────────────────────────┘
```

## Trade-Offs

### Chosen Approach: EMA-Smoothed Byte Estimation

**Pros**:
- Zero additional I/O (uses existing sampling)
- Consistent with ratio estimation accuracy
- Simple implementation
- Stable metrics (EMA smoothing)

**Cons**:
- Estimates, not precise counts
- Accuracy depends on compaction frequency
- May lag during rapid TTL expiration

### Alternative: Manifest-Based Precise Tracking

**Why Rejected**:
- Would require per-table byte tracking in manifest
- Significant manifest bloat
- Still wouldn't give precise expired bytes without scanning

## Validation Plan

### Unit Tests

1. **Byte counter accumulation**: Verify bytes_total and bytes_expired increment correctly
2. **EMA convergence**: Verify byte estimates converge to reasonable values
3. **Metric consistency**: `expired_bytes / total_bytes ≈ expired_ratio` (within 10%)

### Integration Tests

1. **TTL workload**: Insert 1M entities with TTL, verify byte metrics track accumulation
2. **Mixed workload**: Verify non-TTL data doesn't affect expired_bytes
3. **Metric accuracy**: Compare estimated bytes to actual disk usage (within 20%)

## Implementation Phases

### Phase 1: Extend Sampling (0.5 day)

- Add bytes_total and bytes_expired to BarStatistics
- Increment counters during value iteration

### Phase 2: Level Statistics (0.5 day)

- Add estimated_total_bytes and estimated_expired_bytes to ManifestLevel
- Implement EMA update after bar completes

### Phase 3: Metrics Exposure (0.5 day)

- Add metric definitions
- Export metrics on /metrics endpoint
- Unit tests for metric correctness

### Phase 4: Testing (0.5 day)

- Integration tests with TTL workloads
- Verify metric accuracy against actual disk usage
