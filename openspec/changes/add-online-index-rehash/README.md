# Change: Online Index Rehash

Resize RAM index hash table without stopping the database.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~25 hours)

## Spec Deltas

- [specs/hybrid-memory/spec.md](specs/hybrid-memory/spec.md) - Resize operations, CLI, metrics

## Summary

Enables increasing RAM index capacity without downtime:

```bash
# Check if resize is safe
archerdb index resize --check --new-capacity=2000000000

# Start resize (non-blocking)
archerdb index resize --new-capacity=2000000000

# Monitor progress
archerdb index resize --status
```

## How It Works

1. **Double-buffer**: New table allocated alongside old
2. **Lazy migration**: Entries migrate on access
3. **Background sweeper**: Remaining entries migrate in background
4. **Completion**: Old table freed when all entries migrated

```
DURING RESIZE:
┌────────────────────┐
│  Active (NEW)      │ ← Queries go here first
│  2B slots          │
├────────────────────┤
│  Old (draining)    │ ← Checked if not in new
│  1B slots          │
└────────────────────┘
```

## Key Design Decisions

1. **Lazy + background**: Hot entries migrate fast, cold entries in background
2. **Grow-only**: No shrinking (simpler, safer)
3. **Manual trigger**: Predictable ops, no surprises
4. **Rate limiting**: Background work yields to queries

## Performance Impact

- **Memory during resize**: ~2x (old + new tables)
- **Latency impact**: <10% P99 increase
- **Throughput impact**: <5% during resize
- **Completion time**: Variable based on access patterns
