# Backup Operations (Infrastructure-Managed)

ArcherDB does not provide built-in backup orchestration. Backups are managed by your platform tooling.

## Strategy

Use a layered approach:

1. Replica redundancy for high availability
2. Volume/object snapshots for disaster recovery
3. Off-site/cross-region immutable copies for resilience

## Recommended Backup Sources

- Persistent volume snapshots (cloud block storage or CSI snapshot)
- Host-level filesystem snapshots
- Replicated encrypted object-store archives

## Retention Policy Example

- Daily snapshots retained 14 days
- Weekly snapshots retained 8 weeks
- Monthly snapshots retained 12 months
- Immutable retention lock for regulated workloads

## Backup Procedure (Generic)

1. Confirm cluster health and quorum
2. Trigger platform snapshot for all replica data volumes
3. Replicate snapshots/artifacts to secondary region/account
4. Record snapshot IDs, timestamps, and checksums in runbook

## Restore Procedure (Generic)

1. Provision replacement nodes/volumes
2. Restore data volumes from selected snapshot set
3. Start replicas and rejoin cluster using standard startup/recover flow
4. Validate application-level correctness (smoke + integrity checks)

## Verification Cadence

- Weekly: snapshot job success audit
- Monthly: restore-to-staging drill
- Quarterly: full-region recovery exercise

## Evidence to Keep

- Snapshot IDs and retention policy proof
- Restore test logs and timing (RTO/RPO)
- Access audit logs for backup and key operations
- Incident notes for failed backup or restore events

