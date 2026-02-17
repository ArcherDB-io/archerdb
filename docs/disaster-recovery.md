# Disaster Recovery Procedures

This guide covers disaster recovery for ArcherDB using:

- Consensus replication for node/replica failures
- External backup/snapshot tooling for catastrophic loss

ArcherDB itself does not provide built-in backup orchestration.

## Recovery Objectives

Define and track per environment:

- RTO (time to recover service)
- RPO (acceptable data loss window from backup snapshots)

## Failure Classes

1. Single replica loss (quorum remains)
2. Minority replica loss (quorum remains)
3. Majority loss (quorum lost)
4. Full cluster loss
5. Storage corruption

## Replica Loss Recovery

When a data file is lost, recover with `recover` (not `format`):

```bash
./archerdb recover \
  --cluster=0 \
  --addresses=127.0.0.1:3000,127.0.0.1:3001,127.0.0.1:3002 \
  --replica=2 \
  --replica-count=3 \
  /data/0_2.archerdb
```

Then start the replica normally and allow it to catch up.

## Full Cluster Loss Recovery

1. Provision replacement infrastructure
2. Restore replica data from external snapshots
3. Start replicas with original cluster metadata
4. Validate quorum, health endpoints, and smoke tests
5. Re-enable traffic after validation gates pass

## Data Corruption Recovery

1. Isolate affected replica(s)
2. Preserve forensic artifacts and logs
3. Restore from last known-good external snapshot
4. Rejoin cluster and validate integrity

## Required Runbooks

- External snapshot creation and retention
- External snapshot restore (regional and cross-region)
- Key and access-control recovery for encrypted storage
- Traffic cutover/rollback procedures

## Drill Schedule

- Monthly: restore test in staging
- Quarterly: production-like DR exercise
- Post-incident: targeted replay and remediation validation

## Evidence

Keep:

- Snapshot IDs and retention proof
- Restore timings vs RTO/RPO targets
- Validation logs from health/smoke/integrity checks
- Postmortem and corrective action tickets

