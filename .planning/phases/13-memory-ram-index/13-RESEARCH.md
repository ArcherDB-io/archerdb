# Phase 13: Memory & RAM Index - Research

**Researched:** 2026-01-24
**Domain:** Hash table design, SIMD acceleration, memory metrics for Zig 0.14.1
**Confidence:** HIGH

## Summary

Phase 13 optimizes the RAM index for extreme performance at 100M+ entity scale. Per user context (13-CONTEXT.md), the goal shifts from "50% memory reduction" to "maximum performance" - raw speed takes priority over memory savings. The existing `GenericRamIndexType` in `src/ram_index.zig` uses open-addressing with linear probing; the user requests cuckoo hashing with guaranteed O(1) lookups and SIMD acceleration.

Key implementation areas:
1. **Cuckoo hash table design** - Two hash functions with deterministic probe sequence for guaranteed O(1) lookups
2. **64B cache-line aligned entries** - Current `IndexEntry` is already 64B; maintain this for optimal prefetch
3. **SIMD-accelerated probes** - Vectorize key comparison using Zig's `@Vector` primitives
4. **Memory metrics** - Prometheus-compatible metrics for total, per-index, and per-component breakdown
5. **RAM estimation and fail-fast** - Upfront memory requirement calculation before index creation

**Primary recommendation:** Keep the existing 64B entry format, replace linear probing with cuckoo hashing, add SIMD-accelerated key comparison via `@Vector`, and integrate memory metrics following the established Phase 11/12 Prometheus patterns.

## Standard Stack

The established libraries/tools for this domain:

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig @Vector | Built-in | SIMD operations | Native compiler support, auto-vectorization with fallback |
| stdx.hash_inline | In-repo | Hash function | Google Abseil LowLevelHash (wyhash-inspired), already used in ram_index |
| metrics.zig | In-repo | Prometheus metrics | Existing Counter/Gauge/Histogram primitives from Phase 11 |
| CountingAllocator | In-repo | Allocation tracking | Already exists in `src/counting_allocator.zig` |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| std.builtin.cpu | Built-in | CPU feature detection | Runtime SIMD capability detection |
| storage_metrics.zig | In-repo | Prometheus metric patterns | Template for new memory metrics |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Cuckoo hashing | Robin Hood hashing | Robin Hood has better worst-case but variable probe length |
| Zig @Vector | Hand-written assembly | @Vector is portable and compiler-optimized |
| 64B entries | 32B compact entries | 32B saves memory but loses TTL/metadata at index level |

## Architecture Patterns

### Recommended Project Structure

```
src/
├── ram_index.zig          # MODIFY: Replace linear probing with cuckoo hashing
├── ram_index_simd.zig     # NEW: SIMD-accelerated key comparison helpers
├── archerdb/
│   ├── metrics.zig        # EXTEND: Add memory metrics
│   └── index_metrics.zig  # NEW: RAM index specific Prometheus metrics
```

### Pattern 1: Cuckoo Hash Table with Two Hash Functions

**What:** Two independent hash functions that each map a key to a potential slot
**When to use:** O(1) guaranteed lookup performance is required
**Key insight:** With two hash functions, lookup checks exactly two locations. Insertion may displace existing entries, creating a "cuckoo" chain until an empty slot is found.

