# Phase 4: Replication - Research

**Researched:** 2026-01-22
**Domain:** S3 API, Cross-Region Replication, Disk Spillover
**Confidence:** HIGH

## Summary

Phase 4 implements the S3RelayTransport for cross-region replication. The existing codebase has stub implementations at `src/replication.zig:828` (S3 upload) and `src/replication.zig:218` (disk spillover). The requirements demand:

1. **Real S3 uploads** via the generic S3 REST API (not SDK), supporting AWS, MinIO, R2, GCS, and Backblaze B2
2. **AWS SigV4 authentication** for all S3-compatible providers
3. **Disk spillover** that persists entries when memory fills or S3 fails
4. **Replication lag metrics** for observability

The Zig standard library provides `std.http.Client` with TLS support and `std.crypto.auth.hmac.sha2.HmacSha256` for SigV4 signing. No external dependencies are required.

**Primary recommendation:** Implement S3 uploads using Zig's `std.http.Client` with a custom SigV4 signing module. Use the existing spillover file format from `ShipQueue.spillToDisk()` with enhanced metadata tracking.

## Standard Stack

The established libraries/tools for this domain:

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `std.http.Client` | Zig 0.14+ | HTTP client with TLS | Built-in, supports HTTPS required for S3 |
| `std.crypto.auth.hmac.sha2.HmacSha256` | Zig 0.14+ | HMAC-SHA256 for SigV4 | Built-in, no external dependency |
| `std.crypto.hash.sha2.Sha256` | Zig 0.14+ | SHA256 hashing for SigV4 | Built-in |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `std.crypto.tls` | Zig 0.14+ | TLS 1.3 support | Automatic with http.Client |
| `std.Uri` | Zig 0.14+ | URL parsing | Endpoint parsing |
| `std.base64` | Zig 0.14+ | Base64 encoding | Content-MD5 header |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Pure Zig SigV4 | Bind to AWS C SDK | Pure Zig is simpler, AWS SDK adds FFI complexity |
| std.http.Client | curl binding | std.http is sufficient, curl adds dependency |

**Installation:**
No external dependencies required. All functionality available in Zig standard library.

## Architecture Patterns

### Recommended Project Structure
```
src/
├── replication.zig          # Existing - extend S3RelayTransport
├── replication/
│   ├── s3_client.zig        # NEW: S3 HTTP client
│   ├── sigv4.zig            # NEW: AWS SigV4 signing
│   ├── spillover.zig        # NEW: Enhanced disk spillover
│   └── providers.zig        # NEW: Provider-specific adaptations
```

### Pattern 1: S3 Client Architecture
**What:** Layered S3 client with signing separated from HTTP
**When to use:** All S3 operations
**Example:**
```zig
// Source: Based on AWS SigV4 documentation
const S3Client = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    credentials: Credentials,
    endpoint: []const u8,
    region: []const u8,

    pub fn putObject(
        self: *S3Client,
        bucket: []const u8,
        key: []const u8,
        body: []const u8,
        content_md5: ?[16]u8,
    ) !PutObjectResult {
        // 1. Build canonical request
        const canonical_request = try self.buildCanonicalRequest(.PUT, bucket, key, body);

        // 2. Sign request
        const auth_header = try sigv4.sign(
            self.credentials,
            canonical_request,
            self.region,
            "s3",
        );

        // 3. Execute HTTP request
        var request = try self.http_client.request(.PUT, uri, .{});
        try request.headers.append("Authorization", auth_header);
        // ... execute and return result
    }
};
```

### Pattern 2: SigV4 Signing
**What:** AWS Signature Version 4 implementation
**When to use:** All S3 API calls
**Example:**
```zig
// Source: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
pub fn sign(
    credentials: Credentials,
    request: CanonicalRequest,
    region: []const u8,
    service: []const u8,
) ![]const u8 {
    // Step 1: Create canonical request string
    const canonical_string = try createCanonicalString(request);

    // Step 2: Hash canonical request
    var canonical_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_string, &canonical_hash, .{});

    // Step 3: Create string to sign
    const string_to_sign = try createStringToSign(
        request.datetime,
        region,
        service,
        &canonical_hash,
    );

    // Step 4: Derive signing key
    const signing_key = try deriveSigningKey(
        credentials.secret_access_key,
        request.date,
        region,
        service,
    );

    // Step 5: Calculate signature
    var signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, string_to_sign, &signing_key);

    // Step 6: Build Authorization header
    return try buildAuthorizationHeader(
        credentials.access_key_id,
        request.date,
        region,
        service,
        request.signed_headers,
        &signature,
    );
}
```

