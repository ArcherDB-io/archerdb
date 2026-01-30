# Phase 5: Performance Optimization - Research

**Researched:** 2026-01-30
**Domain:** Performance benchmarking, profiling, write/read path optimization, sustained load testing
**Confidence:** HIGH

## Summary

This phase focuses on achieving production-grade performance targets for ArcherDB. The codebase already contains substantial performance infrastructure including a comprehensive benchmark suite (`src/archerdb/geo_benchmark_load.zig`), profiling support (Tracy, perf, Parca), and hardware-tier configurations (enterprise/mid-tier/lite). The key insight is that the benchmarking and profiling tools exist - this phase focuses on systematic bottleneck identification, targeted optimization, and sustained load validation.

The existing infrastructure includes:
- **Benchmark suite** (`benchmark_driver.zig`, `geo_benchmark_load.zig`): Measures F5.1.1 (write throughput), F5.1.2 (UUID latency), F5.1.3 (radius query), F5.1.4 (polygon query)
- **Profiling tools** (`docs/profiling.md`): perf flame graphs, Tracy real-time instrumentation, Parca continuous profiling
- **Hardware configurations** (`src/config.zig`): Enterprise (1M+ writes/sec), mid-tier (500k+ writes/sec), lite (~130MB RAM)
- **LSM compaction strategies** (`src/lsm/compaction_tiered.zig`): Tiered compaction with 2-3x lower write amplification for write-heavy workloads
- **Metrics infrastructure** (`src/archerdb/metrics.zig`): Prometheus-compatible counters, gauges, and histograms with P99/P999 tracking

**Primary recommendation:** Start with baseline profiling using the existing benchmark suite at different scales, identify the top 3-5 bottlenecks via flame graphs, implement targeted optimizations, and validate with a 24-hour sustained load test. The dev server constraints (24GB RAM, 8 cores) require scaled targets but the methodology remains the same.

## Standard Stack

The established infrastructure for performance optimization:

### Core Benchmarking Infrastructure
| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| Geo Benchmark | `src/archerdb/geo_benchmark_load.zig` | Write throughput, query latency measurement | Purpose-built for geospatial workloads |
| Benchmark Driver | `src/archerdb/benchmark_driver.zig` | Orchestrates benchmark runs with temp cluster | Standard pattern from TigerBeetle |
| Perf Benchmarks Script | `scripts/run-perf-benchmarks.sh` | Quick/full/extreme benchmark modes | Reproducible multi-configuration testing |
| CLI Benchmark Command | `./archerdb benchmark` | User-facing benchmark entry point | Integrated measurement interface |

### Profiling Infrastructure
| Component | Location | Purpose | When to Use |
|-----------|----------|---------|-------------|
| Flame Graphs | `scripts/flamegraph.sh` | CPU profiling visualization | Finding hot functions |
| perf Profile | `scripts/profile.sh` | Hardware counter analysis | IPC, cache misses, branch mispredictions |
| Tracy Zones | `src/testing/tracy_zones.zig` | Real-time instrumentation | Live profiling during development |
| Parca Agent | `scripts/parca-agent.sh` | Continuous profiling | Production monitoring |

### Configuration Infrastructure
| Component | Location | Purpose | When to Use |
|-----------|----------|---------|-------------|
| Enterprise Config | `src/config.zig:configs.enterprise` | High-performance hardware (NVMe, 16+ cores) | Production benchmarking |
| Mid-tier Config | `src/config.zig:configs.mid_tier` | Moderate hardware (SATA SSD, 8 cores) | Standard deployments |
| Lite Config | `src/config.zig:configs.lite` | Minimal footprint (~130MB) | Development, testing |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Built-in benchmarks | YCSB, HammerDB | Built-in is purpose-designed for geospatial; external tools need adapters |
| perf flame graphs | Intel VTune, AMD uProf | perf is free, cross-vendor; proprietary tools have deeper HW insight |
| Tracy zones | Manual timing | Tracy has near-zero overhead when disabled; manual is error-prone |
| Linux io_uring | epoll | io_uring already in use (`src/io/linux.zig`); best for high-throughput I/O |

