# Cross-Platform Validation

**Task:** F0.0.4
**Date:** 2026-01-03

## Summary

Cross-platform validation is handled via GitHub Actions CI pipeline, testing on:

| Platform | Runner | Architecture |
|----------|--------|--------------|
| Linux x64 | ubuntu-latest | x86_64 |
| Linux ARM64 | ubuntu-24.04-arm | aarch64 |
| macOS ARM64 | macos-latest | Apple Silicon |
| macOS x64 | macos-13 | Intel |
| Windows x64 | windows-latest | x86_64 |

## CI Pipeline

The `.github/workflows/ci.yml` workflow runs on every push and PR:

### Jobs

1. **smoke** - Quick validation on Linux x64
   - Lints download script with shellcheck
   - Downloads Zig and verifies version
   - Runs `zig build test`

2. **ecosystem-validation** - Cross-platform matrix
   - Downloads platform-specific Zig
   - Runs ecosystem validation tests
   - Builds ArcherDB
   - Verifies binary works

3. **reproducible-build** - Build determinism
   - Builds twice with same inputs
   - Compares SHA256 hashes
   - Fails if builds differ

## Platform-Specific Notes

### Linux (x64 and ARM64)
- Primary development platform
- io_uring available (kernel 5.5+)
- Full feature support

### macOS (Intel and Apple Silicon)
- kqueue for async I/O (not io_uring)
- TigerBeetle has macOS support via `src/io/` abstraction
- ARM64 is primary Apple platform going forward

### Windows
- IOCP for async I/O
- TigerBeetle has Windows support
- Lower priority for MVP but validated

## Local Validation

Current local environment (Linux x86_64):

```bash
./zig/zig version
# 0.14.1

./zig/zig test src/ecosystem_validation.zig
# All 18 tests passed.

./zig/zig build && ./zig-out/bin/archerdb version
# ArcherDB version 0.0.1+...
```

## C FFI ABI Compatibility

The ecosystem validation includes C FFI tests:
- `extern struct` layout matches C expectations
- `@cImport` works correctly
- C type sizes (`c_int`, `c_long`, `c_longlong`) match platform expectations

Cross-platform ABI will be validated by CI running on all platforms.

## Next Steps

1. F0.0.5: GO/NO-GO decision gate
2. F0.0.6: Set up continuous monitoring for Zig releases
3. F0.1: Fork TigerBeetle repository
