# Phase 11: Measurement & Profiling Infrastructure - Context

**Gathered:** 2026-01-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish comprehensive profiling infrastructure so all subsequent optimization work is data-driven. This includes CPU profiling, memory tracking, latency histograms, benchmark harnesses, and CI integration. The tools built here feed all v2.0 optimization phases.

</domain>

<decisions>
## Implementation Decisions

### Output & Reporting
- Both JSON and human-readable output: `--json` flag for machines, default to human-readable
- Detailed output by default, full breakdown always shown (can trim with flags if needed)
- Include both raw data AND basic guidance (flag obvious issues like "P99 > 10x P50 — high tail latency")
- Configurable output destination: `--output` flag for file, stdout if not specified

### Integration Points
- Separate profile build mode: `zig build profile` or `zig build -Dprofiling=true`
- Export to both Prometheus (live monitoring via /metrics endpoint) and perf-compatible formats (deep analysis)
- Helper script for flame graphs: `scripts/flamegraph.sh` wraps perf with sensible defaults

### Metric Granularity
- Fine-grained operation tracking: point read, range scan, insert, update, delete, spatial query, etc.
- Extended percentile set: P50, P75, P90, P95, P99, P99.9, P99.99, max
- Full call stack tracking for memory allocations (leak detection and optimization)
- Full statistical analysis: confidence intervals, outlier detection, significance testing

### Developer Workflow
- Full CI integration: every PR shows perf comparison vs main branch
- Auto-generated baselines: CI generates baseline from main branch on merge
- Statistical regression detection: regression must exceed noise floor (2+ stddev from baseline)
- Both quick and full benchmark modes: `zig build bench-quick` for iteration (<30s), full suite for verification, documented workflow

### Claude's Discretion
- POOP (A/B benchmarking) invocation approach — user deferred this decision
- Exact Prometheus metric naming conventions
- Specific benchmark workload selection for quick mode

</decisions>

<specifics>
## Specific Ideas

- Flame graph workflow should feel familiar to developers who use Linux perf
- Statistical significance testing should prevent noisy false-positive regression alerts
- Quick benchmark mode enables fast iteration without sacrificing verification rigor

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 11-measurement-profiling*
*Context gathered: 2026-01-24*
