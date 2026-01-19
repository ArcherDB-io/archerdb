# Proposal: Compact Index Entry Format

## Summary

Add a memory-optimized 32-byte index entry format for constrained environments, reducing RAM requirements from ~92GB to ~46GB for 1B entities.

## Motivation

### Problem

The current 64-byte `IndexEntry` is optimized for cache-line alignment but consumes significant memory:

| Entities | Current (64B) | With Compact (32B) |
|----------|---------------|-------------------|
| 100M | ~9.2GB | ~4.6GB |
| 500M | ~46GB | ~23GB |
| 1B | ~92GB | ~46GB |

For edge deployments, IoT gateways, or cost-sensitive cloud environments, 92GB RAM is prohibitive.

### Current Behavior

```zig
// Current: 64 bytes (cache-line aligned)
pub const IndexEntry = extern struct {
    entity_id: u128 = 0,    // 16 bytes
    latest_id: u128 = 0,    // 16 bytes
    ttl_seconds: u32 = 0,   // 4 bytes
    reserved: u32 = 0,      // 4 bytes
    padding: [24]u8,        // 24 bytes (wasted)
};
```

24 bytes per entry are reserved padding with no current use.

### Desired Behavior

- **Compact format**: 32-byte entries for memory-constrained environments
- **Compile-time selection**: Choose format at build time
- **Trade-off documentation**: Clear guidance on when to use each format

## Scope

### In Scope

1. **CompactIndexEntry**: 32-byte struct with essential fields only
2. **Generic RAMIndex**: Parameterized on entry type
3. **Build flag**: `--index-format=compact|standard`
4. **Metrics**: Memory usage reporting per format

### Out of Scope

1. **Runtime format switching**: Too complex for initial implementation
2. **Variable-length entries**: Keep fixed-size for simplicity
3. **Compression**: Different optimization approach

## Success Criteria

1. **Memory reduction**: 50% RAM reduction with compact format
2. **Performance parity**: <5% throughput degradation vs standard
3. **Compatibility**: Same wire protocol, transparent to clients

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Reduced TTL precision | Some use cases affected | Document 16-bit TTL limits (18 hours max) |
| No room for future fields | Extensibility limited | Standard format remains available |
| Cache-line split | Performance degradation | Benchmark thoroughly |

## Stakeholders

- **Edge deployment teams**: Need smaller memory footprint
- **Cost-sensitive operators**: Cloud RAM is expensive
- **IoT platform developers**: Gateway devices have limited RAM