```zig
// Source: Cuckoo hashing literature + existing stdx.hash_inline
const Index = struct {
    entries: []align(64) Entry,
    capacity: u64,

    /// Primary hash function - uses high bits of hash
    inline fn hash1(entity_id: u128) u64 {
        return stdx.hash_inline(entity_id);
    }

    /// Secondary hash function - uses different mixing
    inline fn hash2(entity_id: u128) u64 {
        // XOR with a prime constant before hashing for independence
        const mixed: u128 = entity_id ^ 0x9E3779B97F4A7C15_9E3779B97F4A7C15;
        return stdx.hash_inline(mixed);
    }

    inline fn slot1(self: *const Index, entity_id: u128) u64 {
        return hash1(entity_id) % self.capacity;
    }

    inline fn slot2(self: *const Index, entity_id: u128) u64 {
        // Use fastrange for second slot to ensure different distribution
        return stdx.fastrange(hash2(entity_id), self.capacity);
    }

    /// O(1) lookup - check exactly two slots
    pub fn lookup(self: *const Index, entity_id: u128) ?*Entry {
        const s1 = self.slot1(entity_id);
        if (self.entries[s1].entity_id == entity_id) {
            return &self.entries[s1];
        }

        const s2 = self.slot2(entity_id);
        if (self.entries[s2].entity_id == entity_id) {
            return &self.entries[s2];
        }

        return null;
    }
};
```

### Pattern 2: SIMD-Accelerated Key Comparison

**What:** Use `@Vector` for parallel key comparison within cache lines
**When to use:** Batched lookups or probing multiple keys simultaneously

Zig's `@Vector` type enables portable SIMD:
- Compiles to native AVX-512/AVX2/SSE based on target CPU
- Falls back to scalar operations when SIMD unavailable
- No manual instruction set detection needed

```zig
// Source: Zig documentation + existing set_associative_cache.zig pattern
const std = @import("std");

/// Compare 4 keys simultaneously using SIMD
/// Returns bitmask of matching positions
pub inline fn simd_compare_keys(
    keys: *const [4]u128,
    target: u128,
) u4 {
    // Split u128 into two u64 vectors for comparison
    // (Zig @Vector doesn't support u128 directly on most architectures)
    const target_lo: u64 = @truncate(target);
    const target_hi: u64 = @truncate(target >> 64);

    var keys_lo: @Vector(4, u64) = undefined;
    var keys_hi: @Vector(4, u64) = undefined;

    inline for (0..4) |i| {
        keys_lo[i] = @truncate(keys[i]);
        keys_hi[i] = @truncate(keys[i] >> 64);
    }

    const target_lo_vec: @Vector(4, u64) = @splat(target_lo);
    const target_hi_vec: @Vector(4, u64) = @splat(target_hi);

    const match_lo: @Vector(4, bool) = keys_lo == target_lo_vec;
    const match_hi: @Vector(4, bool) = keys_hi == target_hi_vec;

    // Both halves must match
    const match_both = @select(bool, match_lo, match_hi, @as(@Vector(4, bool), @splat(false)));

    return @bitCast(match_both);
}

/// Batch lookup using SIMD comparison
pub fn batch_lookup(
    index: *const Index,
    entity_ids: []const u128,
    results: []?*Entry,
) void {
    // Process 4 keys at a time
    var i: usize = 0;
    while (i + 4 <= entity_ids.len) : (i += 4) {
        const batch = entity_ids[i..][0..4];
        // Fetch all 8 potential slots (2 per key)
        // Compare with SIMD
        // ... implementation details
    }

    // Handle remainder
    while (i < entity_ids.len) : (i += 1) {
        results[i] = index.lookup(entity_ids[i]);
    }
}
```

### Pattern 3: Memory Metrics with Prometheus Format

**What:** Track memory usage at multiple granularities
**When to use:** Production monitoring and capacity planning

Following the established patterns in `storage_metrics.zig`:

