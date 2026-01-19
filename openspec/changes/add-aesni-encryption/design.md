# Design: Hardware-Accelerated AES-NI Encryption

## Context

The current encryption implementation uses Zig's `std.crypto.aead.aes_gcm.Aes256Gcm` which automatically uses hardware AES-NI when available. However:

1. There's no explicit validation that AES-NI is available
2. Silent fallback to software AES causes 10x performance degradation
3. Aegis-256 is 2.5x faster than AES-GCM with AES-NI
4. Aegis-128L is already used for checksums (via `src/vsr/checksum.zig`)

This proposal makes AES-NI an explicit requirement and switches to Aegis-256 for better performance.

## Goals / Non-Goals

### Goals

1. **Explicit AES-NI requirement**: Fail at startup if hardware not available
2. **Better cipher**: Switch to Aegis-256 (2.5x faster, same security)
3. **Observability**: Metrics for hardware status and throughput
4. **Clear documentation**: Hardware requirements and performance expectations

### Non-Goals

1. **ARM64 support**: Future work, not this proposal
2. **Key management changes**: Existing model unchanged
3. **Backward incompatibility**: Must read existing encrypted files

## Decisions

### Decision 1: Use Aegis-256 for Data Encryption

**Choice**: Replace AES-256-GCM with Aegis-256.

**Rationale**:
- **Performance**: Aegis-256 is ~2.5x faster than AES-GCM on AES-NI hardware
- **Security**: 256-bit key, 256-bit tag, proven secure (CAESAR finalist)
- **Consistency**: Already use Aegis-128L for checksums
- **Implementation**: Available in Zig stdlib (`std.crypto.aead.aegis.Aegis256`)

**Benchmarks** (Intel Core i7, AES-NI):
| Cipher | Throughput |
|--------|------------|
| AES-256-GCM (software) | ~150 MB/s |
| AES-256-GCM (AES-NI) | ~1.5 GB/s |
| Aegis-256 (AES-NI) | ~4 GB/s |

**Trade-off**: Requires AES-NI, no software fallback in production.

### Decision 2: Explicit AES-NI Detection at Startup

**Choice**: Check for AES-NI at startup and fail if unavailable.

**Rationale**:
- **Explicit is better**: No silent performance degradation
- **Consistent**: Aegis-128L checksums already require AES-NI
- **Documented**: Clear hardware requirement in docs

**Implementation**:
```zig
const has_aes = std.Target.x86.featureSetHas(builtin.cpu.features, .aes);

pub fn verifyHardwareSupport() !void {
    if (!has_aes) {
        if (config.allow_software_crypto) {
            log.warn("AES-NI not available, using software fallback (NOT RECOMMENDED)", .{});
            return;
        }
        return error.AesNiNotAvailable;
    }
    log.info("AES-NI hardware acceleration available", .{});
}
```

### Decision 3: Configurable Bypass for Testing

**Choice**: Add `--allow-software-crypto` flag for testing environments.

**Rationale**:
- **Testing VMs**: May not have AES-NI in CI/CD
- **Development**: Allow development on older hardware
- **Explicit opt-in**: Must be explicitly enabled, warns loudly

**Configuration**:
```
--allow-software-crypto=true  # Allow software fallback (NOT FOR PRODUCTION)
```

**Log warning when enabled**:
```
WARN: Running with software cryptography - 10x slower, NOT RECOMMENDED for production
```

### Decision 4: Backward Compatibility via Cipher Version

**Choice**: Support both AES-256-GCM (v1) and Aegis-256 (v2) reading.

**Rationale**:
- **Migration path**: Can read existing encrypted files
- **No re-encryption**: Existing files work without migration
- **Future-proof**: Header version field enables future cipher changes

**Implementation**:
```zig
pub const ENCRYPTION_VERSION_GCM: u16 = 1;    // AES-256-GCM (v1)
pub const ENCRYPTION_VERSION_AEGIS: u16 = 2;  // Aegis-256 (v2)
pub const ENCRYPTION_VERSION: u16 = ENCRYPTION_VERSION_AEGIS;

pub fn decryptFile(header: *const Header, ...) ![]u8 {
    return switch (header.version) {
        1 => decryptGcm(...),  // Legacy support
        2 => decryptAegis(...),
        else => error.UnsupportedVersion,
    };
}
```

**New files**: Always use Aegis-256 (v2)
**Existing files**: Read with appropriate cipher based on version

## Architecture

### Component Changes

#### 1. Hardware Detection (src/encryption.zig)

```zig
const std = @import("std");
const builtin = @import("builtin");

/// Check if AES-NI is available on this CPU
pub fn hasAesNi() bool {
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .aes,
        ),
        else => false,
    };
}

/// Verify hardware crypto support at startup
pub fn verifyHardwareSupport(config: EncryptionConfig) !void {
    if (!hasAesNi()) {
        if (config.allow_software_crypto) {
            log.warn("AES-NI not available, using software fallback", .{});
            global_stats.using_software_crypto.store(true, .monotonic);
            return;
        }
        log.err("AES-NI required but not available. Use --allow-software-crypto to bypass.", .{});
        return error.AesNiNotAvailable;
    }
    log.info("AES-NI hardware acceleration enabled", .{});
}
```