**Build Commands:**
```bash
# Run quick benchmark (default lite config)
./zig/zig build -Drelease && ./zig-out/bin/archerdb benchmark --event-count 10000

# Run with specific config
./zig/zig build -Drelease -Dconfig=production && ./zig-out/bin/archerdb benchmark

# Generate flame graph
./scripts/flamegraph.sh --output profile.svg -- ./zig-out/bin/archerdb benchmark

# Hardware counter profiling
./scripts/profile.sh -- ./zig-out/bin/archerdb benchmark

# Build with Tracy instrumentation
./zig/zig build profile -Dtracy=true

# Run extended benchmark suite
./scripts/run-perf-benchmarks.sh --full
```

## Architecture Patterns

### Existing Performance Structure
```
src/
├── archerdb/
│   ├── benchmark_driver.zig   # Orchestration and cluster management
│   ├── benchmark_load.zig     # Forwards to geo_benchmark_load
│   ├── geo_benchmark_load.zig # Core benchmark implementation (F5.1.1-F5.1.4)
│   ├── metrics.zig            # Prometheus metrics (Counter, Gauge, Histogram)
│   ├── metrics_server.zig     # HTTP /metrics endpoint
│   ├── query_metrics.zig      # Query latency breakdown
│   ├── storage_metrics.zig    # Write/space amplification
│   ├── index_metrics.zig      # RAM index statistics
│   └── cluster_metrics.zig    # Cluster-wide metrics
├── config.zig                 # Hardware tier configurations
├── io/
│   ├── linux.zig              # io_uring implementation
│   └── darwin.zig             # kqueue implementation (macOS)
├── lsm/
│   ├── compaction.zig         # Core compaction logic
│   ├── compaction_tiered.zig  # Tiered compaction strategy
│   ├── compaction_throttle.zig# Latency-driven throttling
│   ├── compaction_adaptive.zig# Workload-adaptive tuning
│   └── compression.zig        # LZ4 block compression
├── testing/
│   └── tracy_zones.zig        # Tracy profiling helpers
└── trace/
    └── statsd.zig             # StatsD metrics export
```

### Pattern 1: Benchmark-Driven Development
**What:** Make performance changes guided by measurable benchmark results
**When to use:** All optimization work - never optimize without measurements
**Example:**
```bash
# Source: scripts/run-perf-benchmarks.sh

# 1. Establish baseline
./scripts/profile.sh --json -- ./zig-out/bin/archerdb benchmark > baseline.json
./scripts/flamegraph.sh --output baseline.svg -- ./zig-out/bin/archerdb benchmark

# 2. Make optimization

# 3. Measure impact
./scripts/profile.sh --json -- ./zig-out/bin/archerdb benchmark > optimized.json
./scripts/flamegraph.sh --output optimized.svg -- ./zig-out/bin/archerdb benchmark

# 4. Compare
diff baseline.json optimized.json
```

### Pattern 2: Tiered Configuration Testing
**What:** Test each hardware tier configuration separately
**When to use:** Validating optimizations work across hardware profiles
**Example:**
```zig
// Source: src/config.zig:484-686

// Build for different hardware tiers:
// - Lite: ./zig/zig build -Dconfig=lite
// - Mid-tier: custom config in build.zig with mid_tier values
// - Enterprise: ./zig/zig build -Dconfig=production
// - Production: ./zig/zig build (default)

// Key tuning parameters per tier:
// - lsm_levels: 6-7 (more levels = larger capacity, higher read amp)
// - lsm_growth_factor: 4-10 (higher = lower write amp, higher read amp)
// - lsm_compaction_ops: 4-64 (memtable size, affects flush frequency)
// - block_size: 32KB-512KB (larger = better seq I/O, higher space amp)
// - grid_iops_read_max/write_max: I/O concurrency limits
```

