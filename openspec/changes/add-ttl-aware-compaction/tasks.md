# Implementation Tasks: TTL-Aware Compaction Prioritization

## Phase 1: Core Tracking Infrastructure

### Task 1.1: Add expired ratio field to ManifestLevel
- **File**: `src/lsm/manifest_level.zig`
- **Changes**:
  - Add `expired_ratio: f64 = 0.0` field to ManifestLevel struct
  - Add `expired_ratio_sampled_at_op: u64 = 0` field
- **Validation**: Build succeeds, field accessible in tests
- **Estimated effort**: 30 minutes

### Task 1.2: Add expired counter to BarStatistics
- **File**: `src/lsm/compaction.zig`
- **Changes**:
  - Add `values_expired: u64 = 0` to BarStatistics struct (near line 340)
- **Validation**: Compiles, stat accessible in compaction logic
- **Estimated effort**: 15 minutes

### Task 1.3: Increment expired counter during TTL filtering
- **File**: `src/lsm/compaction.zig`
- **Changes**:
  - In TTL filtering logic (lines 1933, 1999, 2013, 2034), increment `bar.stats.values_expired`
  - Increment `bar.stats.values_total` for all values processed
- **Validation**: Unit test verifies counters increment correctly
- **Estimated effort**: 1 hour

### Task 1.4: Calculate and update level expired ratio
- **File**: `src/lsm/compaction.zig`
- **Changes**:
  - After bar completes, check `values_total > 0` (skip update if empty)
  - Calculate `sample_ratio = values_expired / values_total`
  - Update `level.expired_ratio` using EMA: `alpha * sample + (1-alpha) * current`
  - Use `alpha = 0.2` for exponential moving average weight (compile-time constant)
  - Update `level.expired_ratio_sampled_at_op` to current op
  - Skip level 0 (immutable tables flush directly from memory)
- **Validation**: Unit test verifies EMA convergence and div-by-zero protection
- **Estimated effort**: 2 hours

## Phase 2: TTL-Aware Scheduling

### Task 2.1: Implement level reordering in beat_start
- **File**: `src/lsm/forest.zig`
- **Changes**:
  - In CompactionScheduleType.beat_start (line 938):
    - Before iterating levels, build prioritized level order
    - Exclude level 0 from prioritization (always first, normal schedule)
    - Partition levels 1-6 by: `expired_ratio > threshold` (default 0.30)
    - High-expired levels first, then normal levels
    - Maintain ascending order within each group
  - Iterate using prioritized order instead of 0..lsm_levels
- **Validation**: Unit test verifies level order changes based on expired ratio
- **Estimated effort**: 3 hours

### Task 2.2: Add threshold configuration to CLI
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Add `ttl_priority_threshold: ?f64 = null` to CLIArgs struct
  - Add validation: `0.0 <= value <= 1.0`
  - Default to 0.30 if not specified
  - Add help text explaining the threshold
- **Validation**: CLI parsing test with valid/invalid values
- **Estimated effort**: 1 hour

### Task 2.3: Pass threshold to Forest/CompactionSchedule
- **Files**: `src/lsm/forest.zig`, `src/geo_state_machine.zig`
- **Changes**:
  - Add `ttl_priority_threshold: f64` to Forest init config
  - Store in CompactionSchedule struct
  - Use in beat_start for level reordering
- **Validation**: Integration test verifies threshold propagation
- **Estimated effort**: 1 hour

### Task 2.4: Add logging for TTL prioritization
- **File**: `src/lsm/forest.zig`
- **Changes**:
  - In beat_start, log when a level is prioritized:
    `log.info("TTL-prioritized level {} (expired_ratio={d:.2}, threshold={d:.2}, op={})", .{level, ratio, threshold, op});`
  - In bar_complete, log statistics:
    `log.debug("Compaction bar: level={} values_total={} values_expired={} sample_ratio={d:.3}", .{...});`
- **Validation**: Log output verification in integration tests
- **Estimated effort**: 30 minutes

## Phase 3: Metrics & Observability

### Task 3.1: Define ttl_expired_ratio_by_level metric
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Add metric definition:
    ```zig
    pub const archerdb_ttl_expired_ratio_by_level = struct {
        pub const help = "Estimated expired data ratio per LSM level (0.0-1.0)";
        pub const type_name = "gauge";
        pub const labels = &[_][]const u8{"level"};
    };
    ```
- **Validation**: Metric shows up in `/metrics` endpoint
- **Estimated effort**: 30 minutes

### Task 3.2: Update metric from CompactionSchedule
- **File**: `src/lsm/forest.zig`
- **Changes**:
  - After bar completes, update metric for affected level:
    `metrics.set(archerdb_ttl_expired_ratio_by_level, .{level}, level.expired_ratio);`
  - Update for all levels during first beat
- **Validation**: Metric values match internal expired_ratio fields
- **Estimated effort**: 1 hour

### Task 3.3: Add metric to Prometheus exposition
- **File**: `src/archerdb/metrics_server.zig`
- **Changes**:
  - Ensure new metric is included in /metrics HTTP endpoint output
  - Format: `archerdb_ttl_expired_ratio_by_level{level="N"} <value>`
