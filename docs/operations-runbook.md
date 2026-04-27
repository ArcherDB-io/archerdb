# Operations Runbook

This runbook provides operational procedures for running ArcherDB in production.

## Table of Contents

- [Cluster Management](#cluster-management)
- [Monitoring](#monitoring)
- [Alerting](#alerting)
- [Alert Response Guides](#alert-response-guides)
- [Scaling](#scaling)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Upgrade Procedures](#upgrade-procedures)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)
- [Emergency Procedures](#emergency-procedures)
- [Related Documentation](#related-documentation)

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

### Cluster Membership Boundary

Use `cluster status` to inspect the current static membership:

```bash
# Show membership status
./archerdb cluster status --addresses=node1:3000,node2:3000,node3:3000 --cluster=12345
```

Notes:
- The public `archerdb cluster` CLI currently supports `status` only; membership mutation remains an external orchestration concern.
- Cluster membership is fixed by the startup `--addresses` set.
- To change the node set, provision a replacement cluster with the desired addresses and perform a controlled migration or restore/cutover.

### Coordinator Mode (Multi-Shard Routing)

Run the coordinator when clients need a single endpoint for multi-shard queries:

```bash
# Start with explicit shard list
./archerdb coordinator start \
  --bind=0.0.0.0:5000 \
  --shards=10.0.0.1:3000,10.0.0.2:3000

# Or start with topology discovery
./archerdb coordinator start --seed-nodes=10.0.0.1:3000 --bind=0.0.0.0:5000

# Check status / stop
./archerdb coordinator status --address=127.0.0.1:5000 --format=json
./archerdb coordinator stop --address=127.0.0.1:5000 --timeout=60
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

## Alert Response Guides

When Prometheus alerts fire, use these runbooks for investigation and resolution. Each runbook provides:
- Quick reference (severity, metric, threshold)
- Immediate action checklists
- Investigation steps with diagnostic commands
- Resolution procedures for common causes
- Prevention guidelines

### Alert to Runbook Mapping

| Alert | Severity | Runbook |
|-------|----------|---------|
| ArcherDBReplicaDown | critical | [Replica Down](runbooks/replica-down.md) |
| ArcherDBViewChangeFrequent | warning | [View Changes](runbooks/view-changes.md) |
| ArcherDBIndexDegraded | critical | [Index Degraded](runbooks/index-degraded.md) |
| ArcherDBReadLatencyP99Warning | warning | [High Read Latency](runbooks/high-read-latency.md) |
| ArcherDBReadLatencyP99Critical | critical | [High Read Latency](runbooks/high-read-latency.md) |
| ArcherDBWriteLatencyP99Warning | warning | [High Write Latency](runbooks/high-write-latency.md) |
| ArcherDBWriteLatencyP99Critical | critical | [High Write Latency](runbooks/high-write-latency.md) |
| ArcherDBHighLatency | warning | [High Write Latency](runbooks/high-write-latency.md) |
| ArcherDBDiskSpaceWarning | warning | [Disk Capacity](runbooks/disk-capacity.md) |
| ArcherDBDiskSpaceCritical | critical | [Disk Capacity](runbooks/disk-capacity.md) |
| ArcherDBCompactionBacklog | warning | [Compaction Backlog](runbooks/compaction-backlog.md) |
| ArcherDBDiskFillPrediction24h | warning | [Disk Capacity](runbooks/disk-capacity.md) |
| ArcherDBDiskFillPrediction6h | critical | [Disk Capacity](runbooks/disk-capacity.md) |

### Alert Severity Response Times

| Severity | Response Time | Example Alerts |
|----------|---------------|----------------|
| critical | 15 minutes | ReplicaDown, DiskSpaceCritical, IndexDegraded |
| warning | 1 hour | ViewChangeFrequent, LatencyWarning, CompactionBacklog |

### Quick Triage

When an alert fires:

1. **Check alert severity** - Critical alerts need immediate attention
2. **Open the runbook** - Click the runbook_url in the alert annotation
3. **Follow Immediate Actions** - Complete the checklist in order
4. **Investigate** - Use diagnostic commands to identify root cause
5. **Resolve** - Follow resolution steps for the identified cause
6. **Document** - Record what happened and any changes made

## Scaling

### Vertical Scaling

ArcherDB benefits from:
- **More RAM**: Larger block cache, more in-flight requests
- **Faster SSD**: NVMe recommended for production
- **More CPU cores**: Better concurrent request handling

### Sharding Strategy Selection

Choose a sharding strategy at cluster initialization:

```bash
./archerdb format --cluster=12345 --replica=0 --replica-count=3 \
  --sharding-strategy=jump_hash /data/archerdb.db
```

Trade-offs:
- **jump_hash (default)**: Uniform distribution, minimal movement on reshard, no extra memory.
- **virtual_ring**: Supports weighted shards and uneven capacity, but adds lookup overhead and memory.
- **modulo**: Legacy, power-of-2 only, ~50% movement on reshard.
- **spatial**: Optimizes radius/polygon fan-out but adds two-hop entity lookups; best when spatial queries dominate.

Use `./archerdb info /data/archerdb.db` to verify the configured strategy.

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

## Kubernetes Deployment

Deploy ArcherDB on Kubernetes using StatefulSets for stable network identities and persistent storage.

### Prerequisites

- Kubernetes 1.24 or later
- `kubectl` configured with cluster access
- A StorageClass supporting `ReadWriteOnce` volumes (e.g., `gp3` on AWS, `pd-ssd` on GCP)
- Network policy allowing inter-pod communication on port 3000

### StatefulSet Deployment

Create a namespace and deploy the ArcherDB cluster:

```bash
kubectl create namespace archerdb
```

**ConfigMap for cluster addresses:**

```yaml
# archerdb-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: archerdb-config
  namespace: archerdb
data:
  ADDRESSES: "archerdb-0.archerdb-headless.archerdb.svc.cluster.local:3000,archerdb-1.archerdb-headless.archerdb.svc.cluster.local:3000,archerdb-2.archerdb-headless.archerdb.svc.cluster.local:3000"
```

**Headless Service for stable DNS:**

```yaml
# archerdb-headless.yaml
apiVersion: v1
kind: Service
metadata:
  name: archerdb-headless
  namespace: archerdb
  labels:
    app: archerdb
spec:
  ports:
    - port: 3000
      name: archerdb
    - port: 9090
      name: metrics
  clusterIP: None
  selector:
    app: archerdb
```

**StatefulSet with 3 replicas:**

```yaml
# archerdb-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: archerdb
  namespace: archerdb
spec:
  serviceName: archerdb-headless
  replicas: 3
  selector:
    matchLabels:
      app: archerdb
  template:
    metadata:
      labels:
        app: archerdb
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: archerdb
                topologyKey: kubernetes.io/hostname
      containers:
        - name: archerdb
          image: archerdb/archerdb:latest
          ports:
            - containerPort: 3000
              name: archerdb
            - containerPort: 9090
              name: metrics
          envFrom:
            - configMapRef:
                name: archerdb-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          command:
            - /bin/sh
            - -c
            - |
              REPLICA_INDEX=${POD_NAME##*-}
              ./archerdb start \
                --addresses=$ADDRESSES \
                --replica=$REPLICA_INDEX \
                /data/archerdb.db
          resources:
            requests:
              memory: "2Gi"
              cpu: "1"
            limits:
              memory: "4Gi"
              cpu: "2"
          volumeMounts:
            - name: data
              mountPath: /data
          livenessProbe:
            httpGet:
              path: /health/live
              port: 9090
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 9090
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
```

**Deploy the manifests:**

```bash
kubectl apply -f archerdb-config.yaml
kubectl apply -f archerdb-headless.yaml
kubectl apply -f archerdb-statefulset.yaml
```

### Verification

```bash
# Check pod status
kubectl get pods -n archerdb -w

# Expected output after ~60 seconds:
# archerdb-0   1/1     Running   0          45s
# archerdb-1   1/1     Running   0          30s
# archerdb-2   1/1     Running   0          15s

# Check logs for cluster formation
kubectl logs -n archerdb archerdb-0 | grep -i "quorum"

# Verify cluster health
kubectl exec -n archerdb archerdb-0 -- curl -s localhost:9090/health/detailed

# Check metrics
kubectl exec -n archerdb archerdb-0 -- curl -s localhost:9090/metrics | grep archerdb_replica_role
```

### Client Service

Expose ArcherDB to clients within the cluster:

```yaml
# archerdb-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: archerdb
  namespace: archerdb
spec:
  ports:
    - port: 3000
      name: archerdb
  selector:
    app: archerdb
```

Clients connect to `archerdb.archerdb.svc.cluster.local:3000`.

### Notes

- **Helm charts:** For Helm-based deployment, see future releases.
- **Operator:** A Kubernetes Operator for automated cluster management is planned for future releases.
- For capacity planning in Kubernetes, see [docs/capacity-planning.md](capacity-planning.md).

## Upgrade Procedures

Upgrade ArcherDB without downtime using rolling upgrades. This section covers version upgrades, not configuration changes (see [Rolling Restart](#rolling-restart) for config updates).

### Pre-Upgrade Checklist

Before any upgrade:

- [ ] Read the [CHANGELOG](CHANGELOG.md) for breaking changes
- [ ] Verify current cluster health: `./archerdb status --addresses=$ADDRESSES`
- [ ] Check all replicas are healthy: `curl localhost:9090/health/detailed` on each
- [ ] Trigger external snapshot/backup workflow for all replica volumes
- [ ] Verify snapshot replication and retention policy status
- [ ] Test the new version in a staging environment
- [ ] Schedule maintenance window (upgrades are non-disruptive but allow buffer time)

### Version Compatibility Matrix

| From Version | To Version | Upgrade Path | Notes |
|--------------|------------|--------------|-------|
| 1.x.y | 1.x.z | Direct | Patch upgrades always supported |
| 1.x.y | 1.(x+1).0 | Direct | Minor upgrades always supported |
| 1.x.y | 2.0.0 | Via 1.latest | Upgrade to latest 1.x first |

**Wire protocol compatibility:**
- Minor version upgrades maintain wire protocol compatibility
- Major version upgrades may require all replicas to upgrade together

### Rolling Upgrade Procedure

**1. Identify current primary:**

```bash
# Check which replica is primary
for node in node1 node2 node3; do
  echo -n "$node: "
  ssh $node "curl -s localhost:9090/metrics | grep archerdb_replica_role"
done
```

**2. Upgrade followers first (one at a time):**

```bash
# On each follower node:
# a. Stop the replica
systemctl stop archerdb

# b. Replace the binary
mv /usr/local/bin/archerdb /usr/local/bin/archerdb.old
cp /path/to/new/archerdb /usr/local/bin/archerdb
chmod +x /usr/local/bin/archerdb

# c. Start the replica
systemctl start archerdb

# d. Wait for replica to catch up
while true; do
  lag=$(curl -s localhost:9090/metrics | grep 'archerdb_replication_lag_ms' | awk '{print $2}')
  if [ "$lag" -lt 100 ]; then
    echo "Replica caught up (lag: ${lag}ms)"
    break
  fi
  echo "Waiting for catch-up (lag: ${lag}ms)..."
  sleep 5
done
```

**3. Verify cluster health after each follower:**

```bash
# Check quorum is maintained
./archerdb status --addresses=$ADDRESSES

# Check no errors in logs
journalctl -u archerdb --since "5 minutes ago" | grep -i error
```

**4. Upgrade the primary last:**

```bash
# On primary node:
# This triggers a view change - new primary elected from upgraded followers
systemctl stop archerdb

# Replace binary
mv /usr/local/bin/archerdb /usr/local/bin/archerdb.old
cp /path/to/new/archerdb /usr/local/bin/archerdb
chmod +x /usr/local/bin/archerdb

# Start - will rejoin as follower initially
systemctl start archerdb
```

### Kubernetes Rolling Upgrade

```bash
# Update the image tag
kubectl set image statefulset/archerdb \
  archerdb=archerdb/archerdb:v1.2.0 \
  -n archerdb

# Watch rollout progress
kubectl rollout status statefulset/archerdb -n archerdb

# Kubernetes upgrades pods in reverse order (archerdb-2, then archerdb-1, then archerdb-0)
# ensuring followers upgrade before the primary
```

### Post-Upgrade Verification

After all replicas upgraded:

- [ ] All replicas running new version: `./archerdb version` on each node
- [ ] Cluster health normal: `./archerdb status --addresses=$ADDRESSES`
- [ ] Replication lag minimal: Check `archerdb_replication_lag_ms` metric
- [ ] No errors in logs: `journalctl -u archerdb --since "30 minutes ago" | grep -i error`
- [ ] Run smoke test queries through client
- [ ] Monitoring dashboards show expected behavior

### Rollback Procedure

If issues occur during upgrade:

**1. Stop the problematic replica:**

```bash
systemctl stop archerdb
```

**2. Restore the old binary:**

```bash
mv /usr/local/bin/archerdb.old /usr/local/bin/archerdb
```

**3. Start with old version:**

```bash
systemctl start archerdb
```

**4. For Kubernetes rollback with your deployment tooling:**

```bash
kubectl rollout undo statefulset/archerdb -n archerdb
```

**If external rollback fails or data corruption is suspected:**
See [Disaster Recovery Procedures](disaster-recovery.md) for external snapshot restoration.

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

### Performance Validation

Run periodic performance validation and keep a baseline for regressions:

```bash
# Start a local single-node cluster
./scripts/dev-cluster.sh start --nodes=1 --clean

# Built-in benchmark driver (smoke-scale settings)
./archerdb benchmark --cluster=0 --addresses=127.0.0.1:3001 --events=10000 --batch-size=500

# Multi-language benchmark suite (writes summary CSV)
./scripts/run_benchmarks.sh --events 10000 --batch-size 500 --cluster 127.0.0.1:3001

# Save a baseline for future comparison
cp benchmark-results/summary_*.csv benchmark-results/baseline.csv
```

The benchmark summary is stored under `benchmark-results/` and can be compared to a baseline
by re-running the script with `--baseline benchmark-results/baseline.csv`.

### Gateway/Proxy Certificate Rotation

```bash
# 1. Deploy new certificates alongside old ones
# 2. Update config to use new certificates
# 3. Rolling restart all replicas
# 4. Remove old certificates
```

## Troubleshooting

This section covers quick troubleshooting tips. For comprehensive diagnosis and resolution procedures, see the [Troubleshooting Guide](troubleshooting.md).

### Connection Issues

**Symptom**: Clients can't connect

**Checklist**:
1. Check server is running: `systemctl status archerdb`
2. Check port is open: `netstat -tlnp | grep 3000`
3. Check firewall rules: `iptables -L -n`
4. Check gateway/proxy TLS certificates (if applicable)
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

## Related Documentation

### Core Operations

| Document | Description |
|----------|-------------|
| [Troubleshooting Guide](troubleshooting.md) | Comprehensive diagnosis and resolution procedures |
| [Capacity Planning](capacity-planning.md) | Sizing guidelines for hardware and configuration |
| [LSM Tuning](lsm-tuning.md) | Storage engine performance optimization |

### Backup and Recovery

ArcherDB has built-in backup upload to local filesystem, S3 (or S3-compatible
providers — MinIO, R2, Backblaze, LocalStack), GCS via interop, and Azure Blob
Storage. Enable at startup:

```bash
archerdb start \
  --backup-enabled \
  --backup-provider=s3 \
  --backup-region=us-east-1 \
  --backup-bucket=my-archerdb-backups \
  data.archerdb
```

S3 / GCS / Azure each accept their own endpoint, credential, and `url-style`
flags — see [Backup Operations](backup-operations.md) for the full per-provider
matrix. Restore via `archerdb restore` from any supported provider.

Monitor backup health via the metrics endpoint:

- `archerdb_backup_blocks_uploaded_total` — cumulative blocks durably uploaded.
- `archerdb_backup_lag_blocks` — pending block uploads.
- `archerdb_backup_failures_total` — upload failures.
- `archerdb_storage_space_exhausted` — gauge that flips to 1 when the replica
  is currently rejecting client writes due to a recent storage capacity event.

Platform snapshots remain available as defense-in-depth alongside the built-in
path.

| Document | Description |
|----------|-------------|
| [Backup Operations](backup-operations.md) | Built-in providers, credentials, retention, external snapshot procedures |
| [Disaster Recovery](disaster-recovery.md) | DR planning, RTO/RPO targets, recovery procedures |
| [Upgrade Guide](upgrade-guide.md) | Rolling upgrade procedures, external rollback planning, health checks |

### Alert Runbooks

| Runbook | Alerts Covered |
|---------|----------------|
| [Replica Down](runbooks/replica-down.md) | ArcherDBReplicaDown |
| [View Changes](runbooks/view-changes.md) | ArcherDBViewChangeFrequent |
| [Index Degraded](runbooks/index-degraded.md) | ArcherDBIndexDegraded |
| [High Read Latency](runbooks/high-read-latency.md) | ArcherDBReadLatencyP99Warning/Critical |
| [High Write Latency](runbooks/high-write-latency.md) | ArcherDBWriteLatencyP99Warning/Critical, ArcherDBHighLatency |
| [Disk Capacity](runbooks/disk-capacity.md) | ArcherDBDiskSpaceWarning/Critical, ArcherDBDiskFillPrediction |
| [Compaction Backlog](runbooks/compaction-backlog.md) | ArcherDBCompactionBacklog |