### Pattern 3: Histogram-Based Latency Tracking
**What:** Track latency distributions with percentile calculation
**When to use:** Measuring P99, P999, P9999 latency for SLA validation
**Example:**
```zig
// Source: src/archerdb/metrics.zig:174-265

pub fn HistogramType(comptime bucket_count: usize) type {
    return struct {
        buckets: [bucket_count]std.atomic.Value(u64),
        bucket_bounds: [bucket_count]f64,
        sum: std.atomic.Value(u64),
        count: std.atomic.Value(u64),

        // Observe a duration in nanoseconds
        pub fn observeNs(self: *@This(), value_ns: u64) void {
            _ = self.count.fetchAdd(1, .monotonic);
            _ = self.sum.fetchAdd(value_ns, .monotonic);
            // Find appropriate bucket...
        }

        // Get extended statistics
        pub fn getExtendedStats(self: *const @This()) ExtendedStats {
            return .{
                .p50 = self.getPercentile(0.50),
                .p99 = self.getPercentile(0.99),
                .p999 = self.getPercentile(0.999),
                .p9999 = self.getPercentile(0.9999),
                // ...
            };
        }
    };
}
```

### Pattern 4: Compaction Throttling for Latency Control
**What:** Reduce compaction throughput when query latency exceeds threshold
**When to use:** Preventing compaction from causing latency spikes
**Example:**
```zig
// Source: src/config.zig:180-233 (ConfigProcess compaction settings)

// Predictive throttling: monitor pending compaction bytes
compaction_soft_pending_gib: u32 = 64,   // Start throttling at 64 GiB pending
compaction_hard_pending_gib: u32 = 256,  // Aggressive throttling at 256 GiB

// Reactive throttling: monitor P99 latency
compaction_p99_threshold_ms: u32 = 50,   // Start throttling when P99 > 50ms
compaction_p99_critical_ms: u32 = 100,   // Emergency throttle when P99 > 100ms
compaction_min_throughput_permille: u32 = 100,  // Never below 10% throughput
```

### Anti-Patterns to Avoid
- **Premature optimization:** Never optimize without flame graph evidence showing the function is a hot path (>10% CPU time)
- **Debug builds for benchmarking:** Always use `-Drelease` flag; debug builds are 10-100x slower
- **Cold cache measurements:** Always include warmup runs before timing measurements
- **Single-run measurements:** Run multiple iterations and report statistical distribution, not single values
- **Optimizing wall-clock instead of CPU:** Profile CPU time, not elapsed time (which includes I/O waits)

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Latency histograms | Custom percentile math | `metrics.HistogramType` | Atomic, bucket interpolation, Prometheus format |
| Flame graph generation | Custom perf parsing | `scripts/flamegraph.sh` | FlameGraph scripts, proper stack folding |
| I/O completion tracking | Custom io_uring wrapper | `src/io/linux.zig` | Already optimized, handles edge cases |
| Compaction pacing | Manual throttle logic | `compaction_throttle.zig` | Predictive + reactive, EMA smoothing |
| Memory allocation tracking | Custom tracking | `TrackingAllocator` in testing | Leak detection, peak tracking |
| S2 cell computation | Custom geo math | `src/s2/` (vendored library) | Google's battle-tested spherical geometry |

**Key insight:** The performance infrastructure is already sophisticated. Focus on using existing tools to identify bottlenecks rather than building new measurement frameworks.

## Common Pitfalls

### Pitfall 1: Lite Config Throughput Ceiling
**What goes wrong:** Lite config (~130MB RAM) has inherent throughput limitations due to smaller batches and WAL
**Why it happens:** `message_size_max=32KB` limits batch size to ~1000 events vs 10,000 in production
**How to avoid:** Test final throughput targets with production config; use lite for correctness, not peak performance
**Warning signs:** Throughput plateaus around 5,000-10,000 events/sec despite optimizations

### Pitfall 2: Compaction Write Stalls
**What goes wrong:** Periodic latency spikes during LSM compaction
**Why it happens:** Level 0 fills up while waiting for compaction to complete
**How to avoid:** Use tiered compaction strategy (default), tune `compaction_throttle_*` settings
**Warning signs:** P99 latency 10x+ higher than P50, especially during sustained writes

