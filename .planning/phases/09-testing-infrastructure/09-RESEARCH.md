# Phase 9: Testing Infrastructure - Research

**Researched:** 2026-01-31
**Domain:** Zig testing, deterministic simulation (VOPR), CI/CD test orchestration, performance regression testing
**Confidence:** HIGH

## Summary

This research investigates the testing infrastructure patterns needed to achieve comprehensive test coverage for ArcherDB. The codebase already follows TigerBeetle conventions with a mature testing ecosystem including the VOPR deterministic simulator, fuzz tests, integration tests, unit tests, and chaos testing patterns established in prior phases.

The key challenge is not building testing infrastructure from scratch but organizing, categorizing, and orchestrating the existing tests to meet the TEST-01 through TEST-08 requirements. The established patterns (fixed seed 42, tick-based timing, zero-tolerance flakiness, lite config for development) provide a solid foundation.

**Primary recommendation:** Leverage existing test infrastructure patterns (VOPR, Cluster framework, shell scripts) with enhanced CI orchestration using GitHub Actions matrix strategy to parallelize test categories across runners while maintaining the 60-minute CI time limit.

## Standard Stack

The established libraries/tools for this domain:

### Core

| Tool/Pattern | Version | Purpose | Why Standard |
|--------------|---------|---------|--------------|
| Zig `std.testing` | 0.14.1 | Unit test assertions | Built-in, zero overhead, `expect()`, `expectEqual()` |
| VOPR | N/A | Deterministic simulation testing | TigerBeetle pattern, 700x time acceleration |
| Cluster framework | N/A | Multi-node deterministic testing | Already in `src/testing/cluster.zig` |
| GitHub Actions | v4 | CI orchestration | Matrix strategy, parallel runners |
| Shell scripts | Bash | Chaos/stress tests | Already established in `scripts/` |

### Supporting

| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| `kcov` | Latest | Code coverage | Coverage collection job in CI |
| `timeout` | GNU | Process termination | VOPR duration limits, chaos tests |
| `jq` | Latest | JSON processing | Benchmark result comparison |
| `bc` | Latest | Math operations | Statistical analysis in benchmarks |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Zig test filtering | External test runner | Extra dependency, loses Zig integration |
| Shell chaos scripts | Dedicated chaos framework | Complexity vs established patterns |
| VOPR | Third-party fuzzer | Loses deterministic reproducibility |

**Installation:** Already present in codebase. No new dependencies required.

## Architecture Patterns

### Existing Test Organization

```
src/
├── unit_tests.zig              # Auto-generated test manifest (quine pattern)
├── integration_tests.zig       # Integration tests requiring archerdb binary
├── fuzz_tests.zig              # Non-VOPR fuzzer registry
├── vopr.zig                    # VOPR deterministic simulator
├── testing/
│   ├── cluster.zig             # ClusterType for multi-node tests
│   ├── fuzz.zig                # Fuzzer utilities
│   ├── failover_test.zig       # Integration: failover tests
│   ├── encryption_test.zig     # Integration: encryption tests
│   └── backup_restore_test.zig # Integration: backup tests
└── vsr/
    ├── replica_test.zig              # MULTI-04/05/06 tests
    ├── multi_node_validation_test.zig # MULTI-01/02/03/07 tests
    ├── fault_tolerance_test.zig       # FAULT-01 through FAULT-08
    └── data_integrity_test.zig        # DATA-01 through DATA-09
```

### Pattern 1: Requirement-Labeled Tests

**What:** Tests named with requirement ID prefix (e.g., `FAULT-01:`, `DATA-03:`)
**When to use:** All tests validating specific requirements
**Example:**
```zig
// Source: src/vsr/fault_tolerance_test.zig
test "FAULT-01: process crash (SIGKILL) survives without data loss (R=3)" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();
    // ... test implementation
}
```

### Pattern 2: Fixed Seed Determinism

**What:** All fuzz/simulation tests use seed 42 for reproducibility
**When to use:** Any test using randomness
**Example:**
```zig
// Source: src/vsr/fault_tolerance_test.zig
const t = try TestContext.init(.{
    .replica_count = 3,
    .seed = 42,  // Fixed seed for deterministic reproducibility
});
```

### Pattern 3: Tick-Based Timing

