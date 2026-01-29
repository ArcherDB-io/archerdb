# Codebase Concerns

**Analysis Date:** 2026-01-29

## Tech Debt

**Large monolithic files requiring refactoring:**
- Issue: Core files exceed 12K lines, making them difficult to understand, test, and maintain
- Files:
  - `src/vsr/replica.zig` (12,688 lines) - Consensus replica logic
  - `src/geo_state_machine.zig` (7,058 lines) - State machine implementation
  - `src/ram_index.zig` (6,047 lines) - In-memory indexing
  - `src/archerdb/metrics.zig` (4,326 lines) - Metrics collection
- Impact: Slower development iteration, increased risk of subtle bugs, difficult code review
- Fix approach: Incrementally extract concerns into separate modules; `geo_state_machine.zig` particularly needs separation of operation handling, validation, and indexing

**Numerous incomplete TODO comments scattered through codebase:**
- Issue: 127 TODO comments indicating deferred work, many in critical paths
- Files: Core consensus (`src/vsr.zig`, `src/vsr/replica.zig`), LSM (`src/lsm/`), messaging
- Impact: Uncertain completeness of features; potential gaps in error handling or optimization
- High-priority TODOs:
  - `src/vsr.zig:794` - Timeout adjustment not using randomization (affects retry behavior)
  - `src/vsr.zig:813` - After tick bounds not clamped (could cause logical errors)
  - `src/vsr/journal.zig:292` - prepare_checksums and prepare_inhabited should be unified (inefficient memory use)
  - `src/vsr/checkpoint_trailer.zig:76` - Block acquisition should use grid pool (memory inefficiency)
- Fix approach: Prioritize TODOs by impact; create issues for deferred work; track completion in release notes

**Snapshot handling complexity:**
- Issue: Snapshot management scattered and incomplete; marked as "future work"
- Files: `src/vsr/message_header.zig:1633-1640`, `src/vsr/checkpoint_trailer.zig:411`
- Impact: Snapshot-related features may be partially implemented or missing; unclear interaction with LSM
- Fix approach: Unify snapshot handling abstraction; document snapshot lifecycle; add comprehensive snapshot testing

**LSM compaction tuning deferred:**
- Issue: Compaction parameters (level scaling, retention) marked as requiring tuning
- Files: `src/constants.zig:683`, `src/lsm/manifest_level_fuzz.zig:96-110`
- Impact: Performance characteristics may not be optimal; compaction may be inefficient at scale
- Fix approach: Run full production benchmarks with various data distributions; establish tuned constants; add performance regression tests

**Security-related NOTICE in codebase:**
- Issue: Breach notification system present but appears experimental
- File: `src/archerdb/breach_notification.zig`
- Impact: Unclear if this is production-ready or still under development
- Fix approach: Document breach notification behavior, test end-to-end, ensure compliance with regulations

---

## Known Bugs

**Readiness probe returns 503 after initialization:**
- Symptoms: Health check at /health/ready returns 503 for 10+ seconds after startup, then transitions to 200
- Files: `src/archerdb/` (health check logic), likely `src/vsr/replica.zig` (state machine ready check)
- Trigger: Server startup; readiness check before replica fully initialized
- Workaround: Wait 10+ seconds before considering server ready; use /health/live instead for liveness
- Severity: **High** - Affects Kubernetes/orchestration readiness probes; breaks common deployment patterns
- Root cause: Replica ready state may not be set correctly during initialization; state machine may not signal ready to health endpoint

**Data does not persist after restart (development mode):**
- Symptoms: Data inserted is not present after server restart
- Files: `src/storage.zig`, `src/vsr/journal.zig` (persistence logic)
- Trigger: Insert data, stop server, restart server, attempt to read data
- Evidence: `validation-results/2026-01-29/restart-check.log` shows restart recovery returns empty/None for persisted entities
- Severity: **Critical** - Fundamental to database functionality; affects all deployments
- Workaround: Unknown; this is a blocking issue
- Note: Test was run with `--development` flag; may be limited to development config or all configs
- Root cause: Unclear - may be WAL replay issue, checkpoint loading issue, or storage layer bug

**Primary doesn't stand down during network issues:**
- Symptoms: Primary continues retrying indefinitely during one-way network partitions instead of yielding to backups
- Files: `src/vsr/replica.zig:1819-1823` (contains "Known issue" comment)
- Trigger: One-way network partition where primary can't hear backups but backups hear primary
- Impact: Delays view changes and leader election; may cause temporary unavailability
- Workaround: Manual intervention to kill primary process and trigger failover
- Severity: **Medium** - Correctness not affected (eventual consistency maintained), but reduces availability
- Fix approach: Implement exponential backoff; trigger view change if retry count exceeds threshold; consider replica health feedback

