# Phase 2: Multi-Node Validation - Context

**Gathered:** 2026-01-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Validate that 3-node cluster operates correctly with consensus, replication, and failover. This phase tests the existing distributed consensus system (the core value proposition) to ensure it works as designed. Focus is on validation infrastructure and test coverage, not implementing new consensus features.

</domain>

<decisions>
## Implementation Decisions

### Test environment setup
- Bare processes: Launch 3 server processes directly with different ports/data dirs
- Temp directories with auto-cleanup: Each test gets fresh temp directories (/tmp/test-xxx), cleaned up after test completes
- Local testing only: Manual/automated tests run locally; defer CI integration to Phase 9 (Testing Infrastructure)
- lite config: Use -Dconfig=lite (130MB RAM per node) for resource-constrained testing

### Validation approach
- Verify all replicas agree: After write, query all 3 nodes directly and verify they return identical data (external black-box validation)
- Use both direct HTTP and client SDKs: Primary tests use direct HTTP/protocol calls; secondary tests use Node.js/Java SDKs to validate end-to-end integration
- Leader discovery via status endpoint: Query /health or status endpoint to determine which node is current leader
- Validate election timing + data integrity: After leader election, verify it completed within 5s AND no committed data was lost

### Failure injection
- Use existing Cluster framework: Leverage TigerBeetle's Cluster.zig for deterministic simulated testing with built-in fault injection (partition, crash, pause)
- Process termination: Use both SIGKILL (hard crash scenarios) and SIGTERM (graceful shutdown tests)
- Comprehensive partition coverage: Test all partition types - symmetric (2-1 split), asymmetric (one-way), single node isolation, and majority/minority splits
- Deterministic seeds: Use fixed seeds for reproducible test scenarios; multiple seeds for coverage (not VOPR fuzzing)

### Success criteria verification
- Simulated time measurement: Use Cluster framework's tick counter to measure timing requirements (e.g., 5s leader election). Convert ticks to wall-clock equivalent.
- Zero flakiness: Tests must pass 100% of the time. Any failure is a bug. Deterministic testing should make this achievable.
- Validate intermediate states: Check state at key points (before failure, during partition, after recovery) AND final convergence

### Claude's Discretion
- Which specific TigerBeetle test patterns to adopt (TestContext, TestReplicas, StateChecker, etc.)
- Exact tick-to-wallclock conversion formula
- Test organization (single file vs multiple files per scenario)
- Data integrity verification approach (track committed ops vs use StateChecker vs hybrid)
- How many seeds to run per scenario for deterministic coverage

</decisions>

<specifics>
## Specific Ideas

**TigerBeetle test framework reference:**
- Core cluster simulator: `src/testing/cluster.zig`
- Packet-level fault injection: `src/testing/packet_simulator.zig`
- Network simulation: `src/testing/cluster/network.zig`
- Property-based testing: `src/vopr.zig`
- Replica-level unit tests: `src/vsr/replica_test.zig`

**Test pattern to follow:**
1. Setup: `TestContext.init()` with replica count
2. Establish baseline: Send requests to get consensus
3. Inject faults: Network (`replica.drop_all()`), Storage (`replica.corrupt()`), Node (`replica.stop()`)
4. Exercise system: Send requests, trigger recovery
5. Verify invariants: Check commit, status, sync_status at intermediate points
6. Allow recovery: Let system recover
7. Validate final state: Assert all replicas converge

**Key capabilities from framework:**
- `replica.drop_all()`, `replica.pass_all()` for network partitions
- `replica.stop()`, `replica.open()` for process lifecycle
- `replica.status()`, `replica.commit()`, `replica.role()` for state inspection
- StateChecker, StorageChecker for continuous validation during execution

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 02-multi-node-validation*
*Context gathered: 2026-01-29*
