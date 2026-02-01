# Phase 17: Edge Cases & Advanced Benchmarking - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Validate system behavior at geographic and scale boundaries, then establish automated performance tracking with regression detection and historical trend visualization.

Scope: Edge case testing (geometric boundaries, scale limits) + performance regression detection + historical tracking dashboard. New features or capabilities belong in other phases.

</domain>

<decisions>
## Implementation Decisions

### Edge Case Test Coverage
- **Geometric coverage:** Comprehensive patterns - exact boundaries (±90°, ±180°), near-boundaries (89.9999°, 179.9999°), multiple concave shapes, self-intersecting polygons, degenerate cases (zero-area, single-point)
- **Scale validation:** Both correctness AND performance - verify data integrity (all inserts succeed, queries correct) AND measure throughput/latency at scale
- **Adversarial patterns:** Both existing + new - leverage geo_workload.zig patterns as baseline, add test-specific variants for edge case validation
- **Topology coverage:** All topologies (1/3/5/6 nodes) - verify edge cases work across all cluster sizes

### Regression Detection Criteria
- **Regression trigger:** Both statistical + absolute thresholds - use statistical (2 std dev) for normal variance, absolute percentage (10%) for major drops
- **Baseline selection:** Best historical performance - compare to peak, alert on any degradation from best-ever
- **Regression severity:** Fail CI on regression - block merges when performance degrades (strict quality gate)
- **Monitored metrics:** Both throughput + latency - comprehensive coverage catches different regression types

### Historical Data Management
- **Storage format:** JSON files (one per run) - simple, human-readable, git-friendly
- **Data retention:** Keep all history forever - complete historical record (never delete)
- **Storage location:** In repo (benchmarks/history/) - version controlled, always available
- **Metadata tracking:** Full context - git SHA, branch, timestamp, hardware info, config for complete reproducibility

### Performance Visualization
- **Dashboard format:** Multiple formats - CLI charts for quick checks, HTML reports for detailed analysis
- **Chart types:** Full statistical view - trends, distributions, percentile bands, histograms, box plots
- **Auto-generation:** Always generate - every benchmark run creates updated dashboard
- **Time range:** All history by default - complete record with option to filter

### Claude's Discretion
- Specific near-boundary values (89.9999° vs 89.99999°)
- Statistical confidence level for regression detection (95% vs 99%)
- CLI chart library choice (e.g., asciichartpy, plotext)
- HTML charting library (e.g., Chart.js, Plotly)
- Exact degenerate test cases beyond zero-area and single-point

</decisions>

<specifics>
## Specific Ideas

- Edge cases should build on Phase 14's edge case fixtures (33 test cases for polar/antimeridian/equator)
- Regression detection extends Phase 15's benchmark framework with historical comparison
- Use existing benchmark infrastructure from Phase 15 (config, executor, stats, reporter)
- geo_workload.zig already exists in codebase - leverage proven adversarial patterns

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 17-edge-cases-and-advanced-benchmarking*
*Context gathered: 2026-02-01*
