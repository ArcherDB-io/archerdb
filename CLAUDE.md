# Pre-Commit Testing Requirements

**CRITICAL**: Before running `git commit` or `git push`, the following checks run automatically
via the hook in `.claude/hooks/pre-commit-check.sh`:

1. **Build check**: `./zig/zig build -j4 -Dconfig=lite` - catches compilation errors
2. **License headers**: `./scripts/add-license-headers.sh --check` - ensures headers present
3. **Quick unit tests**: Runs a representative test subset

If any check fails, the commit is **BLOCKED**. Fix the issue first:
- Build failures: Fix compilation errors
- License headers: Run `./scripts/add-license-headers.sh`
- Test failures: Debug and fix the failing tests

# Resource-Constrained Testing

This server has limited resources (24GB RAM, 8 cores, no swap). Use these flags to prevent OOM:

## Quick Reference

| Profile | Command | RAM | Cores | Use Case |
|---------|---------|-----|-------|----------|
| Minimal | `-j2 -Dconfig=lite` | ~2GB | 2 | Heavy load on server |
| Constrained | `-j4 -Dconfig=lite` | ~4GB | 4 | Normal development |
| Full | (default) | ~8GB+ | 8 | CI or dedicated machine |

## Helper Script

```bash
./scripts/test-constrained.sh unit              # Default: -j4, lite
./scripts/test-constrained.sh --minimal unit    # Minimal: -j2, lite
./scripts/test-constrained.sh --full unit       # Full resources
./scripts/test-constrained.sh check             # Quick compile check only
```

## Direct Zig Commands

```bash
# Constrained (recommended for this server)
./zig/zig build -j4 -Dconfig=lite test:unit
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "encryption"

# Minimal (when server is under heavy load)
./zig/zig build -j2 -Dconfig=lite test:unit

# Just compile check (fastest, no tests)
./zig/zig build -j4 -Dconfig=lite check
```

## Build Configurations

- **lite**: Demo/evaluation tier. Fast and lightweight, with intentionally strict data limits.
- **standard**: Baseline production tier.
- **pro**: Higher-performance tier for moderate production hardware.
- **enterprise**: High-end production tier for maximum throughput.
- **ultra**: Highest-capacity profile. Shares the high-performance runtime with standard/pro/enterprise; differs only in RAM index ceiling (64 GiB) and storage ceilings (16 TiB default / 64 TiB max). Use only when enterprise-tier capacity is insufficient for the workload.

## Tier Product Strategy

These rules are intentional product-positioning constraints and should be preserved:

- `lite` is the public demo/trial experience (downloadable and easy to run).
- `lite` must feel fast on first run: prioritize startup speed, responsiveness, and low footprint.
- `lite` must remain intentionally storage-limited (do not relax capacity caps without explicit approval).
- Higher tiers (`standard` -> `pro` -> `enterprise` -> `ultra`) should scale capability/resources progressively.
- Do not add legacy/alternate config aliases; keep canonical tier names only.

When changing tier defaults, always update `docs/tier-profiles.md` and any user-facing tier docs.

## Targeted Tests

Run targeted tests for areas you modified:
```bash
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "encryption"
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "parse_args"
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "error_codes"
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "sharding"
```

GitHub CI runs the full test suite - if CI fails but local checks passed, run the full
suite locally to reproduce: `./zig/zig build test:unit`