### Pattern 3: Exponential Backoff with Jitter
**What:** Retry strategy per CONTEXT.md decisions
**When to use:** S3 upload failures
**Example:**
```zig
// Source: Phase CONTEXT.md - 1s, 2s, 4s, 8s... up to 10 retries
pub fn calculateBackoff(retry_count: u32, prng: *std.rand.Random) u64 {
    const base_delay_ms: u64 = 1000; // 1 second initial
    const max_delay_ms: u64 = 512_000; // ~8.5 minutes max

    // Exponential: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s, 512s
    const delay = @min(
        base_delay_ms << @intCast(retry_count),
        max_delay_ms,
    );

    // Add jitter: +/- 25%
    const jitter_range = delay / 4;
    const jitter = prng.intRangeAtMost(i64, -@intCast(jitter_range), @intCast(jitter_range));

    return @intCast(@max(0, @as(i64, @intCast(delay)) + jitter));
}
```

### Pattern 4: Disk Spillover with Metadata
**What:** Enhanced spillover format with recovery tracking
**When to use:** Memory pressure or S3 failures
**Example:**
```zig
// Spillover directory structure
// {data_dir}/spillover/
//   ├── meta.json          # Index of spillover files
//   ├── 000001.spill       # Spillover segment files
//   ├── 000002.spill
//   └── ...

const SpilloverMeta = struct {
    version: u16 = 1,
    segment_count: u32,
    oldest_op: u64,
    newest_op: u64,
    total_bytes: u64,
    created_at_ns: u64,
    last_upload_attempt_ns: u64,
    consecutive_failures: u32,
};

const SpilloverSegment = struct {
    // Header per segment file
    magic: [4]u8 = .{ 'S', 'P', 'I', 'L' },
    version: u16 = 1,
    entry_count: u32,
    total_bytes: u64,
    // Followed by concatenated ShipEntry + body pairs
};
```

### Anti-Patterns to Avoid
- **Synchronous S3 uploads in write path:** Never block database writes on S3. Always queue asynchronously.
- **Unbounded memory queue:** Always have spillover configured to prevent OOM.
- **Ignoring multipart thresholds:** Files >= 100MB MUST use multipart upload or S3 rejects.
- **Missing Content-MD5:** Always verify uploads with checksums; silent corruption is unacceptable.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| URL encoding | Custom encoder | `std.Uri.encodeUnreserved()` | RFC 3986 compliance required for SigV4 |
| Date formatting | String concatenation | `std.time.Instant` formatting | ISO 8601 format required exactly |
| HMAC-SHA256 | Custom implementation | `std.crypto.auth.hmac.sha2.HmacSha256` | Security-critical, must be constant-time |
| HTTP/TLS | Raw socket + TLS handshake | `std.http.Client` | Connection pooling, TLS 1.3, compression |
| Base64 | Custom encoder | `std.base64.standard` | Content-MD5 header encoding |

**Key insight:** SigV4 signing is extremely sensitive to canonicalization. One byte difference in URL encoding or header formatting breaks authentication. Use standard library functions exclusively.

## Common Pitfalls

### Pitfall 1: SigV4 Canonicalization Errors
**What goes wrong:** Authentication failures (403 Forbidden) due to request/signature mismatch
**Why it happens:** AWS expects exact canonicalization:
- Headers must be lowercase, sorted alphabetically
- Header values must have leading/trailing whitespace trimmed
- URI must be URI-encoded (except `/`)
- Query parameters must be sorted by key name
**How to avoid:**
- Build canonical request step-by-step with explicit sorting
- Log canonical request during development for debugging
- Test against MinIO which has helpful error messages
**Warning signs:** `SignatureDoesNotMatch` error from S3

### Pitfall 2: Content-MD5 Calculation
**What goes wrong:** Upload succeeds but data is corrupted
**Why it happens:** Content-MD5 not verified or calculated incorrectly
**How to avoid:**
- Always include `Content-MD5` header for single-part uploads
- Use `x-amz-content-sha256` (REQUIRED for SigV4)
- For multipart: calculate MD5 per part, store in CompleteMultipartUpload request
**Warning signs:** ETag mismatch after upload, silent data corruption

### Pitfall 3: Multipart Upload Lifecycle
**What goes wrong:** Incomplete multipart uploads accumulate, wasting storage
**Why it happens:** Upload started but never completed/aborted on failure
**How to avoid:**
- Always abort multipart upload on any error after initiation
- Implement bucket lifecycle policy to clean up incomplete uploads after 7 days
- Track in-progress upload IDs for recovery
**Warning signs:** S3 storage costs higher than expected

### Pitfall 4: Provider Endpoint Variations
**What goes wrong:** Code works for AWS but fails for R2/GCS/MinIO
**Why it happens:** Each provider has subtle differences:
- MinIO: Path-style URLs only (no virtual-hosted style)
- R2: Region is always "auto", requires specific signing
- GCS: Uses HMAC keys, different endpoint format
- Backblaze: V4 only, endpoint includes region
**How to avoid:**
- Auto-detect provider from endpoint URL
- Provider-specific adapter for URL formatting
- Test against MinIO in CI (covers most edge cases)
**Warning signs:** Works in dev (AWS) but fails in CI (MinIO)

