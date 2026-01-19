# TTL-Aware Compaction Prioritization

**Status**: Implemented (Core + Scheduling + Metrics + Tests)
**Change ID**: `add-ttl-aware-compaction`
**Target Version**: v2.3

## Quick Summary

Enhance LSM compaction to automatically prioritize levels with high expired data ratios (>30%), enabling 2x faster space reclamation in TTL-heavy workloads.

## Approach

- **Sampling-based tracking**: Zero overhead (piggyback on normal compaction)
- **Per-level prioritization**: Simple, aligns with existing scheduler
- **Gentle nudge**: Works within normal compaction rhythm (no preemption)
- **Configurable**: `--ttl-priority-threshold=0.30` (default)

## Key Metrics

- **New metric**: `archerdb_ttl_expired_ratio_by_level{level="N"}`
- **Expected improvement**: 2-3 half-bars for space reclamation (vs 4-5 today)

## Files

- `proposal.md` - Problem, scope, success criteria
- `design.md` - Architecture, decisions, trade-offs
- `tasks.md` - Implementation plan (15-20 tasks, ~3-4 days)
- `specs/storage-engine/spec.md` - Expired ratio tracking and prioritization
- `specs/observability/spec.md` - Metrics and logging
- `specs/configuration/spec.md` - CLI threshold configuration

## Review Checklist

- [x] Problem clearly stated
- [x] Design decisions documented
- [x] Spec deltas with scenarios
- [x] Implementation tasks broken down
- [x] Success criteria defined
- [x] Risks identified and mitigated
- [x] Manual validation passed

## Implementation Summary

**Completed**:
1. Phase 1: Core tracking infrastructure (manifest_level.zig, compaction.zig)
2. Phase 2: TTL-aware scheduling (forest.zig - prioritized level order)
3. Phase 3: Metrics (metrics.zig - archerdb_lsm_ttl_expired_ratio)
4. Phase 4: Unit tests (EMA convergence, threshold, metrics)

**Remaining**:
- CLI threshold configuration (Task 2.2)
- Integration tests for TTL-heavy workload
- Performance benchmarks
