# Phase 2: VSR & Storage - Context

**Gathered:** 2026-01-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Verify consensus and storage layers are correct — VSR fixes applied, durability guarantees solid, encryption verified. This phase ensures the foundation is rock-solid before building features on top.

</domain>

<decisions>
## Implementation Decisions

### Verification Approach
- Exhaustive property tests (fuzzing) required, not just existing test suite
- Snapshot verification: crash during snapshot, corruption detection, AND network partition recovery
- WAL replay: verify state matches after replay, inject corruption to verify detection, AND verify replay from arbitrary checkpoint
- Success bar: all tests pass + documented reasoning WHY each test proves correctness + coverage metrics
- Standalone verification against our spec — no comparison to TigerBeetle reference
- Coverage target: 100% line coverage, branch coverage, and path coverage for critical VSR paths
- VOPR fuzzer extended with deterministic replay for debugging
- VOPR runs 8 hours to consider verification complete
- Unrecoverable scenarios found = bugs to fix, not document
- Power-loss simulation: SIGKILL at random points + dm-flakey disk failure injection
- dm-flakey: basic tests this phase, extensive suite in Phase 10
- Cluster verification: both 3-node and 5-node configurations
- Replica catch-up: verify within checkpoint window AND beyond checkpoint (full resync)
- Network partitions: symmetric, asymmetric, AND partial (random message drops)
- VSR snapshot verification (disabled in CONCERNS.md): investigate root cause AND thoroughly test after enabling

### LSM Tuning Targets
- Workload profile: 1M+ writes/sec AND 10k-100k reads/sec — both must be excellent
- Optimization priority: minimize write amplification (larger memtables, fewer compactions)
- Memory budget: configurable with recommended defaults for different deployment sizes
- Runtime changes: require restart (no hot-reload)
- Validation: benchmark targets must be hit (1M writes, 100k reads)
- Hardware: document benchmarks for both enterprise tier (NVMe, 16+ cores, 64GB+) and mid-tier (SATA SSD, 8 cores, 32GB)
- If targets missed: investigate root cause before deciding whether to continue
- Benchmark both encrypted and unencrypted modes
- Compaction: dedicated resources reserved — not background/low-priority
- Compaction cannot impact p99 latency — no spikes allowed
- Read latency targets: point queries < 1ms, range queries < 10ms, spatial queries < 10ms
- Bloom filter: aggressive 14 bits/key (~0.1% false positive rate)
- Benchmark results documented with reproducible scripts
- Block size: configurable (let operators tune)
- Compression: LZ4 (fast)

### Encryption Documentation
- Audience: both operators/DevOps AND security auditors (operator guide + security appendix)
- Key rotation: step-by-step runbook with exact commands, verification, rollback
- Algorithm choice: decision matrix (when to use AES-256-GCM vs Aegis-256, trade-offs)
- Verification: against NIST/FIPS test vectors
- Threat model: detailed documentation (what encryption protects against, what it doesn't)
- Key storage: env vars for dev, KMS for production (document both with recommendations)
- Performance: document both overhead percentage AND absolute throughput numbers
- Key revocation: document emergency procedure AND verify it works

### Deprecated Code Handling
- Remove deprecated VSR message types (deprecated_12, _21, _22, _23) cleanly
- Rolling upgrades supported via two-phase approach
- This phase: Phase 2 (remove code) — assume clusters already upgraded to ignore
- Investigate current handling: code search to understand current state
- Message ID slots: reserved forever with comment explaining why
- Verification: both unit tests and cluster integration tests
- Other deprecated code: address if found and trivial

### Claude's Discretion
- Consistency model verification approach (linearizability vs sequential vs strict serializability)
- Write amplification target
- Specific dm-flakey test scenarios
- Exact VOPR extension implementation
- Default block size recommendation

</decisions>

<specifics>
## Specific Ideas

- Performance targets are non-negotiable: 1M+ writes/sec, 10k-100k reads/sec, < 10ms spatial queries
- No latency spikes during compaction — this is a hard requirement
- LZ4 compression chosen for speed over ratio
- Aggressive bloom filters (14 bits/key) to minimize read amplification

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-vsr-storage*
*Context gathered: 2026-01-22*
