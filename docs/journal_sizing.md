# Journal Sizing for ArcherDB

This document analyzes TigerBeetle's journal configuration and calculates
requirements for ArcherDB's target throughput of 1M ops/sec.

## Current Configuration (from TigerBeetle)

| Parameter | Value | Notes |
|-----------|-------|-------|
| `journal_slot_count` | 1,024 | Maximum batch entries in journal |
| `message_size_max` | 1 MiB | Maximum message/prepare size |
| `vsr_checkpoint_ops` | 960 | Checkpoint interval |
| Header size | 256 bytes | Per message header |
| Transfer/Account size | 128 bytes | Per record |

### Journal Storage Layout
```
Journal = Headers Zone + Prepares Zone
       = (1,024 × 256 bytes) + (1,024 × 1 MiB)
       = 256 KiB + 1 GiB
       ≈ 1 GiB total
```

## Retention Time Formula

```
Retention = journal_slot_count / ops_per_second
```

### At 1M ops/sec with Current Settings
```
1,024 slots / 1,000,000 ops/sec = 1.024 milliseconds
```

This means if a replica crashes, it has approximately **1ms of operations**
in the journal before wrap.

## Transfer Capacity per Message

```
Max transfers/message = (message_size_max - header_size) / transfer_size
                      = (1,048,576 - 256) / 128
                      = 8,190 transfers
```

## Validation: Is 8192 Slots Sufficient?

Per the spec, we need to validate `journal_slot_count=8192` for 1M ops/sec:

```
Retention at 8,192 slots:
  8,192 / 1,000,000 = 8.192 milliseconds

With 8,190 transfers per message:
  Throughput = 8,190 × (1,000,000 / 8,192) ≈ 1B transfers/sec
```

**Assessment**: 8,192 slots provides adequate retention (~8ms) for ArcherDB's
target. The checkpoint interval would need adjustment:

```
vsr_checkpoint_ops = journal_slot_count - (pipeline_prepare_queue_max × 2) - lsm_compaction_ops
                   = 8,192 - 16 - 32
                   = 8,144 ops per checkpoint
```

## Durability Constraints

The following invariant must hold (from constants.zig):
```zig
assert(vsr_checkpoint_ops + lsm_compaction_ops +
       pipeline_prepare_queue_max * 2 <= journal_slot_count);
```

With 8,192 slots: `8,144 + 32 + 16 = 8,192` ✓

## Recommendation for ArcherDB

For initial 1M ops/sec target, we recommend:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `journal_slot_count` | 8,192 | 8× retention for better recovery |
| `message_size_max` | 1 MiB | Unchanged, proven |
| `vsr_checkpoint_ops` | 8,144 | Max before wrap |

### Why Not Larger?

- 8,192 slots = 8 GiB journal (reasonable for modern NVMe)
- Retention of 8ms is adequate for replica recovery
- Larger journals increase memory pressure and startup time
- GeoEvents are 128 bytes (same as TigerBeetle accounts/transfers)

### Scaling Beyond 1M ops/sec

For 10M ops/sec (future):
- Consider `journal_slot_count = 16,384` (16ms retention)
- Or increase `message_size_max` to 4 MiB (32K events per batch)
- Balance: retention time vs. batch latency vs. memory

## Key Files

- `src/constants.zig`: Derived configuration values
- `src/config.zig`: Base configuration
- `src/vsr/journal.zig`: WAL implementation
- `src/vsr.zig`: Checkpoint logic

## References

- TigerBeetle Design: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/DESIGN.md
- ArcherDB Spec: `openspec/changes/add-geospatial-core/specs/state-machine/spec.md`
