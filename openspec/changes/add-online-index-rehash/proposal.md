# Proposal: Online Index Rehash

## Summary

Enable resizing the RAM index hash table without stopping the database, allowing capacity increases as data grows beyond initial estimates.

## Motivation

### Problem

Current RAM index capacity is fixed at startup:

```zig
// src/ram_index.zig - capacity is immutable
pub fn init(allocator: Allocator, capacity: u64) !Self {
    const entries = try allocator.alloc(IndexEntry, capacity);
    // ...
}
```

If entity count grows beyond provisioned capacity, operators must:
1. Stop the database
2. Restart with larger capacity
3. Wait for index to rebuild from disk

For 24/7 services, this downtime is unacceptable.

### Current Behavior

- Index capacity set at startup via configuration
- No mechanism to resize running index
- Capacity exceeded = `IndexCapacityExceeded` error
- Recovery requires full restart and rebuild

### Desired Behavior

- **Online resize**: Increase capacity without stopping queries
- **Gradual migration**: Migrate entries during idle time
- **Zero data loss**: All entries preserved during resize
- **Progress visibility**: Metrics showing rehash progress

## Scope

### In Scope

1. **Incremental rehash**: Migrate entries in small batches
2. **Concurrent access**: Reads/writes continue during rehash
3. **Double buffering**: Old and new tables coexist during migration
4. **Progress metrics**: Track rehash completion percentage
5. **CLI command**: Trigger resize via `archerdb index resize`

### Out of Scope

1. **Shrinking**: Only grow, never shrink (simpler, safer)
2. **Automatic resize**: Manual trigger only (predictable)
3. **Hot-standby takeover**: Just resize in place

## Success Criteria

1. **Zero downtime**: No query failures during resize
2. **Bounded latency impact**: <10% P99 increase during rehash
3. **Progress tracking**: Operators can monitor completion
4. **Rollback capability**: Abort resize if issues detected

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Memory spike during resize | OOM | Require 2x headroom check before start |
| Performance degradation | Latency increase | Throttle rehash rate, priority to queries |
| Incomplete resize crash | Data inconsistency | WAL-log resize state, resume on restart |
| Concurrent modification bugs | Data corruption | Extensive testing, formal verification |

## Stakeholders

- **Operators**: Need to grow capacity without downtime
- **SRE teams**: Need predictable resize behavior
- **Capacity planners**: Need visibility into resize progress
