# Alert: ArcherDBViewChangeFrequent

## Quick Reference
- **Severity:** warning
- **Metric:** `archerdb_view_changes_total`
- **Threshold:** `increase(...[5m]) > 3` (more than 3 view changes in 5 minutes)
- **Time to Respond:** Within 15 minutes

## What This Alert Means

Too many leader elections (view changes) are occurring, indicating cluster instability. While the cluster remains available, frequent view changes cause brief write pauses and may indicate an underlying issue that could lead to unavailability.

## Immediate Actions

1. [ ] Check all replica health status
2. [ ] Identify which replica(s) are triggering view changes
3. [ ] Check for network issues between replicas
4. [ ] Review resource utilization on all replicas

## Investigation

### Common Causes

- **Network instability:** Packet loss or high latency between replicas
- **Resource exhaustion:** CPU saturation or disk I/O delays causing heartbeat timeouts
- **Clock skew:** Significant time drift between replicas
- **Failing replica:** One replica repeatedly crashing or hanging

### Diagnostic Commands

```bash
# Check view change history per replica
for i in 0 1 2; do
  echo "=== archerdb-$i ==="
  kubectl exec archerdb-$i -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_view_changes_total
done

# Check which replica is currently primary
for i in 0 1 2; do
  echo -n "archerdb-$i role: "
  kubectl exec archerdb-$i -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_replica_role
done
# 1 = primary, 0 = follower

# Check network latency between replicas
kubectl exec archerdb-0 -n archerdb -- ping -c 10 archerdb-1.archerdb-headless.archerdb.svc.cluster.local

# Check for packet loss
kubectl exec archerdb-0 -n archerdb -- ping -c 100 archerdb-1.archerdb-headless.archerdb.svc.cluster.local | tail -3

# Check CPU usage
kubectl top pod -n archerdb -l app=archerdb

# Check disk I/O
kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
```

### Log Analysis

```bash
# Search for view change events in logs
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "view change"

# Check for timeout events
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "timeout"

# Check for heartbeat failures
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "heartbeat"
```

## Resolution

### Network Instability

1. **Identify network issues:**
   ```bash
   # Test sustained connectivity
   kubectl exec archerdb-0 -n archerdb -- mtr -c 100 --report archerdb-1.archerdb-headless.archerdb.svc.cluster.local
   ```

2. **Check for network policy issues:**
   ```bash
   kubectl get networkpolicy -n archerdb -o yaml
   ```

3. **For cloud deployments:** Check cloud provider status and network logs.

### CPU/Disk Saturation

1. **Check resource usage:**
   ```bash
   kubectl top pod -n archerdb
   kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
   ```

2. **If CPU saturated:** Increase CPU limits or investigate high-CPU operations.

3. **If disk slow:** Check for compaction backlog or storage issues. See [Compaction Backlog](compaction-backlog.md).

### Clock Skew

1. **Check time sync status:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- chronyc tracking
   # Or
   kubectl exec archerdb-0 -n archerdb -- timedatectl status
   ```

2. **If clock skewed > 100ms:** Fix NTP configuration on affected nodes.

### Failing Replica

1. **Identify which replica has issues:**
   ```bash
   # Check view change counts - higher count indicates the problem replica
   for i in 0 1 2; do
     echo -n "archerdb-$i view_changes: "
     kubectl exec archerdb-$i -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_view_changes_total
   done
   ```

2. **Check that replica's logs:**
   ```bash
   kubectl logs archerdb-N -n archerdb --since=30m | grep -E "(error|warning|panic)" -i
   ```

3. **Restart the problematic replica:**
   ```bash
   kubectl delete pod archerdb-N -n archerdb
   ```

## Prevention

- **Network reliability:** Use reliable network infrastructure, consider dedicated network for cluster traffic
- **Resource headroom:** Keep CPU < 70% and memory < 80% under normal load
- **Monitoring:** Alert on individual replica metrics, not just cluster aggregates
- **Time sync:** Ensure NTP is properly configured on all nodes
- **Pod anti-affinity:** Spread replicas across different nodes to isolate failures

## Related Documentation

- [Operations Runbook](../operations-runbook.md) - Cluster management
- [Troubleshooting Guide](../troubleshooting.md#frequent-view-changes) - Detailed view change troubleshooting
- [Replica Down](replica-down.md) - If view changes lead to replica failure
