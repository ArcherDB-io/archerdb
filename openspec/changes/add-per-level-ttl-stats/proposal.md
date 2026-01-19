# Proposal: Per-Level TTL Statistics

## Summary

Add absolute byte counts for expired data alongside the existing expired ratio metrics per LSM level, enabling precise capacity planning and disk usage forecasting for TTL-heavy workloads.

## Motivation

### Problem

The TTL-Aware Compaction proposal (`add-ttl-aware-compaction`) provides `expired_ratio` (0.0-1.0) per level via sampling, which is excellent for compaction prioritization. However, operators need **absolute byte counts** for:

1. **Capacity planning**: "How much disk space is wasted on expired data right now?"
2. **Cost forecasting**: "At current rates, how much will expired data cost us in storage?"
3. **Alerting thresholds**: "Alert if >100GB of expired data accumulates" (absolute, not relative)
4. **Debugging**: Correlate disk usage spikes with specific levels holding expired data

### Current Behavior (with add-ttl-aware-compaction)

- `archerdb_ttl_expired_ratio_by_level{level="N"}` - Ratio (0.0-1.0) via EMA sampling
- No absolute byte counts
- No way to know "Level 5 has 50GB of expired data" (only "50% expired")

### Desired Behavior

- **Absolute counts**: `archerdb_ttl_expired_bytes_by_level{level="N"}` - Estimated expired bytes
- **Total counts**: `archerdb_lsm_bytes_by_level{level="N"}` - Total bytes per level (denominator)
- **Ratio preserved**: Existing `expired_ratio` unchanged (used for prioritization)

## Scope

### In Scope

1. **Per-level byte tracking** - Track total bytes and expired bytes per LSM level
2. **Sampling-based estimation** - Use compaction sampling (same as expired_ratio)
3. **Metrics exposure** - Add `archerdb_ttl_expired_bytes_by_level` and `archerdb_lsm_bytes_by_level` gauges
4. **Capacity alerting support** - Enable absolute threshold alerts

### Out of Scope

1. **Real-time precise tracking** - Would require scanning all data; sampling is sufficient
2. **Per-table byte counts** - Level granularity is enough for capacity planning
3. **Historical trends storage** - Prometheus handles time series; we just expose current state
4. **Automatic actions based on byte thresholds** - Operators use alerts + manual intervention

## Success Criteria

1. **Absolute byte visibility**: Operators can see "Level 5 has ~45GB expired data"
2. **Alert capability**: Prometheus alerts can trigger on `expired_bytes > 50GB`
3. **Zero additional overhead**: Use same sampling mechanism as expired_ratio
4. **Consistency**: Byte estimates converge to reasonable accuracy (within 20% of actual)
5. **Compatibility**: Works seamlessly with existing TTL-aware compaction metrics

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Byte estimates inaccurate | Wrong capacity planning decisions | Document that values are estimates; use EMA smoothing |
| Additional memory per level | Minor memory increase | Only 16 bytes per level (2 x u64) |
| Metric cardinality increase | More Prometheus storage | Only 2 new metrics with 6 levels each (12 series total) |

## Stakeholders

- **Operators**: Need absolute numbers for capacity planning and budgeting
- **Cost managers**: Need to forecast storage costs based on expired data accumulation
- **On-call engineers**: Need to diagnose disk usage issues quickly

## Related Work

- Depends on: `add-ttl-aware-compaction` (uses same sampling infrastructure)
- Related: `ttl-retention/spec.md` (defines TTL expiration behavior)
- Related: `observability/spec.md` (defines Prometheus metrics endpoint)

## Timeline

- **Design & Specification**: 0.5 days (piggybacks on existing sampling)
- **Implementation**: 1-2 days (extend existing infrastructure)
- **Testing & Validation**: 0.5 days
- **Total**: ~2-3 days
