# Design: Jump Consistent Hash for Minimal Resharding

## Context

ArcherDB currently supports two sharding strategies:
1. **Simple modulo**: `shard = hash % num_shards` (requires power-of-2 shards, 50% movement on any change)
2. **Virtual node ring**: `ConsistentHashRing` with 150 vnodes per shard (~1/N movement, but O(n) memory)

This proposal adds Jump Consistent Hash as a third option that combines the best properties:
- O(1) memory like modulo
- Optimal 1/N movement like consistent hashing
- Works with any shard count (not just power-of-2)

## Goals / Non-Goals

### Goals

1. **Zero memory overhead**: No ring data structure, just computation
2. **Optimal resharding**: Mathematically minimal data movement
3. **Fast lookup**: O(log n) iterations, cache-friendly
4. **Simple implementation**: ~15 lines, easy to verify
5. **Strategy selection**: Let users choose the right tradeoff

### Non-Goals

1. **Replace existing strategies**: Keep all options available
2. **Online strategy migration**: Too complex, require offline migration
3. **Weighted shards**: Jump hash assumes uniform weights

## Decisions

### Decision 1: Implement Standard Jump Hash Algorithm

**Choice**: Use Google's exact algorithm without modifications.

**Rationale**:
- Mathematically proven optimal
- Well-understood behavior
- Widely deployed in production
- Easy to verify against reference

**Implementation**:
```zig
/// Jump Consistent Hash (Google, 2014)
///
/// Paper: https://arxiv.org/abs/1406.2294
///
/// Properties:
/// - O(1) memory
/// - O(log n) time (average ~5 iterations for 256 buckets)
/// - Perfect uniformity
/// - Optimal movement: 1/(N+1) keys move when N→N+1 buckets
///
pub fn jumpHash(key: u64, num_buckets: u32) u32 {
    var b: i64 = -1;
    var j: i64 = 0;
    var k = key;

    while (j < num_buckets) {
        b = j;
        k = k *% 2862933555777941757 +% 1;
        j = @intFromFloat(@as(f64, @floatFromInt(b + 1)) *
            @as(f64, @floatFromInt(@as(u64, 1) << 31)) /
            @as(f64, @floatFromInt((k >> 33) + 1)));
    }

    return @intCast(b);
}
```

### Decision 2: Add Sharding Strategy Enum

**Choice**: Create a `ShardingStrategy` enum with explicit selection.

**Rationale**:
- Makes strategy choice explicit
- Enables different strategies for different use cases
- Configuration persisted in cluster metadata

**Implementation**:
```zig
pub const ShardingStrategy = enum {
    /// Simple modulo: shard = hash % num_shards
    /// - Requires power-of-2 shard count
    /// - 50% movement on any change
    /// - O(1) lookup, O(1) memory
    modulo,

    /// Virtual node ring: binary search on sorted ring
    /// - Any shard count
    /// - ~1/N movement (depends on vnode count)
    /// - O(log n) lookup, O(n) memory
    virtual_ring,

    /// Jump consistent hash: mathematical function
    /// - Any shard count
    /// - Exactly 1/(N+1) movement for N→N+1
    /// - O(log n) lookup, O(1) memory
    jump_hash,

    pub fn isDefault() ShardingStrategy {
        return .jump_hash;  // Recommended for new deployments
    }
};
```

### Decision 3: Configuration via CLI Flag

**Choice**: Add `--sharding-strategy` CLI flag.

**Rationale**:
- Operator choice at deployment time
- Strategy is fixed for cluster lifetime
- Migration requires explicit resharding

**Configuration**:
```bash
# New cluster with jump hash (recommended)
archerdb init --sharding-strategy=jump_hash --shards=16

# New cluster with virtual ring (backward compatible)
archerdb init --sharding-strategy=virtual_ring --shards=16

# New cluster with simple modulo (legacy)
archerdb init --sharding-strategy=modulo --shards=16
```

### Decision 4: Migration Support Between Strategies

**Choice**: Provide tooling to compute exact migrations.

**Rationale**:
- Users may want to migrate from modulo to jump hash
- Need to know exactly which entities move
- Enables safe offline migration

**Implementation**:
```zig
/// Compute migrations when changing strategies.
pub fn computeStrategyMigration(
    entity_ids: []const u128,
    old_strategy: ShardingStrategy,
    old_shards: u32,
    new_strategy: ShardingStrategy,
    new_shards: u32,
) MigrationPlan {
    // For each entity, compute old and new shard
    // Return list of (entity_id, old_shard, new_shard)
}
```

### Decision 5: Jump Hash as Default for New Clusters

**Choice**: Make `jump_hash` the default strategy for new clusters.

**Rationale**:
- Best tradeoffs for most use cases
- Zero memory overhead
- Optimal resharding behavior
- Works with any shard count

**Backward Compatibility**:
- Existing clusters keep their configured strategy
- `modulo` and `virtual_ring` remain available
- No automatic migration

## Architecture

### Component Changes

#### 1. ShardingStrategy Enum (src/sharding.zig)

