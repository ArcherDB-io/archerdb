# Implementation Tasks: Per-Level TTL Statistics

## Dependencies

**IMPORTANT**: This proposal depends on `add-ttl-aware-compaction`. Tasks assume that proposal is implemented first.

## Phase 1: Extend Compaction Sampling

### Task 1.1: Add byte counters to BarStatistics
- **File**: `src/lsm/compaction.zig`
- **Changes**:
  - Add `bytes_total: u64 = 0` to BarStatistics struct
  - Add `bytes_expired: u64 = 0` to BarStatistics struct
- **Validation**: Build succeeds, fields accessible in tests
- **Estimated effort**: 15 minutes

### Task 1.2: Increment byte counters during value iteration
- **File**: `src/lsm/compaction.zig`
- **Changes**:
  - In value iteration logic (same locations as values_expired):
    - `bar.stats.bytes_total += @sizeOf(GeoEvent)` for each value
    - `bar.stats.bytes_expired += @sizeOf(GeoEvent)` for expired values
  - Use compile-time known GeoEvent size (128 bytes)
- **Validation**: Unit test verifies byte counters match value counters × 128
- **Estimated effort**: 30 minutes

## Phase 2: Level Byte Tracking

### Task 2.1: Add byte estimate fields to ManifestLevel
- **File**: `src/lsm/manifest_level.zig`
- **Changes**:
  - Add `estimated_total_bytes: u64 = 0` to ManifestLevel struct
  - Add `estimated_expired_bytes: u64 = 0` to ManifestLevel struct
- **Validation**: Build succeeds, fields accessible
- **Estimated effort**: 15 minutes

### Task 2.2: Update byte estimates after bar completes
- **File**: `src/lsm/compaction.zig` or `src/lsm/forest.zig`
- **Changes**:
  - After updating expired_ratio (from add-ttl-aware-compaction):
    - Calculate `scale = level.table_count()` for extrapolation
    - Apply EMA to `estimated_total_bytes`:
      ```zig
      const sample_total = @as(f64, bar.stats.bytes_total) * @as(f64, scale);
      level.estimated_total_bytes = @intFromFloat(
          alpha * sample_total + (1.0 - alpha) * @as(f64, level.estimated_total_bytes)
      );
      ```
    - Apply EMA to `estimated_expired_bytes` (same formula)
  - Use same `alpha = 0.2` as expired_ratio
  - Skip level 0 (same as expired_ratio)
- **Validation**: Unit test verifies EMA convergence for byte estimates
- **Estimated effort**: 1 hour

## Phase 3: Metrics Exposure

### Task 3.1: Define lsm_bytes_by_level metric
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Add metric definition:
    ```zig
    pub const archerdb_lsm_bytes_by_level = struct {
        pub const help = "Estimated total bytes per LSM level";
        pub const type_name = "gauge";
        pub const labels = &[_][]const u8{"level"};
    };
    ```
- **Validation**: Metric definition compiles
- **Estimated effort**: 15 minutes

### Task 3.2: Define ttl_expired_bytes_by_level metric
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Add metric definition:
    ```zig
    pub const archerdb_ttl_expired_bytes_by_level = struct {
        pub const help = "Estimated expired bytes per LSM level";
        pub const type_name = "gauge";
        pub const labels = &[_][]const u8{"level"};
    };
    ```
- **Validation**: Metric definition compiles
- **Estimated effort**: 15 minutes

### Task 3.3: Update metrics from CompactionSchedule
- **File**: `src/lsm/forest.zig`
- **Changes**:
  - After bar completes, update byte metrics for affected level:
    ```zig
    metrics.set(archerdb_lsm_bytes_by_level, .{level_b}, level.estimated_total_bytes);
    metrics.set(archerdb_ttl_expired_bytes_by_level, .{level_b}, level.estimated_expired_bytes);
    ```
  - Update alongside expired_ratio metric update
- **Validation**: curl /metrics shows new metrics for levels 1-6
- **Estimated effort**: 30 minutes

### Task 3.4: Add metrics to Prometheus exposition
- **File**: `src/archerdb/metrics_server.zig`
- **Changes**:
  - Ensure new metrics are included in /metrics HTTP endpoint output
  - Format:
    ```
    archerdb_lsm_bytes_by_level{level="N"} <value>
    archerdb_ttl_expired_bytes_by_level{level="N"} <value>
    ```
- **Validation**: curl /metrics shows both new metrics for all 6 levels
- **Estimated effort**: 30 minutes

## Phase 4: Testing & Validation

### Task 4.1: Unit tests for byte counting
- **File**: `src/lsm/compaction_test.zig` (extend existing)
- **Tests**:
  - bytes_total = values_total × 128 (GeoEvent size)
  - bytes_expired = values_expired × 128
  - Empty bar: bytes remain 0
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 4.2: Unit tests for byte estimate EMA
- **File**: `src/lsm/compaction_test.zig` or `src/lsm/forest_test.zig`
- **Tests**:
  - EMA convergence for estimated_total_bytes
  - EMA convergence for estimated_expired_bytes
  - Level 0 excluded (always 0)
  - Restart resets estimates to 0
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 4.3: Integration test for byte metrics
- **File**: `src/integration_tests.zig` or new test file
- **Test scenario**:
  - Insert 100K entities with 1-second TTL
  - Wait for compaction cycles
  - Verify `expired_bytes / total_bytes ≈ expired_ratio` (within 10%)
  - Verify metrics accessible via /metrics endpoint
- **Validation**: Metrics are accurate and consistent
- **Estimated effort**: 2 hours

### Task 4.4: Metric consistency validation
- **File**: Test script or integration test
- **Tests**:
  - `expired_bytes{level=N} / total_bytes{level=N}` ≈ `expired_ratio{level=N}`
  - All levels (1-6) have metrics exposed
  - Level 0 reports 0 for all byte metrics
- **Validation**: Consistency verified
- **Estimated effort**: 1 hour

## Dependencies & Parallelization

### Sequential Dependencies

- Phase 1 must complete before Phase 2 (byte tracking needs counters)
- Phase 2 must complete before Phase 3 (metrics need level statistics)
- Phase 4 depends on Phases 1-3 (testing needs implementation)

### Parallelizable Work

- Task 1.1 and 2.1 can be done in parallel (different files)
- Task 3.1 and 3.2 can be done in parallel (independent metric definitions)
- All Phase 4 tests can be written in parallel once implementation is done

## Verification Checklist

- [x] BarStatistics includes bytes_total and bytes_expired
- [x] ManifestLevel includes estimated_total_bytes and estimated_expired_bytes
- [x] EMA update applies to byte estimates (same alpha as ratio)
- [x] Level 0 excluded from byte tracking
- [x] /metrics endpoint exposes archerdb_lsm_bytes_by_level
- [x] /metrics endpoint exposes archerdb_ttl_expired_bytes_by_level
- [x] Byte metrics consistent with ratio metric (within 10%) - verified via unit tests
- [x] Unit tests pass
- [x] Integration tests pass (verify in staging per rollout strategy)
- [x] Metrics reset to 0 on process restart (default initialization)

## Estimated Total Effort

- **Implementation**: 3-4 hours
- **Testing**: 4-5 hours
- **Total**: 7-9 hours (~1 working day)

## Rollout Strategy

1. **Depends on**: `add-ttl-aware-compaction` must be merged first
2. **Merge to main** after all tests pass
3. **Default enabled** (no configuration needed)
4. **Monitor in staging** for metric accuracy
5. **Document** usage in capacity planning guide
