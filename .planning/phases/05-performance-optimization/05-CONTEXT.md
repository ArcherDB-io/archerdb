# Phase 5: Performance Optimization - Context

**Gathered:** 2026-01-30
**Status:** Ready for planning

<domain>
## Phase Boundary

Achieve throughput and latency targets for production workloads. Profile bottlenecks, optimize write and read paths, and validate sustained performance under load. This phase covers measurement, optimization, and validation — not feature changes or API additions.

</domain>

<decisions>
## Implementation Decisions

### Benchmarking Workloads
- Primary workload pattern: write-heavy (90%+ writes) — IoT sensors, telemetry, event streaming
- Target data size: large (10-100GB) — production-scale, tests durability under sustained load
- Data patterns: both synthetic uniform (for baselines) and realistic clustered (city-like distributions for validation)
- Query types to benchmark: all types — point queries, radius queries, and bounding box queries

### Target Priorities
- Balance throughput and latency — meet minimum thresholds for both, don't over-optimize either
- Write target: 1M events/sec/node (final target, not interim 100K)
- Scale metrics: report both single-node and cluster-wide (3-node) throughput, single-node as baseline
- Spatial query P99: different limits for different query types (radius vs bounding box — document actual)

### Optimization Boundaries
- Breaking API changes allowed if justified by performance gains
- On-disk format is flexible — no production data yet, format can change freely
- Memory budget: start with lite config (~130MB) on dev server, then test full production config (7GB+)
- External dependencies: any deps OK — whatever improves performance, no restrictions

### Validation Criteria
- Sustained load test duration: 24 hours (matches roadmap requirement)
- Validation environment: dev server only (24GB RAM, 8 cores) — targets scaled accordingly
- Reporting: detailed metrics — full breakdown of throughput, latency percentiles, resource usage
- No degradation definition: flat line — throughput must stay constant within 5% over 24 hours

### Claude's Discretion
- Profiling tools and methodology
- Specific optimization techniques (batching, caching, async I/O approaches)
- Order of optimizations (write path vs read path first)
- Benchmark harness implementation details

</decisions>

<specifics>
## Specific Ideas

- Write-heavy workload reflects real customer use case (IoT/telemetry ingestion)
- 1M events/sec is the ambitious target — interim milestones acceptable during development
- Spatial query latency targets can vary by query type (radius may be slower than point)
- Start development on constrained dev server, production validation can come later

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 05-performance-optimization*
*Context gathered: 2026-01-30*
