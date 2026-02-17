# Troubleshooting Guide

This guide covers common issues encountered when operating ArcherDB and provides step-by-step resolution procedures.

## Quick Diagnosis

Use this table to quickly identify and resolve common issues:

| Symptom | Likely Cause | Quick Fix |
|---------|--------------|-----------|
| 503 on /health/ready | Not yet synced after start | Wait 30s for replica to sync, check logs for progress |
| 503 persists after 60s | Failed to join cluster | Check network connectivity between replicas |
| High P99 latency (>100ms) | Compaction backlog | Increase `compaction_threads` to 3, check disk I/O |
| Connection refused | Server not running or wrong port | Verify `systemctl status archerdb`, check port binding |
| "cluster ID mismatch" | Client configured for wrong cluster | Update client cluster_id to match server |
| "max clients reached" | Connection limit hit | Check `clients_max` config (default 64), close idle connections |
| TTL cleanup removes 0 | TTL not configured on events | Events must have `ttl_seconds > 0` when inserted |
| Replica lag growing | Follower disk too slow | Check `iostat` on lagging replica, upgrade to NVMe |
| Memory usage growing | Entity count exceeds plan | Check entity count vs capacity, scale or archive data |
| View changes frequent | Network instability | Check packet loss between replicas with `ping -c 100` |
| IndexDegraded alert | RAM index at capacity | Increase `ram_index_capacity` or scale horizontally |
| Disk fill prediction | Write rate exceeds capacity | Enable TTL, archive old data, or expand storage |

**For alert-specific runbooks, see:**
- [Replica Down Runbook](runbooks/replica-down.md) - Critical replica failure
- [Alert Rules Reference](../deploy/prometheus/rules.yaml) - All alert definitions

## Table of Contents

