# Profiling Guide

This guide covers profiling tools and workflows for performance analysis and optimization of ArcherDB.

## Table of Contents

- [Overview](#overview)
- [Flame Graphs](#flame-graphs)
- [A/B Benchmarking with POOP](#ab-benchmarking-with-poop)
- [Memory Profiling](#memory-profiling)
- [CPU Profiling](#cpu-profiling)
- [Best Practices](#best-practices)

## Overview

ArcherDB provides several profiling tools for different analysis needs:

| Tool | Use Case | Output |
|------|----------|--------|
| Flame Graphs | CPU time visualization | Interactive SVG |
| POOP | A/B comparison with hardware counters | Text/JSON |
| DebugAllocator | Memory allocation tracking | Statistics |
| Tracy | Real-time profiling | Interactive UI |

### Profiling Workflow

1. **Identify**: Use benchmarks to find slow operations
2. **Profile**: Generate flame graph or use POOP for detailed analysis
3. **Optimize**: Make targeted improvements based on profiling data
4. **Verify**: Use A/B comparison to validate improvement

## Flame Graphs

Flame graphs provide hierarchical visualization of where CPU time is spent.

### Quick Start

```bash
# Record and generate flame graph
./scripts/flame-graph.sh ./zig-out/bin/archerdb benchmark --quick

# Output: flamegraph-YYYYMMDD-HHMMSS.svg
```

### Installation

The script automatically downloads FlameGraph scripts if needed:

```bash
# Or install manually
git clone https://github.com/brendangregg/FlameGraph tools/FlameGraph
```

### Options

```bash
./scripts/flame-graph.sh [OPTIONS] <command>

Options:
  -d, --duration <sec>   Recording duration (default: 30)
  -o, --output <file>    Output SVG filename
  --frequency <hz>       Sampling frequency (default: 99)
  --no-inline            Disable inline function expansion
```

### Interpreting Flame Graphs

- **Width**: Proportional to time spent (wider = more time)
- **Height**: Call stack depth (bottom = entry point, top = leaf functions)
- **Color**: Random, for visual distinction only
- **Hover**: Shows function name and percentage

**Common patterns to look for:**

1. **Wide plateaus**: Functions consuming significant CPU time
2. **Deep stacks**: Excessive call depth or recursion
3. **Repeated patterns**: Hot loops or repeated allocations

## A/B Benchmarking with POOP

POOP (Performance Optimizer Observation Platform) enables statistical comparison between two versions with hardware counter analysis.

### Why POOP over Hyperfine?

| Feature | POOP | Hyperfine |
|---------|------|-----------|
| Hardware counters | Yes (cycles, cache misses, branches) | No |
| Statistical comparison | First command as baseline | Manual calculation |
| IPC calculation | Built-in | No |
| Zig integration | Native | External |

### Installation

```bash
# Clone and build POOP
git clone https://github.com/andrewrk/poop tools/poop
cd tools/poop && zig build -Doptimize=ReleaseFast

# Binary at tools/poop/zig-out/bin/poop
# Or set POOP_PATH environment variable
export POOP_PATH=/path/to/poop
```

### Basic Usage

```bash
# Compare two binaries
./scripts/benchmark-ab.sh \
  './archerdb-v1 benchmark' \
  './archerdb-v2 benchmark'

# With explicit options
./scripts/benchmark-ab.sh -d 10000 -w 5 \
  --baseline './old benchmark' \
  --optimized './new benchmark'

# JSON output for CI
./scripts/benchmark-ab.sh --json \
  './baseline benchmark' \
  './optimized benchmark'
```

### Command Options

```
Usage: benchmark-ab.sh [OPTIONS] <baseline-cmd> <optimized-cmd>

Options:
  -d, --duration <ms>     Per-command duration (default: 5000)
  -w, --warmup <n>        Warmup iterations (default: 3)
  --json                  Output in JSON format for CI
  --baseline <cmd>        Baseline command (alternative to positional)
  --optimized <cmd>       Optimized command (alternative to positional)
```

### Hardware Counters Explained

| Counter | Meaning | Good Value |
|---------|---------|------------|
| cycles | CPU cycles consumed | Lower is better |
| instructions | Instructions executed | Context-dependent |
| IPC | Instructions per cycle | Higher is better (max ~4-6 on modern CPUs) |
| cache-refs | L1/L2/L3 cache accesses | N/A (informational) |
| cache-misses | Cache misses | Lower is better |
| cache-miss-rate | Misses / refs | <5% is good, >10% is concerning |
| branches | Branch instructions | N/A (informational) |
| branch-misses | Mispredicted branches | Lower is better |
| branch-miss-rate | Misses / branches | <2% is good, >5% is concerning |

### Interpreting Results

**Statistical Significance:**
- >5% change with low variance: Significant
- <5% change: Within noise, not significant
- High variance: Unreliable, increase duration

**Color coding:**
- Green: >5% faster (improvement)
- Red: >5% slower (regression)
- Yellow: Within noise threshold

**Common patterns:**

| Pattern | Interpretation |
|---------|----------------|
| Faster + Lower cache misses | Clean optimization |
| Faster + Higher cache misses | Trade-off (may regress under memory pressure) |
| Faster + Higher IPC | Better instruction-level parallelism |
| Same time + Lower cache misses | Memory efficiency improvement |

### A/B Optimization Workflow

Complete workflow for validating an optimization:

```bash
# 1. Build baseline from current commit
git stash  # Save your changes
zig build -Doptimize=ReleaseFast
mv zig-out/bin/archerdb baseline

# 2. Apply your optimization
git stash pop  # Restore your changes
zig build -Doptimize=ReleaseFast

# 3. Compare baseline vs optimized
./scripts/benchmark-ab.sh \
  './baseline benchmark --quick' \
  './zig-out/bin/archerdb benchmark --quick'

# 4. If improvement is significant, commit
# 5. If not significant, analyze hardware counters for insights
```

**Tips for valid comparisons:**

1. Use identical workloads for both commands
2. Ensure system is idle (no other CPU-intensive tasks)
3. Run multiple times to verify consistency
4. Use longer duration (10s+) for small improvements
5. Check hardware counters even if time is similar

### JSON Output Format

For CI integration:

```json
{
  "baseline": {
    "time_ns": 1234567890,
    "counters": {
      "cycles": 12345678,
      "instructions": 23456789,
      "cache_refs": 1234567,
      "cache_misses": 12345,
      "branches": 345678,
      "branch_misses": 1234
    },
    "derived": {
      "ipc": 1.899,
      "cache_miss_rate_percent": 1.00,
      "branch_miss_rate_percent": 0.36
    }
  },
  "optimized": { ... },
  "comparison": {
    "time_delta_percent": -15.5,
    "verdict": "faster",
    "significant": true
  }
}
```

## Memory Profiling

### Using DebugAllocator

ArcherDB includes a `TrackingAllocator` wrapper for memory analysis:

```zig
const tracking = @import("testing/allocator_tracking.zig");

// Create tracking allocator
var tracker = tracking.TrackingAllocator.init(std.heap.page_allocator);
defer {
    const result = tracker.deinit();
    if (result == .leak) {
        std.log.err("Memory leak detected!", .{});
    }
}

const allocator = tracker.allocator();

// Use allocator normally...

// Check statistics
const stats = tracker.getStats();
std.log.info("Peak memory: {} bytes", .{stats.peak_bytes});
std.log.info("Total allocations: {}", .{stats.total_allocations});
```

### Memory Metrics

| Metric | Description |
|--------|-------------|
| total_allocations | Number of allocation calls |
| total_frees | Number of free calls |
| current_bytes | Currently allocated bytes |
| peak_bytes | Maximum allocated at any point |
| allocation_failures | Failed allocation attempts |

### Leak Detection

The `deinit()` method returns leak status:

```zig
const result = tracker.deinit();
switch (result) {
    .ok => std.log.info("No leaks detected", .{}),
    .leak => std.log.err("Memory leak! {} bytes outstanding", .{tracker.getStats().current_bytes}),
}
```

## CPU Profiling

### Using perf

For detailed CPU analysis beyond flame graphs:

```bash
# Record with call graph
perf record -g ./zig-out/bin/archerdb benchmark --quick

# Analyze
perf report

# Top functions by time
perf report --sort=overhead --no-children
```

### Using Tracy (Profile Build)

Build with Tracy support:

```bash
# Build with profile mode
./zig/zig build -Dconfig=profile

# Run with Tracy connected
./zig-out/bin/archerdb-profile serve
```

Tracy provides real-time visualization of:
- Function timing
- Lock contention
- Memory allocations
- Custom zones

## Best Practices

### When to Profile

1. **Before optimization**: Establish baseline
2. **After optimization**: Verify improvement
3. **Before release**: Ensure no regressions
4. **After refactoring**: Confirm performance preserved

### Profiling Checklist

- [ ] Use release builds (`-Doptimize=ReleaseFast`)
- [ ] Warm up caches before measurement
- [ ] Run multiple iterations
- [ ] Use consistent test data
- [ ] Isolate the system (minimal background load)
- [ ] Document results for future comparison

### Common Pitfalls

1. **Debug builds**: 10-100x slower, misleading profiles
2. **Small samples**: High variance, unreliable results
3. **Cold caches**: First run different from steady state
4. **Compiler optimizations**: Release builds may inline/eliminate code
5. **System noise**: Background processes affect measurements

### Optimization Priority

Focus optimization efforts based on profiling data:

1. **Hot paths**: Functions consuming >10% of CPU time
2. **Cache misses**: High miss rate (>10%) in critical paths
3. **Branch mispredictions**: High miss rate (>5%) in loops
4. **Memory allocations**: Excessive allocations in hot paths

## Related Documentation

- [Benchmarks](benchmarks.md) - Performance benchmark results
- [Hardware Requirements](hardware-requirements.md) - System recommendations
- [Architecture](architecture.md) - System design overview
