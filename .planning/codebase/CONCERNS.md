# Codebase Concerns

**Analysis Date:** 2026-01-22

## Tech Debt

**Replication S3 Upload Stub:**
- Issue: S3 upload functionality is not implemented, only simulated with logging
- Files: `src/replication.zig:828`
- Impact: Cross-region replication S3RelayTransport cannot actually ship data to S3. Operations complete locally but data is never persisted to object storage, breaking disaster recovery.
- Fix approach: Integrate AWS SDK or implement HTTP API calls to S3 PutObject. Need to handle authentication, retries, and multipart uploads for large entries.

**Replication Disk Spillover Stub:**
- Issue: Disk spillover for ShipQueue not implemented, uses placeholder
- Files: `src/replication.zig:218`
- Impact: When memory queue fills and spillover path is configured, system currently drops oldest entries instead of writing to disk. This violates the spec requirement for disk spillover and can cause data loss during high replication lag.
- Fix approach: Implement file-based queue on disk with metadata tracking. Need to handle recovery from spillover files on restart (`recoverFromSpillover` exists but spillToDisk is TODO).

**Deprecated Message Types:**
- Issue: Four deprecated message commands retained for backwards compatibility
- Files: `src/vsr/message_header.zig:102-105`, `src/vsr/replica.zig:1815-1818`, `src/vsr.zig:292-295`
- Impact: Code complexity maintained for deprecated_12, deprecated_21, deprecated_22, deprecated_23. These always return invalid but still exist in protocol enums and switch statements.
- Fix approach: Can be removed once minimum supported client version exceeds 0.16.34 (see `src/scripts/release.zig:134` for client_release TODOs). Coordinate with client deprecation timeline.

**Legacy AOF Option:**
- Issue: `--aof` flag deprecated but still functional
- Files: `src/archerdb/cli.zig:199`, `src/archerdb/cli.zig:2119`
- Impact: Maintains duplicate code paths for old flag. Warning shown to users but flag still works, preventing full deprecation.
- Fix approach: Remove in next major version. Currently prints deprecation warning suggesting `--aof-file`.

**Windows C Sanitizer Disabled:**
- Issue: C sanitizer disabled on Windows due to illegal instruction crash
- Files: `build.zig:1737-1738`
- Impact: Memory safety checks not running for C client sample on Windows. Potential bugs in C interop code may go undetected on Windows platform.
- Fix approach: Investigate root cause of illegal instruction. May be compiler bug or incompatible sanitizer/Windows combination. Test with newer Zig versions.

**FIXME Comment Enforcement:**
- Issue: Tidy checks ban FIXME comments to prevent merge
- Files: `src/tidy.zig:329`
- Impact: Not technical debt itself, but enforces cleanup. Any leftover FIXME in code will block CI. Good practice but requires vigilance during development.
- Fix approach: Working as intended. Developers must resolve or convert FIXMEs to TODOs before merge.

**Error Handling with TODO Markers:**
- Issue: Message bus error handling marked with TODO for refinement
- Files: `src/message_bus.zig:347`, `src/message_bus.zig:591`, `src/message_bus.zig:912`
- Impact: Some errors may not be fatal when they should be. Comments indicate uncertainty about which errors warrant connection closure. Could lead to lingering bad connections.
- Fix approach: Audit error conditions and determine which should be fatal vs recoverable. Document decision rationale.

**MacOS x86_64 Test Assertion:**
- Issue: Assertion in build.zig commented out despite known trigger
- Files: `build.zig:811`
- Impact: Build process disables an assertion that would catch issues on macOS x86_64, despite tests working. Masks potential cross-platform issues.
- Fix approach: Investigate why assertion triggers, determine if it's false positive or real issue. Either fix root cause or document why it's safe to ignore.

