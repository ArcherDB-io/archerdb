# Alert: ArcherDBIndexDegraded

## Quick Reference
- **Severity:** critical
- **Metric:** `archerdb_index_probe_limit_hits_total`
- **Threshold:** `> 0` (any probe limit hit)
- **Time to Respond:** Within 1 hour (impacts query performance)

## What This Alert Means

The RAM index is operating in degraded mode due to hash collisions. When the index is too small for the entity count, lookups require additional probing which significantly slows queries. This alert indicates the `ram_index_capacity` setting needs to be increased.

## Immediate Actions

1. [ ] Check current entity count vs index capacity
2. [ ] Assess query latency impact
3. [ ] Plan capacity increase (requires restart)
4. [ ] Schedule maintenance window if immediate action needed

## Investigation

### Common Causes

- **Entity growth:** Data volume exceeded capacity planning assumptions
- **Under-provisioned:** Initial `ram_index_capacity` was set too low
- **Hot spots:** Uneven hash distribution causing localized collisions

### Diagnostic Commands

```bash
# Check entity count vs capacity
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep -E "(archerdb_entities_total|archerdb_index)"

# Check index load factor (should be < 0.5 for optimal performance)
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_index_load_factor

# Check how many probe limit hits occurred
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_index_probe_limit_hits_total

# Check current capacity configuration
kubectl exec archerdb-0 -n archerdb -- ./archerdb info /data/archerdb.db | grep -i index
```

### Impact Assessment

```bash
# Check query latency - degraded index causes P99 spikes
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_read_latency_seconds

# Check for query timeouts
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "timeout"
```

## Resolution

### Increase Index Capacity

The index capacity must be configured at startup. A rolling restart is required.

1. **Calculate required capacity:**
   ```
   Current entities: N
   Target capacity: N * 2 (for 50% load factor)
   Recommended minimum: 500,000 (Phase 5 optimization)
   ```

2. **Update configuration:**

   For Helm deployment:
   ```yaml
   # values.yaml
   config:
     ram_index_capacity: 1000000  # Increase to 1M
   ```

   For bare metal:
   ```bash
   # Update startup script or systemd unit
   ./archerdb start --ram-index-capacity=1000000 ...
   ```

3. **Perform rolling restart:**
   ```bash
   # Kubernetes - update StatefulSet
   kubectl rollout restart statefulset/archerdb -n archerdb

   # Monitor rollout
   kubectl rollout status statefulset/archerdb -n archerdb
   ```

   For bare metal, see [Rolling Restart](../operations-runbook.md#rolling-restart).

### Sizing Guidelines

| Entity Count | Recommended Capacity | Load Factor |
|-------------|---------------------|-------------|
| < 100K      | 250,000             | ~40%        |
| 100K - 250K | 500,000             | ~50%        |
| 250K - 500K | 1,000,000           | ~50%        |
| 500K - 1M   | 2,000,000           | ~50%        |
| > 1M        | entity_count * 2    | ~50%        |

**Note:** Memory usage scales with capacity. Each additional 100K capacity adds ~1MB RAM.

## Prevention

- **Capacity planning:** Use [Capacity Planning Guide](../capacity-planning.md) to set appropriate capacity
- **Monitoring:** Alert when load factor > 0.6 (warning) and > 0.7 (critical)
- **Growth forecasting:** Track entity growth rate and plan capacity increases proactively
- **Headroom:** Always maintain 50% headroom above current entity count

## Verification

After increasing capacity:

```bash
# Verify new capacity is active
kubectl exec archerdb-0 -n archerdb -- ./archerdb info /data/archerdb.db | grep -i index

# Verify load factor is healthy
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_index_load_factor
# Should be < 0.5

# Verify no more probe limit hits
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_index_probe_limit_hits_total
# Counter should stop increasing

# Verify query latency improved
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_read_latency_seconds
```

## Related Documentation

- [Capacity Planning](../capacity-planning.md) - Sizing guidelines
- [LSM Tuning](../lsm-tuning.md) - Storage performance tuning
- [High Read Latency](high-read-latency.md) - If degraded index causes latency alerts