```zig
pub const ShardingStrategy = enum(u8) {
    modulo = 0,
    virtual_ring = 1,
    jump_hash = 2,

    pub fn fromString(s: []const u8) ?ShardingStrategy {
        if (std.mem.eql(u8, s, "modulo")) return .modulo;
        if (std.mem.eql(u8, s, "virtual_ring")) return .virtual_ring;
        if (std.mem.eql(u8, s, "jump_hash")) return .jump_hash;
        return null;
    }

    pub fn toString(self: ShardingStrategy) []const u8 {
        return switch (self) {
            .modulo => "modulo",
            .virtual_ring => "virtual_ring",
            .jump_hash => "jump_hash",
        };
    }

    pub fn requiresPowerOfTwo(self: ShardingStrategy) bool {
        return self == .modulo;
    }
};
```

#### 2. Jump Hash Function (src/sharding.zig)

```zig
/// Jump Consistent Hash - O(1) memory, O(log n) time, optimal movement
pub fn jumpHash(key: u64, num_buckets: u32) u32 {
    assert(num_buckets > 0);

    var b: i64 = -1;
    var j: i64 = 0;
    var k = key;

    while (j < num_buckets) {
        b = j;
        k = k *% 2862933555777941757 +% 1;
        const divisor = (k >> 33) + 1;
        j = @intFromFloat(
            @as(f64, @floatFromInt(b + 1)) *
            (4294967296.0 / @as(f64, @floatFromInt(divisor)))
        );
    }

    return @intCast(b);
}
```

#### 3. Unified Shard Lookup (src/sharding.zig)

```zig
/// Get shard for entity using configured strategy.
pub fn getShardForEntity(
    entity_id: u128,
    num_shards: u32,
    strategy: ShardingStrategy,
    ring: ?*const ConsistentHashRing,
) u32 {
    const key = computeShardKey(entity_id);

    return switch (strategy) {
        .modulo => computeShardBucket(key, num_shards),
        .virtual_ring => if (ring) |r| r.getShardByKey(key) else computeShardBucket(key, num_shards),
        .jump_hash => jumpHash(key, num_shards),
    };
}
```

#### 4. CLI Configuration (src/archerdb/cli.zig)

```zig
/// Sharding configuration arguments
pub const ShardingArgs = struct {
    /// Number of shards (8-256)
    num_shards: u32 = 16,

    /// Sharding strategy
    sharding_strategy: ShardingStrategy = .jump_hash,

    /// Virtual nodes per shard (only for virtual_ring)
    vnodes_per_shard: u16 = 150,
};
```

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ Entity Operation (insert/lookup)                                 │
│                                                                  │
│ entity_id → computeShardKey() → shard_key (u64)                 │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Strategy Selection                                               │
│                                                                  │
│ if strategy == modulo:                                          │
│     shard = shard_key & (num_shards - 1)  // O(1)               │
│                                                                  │
│ if strategy == virtual_ring:                                    │
│     shard = ring.binarySearch(shard_key)  // O(log vnodes)      │
│                                                                  │
│ if strategy == jump_hash:                                       │
│     shard = jumpHash(shard_key, num_shards)  // O(log shards)   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Route to Shard                                                   │
│                                                                  │
│ shard_id → shard_connection → execute operation                 │
└─────────────────────────────────────────────────────────────────┘
```

## Trade-Offs

### Jump Hash vs Virtual Ring

| Aspect | Jump Hash | Virtual Ring |
|--------|-----------|--------------|
| **Pros** | Zero memory, optimal movement, simple code | More flexible, supports weighted shards |
| **Cons** | Can't remove arbitrary shards easily | Memory overhead, slower lookups |
| **Best for** | Horizontal scaling (add shards) | Complex topologies (weighted, removals) |

### Recommendation

- **New deployments**: Use `jump_hash` (default)
- **Weighted shards needed**: Use `virtual_ring`
- **Legacy compatibility**: Use `modulo` (if already using power-of-2)

## Validation Plan

### Unit Tests

1. **Jump hash determinism**: Same key always returns same bucket
2. **Jump hash distribution**: Perfect uniformity (each bucket gets 1/N)
3. **Jump hash movement**: Verify 1/(N+1) movement for N→N+1
4. **Strategy selection**: Correct function called for each strategy

### Integration Tests

1. **Entity routing**: Entities route to correct shards
2. **Strategy persistence**: Strategy survives restart
3. **Migration computation**: Correct entity movements computed

### Benchmarks

1. **Lookup latency**: Compare modulo vs ring vs jump hash
2. **Memory usage**: Verify O(1) for jump hash
3. **Resharding movement**: Verify optimal movement

## Implementation Phases

### Phase 1: Core Implementation (1 day)

1. Add `jumpHash()` function
2. Add `ShardingStrategy` enum
3. Add `getShardForEntity()` unified lookup
4. Unit tests for all strategies

### Phase 2: Configuration (0.5 day)

1. Add `--sharding-strategy` CLI flag
2. Persist strategy in cluster metadata
3. Validate power-of-2 for modulo strategy

### Phase 3: Migration Support (0.5 day)

1. Add strategy migration computation
2. Add migration verification
3. Integration tests

### Phase 4: Documentation (0.5 day)

1. Update operational docs
2. Add strategy selection guide
3. Document migration procedures
