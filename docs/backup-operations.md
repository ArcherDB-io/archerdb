# Backup Operations

ArcherDB has built-in backup upload to local filesystem, S3 (or S3-compatible
endpoints — MinIO, R2, Backblaze, LocalStack), GCS via interop, and Azure Blob
Storage. All four providers are end-to-end proven via integration tests and
have CI lanes (`Backup Restore`, `Backup Restore S3`, `Backup Restore Azure`,
and their `Round-trip` variants) that run on every PR.

Operators can still combine the built-in path with platform snapshots for
extra redundancy; the two are not mutually exclusive.

## Built-in Backup Providers

| Provider | Config | Credentials |
|----------|--------|-------------|
| `local`  | `--backup-provider=local --backup-bucket=/mnt/backups` | filesystem write access |
| `s3`     | `--backup-provider=s3 --backup-bucket=<name> [--backup-endpoint=<url> --backup-url-style=path]` | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` or `--backup-access-key-id` / `--backup-secret-access-key` |
| `gcs`    | `--backup-provider=gcs --backup-bucket=<name>` (uses storage.googleapis.com over the S3-compatible Interop API) | HMAC key issued via Cloud Storage → Settings → Interoperability |
| `azure`  | `--backup-provider=azure --backup-bucket=<container> --backup-access-key-id=<account> --backup-secret-access-key=<base64-key>` | Azure storage account + SharedKey; SAS tokens supported on the restore side |

See [Disaster Recovery](disaster-recovery.md) for the matching restore
procedures.

## Strategy

Use a layered approach:

1. Replica redundancy for high availability
2. Built-in backup upload (S3/GCS/Azure/local) for durable off-host copies
3. Volume/object snapshots or cross-region immutable copies for defense-in-depth
4. Off-site retention lock for regulated workloads

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