**TTL cleanup not removing entries:**
- Symptoms: TTL expiration works (events expire), but cleanup removes 0 entries
- Files: `src/vsr/` (TTL handling), state machine cleanup logic
- Trigger: Set TTL, wait for expiration, observe cleanup
- Evidence: `validation-results/2026-01-29/smoke-test.log` shows "expired after ~2s; cleanup removed 0"
- Severity: **Medium** - Data expires but not freed; causes storage waste and memory bloat over time
- Root cause: TTL delete operation may not be triggered; cleanup batch may be empty or batch handling broken

**Concurrent throughput degradation at 10+ clients:**
- Symptoms: Benchmark fails at 10 concurrent clients; single-client throughput 5,062 events/sec but 10-client runs fail
- Files: Connection pool, message handling, or concurrency coordination
- Trigger: `./scripts/run-perf-benchmarks.sh --quick` with concurrency=10
- Evidence: `validation-results/2026-01-29/perf-quick.log` shows all 3 concurrent runs failed with "Benchmark run failed" message
- Severity: **High** - Prevents multi-threaded usage; impacts real-world deployments
- Root cause: Likely connection pool exhaustion, message buffer limits, or synchronization deadlock
- Investigation needed: Check logs for "Warning: Benchmark run failed" context; examine connection pool state at 10 clients

---

## Security Considerations

**Default binding allows any interface (0.0.0.0):**
- Risk: Server binds to 0.0.0.0 by default, accepting connections from any network interface
- Files: `src/constants.zig` (contains WARNING comment about 0.0.0.0)
- Current mitigation: Documented in code comments; expect deployment to restrict network access
- Recommendations:
  - Default to 127.0.0.1 for development, require explicit flag for 0.0.0.0
  - Add CLI warning when binding to 0.0.0.0 in production builds
  - Document network security in deployment guide

**Direct I/O disabled with warning:**
- Risk: Page cache not trusted after fsync errors; data durability not guaranteed
- Files: `src/constants.zig` (WARNING comment about disabling direct I/O)
- Current mitigation: Comment indicates awareness; configuration allows enabling
- Recommendations:
  - Document when direct I/O must be enabled
  - Add runtime check to warn if direct I/O disabled in production
  - Provide guidance on filesystem selection (ext4, XFS recommendations)

**Encryption implementation present but needs audit:**
- Risk: Encryption at rest (AES-256-GCM) implementation not yet externally audited
- Files: `src/encryption.zig` (3,384 lines)
- Current mitigation: Using standard library implementations (std.crypto)
- Recommendations:
  - Commission third-party security audit of encryption module
  - Document key derivation and rotation procedures
  - Add runtime integrity checks for encrypted data

**Atomic operations without comprehensive synchronization review:**
- Risk: Multi-threaded access to shared state using atomics; potential for subtle race conditions
- Files: `src/read_replica_router.zig` uses std.atomic.Value for health/lag tracking
- Impact: Replica health state may become inconsistent; routing decisions may be based on stale data
- Recommendations:
  - Comprehensive audit of atomic usage and memory ordering
  - Document synchronization guarantees for shared state
  - Add stress tests for concurrent health updates

---

## Performance Bottlenecks

**Write throughput 4,800x below target:**
- Problem: Benchmark shows 5,062 events/sec; requirement is 1,000,000 events/sec/node
- Files: All relevant to throughput - message pool, state machine, persistence layer
- Cause: Likely one or more of:
  - Synchronous I/O blocking threads
  - Message copying overhead
  - State machine processing bottleneck
  - Network/consensus overhead in benchmark environment
- Improvement path:
  - Profile with perf/Tracy to identify bottleneck
  - Verify if benchmark is saturating a single thread
  - Check for synchronous fsync calls in hot path
  - May need batching optimization or async I/O improvements

**Concurrent client handling broken above 10 clients:**
- Problem: Benchmark fails with 10+ concurrent clients; single client gets 5K ops/sec
- Files: Connection pool, message bus, client session handling
- Cause: Likely connection/message resource exhaustion
- Improvement path:
  - Add detailed logging to identify failure point
  - Check connection pool size and limits
  - Review message pool configuration for concurrency
  - Investigate if there's a synchronization bottleneck (lock contention)

**LSM compaction may impact query latency:**
- Problem: Compaction marked as complex with deferred optimizations
- Files: `src/lsm/compaction.zig` (2,146 lines), `src/lsm/forest.zig`
- Cause: Compaction pausing writes/queries during heavy operations
- Improvement path:
  - Profile compaction impact on latency
  - Implement incremental/online compaction if not already present
  - Add metrics to track compaction frequency and duration