```zig
// Source: Extend existing metrics.zig patterns
const metrics = @import("metrics.zig");

pub var archerdb_ram_index_memory_bytes = metrics.Gauge.init(
    "archerdb_ram_index_memory_bytes",
    "Total RAM index memory usage in bytes",
    null,
);

pub var archerdb_ram_index_entries_total = metrics.Gauge.init(
    "archerdb_ram_index_entries_total",
    "Number of entries in RAM index",
    null,
);

pub var archerdb_ram_index_capacity_total = metrics.Gauge.init(
    "archerdb_ram_index_capacity_total",
    "Total capacity of RAM index in entries",
    null,
);

pub var archerdb_ram_index_load_factor = metrics.Gauge.init(
    "archerdb_ram_index_load_factor",
    "Current load factor of RAM index (0-1000 scaled)",
    null,
);

/// Update metrics from index state
pub fn update_index_metrics(index: anytype) void {
    const entry_count = index.count.load(.monotonic);
    const capacity = index.capacity;
    const memory_bytes = capacity * @sizeOf(@TypeOf(index.entries[0]));

    archerdb_ram_index_memory_bytes.set(@intCast(memory_bytes));
    archerdb_ram_index_entries_total.set(@intCast(entry_count));
    archerdb_ram_index_capacity_total.set(@intCast(capacity));

    // Load factor scaled by 1000 (e.g., 700 = 0.70)
    const load_factor = (entry_count * 1000) / capacity;
    archerdb_ram_index_load_factor.set(@intCast(load_factor));
}
```

### Pattern 4: Upfront RAM Estimation and Fail-Fast

**What:** Calculate required memory before allocation; fail with clear error if insufficient
**When to use:** Index initialization

```zig
/// Estimate RAM requirements for a given entity count
pub fn estimate_ram_bytes(entity_count: u64) u64 {
    // Target 70% load factor
    const capacity = @divFloor(entity_count * 10, 7) + 1;
    return capacity * @sizeOf(IndexEntry);
}

/// Check available system memory
pub fn get_available_memory() !u64 {
    // On Linux, read from /proc/meminfo
    if (builtin.os.tag == .linux) {
        // Parse MemAvailable from /proc/meminfo
        // ...
    }
    return error.UnsupportedPlatform;
}

pub fn init_with_validation(
    allocator: Allocator,
    expected_entities: u64,
) !Index {
    const required_bytes = estimate_ram_bytes(expected_entities);
    const available_bytes = try get_available_memory();

    if (required_bytes > available_bytes * 9 / 10) { // Leave 10% headroom
        std.log.err(
            "Insufficient RAM: need {d} GiB, available {d} GiB",
            .{
                required_bytes / (1024 * 1024 * 1024),
                available_bytes / (1024 * 1024 * 1024),
            },
        );
        return error.InsufficientMemory;
    }

    return Index.init(allocator, capacity);
}
```

### Anti-Patterns to Avoid

- **mmap tiering:** Per user context, all index data stays in RAM - no cold data offloading
- **32B compact entries:** User explicitly chose 64B for performance over memory savings
- **Variable probe length:** Cuckoo hashing guarantees max 2 probes; don't fall back to linear probing
- **Blocking SIMD detection:** Detect CPU features once at startup, not per operation
- **Unbounded displacement chains:** Set a max displacement limit (e.g., 500) and fail/rebuild if exceeded

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Hash function | Custom hash | stdx.hash_inline | Already tuned, wyhash-based |
| Memory tracking | Custom allocator | CountingAllocator | Already exists, battle-tested |
| Prometheus metrics | Custom HTTP | metrics.zig + metrics_server.zig | Established patterns |
| SIMD detection | Manual cpuid | std.builtin.cpu | Compiler handles it |
| Percentile calculation | Custom math | metrics.HistogramType | Phase 11 already implemented |

**Key insight:** The codebase already has robust infrastructure for metrics, memory tracking, and hash functions. Phase 13 work is integration and algorithm replacement, not greenfield.

## Common Pitfalls

### Pitfall 1: Cuckoo Insertion Loops

**What goes wrong:** Infinite displacement loops when table is too full
**Why it happens:** Cuckoo insertion can cycle if load factor too high
**How to avoid:** Keep load factor < 0.5; set max displacement count (500); trigger rebuild on failure
**Warning signs:** Insertion latency spikes; displacement chains > 10

### Pitfall 2: SIMD Warmup Penalty