### Pitfall 5: Spillover File Corruption
**What goes wrong:** Recovery fails, data is lost
**Why it happens:** Crash during spillover write leaves partial file
**How to avoid:**
- Write to temp file, then atomic rename
- Include checksum in spillover segment header
- Skip corrupted segments during recovery (log warning)
**Warning signs:** Recovery complains about invalid magic or checksum

## Code Examples

Verified patterns from official sources:

### SigV4 Signing Key Derivation
```zig
// Source: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
fn deriveSigningKey(
    secret_key: []const u8,
    date: []const u8, // YYYYMMDD
    region: []const u8,
    service: []const u8,
) [32]u8 {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

    // DateKey = HMAC("AWS4" + SecretAccessKey, Date)
    var date_key: [32]u8 = undefined;
    var prefixed_key: [4 + secret_key.len]u8 = undefined;
    @memcpy(prefixed_key[0..4], "AWS4");
    @memcpy(prefixed_key[4..], secret_key);
    HmacSha256.create(&date_key, date, &prefixed_key);

    // DateRegionKey = HMAC(DateKey, Region)
    var date_region_key: [32]u8 = undefined;
    HmacSha256.create(&date_region_key, region, &date_key);

    // DateRegionServiceKey = HMAC(DateRegionKey, Service)
    var date_region_service_key: [32]u8 = undefined;
    HmacSha256.create(&date_region_service_key, service, &date_region_key);

    // SigningKey = HMAC(DateRegionServiceKey, "aws4_request")
    var signing_key: [32]u8 = undefined;
    HmacSha256.create(&signing_key, "aws4_request", &date_region_service_key);

    return signing_key;
}
```

### Authorization Header Format
```zig
// Source: https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-auth-using-authorization-header.html
// Format: AWS4-HMAC-SHA256 Credential=<access_key>/<date>/<region>/s3/aws4_request,
//         SignedHeaders=<headers>, Signature=<signature>
fn buildAuthorizationHeader(
    allocator: Allocator,
    access_key_id: []const u8,
    date: []const u8,
    region: []const u8,
    signed_headers: []const u8,
    signature: *const [32]u8,
) ![]const u8 {
    const signature_hex = std.fmt.bytesToHex(signature.*, .lower);
    return std.fmt.allocPrint(allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/s3/aws4_request, SignedHeaders={s}, Signature={s}",
        .{ access_key_id, date, region, signed_headers, &signature_hex },
    );
}
```

### Required S3 Headers
```zig
// Source: https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
fn addS3Headers(
    request: *std.http.Client.Request,
    payload_hash: *const [64]u8, // hex-encoded SHA256
    content_md5: ?*const [24]u8, // base64-encoded MD5 (optional but recommended)
) !void {
    // Required: Host (set automatically by http.Client)

    // Required: x-amz-content-sha256 (REQUIRED for S3 SigV4)
    try request.headers.append("x-amz-content-sha256", payload_hash);

    // Required: x-amz-date
    var date_buf: [16]u8 = undefined;
    const date = try formatAmzDate(&date_buf);
    try request.headers.append("x-amz-date", date);

    // Recommended: Content-MD5 for integrity
    if (content_md5) |md5| {
        try request.headers.append("Content-MD5", md5);
    }
}
```