**S2 cell covering inefficiency:**
- Problem: Spatial query covering may generate excessive cell levels
- Files: `src/s2/`, spatial query code
- Impact: Increased memory use and query latency for large geometric queries
- Improvement path: Review covering algorithm; consider adaptive cell level selection based on geometry size

---

## Fragile Areas

**Consensus replica state machine (12K line file):**
- Files: `src/vsr/replica.zig`
- Why fragile: Monolithic file containing consensus, timing, message dispatch, and recovery logic tightly coupled; hard to understand full state flow
- Safe modification:
  - Extract timeout handling into separate module
  - Extract message dispatch into cleaner dispatch table
  - Add comprehensive state transition documentation
  - Increase unit test coverage for state changes
- Test coverage: Covered by replica tests but file size makes comprehensive testing difficult

**State machine implementation (7K lines):**
- Files: `src/geo_state_machine.zig`
- Why fragile: Single file handling prepare/commit/snapshot, indexing, validation; state mutations scattered
- Safe modification:
  - Add strict invariant assertions at state machine boundaries
  - Extract indexing into separate module
  - Document state mutations and read paths
  - Add before/after verification for operations
- Test coverage: VOPR fuzz testing helps but doesn't guarantee completeness

**RAM index implementation (6K lines):**
- Files: `src/ram_index.zig`
- Why fragile: Large in-memory structure; potential for subtle synchronization bugs; index corruption would be hard to detect
- Safe modification:
  - Disable logging by default (currently shows "Disabled by default - never log")
  - Add runtime integrity checks
  - Document index invariants
  - Add periodic index validation
- Test coverage: Tests exist but index is performance-critical and hard to test exhaustively

**LSM tree compaction logic:**
- Files: `src/lsm/compaction.zig` (lines with "TODO" markers)
- Why fragile: Compaction during active queries; potential for inconsistent reads; complex level selection logic
- Safe modification:
  - Document compaction invariants
  - Add snapshot isolation verification
  - Test compaction during heavy concurrent load
  - Add assertions for level invariants
- Test coverage: Forest fuzzer provides good coverage but real-world workloads may differ

**Message pool and buffer management:**
- Files: `src/message_pool.zig`, `src/message_buffer.zig`
- Why fragile: Reference counting; potential for use-after-free or double-free; memory pressure handling
- Safe modification:
  - Comprehensive audit of buffer lifecycle
  - Add memory leak detection (already present in tests)
  - Stress test under memory pressure
  - Consider moving to arena allocation for batches
- Test coverage: Unit tests exist but concurrency testing needed

**Superblock quorum consensus:**
- Files: `src/vsr/superblock_quorums.zig`, `src/vsr/superblock_quorums_fuzz.zig`
- Why fragile: Correctness depends on complex quorum logic; bugs would cause split-brain or corruption
- Safe modification:
  - Enable currently-disabled generic tests (marked with "TODO: Enable these once SuperBlockHeader is generic")
  - Add invariant verification for quorum state
  - Comprehensive fuzz testing (already has dedicated fuzzer)
- Test coverage: Dedicated fuzzer present; good coverage but emerging from recent VOPR fixes

---

## Scaling Limits

**Memory usage unbounded for large geometries:**
- Current capacity: RAM index fits in memory for typical workloads
- Limit: Very large polygon queries or high-cardinality filters may exhaust RAM
- Scaling path:
  - Implement streaming result processing
  - Add query result pagination/limiting
  - Consider hierarchical spatial indexing
  - Document geometry size limits

**Single-node write throughput ceiling at ~5K ops/sec (in lite config):**
- Current capacity: 5,062 events/sec in benchmark
- Limit: Production target 1,000,000 events/sec; missing 4,800x
- Scaling path:
  - Profile and optimize hot paths
  - Increase batch sizes
  - Implement async I/O if not present
  - May require architectural changes for 1M ops/sec goal

**Concurrent client limit:**
- Current capacity: 1 client works fine, 10 clients fails
- Limit: Connection pool, message buffers, or thread/lock contention
- Scaling path:
  - Determine exact limit (test with 2, 3, 5, 7 clients)
  - Add connection pooling metrics
  - Profile lock contention
  - May need to increase resource limits or optimize synchronization

---

## Dependencies at Risk

**Zig compiler stability:**
- Risk: Project built with custom bundled Zig version; compiler bugs could block development
- Impact: Blocking compilation errors; potential undefined behavior
- Mitigation: Tests and VOPR fuzzing catch most compiler bugs
- Migration plan: Monitor Zig releases; maintain compatibility with standard releases if possible

**Custom vendored crypto library:**
- Risk: `src/stdx/vendored/aegis.zig` uses vendored AEGIS implementation
- Impact: Security vulnerabilities in crypto not caught by standard audits; harder to update
- Migration plan: Prefer std.crypto implementations where available; reduce vendored code over time