### Pitfall 3: io_uring Queue Depth Exhaustion
**What goes wrong:** Throughput drops when too many concurrent I/O operations
**Why it happens:** io_uring has finite submission/completion queue depth
**How to avoid:** Monitor `ios_queued` and `ios_in_kernel` metrics; tune `grid_iops_*_max` settings
**Warning signs:** I/O operations backing up in unqueued list

### Pitfall 4: Memory Pressure from RAM Index
**What goes wrong:** RAM index grows unbounded, causing OOM or swap thrashing
**Why it happens:** Entity count exceeds configured limits
**How to avoid:** Monitor `index.entity_count` metric; configure appropriate `memory_size_max_default`
**Warning signs:** RSS growing continuously, swap activity

### Pitfall 5: Cache Misses in Spatial Queries
**What goes wrong:** Radius/polygon queries have high latency due to cache misses
**Why it happens:** S2 cell coverings touch many non-contiguous memory regions
**How to avoid:** Tune `cache_geo_events_size_default` and `grid_cache_size_default`
**Warning signs:** High `cache-misses` in `perf stat`, flame graph showing time in grid reads

### Pitfall 6: Measuring Wrong Thing
**What goes wrong:** Optimizing client overhead instead of server bottleneck
**Why it happens:** Benchmark client can be the bottleneck with insufficient `--clients`
**How to avoid:** Profile server process, not benchmark driver; use multiple clients
**Warning signs:** Server CPU utilization low (<50%) while benchmark reports throughput limit

## Code Examples

Verified patterns from the codebase:

### Running Benchmark with Latency Histograms
```bash
# Source: scripts/run-perf-benchmarks.sh

# Quick benchmark (CI validation)
./zig-out/bin/archerdb benchmark \
    --event-count=10000 \
    --entity-count=1000 \
    --clients=10 \
    --query-uuid-count=100 \
    --query-radius-count=10

# Full benchmark (release validation)
./zig-out/bin/archerdb benchmark \
    --event-count=1000000 \
    --entity-count=100000 \
    --clients=10 \
    --query-uuid-count=10000 \
    --query-radius-count=1000 \
    --query-polygon-count=100

# Connect to existing cluster
./zig-out/bin/archerdb benchmark \
    --addresses=127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003 \
    --event-count=1000000
```

### Generating and Interpreting Flame Graphs
```bash
# Source: docs/profiling.md, scripts/flamegraph.sh

# Generate flame graph during benchmark
./scripts/flamegraph.sh --output insert.svg --duration 60 -- \
    ./zig-out/bin/archerdb benchmark --event-count 1000000

# Profile running server
PID=$(pgrep archerdb)
./scripts/flamegraph.sh --output server.svg --pid $PID --duration 60

# Generate load while profiling (in another terminal)
./zig-out/bin/archerdb benchmark --addresses 127.0.0.1:3001

# Interpretation:
# - Wide bars at TOP = hot functions (optimize these)
# - Look for: s2.region_coverer, ram_index, io_uring paths
# - Unexpected: high time in allocator, hash functions
```

### Hardware Counter Analysis
```bash
# Source: scripts/profile.sh

# Collect hardware counters
./scripts/profile.sh --repeat 10 -- ./zig-out/bin/archerdb benchmark

# Key metrics to watch:
# - IPC (Instructions Per Cycle): 1.0-2.0 typical, >2.0 excellent
# - Cache miss rate: <5% excellent, >10% investigate
# - Branch miss rate: <2% excellent, >5% consider branchless

# Custom counters for specific analysis
./scripts/profile.sh -c L1-dcache-load-misses,LLC-load-misses -- \
    ./zig-out/bin/archerdb benchmark
```

