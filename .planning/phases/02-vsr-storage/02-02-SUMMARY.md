---
phase: 02-vsr-storage
plan: 02
subsystem: testing
tags: [vopr, durability, crash-recovery, fault-injection]
dependency-graph:
  requires: [01-03]
  provides: [vopr-replay, durability-verification, crash-testing]
  affects: [02-03, 02-04, 10-reliability]
tech-stack:
  added: []
  patterns: [deterministic-simulation, fault-injection, crash-testing]
key-files:
  created:
    - scripts/dm_flakey_test.sh
    - scripts/sigkill_crash_test.sh
    - docs/durability-verification.md
  modified:
    - src/vopr.zig
    - src/testing/storage.zig
    - scripts/run_vopr.sh
decisions:
  - id: D-0202-01
    choice: Use VOPR for crash recovery verification instead of standalone tests
    rationale: VOPR already has comprehensive fault injection infrastructure
    alternatives: [custom-crash-test-framework, jepsen-style-testing]
  - id: D-0202-02
    choice: dm-flakey for Linux-only power-loss testing, SIGKILL for cross-platform
    rationale: dm-flakey provides kernel-level block failure simulation
    alternatives: [qemu-fault-injection, custom-io-wrapper]
  - id: D-0202-03
    choice: Decision history with circular buffer of 1000 entries
    rationale: Balance between memory usage and debugging utility
    alternatives: [unbounded-history, file-based-logging]
metrics:
  duration: 31 min
  completed: 2026-01-22
---

# Phase 02 Plan 02: Durability Verification Summary

**One-liner:** Extended VOPR with deterministic replay, verified WAL/checkpoint recovery via fault injection, created dm-flakey and SIGKILL crash testing infrastructure.

## What Was Done

### Task 1: Extend VOPR with deterministic replay

Added new capabilities to VOPR for debugging and verification:

**New CLI flags:**
- `--replay`: Enable deterministic replay mode with full debug logging
- `--replay-from-tick <N>`: Skip to specific tick (future implementation hook)
- `--dump-on-fail`: Dump decision history on failure
- `--crash-rate <N>`: Set crash fault probability as percentage (0-100)
- `--replicas <N>`: Test specific cluster sizes (1-6)

**Decision history tracking:**
- `DecisionHistory` struct with circular buffer of 1000 entries
- Records: tick number, decision type, and parameters
- Decision types: tick_start, request_sent, crash_replica, restart_replica
- Dumps to stderr on failure for post-mortem debugging

**Script updates:**
- `run_vopr.sh` updated with `--replay`, `--dump-on-fail`, `--crash-rate`, `--replicas`
- Replay mode uses `-Dvopr-log=full` for maximum debug output

### Task 2: Verify WAL replay and checkpoint recovery

**Documentation added to `src/testing/storage.zig`:**
- Documented fault injection presets (standard and high-stress)
- Explained fault types (read, write, misdirect, crash)
- Listed recovery scenarios tested by fault injection

**VOPR verification runs completed:**
- 3-node cluster with 1000 requests: PASSED
- 5-node cluster with 500 requests: PASSED
- 5% crash rate with 100 requests: PASSED
- Multiple seeds tested for determinism

### Task 3: Create power-loss simulation tests

**dm_flakey_test.sh (324 lines):**
- Linux-only dm-flakey power-loss testing
- Creates loop device and dm-flakey target
- Supports drop_writes mode for torn write simulation
- Includes safety checks (refuses to run on potential production systems)
- Requires root privileges

**sigkill_crash_test.sh:**
- Cross-platform (Linux and macOS)
- Tests deterministic recovery after SIGKILL
- Runs VOPR with known seed, kills, verifies replay
- Configurable iterations and timeout

**docs/durability-verification.md (273 lines):**
- Comprehensive methodology documentation
- Explains VOPR, SIGKILL, and dm-flakey approaches
- Coverage matrix (what is/isn't tested)
- CI integration guidance
- Debugging and reproduction instructions

## Key Artifacts

| Artifact | Purpose | Lines |
|----------|---------|-------|
| `src/vopr.zig` | Extended with replay mode and decision history | +200 |
| `scripts/run_vopr.sh` | Updated with new options | +30 |
| `scripts/dm_flakey_test.sh` | Linux power-loss testing | 324 |
| `scripts/sigkill_crash_test.sh` | Cross-platform crash testing | 253 |
| `docs/durability-verification.md` | Verification methodology | 273 |
| `src/testing/storage.zig` | Fault injection documentation | +37 |

## Verification Results

| Test | Configuration | Result |
|------|---------------|--------|
| VOPR replay | seed=42, requests=50 | PASSED |
| VOPR crash rate | crash-rate=1, requests=200 | PASSED (2.3M ticks) |
| VOPR 5-node | replicas=5, requests=200 | PASSED (2.3M ticks) |
| SIGKILL test | iterations=2, timeout=30 | PASSED |
| Documentation | durability-verification.md | 273 lines |

## Deviations from Plan

None - plan executed exactly as written.

## Next Phase Readiness

**Blockers:** None

**Dependencies satisfied for:**
- Plan 02-03: LSM Optimization (builds on VOPR infrastructure)
- Plan 02-04: Encryption Verification (can use fault injection)

**Technical debt:** None introduced

## Commits

| Hash | Type | Description |
|------|------|-------------|
| 6aeb9db | feat | Extend VOPR with deterministic replay |
| 8d60386 | docs | Document fault injection for durability verification |
| 7f5c8ee | feat | Create power-loss simulation tests |
