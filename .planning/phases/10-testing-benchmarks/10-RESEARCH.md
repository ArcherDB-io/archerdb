# Phase 10: Testing & Benchmarks - Research

**Researched:** 2026-01-23
**Domain:** CI/CD, Integration Testing, Performance Benchmarking
**Confidence:** HIGH

## Summary

This phase focuses on completing CI infrastructure (multi-platform with VOPR fuzzing), comprehensive integration tests (geospatial operations, replication, SDKs), and publishing performance benchmarks with competitor comparisons. The codebase already has substantial testing infrastructure including VOPR fuzzer, Vortex testing framework, SDK-specific benchmarks, and a working GitHub Actions CI pipeline.

The research reveals that ArcherDB already has strong foundations: a micro-benchmarking harness (`src/testing/bench.zig`), geo-specific benchmark tooling (`geo_benchmark_load.zig`), multi-language benchmark scripts, and existing CI workflows. The main work involves extending these to meet the 90%+ coverage requirement, adding comprehensive integration tests, running VOPR for 2+ hours in CI, implementing performance regression detection, and producing publishable competitor comparisons.

**Primary recommendation:** Extend the existing CI/benchmark infrastructure rather than building from scratch. Use kcov for Zig coverage, github-action-benchmark for regression detection, and leverage the existing benchmark drivers for competitor comparisons.

## Standard Stack

The established libraries/tools for this domain:

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| kcov | 42+ | Zig code coverage | Works without compile-time instrumentation, supports Zig `unreachable` exclusion |
| GitHub Actions | N/A | CI/CD platform | Already in use, matrix strategy for multi-platform |
| github-action-benchmark | v1 | Performance regression | Tracks historical benchmarks, alerts on regression |
| Codecov | v5 | Coverage reporting | Badge generation, PR comments, threshold blocking |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Valgrind | 3.21+ | Memory leak detection | Linux-only memory safety |
| hyperfine | 1.18+ | CLI benchmarking | External benchmark validation |
| matplotlib/Chart.js | Latest | Benchmark visualization | Website charts for benchmark results |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| kcov | llvm-cov | Requires compile-time instrumentation, more complex with Zig |
| Codecov | Coveralls | Both work, Codecov has better parallel support |
| github-action-benchmark | Bencher | Bencher more sophisticated but adds external dependency |

**Installation:**
```bash
# Ubuntu CI
apt-get install -y kcov valgrind

# macOS CI (no kcov/valgrind, use sanitizers)
# Zig sanitizers work on macOS
```

## Architecture Patterns

### Recommended CI Structure

```
.github/
  workflows/
    ci.yml              # Main CI (existing, extend)
    benchmark.yml       # Nightly benchmarks
    coverage.yml        # Coverage report generation
  ci/
    test_aof.sh         # Integration test scripts
    run_vopr.sh         # VOPR runner with timeout
    run_sdk_tests.sh    # Multi-SDK test orchestration
```

### Pattern 1: Matrix Strategy for Multi-Platform

**What:** GitHub Actions matrix for parallel platform testing
**When to use:** Testing across Linux (Ubuntu + Alpine) and macOS ARM64
**Example:**
```yaml
# Source: GitHub Actions documentation
strategy:
  fail-fast: false
  matrix:
    include:
      - { os: ubuntu-latest, name: 'Linux x64' }
      - { os: ubuntu-latest, container: 'alpine:latest', name: 'Linux Alpine' }
      - { os: macos-latest, name: 'macOS ARM64' }
```

### Pattern 2: Benchmark Regression Detection

**What:** Store benchmark results in gh-pages, compare on PR
**When to use:** Blocking merges on >5% performance regression
**Example:**
```yaml
# Source: github-action-benchmark documentation
- uses: benchmark-action/github-action-benchmark@v1
  with:
    tool: 'customSmallerIsBetter'
    output-file-path: benchmark-results.json
    github-token: ${{ secrets.GITHUB_TOKEN }}
    auto-push: true
    alert-threshold: '105%'  # 5% regression
    comment-on-alert: true
    fail-on-alert: true
```

### Pattern 3: Coverage Threshold Blocking

**What:** Fail CI when coverage drops below threshold
**When to use:** Enforcing 90%+ coverage requirement
**Example:**
```yaml
# Source: Codecov documentation
- uses: codecov/codecov-action@v5
  with:
    files: ./coverage.xml
    fail_ci_if_error: true
    threshold: 90
```

### Anti-Patterns to Avoid

