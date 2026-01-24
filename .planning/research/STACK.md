# Stack Research: Performance & Scale

**Project:** ArcherDB Performance Optimization
**Researched:** 2026-01-24
**Focus:** Profiling, benchmarking, and optimization tools for Zig 0.14.1

## Executive Summary

ArcherDB already has solid foundations for performance work:
- Built-in tracing infrastructure (`src/trace.zig`) with Perfetto/Chrome-compatible JSON output
- StatsD metrics emission for Prometheus integration
- Micro-benchmarking harness (`src/testing/bench.zig`)
- io_uring-based async I/O on Linux

The stack additions focus on **external profiling tools** that complement existing instrumentation, plus **new internal capabilities** for deeper analysis.

---

## Profiling Tools

### CPU Profiling

#### 1. Linux perf (RECOMMENDED - Primary)

**Version:** System package (kernel-matched)
**Platform:** Linux only

**Why:** Native hardware counter access with minimal overhead. ArcherDB already uses io_uring which integrates well with perf's kernel tracing.

**Integration:**
```bash
# CPU sampling
perf record -g ./archerdb start --addresses=...

# Hardware counters (cache misses, branch mispredictions)
perf stat -e cache-misses,branch-misses,instructions ./archerdb benchmark

# Flamegraph generation
perf script | stackcollapse-perf.pl | flamegraph.pl > archerdb.svg
```

**Zig-specific consideration:** Build with `-Drelease` but ensure frame pointers are preserved. ArcherDB's build.zig already sets `omit_frame_pointer = false` for release builds.

**Confidence:** HIGH (verified in codebase: `root_module.omit_frame_pointer = false`)

#### 2. POOP (Performance Optimizer Observation Platform) (RECOMMENDED - Benchmarking)

**Source:** https://github.com/andrewrk/poop
**Version:** Build from source with Zig 0.14.1
**Platform:** Linux only

**Why:** Created by Andrew Kelley specifically for Zig. Reports hardware counters (cache misses, branch mispredictions) alongside timing. Better than hyperfine for A/B comparisons of Zig code.

**Integration:**
```bash
# Compare two implementations
poop './archerdb benchmark --duration=10' './archerdb-optimized benchmark --duration=10'

# Custom duration
poop --duration 10000 './archerdb benchmark'
```

**Advantages over hyperfine:**
- Reports 5 hardware counters alongside timing
- No shell spawning overhead
- Treats first command as reference baseline
- Written in Zig (easy to modify if needed)

**Confidence:** HIGH (official Zig tooling)

#### 3. Tracy Profiler (RECOMMENDED - Deep Instrumentation)

**Version:** Tracy 0.11.x
**Binding:** zig-gamedev/ztracy
**Platform:** Linux, macOS (instrumentation only on Apple Silicon)

**Why:** Real-time visualization of code execution. Complements ArcherDB's existing trace infrastructure. Can run alongside production workloads with minimal overhead when using on-demand mode.

**Integration:**
```zig
// build.zig.zon
.dependencies = .{
    .ztracy = .{
        .url = "https://github.com/zig-gamedev/ztracy/archive/refs/tags/v0.11.0.tar.gz",
    },
},

// Usage
const ztracy = @import("ztracy");
pub fn hot_function() void {
    const zone = ztracy.ZoneNC(@src(), "hot_function", 0x00ff0000);
    defer zone.End();
    // ... work
}
```

**Build options:**
- `enable_ztracy`: Enable profiling markers
- `on_demand`: Only profile when Tracy GUI connects (production-safe)
- `enable_fibers`: For coroutine/green thread support

**Known issue:** Debug builds may crash with Zig 0.15 (not 0.14.1). Use ReleaseFast if issues occur.