**What goes wrong:** First SIMD operations are slow due to CPU frequency scaling
**Why it happens:** AVX2/AVX-512 may cause ~56K cycle warmup or downclocking
**How to avoid:** Use SIMD consistently (not sporadically); prefer AVX2 over AVX-512 for consistent performance
**Warning signs:** First batch of operations much slower than subsequent

### Pitfall 3: False Sharing on Entry Updates

**What goes wrong:** Multiple threads updating adjacent entries cause cache invalidation
**Why it happens:** CPU cache operates on 64B lines
**How to avoid:** 64B entry alignment (already done); single-writer guarantee from VSR
**Warning signs:** Unexplained throughput drops under concurrent load

### Pitfall 4: Hash Function Independence

**What goes wrong:** Two hash functions produce correlated outputs, degrading cuckoo performance
**Why it happens:** Simple transformations (multiply, add) don't create true independence
**How to avoid:** Use XOR with a prime constant before second hash; verify statistical independence
**Warning signs:** One slot consistently more loaded than the other

### Pitfall 5: Memory Overcommit

**What goes wrong:** OOM killer terminates process after allocation succeeds
**Why it happens:** Linux overcommits memory by default
**How to avoid:** Check available memory explicitly; use vm.overcommit_memory=2; or mlock pages
**Warning signs:** Process killed by OOM killer; sporadic crashes under memory pressure

## Code Examples

Verified patterns from official sources:

### Existing Set-Associative Cache SIMD Pattern

```zig
// Source: src/lsm/set_associative_cache.zig:291-296
// Already in codebase - use as template

inline fn search_tags(tags: *const [layout.ways]Tag, tag: Tag) Ways {
    const x: @Vector(layout.ways, Tag) = tags.*;
    const y: @Vector(layout.ways, Tag) = @splat(tag);

    const result: @Vector(layout.ways, bool) = x == y;
    return @bitCast(result);
}
```

### Existing Hash Function Usage

```zig
// Source: src/ram_index.zig:1500-1503
/// Hash function for entity_id (u128).
/// Uses Google Abseil LowLevelHash (wyhash-inspired) from stdx.
inline fn hash(entity_id: u128) u64 {
    return stdx.hash_inline(entity_id);
}
```

### Prometheus Gauge Pattern

```zig
// Source: src/archerdb/storage_metrics.zig:29-33
pub var archerdb_compaction_write_amplification = Gauge.init(
    "archerdb_compaction_write_amplification",
    "Ratio of physical to logical bytes written (1.0 = no amplification)",
    null,
);
```

### CPU Feature Detection (if needed)

