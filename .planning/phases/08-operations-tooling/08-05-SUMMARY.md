---
phase: 08
plan: 05
subsystem: operations-cli
tags: [upgrade, rollback, health-check, cli, operations]
requires: [08-01, 08-02]
provides: [upgrade-cli, rollback-support, health-monitoring]
affects: [09-documentation]
tech-stack:
  added: []
  patterns: [health-based-rollback, rolling-upgrade, cli-orchestration]
key-files:
  created:
    - src/archerdb/upgrade.zig
    - docs/upgrade-guide.md
  modified:
    - src/archerdb/cli.zig
    - src/archerdb/main.zig
decisions:
  - id: 08-05-01
    title: Use integer thresholds for CLI compatibility
    choice: p99-threshold-x10 and error-threshold-x10 as u32
    rationale: Zig flags parser doesn't support f64, multiply by 10 for decimal precision
  - id: 08-05-02
    title: Health-based rollback default thresholds
    choice: 2.0x P99 latency, 1.0% error rate, 3 probe failures
    rationale: Conservative defaults that detect significant degradation without false positives
metrics:
  duration: 8min
  completed: 2026-01-31
---

# Phase 08 Plan 05: Upgrade CLI and Rollback Tooling Summary

**One-liner:** Rolling upgrade CLI with health-based rollback triggers supporting followers-first/primary-last order

## What Was Built

### 1. Upgrade Orchestration Module (upgrade.zig)

Created comprehensive upgrade orchestration logic:

- **HealthThresholds struct**: Configurable P99 latency multiplier, error rate threshold, probe failure count, catchup timeout
- **UpgradeOptions struct**: Addresses, target version, dry-run mode, health thresholds, metrics port
- **UpgradeState enum**: State machine for upgrade lifecycle (not_started -> preflight_checks -> upgrading_followers -> upgrading_primary -> completed)
- **ReplicaInfo struct**: Address, replica_id, is_primary, version, healthy, role, commit_sequence
- **Upgrader struct**: Main orchestrator with execute(), checkHealth(), rollback(), pause(), resume()

Key functions implemented:
- `runPreflightChecks()`: Validates connectivity, version compatibility, cluster quorum
- `identifyPrimary()`: Discovers primary replica before upgrade starts
- `upgradeReplica()`: Handles individual replica upgrade with health monitoring
- `checkHealth()`: Returns HealthStatus with rollback decision
- `rollback()`: Reverts upgraded replicas in reverse order

### 2. CLI Upgrade Command

Added complete upgrade subcommand to cli.zig:

- **status**: Show cluster versions, identify primary, display upgrade readiness
- **start**: Begin rolling upgrade with target version and health thresholds
- **pause**: Pause in-progress upgrade between replicas
- **resume**: Resume paused upgrade
- **rollback**: Manual rollback with --force confirmation

CLI options:
- `--addresses`: Cluster replica addresses (required)
- `--target-version`: Version to upgrade to (required for start)
- `--dry-run`: Show upgrade plan without changes
- `--p99-threshold-x10`: P99 latency multiplier (default: 20 = 2.0x)
- `--error-threshold-x10`: Error rate percentage (default: 10 = 1.0%)
- `--catchup-timeout`: Replica catchup timeout (default: 300s)
- `--metrics-port`: Health probe port (default: 9100)

### 3. Upgrade Guide Documentation (505 lines)

Comprehensive upgrade procedures covering:

- **Overview**: Rolling upgrade philosophy, upgrade order rationale
- **Pre-Upgrade Checklist**: Required and recommended checks before upgrade
- **Version Compatibility**: TigerBeetle model, compatibility matrix
- **Bare Metal Upgrade**: Step-by-step manual procedure
- **Kubernetes Upgrade**: StatefulSet-based rolling update procedure
- **Health-Based Rollback**: Trigger conditions, threshold customization
- **Manual Rollback**: Bare metal and Kubernetes rollback procedures
- **Post-Upgrade Verification**: Health checks, performance validation
- **Troubleshooting**: Common issues and solutions
- **CLI Reference**: Full command documentation

## Technical Decisions

### Decision 08-05-01: Integer Thresholds for CLI

**Context:** Zig's flags parser doesn't support f64 types

**Decision:** Use `--p99-threshold-x10` and `--error-threshold-x10` as u32, multiply by 10 for decimal precision

**Example:** `--p99-threshold-x10=25` means 2.5x baseline

### Decision 08-05-02: Health Rollback Defaults

**Context:** Need conservative defaults that catch real problems without false positives

**Decision:**
- P99 latency: 2.0x baseline triggers rollback
- Error rate: 1.0% triggers rollback
- Probe failures: 3 consecutive failures trigger rollback
- Catchup timeout: 300 seconds (5 minutes)

**Rationale:** These thresholds allow normal variance while catching significant degradation

## Commits

| Hash | Type | Description |
|------|------|-------------|
| d706107 | feat | Add upgrade orchestration module and CLI command |
| 18a2e4b | docs | Create comprehensive upgrade guide |

## Verification Results

All verification criteria passed:

1. **Build check**: `./zig/zig build -j4 -Dconfig=lite check` succeeds
2. **upgrade.zig has required components**:
   - UpgradeOptions with health thresholds (5 references)
   - Primary identification (3 references)
   - Health checking (HealthStatus, checkHealth)
   - Rollback logic (56 references)
3. **CLI has upgrade subcommand**: status, start, pause, resume, rollback options (18 references)
4. **docs/upgrade-guide.md**:
   - Pre-upgrade checklist (section present)
   - Manual and Kubernetes procedures (both documented)
   - Rollback triggers and procedures (24 rollback references)
   - Post-upgrade verification (section present)
   - Cross-reference to operations-runbook.md (2 references)

## Success Criteria Validation

| Requirement | Status | Evidence |
|-------------|--------|----------|
| OPS-07: Upgrade N to N+1 documented | PASS | docs/upgrade-guide.md with CLI tooling |
| OPS-08: Rollback procedure | PASS | Health-based triggers + manual rollback |
| Health-based rollback triggers | PASS | P99 latency, error rate, probe failures |
| Followers first, primary last | PASS | identifyPrimary() + upgrade order logic |
| Bare metal documentation | PASS | Step-by-step procedure in guide |
| Kubernetes documentation | PASS | StatefulSet procedure in guide |

## Deviations from Plan

None - plan executed exactly as written.

## Files Changed

```
src/archerdb/upgrade.zig      (created, 892 lines)
src/archerdb/cli.zig          (modified, +258 lines)
src/archerdb/main.zig         (modified, +126 lines)
docs/upgrade-guide.md         (created, 505 lines)
```

## Next Steps

- **08-06**: Phase verification to validate all OPS requirements
- Future: Integration tests for upgrade scenarios
- Future: Kubernetes operator integration for automated upgrades
