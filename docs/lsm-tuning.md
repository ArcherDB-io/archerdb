# LSM Tree Tuning Guide

This guide describes ArcherDB's LSM tuning model after the tier redesign.

All tier presets now share one high-performance runtime profile. Tier differences
exist only in capacity quotas (RAM index and disk limits).

## Runtime Model

ArcherDB uses one shared runtime profile for `lite`, `standard`, `pro`,
`enterprise`, and `ultra`.

| Runtime parameter | Shared value | Why |
|-------------------|--------------|-----|
| `message_size_max` | `10 MiB` | Prevents request-size bottlenecks in ingest/query paths |
| `block_size` | `1 MiB` | Maximizes sequential I/O throughput |
| `lsm_levels` | `8` | Large capacity envelope with predictable compaction behavior |
| `lsm_growth_factor` | `8` | Balanced write/read amplification |
| `lsm_compaction_ops` | `128` | Larger memtables, fewer flush cycles |
| `lsm_manifest_compact_extra_blocks` | `3` | Keeps manifest growth bounded |
| `lsm_table_coalescing_threshold_percent` | `35` | Aggressive coalescing for space efficiency |
| `pipeline_prepare_queue_max` | `24` | Higher parallelism in the prepare pipeline |
| `journal_slot_count` | `1024` | Keeps WAL sizing practical while preserving throughput |
| `journal_iops_write_max` | `32` | Matches journal safety invariants with current WAL layout |
| `journal_iops_read_max` | `24` | High read-side WAL concurrency |
| `grid_iops_read_max` | `96` | High read concurrency for LSM/grid access |
| `grid_iops_write_max` | `96` | High write concurrency for compaction/replication work |

## Capacity-Only Tier Matrix

These are the only intended differences between tier profiles:

| Tier | RAM index default | Storage default / max |
|------|-------------------|-----------------------|
| `lite` | `128 MiB` | `16 GiB / 16 GiB` |
| `standard` | `16 GiB` | `256 GiB / 1 TiB` |
| `pro` | `32 GiB` | `2 TiB / 8 TiB` |
| `enterprise` | `64 GiB` | `16 TiB / 64 TiB` |
| `ultra` | `128 GiB` | `64 TiB / 256 TiB` |

## What "Capacity-Only" Means in Practice

- If ingest stops because of `TOO_MUCH_DATA` (`status=1`) before RAM or disk is exhausted, that is a transport/request-shape issue, not a tier capacity limit.
- Correct capacity failures should present as resource boundaries, for example:
  - RAM index pressure (`IndexDegraded`)
  - Storage size limit exhaustion
- Tier selection should not be used to tune throughput or latency behavior.

## Hardware Guidance

Runtime tuning is shared, so hardware determines absolute throughput:

| Target throughput | Suggested CPU | Suggested RAM | Suggested storage |
|-------------------|---------------|---------------|-------------------|
| 100K events/sec | 8 cores | 16+ GB | NVMe Gen3+ |
| 500K events/sec | 16 cores | 32+ GB | Fast NVMe |
| 1M+ events/sec | 32+ cores | 64+ GB | NVMe Gen4/Gen5 |

Use tier quotas for capacity governance, not performance throttling.

## Benchmarking

### Quick benchmark

```bash
./scripts/benchmark_lsm.sh --config=standard --scenario=mixed --duration=60
```

### Capacity test (real run)

```bash
python3 scripts/test_capacity_limits.py --config lite --optimize ReleaseFast
python3 scripts/test_capacity_limits.py --config standard --optimize ReleaseFast
```

By default, capacity test artifacts are written to `/tmp/archerdb_capacity_runs`.

## Interpreting Results

For capacity runs, verify:

1. No early transport bottleneck (`status=1`) at normal batch sizes.
2. Throughput remains in the same order of magnitude across tiers on the same hardware.
3. Failure reason changes with capacity quotas, not tier runtime behavior.

Example summary fields:

- `events_inserted`
- `unique_entries`
- `cpu_percent_avg` / `cpu_percent_peak`
- `ram_rss_avg_bytes` / `ram_rss_peak_bytes`
- `disk_logical_bytes` / `disk_physical_bytes_from_du`
- `failure_reason` and `first_error_code`

## Troubleshooting

### Capacity run fails with `status=1`

- Reduce per-request payload in the test runner (adaptive batch backoff should already do this).
- Ensure the test uses the intended tier build and optimize mode.
- Confirm server request envelope has not been overridden to a small value.

### Capacity run fails too early on RAM index

- This is expected for lower-capacity tiers.
- `--ram-index-size` can lower RAM index budget at runtime but cannot exceed the tier cap.
- Increase `ram_index_size_default` only if product intent requires a higher capacity boundary.

### Capacity run fails on storage limit

- Verify `storage_size_limit_default` and `storage_size_limit_max` for the selected tier.
- Use larger tier quotas when the workload requires longer retention.

## References

- `src/config.zig`
- `src/constants.zig`
- `scripts/test_capacity_limits.py`
- `scripts/benchmark_lsm.sh`
