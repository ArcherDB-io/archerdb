---
phase: 12-storage-optimization
plan: 07
subsystem: lsm-storage
tags: [deduplication, content-hashing, storage-optimization, lsm]
dependency-graph:
  requires: [12-01]
  provides: [block-dedup-index, content-hash-lookup, dedup-metrics]
  affects: [future-compaction-integration]
tech-stack:
  added: []
  patterns: [content-addressable-storage, lru-eviction, reference-counting]
key-files:
  created:
    - src/lsm/dedup.zig
  modified:
    - src/lsm/table.zig
    - src/config.zig
decisions:
  - id: dedup-hash-algorithm
    choice: XxHash64 from Zig stdlib
    rationale: Built-in, extremely fast, no external dependency, 64-bit collision resistance sufficient for block deduplication
  - id: dedup-index-scope
    choice: Per-level bounded index with LRU eviction
    rationale: Prevents memory explosion while maintaining effectiveness for trajectory data with localized repetition
  - id: dedup-integration-point
    choice: Module-level exports for compaction use
    rationale: Clean separation allows compaction layer to manage DedupIndex lifecycle
metrics:
  duration: 15m
  completed: 2026-01-24
---

# Phase 12 Plan 07: Block-Level Deduplication Summary

**One-liner:** XxHash64-based block deduplication with bounded LRU index for trajectory data storage reduction

## Completed Tasks

| Task | Name | Commit | Key Changes |
|------|------|--------|-------------|
| 1 | Create deduplication module | a037dd3 | DedupIndex, DedupConfig, lookup_or_insert(), LRU eviction |
| 2 | Add deduplication configuration | (in 0606901) | lsm_dedup_enabled, lsm_dedup_index_memory_mb, lsm_dedup_min_block_size |
| 3 | Integrate into table writing | 1687641 | Type exports, check_block_dedup(), compute_block_hash() |

## Technical Implementation

### DedupIndex (src/lsm/dedup.zig)

```zig
// Core data structure
pub const DedupIndex = struct {
    entries: std.AutoHashMap(u64, DedupEntry),  // hash -> entry
    current_memory: usize,                       // Memory tracking
    config: DedupConfig,                         // Enabled, limits
    current_tick: u32,                           // LRU tracking

    // Metrics
    blocks_checked: u64,
    duplicates_found: u64,
    bytes_saved: u64,
    evictions: u64,
};

// Lookup or insert a block
pub fn lookup_or_insert(block_content: []const u8, new_address: u64) LookupResult;

// LRU eviction when memory limit exceeded
fn evict_lru() void;
```

### Configuration (src/config.zig)

```zig
// Added to ConfigCluster
lsm_dedup_enabled: comptime_int = 1,           // Default: enabled
lsm_dedup_index_memory_mb: comptime_int = 64,  // 64 MiB per level
lsm_dedup_min_block_size: comptime_int = 4096, // Skip small blocks
```

### Table Integration (src/lsm/table.zig)

```zig
// Re-exported types
pub const DedupIndex = dedup.DedupIndex;
pub const DedupCheckResult = union(enum) {
    duplicate: struct { existing_address: u64, bytes_saved: usize },
    unique: void,
};

// Block dedup check function
pub fn check_block_dedup(block, dedup_index, new_address) DedupCheckResult;
pub fn compute_block_hash(block) u64;
```

## Design Decisions

### Why XxHash64?
- **Built-in:** Part of Zig stdlib, no external dependency
- **Fast:** ~15 GB/s throughput, minimal impact on write path
- **Sufficient:** 64-bit collision space adequate for block-level dedup (1 in 2^64)
- **Deterministic:** Same content always produces same hash

### Why Per-Level Bounded Index?
- **Memory control:** 64 MiB per level prevents unbounded growth
- **Locality exploitation:** Trajectory data has level-local repetition patterns
- **LRU eviction:** Keeps frequently-accessed entries, evicts stale ones
- **Reference counting:** Correct block lifecycle management during compaction

### Why Module-Level Integration?
- **Clean separation:** Dedup module provides primitives, compaction manages lifecycle
- **Testability:** Each component independently testable
- **Flexibility:** Runtime integration can choose when/where to apply dedup

## Deviations from Plan

### Configuration Commit Merged
- **What:** Task 2 (dedup config) was inadvertently committed with 12-05 (tiered compaction config)
- **Commit:** 0606901 contains both tiered compaction AND dedup configuration
- **Impact:** No functional impact, config is correctly in place
- **Root cause:** Parallel plan execution with shared file

## Verification Results

```bash
# Build check
./zig/zig build -j4 -Dconfig=lite check
# Result: PASS

# Dedup tests
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "dedup"
# Result: PASS (8 tests)

# Table tests
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "table"
# Result: PASS (4 tests including new dedup tests)
```

## Files Created/Modified

### Created
- `src/lsm/dedup.zig` - Block deduplication module (330 lines)

### Modified
- `src/lsm/table.zig` - Added dedup type exports and helper functions (+99 lines)
- `src/config.zig` - Added deduplication configuration (+42 lines, via 0606901)

## Future Integration Notes

### Compaction Integration
The DedupIndex infrastructure is ready for integration into the compaction layer:

1. **Forest level:** Create per-level DedupIndex instances
2. **Compaction write path:** Call `check_block_dedup()` before `grid.create_block()`
3. **On duplicate:** Use existing address instead of allocating new block
4. **On delete:** Call `decrement_reference()` to maintain refcount

### Expected Storage Savings
- **Trajectory data:** 10-30% reduction for fleet tracking, delivery routes
- **Best case:** Parked vehicles, common stops, repeated locations
- **Worst case:** Highly unique data (random movement, no patterns)

## Next Phase Readiness

- [x] Dedup module complete with bounded memory
- [x] Configuration options in place
- [x] Table integration provides hooks for compaction
- [ ] Runtime compaction integration (future work)
- [ ] Metrics dashboard integration (future work)