### Sustained Load Test Pattern
```bash
# 24-hour endurance test pattern (PERF-08 requirement)

# 1. Start cluster with production config
./zig/zig build -Drelease -Dconfig=production
./scripts/dev-cluster.sh start --replicas 3

# 2. Run baseline to establish expected throughput
BASELINE=$(./zig-out/bin/archerdb benchmark --event-count 1000000 | grep "throughput")

# 3. Start 24-hour test with monitoring
START_TIME=$(date +%s)
while [ $(($(date +%s) - START_TIME)) -lt 86400 ]; do
    # Run 1-hour chunk
    ./zig-out/bin/archerdb benchmark \
        --addresses=127.0.0.1:3001 \
        --event-count=50000000 \
        --clients=10 \
        2>&1 | tee -a endurance-results.log

    # Collect metrics
    curl -s http://localhost:9090/metrics >> metrics-history.prom

    # Check for degradation (throughput within 5% of baseline)
    # ... validation logic ...
done

# 4. Analyze results
# - Throughput should stay within 5% of baseline
# - Memory (RSS) should not continuously grow
# - P99 latency should remain stable
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Leveled compaction | Tiered compaction (default) | ArcherDB v0.1 | 2-3x lower write amplification |
| epoll for I/O | io_uring | Linux 5.5+ | Higher I/O throughput, lower syscall overhead |
| Blocking profiling | On-demand Tracy | N/A | Near-zero overhead when not profiling |
| Manual latency tracking | Histogram metrics | N/A | Automatic P99/P999/P9999 tracking |

**Deprecated/outdated:**
- **Single-threaded compaction:** Adaptive compaction now uses multiple threads based on workload
- **Fixed compaction throttle:** Now uses EMA-smoothed latency-driven throttling
- **Block size < 32KB:** Minimum 32KB for efficient io_uring and SSD alignment

## Open Questions

Things that couldn't be fully resolved:

1. **Dev server scaling factor**
   - What we know: Dev server (24GB RAM, 8 cores) can't hit 1M events/sec target
   - What's unclear: What is the realistic maximum on this hardware?
   - Recommendation: Establish scaled targets (e.g., 100K events/sec on dev, validate 1M on CI/production hardware)

2. **Optimal batch size for throughput vs latency**
   - What we know: Larger batches = higher throughput, higher latency
   - What's unclear: Optimal batch size for 90%+ write workload
   - Recommendation: Test batch sizes 100, 1000, 10000 and document tradeoff curve

3. **Multi-client scaling behavior**
   - What we know: Single-node scales to ~10 clients well (per benchmarks.md)
   - What's unclear: Optimal client count for 3-node cluster with load balancing
   - Recommendation: Test 1, 10, 50, 100 clients with cluster, document scaling curve

## Sources

### Primary (HIGH confidence)
- `src/archerdb/geo_benchmark_load.zig` - Core benchmark implementation
- `src/config.zig` - Hardware tier configurations and tuning parameters
- `src/lsm/compaction_tiered.zig` - Tiered compaction strategy
- `docs/profiling.md` - Profiling tool documentation
- `docs/benchmarks.md` - Benchmark methodology and results

### Secondary (MEDIUM confidence)
- [TigerBeetle io_uring Abstraction](https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/) - io_uring patterns
- [Brendan Gregg's Flame Graphs](https://www.brendangregg.com/flamegraphs.html) - Profiling methodology
- [Aerospike Benchmarking Best Practices](https://aerospike.com/blog/best-practices-for-database-benchmarking/) - Database testing methodology
- [CockroachDB Real-World Testing](https://www.cockroachlabs.com/blog/database-testing-performance-under-adversity/) - Endurance testing patterns
- [Percona perf + Flame Graphs](https://www.percona.com/blog/profiling-software-using-perf-and-flame-graphs/) - Database profiling

### Tertiary (LOW confidence)
- [LSM Compaction Design Space (VLDB 2022)](https://vldb.org/pvldb/vol14/p2216-sarkar.pdf) - Research on compaction strategies
- [MatrixKV Write Stalls (ATC 2020)](https://www.usenix.org/system/files/atc20-yao.pdf) - NVM-optimized LSM research

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All components exist in codebase, well-documented
- Architecture: HIGH - Patterns verified in existing code
- Pitfalls: MEDIUM - Based on codebase analysis and general LSM knowledge, needs validation

**Research date:** 2026-01-30
**Valid until:** 2026-03-30 (60 days - stable domain, infrastructure unlikely to change)
