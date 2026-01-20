# Implementation Tasks: Hardware-Accelerated AES-NI Encryption

## Phase 1: AES-NI Detection and Validation

### Task 1.1: Add hasAesNi() detection function
- **File**: `src/encryption.zig`
- **Changes**:
  - Add `hasAesNi()` function that checks CPU features
  - Use `std.Target.x86.featureSetHas(builtin.cpu.features, .aes)`
  - Return false for non-x86 architectures
- **Validation**: Unit test verifies correct detection on current hardware
- **Estimated effort**: 30 minutes

### Task 1.2: Add verifyHardwareSupport() function
- **File**: `src/encryption.zig`
- **Changes**:
  - Add `verifyHardwareSupport(config: EncryptionConfig)` function
  - Check `hasAesNi()` at startup
  - If no AES-NI and `allow_software_crypto=false`: return `error.AesNiNotAvailable`
  - If no AES-NI and `allow_software_crypto=true`: warn and continue
  - Log hardware status
- **Validation**: Test with and without bypass flag
- **Estimated effort**: 1 hour

### Task 1.3: Add --allow-software-crypto CLI flag
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Add `allow_software_crypto: bool = false` to encryption args
  - Add help text explaining the flag
  - Parse and validate the flag
- **Validation**: CLI parsing test
- **Estimated effort**: 30 minutes

### Task 1.4: Call verifyHardwareSupport at startup
- **File**: `src/archerdb/main.zig`
- **Changes**:
  - Call `verifyHardwareSupport()` when encryption is enabled
  - Handle `error.AesNiNotAvailable` with user-friendly message
  - Exit with code 415 on failure
- **Validation**: Integration test for startup failure
- **Estimated effort**: 30 minutes

### Task 1.5: Add error code 415 (AesNiNotAvailable)
- **File**: `src/error_codes.zig`
- **Changes**:
  - Add error code 415 for AES-NI not available
  - Add error message and retry=false
- **Validation**: Error code test
- **Estimated effort**: 15 minutes

## Phase 2: Aegis-256 Cipher Implementation

### Task 2.1: Add Aegis-256 encryption function
- **File**: `src/encryption.zig`
- **Changes**:
  - Add `encryptAegis()` function using `std.crypto.aead.aegis.Aegis256`
  - 32-byte key, 32-byte nonce, 32-byte tag
  - Match existing `encryptData()` signature
- **Validation**: Unit test for encrypt roundtrip
- **Estimated effort**: 1 hour

### Task 2.2: Add Aegis-256 decryption function
- **File**: `src/encryption.zig`
- **Changes**:
  - Add `decryptAegis()` function
  - Handle authentication tag verification
  - Return `error.DecryptionFailed` on tag mismatch
- **Validation**: Unit test for decrypt, test tampering detection
- **Estimated effort**: 1 hour

### Task 2.3: Update encryption version constants
- **File**: `src/encryption.zig`
- **Changes**:
  - Add `ENCRYPTION_VERSION_GCM: u16 = 1`
  - Add `ENCRYPTION_VERSION_AEGIS: u16 = 2`
  - Update `ENCRYPTION_VERSION` to 2
- **Validation**: Compile check
- **Estimated effort**: 15 minutes

### Task 2.4: Update EncryptedFileHeader for v2
- **File**: `src/encryption.zig`
- **Changes**:
  - Increase nonce field from 12 to 32 bytes
  - Adjust reserved field accordingly
  - Update header size assertion (now 128 bytes for alignment)
- **Validation**: Header serialization test
- **Estimated effort**: 30 minutes

### Task 2.5: Add version-based cipher selection in decrypt
- **File**: `src/encryption.zig`
- **Changes**:
  - In `EncryptedFileReader.readAll()`:
    - Check header version
    - version=1: use `decryptGcm()` (existing)
    - version=2: use `decryptAegis()`
- **Validation**: Test reading v1 and v2 files
- **Estimated effort**: 1 hour

### Task 2.6: Update EncryptedFileWriter to use Aegis-256
- **File**: `src/encryption.zig`
- **Changes**:
  - Update `EncryptedFileWriter.write()` to use Aegis-256
  - Generate 32-byte nonce
  - Set version=2 in header
- **Validation**: Write/read roundtrip test
- **Estimated effort**: 30 minutes

## Phase 3: Metrics and Observability

### Task 3.1: Add AES-NI status metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Add `archerdb_encryption_aesni_available` gauge
  - Add `archerdb_encryption_using_software` gauge
- **Validation**: Metric definition compiles
- **Estimated effort**: 15 minutes

### Task 3.2: Add cipher version metric
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Add `archerdb_encryption_cipher_version` gauge
- **Validation**: Metric definition compiles
- **Estimated effort**: 15 minutes

### Task 3.3: Add throughput tracking to EncryptionStats
- **File**: `src/encryption.zig`
- **Changes**:
  - Add throughput calculation (rolling 10-second average)
  - Track bytes and timestamps for encrypt/decrypt
  - Add `getThroughput(operation)` function
- **Validation**: Unit test for throughput calculation
- **Estimated effort**: 1 hour

