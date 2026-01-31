# Disaster Recovery Procedures

This document outlines procedures for recovering ArcherDB clusters from various failure scenarios.

## Table of Contents

- [RTO/RPO Targets](#rtorpo-targets)
- [Disaster Categories](#disaster-categories)
- [Automatic Failover](#automatic-failover-single-node-failure)
- [Kubernetes-Specific Procedures](#kubernetes-specific-procedures)
- [Backup Strategy](#backup-strategy)
- [Recovery Procedures](#recovery-procedures)
- [Recovery Time Objectives](#recovery-time-objectives)
- [Testing Schedule and Checklists](#testing-schedule-and-checklists)
- [Runbook Checklists](#runbook-checklists)

## RTO/RPO Targets

### Recovery Time Objective (RTO)

RTO defines the maximum acceptable time to restore service after a failure.

| Scenario | RTO | Notes |
|----------|-----|-------|
| Single replica failure | **0** (automatic) | VSR consensus continues with remaining quorum |
| Minority replica failure (< 50%) | **< 5 minutes** | Automatic failover, no manual intervention |
| Majority replica failure (>= 50%) | **< 30 minutes** | Manual intervention required to restore quorum |
| Total cluster loss | **< 4 hours** | Full restore from object storage backups |
| Cross-region failover | **< 6 hours** | Includes DNS propagation and verification |

### Recovery Point Objective (RPO)

RPO defines the maximum acceptable data loss measured in time.

| Scenario | RPO | Notes |
|----------|-----|-------|
| Single replica failure | **0** | Synchronous VSR replication ensures no data loss |
| Minority replica failure | **0** | Quorum maintained, all committed writes safe |
| Majority replica failure | **0** | Committed writes on surviving replicas are preserved |
| Total cluster loss (with backup) | **Minutes** | Depends on backup frequency and last successful upload |
| Total cluster loss (async backup only) | **Minutes to hours** | Based on backup schedule and upload lag |

**Key Principle**: ArcherDB uses synchronous VSR consensus replication. Any write acknowledged to the client has been replicated to a quorum of replicas, achieving RPO = 0 for all non-catastrophic failures.

## Disaster Categories

### Category 1: Single Replica Failure

**Impact**: No data loss, no downtime (with 3+ replicas)
**Recovery**: Automatic failover, replace failed replica

### Category 2: Minority Replica Failure

**Impact**: No data loss, no downtime
**Recovery**: Replace failed replicas, sync from survivors

### Category 3: Majority Replica Failure

**Impact**: Cluster unavailable until quorum restored
**Recovery**: Restore from surviving replica + backups

### Category 4: Total Cluster Loss

**Impact**: Service outage until restored
**Recovery**: Full restore from object storage backups

### Category 5: Data Corruption

**Impact**: Potential data integrity issues
**Recovery**: Point-in-time restore from backups

## Automatic Failover (Single Node Failure)

For single replica failures, ArcherDB provides **automatic failover with RTO = 0** for client operations. No operator intervention is required.

### VSR Consensus Automatic Recovery

ArcherDB uses VSR (Viewstamped Replication) consensus, which automatically handles single node failures:

```
Automatic Failover Flow:

1. Replica pod fails (crash, disk error, OOM kill)
         ↓
2. Liveness probe fails after 3 attempts (90 seconds max)
         ↓
3. Kubernetes restarts pod on same node (if possible)
         ↓
4. VSR consensus continues with remaining replicas (quorum maintained)
         ↓
5. New pod starts, passes health probe
         ↓
6. Replica rejoins cluster via state sync
         ↓
7. Replica catches up from surviving replicas
         ↓
8. Full redundancy restored

Client Impact: NONE (quorum maintained throughout)
RTO: 0 for client operations
```

### Why RTO = 0 for Single Failures

1. **Quorum-based writes**: Client writes are acknowledged after replication to a quorum (2 of 3 replicas)
2. **Automatic traffic routing**: Kubernetes readiness probe marks failed pod as not ready
3. **Service continues**: Remaining healthy replicas handle all client traffic
4. **No primary election needed**: VSR view change occurs automatically if primary fails

### Automatic vs Manual Recovery

| Failure Type | Recovery Mode | Operator Action Required |
|--------------|---------------|-------------------------|
| Single replica crash | Automatic | None |
| Single disk failure | Automatic | None (pod restarts with new PVC if needed) |
| Network partition (minority) | Automatic | None (VSR handles partition) |
| OOM kill | Automatic | Monitor for recurrence |
| Majority failure | **Manual** | Follow recovery procedures below |
| Total cluster loss | **Manual** | Restore from backup |

## Kubernetes-Specific Procedures

### Pod Replacement via StatefulSet

When a pod fails, Kubernetes StatefulSet automatically handles replacement:

```bash
# Force pod replacement (if automatic recovery stalls)
kubectl delete pod archerdb-0 -n archerdb

# StatefulSet will recreate the pod with the same identity
# PVC remains bound, data is preserved
```

### PVC Recovery After Disk Failure

If a PersistentVolumeClaim experiences disk failure:

```bash
# 1. Delete the failed pod (will be recreated)
kubectl delete pod archerdb-1 -n archerdb

# 2. If PVC is corrupted, delete it (data will be re-synced from replicas)
kubectl delete pvc archerdb-data-archerdb-1 -n archerdb

# 3. StatefulSet recreates pod with new PVC
# 4. ArcherDB syncs data from surviving replicas automatically
```

**Note**: PVCs have `helm.sh/resource-policy: keep` by default to prevent accidental deletion during `helm uninstall`.

### Cross-Zone Failover with Pod Anti-Affinity

The Helm chart configures pod anti-affinity to spread replicas across zones:

```yaml
# Configured via values.yaml
podAntiAffinity:
  enabled: true
  weight: 100
```

For zone failure, remaining pods in other zones maintain quorum automatically.

### Helm Rollback for Configuration Issues

If a configuration change causes issues:

```bash
# List release history
helm history archerdb -n archerdb

# Rollback to previous revision
helm rollback archerdb 1 -n archerdb

# Verify rollback
helm status archerdb -n archerdb
```

### Kubernetes Cluster-Level Recovery

For Kubernetes cluster failures:

```bash
# 1. Verify PVCs still exist (if storage survives)
kubectl get pvc -n archerdb

# 2. If PVCs exist, simply redeploy the chart
helm install archerdb deploy/helm/archerdb -n archerdb

# 3. If PVCs are lost, restore from backup (see Procedure 3 below)
```

## Backup Strategy

### Continuous Block Backup

ArcherDB continuously backs up data blocks to object storage:

```bash
# Enable backup to S3
./archerdb start \
  --backup-enabled=true \
  --backup-provider=s3 \
  --backup-bucket=s3://archerdb-backups \
  --backup-region=us-east-1 \
  --backup-mode=mandatory  # Halt writes if backup fails
```

### Backup Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `mandatory` | Halt writes if backup queue full | Regulated environments |
| `best-effort` | Continue writes, log warnings | High availability priority |

### Backup Verification

```bash
# Verify backup integrity
./archerdb backup verify \
  --bucket=s3://archerdb-backups \
  --cluster-id=12345

# List available backups
./archerdb backup list \
  --bucket=s3://archerdb-backups \
  --cluster-id=12345
```

### Multi-Region Replication

For disaster recovery across regions, enable S3 Cross-Region Replication:

```bash
# Primary region: us-east-1
# DR region: us-west-2 (replicated via S3 CRR)

aws s3api put-bucket-replication \
  --bucket archerdb-backups \
  --replication-configuration file://replication.json
```

## Recovery Procedures

### Procedure 1: Single Replica Recovery

**Scenario**: One replica's disk failed, other replicas healthy.

**Steps**:

1. **Remove failed replica from rotation** (if using load balancer)
   ```bash
   # Update LB health checks will handle this automatically
   ```

2. **Format new replica**
   ```bash
   ./archerdb format \
     --cluster=12345 \
     --replica=2 \
     --replica-count=3 \
     /data/archerdb.db
   ```

3. **Start new replica**
   ```bash
   ./archerdb start \
     --addresses=node1:3000,node2:3000,newnode:3000 \
     /data/archerdb.db
   ```

4. **Monitor sync progress**
   ```bash
   curl localhost:9090/metrics | grep replication_lag
   ```

**Recovery Time**: 10-30 minutes depending on data size.

### Procedure 2: Majority Replica Recovery

**Scenario**: 2 of 3 replicas failed, 1 survivor.

**Steps**:

1. **Stop the surviving replica to prevent further writes**
   ```bash
   systemctl stop archerdb
   ```

2. **Backup the surviving replica's data file**
   ```bash
   cp /data/archerdb.db /data/archerdb.db.backup
   ```

3. **Format new replicas**
   ```bash
   # On new nodes
   ./archerdb format --cluster=12345 --replica=1 --replica-count=3 /data/archerdb.db
   ./archerdb format --cluster=12345 --replica=2 --replica-count=3 /data/archerdb.db
   ```

4. **Copy data to new replicas**
   ```bash
   # Copy survivor's data to new replicas
   scp /data/archerdb.db.backup newnode1:/data/archerdb.db
   scp /data/archerdb.db.backup newnode2:/data/archerdb.db
   ```

5. **Start all replicas**
   ```bash
   # Start survivor first, then new replicas
   ./archerdb start --addresses=... /data/archerdb.db
   ```

**Recovery Time**: 30-60 minutes.

### Procedure 3: Total Cluster Recovery from Backup

**Scenario**: All replicas lost, recovering from S3 backups.

**Steps**:

1. **Identify latest complete backup**
   ```bash
   ./archerdb backup list \
     --bucket=s3://archerdb-backups \
     --cluster-id=12345 \
     --format=json | jq '.[-1]'
   ```

2. **Restore to new data file**
   ```bash
   ./archerdb restore \
     --bucket=s3://archerdb-backups \
     --cluster-id=12345 \
     --output=/data/archerdb.db \
     --replica=0 \
     --replica-count=3
   ```

3. **Copy restored data to all replicas**
   ```bash
   scp /data/archerdb.db node2:/data/archerdb.db
   scp /data/archerdb.db node3:/data/archerdb.db
   ```

4. **Update replica IDs**
   ```bash
   # Each node needs correct replica ID in metadata
   ./archerdb repair --set-replica=0 /data/archerdb.db  # node1
   ./archerdb repair --set-replica=1 /data/archerdb.db  # node2
   ./archerdb repair --set-replica=2 /data/archerdb.db  # node3
   ```

5. **Start cluster**
   ```bash
   ./archerdb start --addresses=... /data/archerdb.db  # all nodes
   ```

6. **Verify data integrity**
   ```bash
   ./archerdb verify /data/archerdb.db
   ```

**Recovery Time**: 1-4 hours depending on data size.

### Procedure 4: Point-in-Time Recovery

**Scenario**: Need to recover to a specific timestamp (e.g., before bad data was written).

**Steps**:

1. **Identify backup sequence for target time**
   ```bash
   ./archerdb backup list \
     --bucket=s3://archerdb-backups \
     --cluster-id=12345 \
     --before="2025-01-15T12:00:00Z"
   ```

2. **Restore with point-in-time flag**
   ```bash
   ./archerdb restore \
     --bucket=s3://archerdb-backups \
     --cluster-id=12345 \
     --point-in-time="2025-01-15T12:00:00Z" \
     --output=/data/archerdb-pit.db
   ```

3. **Verify restored data**
   ```bash
   ./archerdb verify /data/archerdb-pit.db
   ./archerdb client query --data-file=/data/archerdb-pit.db ...
   ```

4. **Replace production data if verified**

**Recovery Time**: 1-4 hours.

### Procedure 5: Cross-Region Failover

**Scenario**: Primary region completely unavailable.

**Steps**:

1. **Confirm primary region failure**
   ```bash
   # Check primary cluster health
   ./archerdb status --addresses=primary-region:3000
   # Timeout indicates failure
   ```

2. **Restore from DR region bucket**
   ```bash
   # S3 CRR should have replicated backups to DR region
   ./archerdb restore \
     --bucket=s3://archerdb-backups-dr \
     --cluster-id=12345 \
     --region=us-west-2 \
     --output=/data/archerdb.db
   ```

3. **Start DR cluster**
   ```bash
   ./archerdb start --addresses=dr-node1:3000,dr-node2:3000,dr-node3:3000 /data/archerdb.db
   ```

4. **Update DNS/load balancers to DR region**

5. **Notify clients of new addresses** (if not using DNS)

**Recovery Time**: 2-6 hours including DNS propagation.

## Recovery Time Objectives

This section provides detailed RTO/RPO analysis for each scenario. See [RTO/RPO Targets](#rtorpo-targets) at the top of this document for the summary table.

| Scenario | RTO | RPO | Procedure | Automation |
|----------|-----|-----|-----------|------------|
| Single replica failure | **0** (automatic) | **0** | Automatic via VSR | Full |
| Minority failure (1 of 3) | **< 5 minutes** | **0** | Automatic via VSR | Full |
| Majority failure (2 of 3) | **< 30 minutes** | **0** | Procedure 2 | Manual |
| Total loss (with backups) | **< 4 hours** | **Minutes** | Procedure 3 | Semi-auto |
| Cross-region failover | **< 6 hours** | **Minutes** | Procedure 5 | Manual |
| Point-in-time recovery | **1-4 hours** | **Configurable** | Procedure 4 | Semi-auto |

**RTO** = Recovery Time Objective (maximum time until service restored)
**RPO** = Recovery Point Objective (maximum acceptable data loss)

### RTO Achievement Guide

To achieve the stated RTO targets:

1. **0 / < 5 minutes RTO (automatic failures)**
   - Ensure PodDisruptionBudget is configured (`pdb.enabled: true`)
   - Configure appropriate liveness/readiness probe timeouts
   - Use pod anti-affinity to spread across failure domains

2. **< 30 minutes RTO (majority failure)**
   - Pre-provision replacement infrastructure
   - Automate replica formatting and startup
   - Practice Procedure 2 quarterly

3. **< 4 hours RTO (total cluster loss)**
   - Use regional object storage for backups
   - Pre-stage recovery scripts
   - Document exact steps with copy-paste commands
   - Practice Procedure 3 bi-annually

### Related Documentation

For detailed backup configuration and monitoring, see [Backup Operations Guide](backup-operations.md).

## Testing Schedule and Checklists

### Testing Schedule

| Frequency | Test Type | Environment | Estimated Duration |
|-----------|-----------|-------------|-------------------|
| **Monthly** | Backup restoration | Production (read-only) | 30 minutes |
| **Monthly** | Backup verification | Production | 15 minutes |
| **Quarterly** | Single replica failure | Staging | 1 hour |
| **Quarterly** | Point-in-time recovery | Staging | 2 hours |
| **Bi-annually** | Majority failure simulation | Staging | 4 hours |
| **Bi-annually** | Cross-region failover | Staging/DR | 8 hours |
| **Annually** | Full DR exercise | All environments | 1-2 days |

### Pre-DR Test Checklist

Complete before starting any DR test:

- [ ] **Backup verified**: Run `./archerdb backup verify` successfully
- [ ] **Backup recent**: Last backup < 1 hour old
- [ ] **Monitoring active**: Prometheus/Grafana dashboards accessible
- [ ] **Alerts configured**: Alert channels responding (test page)
- [ ] **Runbooks reviewed**: Team has read relevant procedures
- [ ] **Communication plan**: Stakeholders notified of test window
- [ ] **Rollback plan**: Know how to abort if issues arise
- [ ] **Staging environment ready**: (for destructive tests only)

### Post-DR Test Report Template

Complete after each DR test:

```markdown
## DR Test Report

**Date**: YYYY-MM-DD
**Test Type**: [Backup Restore / Replica Failure / Full DR Exercise]
**Environment**: [Production / Staging / DR]
**Participants**: [Names]

### Summary

**Result**: [PASS / PARTIAL / FAIL]
**Actual RTO**: [time]
**Expected RTO**: [time]
**Actual RPO**: [time or "0"]
**Expected RPO**: [time or "0"]

### Timeline

| Time | Action | Result |
|------|--------|--------|
| HH:MM | Started test | - |
| HH:MM | [Action taken] | [Success/Failure] |
| HH:MM | Service restored | - |
| HH:MM | Verification complete | - |

### Issues Encountered

1. [Issue description and resolution]

### Improvements Identified

1. [Improvement recommendation]

### Runbook Updates Required

1. [Section to update]

### Sign-off

- [ ] DBA Lead
- [ ] Infrastructure Lead
- [ ] On-call Engineer
```

### Monthly DR Tests

1. **Backup restoration test**
   ```bash
   # Restore to test environment
   ./archerdb restore \
     --bucket=s3://archerdb-backups \
     --cluster-id=12345 \
     --output=/tmp/test-restore.db

   # Verify data
   ./archerdb verify /tmp/test-restore.db
   ```

2. **Single replica failure simulation** (Kubernetes)
   ```bash
   # Delete one pod (StatefulSet recreates it)
   kubectl delete pod archerdb-2 -n archerdb

   # Verify cluster continues operating
   kubectl exec archerdb-0 -n archerdb -- ./archerdb client ping

   # Watch pod recovery
   kubectl get pods -n archerdb -w

   # Verify replica rejoins
   kubectl logs archerdb-2 -n archerdb | grep "state sync complete"
   ```

3. **Single replica failure simulation** (Bare metal)
   ```bash
   # Stop one replica
   ssh node3 "systemctl stop archerdb"

   # Verify cluster continues operating
   ./archerdb client ping --addresses=node1:3000,node2:3000

   # Restart replica
   ssh node3 "systemctl start archerdb"
   ```

### Quarterly DR Tests

1. **Majority failure simulation** (in staging environment only)
   - Stop 2 of 3 replicas
   - Verify cluster becomes unavailable (expected)
   - Restore quorum following Procedure 2
   - Measure time to recovery

2. **Cross-region failover drill**
   - Simulate primary region unavailability
   - Execute cross-region failover procedure
   - Verify data integrity in DR region
   - Measure total failover time

3. **Point-in-time recovery test**
   - Create test data with known timestamp
   - Perform additional writes after timestamp
   - Restore to timestamp, verify only expected data present

### Bi-Annual DR Tests

1. **Full majority failure exercise**
   - Complete majority failure and recovery
   - Include stakeholder communication
   - Practice incident command procedures

2. **Cross-region failover with client cutover**
   - Execute full failover including DNS/load balancer changes
   - Verify client applications reconnect successfully

### Annual DR Tests

1. **Full disaster recovery exercise**
   - Simulate total cluster loss
   - Execute Procedure 3 (Total Cluster Recovery)
   - Include all stakeholder communication
   - Full post-mortem review

2. **Update runbooks based on findings**
3. **Review and update RTO/RPO targets**
4. **Validate backup retention meets compliance requirements**

## Runbook Checklists

### Pre-Disaster Preparation

- [ ] Backup enabled and verified working
- [ ] Backup bucket has versioning enabled
- [ ] Cross-region replication configured (if required)
- [ ] Monitoring alerts for backup failures
- [ ] DR runbooks reviewed and up-to-date
- [ ] DR contact list current
- [ ] Last DR test completed within 90 days

### During Incident

- [ ] Assess scope of failure (which replicas affected)
- [ ] Notify stakeholders
- [ ] Determine recovery procedure needed
- [ ] Execute recovery procedure
- [ ] Verify data integrity post-recovery
- [ ] Update clients/DNS if needed
- [ ] Monitor for stability

### Post-Incident

- [ ] Document incident timeline
- [ ] Root cause analysis
- [ ] Update runbooks if needed
- [ ] Review and improve monitoring
- [ ] Schedule follow-up DR test
- [ ] File post-mortem report

## Contact Information

| Role | Contact | Escalation |
|------|---------|------------|
| On-call DBA | pager@example.com | 15 minutes |
| Infrastructure Lead | infra-lead@example.com | 30 minutes |
| Security Team | security@example.com | Immediately for data breach |
| Management | management@example.com | Major outage (> 1 hour) |

## Appendix: Command Reference

```bash
# Backup commands
./archerdb backup list --bucket=s3://... --cluster-id=...
./archerdb backup verify --bucket=s3://... --cluster-id=...
./archerdb backup status  # Show backup queue status

# Restore commands
./archerdb restore --bucket=s3://... --cluster-id=... --output=...
./archerdb restore --point-in-time="..." ...

# Repair commands
./archerdb verify /data/archerdb.db
./archerdb repair --set-replica=N /data/archerdb.db
./archerdb compact /data/archerdb.db

# Status commands
./archerdb status --addresses=...
./archerdb client ping --addresses=...
```
