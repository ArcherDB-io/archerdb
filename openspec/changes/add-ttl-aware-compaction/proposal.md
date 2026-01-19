# Proposal: TTL-Aware Compaction Prioritization

## Summary

Enhance the LSM compaction scheduler to prioritize levels with high expired data ratios, enabling faster space reclamation in TTL-heavy workloads without disrupting normal compaction rhythm.

## Motivation

### Problem

ArcherDB v2 supports TTL-based expiration, but expired data is only reclaimed during normal LSM compaction. In TTL-heavy workloads (e.g., 30-day retention for billions of location events), expired data can accumulate significantly before being compacted, leading to:

1. **Wasted storage**: Expired data occupies disk space unnecessarily
2. **Slower queries**: Expired entries in index consume memory and CPU during lookups
3. **Higher costs**: Cloud storage costs for data that should be deleted
4. **Unpredictable reclamation**: Space recovery depends on normal compaction schedule, not TTL expiration patterns

### Current Behavior (v2.2)

- Compaction follows standard leveled compaction schedule (round-robin across levels)
- Table selection uses "least overlap" heuristic (minimizes write amplification)
- TTL expiration happens during compaction (expired values discarded)
- No awareness of expired data ratio when scheduling compaction
- Operators monitor `archerdb_compaction_debt_ratio` but have no automated response

### Desired Behavior

- Compaction scheduler **gently prioritizes** levels with high expired data ratios (>30%)
- Expired ratio tracked via **sampling during normal compaction** (zero overhead)
- Prioritization **nudges** compaction within existing rhythm (no disruptive preemption)
- Operators maintain visibility via metrics and can tune threshold if needed

## Scope

### In Scope

1. **Expired ratio tracking** - Sample and track expired data percentage per LSM level
2. **Level prioritization** - Adjust compaction scheduling to favor high-expired-ratio levels
3. **Metrics exposure** - Expose `archerdb_ttl_expired_ratio_by_level` gauge
4. **Threshold configuration** - Configurable expired ratio threshold (default: 30%)
5. **Gentle scheduling** - Work within existing compaction beat structure

### Out of Scope

1. **Per-table prioritization** - Too granular; level-based is sufficient
2. **Aggressive preemption** - Don't disrupt normal compaction rhythm
3. **Background TTL scanning** - Only sample during normal compaction (zero overhead)
4. **Manual compaction commands** - Separate feature (v2.3+)
5. **Automatic cliff detection** - Separate feature (v2.3+)

## Success Criteria

1. **Space reclamation improved**: Expired data reclaimed within 2x normal compaction time (vs 4-5x today)
2. **Zero performance regression**: No impact on write throughput or query latency
3. **Metrics visibility**: Operators can monitor expired ratio per level
4. **Configuration simplicity**: Single threshold parameter with sensible default
5. **Operational predictability**: Compaction behavior remains understandable and debuggable

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Compaction starvation of low-TTL levels | Lower levels don't compact | Gentle nudge approach; only prioritize within normal schedule |
| Incorrect expired ratio sampling | Wrong scheduling decisions | Conservative sampling; verify during normal compaction only |
| Increased compaction scheduler complexity | Harder to debug compaction issues | Simple threshold-based logic; comprehensive logging |
| Configuration tuning required per workload | Operational burden | Sensible default (30%); optional tuning for edge cases |

## Stakeholders

- **Operators**: Need predictable space reclamation without manual intervention
- **Cost-conscious users**: Want to minimize storage costs for expired data
- **TTL-heavy workloads**: Fleet tracking, IoT, session data with 7-30 day retention
- **ArcherDB maintainers**: Must maintain compaction scheduler simplicity and debuggability

## Open Questions

None - all design decisions resolved via user input (recommended options selected).

## Related Work

- Existing TTL implementation: `openspec/changes/add-geospatial-core/specs/ttl-retention/spec.md`
- Compaction scheduler: `src/lsm/forest.zig` CompactionScheduleType
- Table selection: `src/lsm/manifest_level.zig` table_with_least_overlap
- TTL filtering during compaction: `src/lsm/compaction.zig` (lines 1933, 1999, 2013, 2034)

## Timeline

- **Design & Specification**: 1-2 days
- **Implementation**: 3-5 days
- **Testing & Validation**: 2-3 days
- **Total**: ~1-2 weeks

## Next Steps

1. Create detailed design document
2. Draft spec deltas for storage-engine and observability
3. Create implementation tasks
4. Validate proposal with `openspec validate`