- [Quick Diagnosis](#quick-diagnosis)
- [How to Use This Guide](#how-to-use-this-guide)
- [Connection Issues](#connection-issues)
- [Performance Issues](#performance-issues)
- [Cluster Issues](#cluster-issues)
- [Query Issues](#query-issues)
- [Replication Issues](#replication-issues)
- [Data Protection Issues](#data-protection-issues)
- [Diagnostic Commands](#diagnostic-commands)

## How to Use This Guide

### Quick Resolution

Each issue follows a consistent format:
- **Symptom**: What you observe
- **Possible Causes**: Likely root causes ranked by frequency
- **Resolution**: Step-by-step fix for each cause
- **Prevention**: How to avoid this issue in the future

### When to Escalate

Escalate to senior support or engineering if:
- The issue persists after following all resolution steps
- You observe data corruption or inconsistency
- Multiple unrelated symptoms appear simultaneously
- The issue requires cluster-wide downtime to resolve

### Log Locations

| Component | Log Location | Format |
|-----------|--------------|--------|
| ArcherDB (systemd) | `journalctl -u archerdb` | Structured JSON or text |
| ArcherDB (manual) | stdout/stderr | Structured JSON or text |
| Metrics | `localhost:9090/metrics` | Prometheus format |
| Health | `localhost:9090/health/detailed` | JSON |

For log format configuration, see `--log-format` and `--log-level` options.

## Connection Issues

### Connection Refused

**Symptom:** Client receives "connection refused" error when connecting to ArcherDB.

**Possible Causes:**
1. Server not running
2. Wrong port number
3. Firewall blocking the port
4. Binding to wrong network interface

**Resolution:**

1. **Check if server is running:**
   ```bash
   systemctl status archerdb
   # Or
   pgrep -f archerdb
   ```
   If not running, start it: `systemctl start archerdb`

2. **Verify listening port:**
   ```bash
   ss -tlnp | grep archerdb
   # Or
   netstat -tlnp | grep 3000
   ```
   Ensure ArcherDB is listening on the expected port.

3. **Check firewall rules:**
   ```bash
   # Linux (iptables)
   iptables -L -n | grep 3000

   # Linux (firewalld)
   firewall-cmd --list-ports

   # Cloud: Check security groups/firewall rules in console
   ```

4. **Verify bind address:**
   ```bash
   # Check config or command line for --bind option
   # Default: 0.0.0.0 (all interfaces)
   ```

**Prevention:** Use monitoring to alert on server unavailability. Configure health checks in load balancers.

---

### Connection Timeout

**Symptom:** Client connections hang and eventually timeout.

**Possible Causes:**
1. Network routing issues
2. DNS resolution failure
3. Load balancer misconfiguration
4. Server overloaded

**Resolution:**

1. **Test network connectivity:**
   ```bash
   # From client machine
   ping node1
   telnet node1 3000
   nc -zv node1 3000
   ```

2. **Verify DNS resolution:**
   ```bash
   nslookup node1
   dig node1
   ```

3. **Check load balancer health:**
   ```bash
   # Verify backend health in LB dashboard
   # Check LB logs for connection errors
   ```

4. **Check server load:**
   ```bash
   curl -s localhost:9090/metrics | grep archerdb_connections_active
   curl -s localhost:9090/metrics | grep process_open_fds
   ```

**Prevention:** Implement connection timeouts in clients. Monitor connection counts and latency.

---

### Cluster ID Mismatch

**Symptom:** Client receives "cluster ID mismatch" error.

**Possible Causes:**
1. Client configured with wrong cluster ID
2. Connecting to wrong cluster
3. Data file from different cluster

**Resolution:**

1. **Check server cluster ID:**
   ```bash
   ./archerdb info /data/archerdb.db | grep cluster
   # Or check startup logs for "cluster_id"
   ```

2. **Update client configuration:**
   ```python
   # Ensure cluster_id matches server
   client = ArcherDBClient(
       addresses=["node1:3000"],
       cluster_id=12345  # Must match server
   )
   ```

3. **If data file is wrong:**
   Restore from external snapshot/archive or re-format with correct cluster ID.

**Prevention:** Store cluster IDs in configuration management. Use separate DNS names per cluster.

---

### Gateway TLS Handshake Failed

**Symptom:** Connection fails with TLS/SSL handshake error at gateway/proxy boundary.

**Possible Causes:**
1. Certificate expired
2. Hostname mismatch
3. CA certificate not trusted
4. Protocol/cipher mismatch in gateway or service mesh

**Resolution:**

1. **Check certificate expiry in gateway/proxy:**
   ```bash
   openssl x509 -in /path/to/cert.pem -noout -dates
   ```
   If expired, rotate certificates (see [Certificate Rotation](operations-runbook.md#gatewayproxy-certificate-rotation)).

2. **Verify hostname/SAN matches exposed endpoint:**
   ```bash
   openssl x509 -in /path/to/cert.pem -noout -text | grep -A1 "Subject Alternative Name"
   ```

3. **Test TLS endpoint directly:**
   ```bash
   openssl s_client -connect node1:3000 -CAfile /path/to/ca.pem
   ```

4. **Check TLS version/cipher compatibility:**
   Ensure client and gateway/proxy settings are aligned.

**Prevention:** Monitor certificate expiry dates. Automate rotation in gateway/mesh control plane. Keep TLS policy managed centrally.

## Performance Issues

### High Latency (P99 > 100ms)

**Symptom:** Request latency exceeds acceptable thresholds.

**Possible Causes:**
1. Disk I/O saturation
2. Compaction running
3. Large batch sizes causing queuing
4. Insufficient memory for block cache

**Resolution:**

1. **Check disk I/O:**
   ```bash
   iostat -x 1 5
   # Look for %util > 80% or high await times
   ```
   If disk saturated, consider faster storage (NVMe).

2. **Check for active compaction:**
   ```bash
   curl -s localhost:9090/metrics | grep archerdb_compaction_active
   curl -s localhost:9090/metrics | grep archerdb_compaction_write_amp
   ```
   Compaction is normal but can cause latency spikes. See [LSM Tuning](lsm-tuning.md).

3. **Reduce batch sizes:**
   Large batches (>5000 events) can cause queuing delays. Optimal range: 500-2000.

4. **Check memory pressure:**
   ```bash
   curl -s localhost:9090/metrics | grep process_resident_memory_bytes
   free -h
   ```
   If memory constrained, increase RAM or reduce entity count.

**Prevention:** Monitor P99 latency trends. Set up alerts at 50ms (warning) and 100ms (critical).

---

### Low Throughput

**Symptom:** Insert or query rate lower than expected.

**Possible Causes:**
1. Connection pool too small
2. Batch sizes too small
3. Client-side bottleneck
4. Network bandwidth limit

**Resolution:**

1. **Increase connection pool:**
   ```python
   client = ArcherDBClient(
       addresses=["node1:3000"],
       pool_size=10  # Increase from default
   )
   ```

2. **Increase batch sizes:**
   ```python
   batch = client.create_batch()
   # Add 1000-5000 events per batch instead of small batches
   for event in events:
       batch.add(event)
   batch.commit()
   ```

3. **Profile client application:**
   Ensure client isn't CPU-bound processing results.

4. **Check network throughput:**
   ```bash
   iperf3 -c node1 -p 5201
   ```

**Prevention:** Benchmark during capacity planning. Monitor throughput metrics over time.

---

### High Memory Usage

**Symptom:** Memory usage approaching limits, potential OOM.

**Possible Causes:**
1. RAM index grown beyond capacity plan
2. Memory leak (rare)
3. Large query result sets in memory

**Resolution:**

1. **Check entity count vs. capacity:**
   ```bash
   curl -s localhost:9090/metrics | grep archerdb_entities_total
   # Compare to capacity plan
   ```
   See [Capacity Planning](capacity-planning.md) for sizing.

2. **Check index load factor:**
   ```bash
   curl -s localhost:9090/metrics | grep archerdb_index_load_factor
   # Should be < 0.7 for optimal performance
   ```

3. **Restart if memory keeps growing (potential leak):**
   ```bash
   systemctl restart archerdb
   # Monitor if issue recurs
   ```

**Prevention:** Set resource limits. Monitor memory usage with alerts at 70% and 85%.

---

### Disk Usage Growing

**Symptom:** Disk usage continuously increasing.

**Possible Causes:**
1. TTL not configured
2. Compaction falling behind
3. High update rate creating versions

**Resolution:**

1. **Check if TTL is configured:**
   ```bash
   ./archerdb info /data/archerdb.db | grep ttl
   ```
   Consider enabling TTL for automatic cleanup.

2. **Check compaction status:**
   ```bash
   curl -s localhost:9090/metrics | grep archerdb_lsm_levels
   curl -s localhost:9090/metrics | grep archerdb_compaction
   ```
   If levels accumulating, compaction may be behind.

3. **Manual compaction:**
   ```bash
   ./archerdb compact /data/archerdb.db
   ```

**Prevention:** Configure TTL appropriate for use case. Monitor disk usage trends.

## Cluster Issues

### Cluster Won't Form Quorum

**Symptom:** Replicas don't elect a primary; cluster unavailable.

**Possible Causes:**
1. Network partition between replicas
2. Clock skew too large
3. Data corruption preventing startup
4. Wrong cluster configuration

**Resolution:**

1. **Test network connectivity between replicas:**
   ```bash
   # From each node, test others
   for node in node1 node2 node3; do
     echo "Testing $node"
     nc -zv $node 3000
   done
   ```

2. **Check clock synchronization:**
   ```bash
   chronyc tracking
   # Or
   timedatectl status
   # Clock skew should be < 100ms
   ```
   If skewed, fix NTP: `systemctl restart chronyd`

3. **Verify data file integrity:**
   ```bash
   ./archerdb verify /data/archerdb.db
   ```
   If corrupted, see [Disaster Recovery](disaster-recovery.md).

4. **Check configuration consistency:**
   Ensure all replicas use same `--addresses` list and `--cluster` ID.

**Prevention:** Monitor clock skew and network connectivity. Use consistent configuration management.

---

### Frequent View Changes

**Symptom:** `archerdb_view_changes_total` incrementing frequently.

**Possible Causes:**
1. Network instability
2. Disk I/O latency causing heartbeat timeouts
3. Resource exhaustion (CPU/memory)

**Resolution:**

1. **Check network stability:**
   ```bash
   # Test packet loss between replicas
   ping -c 100 node2 | grep "packet loss"
   ```

2. **Check disk latency:**
   ```bash
   iostat -x 1 5
   # Check await column - should be < 10ms for SSD
   ```

3. **Check resource usage:**
   ```bash
   top -p $(pgrep archerdb)
   curl -s localhost:9090/metrics | grep process_
   ```

**Prevention:** Use stable network infrastructure. Monitor view change rate. Alert on > 3 changes per 5 minutes.

---

### Replica Falling Behind

**Symptom:** One replica's `archerdb_replication_lag_ms` consistently high.

**Possible Causes:**
1. Slow disk on follower
2. Network congestion to follower
3. Follower under-resourced

**Resolution:**

1. **Check disk performance on lagging replica:**
   ```bash
   ssh lagging-node "iostat -x 1 5"
   ```

2. **Check network path:**
   ```bash
   iperf3 -c lagging-node -p 5201
   mtr lagging-node
   ```

3. **Compare resources:**
   Ensure lagging replica has same CPU/RAM/disk spec as others.

**Prevention:** Use homogeneous hardware. Monitor replication lag per replica.

---

### Split Brain Suspected

**Symptom:** Concern about split brain after network partition.

**Possible Causes:**
This is **not possible** with ArcherDB's Viewstamped Replication (VSR) protocol.

**Explanation:**
- VSR requires a majority (2 of 3, 3 of 5) to commit any operation
- During a partition, only one partition can have a majority
- The minority partition cannot accept writes (returns `cluster_unavailable`)
- When the partition heals, the minority automatically catches up

**Resolution:**

1. **Verify cluster state:**
   ```bash
   # Check each replica's view number
   for node in node1 node2 node3; do
     echo -n "$node view: "
     ssh $node "curl -s localhost:9090/metrics | grep archerdb_view_number"
   done
   ```
   All healthy replicas should have the same view number.

2. **If partitioned now, identify majority:**
   The partition accepting writes has quorum. Wait for network to heal.

**Prevention:** Use reliable network infrastructure. Monitor view numbers across replicas.

## Query Issues

### Radius Query Returns No Results

**Symptom:** Radius query returns empty results when data expected.

**Possible Causes:**
1. Coordinate encoding mismatch (degrees vs. nanodegrees)
2. Query area actually empty
3. Wrong group ID filter
4. Data not yet replicated

**Resolution:**

1. **Verify coordinate encoding:**
   ```python
   # ArcherDB uses nanodegrees internally
   # SDK should handle conversion, but verify:
   lat = 37.7749  # degrees
   lat_nano = 37774900000  # nanodegrees (lat * 1e9)
   ```

2. **Check with broader query:**
   ```python
   # Expand radius to verify data exists
   results = client.query_radius(
       center_lat=37.7749,
       center_lon=-122.4194,
       radius_m=100000  # 100km to find any nearby data
   )
   ```

3. **Verify group ID:**
   ```python
   # Try without group filter
   results = client.query_radius(..., group_id=None)
   ```

4. **Check if data committed:**
   Recent inserts may not be queryable until committed (milliseconds).

**Prevention:** Add unit tests for coordinate encoding. Log query parameters.

---

### Polygon Query Rejects Input

**Symptom:** Polygon query returns "invalid polygon" error.

**Possible Causes:**
1. Wrong winding order (exterior must be counter-clockwise)
2. Self-intersecting polygon
3. Too few vertices (minimum 4 for closed ring)
4. Holes with wrong winding order (must be clockwise)

**Resolution:**

1. **Check winding order:**
   ```python
   # Exterior ring: counter-clockwise
   # Holes: clockwise
   exterior = [
       (-122.4, 37.7),   # Start
       (-122.3, 37.7),   # Go counter-clockwise
       (-122.3, 37.8),
       (-122.4, 37.8),
       (-122.4, 37.7),   # Close the ring
   ]
   ```

2. **Check for self-intersection:**
   Use a GIS tool or library to validate the polygon.

3. **Verify ring closure:**
   First and last vertex must be identical.

**Prevention:** Validate polygons before querying. Use well-known-text (WKT) validation libraries.

---

### Results Seem Incomplete

**Symptom:** Query returns fewer results than expected.

**Possible Causes:**
1. Result limit reached (default: 1000)
2. Pagination required
3. Filter excluding data (group_id, time range)

**Resolution:**

1. **Check for pagination:**
   ```python
   results = client.query_radius(...)
   all_events = results.events

   while results.has_more:
       results = client.query_radius(..., cursor=results.cursor)
       all_events.extend(results.events)

   print(f"Total: {len(all_events)}")
   ```

2. **Increase limit if needed:**
   ```python
   results = client.query_radius(..., limit=10000)  # Max: 10000
   ```

3. **Remove filters to test:**
   Try query without group_id or time constraints.

**Prevention:** Always handle pagination in client code. Log result counts.

## Replication Issues

### S3 Log Shipping Failing

**Symptom:** S3 log-shipping uploads failing; `archerdb_replication_state` shows degraded.

**Possible Causes:**
1. Invalid credentials
2. Bucket permissions
3. Network connectivity to S3
4. S3 service outage

**Resolution:**

1. **Check credentials:**
   ```bash
   # Verify AWS credentials
   aws sts get-caller-identity

   # Test S3 access
   aws s3 ls s3://your-bucket/
   ```

2. **Check bucket policy:**
   Ensure IAM role/user has `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`.

3. **Test network connectivity:**
   ```bash
   curl -I https://s3.amazonaws.com
   # Or your regional endpoint
   ```

4. **Check spillover directory:**
   ```bash
   ls -la /data/spillover/
   # Files here indicate S3 writes are queued
   ```

**Prevention:** Use IAM roles (not keys) on EC2. Monitor replication state metric. Set up S3 bucket notifications.

---

### Replication Lag High

**Symptom:** `archerdb_replication_lag_seconds` consistently elevated.

**Possible Causes:**
1. S3 throttling
2. Network bandwidth limitation
3. High write volume

**Resolution:**

1. **Check for S3 throttling:**
   ```bash
   # Check S3 metrics in CloudWatch for 503 errors
   aws cloudwatch get-metric-statistics \
     --namespace AWS/S3 \
     --metric-name 5xxErrors \
     --dimensions Name=BucketName,Value=your-bucket
   ```

2. **Check upload bandwidth:**
   ```bash
   curl -s localhost:9090/metrics | grep archerdb_replication_bytes
   ```

3. **Consider S3 Transfer Acceleration or multi-region setup.**

**Prevention:** Use appropriate S3 tier. Monitor replication lag with alerts at 30s and 2min.

---

### Spillover Files Growing

**Symptom:** Files accumulating in spillover directory.

**Possible Causes:**
1. S3 outage or prolonged failure
2. Credentials expired
3. Network partition to S3

**Resolution:**

1. **Check S3 connectivity:**
   ```bash
   aws s3 ls s3://your-bucket/
   ```

2. **Check credential expiry:**
   For IAM roles, ensure instance profile is attached.

3. **Monitor spillover directory:**
   ```bash
   du -sh /data/spillover/
   ls -lt /data/spillover/ | head
   ```

4. **When S3 recovers:**
   Spillover files are automatically uploaded in order. Monitor until directory empties.

**Prevention:** Alert on spillover directory size. Use multiple S3 regions for redundancy.

## Data Protection Issues

ArcherDB expects encryption-at-rest and key operations to be managed by storage/cloud infrastructure.

### Storage Encryption Policy Drift

**Symptom:** Security scans report unencrypted volumes/snapshots.

**Possible Causes:**
1. New volume created outside policy
2. Snapshot replication policy disabled
3. Wrong storage class or account defaults

**Resolution:**

1. Verify encryption settings on active data volumes and snapshots.
2. Recreate non-compliant resources with enforced encryption policy.
3. Re-run restore drill from compliant snapshot set.

### External Key Service Issues

**Symptom:** Platform tooling reports KMS/key policy failures.

**Possible Causes:**
1. KMS connectivity or endpoint policy issue
2. IAM permissions drift
3. Key disabled/deleted

**Resolution:**

1. Validate key accessibility with platform tooling.
2. Restore least-privilege IAM/key policies from IaC baseline.
3. Ensure restore pipeline can access required keys before recovery exercises.

## Diagnostic Commands

### Health Checks

```bash
# Quick health check
curl -s localhost:9090/health/live
# Returns: {"status":"ok"}

# Readiness check
curl -s localhost:9090/health/ready
# Returns: {"status":"ready"} or {"status":"not_ready","reason":"..."}

# Detailed health with component status
curl -s localhost:9090/health/detailed | jq .
# Returns component-level health: replica, memory, storage, replication
```

### Metrics Inspection

```bash
# All metrics
curl -s localhost:9090/metrics

# Specific metric patterns
curl -s localhost:9090/metrics | grep archerdb_request_duration
curl -s localhost:9090/metrics | grep archerdb_replication
curl -s localhost:9090/metrics | grep archerdb_compaction
curl -s localhost:9090/metrics | grep process_

# Current connections
curl -s localhost:9090/metrics | grep archerdb_connections

# Entity count
curl -s localhost:9090/metrics | grep archerdb_entities_total
```

### Log Analysis

```bash
# Recent errors
journalctl -u archerdb --since "1 hour ago" | grep -i error

# View changes
journalctl -u archerdb | grep -i "view change"

# Replication events
journalctl -u archerdb | grep -i "replication"

# Connection events
journalctl -u archerdb | grep -i "connection"

# JSON log parsing (if using JSON format)
journalctl -u archerdb -o cat | jq 'select(.level == "error")'
```

### Data File Verification

```bash
# Verify data file integrity
./archerdb verify /data/archerdb.db

# Show data file info
./archerdb info /data/archerdb.db

# Check disk usage
du -sh /data/archerdb.db
df -h /data
```

### Cluster Status

```bash
# Cluster health
./archerdb status --addresses=node1:3000,node2:3000,node3:3000

# Check which replica is primary
curl -s localhost:9090/metrics | grep archerdb_replica_role
# 1 = primary, 0 = follower

# View number (should match across replicas)
curl -s localhost:9090/metrics | grep archerdb_view_number
```

## Getting Help

When the troubleshooting steps above don't resolve your issue, follow these steps to get help.

### Collecting Diagnostic Information

Before reaching out, collect the following:

```bash
# 1. System information
uname -a
cat /etc/os-release

# 2. ArcherDB version
./archerdb --version

# 3. Configuration (redact sensitive values)
cat /etc/archerdb/config.yaml | grep -v password | grep -v key

# 4. Recent logs (last 1000 lines)
journalctl -u archerdb --since "30 minutes ago" | tail -1000 > archerdb-logs.txt

# 5. Metrics snapshot
curl -s localhost:9090/metrics > archerdb-metrics.txt

# 6. Health check details
curl -s localhost:9090/health/detailed | jq . > archerdb-health.json

# 7. Cluster state (if multi-node)
for i in 0 1 2; do
  echo "=== Node $i ===" >> cluster-state.txt
  curl -s node$i:9090/metrics | grep -E "archerdb_(view|replica|replication)" >> cluster-state.txt
done
```

### What to Include in Bug Reports

When opening a GitHub issue, include:

1. **Environment**: OS, ArcherDB version, hardware specs (CPU, RAM, disk type)
2. **Configuration**: Cluster size, relevant config settings
3. **Reproduction steps**: Exact sequence to reproduce the issue
4. **Expected behavior**: What should happen
5. **Actual behavior**: What actually happens
6. **Logs**: Relevant log snippets (redact sensitive data)
7. **Metrics**: Relevant metric values at time of issue

### Support Channels

| Channel | Best For | Response Time |
|---------|----------|---------------|
| [GitHub Issues](https://github.com/ArcherDB-io/archerdb/issues) | Bug reports, feature requests | Community: 1-7 days |
| [GitHub Discussions](https://github.com/ArcherDB-io/archerdb/discussions) | Questions, best practices | Community: 1-3 days |
| Documentation | Self-service troubleshooting | Immediate |

### Emergency Procedures

For production emergencies:

1. **Data loss suspected**: Stop writes, capture external snapshot, preserve logs
2. **Cluster unavailable**: Check quorum (need 2/3 or 3/5 replicas)
3. **Security incident**: Isolate affected nodes, preserve evidence, rotate credentials

See [Disaster Recovery](disaster-recovery.md) for emergency procedures.

## Related Documentation

- [Operations Runbook](operations-runbook.md) - Operational procedures
- [Disaster Recovery](disaster-recovery.md) - Recovery procedures
- [Error Codes Reference](error-codes.md) - Complete error code list
- [Capacity Planning](capacity-planning.md) - Sizing guidance
- [LSM Tuning](lsm-tuning.md) - Storage performance tuning
- [Performance Tuning](performance-tuning.md) - Optimization guide
