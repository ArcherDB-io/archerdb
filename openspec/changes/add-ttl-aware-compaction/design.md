# Design: TTL-Aware Compaction Prioritization

## Context

ArcherDB's LSM storage engine uses leveled compaction to merge and garbage-collect data. TTL expiration is handled during compaction - when tables are merged, expired values are discarded. However, the current compaction scheduler is **TTL-unaware**: it schedules compaction based on table overlap and round-robin level rotation, not on expired data accumulation.

For workloads with high TTL usage (e.g., 30-day retention for location events), this means:
- Expired data may sit uncompacted for extended periods
- Space reclamation depends on normal compaction schedule, not TTL patterns
- No automated mechanism to prioritize compacting "expired-heavy" levels

## Goals / Non-Goals

### Goals

1. **Faster space reclamation**: Prioritize compacting levels with high expired data ratios
2. **Zero overhead tracking**: Sample expired ratio during normal compaction (no extra scans)
3. **Predictable behavior**: Gentle nudge within existing compaction rhythm, not aggressive preemption
4. **Operator visibility**: Expose expired ratio metrics per level for monitoring

### Non-Goals

1. **Aggressive preemption**: Don't disrupt normal compaction for TTL (maintain predictability)
2. **Per-table granularity**: Level-based is sufficient (simpler, less metadata)
3. **Background scanning**: No extra I/O for TTL detection (sampling-based is enough)
4. **Automatic cliff mitigation**: Defer to separate feature (v2.3+)

## Decisions

### Decision 1: Sample Expired Ratio During Normal Compaction

**Choice**: Track expired data ratio per level by sampling during normal compaction runs.

**Rationale**:
- **Zero overhead**: No extra I/O or CPU - piggyback on existing compaction work
- **Eventually accurate**: All tables eventually get compacted, so sampling converges to reality
- **Simple implementation**: Count expired values during existing TTL filtering logic
- **No metadata bloat**: Only track aggregate per-level ratio, not per-table

**Implementation**:
```zig
// In compaction.zig, during value filtering:
if (value_expired) {
    bar.stats.values_expired += 1;
}
bar.stats.values_total += 1;

// After bar completes (with EMA smoothing):
if (bar.stats.values_total > 0) {
    const sample = @as(f64, bar.stats.values_expired) / @as(f64, bar.stats.values_total);
    const alpha: f64 = 0.2;
    level.expired_ratio = alpha * sample + (1.0 - alpha) * level.expired_ratio;
}
```

**Alternatives Considered**:
1. *Periodic full scan*: Rejected - adds I/O overhead, doesn't provide real-time visibility
2. *Real-time tracking per write*: Rejected - overhead on every write operation
3. *Background sampling task*: Rejected - adds complexity, still requires I/O

### Decision 2: Per-Level Prioritization with Threshold

**Choice**: When a level's expired ratio exceeds threshold (default 30%), prioritize it in scheduling.

**Rationale**:
- **Aligns with existing structure**: Compaction already works level-by-level
- **Simple logic**: Single threshold check per level
- **Predictable**: Operators understand "level 3 has 40% expired data, will compact soon"
- **Avoids metadata tracking**: Don't need per-table expiration tracking

**Threshold Selection** (30% default):
- Below 30%: Normal compaction handles expired data efficiently
- 30-50%: Moderate priority boost (compact within 1-2 bars instead of 3-4)
- Above 50%: High priority (compact within current bar if possible)

**Alternatives Considered**:
1. *Per-table prioritization*: Rejected - requires complex table selection changes
2. *Weighted scoring*: Rejected - adds complexity without clear benefit
3. *Fixed priority boost*: Rejected - inflexible for different workload patterns

### Decision 3: Gentle Nudge Within Compaction Rhythm

**Choice**: Adjust level selection order within existing half-bar structure, don't preempt.

**Rationale**:
- **Preserves predictability**: Compaction still runs every half-bar (50 ops)
- **No write amplification spike**: Avoids sudden compaction storms
- **Existing quota limits apply**: beat_input_size limits prevent overload
- **Debuggable**: Compaction logs show "TTL-prioritized level 3" reasoning

