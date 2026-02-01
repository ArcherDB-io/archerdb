# Phase 16: Multi-Topology Testing - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Validate that all 14 operations work correctly across different cluster configurations (1/3/5/6 nodes) with failover handling. This phase ensures the distributed system behavior is correct - operations that work on single nodes continue working when clusters scale, and the system handles failures gracefully.

Scope: Testing existing operations across topologies. New operations or features belong in other phases.

</domain>

<decisions>
## Implementation Decisions

### Test Execution Strategy
- **Coverage:** Full test suite (all 14 operations × 6 SDKs) runs against each topology (1/3/5/6 nodes)
- **Execution mode:** Sequential - one topology at a time (1-node → 3-node → 5-node → 6-node)
- **CI integration:** Separate "topology" tier, independent from smoke/PR/nightly
- **Failure handling:** Continue through entire suite even after failures - collect full scope of issues per topology

### Failover Simulation Approach
- **Leader failure modes:** Both graceful (SIGTERM) and ungraceful (SIGKILL) shutdown scenarios
- **Network partitions:** Full partition testing - simulate network splits, isolated nodes, minority/majority partitions (requires iptables/tc manipulation)
- **Failure timing:** Random injection - failures triggered both mid-operation and between operations to catch edge cases
- **Failover cycles:** Multiple sequential failovers per test - validate repeated recovery and state consistency

### Verification Depth
- **Post-change validation:** Full data consistency checks after every topology change
  - Cluster health (nodes up, leader elected)
  - Operation correctness (re-run operations to verify success)
  - Data consistency across all nodes
- **Topology query:** Verify after every change - ensure clients see accurate node list and current leader
- **Consistency failures:** Retry with backoff before failing - accounts for eventual consistency and in-flight replication

### Recovery Expectations
- **Client behavior:** Automatic transparent failover - clients discover new leader and retry operations without user intervention
- **Election timeout:** Configurable per test - different topologies may need different timeouts (5-node might need longer than 3-node)
- **Recovery SLAs:** Enforce maximum recovery time targets (measure and fail if exceeded)
- **In-flight operations:** Must not lose data - writes that were acknowledged must survive leader failure (strong durability guarantee)

### Claude's Discretion
- Specific SLA target values for recovery times (to be determined based on cluster size)
- Exact consistency verification method (query all nodes vs checksums vs leader-only)
- Network partition tooling implementation details
- Retry backoff timing and maximum retry attempts

</decisions>

<specifics>
## Specific Ideas

- Testing should build on Phase 11's cluster harness infrastructure
- Leverage existing JSON fixtures from Phase 11 for test data
- Use Phase 13's SDK test runners as foundation for topology tests
- Network partition testing distinguishes this phase from simple node crash testing

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 16-multi-topology-testing*
*Context gathered: 2026-02-01*