**What:** Use tick counts instead of wall-clock time for timing assertions
**When to use:** Leader election, recovery time, timeout tests
**Example:**
```zig
// Source: src/vsr/fault_tolerance_test.zig
// 500 ticks = 5 seconds in real-world equivalent
const tick_max = 4_100;
var tick_count: usize = 0;
while (tick_count < tick_max) : (tick_count += 1) {
    if (t.tick()) tick_count = 0;  // Reset on progress
}
```

### Pattern 4: Quine Test Manifest

**What:** Auto-generated `unit_tests.zig` that discovers all test files
**When to use:** Ensuring no tests are accidentally excluded
**Example:**
```zig
// Source: src/unit_tests.zig
comptime {
    _ = @import("aof.zig");
    _ = @import("archerdb/backup_config.zig");
    // ... auto-generated list of all test files
}
```

### Pattern 5: Shell Script Regression Tests

**What:** Shell scripts that serve as E2E regression tests
**When to use:** Chaos tests, SIGKILL tests, multi-process scenarios
**Example:**
```bash
# Source: scripts/sigkill_crash_test.sh
run_vopr_with_timeout "${TIMEOUT}" "${TIMEOUT}" || crash_exit_code=$?
if [[ $crash_exit_code -eq 137 ]]; then
    log_info "VOPR was killed as expected (exit code: 137)"
fi
```

### Anti-Patterns to Avoid

- **Wall-clock timing assertions:** Use tick-based timing instead (already established)
- **Flaky test quarantine:** Zero tolerance - fix immediately or block merge
- **Production config in dev tests:** Use lite config (32KB block_size)
- **Mutable global state:** Use TestContext pattern for isolation
- **Random seeds without logging:** Always log seed for reproducibility

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Multi-node test harness | Custom cluster setup | `TestContext`/`Cluster` | Handles network, storage, fault injection |
| Deterministic time | Mock time manually | `TimeSim` | Tick-based, deterministic |
| Network partitions | Socket manipulation | `drop_all`/`pass_all` | Already in TestReplicas |
| Storage corruption | File manipulation | `corrupt()` method | Zeros sectors, invalidates checksums |
| Fault verification | Custom assertions | `area_faulty()` | Confirms repair completed |
| PRNG utilities | Custom random | `stdx.PRNG` | Reproducible, seed-based |
| Test filtering | Custom test runner | `zig test --test-filter` | Built into Zig |

**Key insight:** The existing test infrastructure in `src/testing/` is comprehensive. Phase 9 should organize and orchestrate existing tests, not build new infrastructure.

## Common Pitfalls

### Pitfall 1: Test Flakiness from Real Time Dependencies

**What goes wrong:** Tests pass locally but fail intermittently in CI due to wall-clock timing
**Why it happens:** Using `std.time.sleep()` or real timestamps in assertions
**How to avoid:** Use tick-based timing (`t.tick()` returns bool for progress)
**Warning signs:** Tests that only fail "sometimes" or "on slow machines"

### Pitfall 2: Non-Deterministic Test Order

**What goes wrong:** Tests pass individually but fail when run together
**Why it happens:** Shared state, filesystem pollution, port conflicts
**How to avoid:** Use `TestContext.init()`/`deinit()` pattern, unique temp directories
**Warning signs:** Different results with `--test-filter` vs full suite

### Pitfall 3: CI Timeout from Unparallelized Tests

**What goes wrong:** CI exceeds 60-minute limit
**Why it happens:** All tests run sequentially on single runner
**How to avoid:** Matrix strategy to split test categories across runners
**Warning signs:** CI time growing linearly with test count

### Pitfall 4: Missing Test Discovery

**What goes wrong:** New test files not included in test suite
**Why it happens:** Manual test manifest, forgotten `@import`
**How to avoid:** Use quine pattern in `unit_tests.zig` for auto-discovery
**Warning signs:** Test coverage decreasing despite new tests added

### Pitfall 5: Flaky Chaos Tests

**What goes wrong:** SIGKILL/partition tests fail intermittently
**Why it happens:** Race conditions in process lifecycle
**How to avoid:** Use deterministic VOPR for fault injection, not real processes
**Warning signs:** Chaos tests that "usually work" but fail in CI

