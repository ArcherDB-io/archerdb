# Proposal: Hardware-Accelerated AES-NI Encryption

## Summary

Upgrade encryption at rest from software AES-256-GCM to hardware-accelerated Aegis-256 with explicit AES-NI detection, startup validation, and observability metrics.

## Motivation

### Problem

The current v1 encryption implementation (`src/encryption.zig`) uses:
- `std.crypto.aead.aes_gcm.Aes256Gcm` - Zig's standard library AES-GCM
- Automatic hardware detection (uses AES-NI if available, falls back to software)
- No explicit validation that AES-NI is available
- No metrics for encryption hardware status

This has several issues:
1. **Silent fallback**: If AES-NI isn't available, encryption silently uses software AES (10x slower)
2. **No observability**: Operators cannot verify hardware acceleration is active
3. **Suboptimal cipher**: AES-GCM is ~2.5x slower than Aegis-256 on AES-NI hardware
4. **Inconsistent requirements**: Aegis-128L (checksums) requires AES-NI but encryption doesn't

### Current Behavior

- Encryption uses software AES-256-GCM by default
- No startup check for AES-NI availability
- No metrics for encryption hardware status
- Performance: ~1.5 GB/s on modern CPUs (software fallback: ~150 MB/s)

### Desired Behavior

- **Explicit AES-NI requirement**: Fail at startup if AES-NI unavailable (opt-out for testing)
- **Aegis-256 cipher**: 2.5x faster than AES-GCM, same security level
- **Hardware metrics**: Expose AES-NI status and encryption throughput
- **Documentation**: Clear hardware requirements and performance expectations

## Scope

### In Scope

1. **Cipher upgrade**: Replace AES-256-GCM with Aegis-256 for data encryption
2. **AES-NI detection**: Explicit runtime check with startup validation
3. **Startup failure**: Fail fast if AES-NI unavailable (configurable bypass)
4. **Observability**: Metrics for hardware status and encryption performance
5. **Documentation**: Hardware requirements, performance benchmarks

### Out of Scope

1. **ARM64 NEON support** - Future work for ARM servers
2. **Key management changes** - Existing KEK/DEK model unchanged
3. **File format change** - Header remains 96 bytes, just different cipher

## Success Criteria

1. **Explicit validation**: Startup fails without AES-NI (unless bypassed)
2. **Performance improvement**: 2-3x faster encryption vs current implementation
3. **Observability**: Prometheus metrics show AES-NI status and throughput
4. **Documentation**: Clear hardware requirements in operational docs

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| AES-NI not available in testing VMs | Tests fail | `--allow-software-crypto` bypass flag |
| File format incompatibility | Cannot read old encrypted files | Version field in header, support both ciphers |
| Performance regression | Slower than expected | Benchmark before/after, Aegis-256 is proven faster |

## Stakeholders

- **Operators**: Need explicit hardware requirements and validation
- **Security team**: Ensure cipher change maintains security properties
- **Performance team**: Validate 2-3x improvement claim

## Related Work

- Extends: `add-v2-distributed-features/specs/security/spec.md` (encryption at rest)
- Similar to: Aegis-128L usage for checksums (`src/vsr/checksum.zig`)
- References: [Aegis specification](https://competitions.cr.yp.to/round3/aegisv11.pdf)
