# Phase 4: Replication - Context

**Gathered:** 2026-01-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Implement S3-based cross-region replication with disk spillover for durability. S3RelayTransport uploads WAL segments to S3-compatible storage (AWS, MinIO, R2, GCS, Backblaze). Disk spillover buffers data locally when S3 is unreachable or memory fills. Metrics expose replication lag and health status.

</domain>

<decisions>
## Implementation Decisions

### S3 Upload Behavior
- Exponential backoff on failure: 1s, 2s, 4s, 8s... up to 10 retries (~17 minutes total)
- After retries exhausted, spill to disk and keep running — never block writes
- Multipart uploads for files >= 100MB
- Always verify uploads with Content-MD5 checksums
- Compression is configurable per environment (operator choice)
- Retry spillover uploads forever — never lose data

### Disk Spillover Mechanics
- Trigger spillover on memory pressure OR S3 failure (both conditions)
- Store spillover files in subdirectory of ArcherDB's data directory
- Delete spillover files immediately after S3 confirms receipt
- On restart, auto-detect spillover files and resume uploads

### Provider Compatibility
- Support full credential chain: IAM roles, environment variables, config file
- Auto-detect provider from endpoint URL (s3.amazonaws.com → AWS, etc.)
- Internal adaptation for provider differences — operator just provides endpoint
- Integration tests use MinIO only (S3-compatible, sufficient for CI)

### Metrics & Lag Exposure
- Expose both time-based lag (seconds since oldest unuploaded segment) and segment count
- Full observability: counters, latency histograms (p50/p95/p99), per-provider breakdown
- Spillover disk usage exposed as metric with configurable alert threshold
- Replication state (healthy/degraded/failed) exposed both as metric AND in health endpoint

### Claude's Discretion
- Batching strategy for uploads (size vs time vs individual)
- Memory queue size threshold for spillover trigger
- Specific exponential backoff parameters (jitter, cap)
- Spillover file naming convention
- Provider detection heuristics

</decisions>

<specifics>
## Specific Ideas

- Never block writes — spill to disk, keep running
- Retry forever from disk — data loss is unacceptable
- Operators should see replication state in health endpoints for kubernetes probes

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 04-replication*
*Context gathered: 2026-01-22*
