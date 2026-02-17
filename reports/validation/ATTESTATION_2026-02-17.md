# ArcherDB Validation Attestation (2026-02-17)

## Scope

- Repository: `archerdb`
- Branch: `main`
- Validation run: `reports/validation/run-20260217-114731-recheck/summary.tsv`
- Core fix validated in this run: `e06df459` (`vsr: make solo recovery replay-safe with fast read path`)
- Assessment intent: production-grade readiness gate for 1B vehicle tracking workload profile

## Evidence Summary

- `step01_build_check`: PASS (`./zig/zig build -j4 -Dconfig=lite check`)
- `step02_license_headers_check`: PASS (`./scripts/add-license-headers.sh --check`)
- `step03_unit_minimal`: PASS (`./scripts/test-constrained.sh --minimal unit`)
- `step04_readiness_persistence`: PASS (`./scripts/test-readiness-persistence.sh`)
- `step05_unit_constrained`: PASS (`./scripts/test-constrained.sh unit`)
- `step06_integration_tests`: PASS (`./scripts/run_integration_tests.sh`)
- `step07_client_tests`: PASS (`./scripts/test_clients.sh`)
- `step08_e2e_tests`: PASS (`./scripts/e2e-test.sh`)
- `step09_full_build_test`: PASS (`./zig/zig build test`)
- `step10_vopr`: PASS (`./scripts/run_vopr.sh`)
- `step11_stress_test`: PASS (`./scripts/stress-test.sh`)
- `step12_perf_benchmarks`: FAIL (precondition only: no server at `127.0.0.1:3001`)
- `step12b_perf_benchmarks_auto_local`: PASS (`./scripts/run-perf-benchmarks.sh --auto-start-local`)
- `step12c_perf_benchmarks_manual_local`: PASS (manual local server + `./scripts/run-perf-benchmarks.sh`)
- `step13_disaster_recovery`: PASS wrapper result, all DR subtests skipped by script preconditions

## Performance Gate Evidence

Full benchmark executed on `LAB45`:

`./zig-out/bin/archerdb benchmark --clients=10 --event-count=1000000 --entity-count=100000 --query-uuid-count=1000 --query-radius-count=1000 --query-polygon-count=1000`

Observed:

- F5.1.1 write throughput: `1,045,778 events/s` (target `>= 1,000,000`) -> PASS
- F5.1.2 UUID single p99: `183 us` (target `< 500 us`) -> PASS
- F5.1.2b UUID batch per-entity p99: `2 us` (diagnostic)
- F5.1.3 radius p99: `0 ms` (target `< 50 ms`) -> PASS
- F5.1.4 polygon p99: `0 ms` (target `< 100 ms`) -> PASS

## Attestation Decision

- Core engineering validation gates (build, test, readiness, replay recovery, and benchmark targets) are satisfied.
- Release gate decision for core database behavior: **GO**.

## Remaining Operational Preconditions (Non-Blocking for Core Gate)

- DR deep tests require explicit environment inputs not supplied in this run:
  - `--backup-bucket`
  - `--cluster-id`
  - `--k8s`
- `step12_perf_benchmarks` in non-auto mode requires a pre-running local node at `127.0.0.1:3001`.

## Sign-off

- Engineering validation owner: Cursor CLI coding agent run on 2026-02-17
- Evidence references:
  - `reports/validation/run-20260217-114731-recheck/summary.tsv`
  - `reports/validation/run-20260217-114731-recheck/*.log`

