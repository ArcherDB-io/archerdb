# Operations Runbook

This runbook provides operational procedures for running ArcherDB in production.

## Table of Contents

- [Cluster Management](#cluster-management)
- [Monitoring](#monitoring)
- [Alerting](#alerting)
- [Scaling](#scaling)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)
- [Emergency Procedures](#emergency-procedures)

## Cluster Management

### Starting a Cluster

#### Single Node (Development)

```bash
# Format data file
./archerdb format --cluster=0 --replica=0 --replica-count=1 /data/archerdb.db

# Start server
./archerdb start --addresses=3000 /data/archerdb.db
```

#### Production Cluster (3 Nodes)

Start replicas in any order - they will discover each other and elect a primary.

```bash
# All nodes use the same addresses list
ADDRESSES="node1:3000,node2:3000,node3:3000"

# Node 1 (replica 0)
./archerdb start --addresses=$ADDRESSES /data/archerdb.db

# Node 2 (replica 1)
./archerdb start --addresses=$ADDRESSES /data/archerdb.db

# Node 3 (replica 2)
./archerdb start --addresses=$ADDRESSES /data/archerdb.db
```

### Stopping a Cluster

**Graceful Shutdown:**
```bash
# Send SIGTERM to each replica
kill -TERM $(pidof archerdb)

# Or use systemd
systemctl stop archerdb
```

**Order doesn't matter** - replicas handle shutdown gracefully and will sync on restart.

### Checking Cluster Status

```bash
# Check if process is running
systemctl status archerdb

# Check cluster health via client
./archerdb client ping --addresses=node1:3000,node2:3000,node3:3000
```

## Monitoring

### Key Metrics

#### Throughput Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| `archerdb_operations_total{op="insert"}` | Insert operations/sec | < 10,000/s per replica |
| `archerdb_operations_total{op="query"}` | Query operations/sec | Application-dependent |
| `archerdb_batch_size` | Events per batch | 500-5000 optimal |

#### Latency Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| `archerdb_request_duration_seconds{quantile="0.99"}` | P99 latency | < 50ms |
| `archerdb_request_duration_seconds{quantile="0.5"}` | P50 latency | < 5ms |
| `archerdb_replication_lag_ms` | Follower lag | < 100ms |

#### Resource Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| `archerdb_disk_usage_bytes` | Data file size | < 80% of disk |
| `archerdb_memory_usage_bytes` | Memory usage | < 80% of RAM |
| `archerdb_connections_active` | Active clients | < pool_size × clients |

#### Consensus Metrics

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `archerdb_view_changes_total` | Leader elections | > 0 in 5min |
| `archerdb_primary_changes_total` | Primary switches | > 1/hour |
| `archerdb_commit_latency_ms` | Consensus latency | > 100ms |

### Prometheus Configuration

```yaml
scrape_configs:
  - job_name: 'archerdb'
    static_configs:
      - targets:
        - node1:9090
        - node2:9090
        - node3:9090
    metrics_path: /metrics
    scrape_interval: 15s
```

### Grafana Dashboards

Import the recommended dashboards:
- **Cluster Overview**: Throughput, latency, resource usage
- **Replication Status**: View changes, commit latency, follower lag
- **Client Metrics**: Connection counts, retry rates, errors

## Alerting

### Critical Alerts

```yaml
# Cluster Unavailable
- alert: ArcherDBClusterDown
  expr: sum(up{job="archerdb"}) < 2
  for: 30s
  labels:
    severity: critical
  annotations:
    summary: "ArcherDB cluster has lost quorum"
    description: "Less than 2 of 3 replicas are healthy"

# Disk Space Critical
- alert: ArcherDBDiskCritical
  expr: archerdb_disk_usage_bytes / archerdb_disk_total_bytes > 0.9
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "ArcherDB disk usage > 90%"

# High Latency
- alert: ArcherDBHighLatency
  expr: histogram_quantile(0.99, archerdb_request_duration_seconds) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "ArcherDB P99 latency > 100ms"
```

### Warning Alerts

```yaml
# Frequent View Changes
- alert: ArcherDBViewChanges
  expr: increase(archerdb_view_changes_total[5m]) > 3
  labels:
    severity: warning
  annotations:
    summary: "Frequent leader elections detected"

# Client Retry Rate High
- alert: ArcherDBHighRetryRate
  expr: rate(archerdb_client_retries_total[5m]) > 10
  labels:
    severity: warning
  annotations:
    summary: "High client retry rate"

# Replication Lag
- alert: ArcherDBReplicationLag
  expr: archerdb_replication_lag_ms > 1000
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Follower replication lag > 1s"
```

## Scaling

### Vertical Scaling

ArcherDB benefits from:
- **More RAM**: Larger block cache, more in-flight requests
- **Faster SSD**: NVMe recommended for production
- **More CPU cores**: Better concurrent request handling

### Horizontal Scaling (Read Replicas)

For read-heavy workloads, add read replicas:

```bash
# Add a read-only replica (replica 3 in a 3-node write cluster)
./archerdb format --cluster=12345 --replica=3 --replica-count=5 /data/archerdb.db
./archerdb start --addresses=$ADDRESSES --read-only /data/archerdb.db
```

**Note**: Read replicas don't participate in consensus and may have slight lag.

### Client-Side Scaling

- **Connection pooling**: Use `pool_size > 1` for high-throughput clients
- **Batch sizing**: Larger batches (1000-5000) improve throughput
- **Multiple clients**: Distribute load across client instances

## Maintenance

### Rolling Restart

To update ArcherDB without downtime:

```bash
# 1. Restart one replica at a time
# Start with followers, primary last

# Stop replica 2 (follower)
ssh node3 "systemctl stop archerdb"
ssh node3 "systemctl start archerdb"
# Wait for replica to catch up (check replication_lag_ms)

# Stop replica 1 (follower)
ssh node2 "systemctl stop archerdb"
ssh node2 "systemctl start archerdb"
# Wait for replica to catch up

# Stop replica 0 (primary)
# This triggers view change - new primary elected
ssh node1 "systemctl stop archerdb"
ssh node1 "systemctl start archerdb"
```

### Data File Maintenance

```bash
# Check data file integrity
./archerdb verify /data/archerdb.db

# Compact data file (reduces disk usage)
./archerdb compact /data/archerdb.db
```

### Certificate Rotation (mTLS)

```bash
# 1. Deploy new certificates alongside old ones
# 2. Update config to use new certificates
# 3. Rolling restart all replicas
# 4. Remove old certificates
```

## Troubleshooting

### Connection Issues

**Symptom**: Clients can't connect

**Checklist**:
1. Check server is running: `systemctl status archerdb`
2. Check port is open: `netstat -tlnp | grep 3000`
3. Check firewall rules: `iptables -L -n`
4. Check TLS certificates (if using mTLS)
5. Verify cluster_id matches between client and server

### High Latency

**Symptom**: P99 latency > 100ms

**Checklist**:
1. Check disk I/O: `iostat -x 1`
2. Check for view changes: `curl localhost:9090/metrics | grep view_changes`
3. Check replication lag: `curl localhost:9090/metrics | grep replication_lag`
4. Check batch sizes (too small = overhead, too large = queuing)
5. Check if compaction is running

### Cluster Won't Start

**Symptom**: Replicas won't form quorum

**Checklist**:
1. Verify all replicas use same cluster_id
2. Check network connectivity between nodes
3. Check for clock skew: `chronyc tracking`
4. Verify data files aren't corrupted: `./archerdb verify`
5. Check logs for specific errors

### Out of Disk Space

**Symptom**: Writes failing with "out of space"

**Immediate Actions**:
1. Check disk usage: `df -h`
2. Identify largest files: `du -sh /data/*`
3. If TTL is configured, wait for expiration
4. Run compaction: `./archerdb compact`
5. Add disk capacity or archive old data

### Split Brain Prevention

ArcherDB uses Viewstamped Replication which **prevents split brain by design**:
- Requires majority (2 of 3) to commit
- No "split brain" possible with proper configuration

If replicas are partitioned:
- Majority partition continues operating
- Minority partition rejects writes (returns `cluster_unavailable`)
- After partition heals, minority catches up automatically

## Emergency Procedures

### Cluster Recovery from Total Failure

If all replicas fail simultaneously:

```bash
# 1. Stop all replicas
systemctl stop archerdb  # on all nodes

# 2. Verify data files
./archerdb verify /data/archerdb.db  # on all nodes

# 3. Start the replica with the most recent data first
# Check timestamps in logs or data file metadata

# 4. Start remaining replicas - they will sync from the first one
```

### Recovering from Corrupted Replica

```bash
# 1. Stop the corrupted replica
systemctl stop archerdb

# 2. Remove corrupted data file
mv /data/archerdb.db /data/archerdb.db.corrupted

# 3. Re-format and rejoin cluster
./archerdb format --cluster=12345 --replica=N --replica-count=3 /data/archerdb.db
systemctl start archerdb

# 4. Replica will sync from healthy replicas
```

### Emergency Cluster Shutdown

```bash
# If immediate shutdown is required
# (e.g., security incident, runaway process)

# Send SIGKILL to all replicas
pkill -9 archerdb

# Note: This may leave some operations uncommitted
# but data integrity is preserved due to write-ahead logging
```

## Contact and Escalation

| Issue Type | Contact | SLA |
|------------|---------|-----|
| Cluster unavailable | On-call | 15 min response |
| High latency | On-call | 1 hour response |
| Disk space | Team lead | 4 hour response |
| Security incident | Security team | Immediate |

## Appendix: Common Commands

```bash
# Check cluster health
./archerdb status --addresses=node1:3000

# List active sessions
./archerdb sessions --addresses=node1:3000

# Force leader election (use with caution)
./archerdb step-down --addresses=primary:3000

# Export metrics snapshot
curl -s localhost:9090/metrics > metrics-$(date +%Y%m%d).prom
```
