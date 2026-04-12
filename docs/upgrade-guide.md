# ArcherDB Upgrade Guide

This guide provides procedures for safely upgrading ArcherDB clusters with minimal downtime, using `archerdb upgrade` for status and dry-run planning and your deployment tooling for live rollout and rollback.

## Table of Contents

- [Overview](#overview)
- [Pre-Upgrade Checklist](#pre-upgrade-checklist)
- [Version Compatibility](#version-compatibility)
- [Upgrade Procedures](#upgrade-procedures)
  - [Bare Metal Upgrade](#bare-metal-upgrade)
  - [Kubernetes Upgrade](#kubernetes-upgrade)
- [Health-Based Planning Thresholds](#health-based-planning-thresholds)
- [External Rollback](#external-rollback)
- [Post-Upgrade Verification](#post-upgrade-verification)
- [Troubleshooting](#troubleshooting)
- [CLI Reference](#cli-reference)

## Overview

ArcherDB upgrades follow a **rolling upgrade** philosophy designed for zero-downtime deployments:

1. **One node at a time** - Never upgrade multiple replicas simultaneously
2. **Followers first, primary last** - Minimizes disruption to write operations
3. **Health-based rollback planning** - Thresholds for your deployment tooling to decide when to stop or roll back
4. **Version compatibility** - Backwards-compatible data format between versions

### Upgrade Order

The upgrade process follows this strict order:

```
1. Identify primary replica
2. For each follower replica:
   a. Upgrade the follower
   b. Wait for catch-up (replication lag < threshold)
   c. Verify health checks pass
   d. Continue to next follower
3. Upgrade primary last
4. Verify cluster health
```

This order ensures:
- Quorum is maintained throughout the upgrade
- Write availability is preserved until the final step
- External deployment tooling can roll back to the previous version if issues occur

## Pre-Upgrade Checklist

Before starting any upgrade, complete this checklist:

### Required Checks

- [ ] **Review CHANGELOG** for breaking changes between your current version and target version
- [ ] **Verify external snapshots are recent** - Ensure snapshot jobs completed within acceptable RPO (see [backup-operations.md](backup-operations.md))
- [ ] **Test snapshot restore** - Verify external restore works in a test environment
- [ ] **Check cluster health** - All replicas must be healthy before upgrade
  ```bash
  archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000
  ```
- [ ] **Test in staging** - Run the new version in a staging environment first
- [ ] **Verify disk space** - Ensure at least 20% free disk space on all nodes
- [ ] **Check memory** - Ensure RAM requirements are met for new version

### Recommended Checks

- [ ] **Schedule maintenance window** - Plan for potential rollback time
- [ ] **Notify stakeholders** - Alert users about potential brief interruptions
- [ ] **Review monitoring dashboards** - Know baseline metrics before upgrade
- [ ] **Prepare external rollback procedure** - Have service-manager or orchestrator rollback steps ready
- [ ] **Document current versions** - Record exact versions on each node

### Pre-Upgrade Health Check

Run this command to verify cluster readiness:

```bash
# Check cluster status and identify primary
archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000

# Expected output shows:
# - All replicas healthy
# - Primary identified
# - Replication lag < 100ms
```

## Version Compatibility

ArcherDB follows the **TigerBeetle model** for version compatibility:

### Upgrade Rules

1. **Sequential upgrades**: Each version specifies the oldest compatible source version
2. **Skip versions**: May require intermediate upgrades (check CHANGELOG)
3. **Data format**: Backwards compatible within major versions
4. **Wire protocol**:
   - Minor versions (1.x.y -> 1.x.z): Always compatible
   - Major versions (1.x -> 2.x): May require simultaneous upgrade

### Checking Compatibility

```bash
# Check current versions
archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000

# Dry-run to check compatibility
archerdb upgrade start --addresses=node1:3000,node2:3000,node3:3000 \
  --target-version=1.2.0 --dry-run
```

### Version Compatibility Matrix

| From Version | To Version | Compatible | Notes |
|-------------|------------|------------|-------|
| 1.0.x | 1.1.x | Yes | Direct upgrade supported |
| 1.1.x | 1.2.x | Yes | Direct upgrade supported |
| 1.0.x | 1.2.x | Yes | May upgrade directly or via 1.1.x |
| 1.x | 2.0 | Check | Review CHANGELOG for breaking changes |

## Upgrade Procedures

### Bare Metal Upgrade

#### Step 1: Verify Current State

```bash
# Check cluster health and identify primary
archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000

# Record output showing:
# - Primary: node1:3000 (replica 0)
# - Followers: node2:3000, node3:3000
# - All replicas: healthy
```

#### Step 2: Download New Binary

```bash
# On each node, download the new version
wget https://releases.archerdb.io/v1.2.0/archerdb-linux-amd64
chmod +x archerdb-linux-amd64
```

#### Step 3: Upgrade Followers (One at a Time)

For each follower node (NOT the primary):

```bash
# On follower node (e.g., node2)

# 1. Stop the current process gracefully
systemctl stop archerdb
# Or: kill -TERM $(pidof archerdb)

# 2. Replace the binary
mv /usr/local/bin/archerdb /usr/local/bin/archerdb.bak
mv archerdb-linux-amd64 /usr/local/bin/archerdb

# 3. Start with new version
systemctl start archerdb

# 4. Wait for catch-up and health check
# Monitor logs for "replication caught up" message
journalctl -u archerdb -f
```

After each follower upgrade, verify:

```bash
# Check follower is healthy and caught up
archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000

# Expected: follower shows new version, healthy, low replication lag
```

#### Step 4: Upgrade Primary Last

```bash
# On primary node (node1)

# 1. Stop primary (triggers leader election among upgraded followers)
systemctl stop archerdb

# 2. Replace binary
mv /usr/local/bin/archerdb /usr/local/bin/archerdb.bak
mv archerdb-linux-amd64 /usr/local/bin/archerdb

# 3. Start with new version
systemctl start archerdb

# 4. Verify new primary elected and old primary rejoins as follower
archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000
```

### Kubernetes Upgrade

For Kubernetes deployments, upgrades are managed through StatefulSet image updates.
The ArcherDB CLI provides monitoring and guidance.

#### Step 1: Check Current State

```bash
# Check cluster status
archerdb upgrade status --addresses=archerdb-0:3000,archerdb-1:3000,archerdb-2:3000

# Check current image
kubectl get statefulset archerdb -n archerdb -o jsonpath='{.spec.template.spec.containers[0].image}'
```

#### Step 2: Update Image Tag

```bash
# Update the image tag
kubectl set image statefulset/archerdb \
  archerdb=archerdb/archerdb:v1.2.0 \
  -n archerdb
```

#### Step 3: Watch Rolling Update

Kubernetes StatefulSet performs a rolling update automatically:

```bash
# Watch rollout progress
kubectl rollout status statefulset/archerdb -n archerdb

# Monitor pod restarts
kubectl get pods -n archerdb -w

# Check upgrade status via CLI
archerdb upgrade status --addresses=archerdb-0:3000,archerdb-1:3000,archerdb-2:3000
```

#### Step 4: Verify Completion

```bash
# Verify all pods running new version
kubectl get pods -n archerdb -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Verify cluster health
archerdb upgrade status --addresses=archerdb-0:3000,archerdb-1:3000,archerdb-2:3000
```

### Using the Upgrade CLI

The upgrade CLI provides status inspection and dry-run planning. The live rollout is still performed by your external deployment tooling:

```bash
# Dry-run first to see the upgrade plan
archerdb upgrade start --addresses=node1:3000,node2:3000,node3:3000 \
  --target-version=1.2.0 --dry-run

# Generate a dry-run plan with custom thresholds
archerdb upgrade start --addresses=node1:3000,node2:3000,node3:3000 \
  --target-version=1.2.0 \
  --p99-threshold-x10=30 \      # 3.0x baseline triggers rollback
  --error-threshold-x10=5 \      # 0.5% error rate triggers rollback
  --catchup-timeout=600          # 10 minute catchup timeout
```

Use the resulting plan to drive a follower-first rollout in your service manager, Kubernetes controller, or other deployment system.

## Health-Based Planning Thresholds

ArcherDB evaluates these thresholds during dry-run planning and live status checks. Actual rollback is performed by your deployment tooling.

### Rollout Risk Triggers

Treat any of these conditions as rollout blockers:

| Condition | Default Threshold | Description |
|-----------|------------------|-------------|
| **Readiness probe failure** | 3 consecutive failures | Replica health endpoint returns non-200 |
| **P99 latency spike** | 2x baseline | P99 latency exceeds double pre-upgrade baseline |
| **Absolute P99 latency** | 100ms | P99 latency exceeds absolute maximum |
| **Error rate** | 1% | Request error rate exceeds threshold |
| **Catchup timeout** | 300 seconds | Replica fails to catch up within timeout |

### Customizing Thresholds

```bash
# Stricter thresholds (more sensitive to degradation)
archerdb upgrade start --addresses=... --target-version=1.2.0 \
  --dry-run \
  --p99-threshold-x10=15 \       # 1.5x baseline
  --error-threshold-x10=5 \       # 0.5% errors
  --catchup-timeout=180           # 3 minutes

# Looser thresholds (more tolerant)
archerdb upgrade start --addresses=... --target-version=1.2.0 \
  --dry-run \
  --p99-threshold-x10=50 \       # 5.0x baseline
  --error-threshold-x10=20 \      # 2.0% errors
  --catchup-timeout=600           # 10 minutes
```

## External Rollback

### Bare Metal Rollback

```bash
# Check upgrade status
archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000

# ArcherDB does not perform rollback itself; use your service manager or deploy tool
```

Or roll back manually on each node with your service manager or deployment tooling:

```bash
# On each upgraded node (primary first if upgraded):

# 1. Stop the process
systemctl stop archerdb

# 2. Restore old binary
mv /usr/local/bin/archerdb.bak /usr/local/bin/archerdb

# 3. Start with old version
systemctl start archerdb
```

### Kubernetes Rollback

```bash
# Rollback to previous revision
kubectl rollout undo statefulset/archerdb -n archerdb

# Or rollback to specific revision
kubectl rollout undo statefulset/archerdb -n archerdb --to-revision=2

# Watch rollback progress
kubectl rollout status statefulset/archerdb -n archerdb
```

## Post-Upgrade Verification

After upgrade completes, verify these conditions:

### Immediate Checks

```bash
# 1. All replicas running new version
archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000

# 2. Cluster health is normal
curl http://node1:9100/health/ready
curl http://node2:9100/health/ready
curl http://node3:9100/health/ready

# 3. Replication lag is minimal
curl http://node1:9100/metrics | grep archerdb_replication_lag
```

### Performance Validation

```bash
# 4. Compare P99 latency to baseline
curl http://node1:9100/metrics | grep 'request_duration.*quantile="0.99"'

# 5. Check error rate
curl http://node1:9100/metrics | grep archerdb_request_errors

# 6. Verify throughput
curl http://node1:9100/metrics | grep archerdb_operations_total
```

### Functional Validation

```bash
# 7. Test write operations
archerdb repl --addresses=node1:3000,node2:3000,node3:3000 --cluster=<cluster-id>
> INSERT INTO geo_events ...

# 8. Test read operations
> SELECT * FROM geo_events WHERE ...
```

## Troubleshooting

### Upgrade Stuck on Replica

**Symptom**: Upgrade status shows "waiting_for_catchup" for extended time

**Diagnosis**:
```bash
# Check replica logs
journalctl -u archerdb -f  # bare metal
kubectl logs archerdb-1 -n archerdb  # kubernetes

# Check replication lag
curl http://node2:9100/metrics | grep replication_lag
```

**Solutions**:
1. Increase catchup timeout: `--catchup-timeout=600`
2. Check network connectivity between replicas
3. Verify disk I/O is not saturated
4. Check if compaction is blocking catch-up

### Rollback Fails to Complete

**Symptom**: External rollback command hangs or reports errors

**Diagnosis**:
```bash
# Check node status
archerdb upgrade status --addresses=...

# Check process status
systemctl status archerdb
```

**Solutions**:
1. Manually stop and restart each replica with old binary
2. Check for disk space issues
3. Verify network connectivity

### Version Incompatibility Error

**Symptom**: Upgrade reports "Version incompatible - sequential upgrade required"

**Solutions**:
1. Check CHANGELOG for upgrade path requirements
2. Perform intermediate upgrade first
3. Open an issue with the logs and upgrade path details if the required sequence is unclear

### Health Check False Positives

**Symptom**: External rollback triggers despite cluster appearing healthy

**Diagnosis**:
```bash
# Check actual latency metrics
curl http://node1:9100/metrics | grep request_duration

# Review external rollback reason in logs
journalctl -u archerdb | grep -i rollback
```

**Solutions**:
1. Increase thresholds: `--p99-threshold-x10=30`
2. Review baseline latency (may have been unusually low)
3. Check for external factors affecting latency

## CLI Reference

### Status Command

```bash
archerdb upgrade status --addresses=<addresses> [--metrics-port=<port>] [--format=<text|json>]
```

Shows current cluster versions, identifies primary, and displays upgrade readiness.

### Start Command

```bash
archerdb upgrade start --addresses=<addresses> --target-version=<version> \
  --dry-run \
  [--metrics-port=<port>] \
  [--p99-threshold-x10=<value>] \
  [--error-threshold-x10=<value>] \
  [--catchup-timeout=<seconds>] \
  [--format=<text|json>]
```

Generates a dry-run rolling-upgrade plan to the target version. `--dry-run` is required in the current runtime surface.

The ArcherDB CLI does not own process restarts, pause/resume state, or rollback actuation. Use your deployment tooling for those mutations and use `upgrade status` plus `upgrade start --dry-run` for inspection and planning.

---

## Related Documentation

- [Operations Runbook](operations-runbook.md) - General operational procedures
- [Backup Operations](backup-operations.md) - External snapshot and restore procedures
- [Disaster Recovery](disaster-recovery.md) - DR planning and procedures
- [Monitoring](operations-runbook.md#monitoring) - Metrics and alerting
