# ArcherDB Profiling Guide

This guide covers CPU profiling and performance analysis for ArcherDB using Linux perf and flame graphs.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Flame Graphs](#flame-graphs)
- [Hardware Counter Profiling](#hardware-counter-profiling)
- [Profiling Workflows](#profiling-workflows)
- [A/B Benchmarking with POOP](#ab-benchmarking-with-poop)
- [Memory Profiling](#memory-profiling)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## Prerequisites

### System Requirements

- **Linux kernel >= 5.6** with perf support
- **perf tools** installed
- **FlameGraph scripts** for flame graph generation

### Install perf

```bash
# Ubuntu/Debian
sudo apt install linux-perf

# If that doesn't work, try version-specific package
sudo apt install linux-tools-$(uname -r)

# Fedora/RHEL
sudo dnf install perf

# Arch
sudo pacman -S perf
```

### Install FlameGraph

```bash
# Clone into the project tools directory
git clone https://github.com/brendangregg/FlameGraph.git tools/FlameGraph

# Or set FLAMEGRAPH_DIR to use an existing installation
export FLAMEGRAPH_DIR=/path/to/FlameGraph
```

### Configure perf Permissions

By default, perf requires elevated privileges. To enable user profiling:

```bash
# Check current setting
cat /proc/sys/kernel/perf_event_paranoid

# Allow user profiling (value of 1 or lower)
sudo sysctl kernel.perf_event_paranoid=1

# Make permanent (add to /etc/sysctl.conf)
echo "kernel.perf_event_paranoid=1" | sudo tee -a /etc/sysctl.conf
```

### Frame Pointers

ArcherDB builds preserve frame pointers (`-fno-omit-frame-pointer`), ensuring complete stack traces in profiling output. You should not see `[unknown]` frames in flame graphs.

## Quick Start

### Generate a Flame Graph

```bash
# Build with release optimizations
./zig/zig build -Drelease

# Profile a benchmark run
./scripts/flamegraph.sh --output profile.svg -- ./zig-out/bin/archerdb benchmark

# View in browser
xdg-open profile.svg
# Or: firefox profile.svg
# Or: google-chrome profile.svg
```

### Collect Hardware Counters

```bash
# Profile hardware counters (5 runs for statistics)
./scripts/profile.sh -- ./zig-out/bin/archerdb benchmark
```

## Flame Graphs

Flame graphs provide hierarchical visualization of where CPU time is spent.

### Using flamegraph.sh

```bash
# Basic usage - profile a command
./scripts/flamegraph.sh --output profile.svg -- ./zig-out/bin/archerdb benchmark

# Profile an existing server process
./scripts/flamegraph.sh --output server.svg --pid 12345 --duration 60

# High-frequency sampling with kernel stacks
./scripts/flamegraph.sh --output detailed.svg -f 999 -a -- ./zig-out/bin/archerdb benchmark
```

### Options

```
-d, --duration <sec>    Sampling duration in seconds (default: 30)
-f, --frequency <hz>    Sampling frequency in Hz (default: 99)
-a, --all               Include kernel stacks
-p, --pid <pid>         Attach to existing process
--output <file.svg>     Output SVG file (required)
--no-cleanup            Keep perf.data file after generation
```

### How to Read Flame Graphs

Flame graphs are a visualization of CPU samples collected during program execution.

- **X-axis (width)**: Time spent in a function. Wider = more CPU time.
- **Y-axis (height)**: Stack depth. Bottom = entry point, top = leaf functions.
- **Colors**: Arbitrary (no meaning), just for visual distinction.
- **Interactivity**: Click on a frame to zoom in, click "Reset Zoom" to return.

### Common Patterns

#### Hot Functions (Wide Bars)

Wide bars at the top of the stack indicate functions consuming significant CPU time:

```
|                      hot_function                       |  <- Optimize this
|            caller_1             |       caller_2        |
|                         main                            |
```

**Action**: Focus optimization efforts on these functions.

#### Deep Stacks

Very tall stacks may indicate excessive abstraction or recursion:

```
|func|
|func|
|func|
...
|main|
```

**Action**: Consider flattening call chains or converting recursion to iteration.

#### Unexpected Callers

If a function appears under unexpected parents, trace the call path:

```
|      slow_path     |
|   unexpected_fn    |  <- Why is this calling slow_path?
|       main         |
```

**Action**: Investigate whether this code path should exist.

### ArcherDB-Specific Tips

When profiling ArcherDB, look for:

1. **S2 Cell Operations**: Functions in `s2/` directory handling spatial indexing
2. **LSM Operations**: Compaction, level management in the storage layer
3. **Network I/O**: Message serialization/deserialization
4. **Memory Allocation**: Frequent allocator calls may indicate optimization opportunities

Hot spots to watch:

- `s2.region_coverer.getCovering` - Spatial query coverage
- `ram_index` operations - In-memory indexing
- `io_uring` submission paths - Async I/O handling

## Hardware Counter Profiling

### Using profile.sh

The `scripts/profile.sh` script collects hardware performance counters:

```bash
# Basic profiling (5 runs)
./scripts/profile.sh -- ./zig-out/bin/archerdb benchmark

# More runs for better statistics
./scripts/profile.sh --repeat 10 -- ./zig-out/bin/archerdb benchmark

# JSON output for CI
./scripts/profile.sh --json -- ./zig-out/bin/archerdb benchmark > metrics.json

# Per-core breakdown
./scripts/profile.sh --detailed -- ./zig-out/bin/archerdb benchmark

# Custom counters
./scripts/profile.sh -c cycles,instructions,L1-dcache-load-misses -- ./zig-out/bin/archerdb benchmark
```

### Options

```
-c, --counters <list>   Hardware counters, comma-separated
                        (default: cycles,instructions,cache-misses,cache-references,branch-misses,branches)
-r, --repeat <n>        Number of runs for statistics (default: 5)
-d, --detailed          Show detailed per-core breakdown
--json                  Output in JSON format for CI
```

### Key Metrics

#### Instructions Per Cycle (IPC)

IPC measures how efficiently the CPU executes instructions:

| IPC Range | Interpretation |
|-----------|----------------|
| < 1.0 | CPU-bound with many stalls (cache misses, branch mispredictions) |
| 1.0-2.0 | Typical for complex workloads |
| 2.0-4.0 | Very efficient, well-optimized code |
| > 4.0 | Possible with SIMD/vectorization |

**For ArcherDB workloads**: Expect IPC of 1.0-2.0 for typical database operations. Lower values during spatial queries (complex branching) are normal.

#### Cache Miss Rate

Percentage of memory accesses that miss the last-level cache:

| Rate | Interpretation |
|------|----------------|
| < 5% | Excellent cache behavior |
| 5-10% | Good |
| 10-20% | Acceptable for large datasets |
| > 20% | Potential memory bottleneck |

**For ArcherDB**: Higher miss rates during full-table scans are expected. Point lookups should have < 5% miss rate.

#### Branch Miss Rate

Percentage of branch instructions that were mispredicted:

| Rate | Interpretation |
|------|----------------|
| < 2% | Excellent branch prediction |
| 2-5% | Typical |
| > 5% | May benefit from branchless code |

**For ArcherDB**: Spatial queries have inherently unpredictable branches. Focus optimization on frequently executed paths.

### Hardware Counters Reference

| Counter | Meaning | Good Value |
|---------|---------|------------|
| cycles | CPU cycles consumed | Lower is better |
| instructions | Instructions executed | Context-dependent |
| cache-references | L1/L2/L3 cache accesses | N/A (informational) |
| cache-misses | Cache misses | Lower is better |
| branches | Branch instructions | N/A (informational) |
| branch-misses | Mispredicted branches | Lower is better |
| L1-dcache-loads | L1 data cache loads | N/A (informational) |
| L1-dcache-load-misses | L1 data cache load misses | Lower is better |

## Profiling Workflows

### Profiling a Specific Benchmark

```bash
# Build release binary
./zig/zig build -Drelease

# Profile the benchmark command
./scripts/flamegraph.sh --output insert.svg --duration 60 -- \
    ./zig-out/bin/archerdb benchmark --event-count 1000000

# Collect hardware counters
./scripts/profile.sh --repeat 10 -- \
    ./zig-out/bin/archerdb benchmark --event-count 100000
```

### Profiling a Running Server

```bash
# Start ArcherDB in one terminal
./zig-out/bin/archerdb --data-dir /tmp/archerdb

# Find the PID
pgrep archerdb

# Profile for 60 seconds
./scripts/flamegraph.sh --output server.svg --pid $(pgrep archerdb) --duration 60

# Generate load in another terminal while profiling
./zig-out/bin/archerdb benchmark --addresses 127.0.0.1:3001
```

### A/B Comparison Workflow

For comparing performance before/after changes:

```bash
# 1. Profile baseline (before changes)
git stash  # Save your changes
./zig/zig build -Drelease
./scripts/profile.sh --json -- ./zig-out/bin/archerdb benchmark > baseline.json
./scripts/flamegraph.sh --output baseline.svg -- ./zig-out/bin/archerdb benchmark

# 2. Profile with changes
git stash pop
./zig/zig build -Drelease
./scripts/profile.sh --json -- ./zig-out/bin/archerdb benchmark > changed.json
./scripts/flamegraph.sh --output changed.svg -- ./zig-out/bin/archerdb benchmark

# 3. Compare JSON metrics
diff baseline.json changed.json

# 4. Visual comparison - open both flame graphs side by side
```

### Continuous Profiling in CI

```bash
# In CI pipeline
./scripts/profile.sh --json --repeat 10 -- ./zig-out/bin/archerdb benchmark > metrics.json

# Check for regressions
# (compare against baseline metrics stored in repo or artifact storage)
```

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
# Compare two binaries directly with POOP
./tools/poop/zig-out/bin/poop \
  './archerdb-v1 benchmark' \
  './archerdb-v2 benchmark'
```

**Note**: For wrapper script usage and detailed POOP workflow, see plan 11-02.

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

## Troubleshooting

### "perf: command not found"

Install perf tools for your distribution:

```bash
# Ubuntu/Debian
sudo apt install linux-perf

# If that doesn't work, try version-specific package
sudo apt install linux-tools-$(uname -r)

# Fedora
sudo dnf install perf
```

### "[unknown]" Frames in Flame Graph

This should NOT happen with ArcherDB because frame pointers are preserved. If you see `[unknown]` frames:

1. **Verify build**: Ensure you built with `./zig/zig build` (frame pointers are enabled by default)
2. **Check binary**: Run `readelf -S zig-out/bin/archerdb | grep -i frame` to verify
3. **Kernel symbols**: For kernel stacks, ensure `/proc/kallsyms` is readable

If profiling third-party libraries:

```bash
# The library may need to be built with -fno-omit-frame-pointer
CFLAGS="-fno-omit-frame-pointer" ./configure && make
```

### "Permission denied" or "Access denied"

Lower the perf_event_paranoid setting:

```bash
# Check current value
cat /proc/sys/kernel/perf_event_paranoid

# Values:
#  -1 = Allow all users
#   0 = Allow non-root but disallow kernel profiling
#   1 = Allow non-root with kernel profiling
#   2 = Disallow all non-root (default on many systems)
#   3 = Disallow all non-root completely

# Set to 1 (recommended)
sudo sysctl kernel.perf_event_paranoid=1
```

Alternatively, run with sudo:

```bash
sudo ./scripts/flamegraph.sh --output profile.svg -- ./zig-out/bin/archerdb benchmark
```

### "No samples collected" or Empty Flame Graph

1. **Duration too short**: Increase duration with `-d 60`
2. **Workload too fast**: The command finished before sampling started
3. **Wrong frequency**: Try lower frequency if samples are being throttled

```bash
# Check for throttling messages
dmesg | grep perf

# Use lower frequency
./scripts/flamegraph.sh --output profile.svg -f 49 -- ./zig-out/bin/archerdb benchmark
```

### perf stat Shows "not supported"

Some hardware counters may not be available on your CPU:

```bash
# List available counters
perf list

# Use only universally available counters
./scripts/profile.sh -c cycles,instructions -- ./zig-out/bin/archerdb benchmark
```

### Flame Graph SVG Won't Open

1. **File too large**: Reduce sampling duration or increase frequency
2. **Corrupted output**: Check for error messages during generation
3. **Browser issues**: Try a different browser (Chrome/Firefox work best)

## Best Practices

### When to Profile

1. **Before optimization**: Establish baseline
2. **After optimization**: Verify improvement
3. **Before release**: Ensure no regressions
4. **After refactoring**: Confirm performance preserved

### Profiling Checklist

- [ ] Use release builds (`./zig/zig build -Drelease`)
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

## Tracy Real-Time Instrumentation

Tracy provides real-time instrumentation with visualization. ArcherDB supports Tracy in on-demand mode - zero overhead unless the Tracy profiler GUI is connected.

### Building with Tracy

```bash
# Build with Tracy profiling enabled (on-demand mode)
./zig/zig build profile -Dtracy=true

# Or use the profiling flag
./zig/zig build -Dprofiling=true -Dtracy=true
```

### Using Tracy Zones

ArcherDB provides ergonomic Tracy zone helpers that compile to no-ops when Tracy is disabled:

```zig
const tracy = @import("testing/tracy_zones.zig");

fn processQuery(query: Query) !Result {
    const zone = tracy.zone(@src(), "process_query");
    defer zone.end();

    // Add context to the zone
    zone.text(query.type);
    zone.value(query.entity_count);

    // ... processing ...
}
```

Available zone helpers:

| Function | Purpose |
|----------|---------|
| `zone(@src(), "name")` | Create a named profiling zone |
| `zoneN(@src(), name)` | Create zone with runtime name |
| `frameMark()` | Mark frame boundary |
| `message(text)` | Log to Tracy timeline |
| `plot(name, value)` | Plot metric over time |

### Predefined Colors

Use semantic colors for different subsystems:

```zig
const colors = tracy.colors;

zone.color(colors.query);      // Green - query processing
zone.color(colors.storage);    // Blue - storage operations
zone.color(colors.consensus);  // Red - consensus/Raft
zone.color(colors.network);    // Yellow - network I/O
zone.color(colors.index);      // Magenta - index operations
zone.color(colors.geo);        // Orange - geo/S2 operations
```

### Running Tracy

1. Download Tracy profiler from https://github.com/wolfpld/tracy/releases
2. Run the ArcherDB binary built with `-Dtracy=true`
3. Connect Tracy profiler to the running process
4. Zones will appear in the timeline when profiler connects

Tracy on-demand mode means the instrumentation has near-zero overhead when the profiler is not connected. Profiling only activates when the Tracy GUI establishes a connection.

## Parca Continuous Profiling

Parca provides always-on continuous profiling using eBPF with <1% overhead. Ideal for production monitoring and historical analysis.

### Prerequisites

- Linux kernel >= 5.6 with eBPF support
- Root privileges for eBPF programs

### Quick Start

```bash
# Install Parca agent
sudo ./scripts/parca-agent.sh install

# Start with local Parca server
sudo ./scripts/parca-agent.sh start

# Check status
./scripts/parca-agent.sh status
```

### Parca Server

Run a local Parca server for development:

```bash
# Using Docker
docker run -p 7070:7070 ghcr.io/parca-dev/parca:latest

# Or download binary
curl -sL https://github.com/parca-dev/parca/releases/latest/download/parca_Linux_x86_64.tar.gz | tar xz
./parca --config-path=parca.yaml
```

For production, consider [Parca Cloud](https://www.polarsignals.com/) or self-hosted deployment.

### Analyzing Profiles

1. Open Parca UI at http://localhost:7070
2. Select time range and process
3. View flame graph of CPU usage over time
4. Compare profiles between time periods to find regressions

### Parca Features

- **Continuous profiling**: Always-on with <1% overhead
- **Historical data**: Query profiles from any point in time
- **Differential analysis**: Compare profiles to find regressions
- **Label-based queries**: Filter by process, container, node
- **eBPF-based**: No code changes required

## Profile Build Mode

ArcherDB provides a dedicated profile build mode optimized for profiling:

```bash
# Build with profiling support (frame pointers preserved)
./zig/zig build profile

# Build with Tracy instrumentation
./zig/zig build profile -Dtracy=true
```

The profile build:
- Uses `ReleaseFast` optimization for representative performance
- Preserves frame pointers for accurate stack traces
- Outputs `archerdb-profile` binary

## Additional Resources

- [Brendan Gregg's Flame Graphs](https://www.brendangregg.com/flamegraphs.html) - Original flame graph documentation
- [perf Examples](https://www.brendangregg.com/perf.html) - Comprehensive perf tutorial
- [Linux Perf Wiki](https://perf.wiki.kernel.org/) - Official perf documentation
- [Tracy Profiler](https://github.com/wolfpld/tracy) - Real-time frame profiler
- [Parca Documentation](https://www.parca.dev/docs/) - Continuous profiling

## Related Documentation

- [Benchmarks](benchmarks.md) - Performance benchmark results
- [Hardware Requirements](hardware-requirements.md) - System recommendations
- [Architecture](architecture.md) - System design overview