**Scheduling Algorithm**:
```
For each half-bar:
  1. Iterate levels in active order (normal: 1, 2, 3, 4, 5, 6)
  2. If level expired_ratio > threshold:
     - Move level to front of iteration order for this half-bar
  3. Within each level, use existing least-overlap table selection
  4. Apply existing beat quota limits
```

**Alternatives Considered**:
1. *Aggressive preemption*: Rejected - disrupts normal compaction, unpredictable latency
2. *Separate TTL compaction track*: Rejected - doubles compaction complexity
3. *Continuous background compaction*: Rejected - violates existing beat structure

### Decision 4: Expose Expired Ratio Metrics Per Level

**Choice**: Add `archerdb_ttl_expired_ratio_by_level{level="N"}` gauge (0.0-1.0 range).

**Rationale**:
- **Operator visibility**: Monitor expired accumulation before it becomes problematic
- **Alert integration**: Set alerts on "level 5 expired ratio > 0.5" for proactive intervention
- **Debugging**: Understand why compaction prioritization triggered
- **Capacity planning**: Predict when space will be reclaimed

**Metric Details**:
```
archerdb_ttl_expired_ratio_by_level{level="1"} 0.05
archerdb_ttl_expired_ratio_by_level{level="2"} 0.12
archerdb_ttl_expired_ratio_by_level{level="3"} 0.45  # High - will prioritize
archerdb_ttl_expired_ratio_by_level{level="4"} 0.28
archerdb_ttl_expired_ratio_by_level{level="5"} 0.61  # Very high - will prioritize
archerdb_ttl_expired_ratio_by_level{level="6"} 0.35  # High - will prioritize
```

## Architecture

### Component Changes

#### 1. Compaction Statistics (src/lsm/compaction.zig)

Add per-bar expired value counting:
```zig
pub const BarStatistics = struct {
    values_total: u64,
    values_expired: u64,  // NEW
    values_dropped_tombstone: u64,
    values_output: u64,
};
```

Update TTL filtering logic to increment counters (existing locations: lines 1933, 1999, 2013, 2034).

#### 2. Level Expired Ratio Tracking (src/lsm/manifest_level.zig)

Add expired ratio field:
```zig
pub const ManifestLevel = struct {
    // ... existing fields

    /// Estimated expired data ratio (0.0 - 1.0).
    /// Updated via exponential moving average during compaction sampling.
    expired_ratio: f64 = 0.0,

    /// Last timestamp this level's expired ratio was sampled.
    expired_ratio_sampled_at_op: u64 = 0,
};
```

Update ratio using exponential moving average (EMA) when bar completes:
```zig
const alpha = 0.2; // Weight for new samples
level.expired_ratio = alpha * new_sample + (1 - alpha) * level.expired_ratio;
```

#### 3. TTL-Aware Scheduling (src/lsm/forest.zig - CompactionScheduleType)

Modify `beat_start` to reorder levels before compaction:
```zig
// In beat_start, before iterating levels:
const ttl_priority_threshold = 0.30; // 30% expired
var level_order: [constants.lsm_levels]u8 = undefined;

// Build prioritized level order
var normal_idx: usize = 0;
var priority_idx: usize = 0;

// First pass: high-expired levels
for (0..constants.lsm_levels) |level_b| {
    const level = forest.manifest.levels[level_b];
    if (level.expired_ratio > ttl_priority_threshold) {
        level_order[priority_idx] = level_b;
        priority_idx += 1;
    }
}

// Second pass: normal levels
for (0..constants.lsm_levels) |level_b| {
    const level = forest.manifest.levels[level_b];
    if (level.expired_ratio <= ttl_priority_threshold) {
        level_order[priority_idx] = level_b;
        priority_idx += 1;
    }
}

// Iterate in priority order
for (level_order) |level_b| {
    if (level_active(.{ .level_b = level_b, .op = op })) {
        // ... existing compaction logic
    }
}
```

#### 4. Metrics Exposure (src/archerdb/metrics.zig)

Add new metric:
```zig
/// TTL expired data ratio per LSM level (0.0-1.0 range).
/// Sampled during compaction. Values near 1.0 indicate high expired accumulation.
pub const archerdb_ttl_expired_ratio_by_level = struct {
    pub const help = "Estimated expired data ratio per LSM level (0.0-1.0)";
    pub const type_name = "gauge";
    pub const labels = &[_][]const u8{"level"};
};
```

