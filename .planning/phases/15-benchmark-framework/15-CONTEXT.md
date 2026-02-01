# Phase 15: Benchmark Framework - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Building a performance benchmarking framework that measures throughput (events/sec across 1/3/5/6 node clusters) and latency (P50/P95/P99 percentiles for reads and writes) with statistical rigor. This validates that ArcherDB meets performance targets after correctness and parity are established in Phases 13-14.

Scope includes:
- Throughput benchmarking across node configurations
- Latency percentile measurement (P50/P95/P99)
- Statistical analysis with confidence intervals
- Performance target verification
- Historical result tracking
- Regression detection

</domain>

<decisions>
## Implementation Decisions

### Benchmark Execution
- **Duration control:** Both constraints — run until hitting either time limit OR operation count, whichever comes first
- **Data generation:** All four approaches:
  - Use Phase 11 generators (uniform and city-concentrated distributions)
  - Real-world datasets (actual cities, POIs for realistic patterns)
  - Synthetic patterns (adversarial: clustered, sparse, edge cases)
  - Mixed workloads (combine reads and writes in realistic ratios, e.g., 80% reads, 20% writes)
- **Warmup period:** Both warmup methods
  - Use Phase 11 iteration counts (Java 500, Node 200, Python/Go 100, C/Zig 50)
  - AND ensure metrics stabilize (time-based warmup until stable)
- **Cluster topology:** Fresh cluster per run — start clean cluster, load data, run benchmark, stop cluster (isolated measurements, no shared state)

### Statistical Rigor
- **Sample size:** Multi-level requirements:
  - Target: 10K+ samples per benchmark
  - Minimum: 1000 samples (error if fewer)
  - Duration-based collection (collect for duration, however many that yields)
- **Outlier handling:** Include all samples — no outlier removal, P99 naturally captures tail latency (production cares about worst case)
- **Confidence intervals:** Report with confidence intervals — e.g., "P95: 0.8ms ± 0.1ms (95% CI)" to show measurement reliability
- **Run variability:** Stability check — run until coefficient of variation <10% OR max 10 runs (ensures stable measurements)

### Result Reporting
- **Output formats (all four):**
  - JSON: reports/benchmarks/*.json for CI automation
  - Markdown: docs/BENCHMARKS.md for human review
  - Terminal: Color-coded tables during runs
  - CSV: exports for spreadsheet analysis
- **Result display:** All three views:
  - Absolute values (850K events/sec, P95: 0.8ms)
  - Comparison to target (850K/770K = 110% of baseline)
  - Comparison to previous (850K, +5% from previous run)
- **Real-time output:** Detailed progress — show progress bar + live metrics + sample count + elapsed time during runs
- **Organization:** Support multiple views:
  - By node count (1-node results, 3-node results, etc.)
  - By metric type (Throughput section, Latency-Read section, Latency-Write section)
  - By operation (Insert metrics, Query metrics across all configs)

### Performance Targets
- **Target verification:** Hard pass/fail — benchmark fails if any target missed (>=770K events/sec, P95 <1ms, P99 <10ms for reads, etc.) — strict enforcement
- **Variance tolerance:** Confidence-based — pass if 95% confidence interval includes target (accounts for measurement noise statistically)
- **Regression detection:** Statistical test — use t-test or similar to detect significant performance changes (not just absolute thresholds)
- **Historical tracking:** Store in git — commit benchmark results to reports/history/ for version-controlled trends and analysis

### Claude's Discretion
- Specific statistical test choice (t-test, Mann-Whitney, etc.)
- Exact coefficient of variation threshold (suggested <10%)
- Time limits and operation counts (duration/count pairs)
- Color scheme for terminal output
- CSV column ordering and formatting
- Markdown table styling

</decisions>

<specifics>
## Specific Ideas

No specific product references mentioned — open to standard benchmarking and statistical analysis approaches.

**Performance targets from ROADMAP.md:**
- 3-node throughput baseline: >=770K events/sec
- 3-node throughput stretch goal: >=1M events/sec
- Read latency: P95 <1ms, P99 <10ms
- Write latency: P95 <10ms, P99 <50ms

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 15-benchmark-framework*
*Context gathered: 2026-02-01*