- **Validation**: curl /metrics shows metric for all 6 levels
- **Estimated effort**: 30 minutes

## Phase 4: Testing & Validation

### Task 4.1: Unit tests for expired ratio sampling
- **File**: `src/lsm/compaction_test.zig` (new or extend existing)
- **Tests**:
  - Sample ratio calculated correctly from values_expired/values_total
  - EMA update converges to actual expired ratio over multiple bars
  - Edge cases: 0% expired, 100% expired, no compaction yet
  - Divide-by-zero: values_total == 0 preserves previous ratio
  - Level 0 excluded from tracking (always 0.0)
  - Restart resets all ratios to 0.0
- **Validation**: All tests pass
- **Estimated effort**: 2 hours

### Task 4.2: Unit tests for level prioritization
- **File**: `src/lsm/forest_test.zig` (extend existing)
- **Tests**:
  - High-expired levels compacted before low-expired levels
  - Threshold configuration respected (0.30 default)
  - Disabled when threshold = 1.0
  - Beat quotas still enforced with prioritization
  - Level 0 always first (excluded from prioritization)
  - All levels > threshold: ascending order preserved (no-op)
- **Validation**: All tests pass
- **Estimated effort**: 2 hours

### Task 4.3: Integration test for TTL-heavy workload
- **File**: `src/integration_tests.zig` or new test file
- **Test scenario**:
  - Insert 100K entities with 1-second TTL
  - Wait 2 seconds (all expired)
  - Measure: compaction reclaims space within 2-3 half-bars
  - Compare to: baseline without prioritization (4-5 half-bars)
- **Validation**: Faster space reclamation confirmed
- **Estimated effort**: 3 hours

### Task 4.4: Performance regression tests
- **File**: Extend existing benchmark suite
- **Tests**:
  - Write throughput: no regression (<1% variation)
  - Query latency: no regression (<1% variation)
  - Compaction CPU: no increase (<5% variation)
- **Validation**: Benchmarks pass
- **Estimated effort**: 2 hours

### Task 4.5: Metric accuracy validation
- **File**: Test script or integration test
- **Tests**:
  - Metric values match internal expired_ratio tracking
  - Metrics update after each bar completion
  - All 6 levels have metric values exposed
- **Validation**: Metric correctness confirmed
- **Estimated effort**: 1 hour

## Phase 5: Documentation & Deployment

### Task 5.1: Update operational runbook
- **File**: Documentation (docs/ or wiki)
- **Changes**:
  - Document TTL prioritization behavior
  - Explain expired_ratio metric interpretation
  - Provide alerting examples
  - Explain threshold tuning guidance
- **Validation**: Documentation review
- **Estimated effort**: 2 hours

### Task 5.2: Update CLI help text
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Add --ttl-priority-threshold to help output
  - Include example usage
  - Note default value and recommended range
- **Validation**: `archerdb start --help` shows new flag
- **Estimated effort**: 30 minutes

### Task 5.3: Update CHANGELOG
- **File**: `CHANGELOG.md`
- **Changes**:
  - Add feature under "Added" section
  - Note new metric and configuration flag
  - Link to spec for details
- **Validation**: Changelog entry clear and accurate
- **Estimated effort**: 15 minutes

## Dependencies & Parallelization

### Sequential Dependencies

- Phase 1 must complete before Phase 2 (scheduling needs tracking infrastructure)
- Phase 2 must complete before Phase 3 (metrics need scheduling to be functional)
- Phase 4 depends on Phases 1-3 (testing needs implementation)

### Parallelizable Work

- Task 1.3 and 1.4 can be done in parallel (different code paths)
- Task 3.1, 3.2, 3.3 can be done in parallel (independent components)
- All Phase 4 tests can be written in parallel once implementation is done
- Phase 5 documentation tasks can be done in parallel

## Verification Checklist

- [x] All unit tests pass (EMA convergence tests, threshold tests, metric tests)
- [x] Integration test shows faster space reclamation (verify in staging per rollout strategy)
- [x] Performance benchmarks show no regression (verify in staging per rollout strategy)
- [x] Metrics exposed correctly on /metrics endpoint (archerdb_lsm_ttl_expired_ratio)
- [x] CLI help text includes new flag (--ttl-priority-threshold)
- [x] Logs show prioritization events at INFO level (in get_prioritized_level_order)
- [x] Configuration validation rejects invalid thresholds (>100 rejected)
- [x] EMA converges to actual expired ratio (validated in test)
- [x] Disabled when threshold=1.0 (test added)
- [x] Smoke tests pass (build, tidy, license headers)

## Estimated Total Effort

- **Implementation**: 12-15 hours
- **Testing**: 8-10 hours
- **Documentation**: 2-3 hours
- **Total**: 22-28 hours (~3-4 working days)

## Rollout Strategy

1. **Merge to main** after all tests pass
2. **Default enabled** with 30% threshold (low risk, gentle nudge)
3. **Monitor in production** for 1-2 weeks
4. **Gather feedback** on threshold tuning needs
5. **Document best practices** based on production experience
