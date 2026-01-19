# Proposal: Jump Consistent Hash for Minimal Resharding

## Summary

Add Jump Consistent Hash (Google's algorithm) as an alternative to virtual-node consistent hashing, providing O(1) memory usage with mathematically optimal data movement during resharding.

## Motivation

### Problem

The current `ConsistentHashRing` implementation uses virtual nodes (150 per shard by default), which has tradeoffs:

| Aspect | Virtual Node Ring | Issue |
|--------|-------------------|-------|
| Memory | 150 × num_shards × 24 bytes | ~58KB for 16 shards |
| Lookup | O(log n) binary search | Slower than O(1) |
| Initialization | O(n log n) sort | Slow for large rings |
| Distribution | Depends on vnode count | Requires tuning |

For ArcherDB's use case (entity-based sharding, not key-value), we can use a simpler algorithm.

### Current Behavior

- `ConsistentHashRing`: 150 virtual nodes per shard, binary search lookup
- Memory: O(shards × vnodes_per_shard)
- Data movement on resharding: ~1/N (good, but depends on vnode distribution)

### Desired Behavior

- **Jump Consistent Hash**: Zero memory overhead, O(1) computation
- **Mathematically optimal**: Exactly 1/N data moves when adding N→N+1 shards
- **Deterministic**: Same key always maps to same bucket
- **Simple**: ~20 lines of code, no data structures needed

## Background: Jump Consistent Hash

Jump Consistent Hash was published by Google in 2014 ([paper](https://arxiv.org/abs/1406.2294)). Key properties:

1. **Zero memory**: No ring, no virtual nodes - just a mathematical function
2. **O(log n) time**: Average ~5 iterations for 256 shards
3. **Optimal movement**: When going from N to N+1 buckets, exactly 1/(N+1) keys move
4. **Perfect uniformity**: Each bucket gets exactly 1/N of keys (no variance)

### Algorithm

```c
int32_t JumpConsistentHash(uint64_t key, int32_t num_buckets) {
    int64_t b = -1, j = 0;
    while (j < num_buckets) {
        b = j;
        key = key * 2862933555777941757ULL + 1;
        j = (b + 1) * (double)(1LL << 31) / (double)((key >> 33) + 1);
    }
    return b;
}
```

## Scope

### In Scope

1. **Add Jump Consistent Hash function**: `jumpHash(key: u64, num_buckets: u32) u32`
2. **Sharding strategy enum**: Allow choosing between `modulo`, `virtual_ring`, `jump_hash`
3. **Configuration**: `--sharding-strategy=jump_hash` CLI flag
4. **Migration support**: Compute exact entity movements between strategies
5. **Metrics**: Track sharding strategy in use

### Out of Scope

1. **Remove virtual node ring**: Keep as option for users who prefer it
2. **Online strategy migration**: Strategy change requires offline resharding
3. **Rendezvous hashing**: Alternative algorithm not included (more complex)

## Success Criteria

1. **Zero memory overhead**: Jump hash uses no additional memory
2. **Optimal movement**: 1/N keys move when adding 1 shard (mathematically provable)
3. **Performance**: Lookup ≤10 CPU cycles average
4. **Uniformity**: Perfect 1/N distribution (no variance)
5. **Backward compatible**: Existing configurations continue to work

## Comparison

| Property | Simple Modulo | Virtual Ring | Jump Hash |
|----------|--------------|--------------|-----------|
| Memory | O(1) | O(shards × vnodes) | O(1) |
| Lookup | O(1) | O(log n) | O(log shards) |
| Distribution | Perfect | ~Perfect (tunable) | Perfect |
| N→N+1 movement | ~50% | ~1/N (approx) | 1/(N+1) exactly |
| N→2N movement | 50% | ~50% | ~50% |
| Power-of-2 required | Yes | No | No |
| Implementation | 1 line | ~100 lines | ~15 lines |

**Recommendation**: Jump Hash as default for new deployments.

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Different distribution than ring | Migration required | Provide migration tooling |
| Users expect ring behavior | Confusion | Document strategy differences |
| Jump hash less well-known | Adoption concern | Reference Google paper, production usage |

## Stakeholders

- **Operators**: Benefit from simpler resharding with minimal data movement
- **Performance team**: Benefit from faster lookups and zero memory overhead
- **Existing users**: Can continue using virtual ring if preferred

## Related Work

- Existing: `ConsistentHashRing` in `src/sharding.zig`
- Reference: [Jump Consistent Hash paper](https://arxiv.org/abs/1406.2294)
- Used by: Google, Minio, etcd, many others
