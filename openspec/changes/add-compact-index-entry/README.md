# Change: Compact Index Entry Format

Memory-optimized 32-byte index entries for constrained environments.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~13 hours)

## Spec Deltas

- [specs/hybrid-memory/spec.md](specs/hybrid-memory/spec.md) - CompactIndexEntry, build options

## Summary

Adds optional 32-byte `CompactIndexEntry` format that halves RAM requirements:

| Entities | Standard (64B) | Compact (32B) |
|----------|----------------|---------------|
| 100M | ~9.2GB | ~4.6GB |
| 500M | ~46GB | ~23GB |
| 1B | ~92GB | ~46GB |

## Trade-Offs

| Aspect | Standard | Compact |
|--------|----------|---------|
| Entry size | 64 bytes | 32 bytes |
| Index-level TTL | Yes | No |
| Future extensibility | 24 bytes reserved | None |
| Cache alignment | Optimal | Good |
| Target | High-end servers | Edge/constrained |

## Usage

```bash
# Standard format (default)
zig build

# Compact format for constrained environments
zig build -Dindex-format=compact
```

## Key Design Decisions

1. **32-byte layout**: entity_id (16B) + latest_id (16B), no TTL/padding
2. **Build-time selection**: No runtime overhead
3. **Generic RAMIndex**: Single implementation, two entry types
4. **TTL via GeoEvent**: Compact entries rely on event-level TTL
