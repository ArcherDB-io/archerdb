# Plan: Fix SDK parity and core issues

## Goals
- Run the official SDK integration script and parity runner end‑to‑end.
- Fix test runner gaps so Go/Java/C/Zig tests have a live cluster.
- Align cross‑SDK skip logic so parity reflects supported behavior.
- Address critical runtime issues found in review (spillover IDs, metrics output, start time, S3 timeouts, TLS revocation stubs).

## Assumptions
- Local toolchains are available (Python 3.11+, Node 20+, Go 1.21+, Java 21+, Zig bundled).
- We can build with `-Dconfig=lite` to stay within resource limits.
- “Full functionality & parity” means all supported operations pass fixtures; known limitations are explicitly tagged and skipped consistently.

## Plan
1) **Baseline setup**
   - Install required deps: `pip install -r test_infrastructure/requirements.txt`, `npm install` under `tests/sdk_tests/node`, `go mod download` under `tests/sdk_tests/go`, and Maven deps under `tests/sdk_tests/java`.
   - Build server: `./zig/zig build -j4 -Dconfig=lite`.

2) **Make SDK integration runner self‑contained**
   - Update `tests/sdk_tests/run_sdk_tests.sh` to start a single‑node cluster (via `test_infrastructure.harness`) before Go/Java/C/Zig runs, export `ARCHERDB_ADDRESS`/`ARCHERDB_URL`, and ensure cleanup via `trap` on exit.
   - Keep Python/Node tests as‑is (they start their own clusters on random ports), but avoid collisions by pinning the shared cluster to port 3001.

3) **Make parity runner self‑contained**
   - Add an optional `--start-cluster` (or `ARCHERDB_INTEGRATION=1`) path in `tests/parity_tests/parity_runner.py` to spin up a harness cluster, run parity tests against its URL, and shut it down.

4) **Align cross‑SDK skip logic**
   - Tag unsupported/known‑limitation cases in fixtures (e.g., `unsupported`, `boundary`, `invalid`, `concave`, `antimeridian`, `timestamp_filter`, `hotspot`).
   - Update all SDK tests and parity runner to skip based on tags (not name heuristics) so the same cases are excluded everywhere.

5) **Fix core correctness issues**
   - **Spillover** (`src/replication/spillover.zig`): track `max_segment_id` separately from `segment_count`, scan directory on init, and iterate recovery to max id to avoid ID reuse and missing segments.
   - **Metrics server** (`src/archerdb/metrics_server.zig`): use epoch time for `process_start_time_seconds`; write responses with a loop to handle partial writes.
   - **S3 client** (`src/replication/s3_client.zig`): apply `connect_timeout_ms`/`request_timeout_ms` to `std.http.Client` or request options.
   - **TLS revocation** (`src/archerdb/tls_config.zig`): replace mock OCSP response and unimplemented CRL fetch with real HTTP calls when URLs are provided; otherwise fail closed with explicit errors.

6) **Run tests and fix failures**
   - Zig unit tests: `./zig/zig build -j4 -Dconfig=lite test:unit`.
   - SDK integration script: `tests/sdk_tests/run_sdk_tests.sh` (expect 6/6 PASS).
   - Parity runner: `python tests/parity_tests/parity_runner.py --start-cluster` (expect 84/84 supported cells PASS).
   - Fix any remaining failures and re‑run relevant tests.

7) **Report results**
   - Summarize fixes, test outcomes, and any remaining known limitations explicitly (no unsupported cases hidden).