**Confidence:** MEDIUM (zig-gamedev/ztracy verified, but haven't tested specific integration)

### Memory Profiling

#### 4. Zig DebugAllocator (RECOMMENDED - Development)

**Version:** std.heap.DebugAllocator (Zig 0.14.1 stdlib)
**Platform:** All

**Why:** Built-in, zero-external-dependency memory debugging with leak detection and double-free protection.

**Integration:**
```zig
const std = @import("std");

// For development/testing builds
var debug_allocator: std.heap.DebugAllocator(.{}) = .init(std.heap.page_allocator);
const allocator = debug_allocator.allocator();

// Check total allocations
const total = debug_allocator.total_requested_bytes;
```

**Features in Zig 0.14:**
- Leak detection with stack traces
- Double-free detection
- Use-after-free detection
- `total_requested_bytes` for memory tracking

**Confidence:** HIGH (Zig stdlib)

#### 5. Valgrind Massif (RECOMMENDED - Heap Analysis)

**Version:** Valgrind 3.26.x
**Platform:** Linux, macOS (limited)

**Why:** Detailed heap profiling showing allocation sites and peak memory usage over time. Works with Zig when using c_allocator.

**Integration:**
```bash
# Profile heap usage
valgrind --tool=massif ./archerdb benchmark
ms_print massif.out.PID > heap_report.txt

# For GUI visualization
massif-visualizer massif.out.PID
```

**Zig requirement:** Must use `std.heap.c_allocator` (link libc) for Valgrind to track allocations.

**Performance impact:** 10-30x slowdown. Use for analysis, not benchmarking.

**Confidence:** HIGH (Valgrind well-documented)

#### 6. Cachegrind/Callgrind (OPTIONAL - Cache Analysis)

**Version:** Valgrind 3.26.x
**Platform:** Linux

**Why:** Detailed cache miss analysis. Useful for optimizing LSM-tree data layouts and S2 index structures.

**Integration:**
```bash
# Cache simulation
valgrind --tool=cachegrind ./archerdb benchmark
cg_annotate cachegrind.out.PID

# Call graph with cache info
valgrind --tool=callgrind ./archerdb benchmark
kcachegrind callgrind.out.PID
```

**Confidence:** HIGH (Valgrind well-documented)

---

## Benchmarking

### Existing Infrastructure (USE THESE)

ArcherDB already has comprehensive benchmarking:

| Tool | Location | Use Case |
|------|----------|----------|
| `src/testing/bench.zig` | Micro-benchmarks | Component-level timing |
| `archerdb benchmark` | End-to-end | Full system throughput |
| `src/lsm/*_benchmark.zig` | LSM components | Binary search, k-way merge |
| `scripts/competitor-benchmarks/` | Competitive analysis | vs Tile38, PostGIS, etc. |

### Additions

#### 7. hyperfine (RECOMMENDED - CLI Benchmarking)

**Version:** 1.20.x
**Source:** https://github.com/sharkdp/hyperfine
**Platform:** All

**Why:** Statistical rigor for command-line benchmarks. Handles warmup, outlier detection, and exports to multiple formats.

**Integration:**
```bash
# Basic comparison
hyperfine --warmup 3 \
  './archerdb benchmark --duration=10' \
  './archerdb-v2 benchmark --duration=10'

# With cache clearing (for cold-start tests)
hyperfine --prepare 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches' \
  './archerdb benchmark'

# Export for CI
hyperfine --export-json results.json './archerdb benchmark'
```

**When to use hyperfine vs POOP:**
- **hyperfine:** Cross-platform, CI integration, statistical analysis
- **POOP:** Hardware counter details, A/B comparisons, Zig-native

**Confidence:** HIGH (mature, well-documented)

#### 8. Continuous Benchmarking with Bencher (OPTIONAL)

**Source:** https://bencher.dev
**Platform:** CI/CD integration

**Why:** Track performance regressions across commits. Integrates with hyperfine output.

**Integration:**
```yaml
# .github/workflows/benchmark.yml
- name: Run benchmarks
  run: |
    hyperfine --export-json results.json './archerdb benchmark'
    bencher run --file results.json
```

**Confidence:** MEDIUM (haven't verified integration)

---

## Distributed Profiling

### Existing Infrastructure (LEVERAGE THESE)

ArcherDB has strong foundations:

| Capability | Implementation | Status |
|------------|----------------|--------|
| Event tracing | `src/trace.zig` | Perfetto-compatible JSON |
| StatsD metrics | `src/trace/statsd.zig` | UDP emission |
| Prometheus | Via StatsD adapter | Works today |
| OpenTelemetry | Not native | Could bridge via collector |

### Recommendations

#### 9. Grafana Stack (RECOMMENDED - Production Monitoring)

**Components:**
- **Prometheus:** Metrics storage (via existing StatsD bridge)
- **Grafana:** Dashboards and alerting
- **Tempo:** Distributed tracing (via OpenTelemetry Collector)

**Why:** ArcherDB already emits StatsD. The Grafana stack provides visualization without code changes.

**Integration:**
```yaml
# docker-compose.yml addition
services:
  statsd-exporter:
    image: prom/statsd-exporter:latest
    ports:
      - "9102:9102"  # Prometheus scrape
      - "8125:8125/udp"  # StatsD receive

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
```

**Confidence:** HIGH (standard tooling, ArcherDB already emits StatsD)

#### 10. Jaeger 2.0 (OPTIONAL - Request Tracing)

**Version:** 2.0+ (OpenTelemetry-native)
**Why:** Visualize cross-replica request flow. ArcherDB's trace JSON could be converted to OTLP.

**Integration complexity:** MEDIUM - Would need a trace-to-OTLP converter.

**Confidence:** LOW (would require new code)

#### 11. Parca (OPTIONAL - Continuous CPU Profiling)

**Source:** https://parca.dev
**Why:** eBPF-based continuous profiling with <1% overhead. Can run in production.

**When to use:** If production CPU profiling is needed beyond Tracy's on-demand mode.

**Confidence:** MEDIUM (eBPF well-established, but haven't tested with Zig binaries)

---

## Memory Optimization Techniques

### Zig-Specific Patterns

#### Allocation Tracking

ArcherDB already uses arena allocators extensively. Track allocations with:

```zig
// Wrap allocator to track allocations
const TrackingAllocator = struct {
    underlying: std.mem.Allocator,
    total_allocated: usize = 0,
    allocation_count: usize = 0,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ...) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.total_allocated += len;
        self.allocation_count += 1;
        return self.underlying.rawAlloc(len, ...);
    }
    // ... resize, free implementations
};
```

#### Pool Allocator Analysis

ArcherDB uses `node_pool.zig` for LSM tree nodes. Profile pool efficiency:

```zig
// Add to node_pool for analysis
pub const PoolStats = struct {
    nodes_allocated: usize,
    nodes_in_use: usize,
    fragmentation_ratio: f64,
};
```

### OS-Level Memory Analysis

```bash
# Track RSS over time
while true; do
  ps -o rss= -p $(pgrep archerdb) >> rss_log.txt
  sleep 1
done

# Detailed memory map
pmap -x $(pgrep archerdb)

# Page fault analysis
perf stat -e page-faults,minor-faults,major-faults ./archerdb benchmark
```

---

## Concurrency Profiling

### io_uring Analysis

ArcherDB uses io_uring for async I/O. Profile with:

```bash
# Trace io_uring operations
sudo perf trace -e 'io_uring:*' ./archerdb start

# Detailed submission/completion analysis
sudo bpftrace -e 'tracepoint:io_uring:io_uring_complete { @[comm] = count(); }'
```

### Thread Contention

For multi-threaded scenarios (cluster coordination):

```bash
# Lock contention
perf lock record ./archerdb start
perf lock report

# Scheduler analysis
perf sched record ./archerdb benchmark
perf sched latency
```

---

## Recommendations Summary

### Must Have (Phase 1)

| Tool | Purpose | Integration Effort |
|------|---------|-------------------|
| Linux perf | CPU profiling, flamegraphs | Minimal (works today) |
| POOP | A/B benchmark comparisons | Build from source |
| DebugAllocator | Memory leak detection | Already in stdlib |
| hyperfine | CI benchmark tracking | Install binary |

### Should Have (Phase 2)

| Tool | Purpose | Integration Effort |
|------|---------|-------------------|
| Tracy (ztracy) | Real-time instrumentation | build.zig.zon dependency |
| Valgrind Massif | Heap profiling | Use c_allocator for analysis |
| Grafana + Prometheus | Production dashboards | Docker compose |

### Nice to Have (Phase 3)

| Tool | Purpose | Integration Effort |
|------|---------|-------------------|
| Parca | Continuous production profiling | eBPF agent deployment |
| Cachegrind | Cache optimization | Per-analysis basis |
| Bencher | Regression tracking | CI integration |

---

## Not Recommended

| Tool | Reason |
|------|--------|
| **gprof** | Outdated, poor support for modern code |
| **Intel VTune** | Overkill for current needs, complex licensing |
| **AMD uProf** | CPU-vendor specific, limited Linux support |
| **DTrace** | macOS only for system tracing, limited Zig support |
| **Instruments.app** | macOS only, no Zig symbol support |
| **zprof** | Requires Zig 0.15.1+, not compatible with 0.14.1 |
| **Custom eBPF** | High effort, Parca/perf cover use cases |

---

## Installation Commands

```bash
# Ubuntu/Debian
sudo apt install linux-perf valgrind hyperfine

# Build POOP from source
git clone https://github.com/andrewrk/poop
cd poop && zig build -Drelease

# Tracy (client)
git clone https://github.com/wolfpld/tracy
cd tracy/profiler/build/unix && make release

# Grafana stack
docker compose up -d  # with provided docker-compose.yml
```

---

## Sources

- [Zig profiling on Apple Silicon](https://blog.bugsiki.dev/posts/zig-profilers/)
- [zig-gamedev/ztracy](https://github.com/zig-gamedev/ztracy)
- [andrewrk/poop](https://github.com/andrewrk/poop)
- [sharkdp/hyperfine](https://github.com/sharkdp/hyperfine)
- [Valgrind Manual - Massif](https://valgrind.org/docs/manual/ms-manual.html)
- [Linux perf Examples](https://www.brendangregg.com/perf.html)
- [Grafana OpenTelemetry](https://grafana.com/docs/opentelemetry/)
- [Zig 0.14.0 Allocator Updates](https://ziglang.org/devlog/2025/)
