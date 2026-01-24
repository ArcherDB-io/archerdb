# Phase 11: Measurement & Profiling Infrastructure - Research

**Researched:** 2026-01-24
**Domain:** Performance profiling, benchmarking, observability tooling for Zig 0.14.1
**Confidence:** HIGH

## Summary

Phase 11 establishes comprehensive profiling infrastructure to enable data-driven optimization for all subsequent v2.0 phases. ArcherDB already has strong foundations: a Perfetto-compatible trace system (`src/trace.zig`), StatsD metrics emission, and a micro-benchmarking harness (`src/testing/bench.zig`). The project also maintains frame pointers in release builds (`omit_frame_pointer = false`), making Linux perf integration straightforward.

The primary work involves:
1. Creating helper scripts and build modes for CPU profiling with Linux perf
2. Integrating POOP for A/B benchmarking with hardware counters
3. Adding DebugAllocator-based memory tracking for test builds
4. Extending the existing metrics system with latency histograms (percentiles beyond min/max/avg)
5. Building a reproducible benchmark harness with statistical analysis
6. Optional: Tracy real-time instrumentation and Parca continuous profiling

**Primary recommendation:** Build on existing infrastructure rather than replacing it. The trace system, StatsD emission, and bench.zig provide solid foundations that need extension, not replacement.

## Standard Stack

