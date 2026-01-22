---
phase: 04-replication
plan: 02
subsystem: replication
tags: [spillover, durability, metrics, disk-persistence]
dependency-graph:
  requires: [04-01]
  provides: [SpilloverManager, replication_spillover_bytes, replication_state]
  affects: [04-03, 06-observability]
tech-stack:
  added: []
  patterns: [atomic-writes, temp-rename, segment-files]
key-files:
  created:
    - src/replication/spillover.zig
  modified:
    - src/replication.zig
    - src/archerdb/metrics.zig
    - src/replication/providers.zig
    - src/replication/s3_client.zig
    - src/replication/sigv4.zig
decisions:
  - id: "04-02-D1"
    summary: "SpilloverSegment uses u64 checksum instead of u128"
    rationale: "Simpler alignment, Wyhash produces u64, 64-byte struct layout"
  - id: "04-02-D2"
    summary: "spillover_dir replaces spillover_path in Config"
    rationale: "SpilloverManager manages directory with metadata and segments"
  - id: "04-02-D3"
    summary: "Iterator seeks past body data without reading"
    rationale: "Recovery iterator returns headers only; full body read done by ShipQueue"
metrics:
  duration: 17 min
  completed: 2026-01-22
---

# Phase 04 Plan 02: Disk Spillover for Replication Durability Summary

Atomic disk spillover with metadata tracking for replication entries when S3 uploads fail or memory fills.

## Completed Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create spillover manager module | f398253 | src/replication/spillover.zig |
| 2 | Wire spillover into ShipQueue and add metrics | c625f9c | src/replication.zig, src/archerdb/metrics.zig |
| 3 | Trigger spillover on S3 failure and wire coordinator | 5ab7f28 | src/replication.zig |

## Implementation Details

### Task 1: SpilloverManager Module
Created `src/replication/spillover.zig` with:
- **SpilloverMeta**: JSON-persisted metadata tracking segment count, oldest/newest op, total bytes
- **SpilloverSegment**: 64-byte binary header with magic, version, entry count, checksum
- **SpillEntry**: Header + body structure for spillover operations
- **EntryIterator**: Sequential recovery of entries from spillover segments
- **SpilloverManager**: Manages spillover directory with atomic writes (temp file + rename)

Key patterns:
- Atomic writes: Write to `.tmp_N.spill`, sync, then rename to `000001.spill`
- Segment rotation: Each spillEntries() call creates a new segment
- Metadata persistence: meta.json tracks all segments for recovery

### Task 2: ShipQueue Integration
Updated `src/replication.zig`:
- Added `spillover_manager` field to ShipQueue
- Changed Config from `spillover_path: ?[]const u8` to `spillover_dir: ?[]const u8`
- Replaced `spillToDisk()` to use SpilloverManager atomic writes
- Updated `recoverFromDisk()` to use SpilloverManager iterator

Added metrics to `src/archerdb/metrics.zig`:
- `replication_spillover_bytes`: Current bytes on disk spillover
- `replication_spillover_segments`: Number of spillover segments
- `replication_state`: 0=healthy, 1=degraded (spillover active), 2=failed

### Task 3: Coordinator Wiring
Updated ShipCoordinator:
- Added `data_dir` to Config for spillover directory
- Modified `tick()` to trigger spillover after `max_retries` (10) consecutive failures
- Added `markUploaded()` call on successful ship to clean up spillover files
- Updates `replication_state` metric to degraded (1) during spillover
- Restores healthy state (0) when spillover is cleared
- Added `updateLagMetrics()` for replication lag tracking

## Verification Results

```
./zig/zig build                                    # Compiles without errors
./zig/zig build test:unit -- --test-filter "spillover"    # 11/11 tests pass
./zig/zig build test:unit -- --test-filter "ShipQueue"    # All tests pass
./zig/zig build test:unit -- --test-filter "metrics"      # All tests pass
./zig/zig build test:unit -- --test-filter "replication"  # All tests pass
./scripts/add-license-headers.sh --check           # All files have headers
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] SpilloverSegment size alignment**
- **Found during:** Task 1/2
- **Issue:** u128 checksum caused alignment padding issues
- **Fix:** Changed to u64 checksum, added explicit padding fields
- **Files modified:** src/replication/spillover.zig

**2. [Rule 1 - Bug] EntryIterator segment advancement**
- **Found during:** Task 2 tests
- **Issue:** Iterator re-read same segment after exhausting entries
- **Fix:** Track file open state and increment segment_id when exhausted
- **Files modified:** src/replication/spillover.zig

**3. [Rule 3 - Blocking] var/const warnings in S3 modules**
- **Found during:** Task 2 build
- **Issue:** Unused mutable variables in providers.zig, s3_client.zig
- **Fix:** Changed to const where appropriate
- **Files modified:** src/replication/providers.zig, src/replication/s3_client.zig

## Key Decisions

1. **SpilloverSegment 64-byte layout**: Explicit padding fields instead of compiler-inserted padding for cross-platform binary compatibility.

2. **spillover_dir vs spillover_path**: New API uses directory path, SpilloverManager creates subdirectory structure with meta.json and numbered .spill files.

3. **Iterator body handling**: EntryIterator returns headers only, seeks past body data. ShipQueue allocates and reads body separately during recovery.

## Next Phase Readiness

### Inputs Provided
- SpilloverManager for disk durability
- Spillover metrics exposed via Prometheus
- ShipCoordinator triggers spillover on S3 failure

### Dependencies Met
- Requires: 04-01 (S3 client) - COMPLETE
- Provides: SpilloverManager, replication durability metrics
- Affects: 04-03 (recovery testing), 06-observability (metrics)

### Outstanding Items
None - ready for 04-03 (recovery and testing).
