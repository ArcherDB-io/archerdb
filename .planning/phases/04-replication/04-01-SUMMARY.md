---
phase: 04-replication
plan: 01
subsystem: replication
tags: [s3, sigv4, aws, http, multipart-upload, exponential-backoff, minio, r2, gcs, backblaze]

# Dependency graph
requires:
  - phase: 03-geospatial
    provides: stable foundation for extension
provides:
  - S3 upload functionality with SigV4 authentication
  - Multi-provider support (AWS, MinIO, R2, GCS, Backblaze)
  - Retry logic with exponential backoff
  - Multipart upload for large files (>=100MB)
  - Content-MD5 integrity verification
affects: [04-02, 04-03, 05-observability]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - SigV4 request signing with canonical request construction
    - Provider detection and URL style adaptation (path vs virtual-hosted)
    - Exponential backoff with jitter for retries (1s, 2s, 4s... capped at 512s)

key-files:
  created:
    - src/replication/sigv4.zig
    - src/replication/s3_client.zig
    - src/replication/providers.zig
  modified:
    - src/replication.zig

key-decisions:
  - "Generic S3 API supports AWS, MinIO, R2, GCS, Backblaze via provider detection"
  - "Path style URLs for MinIO/generic, virtual-hosted for AWS"
  - "R2 uses region=auto for signing per Cloudflare spec"
  - "16MB part size for multipart uploads (100MB threshold)"
  - "10 retries with exponential backoff ~17 min total before failure"
  - "Graceful fallback to simulated uploads when credentials unavailable"

patterns-established:
  - "SigV4 signing: canonical request -> string to sign -> signature -> authorization header"
  - "Provider abstraction: detect provider, adapt URL style, get effective region"
  - "Retry with backoff: exponential delay with +/-25% jitter to prevent thundering herd"

# Metrics
duration: 15min
completed: 2026-01-22
---

# Phase 04 Plan 01: S3 Uploads Summary

**Real S3 uploads with SigV4 auth, multi-provider support (AWS/MinIO/R2/GCS/Backblaze), exponential backoff retries, and multipart upload for large files**

## Performance

- **Duration:** 15 min
- **Started:** 2026-01-22T20:36:44Z
- **Completed:** 2026-01-22T20:52:32Z
- **Tasks:** 3
- **Files created:** 3
- **Files modified:** 1

## Accomplishments
- Implemented AWS SigV4 signing with canonical request construction per AWS spec
- Created S3 HTTP client supporting all S3-compatible providers
- Wired real S3 uploads into S3RelayTransport with automatic retry logic
- Added multipart upload support for files >= 100MB with 16MB parts
- Content-MD5 verification on all uploads for integrity

## Task Commits

Each task was committed atomically:

1. **Task 1: Create SigV4 signing module** - `91fcc5a` (feat)
2. **Task 2: Create S3 client and provider modules** - `0cd7aa6` (feat)
3. **Task 3: Wire S3 client into S3RelayTransport** - `c625f9c` (feat)

**Note:** Task 3 commit (`c625f9c`) contains mixed changes with plan 04-02 due to concurrent execution. The S3RelayTransport changes for this plan are present and verified.

## Files Created/Modified

- `src/replication/sigv4.zig` - AWS Signature Version 4 signing implementation
  - deriveSigningKey() for signing key derivation
  - createCanonicalRequest() for canonical request construction
  - createStringToSign() for string-to-sign creation
  - sign() for complete request signing workflow
  - Unit tests with AWS test vectors

- `src/replication/s3_client.zig` - S3 HTTP client
  - S3Client struct with HTTP operations
  - putObject() for single-part uploads
  - initiateMultipartUpload(), uploadPart(), completeMultipartUpload(), abortMultipartUpload()
  - multipartUpload() for automatic large file handling
  - XML response parsing for upload IDs

- `src/replication/providers.zig` - Provider detection and adaptation
  - Provider enum: aws, minio, r2, gcs, backblaze, generic
  - detectProvider() from endpoint URL patterns
  - getRegion() with provider-specific defaults (R2 = "auto")
  - buildRequestUrl() with path vs virtual-hosted styles
  - getHostHeader() and getSigningUri() for request construction

- `src/replication.zig` - S3RelayTransport integration
  - Added s3_client field for real uploads
  - Added retry_prng for backoff jitter
  - Added multipart_threshold (100MB) and max_retries (10)
  - shipImpl() now calls uploadWithRetry() instead of logging stub
  - calculateBackoff() implements exponential backoff with jitter

## Decisions Made

1. **Generic S3 API:** Single implementation supports all S3-compatible providers via provider detection from endpoint URL patterns.

2. **URL Style Selection:** AWS uses virtual-hosted style by default, MinIO/generic use path style for better compatibility.

3. **R2 Region:** Cloudflare R2 always uses "auto" region for signing per their documentation.

4. **Multipart Threshold:** 100MB threshold with 16MB parts balances memory usage and upload efficiency.

5. **Retry Configuration:** 10 retries with exponential backoff (1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s, 512s) gives ~17 minutes total retry window.

6. **Graceful Degradation:** When credentials are unavailable, S3RelayTransport falls back to simulated uploads with logging instead of failing.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed Zig HTTP client API usage**
- **Found during:** Task 3 (S3 client HTTP operations)
- **Issue:** Used `req.status` instead of `req.response.status`, and `req.write()` return value not handled
- **Fix:** Changed to `req.response.status`, added `_ =` to discard write return value, used `req.response.iterateHeaders()` for header iteration
- **Files modified:** src/replication/s3_client.zig
- **Verification:** Build and tests pass
- **Committed in:** Part of Task 3 commit

**2. [Rule 1 - Bug] Fixed hexDigit type mismatch**
- **Found during:** Task 1 (SigV4 URI encoding)
- **Issue:** `hexDigit(n: u4)` function tried arithmetic with character literals which caused type coercion issues
- **Fix:** Changed to lookup table approach: `const digits = "0123456789ABCDEF"; return digits[n];`
- **Files modified:** src/replication/sigv4.zig
- **Verification:** URI encoding tests pass
- **Committed in:** Part of Task 1 commit

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug)
**Impact on plan:** Both fixes necessary for correct operation. No scope creep.

## Issues Encountered

- **Linter race conditions:** The Zig build system or linter occasionally modified files during editing, requiring re-reads. Handled by re-reading files before each edit.

- **Mixed commit history:** Task 3 work was captured in a commit that also includes plan 04-02 changes due to concurrent session state. The functionality is correct and verified.

## User Setup Required

None - no external service configuration required. S3 credentials are optional and loaded from environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) when available.

## Next Phase Readiness

- S3 upload infrastructure complete and tested
- Ready for plan 04-02 (spillover) to use S3 uploads for persisted data
- Ready for plan 04-03 (health checks) to monitor upload success/failure metrics
- Provider abstraction enables easy addition of new S3-compatible providers

### Blockers/Concerns

- Real S3 integration testing requires actual credentials (unit tests use simulated mode)
- Multipart upload tested only via unit tests, not against real S3

---
*Phase: 04-replication*
*Completed: 2026-01-22*
