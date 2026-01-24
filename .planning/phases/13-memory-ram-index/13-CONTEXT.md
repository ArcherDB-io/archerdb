# Phase 13: Memory & RAM Index - Context

**Gathered:** 2026-01-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Optimize RAM index for extreme performance at 100M+ entity scale. User prioritizes raw speed over memory savings — willing to provision more hardware rather than accept latency variance from tiering.

**Key shift from original requirements:** The "50% memory reduction" goal is secondary to performance. Keep 64B entries if they're faster. No mmap tiering — all data stays in RAM.

</domain>

<decisions>
## Implementation Decisions

### Index Entry Format
- Keep 64B entries for performance (no compression to 32B)
- Pad entries to exactly 64 bytes (one cache line per entry)
- No false sharing, predictable prefetch patterns
- Store all fields needed for fast lookups — avoid derivation overhead

### Hash Table Design
- Use cuckoo hashing for guaranteed O(1) lookups
- Two hash functions with deterministic probe sequence
- In-place updates (not delete+reinsert) for lower write amplification

### Memory Model
- **No mmap tiering** — all index data stays in RAM
- Provide upfront RAM estimate before index creation
- Fail with clear error if estimated RAM exceeds available memory
- No OOM surprises — fail fast with explicit requirements

### SIMD Acceleration
- Vectorize both hash computation and key comparison
- Runtime detection of SIMD capabilities at startup
- Pick best path: AVX-512, AVX2, or scalar fallback
- Auto-tune batch size based on hardware probing at startup

### Memory Metrics
- Full granularity: total, per-index, and per-component breakdown
- Periodic sampling (balance accuracy vs overhead)
- Expose via Prometheus for monitoring and alerting

### Claude's Discretion
- Specific SIMD instruction set selection based on benchmarks
- Optimal batch sizes for vectorized operations
- Whether to include allocation rate metrics (allocs/sec)
- Whether to include alert rules (following Phase 12 patterns)
- Scalar fallback implementation details

</decisions>

<specifics>
## Specific Ideas

- "I need extreme performance, any decision should come from that"
- "I'd prefer performance guarantees no matter what, I'm ready to provide more hardware necessary"
- Cuckoo hashing specifically requested for O(1) guarantee
- Cache-line alignment (64B padding) specifically requested

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 13-memory-ram-index*
*Context gathered: 2026-01-24*