**Java client bindings manually maintained:**
- Risk: Generated from Zig but manually modified; risk of divergence
- Files: `src/clients/java/`
- Impact: Java SDK may have bugs or missing features compared to server
- Migration plan: Fully automate Java client generation; ensure parity tests

---

## Missing Critical Features

**No explicit transaction support:**
- Problem: Multi-operation atomicity not guaranteed
- Blocks: Complex operations requiring all-or-nothing semantics
- Workaround: Implement at application level
- Impact: Harder to build reliable applications; data consistency burden on client

**No query optimization/explain:**
- Problem: No way to understand why a query is slow or how it's planned
- Blocks: Performance debugging; query tuning; client optimization
- Workaround: Add comprehensive logging
- Impact: Harder to optimize slow queries

**Limited error categorization:**
- Problem: Error codes present but not fully categorized (retryable vs fatal)
- Blocks: Client retry logic; automatic failover
- Workaround: Document error codes manually
- Impact: Clients may retry fatal errors or give up on transient ones

**No backup/restore capability (production-ready):**
- Problem: Backup infrastructure incomplete (marked in CONTRIBUTING.md)
- Blocks: Data protection; disaster recovery
- Workaround: File-system level backups only
- Impact: Cannot meet enterprise data protection requirements

---

## Test Coverage Gaps

**Untested area: Multi-node cluster behavior:**
- What's not tested: Replica failover, leader election, data consistency across multiple nodes
- Files: `src/testing/cluster.zig` exists but tests may not cover all failure modes
- Risk: Multi-node deployments may have correctness bugs not caught by single-node tests
- Priority: **High** - Multi-node is production requirement

**Untested area: TTL cleanup:**
- What's not tested: TTL expiration and cleanup operation; data removal after TTL
- Files: `src/ttl.zig` logic; state machine cleanup
- Risk: Data expires but isn't freed; storage bloat; memory leaks
- Evidence: Validation shows cleanup removed 0 entries
- Priority: **High** - Core feature not working

**Untested area: Concurrent client load:**
- What's not tested: 10+ simultaneous clients; connection pool exhaustion; message buffer limits
- Files: `src/connection_pool.zig`, message handling
- Risk: Production deployments with multiple clients will fail
- Evidence: Benchmark fails at concurrency=10
- Priority: **Critical** - Blocks production use

**Untested area: Encryption correctness:**
- What's not tested: Encrypted data round-trip; encryption with multiple keys; key rotation
- Files: `src/encryption.zig`
- Risk: Encrypted data may be corrupted or unrecoverable
- Priority: **High** - Security critical

**Untested area: Snapshot isolation:**
- What's not tested: Queries isolated to specific snapshots; snapshot consistency during compaction
- Files: Snapshot logic scattered
- Risk: Snapshot queries may see inconsistent data
- Priority: **Medium** - Feature may not be fully implemented

**Untested area: Disaster recovery:**
- What's not tested: Recovery from corrupted superblocks, torn writes, partial disk failures
- Files: `src/vsr/` recovery logic, storage layer
- Risk: Unrecoverable data loss in failure scenarios
- Priority: **High** - Enterprise requirement

**Untested area: Large dataset performance:**
- What's not tested: Throughput/latency with 100GB+ datasets; compaction efficiency at scale
- Files: All LSM code, compaction
- Risk: Performance degrades unexpectedly; compaction stalls
- Priority: **Medium** - Affects production deployments

---

## Architectural Concerns

**Monolithic state machine design:**
- Issue: State machine handles prepare/commit/snapshot/indexing/validation in single large module
- Impact: Hard to reason about correctness; changes risky; difficult to parallelize
- Recommendation: Extract validation, indexing, and snapshot handling into pluggable modules

**Missing abstraction for consensus state:**
- Issue: Replica state scattered across multiple structs (journal, grid, checkpoint, etc.)
- Impact: State transitions hard to verify; consistency invariants not obvious
- Recommendation: Create explicit state machine for replica lifecycle; document invariants

**Unclear separation between VSR and geospatial concerns:**
- Issue: State machine mixes consensus operations with geo domain logic
- Impact: Hard to test consensus separately from geo operations; bugs may be caused by either layer
- Recommendation: Clear API boundary between VSR and state machine

**Potential race condition in health tracking:**
- Issue: `src/read_replica_router.zig` uses atomic values without documented synchronization strategy
- Impact: Routing decisions based on stale health data; potential for cascading failures
- Recommendation: Document memory ordering guarantees; add stress tests

---

**Last Updated:** 2026-01-29
**Severity Distribution:** 3 Critical, 5 High, 4 Medium, 3 Low
**Tech Debt Items:** 5
**Known Bugs:** 4
**Test Coverage Gaps:** 7