#### 2. Aegis-256 Cipher (src/encryption.zig)

```zig
const Aegis256 = std.crypto.aead.aegis.Aegis256;

/// Encrypt data using Aegis-256
pub fn encryptAegis(
    allocator: Allocator,
    plaintext: []const u8,
    dek: *const [32]u8,
    nonce: *const [32]u8,
    aad: []const u8,
) ![]u8 {
    const ciphertext = try allocator.alloc(u8, plaintext.len + Aegis256.tag_length);
    errdefer allocator.free(ciphertext);

    var tag: [Aegis256.tag_length]u8 = undefined;
    Aegis256.encrypt(ciphertext[0..plaintext.len], &tag, plaintext, aad, nonce.*, dek.*);
    @memcpy(ciphertext[plaintext.len..], &tag);

    return ciphertext;
}
```

#### 3. Configuration (src/archerdb/cli.zig)

```zig
/// CLI arguments for encryption
pub const EncryptionArgs = struct {
    encryption_enabled: bool = false,
    encryption_key_provider: ?KeyProviderType = null,
    encryption_key_id: ?[]const u8 = null,
    allow_software_crypto: bool = false,  // NEW
};
```

#### 4. Metrics (src/archerdb/metrics.zig)

```zig
pub const archerdb_encryption_aesni_available = struct {
    pub const help = "Whether AES-NI hardware acceleration is available (1=yes, 0=no)";
    pub const type_name = "gauge";
};

pub const archerdb_encryption_using_software = struct {
    pub const help = "Whether using software crypto fallback (1=yes, 0=no)";
    pub const type_name = "gauge";
};

pub const archerdb_encryption_throughput_bytes_per_second = struct {
    pub const help = "Encryption throughput in bytes per second (rolling average)";
    pub const type_name = "gauge";
};
```

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Startup                                                       │
│    └─> verifyHardwareSupport()                                  │
│        └─> hasAesNi() → true: continue                          │
│        └─> hasAesNi() → false:                                  │
│            └─> allow_software_crypto? → warn, continue          │
│            └─> else → error.AesNiNotAvailable (startup fails)   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Write Encrypted File                                          │
│    └─> Generate DEK, nonce                                      │
│    └─> encryptAegis(plaintext, dek, nonce, aad)                 │
│    └─> Write header with version=2 (Aegis-256)                  │
│    └─> Update metrics (encrypt_ops, bytes_encrypted)            │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Read Encrypted File                                           │
│    └─> Read header, check version                               │
│    └─> version=1: decryptGcm() (legacy)                         │
│    └─> version=2: decryptAegis() (current)                      │
│    └─> Update metrics (decrypt_ops, bytes_decrypted)            │
└─────────────────────────────────────────────────────────────────┘
```

## Trade-Offs

### Chosen Approach: Explicit AES-NI Requirement

**Pros**:
- No silent performance degradation
- Clear hardware requirements for operators
- Consistent with checksum requirements

**Cons**:
- Cannot run on very old hardware without bypass flag
- Requires flag for some CI/CD environments

### Alternative: Keep Automatic Fallback

**Why Rejected**:
- Silent 10x performance degradation is unacceptable
- Operators may not realize encryption is slow
- Inconsistent with Aegis-128L checksum requirements

## Migration Plan

### Phase 1: Add Hardware Detection

1. Add `hasAesNi()` function
2. Add `verifyHardwareSupport()` called at startup
3. Add `--allow-software-crypto` flag
4. Update existing tests to handle new behavior

### Phase 2: Add Aegis-256 Cipher

1. Add `encryptAegis()` and `decryptAegis()` functions
2. Update version constant to 2
3. Add version-based cipher selection in decrypt
4. New files use Aegis-256 (v2)

### Phase 3: Metrics and Documentation

1. Add AES-NI status metrics
2. Add throughput metrics
3. Update operational documentation
4. Add hardware requirements to README

## Validation Plan

### Unit Tests

1. **Hardware detection**: Test `hasAesNi()` returns correct value
2. **Aegis-256 roundtrip**: Encrypt/decrypt with Aegis-256
3. **Version compatibility**: Read v1 (GCM) files, write v2 (Aegis)
4. **Bypass flag**: Test software fallback when flag enabled

### Integration Tests

1. **Startup validation**: Verify startup fails without AES-NI (in non-bypass mode)
2. **Backward compatibility**: Read existing encrypted files after upgrade
3. **Performance benchmark**: Verify 2-3x improvement over GCM

### Performance Tests

1. **Throughput**: Measure encryption throughput (target: >3 GB/s)
2. **Latency**: Measure per-operation latency
3. **CPU utilization**: Measure CPU impact during encryption
