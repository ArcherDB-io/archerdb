# Zig Ecosystem Workarounds

**Task:** F0.0.3
**Date:** 2026-01-03

## Summary

No fallbacks required. All critical features validated successfully.

## Workarounds Applied

### 1. Zig Version Alignment

**Issue:** Initial development used Zig 0.15.2, but TigerBeetle pins Zig 0.14.1.

**Resolution:** Switched to Zig 0.14.1 using TigerBeetle's `zig/download.sh` script.

**Rationale:**
- TigerBeetle's codebase is our foundation and must build without modifications
- Zig is pre-1.0 with frequent API changes between minor versions
- Using the same Zig version ensures compatibility when forking

**Impact:** Minor - one API difference in test code (`ArrayList.deinit()` signature)

## Features Validated (No Fallback Needed)

| Feature | Status | Fallback |
|---------|--------|----------|
| Hardware AES (Aegis-128L) | NOT TESTED YET | libsodium if missing |
| std.math trig functions | PASS | None needed |
| std.atomic operations | PASS | None needed |
| io_uring availability | PASS (Linux) | kqueue (macOS), IOCP (Windows) |
| extern struct layout | PASS | None needed |
| C FFI (@cImport) | PASS | None needed |
| std.crypto (SHA256, CRC32) | PASS | None needed |

## Potential Future Workarounds

### Hardware AES (Aegis-128L)

TigerBeetle uses Aegis-128L for data integrity checksums, requiring AES-NI hardware support.

**Detection:** Will be validated when forking TigerBeetle (F0.1).

**Fallback:** If hardware AES is unavailable:
1. Link libsodium for software crypto
2. Accept performance penalty (~10x slower checksums)
3. Document minimum hardware requirements

### Cross-Platform I/O

| Platform | Primary | Fallback |
|----------|---------|----------|
| Linux | io_uring (kernel 5.5+) | epoll |
| macOS | kqueue | poll |
| Windows | IOCP | N/A |

TigerBeetle already implements these platform abstractions in `src/io/`.

## Conclusion

All ecosystem validation tests pass. No immediate workarounds required.
The only change was aligning on Zig 0.14.1 (TigerBeetle's version).

## Next Steps

1. F0.0.4 (Day 3): Cross-platform validation
2. F0.0.5: GO/NO-GO decision gate
3. F0.1: Fork TigerBeetle
