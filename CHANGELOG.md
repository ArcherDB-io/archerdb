# Changelog

ArcherDB release history.

## Unreleased

Cloud backup providers, latency-aware Java NEAREST routing, and the first pieces of
ENOSPC plumbing land in this section. See commits `c003883c..145dc05a` for the full
history.

### Backup & restore

- **S3 / S3-compatible backup runtime**: full provider (AWS, MinIO, R2, Backblaze,
  LocalStack) wired through `BackupUploader`. New CLI flags
  `--backup-endpoint`, `--backup-access-key-id`, `--backup-secret-access-key`,
  `--backup-url-style`. Verified against MinIO end-to-end via the
  `Backup Restore S3` and `Backup Restore S3 Round-trip` CI lanes.
- **GCS via interop**: `--backup-provider=gcs` routes through the same `S3Client`
  using HMAC keys + `storage.googleapis.com`. Operator instructions point at the
  Cloud Storage → Settings → Interoperability flow.
- **Azure Blob**: new `azure_blob_client.zig` with SharedKey auth, including
  `Put Block` + `Put Block List` multipart upload for blobs ≥100 MiB. Verified
  against Azurite (3-block round-trip).
- **Restore parity**: SAS-token Azure restore retained; new SharedKey path lets
  operators use the same credentials for backup and restore. Round-trip tests
  drive the full backup → restore → on-disk-verification chain on both S3 and
  Azure providers.
- **S3Client correctness fixes**: removed duplicate Host / Content-Length
  headers; added SigV4 canonical-query encoding. Unblocked all 52
  `test:integration:replication` tests, which previously skipped on the first
  `putObject` failure.

### Java SDK

- **NEAREST v2 latency-aware routing**: background `LatencyProber` measures
  TCP-connect RTT per region, maintains rolling stats with three-state health,
  and selects the lowest-RTT healthy region. Falls back to config-order before
  the first probe completes so the first request never stalls.
- New `ClientConfig` knobs: `setProbeIntervalMs`, `setProbeTimeoutMs`,
  `setProbeSampleCount`, `setUnhealthyThreshold`,
  `setBackgroundProbingEnabled`. Defaults match Python's `geo_routing` to keep
  cross-SDK behaviour aligned.

### Durability simulation & ENOSPC

- `Storage.Options.available_capacity` simulates silent ENOSPC under VOPR
  workloads; rejected writes flag target sectors faulty so reads surface as
  checksum failures.
- New metrics `archerdb_storage_space_exhausted_total` (counter) and
  `archerdb_storage_space_exhausted` (gauge); the state machine consults the
  gauge at `commit()` and rejects insert/upsert/delete/ttl_set/ttl_extend/
  ttl_clear with structured per-event responses while it is set. Reads,
  `pulse`, and `cleanup_expired` continue.
- New wire variant `storage_space_exhausted` on `InsertGeoEventResult` (17),
  `DeleteEntityResult` (5), and `TtlOperationResult` (5). All five SDKs
  (C, Go, Java, Node, Python) regenerated to match.

### Vortex / WAN scenarios

- New `wan-typical` Vortex scenario (100 ms delay, 20 ms jitter, 1 % loss);
  paired CI matrix entry runs it on every PR.
- Java NEAREST v2 has its own integration test that drives real localhost TCP
  listeners with differentiated accept latency to prove the prober reacts to
  measured RTT.

### Release & operator surface

- Java Central rehearsal workflow with optional `MAVEN_CENTRAL_PUBLISHING_TYPE=
  USER_MANAGED` so operators can stage a deployment for validation without
  auto-publishing. Adds the `MAVEN_CENTRAL_PUBLISHER_BASE_URL` env hook on
  `release.zig`.
- QEMU kernel-crash durability harness (`scripts/durability-kernel-crash.sh`)
  + runbook (`docs/runbooks/kernel-crash-durability.md`). Operator-runnable;
  CI integration deferred until runners have prebuilt cloud images.

### Documentation

- `docs/backup-operations.md` and `docs/disaster-recovery.md` updated to
  describe the built-in providers as the primary path.
- `docs/SDK_LIMITATIONS.md` and `docs/release-checklist.md` reflect the Java
  NEAREST upgrade.
- `FINALIZATION_PLAN.md` durability section updated with the new coverage.

### Known follow-ups

- Production `error.NoSpaceLeft` propagation from `io/linux.zig` through
  journal/grid up to the replica. Today the simulation-side path covers the
  replica lifecycle; production-IO plumbing needs a VSR write-completion
  callback contract revision and is queued for its own design pass.
- Dynamic cluster membership, server-side multi-region runtime, live upgrade
  actuation, and in-process CRL/OCSP remain explicitly non-GA.

## ArcherDB 1.0.0

Released: 2026-01-23

Initial v1.0 release of ArcherDB geospatial database.

### Features

- Core database engine with VSR consensus
- Geospatial indexing with S2 geometry
- Multi-replica support

## 2024-08-05 (prehistory)

Legacy entries follow.
