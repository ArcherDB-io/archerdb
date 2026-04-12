# Benchmark Framework

This document describes ArcherDB's benchmark evidence model and where benchmark artifacts live.

## Benchmark Layers

ArcherDB currently has two benchmark layers in the repository:

1. The Python benchmark harness under [`test_infrastructure/benchmarks/`](/home/g/archerdb/test_infrastructure/benchmarks)
2. GitHub Actions workflows for baseline comparison and published history under [`.github/workflows/benchmark.yml`](/home/g/archerdb/.github/workflows/benchmark.yml) and [`.github/workflows/benchmark-weekly.yml`](/home/g/archerdb/.github/workflows/benchmark-weekly.yml)

## Local Outputs

Local benchmark runs write to:

- `reports/benchmarks/` for detailed run outputs
- `reports/history/` for local history
- `reports/baselines/` for saved baselines

These are the authoritative local paths for development and release-candidate evidence.

## Published History

The manual benchmark publication workflow stores promoted historical artifacts in:

- `benchmarks/history/`

Use that location for checked-in benchmark snapshots and long-term graph publication. Do not assume it is populated unless the publication workflow has been run.

## CLI Surface

The benchmark CLI is the supported entry point for local execution:

```bash
# Single topology
python3 test_infrastructure/benchmarks/cli.py run --topology 3 --time-limit 60 --op-count 10000

# Full suite
python3 test_infrastructure/benchmarks/cli.py run --full-suite

# Full suite without mixed workload
python3 test_infrastructure/benchmarks/cli.py run --full-suite --no-mixed
```

The active harness now drives ArcherDB through the supported SDK/client surface.
It does not send raw HTTP requests at replica/message-bus ports.

For larger local topologies, the harness also uses a machine-fit cluster profile so
5-node and 6-node runs do not reserve the same per-node memory budget as 1-node and
3-node runs on a shared development machine.

For the 6-node local topology, the harness now also:

- formats the cluster as `5` voters plus `1` standby
- passes `--replica-count` through both `format` and `start`
- staggers startup until each replica completes local init
- orders SDK endpoints as leader-first, then the remaining voters

Current checked-in quick artifacts from the April 9, 2026 evidence refresh live under:

- `reports/benchmarks/release-20260409-sdkquick/20260409-055134-1node.json`
- `reports/benchmarks/release-20260409-sdkquick/20260409-055217-3node.json`
- `reports/benchmarks/release-20260409-sdkquick/20260409-063550-5node.json`
- `reports/benchmarks/release-20260409-sdkquick/20260409-082107-6node.json`

## Performance Targets

The repository currently uses these comparison gates on comparable hardware profiles:

| Metric | Baseline Target | Stretch Target |
|--------|-----------------|----------------|
| 3-node throughput | >=770K events/sec | >=1M events/sec |
| Read latency P95 | <1ms | <0.5ms |
| Read latency P99 | <10ms | <5ms |
| Write latency P95 | <10ms | <5ms |
| Write latency P99 | <50ms | <25ms |

## Release Rule

Performance claims in release docs and announcements should only cite benchmark artifacts produced by the real benchmark harness. Synthetic proxies and stale historical summaries are not sufficient release evidence.
