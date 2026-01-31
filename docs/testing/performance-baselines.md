# Performance Baseline Management

This document describes how ArcherDB manages performance baselines for regression detection
in CI.

## Overview

Performance baselines are locked reference points that CI uses to detect regressions.
Each PR's benchmark results are compared against the current main branch baseline.
Regressions block merge to prevent shipping slow code.

## Regression Thresholds

The following thresholds are used to detect performance regressions:

| Metric | Threshold | Rationale |
|--------|-----------|-----------|
| Throughput | 5% | Matches observed 5% coefficient of variation (CV) in benchmarks |
| Latency P99 | 25% | Accounts for higher variance in tail latencies |

**Throughput**: If current mean execution time is >5% slower than baseline, the check fails.
- Formula: `current_mean > baseline_mean * 1.05`
- Example: Baseline 1000ns, current 1060ns = 6% slower = FAIL

**Latency P99**: If current P99 latency is >25% higher than baseline, the check fails.
- Formula: `current_p99 > baseline_p99 * 1.25`
- Example: Baseline P99 1200ns, current P99 1400ns = 16.7% higher = PASS
- Example: Baseline P99 1200ns, current P99 1600ns = 33.3% higher = FAIL

## Baseline Lifecycle

```
main branch push
       |
       v
+------------------+
| Run benchmarks   |
| (full mode)      |
+------------------+
       |
       v
+------------------+
| Upload as        |
| benchmark-       |
| baseline         |
+------------------+
       |
       v
  (90 day retention)
```

```
PR created/updated
       |
       v
+------------------+
| Download         |
| baseline from    |
| main             |
+------------------+
       |
       v
+------------------+
| Run benchmarks   |
| (quick mode)     |
+------------------+
       |
       v
+------------------+
| Compare against  |
| baseline         |
+------------------+
       |
    +--+--+
    |     |
 PASS   FAIL
    |     |
    v     v
 Merge  Block
 OK     merge
```

### Timeline

1. **Main branch pushes** upload new baseline artifact (full benchmark mode)
2. **PRs** download the current main baseline and run quick benchmarks
3. **Comparison** checks both throughput and P99 latency against thresholds
4. **Regressions** block merge until fixed or baseline is reset

## Resetting the Baseline

Sometimes you need to reset the baseline after intentional performance changes:

### When to Reset

- **Intentional trade-off**: You accepted slower writes for better consistency
- **New feature overhead**: Added necessary functionality that increases latency
- **Algorithm change**: Changed from O(n) to O(log n) with different constants

### How to Reset

1. **Delete the current baseline artifact**:
   - Go to GitHub Actions > Select a recent main workflow run
   - Find "benchmark-baseline" artifact and delete it
   - Or use GitHub CLI: `gh api -X DELETE /repos/{owner}/{repo}/actions/artifacts/{artifact_id}`

2. **Merge your PR** (no comparison runs without baseline)

3. **New baseline created** on next main push

### Alternative: Update Baseline Manually

If you don't want to delete the artifact:

1. Merge to main (workflow runs)
2. New baseline automatically uploaded
3. Future PRs compare against new baseline

## Troubleshooting

### False Positives

**Symptom**: Benchmark fails but code hasn't changed performance.

**Possible causes**:
- **Stale baseline**: If baseline is very old, machine differences may cause variance
- **CI runner variance**: GitHub Actions runners can have different performance
- **Background load**: Other jobs running on same machine

**Resolution**:
- Re-run the benchmark job
- If consistent, reset the baseline

### Consistent Failures

**Symptom**: Multiple re-runs show same regression.

**This likely indicates a real regression**:
1. Review recent commits for performance-impacting changes
2. Profile locally to identify hot paths
3. Fix the performance issue
4. If intentional, reset the baseline and document why

### No Baseline Available

**Symptom**: "Download baseline" step shows "Artifact not found".

**This is normal for**:
- First run after repository setup
- After baseline was manually deleted
- Baseline artifact expired (90 day retention)

**Resolution**: Merge to main to create new baseline.

### jq/bc Not Available

**Symptom**: "jq not installed" warning in comparison output.

**Resolution**: The workflow installs these dependencies. If you're running
locally, install them:

```bash
# Ubuntu/Debian
sudo apt-get install jq bc

# macOS
brew install jq bc
```

## Configuration

### Modifying Thresholds

Thresholds are defined in `scripts/benchmark-ci.sh`:

```bash
# Throughput: 5% threshold
throughput_threshold=$(echo "scale=0; $baseline_mean * 1.05 / 1" | bc)

# Latency P99: 25% threshold
latency_threshold=$(echo "scale=0; $baseline_p99 * 1.25 / 1" | bc)
```

To change thresholds:
1. Edit the multipliers in `benchmark-ci.sh`
2. Update this documentation
3. Update workflow header comments

### Benchmark Modes

| Mode | Duration | Use Case |
|------|----------|----------|
| quick | ~30 seconds | PRs (fast feedback) |
| full | ~5 minutes | Main branch (accurate baseline) |

## Related Files

- `.github/workflows/benchmark.yml` - CI workflow
- `scripts/benchmark-ci.sh` - Benchmark runner and comparison logic
- `.planning/phases/09-testing-infrastructure/09-CONTEXT.md` - Threshold decisions

## References

- [CONTEXT.md decisions](../../.planning/phases/09-testing-infrastructure/09-CONTEXT.md) - Why these thresholds were chosen
- [STATE.md](../../.planning/STATE.md) - Observed 5% CV in benchmarks
