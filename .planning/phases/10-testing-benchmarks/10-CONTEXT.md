# Phase 10: Testing & Benchmarks - Context

**Gathered:** 2026-01-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Complete CI infrastructure, integration tests, and publish performance benchmarks with competitor comparisons. This phase verifies correctness at scale and produces published performance data — it does not add features.

</domain>

<decisions>
## Implementation Decisions

### Benchmark Methodology

**Workload sizes:**
- Focus on extreme scale (100M+ entities) to showcase ArcherDB's limits
- Varied result sizes from 10 to 100 million entities

**Competitor comparison approach:**
- Both default configs and tuned configs per system
- Same hardware for fair comparison, plus optimized configs for best-case scenarios

**Statistical rigor:**
- Report p50, p95, p99, p99.9 percentiles for latency
- Multiple concurrency levels: 1, 10, 100 concurrent clients
- Steady-state detection for warm-up (run until variance stabilizes)
- 30+ runs with full percentile distribution to handle variability

**Workload patterns:**
- Both separate and mixed read/write workloads (pure + 80/20, 50/50)
- All three query types equally: radius, polygon, UUID
- Both uniform random and clustered hotspot data distributions

**Configuration variants:**
- Both encrypted and unencrypted to show encryption overhead
- Both single-node and 3-node replicated cluster
- Cold and warm cache scenarios
- Single operations and batched (100, 1000, 10000)

**Storage media:**
- NVMe SSD, SATA SSD, and cloud instance storage (AWS gp3/io2)

**Memory tracking:**
- Peak RSS and time series of memory growth

### CI Test Strategy

**Test execution:**
- Full test suite on every change (never compromise)
- Full failover suite runs on every PR
- All 5 SDKs tested in main CI
- All integration tests with real external services (MinIO, etc.)

**VOPR fuzzing:**
- Long duration (2+ hours) in CI

**Coverage:**
- 90%+ coverage threshold blocks merges

**Flaky test policy:**
- Strict no retry — flaky tests are treated as broken, must fix immediately

**Platforms:**
- Linux: Ubuntu + Alpine
- macOS: Arm64 only (Apple Silicon)

**Performance regression:**
- Block CI on >5% regression
- Track and fail on significant performance drops

**Memory safety:**
- Memory leak detection (Valgrind/sanitizers) runs on every build
- Clean builds always (no caching)

**Additional CI tests:**
- Full upgrade matrix (all supported versions)
- Full backup/restore cycle (backup, corrupt, restore, verify)

**Reporting:**
- Coverage badge + detailed downloadable artifact

### Benchmark Presentation

**Publication format:**
- Both markdown docs in repo (docs/benchmarks.md) and dedicated website
- Markdown for developers, website for marketing/visibility

**Visualization:**
- Both tables (raw data) and bar charts (visual comparison)

**Reproducibility:**
- Full reproduction scripts included
- Run this → get same results transparency

**Versioning:**
- Historical comparison showing performance evolution across versions

### Hardware Recommendations

**Organization:**
- Recommendations organized by workload type (read-heavy, write-heavy, balanced)

**Specifications:**
- Generic CPU/RAM/disk specs with cloud instance examples (AWS, GCP, Azure)
- No cost estimates (prices change too frequently)
- Both minimum and recommended specs documented

**Network:**
- Detailed network requirements: latency, bandwidth, ports

**Storage:**
- General guidance ("Use NVMe SSD") without specific IOPS targets

**Memory sizing:**
- Both formula (X bytes per entity) and quick-reference tables

**Multi-region:**
- Brief mention with link to replication docs (not detailed guidance)

**Kubernetes:**
- Reference existing K8s docs in operations runbook (avoid duplication)

### Claude's Discretion
- Specific benchmark tool implementation (custom vs existing framework)
- CI workflow file structure and job organization
- Chart library choice for website visualizations
- Exact coverage tool selection for Zig

</decisions>

<specifics>
## Specific Ideas

- "Show ArcherDB's limits at extreme scale" — 100M+ entities is the target
- "Run until variance stabilizes" — no arbitrary warm-up iteration count
- "Tables for precision, charts for quick insight" — both visualization types
- "Flaky = broken" — strict test discipline
- Historical benchmark comparison across versions for performance evolution tracking

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 10-testing-benchmarks*
*Context gathered: 2026-01-23*
