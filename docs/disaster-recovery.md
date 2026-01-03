# Disaster Recovery Procedures

This document outlines procedures for recovering ArcherDB clusters from various failure scenarios.

## Table of Contents

- [Disaster Categories](#disaster-categories)
- [Backup Strategy](#backup-strategy)
- [Recovery Procedures](#recovery-procedures)
- [Recovery Time Objectives](#recovery-time-objectives)
- [Testing Procedures](#testing-procedures)
- [Runbook Checklists](#runbook-checklists)

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

| Scenario | RTO | RPO |
|----------|-----|-----|
| Single replica failure | 0 (automatic) | 0 |
| Minority failure | < 1 hour | 0 |
| Majority failure | 1-2 hours | Minutes |
| Total loss (with backups) | 2-4 hours | Minutes-Hours |
| Cross-region failover | 4-8 hours | Minutes-Hours |

**RTO** = Recovery Time Objective (how long until service restored)
**RPO** = Recovery Point Objective (how much data could be lost)

## Testing Procedures

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

2. **Single replica failure simulation**
   ```bash
   # Stop one replica
   ssh node3 "systemctl stop archerdb"

   # Verify cluster continues operating
   ./archerdb client ping --addresses=node1:3000,node2:3000

   # Restart replica
   ssh node3 "systemctl start archerdb"
   ```

### Quarterly DR Tests

1. **Majority failure simulation** (in staging environment)
2. **Cross-region failover drill**
3. **Point-in-time recovery test**

### Annual DR Tests

1. **Full disaster recovery exercise**
2. **Update runbooks based on findings**
3. **Review and update RTO/RPO targets**

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