The established libraries/tools for this domain:

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Linux perf | System package | CPU profiling, flamegraphs | Native hardware counter access, kernel-level tracing, works with preserved frame pointers |
| [POOP](https://github.com/andrewrk/poop) | Build from source | A/B benchmarking with hardware counters | Created by Zig author, reports 5+ hardware counters, treats first command as baseline |
| Zig DebugAllocator | std.heap.DebugAllocator (Zig 0.14.1) | Memory allocation tracking | Built-in leak detection, stack traces, double-free detection |
| [FlameGraph](https://github.com/brendangregg/FlameGraph) | Latest | Flame graph generation | Industry standard, Brendan Gregg's canonical implementation |
| [hyperfine](https://github.com/sharkdp/hyperfine) | 1.20.x | CLI benchmarking with statistical analysis | Cross-platform, warmup support, JSON export for CI |

### Supporting

| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| [Tracy](https://github.com/wolfpld/tracy) | 0.11.x via zig-gamedev/ztracy | Real-time instrumentation | Deep instrumentation profiling, on-demand mode for production |
| [Parca](https://parca.dev) | Latest | Continuous profiling with eBPF | Production always-on profiling with <1% overhead |
| Valgrind Massif | 3.26.x | Heap profiling | Detailed allocation site analysis (requires c_allocator) |
| Prometheus | 2.x | Metrics storage | Live monitoring via /metrics endpoint |
| Grafana | Latest | Dashboards | Visualization of Prometheus metrics |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| POOP | hyperfine | hyperfine lacks hardware counters but is cross-platform |
| Tracy | Manual instrumentation | Tracy adds build complexity but provides real-time visualization |
| Parca | Manual perf sampling | Parca automates continuous profiling but requires eBPF infrastructure |
| DebugAllocator | Valgrind Memcheck | Valgrind provides more detail but 10-30x slowdown |

**Installation:**
```bash
# Ubuntu/Debian
sudo apt install linux-perf valgrind hyperfine

# Build POOP from source (Zig 0.14.1)
git clone https://github.com/andrewrk/poop
cd poop && zig build -Doptimize=ReleaseFast

# FlameGraph scripts
git clone https://github.com/brendangregg/FlameGraph
```

## Architecture Patterns

### Recommended Project Structure

```
scripts/
├── flamegraph.sh          # Wrapper for perf + FlameGraph with sensible defaults
├── benchmark-ab.sh        # POOP-based A/B comparison helper
└── benchmark-ci.sh        # CI benchmark runner with baseline comparison

src/
├── testing/
│   ├── bench.zig          # EXISTING: micro-benchmark harness
│   └── allocator_tracking.zig  # NEW: DebugAllocator wrapper with reporting
├── archerdb/
│   ├── metrics.zig        # EXISTING: Prometheus metrics (extend with histograms)
│   └── metrics_server.zig # EXISTING: /metrics HTTP endpoint
└── trace/
    ├── event.zig          # EXISTING: trace events
    └── statsd.zig         # EXISTING: StatsD emission

.github/workflows/
└── benchmark.yml          # NEW: CI benchmark workflow
```

### Pattern 1: Latency Histogram with Extended Percentiles

**What:** Track P50, P75, P90, P95, P99, P99.9, P99.99, max for all operation types
**When to use:** All latency-sensitive operations

The existing `src/archerdb/metrics.zig` has `HistogramType` but needs extended percentile calculation:

```zig
// Source: Extend existing HistogramType in src/archerdb/metrics.zig
pub fn ExtendedHistogramType(comptime bucket_count: usize) type {
    return struct {
        buckets: [bucket_count]std.atomic.Value(u64),
        bucket_bounds: [bucket_count]f64,
        sum: std.atomic.Value(u64),
        count: std.atomic.Value(u64),

        // Extended percentile computation
        pub fn getPercentile(self: *const @This(), p: f64) f64 {
            const target_count = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.count.load(.monotonic))) * p));
            var cumulative: u64 = 0;
            for (self.bucket_bounds, 0..) |bound, i| {
                cumulative += self.buckets[i].load(.monotonic);
                if (cumulative >= target_count) {
                    return bound;
                }
            }
            return self.bucket_bounds[bucket_count - 1];
        }

        pub fn getExtendedStats(self: *const @This()) ExtendedStats {
            return .{
                .p50 = self.getPercentile(0.50),
                .p75 = self.getPercentile(0.75),
                .p90 = self.getPercentile(0.90),
                .p95 = self.getPercentile(0.95),
                .p99 = self.getPercentile(0.99),
                .p999 = self.getPercentile(0.999),
                .p9999 = self.getPercentile(0.9999),
                .max = self.bucket_bounds[bucket_count - 1],
                .count = self.count.load(.monotonic),
                .sum = self.getSum(),
            };
        }
    };
}

pub const ExtendedStats = struct {
    p50: f64,
    p75: f64,
    p90: f64,
    p95: f64,
    p99: f64,
    p999: f64,
    p9999: f64,
    max: f64,
    count: u64,
    sum: f64,
};
```

### Pattern 2: Memory Allocation Tracking with Stack Traces

**What:** Wrap allocator to track all allocations with full call stacks
**When to use:** Test builds for leak detection and memory optimization

```zig
// Source: Based on Zig stdlib DebugAllocator
const std = @import("std");

pub fn TrackingAllocator(comptime stack_trace_frames: usize) type {
    return struct {
        underlying: std.mem.Allocator,
        allocations: std.AutoHashMap(usize, AllocationInfo),
        mutex: std.Thread.Mutex,
        total_allocated: usize,
        total_freed: usize,
        peak_allocated: usize,
        allocation_count: usize,

        pub const AllocationInfo = struct {
            size: usize,
            stack_trace: std.debug.Trace,
            timestamp: i64,
        };

        pub fn init(underlying: std.mem.Allocator, backing_allocator: std.mem.Allocator) @This() {
            return .{
                .underlying = underlying,
                .allocations = std.AutoHashMap(usize, AllocationInfo).init(backing_allocator),
                .mutex = .{},
                .total_allocated = 0,
                .total_freed = 0,
                .peak_allocated = 0,
                .allocation_count = 0,
            };
        }

        pub fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        pub fn dumpLeaks(self: *@This(), writer: anytype) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var iter = self.allocations.iterator();
            while (iter.next()) |entry| {
                try writer.print("Leaked {d} bytes at 0x{x}:\n", .{
                    entry.value_ptr.size,
                    entry.key_ptr.*,
                });
                entry.value_ptr.stack_trace.format("  ", null, writer);
            }
        }

        // ... vtable implementation
    };
}
```

### Pattern 3: Benchmark Harness with Statistical Analysis

**What:** Extended benchmark runner with confidence intervals and outlier detection
**When to use:** All performance benchmarks

```zig
// Source: Extend existing src/testing/bench.zig
pub const StatisticalResult = struct {
    mean: f64,
    std_dev: f64,
    confidence_interval_95: struct { lower: f64, upper: f64 },
    min: f64,
    max: f64,
    p50: f64,
    p99: f64,
    samples: usize,
    outliers_removed: usize,

    pub fn format(self: *const @This(), writer: anytype) !void {
        try writer.print(
            \\mean={d:.3}ms (+/- {d:.3}ms)
            \\95% CI: [{d:.3}ms, {d:.3}ms]
            \\P50={d:.3}ms P99={d:.3}ms
            \\samples={d} (outliers removed: {d})
        , .{
            self.mean / 1e6,
            self.std_dev / 1e6,
            self.confidence_interval_95.lower / 1e6,
            self.confidence_interval_95.upper / 1e6,
            self.p50 / 1e6,
            self.p99 / 1e6,
            self.samples,
            self.outliers_removed,
        });
    }
};

pub fn computeStatistics(samples: []const f64) StatisticalResult {
    // Sort for percentile calculation
    var sorted = samples;
    std.sort.block(f64, sorted, {}, std.sort.asc(f64));

    // Remove outliers (IQR method)
    const q1_idx = sorted.len / 4;
    const q3_idx = (sorted.len * 3) / 4;
    const iqr = sorted[q3_idx] - sorted[q1_idx];
    const lower_bound = sorted[q1_idx] - 1.5 * iqr;
    const upper_bound = sorted[q3_idx] + 1.5 * iqr;

    var filtered: std.ArrayList(f64) = .{};
    var outliers_removed: usize = 0;
    for (sorted) |s| {
        if (s >= lower_bound and s <= upper_bound) {
            filtered.append(s);
        } else {
            outliers_removed += 1;
        }
    }

    // Compute statistics on filtered data
    const mean = computeMean(filtered.items);
    const std_dev = computeStdDev(filtered.items, mean);
    const se = std_dev / @sqrt(@as(f64, @floatFromInt(filtered.items.len)));

    return .{
        .mean = mean,
        .std_dev = std_dev,
        .confidence_interval_95 = .{
            .lower = mean - 1.96 * se,
            .upper = mean + 1.96 * se,
        },
        .min = filtered.items[0],
        .max = filtered.items[filtered.items.len - 1],
        .p50 = filtered.items[filtered.items.len / 2],
        .p99 = filtered.items[(filtered.items.len * 99) / 100],
        .samples = filtered.items.len,
        .outliers_removed = outliers_removed,
    };
}
```

### Pattern 4: Flame Graph Helper Script

**What:** Wrapper script for Linux perf with sensible defaults for ArcherDB
**When to use:** CPU profiling of any workload

```bash
#!/bin/bash
# scripts/flamegraph.sh
# Source: Best practices from https://www.brendangregg.com/perf.html

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$SCRIPT_DIR/../tools/FlameGraph}"

usage() {
    echo "Usage: $0 [options] <output.svg> -- <command>"
    echo "Options:"
    echo "  -d, --duration <sec>    Sampling duration (default: 30)"
    echo "  -f, --frequency <hz>    Sampling frequency (default: 99)"
    echo "  -a, --all               Include kernel stacks"
    echo "  --help                  Show this help"
}

DURATION=30
FREQUENCY=99
INCLUDE_KERNEL=""
OUTPUT=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--duration) DURATION="$2"; shift 2 ;;
        -f|--frequency) FREQUENCY="$2"; shift 2 ;;
        -a|--all) INCLUDE_KERNEL="-a"; shift ;;
        --help) usage; exit 0 ;;
        --) shift; COMMAND="$*"; break ;;
        *) OUTPUT="$1"; shift ;;
    esac
done

if [[ -z "$OUTPUT" ]] || [[ -z "$COMMAND" ]]; then
    usage
    exit 1
fi

# Run perf record
echo "Recording for ${DURATION}s at ${FREQUENCY}Hz..."
perf record -F "$FREQUENCY" -g $INCLUDE_KERNEL --call-graph dwarf \
    -o perf.data -- timeout "$DURATION" $COMMAND || true

# Generate flame graph
perf script -i perf.data | \
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" | \
    "$FLAMEGRAPH_DIR/flamegraph.pl" --title "ArcherDB CPU Profile" > "$OUTPUT"

echo "Flame graph written to: $OUTPUT"
rm -f perf.data
```

### Anti-Patterns to Avoid

- **Averaging without percentiles:** Always report P50/P90/P99/P99.9, not just mean
- **Benchmark gaming:** Never create code paths that only activate for benchmarks
- **Profile build in production:** Profile builds should ONLY be for development/testing
- **Ignoring warmup:** Always discard first N runs for JIT, cache warming
- **Manual timing without statistical analysis:** Always compute confidence intervals

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| CPU flame graphs | Custom profiler | Linux perf + FlameGraph | perf has kernel access, FlameGraph is canonical |
| A/B benchmark comparison | Manual timing diff | POOP | Hardware counter access, statistical comparison |
| Memory leak detection | Custom tracking | std.heap.DebugAllocator | Built-in stack traces, double-free detection |
| Prometheus metrics | Custom HTTP server | Extend existing metrics.zig | ArcherDB already has /metrics endpoint |
| Statistical analysis | Manual mean/stddev | Use established formulas | Proper outlier detection, confidence intervals matter |
| Stack trace capture | Inline assembly | @returnAddress() + DebugInfo | Zig provides proper unwinding support |

**Key insight:** ArcherDB already has 70% of the infrastructure. The work is integration and extension, not greenfield development.

## Common Pitfalls

### Pitfall 1: Optimizing Without Data

**What goes wrong:** Engineering effort spent on components that aren't actual bottlenecks
**Why it happens:** Developer intuition about performance is frequently wrong
**How to avoid:** Profile first, optimize second - always require flame graph or profiling data before approving optimization work
**Warning signs:** PRs with "performance improvement" that lack profiling evidence

### Pitfall 2: Benchmark Gaming

**What goes wrong:** Optimizations that only help synthetic benchmarks
**Why it happens:** Benchmarks become proxies for success
**How to avoid:** Use production-representative workloads; test with realistic data distributions; always measure tail latencies
**Warning signs:** Different code paths for "benchmark mode"; P50 looks great but P99 is terrible

### Pitfall 3: Ignoring Tail Latencies

**What goes wrong:** Focus on P50/average while P99 is 10-100x worse
**Why it happens:** Average/median metrics hide tail behavior
**How to avoid:** Track P50, P90, P95, P99, P99.9 for ALL operations; set alerts on tail latencies
**Warning signs:** P99/P50 ratio > 10x; users reporting "random" slow requests

### Pitfall 4: Noisy Benchmark Results

**What goes wrong:** False regression alerts from statistical noise
**Why it happens:** Single-run benchmarks without confidence intervals
**How to avoid:** Run 10+ samples; compute 95% confidence intervals; require regression to exceed 2+ stddev
**Warning signs:** Flaky CI benchmarks; different results on each run

### Pitfall 5: Frame Pointer Stripping

**What goes wrong:** Flame graphs show incomplete stacks
**Why it happens:** Default compiler settings omit frame pointers for optimization
**How to avoid:** ArcherDB already preserves frame pointers (`omit_frame_pointer = false`) - verify this for all profiled builds
**Warning signs:** Flame graphs with "[unknown]" frames; truncated call stacks

## Code Examples

Verified patterns from official sources:

### Linux perf Basic Usage
```bash
# Source: https://www.brendangregg.com/perf.html

# CPU sampling with call graphs
perf record -F 99 -g --call-graph dwarf ./archerdb benchmark --duration=30

# Generate report
perf report --stdio

# Hardware counters (cache misses, branches)
perf stat -e cache-misses,cache-references,branches,branch-misses \
    ./archerdb benchmark --duration=10
```

### POOP A/B Comparison
```bash
# Source: https://github.com/andrewrk/poop

# Compare baseline vs optimized (first command is reference)
poop --duration 5000 \
    './archerdb-baseline benchmark --duration=10' \
    './archerdb-optimized benchmark --duration=10'

# Output shows hardware counters and timing comparison
```

### DebugAllocator Usage
```zig
// Source: Zig stdlib documentation

const std = @import("std");

pub fn main() !void {
    // For test/development builds
    var debug_allocator: std.heap.DebugAllocator(.{
        .stack_trace_frames = 8,  // Capture 8 stack frames
        .retain_metadata = true,
    }) = .init(std.heap.page_allocator);
    defer {
        const leak_check = debug_allocator.deinit();
        if (leak_check == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }

    const allocator = debug_allocator.allocator();

    // Use allocator normally
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);
}
```

### Prometheus Metric Naming
```zig
// Source: https://prometheus.io/docs/practices/naming/

// Good: follows conventions
pub var archerdb_query_latency_seconds = latencyHistogram(
    "archerdb_query_latency_seconds",  // snake_case, base unit
    "Query latency in seconds",
    "operation=\"radius_query\"",  // label for operation type
);

pub var archerdb_operations_total = Counter.init(
    "archerdb_operations_total",  // _total suffix for counters
    "Total operations processed",
    "type=\"insert\"",
);

// Bad: avoid these patterns
// archerdb_queryLatencyMs  -- camelCase, milliseconds instead of base unit
// archerdb_operations      -- missing _total suffix for counter
// archerdb:internal:ops    -- colons reserved for recording rules
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| gprof instrumentation | perf + eBPF | ~2015 | Zero-overhead sampling, kernel visibility |
| Manual timing | POOP/hyperfine | ~2020 | Statistical rigor, hardware counters |
| Custom allocator wrappers | std.heap.DebugAllocator | Zig 0.11 | Built-in stack traces, standardized |
| Single percentile (P95) | Full distribution | ~2018 | Better tail latency understanding |
| Manual baseline management | CI auto-baselines | ~2022 | Automated regression detection |

**Deprecated/outdated:**
- **gprof:** Requires instrumentation, doesn't work well with modern optimizations
- **Instruments.app (macOS):** No Zig symbol support
- **zprof:** Requires Zig 0.15.1+, not compatible with 0.14.1

## Open Questions

Things that couldn't be fully resolved:

1. **POOP Invocation Approach**
   - What we know: POOP compares multiple commands, treats first as baseline
   - What's unclear: Best way to invoke from build.zig vs external script
   - Recommendation: Start with shell script wrapper, can integrate into build.zig later if needed

2. **Tracy On-Demand Mode Configuration**
   - What we know: Tracy supports on-demand profiling that only activates when profiler connects
   - What's unclear: Exact build.zig configuration for on-demand vs always-on
   - Recommendation: Follow zig-gamedev/ztracy examples; test with explicit `TRACY_ON_DEMAND` define

3. **CI Baseline Storage**
   - What we know: Need to store baseline benchmarks for regression comparison
   - What's unclear: Best storage mechanism (artifact? branch? external service?)
   - Recommendation: Start with git branch storage (`benchmarks` branch), evaluate Bencher.dev for longer term

4. **Quick Benchmark Workload Selection**
   - What we know: Need <30s quick mode for iteration
   - What's unclear: Which operations to include for representative coverage
   - Recommendation: Include: 1000 inserts, 100 radius queries, 50 polygon queries, 10 range scans

## Sources

### Primary (HIGH confidence)
- [andrewrk/poop](https://github.com/andrewrk/poop) - Official POOP repository
- [Zig stdlib DebugAllocator](https://ziglang.org/documentation/master/std/#std.heap.DebugAllocator) - Memory debugging
- [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/) - Metric naming
- [brendangregg/FlameGraph](https://github.com/brendangregg/FlameGraph) - Canonical flame graph tools
- [Linux perf Examples](https://www.brendangregg.com/perf.html) - Brendan Gregg's perf guide

### Secondary (MEDIUM confidence)
- [zig-gamedev/ztracy](https://github.com/zig-gamedev/ztracy) - Tracy Zig bindings
- [parca-dev/parca](https://github.com/parca-dev/parca) - Continuous profiling
- [sharkdp/hyperfine](https://github.com/sharkdp/hyperfine) - CLI benchmarking

### Tertiary (LOW confidence)
- TracyProfiler on-demand mode - requires validation against current version

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - verified with official sources and existing codebase
- Architecture patterns: HIGH - based on existing ArcherDB infrastructure
- Pitfalls: HIGH - documented in prior research (PITFALLS.md)

**Research date:** 2026-01-24
**Valid until:** 2026-02-24 (30 days - stable domain)

---

## Existing Infrastructure Summary

Key existing components that Phase 11 builds upon:

| Component | Location | Status | Phase 11 Action |
|-----------|----------|--------|-----------------|
| Trace system | `src/trace.zig` | Working | Export to perf format |
| StatsD emission | `src/trace/statsd.zig` | Working | Keep for Prometheus |
| Prometheus metrics | `src/archerdb/metrics.zig` | Working | Add extended histograms |
| Micro-bench harness | `src/testing/bench.zig` | Working | Add statistical analysis |
| Frame pointers | `build.zig` | Preserved | Already correct |
| LSM benchmarks | `src/lsm/*_benchmark.zig` | Working | Template for new benchmarks |
| CI workflow | `.github/workflows/ci.yml` | Working | Add benchmark job |

This infrastructure means Phase 11 is primarily **integration and extension** work, not greenfield development.
