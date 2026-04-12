# CI Tier Structure

ArcherDB uses a tiered CI approach to balance fast feedback with comprehensive testing.

## Overview

| Tier | Duration | Trigger | Purpose |
|------|----------|---------|---------|
| Smoke | <5 min | Every push | Fast feedback, gate PRs |
| PR | <15 min | Pull requests | Comprehensive validation |
| Nightly | 2h | Manual dispatch | Full coverage, edge cases |
| Weekly | 3h | Manual dispatch | Performance regression detection and history publication |

## Tier 1: Smoke Tests

**Trigger:** Every push to main, every commit in PRs

**Duration:** <5 minutes

**Scope:**
- Build verification (compiles cleanly)
- Basic connectivity test per SDK
- Single operation per SDK (insert + query)
- Single-node topology only

**Purpose:**
- Immediate feedback on breakage
- Gate for PR merges
- Catch obvious regressions fast

**Failure handling:**
- Blocks PR merge
- Notifies author immediately
- Must fix before proceeding

**Jobs:**

| Job | Tests | Time |
|-----|-------|------|
| build | Compile check | 30s |
| python-smoke | 3 tests | 45s |
| node-smoke | 3 tests | 45s |
| go-smoke | 3 tests | 30s |
| java-smoke | 3 tests | 90s |
| c-smoke | 3 tests | 20s |

All SDK jobs run in parallel using GitHub Actions matrix strategy.

## Tier 2: PR Tests

**Trigger:** Pull request opened, synchronized, or reopened

**Duration:** <15 minutes

**Scope:**
- Full SDK test suite for all 5 SDKs
- Single-node topology
- All 14 operations tested
- Error handling verification
- Retry logic validation

**Purpose:**
- Comprehensive validation before merge
- Catch edge cases smoke tests miss
- Verify parity across SDKs

**Failure handling:**
- Blocks PR merge
- Detailed test report in PR comment
- Must fix all failures before merge

**Jobs:**

| Job | Tests | Time |
|-----|-------|------|
| python-full | ~100 tests | 3 min |
| node-full | ~80 tests | 2 min |
| go-full | ~70 tests | 1.5 min |
| java-full | ~60 tests | 4 min |
| c-full | ~50 tests | 1 min |
| zig-full | ~50 tests | 1 min |
| parity-check | 84 cells | 3 min |

## Tier 3: Nightly Tests

**Trigger:** Manual `workflow_dispatch`

**Duration:** ~2 hours

**Scope:**
- All Tier 2 tests plus:
- Multi-node topologies (1, 3, 5, 6 nodes)
- Geographic edge cases (poles, antimeridian, equator)
- Failure injection tests
- Recovery verification
- Long-running stability tests

**Purpose:**
- Catch topology-specific issues
- Verify multi-node consistency
- Test failure recovery paths
- Find rare race conditions

**Failure handling:**
- Does NOT block merges
- Used for release-candidate and deep validation runs
- Failures are triaged manually from workflow output and artifacts

**Jobs:**

| Job | Description | Time |
|-----|-------------|------|
| topology-1 | Single node, all SDKs | 15 min |
| topology-3 | 3-node cluster, all SDKs | 25 min |
| topology-5 | 5-node cluster, all SDKs | 30 min |
| topology-6 | 6-node cluster, all SDKs | 35 min |
| edge-cases | Geographic boundaries | 10 min |
| failure-injection | Node failures, partitions | 20 min |
| stability | Long-running workload | 15 min |

## Tier 4: Weekly Benchmarks

**Trigger:** Manual `workflow_dispatch`

**Duration:** ~3 hours

**Scope:**
- Full benchmark suite across topologies
- Throughput benchmarks (events/sec)
- Read latency (P50, P95, P99)
- Write latency (P50, P95, P99)
- Mixed workload benchmarks
- SDK parity benchmarks

**Purpose:**
- Detect performance regressions
- Track performance trends
- Compare SDK performance
- Validate scaling behavior

**Failure handling:**
- Used when maintainers want to refresh published benchmark history
- Results are reviewed manually before promotion into long-term history
- Does not block future merges

**Performance Targets:**

| Metric | Target | Alert Threshold |
|--------|--------|-----------------|
| 3-node throughput | >=770K events/sec | -10% |
| Read latency P95 | <1ms | +20% |
| Read latency P99 | <10ms | +20% |
| Write latency P95 | <10ms | +20% |
| Write latency P99 | <50ms | +20% |

**Regression Detection:**
- Uses Welch's t-test for statistical significance
- Compares against stored baseline (JSON)
- 95% confidence level (alpha=0.05)
- Requires consistent CV <10% before comparison

**Jobs:**

| Job | Description | Time |
|-----|-------------|------|
| benchmark-1 | Single node | 30 min |
| benchmark-3 | 3-node cluster | 45 min |
| benchmark-5 | 5-node cluster | 50 min |
| benchmark-6 | 6-node cluster | 55 min |
| sdk-parity-bench | SDK comparison | 20 min |

Local benchmark outputs live under `reports/benchmarks/`, `reports/history/`, and `reports/baselines/`. Published history can be promoted into `benchmarks/history/YYYY-MM-DD.json` by the manual benchmark publication workflow.

## Hardware

| Tier | Runner | Specs |
|------|--------|-------|
| Smoke | ubuntu-latest | 2 cores, 7GB RAM |
| PR | ubuntu-latest | 2 cores, 7GB RAM |
| Nightly | ubuntu-latest-4-cores | 4 cores, 16GB RAM |
| Weekly | ubuntu-latest-8-cores | 8 cores, 32GB RAM |

## Artifacts

All tiers upload artifacts for debugging:

| Artifact | Retention | Contents |
|----------|-----------|----------|
| test-reports | 14 days | JUnit XML, pytest output |
| coverage | 14 days | Coverage HTML, lcov data |
| logs | 7 days | Server logs, stderr |
| benchmarks | 90 days | JSON results, CSV data |

## Running Locally

Simulate each tier locally:

**Smoke:**
```bash
./scripts/test-constrained.sh check
pytest tests/ -v -m smoke --timeout=60
```

**PR:**
```bash
./scripts/test-constrained.sh unit
pytest tests/ -v --timeout=300
```

**Nightly (requires cluster setup):**
```bash
export ARCHERDB_INTEGRATION=1
python -m test_infrastructure.harness.cli start --nodes=3
pytest tests/ -v -m "integration or nightly"
python -m test_infrastructure.harness.cli stop
```

**Weekly (requires cluster setup):**
```bash
python3 test_infrastructure/benchmarks/cli.py run --full-suite
```

## Workflow Files

CI workflows are defined in `.github/workflows/`:

| File | Tier |
|------|------|
| `sdk-smoke.yml` | Smoke tests |
| `sdk-pr.yml` | PR tests |
| `sdk-nightly.yml` | Nightly tests |
| `benchmark-weekly.yml` | Benchmark publication |

## Monitoring

CI health dashboard: Track test stability, flakiness, and duration trends.

Key metrics:
- Pass rate by tier (target: >99% for smoke/PR)
- Mean duration by tier
- Flaky test count (target: 0)
- Regression frequency (weekly benchmark)

## See Also

- [Testing Guide](README.md) - Local test running
- [Benchmark Guide](../benchmarks/README.md) - Performance testing details
- [Parity Matrix](../PARITY.md) - SDK verification status

---

*Last updated: 2026-02-01*
