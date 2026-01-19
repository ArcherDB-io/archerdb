# Jump Consistent Hash for Minimal Resharding

**Status**: Proposal
**Change ID**: `add-jump-consistent-hash`
**Target Version**: v2.2

## Quick Summary

Add Jump Consistent Hash (Google, 2014) as an alternative sharding strategy with O(1) memory and mathematically optimal data movement during resharding.

## Why Jump Hash?

| Property | Simple Modulo | Virtual Ring | Jump Hash |
|----------|--------------|--------------|-----------|
| Memory | O(1) | O(shards × vnodes) | **O(1)** |
| Lookup | O(1) | O(log n) | **O(log shards)** |
| Distribution | Perfect | ~Perfect | **Perfect** |
| N→N+1 movement | ~50% | ~1/N | **1/(N+1) exact** |
| Power-of-2 required | Yes | No | **No** |
| Implementation | 1 line | ~100 lines | **~15 lines** |

## New CLI Flag

```bash
# Recommended for new deployments
archerdb init --sharding-strategy=jump_hash --shards=24

# Keep using virtual ring (if needed for weighted shards)
archerdb init --sharding-strategy=virtual_ring --shards=16

# Legacy simple modulo (power-of-2 only)
archerdb init --sharding-strategy=modulo --shards=16
```

## Key Benefits

1. **Zero memory**: No ring, no virtual nodes - just a mathematical function
2. **Optimal movement**: Exactly 1/(N+1) keys move when adding 1 shard
3. **Any shard count**: Not limited to power-of-2 (enables 12, 24, 48, etc.)
4. **Simple**: ~15 lines of code, mathematically proven correct

## Algorithm

```zig
pub fn jumpHash(key: u64, num_buckets: u32) u32 {
    var b: i64 = -1;
    var j: i64 = 0;
    var k = key;

    while (j < num_buckets) {
        b = j;
        k = k *% 2862933555777941757 +% 1;
        j = @intFromFloat(@as(f64, @floatFromInt(b + 1)) *
            4294967296.0 / @as(f64, @floatFromInt((k >> 33) + 1)));
    }

    return @intCast(b);
}
```

## Files

- `proposal.md` - Problem, scope, comparison with alternatives
- `design.md` - Architecture, decisions, trade-offs
- `tasks.md` - Implementation plan (~2 days)
- `specs/index-sharding/spec.md` - Formal requirements and scenarios

## Review Checklist

- [x] Problem clearly stated
- [x] Algorithm documented with reference
- [x] Strategy comparison table
- [x] Spec deltas with scenarios
- [x] Implementation tasks broken down
- [x] Backward compatibility addressed

## References

- [Jump Consistent Hash Paper](https://arxiv.org/abs/1406.2294) - Google, 2014
- Used in: Minio, etcd, CockroachDB, and many others

## Next Steps

1. Review proposal for approval
2. Implement according to tasks.md
3. Validate optimal movement in tests
4. Update documentation with strategy guide
