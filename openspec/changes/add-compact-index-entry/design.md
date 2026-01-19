# Design: Compact Index Entry Format

## Context

ArcherDB's RAM index uses 64-byte cache-aligned entries. While optimal for CPU cache performance on high-end servers, this wastes 24 bytes per entry in padding. For 1B entities, that's 24GB of unused RAM.

## Goals / Non-Goals

### Goals

1. **50% memory reduction**: 32-byte entries halve RAM requirements
2. **Compile-time selection**: No runtime overhead for format choice
3. **Minimal code changes**: Generic programming over entry type

### Non-Goals

1. **Runtime format switching**: Complexity not justified
2. **Hybrid mode**: Mix of compact/standard entries
3. **Compression**: Orthogonal optimization

## Decisions

### Decision 1: 32-Byte Compact Entry Layout

**Choice**: Remove padding, truncate TTL to 16 bits.

**Rationale**:
- 32 bytes is half a cache line, still good alignment
- TTL precision loss acceptable for most use cases
- Essential fields preserved: entity_id, latest_id

**Implementation**:
```zig
/// CompactIndexEntry - 32-byte memory-optimized entry.
///
/// Trade-offs vs IndexEntry (64B):
/// - TTL precision: 16 bits (max ~18 hours) vs 32 bits (~136 years)
/// - No reserved space for future fields
/// - May span cache lines (2 entries per cache line)
pub const CompactIndexEntry = extern struct {
    /// Entity UUID - primary lookup key.
    entity_id: u128 = 0,      // 16 bytes

    /// Composite ID of latest GeoEvent.
    latest_id: u128 = 0,      // 16 bytes

    // Total: 32 bytes (no TTL, no padding)

    pub const empty: CompactIndexEntry = .{};

    pub inline fn is_empty(self: CompactIndexEntry) bool {
        return self.entity_id == 0;
    }

    pub inline fn is_tombstone(self: CompactIndexEntry) bool {
        return self.entity_id != 0 and self.latest_id == 0;
    }

    pub inline fn timestamp(self: CompactIndexEntry) u64 {
        return @as(u64, @truncate(self.latest_id));
    }
};

comptime {
    assert(@sizeOf(CompactIndexEntry) == 32);
    assert(@alignOf(CompactIndexEntry) >= 16);
}
```

### Decision 2: TTL Handled Externally

**Choice**: Compact format relies on GeoEvent TTL, not index-level TTL.

**Rationale**:
- TTL already stored in GeoEvent (4 bytes)
- Index-level TTL is convenience, not necessity
- TTL expiration check happens during query anyway

**Trade-off**: Slightly slower TTL checks (must read event), but acceptable for memory-constrained environments.

### Decision 3: Generic RAMIndex

**Choice**: Parameterize RAMIndex on entry type.

**Rationale**:
- Single implementation, two entry types
- Compile-time specialization for optimal code generation
- No runtime polymorphism overhead

**Implementation**:
```zig
/// Generic RAM Index parameterized on entry type.
pub fn GenericRAMIndex(comptime Entry: type) type {
    return struct {
        entries: []Entry,
        capacity: u64,
        stats: IndexStats,

        const Self = @This();

        pub fn init(allocator: Allocator, capacity: u64) !Self {
            const entries = try allocator.alloc(Entry, capacity);
            @memset(entries, Entry.empty);
            return .{
                .entries = entries,
                .capacity = capacity,
                .stats = .{ .capacity = capacity },
            };
        }

        pub fn lookup(self: *Self, entity_id: u128) ?*const Entry {
            // Same algorithm for both entry types
            // ...
        }

        pub fn upsert(self: *Self, entry: Entry) !void {
            // Same algorithm for both entry types
            // ...
        }
    };
}

// Type aliases for convenience
pub const RAMIndex = GenericRAMIndex(IndexEntry);
pub const CompactRAMIndex = GenericRAMIndex(CompactIndexEntry);
```

### Decision 4: Build-Time Configuration

**Choice**: Select format via build option, not runtime config.

**Rationale**:
- Zero runtime overhead
- Simpler code paths
- Clear deployment decision

**Implementation**:
```zig
// build.zig
const index_format = b.option(
    enum { standard, compact },
    "index-format",
    "Index entry format (standard=64B, compact=32B)",
) orelse .standard;

// Pass to compilation
exe.root_module.addOptions(options);
```

## Architecture

### Memory Layout Comparison

```
Standard (64B):          Compact (32B):
┌────────────────────┐   ┌────────────────────┐
│ entity_id  (16B)   │   │ entity_id  (16B)   │
├────────────────────┤   ├────────────────────┤
│ latest_id  (16B)   │   │ latest_id  (16B)   │
├────────────────────┤   └────────────────────┘
│ ttl_seconds (4B)   │
├────────────────────┤   2 entries per cache line
│ reserved    (4B)   │
├────────────────────┤
│ padding    (24B)   │   1 entry per cache line
└────────────────────┘
```

### Cache Performance Analysis

| Aspect | Standard (64B) | Compact (32B) |
|--------|----------------|---------------|
| Entries per cache line | 1 | 2 |
| Cache line splits | Never | Possible |
| Sequential scan | Optimal | Good |
| Random access | Optimal | Minor penalty |
| Memory bandwidth | Higher | Lower |

**Expected impact**: 0-5% throughput reduction for random access, potentially better for sequential scans due to improved cache utilization.

## Configuration

### Build Options

```bash
# Standard format (default) - 64-byte entries
zig build

# Compact format - 32-byte entries
zig build -Dindex-format=compact
```

### Runtime Detection

```zig
pub const index_entry_size: u32 = @sizeOf(ActiveIndexEntry);
pub const index_format_name: []const u8 = if (@sizeOf(ActiveIndexEntry) == 64)
    "standard" else "compact";
```

## Trade-Offs

### Standard vs Compact

| Aspect | Standard | Compact |
|--------|----------|---------|
| RAM for 1B entities | ~92GB | ~46GB |
| Index-level TTL | Yes (32-bit) | No |
| Future extensibility | 24 bytes reserved | None |
| Cache alignment | Optimal | Good |
| Target environment | High-end servers | Edge/constrained |

**Recommendation**:
- **Standard**: Production servers with ample RAM
- **Compact**: Edge deployments, cost-sensitive, <500M entities

## Validation Plan

### Unit Tests

1. **CompactIndexEntry layout**: Size and alignment assertions
2. **Generic RAMIndex**: Works with both entry types
3. **Lookup/upsert**: Identical behavior across formats

### Performance Tests

1. **Throughput comparison**: Standard vs compact under load
2. **Latency percentiles**: P50, P99, P999 for both formats
3. **Memory verification**: Actual vs expected RAM usage

### Integration Tests

1. **End-to-end**: Full query path with compact index
2. **TTL behavior**: Verify event-level TTL works correctly