### Pitfall 6: Performance Regression False Positives

**What goes wrong:** Benchmark tests fail due to normal variance
**Why it happens:** Tight threshold without accounting for CV
**How to avoid:** Use 2-sigma threshold (baseline + 2*std_dev), documented 5% CV
**Warning signs:** Benchmark failures without actual code changes

## Code Examples

### Test Context Setup (Established Pattern)

```zig
// Source: src/vsr/fault_tolerance_test.zig
const TestContext = struct {
    cluster: *Cluster,
    log_level: std.log.Level,
    client_requests: []usize,
    client_replies: []usize,

    pub fn init(options: struct {
        replica_count: u8 = 3,
        standby_count: u8 = 0,
        client_count: u8 = constants.clients_max,
        seed: u64 = 42,  // Fixed seed
    }) !*TestContext {
        // ... initialization
        const cluster = try Cluster.init(allocator, .{
            .cluster = .{
                .cluster_id = 0,
                .replica_count = options.replica_count,
                .seed = prng.int(u64),
                // ...
            },
        });
        // ...
    }

    pub fn deinit(t: *TestContext) void {
        std.testing.log_level = t.log_level;
        // ... cleanup
    }
};
```

### Network Partition Test (Established Pattern)

```zig
// Source: src/vsr/fault_tolerance_test.zig
test "FAULT-05: network partition isolates minority without data loss (R=3)" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit initial operations
    try c.request(5, 5);

    // Partition one replica
    t.replica(.B2).drop_all(.__, .bidirectional);

    // Continue committing - majority can still commit
    try c.request(10, 10);

    // Heal partition
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();

    // Verify convergence
    try expectEqual(t.replica(.R_).commit(), 10);
}
```

### VOPR Seed-Based Testing

```zig
// Source: src/vopr.zig
pub fn main() !void {
    const seed = seed_from_arg: {
        const seed_argument = cli_args.seed orelse break :seed_from_arg seed_random;
        break :seed_from_arg vsr.testing.parse_seed(seed_argument);
    };

    var prng = stdx.PRNG.from_seed(seed);
    var options = options_swarm(&prng);
    // Seed determines all random choices: network delays, fault injection, etc.
}
```

### CI Matrix Configuration

```yaml
# Source: .github/workflows/ci.yml
strategy:
  fail-fast: false
  matrix:
    include:
      - { os: 'ubuntu-latest', name: 'Linux x64' }
      - { os: 'macos-latest', name: 'macOS ARM64' }
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Real-time waits | Tick-based timing | Established | Deterministic timing assertions |
| Manual test discovery | Quine auto-generation | Established | No missing tests |
| Sequential CI | Matrix parallel runners | Established | 60-min CI achievable |
| Random seeds per run | Fixed seed 42 | Phase 2 | Reproducible failures |
| Quarantine flaky tests | Zero tolerance + fix | CONTEXT.md | No skipped tests |

**Deprecated/outdated:**
- N/A - Current patterns are aligned with TigerBeetle best practices

## Test Requirement Mapping

Based on TEST-01 through TEST-08 requirements and existing infrastructure:

| Requirement | Test Type | Location/Strategy |
|-------------|-----------|-------------------|
| TEST-01: Unit 100% | Unit tests | `unit_tests.zig` + quine discovery |
| TEST-02: Integration 100% | Integration tests | `integration_tests.zig` |
| TEST-03: VOPR 10+ seeds | Deterministic simulation | `.github/workflows/vopr.yml` |
| TEST-04: Stress 24h+ | Long-running stability | `scripts/benchmark-ci.sh --full` extended |
| TEST-05: Chaos tests | Fault injection | `fault_tolerance_test.zig` + shell scripts |
| TEST-06: Multi-node E2E | Cluster tests | `multi_node_validation_test.zig` |
| TEST-07: SDK tests | SDK integration | `.github/workflows/ci.yml` SDK jobs |
| TEST-08: Perf regression | Benchmark comparison | `.github/workflows/benchmark.yml` |

## CI Pipeline Architecture

### Recommended Matrix Strategy

```yaml
jobs:
  # Fast feedback tier (< 5 min)
  smoke:
    - license headers
    - formatting
    - quick build

  # Parallel test categories (< 20 min each)
  test-matrix:
    strategy:
      matrix:
        category:
          - unit        # test:unit
          - integration # test:integration
          - chaos       # fault_tolerance_test.zig subset
          - vopr-quick  # 5-minute VOPR smoke

  # SDK tests parallel (< 10 min each)
  sdk-matrix:
    matrix:
      language: [python, nodejs, java, go]

  # Long-running (separate workflow, not per-PR)
  vopr-full:
    # 2-hour VOPR runs
    # Scheduled daily

  stress-test:
    # 24-hour stability test
    # Scheduled weekly
