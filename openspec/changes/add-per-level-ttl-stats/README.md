# Per-Level TTL Statistics

**Status**: Implemented
**Change ID**: `add-per-level-ttl-stats`
**Target Version**: v2.3
**Depends On**: `add-ttl-aware-compaction` (completed)

## Quick Summary

Extend TTL-aware compaction sampling to expose absolute byte counts per LSM level, enabling capacity planning alerts like "expired_bytes > 100GB".

## Approach

- **Extend existing sampling**: Piggyback on `add-ttl-aware-compaction` infrastructure
- **Track bytes alongside ratios**: Same EMA smoothing, same accuracy expectations
- **Two new metrics**: `archerdb_lsm_bytes_by_level` and `archerdb_ttl_expired_bytes_by_level`

## Key Metrics

- **New metric**: `archerdb_lsm_bytes_by_level{level="N"}` - Total estimated bytes per level
- **New metric**: `archerdb_ttl_expired_bytes_by_level{level="N"}` - Expired bytes per level
- **Relationship**: `expired_bytes / total_bytes ≈ expired_ratio` (within 10%)

## Use Cases

```promql
# Alert on absolute expired data accumulation
sum(archerdb_ttl_expired_bytes_by_level) > 107374182400  # 100GB

# Estimate reclaimable storage cost
sum(archerdb_ttl_expired_bytes_by_level) * 0.023 / 1073741824  # $/GB/month

# Find level with most expired data
topk(1, archerdb_ttl_expired_bytes_by_level)
```

## Files

- `proposal.md` - Problem, scope, success criteria
- `design.md` - Architecture, decisions, trade-offs
- `tasks.md` - Implementation plan (~1 day, depends on add-ttl-aware-compaction)
- `specs/storage-engine/spec.md` - Byte tracking during compaction
- `specs/observability/spec.md` - New Prometheus metrics

## Review Checklist

- [x] Problem clearly stated
- [x] Design decisions documented
- [x] Spec deltas with scenarios
- [x] Implementation tasks broken down
- [x] Success criteria defined
- [x] Dependencies identified (add-ttl-aware-compaction)

## Next Steps

1. Review proposal for approval
2. Implement `add-ttl-aware-compaction` first (dependency)
3. Implement this proposal according to tasks.md
4. Validate with integration tests
