# Alert: ArcherDBReplicaDown

## Quick Reference
- **Severity:** critical
- **Metric:** `up{job="archerdb"}`
- **Threshold:** `== 0` (replica unreachable)
- **Time to Respond:** Immediate (affects quorum)

## What This Alert Means

A replica is not responding to health checks. If multiple replicas go down simultaneously, the cluster may lose quorum and become unavailable for writes.

## Immediate Actions

1. [ ] Check if the pod/process is running
2. [ ] Verify network connectivity to the replica
3. [ ] Check for resource exhaustion (OOM, disk full)
4. [ ] Verify remaining replicas have quorum (2 of 3 minimum)

## Investigation

### Common Causes

- **Process crash:** OOM kill, unhandled error, or bug
- **Node failure:** Hardware issue, kernel panic, or cloud provider incident
- **Network partition:** Replica is running but unreachable from Prometheus
- **Resource exhaustion:** Out of memory, disk full, or file descriptor limit

### Diagnostic Commands

```bash
# Check pod status (Kubernetes)
kubectl get pods -n archerdb -l app=archerdb

# Check pod events
kubectl describe pod archerdb-N -n archerdb | tail -20

# Check if process is running (bare metal)
systemctl status archerdb
pgrep -f archerdb

# Check recent logs
kubectl logs archerdb-N -n archerdb --tail=100
# Or
journalctl -u archerdb --since "10 minutes ago"

# Check resource usage
kubectl top pod archerdb-N -n archerdb
# Or
free -h && df -h /data

# Test network from another replica
kubectl exec archerdb-0 -n archerdb -- nc -zv archerdb-N.archerdb-headless.archerdb.svc.cluster.local 3000
```

## Resolution

### Process Crashed

1. Check logs for crash reason:
   ```bash
   kubectl logs archerdb-N -n archerdb --previous
   ```

2. If OOM killed, increase memory limits:
   ```yaml
   resources:
     limits:
       memory: "8Gi"  # Increase from default
   ```

3. Restart the pod:
   ```bash
   kubectl delete pod archerdb-N -n archerdb
   # StatefulSet will recreate it
   ```

### Node Failure

1. Check node status:
   ```bash
   kubectl get nodes
   kubectl describe node <node-name>
   ```

2. If node is unhealthy, pod will be rescheduled automatically (may take 5+ minutes).

3. For faster recovery, delete the pod to trigger immediate reschedule:
   ```bash
   kubectl delete pod archerdb-N -n archerdb --force --grace-period=0
   ```

### Network Partition

1. Verify network policies allow inter-pod communication:
   ```bash
   kubectl get networkpolicy -n archerdb
   ```

2. Check DNS resolution:
   ```bash
   kubectl exec archerdb-0 -n archerdb -- nslookup archerdb-N.archerdb-headless.archerdb.svc.cluster.local
   ```

3. Test port connectivity:
   ```bash
   kubectl exec archerdb-0 -n archerdb -- nc -zv archerdb-N.archerdb-headless.archerdb.svc.cluster.local 3000
   ```

### Resource Exhaustion

1. **Out of memory:** Increase memory limits or reduce entity count
2. **Disk full:** See [Disk Capacity Runbook](disk-capacity.md)
3. **File descriptors:** Check ulimits and increase if needed

## Prevention

- **PodDisruptionBudget:** Configure `minAvailable: 2` to prevent simultaneous evictions
- **Resource limits:** Set appropriate memory and CPU limits based on workload
- **Anti-affinity:** Spread replicas across nodes/zones
- **Monitoring:** Alert on memory usage > 80% before OOM
- **Node health:** Monitor node conditions and drain unhealthy nodes proactively

## Post-Recovery Verification

After the replica recovers:

```bash
# Verify replica is catching up
kubectl exec archerdb-N -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_replication_lag

# Verify view number matches other replicas
for i in 0 1 2; do
  echo -n "archerdb-$i: "
  kubectl exec archerdb-$i -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_view_number
done

# Verify cluster health
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/health/detailed
```

## Related Documentation

- [Operations Runbook](../operations-runbook.md) - Cluster management procedures
- [Disaster Recovery](../disaster-recovery.md) - Recovery from total failure
- [Troubleshooting Guide](../troubleshooting.md) - General troubleshooting