```zig
// Source: Zig stdlib
const builtin = @import("builtin");

pub fn has_avx2() bool {
    return builtin.cpu.features.contains(.avx2);
}

pub fn has_avx512f() bool {
    return builtin.cpu.features.contains(.avx512f);
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Linear probing | Cuckoo hashing | Research since 2001 | Guaranteed O(1) lookup |
| Scalar key comparison | SIMD vectorized | ~2018 | 4-8x throughput for batch ops |
| Manual SIMD intrinsics | @Vector portability | Zig 0.11+ | Cross-platform, compiler-optimized |
| Single hash function | Two independent hashes | Cuckoo standard | Balanced slot utilization |

**Deprecated/outdated:**
- **Separate chaining:** Poor cache locality for large tables
- **Hand-written AVX assembly:** @Vector provides equivalent performance with portability
- **mmap tiering:** User explicitly rejected for this phase

## Open Questions

Things that couldn't be fully resolved:

1. **Optimal Max Displacement Count**
   - What we know: Literature suggests 500-1000 is typical
   - What's unclear: Best value for 100M+ entity scale
   - Recommendation: Start with 500; tune based on load testing; trigger rebuild on failure

2. **SIMD Batch Size Auto-Tuning**
   - What we know: 4-8 keys per batch is typical; depends on cache line size and CPU
   - What's unclear: Whether to auto-tune or use fixed batch size
   - Recommendation: Start with fixed batch of 4 (fits one cache line); benchmark alternatives

3. **Memory Sampling Interval**
   - What we know: Prometheus scrape typically 15-60s; real-time metrics need sub-second
   - What's unclear: Overhead of per-operation vs periodic sampling
   - Recommendation: Update metrics on scrape (lazy); add optional per-second timer if needed

4. **Second Hash Function Design**
   - What we know: Must be independent from primary; XOR+hash is common approach
   - What's unclear: Optimal constant for XOR mixing
   - Recommendation: Use well-known constant (golden ratio: 0x9E3779B97F4A7C15); verify distribution in tests

5. **Allocation Rate Metrics**
   - What we know: User marked as "Claude's discretion"
   - Recommendation: Include `archerdb_ram_index_allocs_total` counter since CountingAllocator already tracks this; low overhead

## Sources

### Primary (HIGH confidence)
- Existing codebase: `src/ram_index.zig` - Current index implementation
- Existing codebase: `src/lsm/set_associative_cache.zig` - SIMD pattern with @Vector
- Existing codebase: `src/stdx/stdx.zig` - hash_inline implementation
- Existing codebase: `src/archerdb/metrics.zig` - Prometheus primitives
- Existing codebase: `src/archerdb/storage_metrics.zig` - Metric patterns
- [Zig @Vector documentation](https://ziglang.org/documentation/master/#Vectors) - SIMD primitives

### Secondary (MEDIUM confidence)
- [ViViD Cuckoo Hash paper](https://www.researchgate.net/publication/336720299_ViViD_Cuckoo_Hash_Fast_Cuckoo_Table_Building_in_SIMD) - SIMD + cuckoo techniques
- [Analyzing Vectorized Hash Tables (VLDB 2023)](https://www.vldb.org/pvldb/vol16/p2755-bother.pdf) - AVX2 vs AVX-512 tradeoffs
- [reiner.org cuckoo hashing](https://reiner.org/cuckoo-hashing) - Why cuckoo beats alternatives

### Tertiary (LOW confidence)
- AVX-512 warmup and downclocking behavior - vendor-specific, needs validation
- Optimal displacement limits for 100M+ scale - requires empirical tuning

## Metadata

**Confidence breakdown:**
- Cuckoo hashing algorithm: HIGH - well-documented algorithm, clear implementation path
- SIMD acceleration: HIGH - existing @Vector pattern in codebase (set_associative_cache.zig)
- Memory metrics: HIGH - established Prometheus patterns from Phase 11/12
- Displacement limits: MEDIUM - literature provides guidance but tuning needed
- SIMD batch auto-tuning: LOW - marked as Claude's discretion, needs benchmarking

**Research date:** 2026-01-24
**Valid until:** 2026-02-24 (30 days - stable domain)

---

## Existing Infrastructure Summary

Key existing components that Phase 13 builds upon:

| Component | Location | Status | Phase 13 Action |
|-----------|----------|--------|-----------------|
| RAM index | `src/ram_index.zig` | Working | Replace linear probing with cuckoo |
| IndexEntry (64B) | `src/ram_index.zig:110` | Working | Keep as-is (cache-line aligned) |
| Hash function | `src/stdx/stdx.zig:hash_inline` | Working | Add second hash for cuckoo |
| SIMD pattern | `src/lsm/set_associative_cache.zig:291` | Working | Template for key comparison |
| Prometheus metrics | `src/archerdb/metrics.zig` | Working | Add memory gauges |
| CountingAllocator | `src/counting_allocator.zig` | Working | Track per-component usage |
| Storage metrics | `src/archerdb/storage_metrics.zig` | Working | Template for index metrics |

This infrastructure means Phase 13 is primarily **algorithm replacement and metric integration**, not greenfield development.