**Multiversion Deprecated Architectures:**
- Issue: macOS multiversion uses deprecated architectures for header/body storage
- Files: `src/build_multiversion.zig:635-636`
- Impact: Relies on deprecated architecture support in build system. May break when Zig drops support for these targets.
- Fix approach: Migrate to alternative storage mechanism before Zig removes deprecated arch support.

## Known Bugs

**VSR Superblock Snapshot Verification:**
- Symptoms: Snapshot verification disabled during manifest block checks
- Files: `src/vsr/message_header.zig:1623`
- Trigger: When manifest blocks include a snapshot field
- Workaround: TODO comment indicates verification needs to be added once snapshot numbers match op numbers

**Journal Prepare Checksums Assertion:**
- Symptoms: Assertion disabled with TODO comment
- Files: `src/vsr/journal.zig:303`
- Trigger: Unknown - assertion was causing failures
- Workaround: Assertion commented out pending investigation

**Windows Socket Workaround:**
- Symptoms: Cannot use standard library socket function, needs workaround
- Files: `src/io/windows.zig:582`
- Trigger: Using `os.windows.loadWinsockExtensionFunction` before fix lands in stdlib
- Workaround: Custom implementation until Zig standard library updated

**Darwin Fsync Safety Concern:**
- Symptoms: Fallback to posix.fsync has dubious safety properties
- Files: `src/io/darwin.zig:1071`
- Trigger: When F_FULLFSYNC is not available
- Workaround: Code notes this is "not safe" but uses as fallback

## Security Considerations

**Security Policy Exists:**
- Risk: Standard security disclosure process documented
- Files: `SECURITY.md`
- Current mitigation: GitHub Security Advisories process in place, email fallback available
- Recommendations: Security policy is well-structured. No concerns identified in policy itself.

**Non-root User in Docker:**
- Risk: None - best practice followed
- Files: `deploy/Dockerfile:40`
- Current mitigation: Container runs as non-root user
- Recommendations: Continue this practice for all deployment configurations.

**No Injection Vulnerabilities Found:**
- Risk: No obvious SQL/command injection patterns found in codebase search
- Files: Searched entire codebase
- Current mitigation: Type-safe Zig code, no dynamic SQL or shell command construction from user input
- Recommendations: Maintain vigilance during new feature development.

**Encryption Implementation:**
- Risk: Dual encryption versions (legacy GCM, current Aegis-256)
- Files: `src/encryption.zig:34-38`
- Current mitigation: Version 2 (Aegis-256) is current default. Version 1 (AES-256-GCM) marked legacy but still readable for backwards compatibility.
- Recommendations: Plan deprecation timeline for GCM after sufficient adoption of Aegis-256. Ensure key rotation procedures documented.

## Performance Bottlenecks

**Full Test Suite Too Slow for Pre-commit:**
- Problem: Full unit test suite (`./zig/zig build test:unit`) too slow for developer workflow
- Files: `CLAUDE.md:15`, `.claude/hooks/pre-commit-check.sh:44`
- Cause: Comprehensive test coverage comes at cost of execution time
- Improvement path: Pre-commit hook uses single representative test (EncryptedFileHeader with 120s timeout). Developers must manually run targeted test filters. CI runs full suite. Could parallelize test execution or optimize slowest tests.

**Jump Hash Performance:**
- Problem: Jump hash is O(log n) vs modulo O(1)
- Files: `src/sharding.zig:3290`
- Cause: Mathematical properties of jump hash algorithm
- Improvement path: Comment notes it should be "at most 10x slower than modulo". This is expected tradeoff for better resharding properties. No fix needed unless profiling shows it's actual bottleneck.

**IO_uring Disabled Check:**
- Problem: Tests may fail if io_uring disabled on Linux
- Files: `scripts/run_integration_tests.sh:11-12`, `scripts/test_clients.sh:22-30`
- Cause: Kernel security setting (`kernel.io_uring_disabled`)
- Improvement path: Scripts check and warn. Could fallback to different IO backend if io_uring unavailable, but current behavior (warn and continue) is reasonable.