### MinIO Integration Test Setup
```zig
// Source: Phase requirements REPL-10
// MinIO Docker container for CI testing
const MinioTestContext = struct {
    process: std.process.Child,
    endpoint: []const u8,
    access_key: []const u8,
    secret_key: []const u8,

    pub fn start(allocator: Allocator) !MinioTestContext {
        // docker run -d -p 9000:9000 -e MINIO_ROOT_USER=minioadmin
        //            -e MINIO_ROOT_PASSWORD=minioadmin minio/minio server /data
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "docker", "run", "-d", "--rm",
                "-p", "9000:9000",
                "-e", "MINIO_ROOT_USER=minioadmin",
                "-e", "MINIO_ROOT_PASSWORD=minioadmin",
                "minio/minio", "server", "/data",
            },
        });
        // Wait for MinIO to be ready
        std.time.sleep(2 * std.time.ns_per_s);
        return .{
            .process = result,
            .endpoint = "http://localhost:9000",
            .access_key = "minioadmin",
            .secret_key = "minioadmin",
        };
    }
};
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SigV2 | SigV4 (required) | 2019 | Backblaze only supports V4; AWS deprecated V2 |
| Content-MD5 only | SHA256 checksums preferred | 2022 | x-amz-content-sha256 now required for SigV4 |
| XML-only API | JSON also available | 2023 | S3 still primarily XML; JSON for some operations |
| Single region keys | SigV4a for multi-region | 2022 | Multi-Region Access Points need asymmetric signing |

**Deprecated/outdated:**
- AWS Signature Version 2: Completely deprecated, most providers reject it
- Virtual-hosted style with dots in bucket names: MinIO and some providers don't support
- HTTP (non-TLS): All major providers require HTTPS for API access

## Open Questions

Things that couldn't be fully resolved:

1. **GCS HMAC Key Behavior**
   - What we know: GCS supports S3-compatible API via HMAC keys
   - What's unclear: Exact header requirements vs AWS
   - Recommendation: Test with GCS emulator in CI if GCS support is critical

2. **Zig std.http.Client Connection Pooling**
   - What we know: Connection pooling exists in 0.14+
   - What's unclear: Optimal pool size for S3 workload
   - Recommendation: Start with default, tune based on metrics

3. **Multipart Upload Part Size**
   - What we know: 100MB threshold per CONTEXT.md
   - What's unclear: Optimal part size for performance (AWS recommends 8-16MB)
   - Recommendation: Use 16MB parts for >= 100MB files

## Sources

### Primary (HIGH confidence)
- [AWS SigV4 Documentation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html) - Signing algorithm details
- [AWS S3 API Reference](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-auth-using-authorization-header.html) - Authorization header format
- [Zig std.crypto.auth.hmac](https://github.com/ziglang/zig/blob/master/lib/std/crypto/hmac.zig) - HMAC implementation
- Codebase: `src/replication.zig` - Existing transport abstraction

### Secondary (MEDIUM confidence)
- [MinIO S3 Compatibility](https://min.io/product/s3-compatibility) - Provider compatibility notes
- [Cloudflare R2 S3 API](https://developers.cloudflare.com/r2/api/s3/) - R2 differences
- [GCS Interoperability](https://docs.cloud.google.com/storage/docs/interoperability) - GCS HMAC keys
- [Backblaze B2 S3 API](https://www.backblaze.com/docs/cloud-storage-s3-compatible-api) - V4 only requirement

### Tertiary (LOW confidence)
- General patterns for disk-based queues (rsyslog, RabbitMQ documentation)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Zig stdlib well-documented, AWS SigV4 spec is authoritative
- Architecture: HIGH - Based on existing codebase patterns and AWS best practices
- Pitfalls: HIGH - AWS documentation explicitly covers these error cases

**Research date:** 2026-01-22
**Valid until:** 2026-03-22 (60 days - S3 API stable, Zig stdlib stable)

---

## Provider-Specific Notes

### AWS S3
- Endpoint: `https://s3.{region}.amazonaws.com`
- Virtual-hosted style: `https://{bucket}.s3.{region}.amazonaws.com`
- Path style: `https://s3.{region}.amazonaws.com/{bucket}`
- Region: Required, must match bucket region

### MinIO
- Endpoint: User-configured (e.g., `http://minio.local:9000`)
- Path style only recommended
- Region: Typically "us-east-1" (default)
- SigV4 and V2 both supported (use V4)

### Cloudflare R2
- Endpoint: `https://{account_id}.r2.cloudflarestorage.com`
- Region: Always "auto"
- Requires specific `service=s3` in signing
- CORS support improved in 2025

### Google Cloud Storage
- Endpoint: `https://storage.googleapis.com`
- Uses HMAC keys (not IAM)
- Region: Multi-region by default
- No batch delete API (delete individually)

### Backblaze B2
- Endpoint: `https://s3.{region}.backblazeb2.com`
- Region: Extracted from endpoint (e.g., "us-west-001")
- SigV4 only (V2 not supported)
- HTTPS required

---

## Metrics to Expose

Per CONTEXT.md requirements for replication lag metrics:

| Metric | Type | Description |
|--------|------|-------------|
| `archerdb_replication_lag_seconds` | Gauge | Time since oldest unuploaded segment |
| `archerdb_replication_lag_ops` | Gauge | Number of unuploaded operations |
| `archerdb_replication_queue_depth` | Gauge | Total entries pending (memory + disk) |
| `archerdb_replication_spillover_bytes` | Gauge | Bytes on disk spillover |
| `archerdb_replication_uploads_total` | Counter | Total successful uploads |
| `archerdb_replication_upload_failures_total` | Counter | Total failed upload attempts |
| `archerdb_replication_upload_latency_seconds` | Histogram | Upload latency (p50/p95/p99) |
| `archerdb_replication_state` | Gauge | 0=healthy, 1=degraded, 2=failed |

Health endpoint should return replication state in `/health/region` response (already exists in metrics_server.zig).