- **Retry flaky tests:** Treats symptoms not causes. Per CONTEXT.md: "flaky = broken"
- **Cache test results between runs:** Can mask actual failures. Per CONTEXT.md: "clean builds always"
- **Arbitrary warm-up iteration counts:** Run until variance stabilizes instead
- **Single-run benchmarks:** Need 30+ runs for statistical significance

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Coverage collection | Custom instrumentation | kcov | Works with Zig binaries, no compile changes |
| Benchmark visualization | Custom charts | github-action-benchmark | Handles historical tracking, alerts |
| Percentile calculation | Manual sorting | HdrHistogram patterns | Handles outliers, memory-efficient |
| Multi-platform CI | Separate workflows | Matrix strategy | DRY, parallel execution |
| Performance alerts | Custom comparison | github-action-benchmark | Handles baseline management |

**Key insight:** The existing `src/testing/bench.zig` harness is well-designed. Extend it for the benchmark suite rather than replacing it. The benchmark tooling already handles smoke/benchmark mode switching.

## Common Pitfalls

### Pitfall 1: Cold Start Variance

**What goes wrong:** First benchmark run is significantly slower due to caching
**Why it happens:** Database and OS-level caching affects performance
**How to avoid:**
- Run warmup iterations until variance stabilizes (not fixed count)
- Discard first N measurements
- Report both cold and warm cache numbers separately
**Warning signs:** High variance in early iterations, p99 >> p50

### Pitfall 2: Benchmarking Non-Production Builds

**What goes wrong:** Debug builds show 10x worse performance
**Why it happens:** Assertions, lack of optimization
**How to avoid:**
- Always use `-Drelease` for benchmarks (existing code warns about this)
- Verify direct IO is enabled
- Check for extra assertions in production
**Warning signs:** Unrealistic throughput numbers, high memory usage

### Pitfall 3: Misleading Competitor Comparisons

**What goes wrong:** Comparing tuned ArcherDB vs default competitor configs
**Why it happens:** Each database has different defaults
**How to avoid:**
- Per CONTEXT.md: "Both default configs and tuned configs per system"
- Document exact configuration for each test
- Provide reproduction scripts
**Warning signs:** Orders of magnitude differences, reviewers unable to reproduce

### Pitfall 4: Coverage Measurement Overhead

**What goes wrong:** kcov slows tests dramatically, causing timeouts
**Why it happens:** Coverage instrumentation adds runtime overhead
**How to avoid:**
- Run coverage separately from main test suite
- Use sampling for very large test suites
- Don't include coverage in performance-sensitive CI paths
**Warning signs:** CI timeouts only when coverage enabled

### Pitfall 5: Platform-Specific Test Failures

**What goes wrong:** Tests pass on Linux, fail on macOS (or vice versa)
**Why it happens:** Filesystem timing, network behavior differences
**How to avoid:**
- Run full suite on all target platforms
- Use platform-specific timeouts where needed
- Document known platform differences
**Warning signs:** Intermittent failures only on specific platforms

## Code Examples

Verified patterns from the existing codebase:

### Micro-Benchmark with Harness (Existing Pattern)

```zig
// Source: src/testing/bench.zig
test "benchmark: API tutorial" {
    var bench: Bench = .init();
    defer bench.deinit();

    const a = bench.parameter("a", 1, 1_000);     // Smoke: 1, Real: 1000
    const b = bench.parameter("b", 2, 2_000);     // Smoke: 2, Real: 2000

    bench.start();
    const c = a + b;
    const elapsed = bench.stop();

    bench.report("hash: {}", .{c});               // Prevents optimization
    bench.report("elapsed: {}", .{elapsed});
}
```

### Latency Histogram Pattern (Existing)

```zig
// Source: src/archerdb/geo_benchmark_load.zig
// Latency histogram (1ms buckets, 0-10000ms)
const request_latency_histogram = try allocator.alloc(u64, 10_001);
@memset(request_latency_histogram, 0);
defer allocator.free(request_latency_histogram);
```

### GitHub Actions Coverage with kcov

```yaml
# Pattern: Run kcov on test binary
- name: Run tests with coverage
  run: |
    kcov --exclude-line=//ignore:cover \
         --exclude-pattern=/zig/lib/ \
         ./coverage-output \
         ./zig-out/bin/test-unit

- name: Upload coverage
  uses: codecov/codecov-action@v5
  with:
    directory: ./coverage-output
```

### Python SDK Benchmark Pattern (Existing)

```python
# Source: src/clients/python/benchmark.py
def benchmark_insert(self) -> BenchmarkResult:
    """Benchmark insert throughput."""
    latencies_us = []
    errors = 0
    start_time = time.perf_counter()

    for i in range(0, self.test_events, self.batch_size):
        batch_start = time.perf_counter()
        try:
            batch = self.client.create_batch()
            for _ in range(min(self.batch_size, self.test_events - i)):
                batch.add(self.generate_random_event())
            results = batch.commit()
        except Exception as e:
            errors += self.batch_size
            continue

        batch_latency_us = (batch_end - batch_start) * 1_000_000
        latencies_us.append(batch_latency_us)
```

