# Phase 17: Storage Validation & Adaptive Wiring - Research

**Researched:** 2026-01-25
**Domain:** Storage benchmarks, LSM compaction validation, adaptive compaction wiring (Zig + Python)
**Confidence:** MEDIUM

## Summary

Phase 17 focuses on validating storage optimization claims and ensuring adaptive compaction tuning is actually wired into runtime behavior. The repo already includes benchmark scripts (`scripts/benchmark-compression.py`, `scripts/benchmark-compaction.py`) and adaptive compaction logic (`src/lsm/compaction_adaptive.zig`) with recording hooks in `src/geo_state_machine.zig` and a sampling loop in `src/lsm/forest.zig`.

The open gaps are operational: benchmarks are currently in estimation mode unless the `archerdb` binary is built, and the compression benchmark lacks a clear runtime switch for uncompressed baselines. The adaptive state machine collects data and logs recommendations but its recommended parameters are not yet wired into the actual compaction configuration (no call sites use `Forest.adaptive_get_*` values).

**Primary recommendation:** Use the existing benchmark scripts with the real `archerdb` binary, and wire `AdaptiveState` outputs into the compaction configuration points (L0 trigger + compaction threads) so adaptation changes runtime behavior.

## Standard Stack

The established libraries/tools for this domain:

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig | 0.14.1 | Core storage/compaction implementation | Project language/runtime constraint |
| Python | 3.8+ | Benchmark automation scripts | Existing benchmark scripts rely on stdlib only |
| ArcherDB CLI | repo build | `archerdb benchmark` workload driver | Existing, project-standard benchmark entrypoint |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| stdlib (subprocess/json/dataclasses) | Python stdlib | Script orchestration, results export | Benchmark scripts (`scripts/benchmark-*.py`) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `archerdb benchmark` | Custom harness | More work, diverges from existing benchmark and metrics expectations |

**Installation:**
```bash
./zig/zig build
```

## Architecture Patterns

### Recommended Project Structure
```
scripts/
├── benchmark-compression.py   # Compression ratio validation
└── benchmark-compaction.py    # Leveled vs tiered compaction benchmark
src/lsm/
├── compaction_adaptive.zig    # Adaptive state machine
└── forest.zig                 # Compaction loop + adaptive sampling
src/
└── geo_state_machine.zig      # Workload recording hooks
```

### Pattern 1: Adaptive sampling in the compaction loop
**What:** The compaction loop triggers sampling and adaptation based on deterministic timestamps.
**When to use:** On each compaction beat, before executing compaction work.
**Example:**
```zig
// Source: src/lsm/forest.zig
forest.compaction_timestamp_ns = compaction_timestamp_ns;
forest.adaptive_sample_and_adapt(compaction_timestamp_ns);
```

### Pattern 2: Record workload signals in the state machine
**What:** Write/read/scan operations call `adaptive_record_*` in the state machine.
**When to use:** After writes, reads, or scans are executed, before returning results.
**Example:**
```zig
// Source: src/geo_state_machine.zig
if (deleted_count > 0) {
    self.forest.adaptive_record_write(deleted_count);
}
```

### Pattern 3: Adaptive recommendations with operator overrides
**What:** Adaptive state recommends parameters but respects operator overrides.
**When to use:** When computing compaction thresholds or thread counts.
**Example:**
```zig
// Source: src/lsm/compaction_adaptive.zig
return override orelse self.current_l0_trigger;
```

### Anti-Patterns to Avoid
- **Estimation-only benchmarks:** Running benchmark scripts without a built `archerdb` binary only yields theoretical results, not validation.
- **Adaptive state without wiring:** Sampling and logging without applying `AdaptiveState` recommendations to compaction parameters leaves auto-tuning inactive.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Storage benchmark harness | New custom harness | `scripts/benchmark-compression.py`, `scripts/benchmark-compaction.py` | Already matches roadmap success criteria and exports JSON |
| Workload generator | Ad-hoc test load | `archerdb benchmark` command | Reuses canonical benchmark path + output parsing |
| Adaptive workload detection | New heuristics | `src/lsm/compaction_adaptive.zig` | EMA smoothing, dual-trigger logic, guardrails already implemented |

**Key insight:** Existing scripts and adaptive state machine already encode the roadmap success criteria; the missing work is wiring and real execution, not new tooling.

## Common Pitfalls

