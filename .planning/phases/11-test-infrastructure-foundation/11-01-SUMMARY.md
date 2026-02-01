---
phase: 11-test-infrastructure-foundation
plan: 01
subsystem: testing
tags: [python, cluster-management, test-data, pytest, subprocess]

# Dependency graph
requires: []
provides:
  - ArcherDBCluster class for programmatic cluster management
  - ClusterConfig for cluster configuration
  - Port allocation utilities for parallel test safety
  - Data generators with uniform, city-concentrated, hotspot patterns
  - CLI wrapper for manual cluster management
affects: [11-02, 12-*, 13-*, sdk-testing, benchmarks]

# Tech tracking
tech-stack:
  added: [requests]
  patterns: [context-manager-lifecycle, seeded-rng-reproducibility]

key-files:
  created:
    - test_infrastructure/harness/cluster.py
    - test_infrastructure/harness/port_allocator.py
    - test_infrastructure/harness/log_capture.py
    - test_infrastructure/harness/cli.py
    - test_infrastructure/generators/data_generator.py
    - test_infrastructure/generators/distributions.py
    - test_infrastructure/generators/city_coordinates.py
  modified: []

key-decisions:
  - "Auto-detect leader via region role metric (archerdb_region_info role=primary)"
  - "Use seeded RNG for entity_id generation (reproducibility)"
  - "Use underscore naming (test_infrastructure) for Python module compatibility"

patterns-established:
  - "Context manager pattern for cluster lifecycle (with ArcherDBCluster as cluster:)"
  - "DatasetConfig dataclass for flexible test data configuration"
  - "City database with geographic diversity for edge case testing"

# Metrics
duration: 8min
completed: 2026-02-01
---

# Phase 11 Plan 01: Python Cluster Harness and Data Generators Summary

**Python test infrastructure with ArcherDBCluster class supporting 1/3/5+ node clusters, auto port allocation, and test data generators with uniform, city-concentrated, and hotspot distribution patterns**

## Performance

- **Duration:** 8 min
- **Started:** 2026-02-01T05:46:22Z
- **Completed:** 2026-02-01T05:54:09Z
- **Tasks:** 3
- **Files modified:** 12

## Accomplishments

- Cluster harness supporting 1, 3, 5+ node clusters with health check polling
- Dynamic port allocation for parallel test safety (no hardcoded ports)
- Test data generators with three distribution patterns and size tiers
- Full reproducibility with seeded RNG, plus truly random mode
- Comprehensive README with examples and SDK integration patterns

## Task Commits

Each task was committed atomically:

1. **Task 1: Create cluster harness Python package** - `1793cdd` (feat)
2. **Task 2: Create test data generators** - `c589f10` (feat)
3. **Task 3: Create README and validate end-to-end** - `0050f08` (docs)

## Files Created/Modified

- `test_infrastructure/__init__.py` - Package root
- `test_infrastructure/harness/__init__.py` - Harness package exports
- `test_infrastructure/harness/cluster.py` - ArcherDBCluster class
- `test_infrastructure/harness/port_allocator.py` - Dynamic port allocation
- `test_infrastructure/harness/log_capture.py` - Thread-safe log capture
- `test_infrastructure/harness/cli.py` - CLI wrapper for manual testing
- `test_infrastructure/generators/__init__.py` - Generators package exports
- `test_infrastructure/generators/data_generator.py` - Event generation
- `test_infrastructure/generators/distributions.py` - Distribution patterns
- `test_infrastructure/generators/city_coordinates.py` - 28 global cities
- `test_infrastructure/requirements.txt` - Dependencies (requests)
- `test_infrastructure/README.md` - Comprehensive documentation

## Decisions Made

1. **Leader detection via region role metric**: ArcherDB doesn't expose Raft leader directly in metrics. Used `archerdb_region_info{role="primary"}` to identify write-capable nodes since ArcherDB routes writes to leader internally.

2. **Entity ID generation with seeded RNG**: Changed from `uuid.uuid4()` to `rng.getrandbits(128)` formatted as hex to ensure reproducibility when seed is specified.

3. **Underscore directory naming**: Renamed from `test-infrastructure` to `test_infrastructure` for Python module import compatibility.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Renamed directory for Python import**
- **Found during:** Task 1 (Initial testing)
- **Issue:** Directory `test-infrastructure` with hyphen not importable as Python module
- **Fix:** Renamed to `test_infrastructure` with underscore
- **Files modified:** All paths changed from test-infrastructure to test_infrastructure
- **Verification:** Import succeeds
- **Committed in:** 1793cdd (Task 1 commit)

**2. [Rule 1 - Bug] Fixed entity_id reproducibility**
- **Found during:** Task 2 (Reproducibility test)
- **Issue:** `uuid.uuid4()` not using seeded RNG, so same seed produced different entity IDs
- **Fix:** Changed to `format(rng.getrandbits(128), '032x')` for seeded generation
- **Verification:** Same seed now produces identical datasets
- **Committed in:** c589f10 (Task 2 commit)

**3. [Rule 1 - Bug] Fixed leader detection regex**
- **Found during:** Task 1 (3-node test)
- **Issue:** Looked for nonexistent `archerdb_cluster_role{role="leader"}` metric
- **Fix:** Changed to detect `archerdb_region_info{role="primary"}` which exists
- **Verification:** Leader detection now succeeds for multi-node clusters
- **Committed in:** 1793cdd (Task 1 commit)

---

**Total deviations:** 3 auto-fixed (2 bugs, 1 blocking)
**Impact on plan:** All auto-fixes necessary for correct operation. No scope creep.

## Issues Encountered

- `requests` library not installed by default on system Python; installed with `--break-system-packages` flag due to externally-managed environment

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Cluster harness ready for SDK integration testing
- Data generators ready for benchmark and stress test scenarios
- All must_haves truths validated:
  - Single-node, 3-node, 5-node clusters start/stop cleanly
  - Uniform, city-concentrated, hotspot distributions working
  - Seeded (reproducible) and truly random (seed=None) generation working
  - All size tiers (small 100, medium 10K, large 100K) validated

---
*Phase: 11-test-infrastructure-foundation*
*Completed: 2026-02-01*
