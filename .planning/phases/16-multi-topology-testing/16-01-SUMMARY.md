---
phase: 16-multi-topology-testing
plan: 01
subsystem: testing
tags: [topology, failover, iptables, cluster, distributed, consistency]

# Dependency graph
requires:
  - phase: 11
    provides: Cluster harness infrastructure (ArcherDBCluster, ClusterConfig)
  - phase: 13
    provides: SDK runners for all 6 SDKs (run_operation interface)
  - phase: 14
    provides: JSON fixtures for all 14 operations
provides:
  - Node lifecycle methods in ArcherDBCluster (stop/start/kill/is_running)
  - Leader replica detection (get_leader_replica)
  - NetworkPartitioner for iptables-based partition simulation
  - FailoverSimulator for leader failure testing and recovery measurement
  - ConsistencyChecker for health and data verification
  - TopologyTestRunner for full test matrix orchestration
affects: [16-02, 16-03]

# Tech tracking
tech-stack:
  added: [tenacity]
  patterns: [failover-simulator, consistency-checker, network-partition]

key-files:
  created:
    - test_infrastructure/topology/__init__.py
    - test_infrastructure/topology/partition.py
    - test_infrastructure/topology/failover.py
    - test_infrastructure/topology/consistency.py
    - test_infrastructure/topology/runner.py
  modified:
    - test_infrastructure/harness/cluster.py
    - test_infrastructure/requirements.txt

key-decisions:
  - "Use subprocess.terminate()/kill() instead of os.kill() for clean signal handling"
  - "NetworkPartitioner uses iptables INPUT chain DROP rules for simplicity"
  - "ConsistencyChecker uses tenacity retry with fixed wait for eventual consistency"
  - "TopologyTestRunner continues through failures to collect full scope"
  - "Recovery SLA targets: 3-node <10s, 5-node <15s, 6-node <20s"

patterns-established:
  - "FailoverResult dataclass for structured failover results"
  - "Context manager pattern for NetworkPartitioner (auto-heal on exit)"
  - "Sequential topology execution (1->3->5->6) in runner"

# Metrics
duration: 4 min
completed: 2026-02-01
---

# Phase 16 Plan 01: Topology Testing Infrastructure Summary

**Extended ArcherDBCluster with 7 node lifecycle methods, created topology package with NetworkPartitioner (iptables), FailoverSimulator, ConsistencyChecker, and TopologyTestRunner for full test matrix orchestration**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-01T11:07:57Z
- **Completed:** 2026-02-01T11:11:35Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments

- ArcherDBCluster extended with node lifecycle control (stop_node, start_node, kill_node, is_node_running, get_leader_replica, get_ports, get_metrics_ports)
- NetworkPartitioner class for simulating network partitions using iptables DROP rules
- FailoverSimulator for triggering leader failures (graceful/ungraceful) and measuring recovery time
- ConsistencyChecker for verifying cluster health and data consistency with retry backoff
- TopologyTestRunner orchestrator for running all 14 operations across 6 SDKs for all 4 topologies

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend ArcherDBCluster with node lifecycle methods** - `616d209` (feat)
2. **Task 2: Create topology infrastructure modules** - `0361b0c` (feat)
3. **Task 3: Create TopologyTestRunner orchestrator** - `234a145` (feat)

## Files Created/Modified

- `test_infrastructure/harness/cluster.py` - Added 7 node lifecycle methods
- `test_infrastructure/topology/__init__.py` - Package exports
- `test_infrastructure/topology/partition.py` - NetworkPartitioner class
- `test_infrastructure/topology/failover.py` - FailoverSimulator and FailoverResult
- `test_infrastructure/topology/consistency.py` - ConsistencyChecker class
- `test_infrastructure/topology/runner.py` - TopologyTestRunner orchestrator
- `test_infrastructure/requirements.txt` - Added tenacity>=8.2.0

## Decisions Made

1. **Signal handling:** Use subprocess.terminate()/kill() instead of os.kill() for proper process cleanup
2. **iptables approach:** Use INPUT chain DROP rules (simpler than tc/Toxiproxy, sufficient for local testing)
3. **Retry library:** tenacity for consistency verification (provides jitter, exponential backoff)
4. **Failure continuation:** Runner continues through failures to collect full scope per CONTEXT.md
5. **Recovery SLAs:** Based on RESEARCH.md recommendations (3-node <10s, 5-node <15s, 6-node <20s)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Topology testing infrastructure complete
- Ready for 16-02-PLAN.md (topology tests using this infrastructure)
- All classes importable and verified
- tenacity dependency added to requirements.txt

---
*Phase: 16-multi-topology-testing*
*Completed: 2026-02-01*