### VOPR Long-Running CI Pattern

```yaml
# Pattern: VOPR with timeout and artifact upload
- name: Run VOPR (2h)
  timeout-minutes: 150
  run: |
    ./zig/zig build vopr \
      -Dvopr-state-machine=geo \
      -Drelease \
      -- ${{ github.sha }} \
      --ticks-max-requests=100000000

- name: Upload VOPR logs on failure
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: vopr-logs
    path: vopr-*.log
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Simple test pass/fail | Coverage thresholds block merge | 2024+ | Quality enforcement |
| Manual benchmark comparison | Automated regression detection | 2023+ | Prevents regressions |
| Single platform CI | Matrix multi-platform | 2022+ | Catches platform bugs |
| Fixed warm-up counts | Variance-stabilization | 2025 | More accurate results |

**Deprecated/outdated:**
- Travis CI: Migrated to GitHub Actions
- Coveralls without parallel: Use parallel mode for matrix builds
- Manual percentile calculation: Use histogram-based approaches

## Benchmark Methodology Notes

Per CONTEXT.md decisions, the benchmark suite must:

### Statistical Rigor
- Report p50, p95, p99, p99.9 percentiles
- Multiple concurrency levels: 1, 10, 100 concurrent clients
- 30+ runs with full percentile distribution
- Variance-based warm-up detection

### Configuration Variants
- Both encrypted and unencrypted
- Single-node and 3-node replicated cluster
- Cold and warm cache scenarios
- Batch sizes: single, 100, 1000, 10000

### Competitor Systems
- PostGIS (geospatial queries)
- Redis/Tile38 (latency)
- Elasticsearch Geo (throughput)
- Aerospike (write performance)

Each competitor should be tested with:
- Default configuration
- Tuned configuration (best-case for competitor)
- Same hardware for fair comparison

### Reproduction
- Full reproduction scripts in repository
- Environment documented (OS, hardware, versions)
- Docker/container setup for portability

## Open Questions

Things that couldn't be fully resolved:

1. **kcov + Alpine Linux**
   - What we know: kcov works on Ubuntu/Debian
   - What's unclear: Alpine musl compatibility may have issues
   - Recommendation: Test kcov on Alpine early; may need glibc container for coverage

2. **macOS Coverage**
   - What we know: kcov has limited macOS support, Valgrind doesn't work on ARM64 macOS
   - What's unclear: Best coverage approach for macOS
   - Recommendation: Skip coverage on macOS, rely on Linux coverage; use address sanitizer on macOS

3. **VOPR Duration in CI**
   - What we know: 2+ hours is specified
   - What's unclear: GitHub Actions free tier has 6-hour job limit
   - Recommendation: Use self-hosted runners or split VOPR across multiple jobs

4. **Competitor Benchmark Licensing**
   - What we know: PostGIS (GPLv2), Elasticsearch (Elastic License 2.0), Aerospike (AGPL)
   - What's unclear: Whether running benchmarks requires specific license compliance
   - Recommendation: Verify license terms before publishing comparison results

## Sources

### Primary (HIGH confidence)
- Existing codebase: `build.zig`, `src/testing/bench.zig`, `src/vopr.zig`
- Existing CI: `.github/workflows/ci.yml`
- Existing benchmarks: `src/archerdb/geo_benchmark_load.zig`, `src/clients/python/benchmark.py`

### Secondary (MEDIUM confidence)
- [github-action-benchmark](https://github.com/benchmark-action/github-action-benchmark) - Regression detection
- [Codecov Action](https://github.com/codecov/codecov-action) - Coverage upload
- [Aerospike Best Practices](https://aerospike.com/blog/best-practices-for-database-benchmarking/) - Benchmark methodology
- [PostGIS Performance Tips](https://postgis.net/docs/performance_tips.html) - Competitor benchmarking
- [kcov for Zig](https://zig.news/liyu1981/tiny-change-to-kcov-for-better-covering-zig-hjm) - Coverage tooling

### Tertiary (LOW confidence)
- [Elasticsearch Benchmarks](https://elasticsearch-benchmarks.elastic.co/) - General approach reference
- [Tile38 Benchmark Tool](https://github.com/tidwall/tile38/tree/master/cmd/tile38-benchmark) - Competitor tooling

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - kcov/codecov well-documented, GitHub Actions familiar
- Architecture: HIGH - Patterns come from existing codebase
- Benchmark methodology: HIGH - CONTEXT.md provides specific decisions
- Competitor benchmarking: MEDIUM - Need to verify competitor setups work as expected
- Coverage tooling: MEDIUM - kcov + Zig needs validation in CI environment

**Research date:** 2026-01-23
**Valid until:** 2026-02-23 (30 days - stable domain)