### Pitfall 1: Benchmarks run in estimation mode
**What goes wrong:** Scripts fall back to theoretical models when `archerdb` is missing.
**Why it happens:** `check_archerdb_available()` returns none, causing `--dry-run` behavior.
**How to avoid:** Build `archerdb` and ensure the binary is available before running benchmarks.
**Warning signs:** Output notes "[Estimation Mode]" and JSON results have `"mode": "estimation"`.

### Pitfall 2: Compression benchmark lacks a real uncompressed baseline
**What goes wrong:** `benchmark-compression.py` runs two benchmarks but does not currently toggle compression, so "uncompressed" runs may still be compressed.
**Why it happens:** No CLI flags or config overrides are passed to disable compression.
**How to avoid:** Add a runtime flag or build-time toggle for uncompressed runs, or compute uncompressed size from the raw event bytes.
**Warning signs:** Compressed and uncompressed data file sizes are identical.

### Pitfall 3: Adaptive recommendations never affect compaction behavior
**What goes wrong:** Adaptive state updates but compaction parameters remain static.
**Why it happens:** `Forest.adaptive_get_l0_trigger()` / `adaptive_get_compaction_threads()` are not used in compaction configuration.
**How to avoid:** Wire adaptive getters into the compaction scheduling and L0 trigger logic.
**Warning signs:** Logs show workload changes but compaction behavior does not change.

## Code Examples

Verified patterns from repo sources:

### Compaction benchmark invocation (tiered)
```python
# Source: scripts/benchmark-compaction.py
bench_cmd = [archerdb_path, "benchmark", f"--count={event_count}"]
bench_cmd.extend(strategy_config["flags"])  # "tiered" uses ["--experimental"]
```

### Adaptive sampling in compaction loop
```zig
// Source: src/lsm/forest.zig
forest.adaptive_sample_and_adapt(compaction_timestamp_ns);
if (forest.adaptive_state.shouldAdapt(forest.adaptive_config)) {
    forest.adaptive_apply_recommendations();
}
```

### Workload recording hooks
```zig
// Source: src/geo_state_machine.zig
self.forest.adaptive_record_read(1);
self.forest.adaptive_record_scan(1);
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Static compaction parameters | Adaptive compaction state machine with EMA + dual-trigger | Phase 12 | Enables auto-tuning but still needs wiring to runtime parameters |

**Deprecated/outdated:**
- Manual-only compaction tuning: supplanted by adaptive configuration in `src/lsm/compaction_adaptive.zig`.

## Open Questions

1. **How to run compression benchmark with compression disabled?**
   - What we know: `scripts/benchmark-compression.py` does not pass a CLI flag to disable compression, and config has compression enabled by default.
   - What's unclear: Whether there is an existing CLI flag or build-time configuration to disable compression for benchmark runs.
   - Recommendation: Identify a supported toggle in CLI/config or update the benchmark to compute uncompressed sizes directly.

2. **Which runtime knobs should adaptive compaction control?**
   - What we know: `AdaptiveState` produces `l0_trigger` and `compaction_threads`, and `Forest.adaptive_get_*` exposes them.
   - What's unclear: Where L0 trigger and compaction thread counts are consumed in the LSM compaction scheduling path.
   - Recommendation: Locate the compaction configuration points and wire `Forest.adaptive_get_*` there.

## Sources

### Primary (HIGH confidence)
- `scripts/benchmark-compaction.py` - compaction benchmark logic and flags
- `scripts/benchmark-compression.py` - compression benchmark workload generation
- `src/lsm/forest.zig` - adaptive sampling and record hooks
- `src/lsm/compaction_adaptive.zig` - adaptive state machine and recommendations
- `src/geo_state_machine.zig` - workload recording calls
- `.planning/ROADMAP.md` - phase goals and success criteria

### Secondary (MEDIUM confidence)
- `.planning/phases/12-storage-optimization/12-10-PLAN.md` - intended benchmark behaviors
- `.planning/v2.0-v2.0-MILESTONE-AUDIT.md` - identified gaps driving Phase 17

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all components are in-repo and used by existing benchmarks.
- Architecture: MEDIUM - adaptive wiring points are defined but not yet connected to runtime behavior.
- Pitfalls: MEDIUM - derived from scripts and audit notes, but some runtime behavior needs confirmation.

**Research date:** 2026-01-25
**Valid until:** 2026-02-24