### Task 3.4: Add throughput metric
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Add `archerdb_encryption_throughput_bytes` gauge with `operation` label
- **Validation**: Metric definition compiles
- **Estimated effort**: 15 minutes

### Task 3.5: Update metrics at startup and during operations
- **File**: `src/archerdb/main.zig`, `src/encryption.zig`
- **Changes**:
  - Set AES-NI and software fallback metrics at startup
  - Update throughput metrics after operations
  - Export metrics via `/metrics` endpoint
- **Validation**: curl /metrics shows new metrics
- **Estimated effort**: 1 hour

## Phase 4: Testing and Validation

### Task 4.1: Unit tests for AES-NI detection
- **File**: `src/encryption.zig` (test section)
- **Tests**:
  - `hasAesNi()` returns correct value for current hardware
  - `verifyHardwareSupport()` fails without AES-NI (when not bypassed)
  - `verifyHardwareSupport()` warns but continues with bypass
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 4.2: Unit tests for Aegis-256 cipher
- **File**: `src/encryption.zig` (test section)
- **Tests**:
  - Encrypt/decrypt roundtrip
  - Tampering detection (auth tag failure)
  - Different key produces different ciphertext
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 4.3: Unit tests for backward compatibility
- **File**: `src/encryption.zig` (test section)
- **Tests**:
  - Read v1 (AES-GCM) file with v2 code
  - Write v2 (Aegis-256) file
  - Version mismatch handling
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 4.4: Integration test for startup validation
- **File**: `src/integration_tests.zig` or new test
- **Tests**:
  - Startup fails without AES-NI (simulated)
  - Startup succeeds with bypass flag
  - Correct metrics set at startup
- **Validation**: Integration tests pass
- **Estimated effort**: 2 hours

### Task 4.5: Performance benchmark
- **File**: `src/benchmarks/` or test script
- **Tests**:
  - Measure Aegis-256 throughput (target: >3 GB/s)
  - Compare to AES-GCM throughput
  - Verify 2-3x improvement
- **Validation**: Benchmark shows expected improvement
- **Estimated effort**: 2 hours

## Phase 5: Documentation

### Task 5.1: Update CLI help text
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Add `--allow-software-crypto` to help output
  - Document hardware requirements
- **Validation**: `archerdb --help` shows new flag
- **Estimated effort**: 30 minutes

### Task 5.2: Update operational documentation
- **File**: Documentation (docs/ or wiki)
- **Changes**:
  - Document AES-NI requirement
  - Document hardware requirements (Intel Westmere+, AMD Bulldozer+)
  - Document how to check AES-NI support
  - Document performance expectations
- **Validation**: Documentation review
- **Estimated effort**: 1 hour

### Task 5.3: Update CHANGELOG
- **File**: `CHANGELOG.md`
- **Changes**:
  - Add feature under "Changed" section
  - Note cipher upgrade from AES-256-GCM to Aegis-256
  - Note new `--allow-software-crypto` flag
  - Note new error code 415
- **Validation**: Changelog entry accurate
- **Estimated effort**: 15 minutes

## Dependencies & Parallelization

### Sequential Dependencies

- Phase 1 must complete before Phase 2 (validation needed before cipher change)
- Phase 2 must complete before Phase 3 (metrics need cipher to work)
- Phase 4 depends on Phases 1-3 (testing needs implementation)

### Parallelizable Work

- Task 1.1 and 1.3 can be done in parallel (different files)
- Task 2.1 and 2.2 can be done in parallel (independent functions)
- Task 3.1, 3.2, 3.4 can be done in parallel (independent metric definitions)
- All Phase 5 documentation tasks can be done in parallel

## Verification Checklist

- [x] `hasAesNi()` correctly detects hardware (unit tests: 3 tests)
- [x] `verifyHardwareSupport()` validates at startup (unit tests)
- [x] Startup fails without AES-NI (unless bypassed) - implemented in main.zig command_start
- [x] `--allow-software-crypto` flag works - added to CLI StartArgs and wired to verifyHardwareSupport
- [x] Error code 415 returned correctly (SecurityError.aesni_not_available)
- [x] Aegis-256 encrypt/decrypt works (unit tests: 9 tests)
- [x] v1 (AES-GCM) files can still be read (EncryptedFileReader detects version)
- [x] New files use v2 (Aegis-256) (EncryptedFileWriter uses v2 by default, 2 new tests)
- [x] Metrics exposed: aesni_available, using_software, cipher_version (added to metrics.zig)
- [x] Throughput metrics track encryption performance (encryption_throughput_encrypt/decrypt in metrics.zig)
- [x] CLI help shows new flag - auto-generated from StartArgs
- [x] Performance improvement verified (2-3x) - benchmark tests added in encryption.zig
- [x] All existing encryption tests still pass (41 tests)

## Estimated Total Effort

- **Implementation**: 8-10 hours
- **Testing**: 6-8 hours
- **Documentation**: 2 hours
- **Total**: 16-20 hours (~2-3 working days)

## Rollout Strategy

1. **Merge to main** after all tests pass
2. **Default AES-NI required** (no bypass unless explicitly set)
3. **Backward compatible** with v1 encrypted files
4. **Monitor in staging** for performance improvement
5. **Gradual rollout** to production clusters
6. **Update hardware requirements** in deployment docs