**Performance Mode in VOPR:**
- Problem: Debug mode too slow for performance testing
- Files: `src/vopr.zig:143-151`
- Cause: Full debug logs in debug builds
- Improvement path: Already has `--performance` flag that uses ReleaseSafe mode. Warns users when running in debug without seed. Working as intended.

## Fragile Areas

**Replica State Machine (12,447 lines):**
- Files: `src/vsr/replica.zig`
- Why fragile: Largest file in codebase, handles core distributed consensus. Complex state transitions with 1,664 assert/panic/unreachable calls. Many TODOs for optimizations and edge cases.
- Safe modification: Extensive test coverage via `src/vsr/replica_test.zig` (2,909 lines). Changes should be tested with VOPR fuzzer. Read marks.zig wrapping for debugging. Follow state machine invariants carefully.
- Test coverage: Well-tested but complex. VOPR fuzzer exercises replica failures, view changes, and recovery scenarios.

**Geo State Machine (5,487 lines):**
- Files: `src/geo_state_machine.zig`
- Why fragile: Core business logic for geospatial operations. Integrates S2 geometry, RAM index, LSM storage, and TTL expiration. Changes affect all query types.
- Safe modification: Test with `state_machine_fuzz.zig` and radius query coverage tests. Validate S2 cell operations carefully. Changes to index structure need migration plan.
- Test coverage: Fuzz tested for radius queries. Comprehensive operation coverage in fuzz suite.

**RAM Index with TTL (4,627 lines):**
- Files: `src/ram_index.zig`
- Why fragile: In-memory index with concurrent access patterns. Race condition handling critical (`ram_index.zig:1859` has race condition prevention). Hash-based structure sensitive to collision handling.
- Safe modification: Test concurrent operations. Check `remove_if_id_matches` race condition handling. Verify TTL expiration doesn't create memory leaks.
- Test coverage: Has specific race condition test at line 2884. Thread sanitizer requirement noted at line 4561.

**Sharding Logic (3,480 lines):**
- Files: `src/sharding.zig`
- Why fragile: Routing logic for distributed queries. Jump hash implementation must match across versions. Shard boundary calculations critical for correctness.
- Safe modification: Validate against existing shard assignments. Test both modulo and jump hash strategies. Changes must not break existing data distribution.
- Test coverage: Good - includes strategy comparison tests.

**Message Bus (Complex Error Handling):**
- Files: `src/message_bus.zig`
- Why fragile: Network communication layer with 145 assert/panic calls. Connection state management complex. TODOs indicate error handling needs refinement.
- Safe modification: Test with message_bus_fuzz.zig. Validate connection state transitions. Check peer eviction logic carefully.
- Test coverage: Dedicated fuzzer exists. Connection handling tested with fault injection.

**IO Layer Platform Differences:**
- Files: `src/io/linux.zig` (1,862 lines), `src/io/windows.zig` (1,641 lines), `src/io/darwin.zig` (43 panic calls)
- Why fragile: Platform-specific syscall wrappers. Different error semantics across OSes. Darwin fsync workaround noted as unsafe. Windows socket workaround needed.
- Safe modification: Test on target platform. Cannot rely on cross-platform behavior. Each platform has unique failure modes.
- Test coverage: CI runs on Linux and macOS. Windows tests not in current CI matrix (see `.github/workflows/ci.yml:52`).

## Scaling Limits

**Memory Queue Overflow:**
- Current capacity: Configurable `memory_max` per ShipQueue
- Limit: When memory queue fills without disk spillover configured, oldest entries dropped
- Scaling path: Implement disk spillover (currently TODO). Monitor `stats.memory_entries` and `stats.memory_bytes`. Increase memory_max or enable spillover path.