Update metric from CompactionSchedule after each bar completes.

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Normal Compaction Run (Every Half-Bar)                       │
│    └─> Merge tables from level A → level B                     │
│        └─> Filter expired values (existing TTL logic)           │
│            └─> Count: values_total, values_expired              │
│                └─> Calculate: expired_ratio = expired / total   │
│                    └─> Update level.expired_ratio (EMA)         │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Compaction Scheduling (Next Half-Bar Beat Start)             │
│    └─> Check expired_ratio for each level                       │
│        └─> If expired_ratio > 30%: prioritize level             │
│            └─> Reorder level iteration (high-expired first)     │
│                └─> Apply existing table selection & quotas      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Metrics & Observability                                      │
│    └─> Expose archerdb_ttl_expired_ratio_by_level{level="N"}   │
│        └─> Operators monitor and alert on high ratios           │
│            └─> Optional: Tune threshold if needed               │
└─────────────────────────────────────────────────────────────────┘
```

## Trade-Offs

### Chosen Approach: Gentle Sampling-Based Prioritization

**Pros**:
- ✅ Zero overhead (samples during normal compaction)
- ✅ Eventually accurate (all tables eventually sampled)
- ✅ Simple implementation (threshold + reordering)
- ✅ Predictable behavior (no aggressive preemption)
- ✅ Easy to debug (clear log messages)

**Cons**:
- ❌ Not real-time (sampling lag until level is compacted)
- ❌ Not precise (exponential moving average, not exact count)
- ❌ Limited aggressiveness (won't preempt normal schedule)

### Alternative 1: Periodic Background Scanning

**Why Rejected**:
- Adds I/O overhead for scanning table metadata
- Requires CPU time for ratio calculation
- More accurate, but accuracy doesn't justify cost

### Alternative 2: Real-Time Per-Write Tracking

**Why Rejected**:
- Overhead on every write operation
- Requires per-table metadata storage
- Over-engineered for the problem

### Alternative 3: Aggressive Preemptive Compaction

**Why Rejected**:
- Disrupts normal compaction rhythm
- Unpredictable latency spikes
- Harder to reason about compaction behavior
- May starve non-TTL levels

## Validation Plan

### Unit Tests

1. **Expired ratio sampling accuracy**: Verify EMA converges to actual expired ratio
2. **Level prioritization correctness**: High-expired levels compacted before low-expired
3. **Beat quota limits respected**: TTL prioritization doesn't exceed beat quotas
4. **Metric correctness**: Exposed metrics match internal tracking

### Integration Tests

1. **TTL-heavy workload**: Insert 1M entities with 1-day TTL, verify faster reclamation
2. **Mixed workload**: Verify non-TTL data still compacts normally
3. **Edge case**: All levels > 30% expired - verify graceful handling
4. **Performance**: No regression in write throughput or query latency

### Production Validation

1. **Monitor metrics**: Track `archerdb_ttl_expired_ratio_by_level` in staging
2. **Measure reclamation time**: Compare before/after for space recovery
3. **Alert testing**: Verify alerts trigger correctly on high ratios

## Implementation Phases

### Phase 1: Sampling Infrastructure (2 days)

- Add `expired_ratio` field to ManifestLevel
- Implement EMA update during bar_complete
- Unit tests for sampling accuracy

### Phase 2: Scheduling Logic (2 days)

- Implement level reordering in beat_start
- Add threshold configuration
- Unit tests for prioritization

### Phase 3: Metrics & Observability (1 day)

- Add `archerdb_ttl_expired_ratio_by_level` metric
- Update metrics on bar completion
- Integration test for metric correctness

### Phase 4: Testing & Documentation (2 days)

- Integration tests with TTL-heavy workloads
- Performance regression tests
- Update operational runbooks

## Success Metrics

- **Space reclamation time** (1M entities, 1-day TTL):
  - Current: 4-5 half-bars after expiration
  - Target: 2-3 half-bars after expiration

- **Performance (no regression)**:
  - Write throughput: ≥1M events/sec (same as v2.2)
  - Query latency: <500μs UUID lookup (same as v2.2)
  - Compaction CPU: <10% (same as v2.2)

- **Operational**:
  - Metrics exposed and accurate
  - Alerts trigger correctly
  - Configuration simple (single threshold)