```

### Time Budget (60-minute limit)

| Category | Estimated Time | Parallelization |
|----------|---------------|-----------------|
| Smoke | 2 min | Sequential (blocks others) |
| Unit tests | 10 min | 2 runners (Linux, macOS) |
| Integration | 15 min | 1 runner (requires Docker) |
| VOPR quick | 5 min | 2 runners (geo, testing) |
| SDK tests | 8 min | 4 runners (parallel languages) |
| **Total** | **~20 min** | Matrix parallel |

## Regression Threshold Implementation

Per CONTEXT.md decisions:

| Metric | Threshold | Implementation |
|--------|-----------|----------------|
| Throughput | 5% drop | `current < baseline * 0.95` |
| Latency P99 | 25% increase | `current > baseline * 1.25` |
| Baseline source | Release-locked | Stored as CI artifact |
| Block policy | Regression blocks merge | CI check required |

### Statistical Analysis

```bash
# Source: scripts/benchmark-ci.sh
# Threshold: baseline_mean + 2 * baseline_std
threshold=$(echo "$baseline_mean + 2 * $baseline_std" | bc)

if (( $(echo "$current_mean > $threshold" | bc -l) )); then
    echo "REGRESSION detected"
    exit 1
fi
```

## Open Questions

Things that couldn't be fully resolved:

1. **24-hour stress test infrastructure**
   - What we know: Scripts exist (`benchmark-ci.sh`), 7-min runs validated in Phase 5
   - What's unclear: Where to run 24+ hour tests (not GitHub Actions)
   - Recommendation: Document self-hosted runner or dedicated stress test server

2. **SDK test completeness**
   - What we know: SDK tests exist but currently skip without server
   - What's unclear: Full E2E SDK coverage requires running server
   - Recommendation: Spawn server in CI job before SDK tests

3. **VOPR seed selection strategy**
   - What we know: Fixed seed 42 for reproducibility, Git SHA for CI variance
   - What's unclear: How to select 10+ seeds for TEST-03
   - Recommendation: Use sequential seeds (42, 43, ..., 51) or hash-based derivation

## Sources

### Primary (HIGH confidence)

- `/home/g/archerdb/src/vsr/fault_tolerance_test.zig` - Established fault test patterns
- `/home/g/archerdb/src/vopr.zig` - VOPR deterministic simulator
- `/home/g/archerdb/src/testing/cluster.zig` - Cluster test infrastructure
- `/home/g/archerdb/.github/workflows/ci.yml` - Existing CI configuration
- `/home/g/archerdb/.github/workflows/vopr.yml` - VOPR CI workflow
- `/home/g/archerdb/src/unit_tests.zig` - Quine test manifest pattern

### Secondary (MEDIUM confidence)

- [TigerBeetle VOPR Documentation](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md) - VOPR architecture reference
- [TigerBeetle Vortex Blog](https://tigerbeetle.com/blog/2025-02-13-a-descent-into-the-vortex/) - Non-deterministic testing complement
- [GitHub Actions Matrix Builds](https://docs.github.com/en/actions/examples/using-concurrency-expressions-and-a-test-matrix) - CI parallelization patterns

### Tertiary (LOW confidence)

- [Ziggit Test Filtering Discussion](https://ziggit.dev/t/best-practices-for-filtering-tests/8937) - Community patterns
- [Flaky Test Prevention 2026](https://www.accelq.com/blog/flaky-tests/) - General flakiness prevention

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Existing codebase patterns verified
- Architecture: HIGH - Established patterns in actual code
- Pitfalls: HIGH - Documented in CONTEXT.md and STATE.md

**Research date:** 2026-01-31
**Valid until:** 60 days (stable infrastructure patterns)