**LSM Compaction Under Load:**
- Current capacity: LSM tree handles writes via leveled compaction
- Limit: `src/lsm/compaction.zig` (2,322 lines) manages compaction. Under extreme write load, compaction may fall behind.
- Scaling path: Monitor compaction lag. Tune `constants.zig` parameters (line 670 has "TODO Tune this better" for LSM settings). Consider compaction parallelization.

**Grid Block Pool:**
- Current capacity: Fixed-size block pool for storage operations
- Limit: `src/vsr/checkpoint_trailer.zig:76` notes need to acquire blocks as-needed from grid pool
- Scaling path: Implement dynamic block acquisition from pool. Current fixed allocation may limit checkpoint size.

## Dependencies at Risk

**Zig Language Version Lock:**
- Risk: Project uses specific Zig version downloaded via `zig/download.sh`
- Impact: Breaking changes in Zig compiler could require code updates
- Migration plan: Scripts handle Zig download. Monitor Zig release notes. Test with new versions before adopting. Build system (`build.zig`) may need updates for new Zig features.

**No External Runtime Dependencies:**
- Risk: Minimal - project is largely self-contained
- Impact: Zig standard library is only major dependency
- Migration plan: Vendored dependencies in `src/stdx/vendored/aegis.zig`. Control over dependency updates.

## Missing Critical Features

**S3 Replication Backend:**
- Problem: Cross-region replication to S3 not implemented
- Blocks: Disaster recovery to object storage, geographic data distribution
- Priority: High - marked with TODO in replication.zig

**Disk Spillover for ShipQueue:**
- Problem: Queue cannot spill to disk when memory limit reached
- Blocks: High-volume replication scenarios, prevents data loss during lag spikes
- Priority: High - spec defines disk spillover behavior but implementation incomplete

**Windows CI Testing:**
- Problem: Windows tests not in CI matrix despite Windows support code
- Blocks: Confidence in Windows platform stability
- Priority: Medium - Windows platform exists but untested in CI (see `build.zig` Windows-specific code)

**Snapshots in Manifest Blocks:**
- Problem: Snapshot verification disabled pending snapshot number alignment
- Blocks: Full snapshot integrity validation
- Priority: Medium - marked TODO in message_header.zig:1623

## Test Coverage Gaps

**Windows Platform:**
- What's not tested: Windows IO layer, Windows-specific syscalls, C sanitizer on Windows
- Files: `src/io/windows.zig`, `build.zig:1737-1738`
- Risk: Windows-specific bugs may reach production
- Priority: Medium - Windows support exists but not in CI matrix

**Replication S3 Upload:**
- What's not tested: Actual S3 upload flow, AWS SDK integration, multipart uploads
- Files: `src/replication.zig:828`
- Risk: Implementation incomplete, no tests for non-existent feature
- Priority: High - should add integration tests when implementing S3 backend

**Replication Disk Spillover:**
- What's not tested: Spillover file creation, recovery from spillover, queue persistence
- Files: `src/replication.zig:218`
- Risk: Feature not implemented, cannot test
- Priority: High - needs tests when implementing disk spillover

**Error Recovery Paths:**
- What's not tested: Specific error conditions in message bus marked with TODO
- Files: `src/message_bus.zig:347,591,912`
- Risk: Error handling strategy uncertain, may have untested code paths
- Priority: Medium - errors may not be handled correctly

**Darwin Fsync Fallback:**
- What's not tested: Safety of posix.fsync fallback on macOS
- Files: `src/io/darwin.zig:1071`
- Risk: Durability guarantees may not hold if F_FULLFSYNC unavailable
- Priority: Low - marked "dubious safety" but used as fallback

**Multiversion Deprecated Architectures:**
- What's not tested: What happens when Zig removes deprecated architecture support
- Files: `src/build_multiversion.zig:635-636`
- Risk: Build may break on future Zig versions
- Priority: Low - works currently but needs proactive fix before Zig drops support

---

*Concerns audit: 2026-01-22*
