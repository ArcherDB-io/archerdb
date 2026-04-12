# ArcherDB Finalization Plan

Date: 2026-04-07

## Objective

Finalize ArcherDB as a release-honest geospatial database by:

- closing the remaining runtime gaps that can corrupt operator expectations,
- removing simulated-success paths from durability and upgrade workflows,
- upgrading SDK/parity coverage from placeholder to executable evidence,
- and attaching every product claim to a repeatable validation artifact.

## Exit Criteria

ArcherDB is only considered finalized when all of the following are true:

1. Every GA feature has a real implementation, not a placeholder or simulated-success path.
2. Every GA claim is backed by executable tests, logs, or benchmark artifacts produced from the current commit.
3. The operator surface fails closed on missing infrastructure instead of pretending success.
4. SDK parity is proven by runnable parity suites for all supported SDKs.
5. Release tooling publishes the same artifacts that were built and verified.

## Confirmed Gap Inventory

### P0: Runtime And Durability

- Live backup upload orchestration is not wired into the running `start` path.
- `S3RelayTransport` can silently simulate uploads and return success.
- Upgrade orchestration still uses simulated discovery, role detection, and health probing.
- Multi-region server flags are parsed but rejected as unimplemented.
- Restore checksum verification is incomplete for local block validation.
- Snapshot metadata/query plumbing is incomplete in checkpoint/LSM paths.

### P1: Operator And Data Paths

- CSV import is still a placeholder.
- `inspect` cannot decode all block and operation types.
- Internal CDC runner does not actually publish to AMQP.
- OTLP trace export omits span events.
- Breach-notification template substitution is incomplete.
- TLS CRL parsing is simplified rather than full ASN.1/X.509.

### P2: SDK, Parity, And Validation

- Python SDK skips group-filter and timestamp-filter parity cases.
- Java parity runner is still placeholder code.
- Java multi-region routing is skeletal.
- Java and Node unit tests still lean on skeleton-mode paths.
- Vortex network fault injection is missing duplication, reordering, and rate limiting.
- Vortex workload generation still uses fake S2 IDs rather than proper geometry.
- Durability automation still has declared blind spots: full disk, kernel crash, hardware corruption, WAN latency.
- Java release publishing rebuilds and uploads a different artifact than the verified dist output.

## Execution Strategy

### Tranche 0: Fail Closed, Truthful Defaults

Purpose:
- Remove any path that reports success without real side effects.

Implementation:
- Make replication S3 relay fail closed unless explicitly configured for test-only simulation.
- Reject incomplete backup runtime config at startup instead of accepting dead flags.
- Narrow docs and CLI help where a feature is not yet live.

Validation:
- Unit tests for missing-credentials, bad-endpoint, and upload-failure behavior.
- Integration test proving upload failure surfaces to caller.
- Startup tests proving invalid backup config is rejected.

Release gate:
- No simulated-success upload path remains enabled by default.

### Tranche 1: Backup And Restore Completeness

Purpose:
- Make backup/restore an actual product feature, not a library of disconnected modules.

Implementation:
- Wire backup queue/coordinator/state into the live replica runtime.
- Attach queue enqueue points to the closed-block / durable-block lifecycle.
- Add a dedicated runtime module owned by `command_start()` to instantiate backup config, queue, coordinator, state persistence, and upload ticking.
- Extend the `Replica` event callback path with a durability event so the runtime can release buffered block refs only after checkpoint durability.
- Start with `local` provider first; reuse the same runtime path for S3/GCS/Azure only after the local end-to-end flow is proven.
- Run an uploader loop that persists progress and respects queue mode.
- Upgrade restore checksum verification from header readability to real block checksum validation.
- Add end-to-end backup->restore tests against local and S3-compatible storage.

Validation:
- Unit tests for queue backpressure, primary/follower-only behavior, resume after restart.
- Integration test: start node with backups enabled, generate writes, verify objects appear remotely.
- Integration test: restore from produced backup and compare imported block sequences/checksums.
- Failure tests: missing credentials, object-store outage, mandatory-mode queue saturation.

Release gate:
- Backup-enabled runtime produces real remote objects.
- Restore rejects corrupted backup blocks.

### Tranche 2: Operator Control Plane

Purpose:
- Make operator commands interrogate real cluster state rather than simulated state.

Implementation:
- Upgrade `upgrade.zig` to use real health/status probing and primary detection.
- Reuse existing health/metrics/coordinator endpoints instead of synthetic replica metadata.
- Implement CSV import path.
- Extend `inspect` coverage for the remaining block/op types.
- Decide whether multi-region server flags are GA now or explicitly deferred. If GA, plumb them fully; if not, remove them from GA-facing documentation and release claims.

Validation:
- Unit tests for health-response parsing and primary detection.
- Integration test: rolling upgrade dry-run against a live local cluster with real status reads.
- Import tests for CSV happy-path and malformed rows.
- Focused output checks for `inspect` decode paths, exercised via a dedicated `zig test` invocation for `src/archerdb/inspect.zig`.

Release gate:
- Upgrade status/start/rollback paths observe real node state.
- No operator command prints `unimplemented` for supported GA workflows.

### Tranche 3: CDC, Observability, Security Hardening

Purpose:
- Close the remaining partially implemented operational features.

Implementation:
- Switch CDC runner batch flush from placeholder logic to real AMQP publish calls.
- Export span events in OTLP payloads.
- Complete breach-template variable substitution.
- Replace simplified CRL parsing with a correct parser or downgrade feature claims if full parsing is out of scope.

Validation:
- Broker-backed integration test for CDC publish and reconnect behavior.
- OTLP payload golden tests including events/links.
- Template rendering tests for every notification variable.
- CRL parse tests with valid, revoked, malformed, and unsupported inputs.

Release gate:
- CDC emits real messages under integration test.
- Security/observability features match documented behavior.

### Tranche 4: SDK And Parity Closure

Purpose:
- Ensure the public client surface is actually proven across languages.

Implementation:
- Remove stale Python and Node fixture skips where filter support already exists.
- Replace Java parity placeholder fallback with a real degraded runner path or an explicit hard failure.
- Keep skeleton-mode unit tests, but relabel them honestly as unit/wire-format coverage rather than integration evidence.
- Tighten Java multi-region routing or mark it non-GA.

Validation:
- Fresh parity artifact covering C, Go, Java, Node, and Python.
- Per-SDK smoke suite against a live single-node cluster.
- Per-SDK edge-case suite for invalid inputs, TTL, ordering, and pagination.
- Focused reruns of the previously skipped Python/Node filter fixtures before the full parity sweep.

Release gate:
- No parity runner returns placeholder output.
- No GA SDK surface is only covered in skeleton mode.

### Tranche 5: Verification Fidelity And Release Evidence

Purpose:
- Upgrade confidence from “unit-tested” to “operationally proven”.

Implementation:
- Expand Vortex faults to include duplication, reordering, and rate limiting.
- Replace fake S2 IDs in workload generation with real geometry-derived IDs where correctness matters.
- Fix Java release publishing to deploy the verified artifact rather than a rebuilt substitute.
- Regenerate the release evidence bundle from the current commit.

Validation:
- Chaos/fault regression suite for the new Vortex modes.
- Benchmark and workload correctness checks with stored artifacts.
- Release rehearsal proving artifact identity from build to publish.

Release gate:
- Release evidence bundle is complete and reproducible.

## Validation Matrix

### Core Correctness

- Unit: geo operations, TTL, sharding, serialization, checksum validation.
- Integration: single-node inserts/queries/import/export/status/verify.
- Distributed: 3-node and 5-node failover, view change, replica restart, read-after-failover.

### Durability

- Unit: backup queue, coordinator, checksum validators, restore timestamp filtering.
- Integration: backup upload, restore, crash recovery, WAL replay.
- Fault injection: object-store outage, queue saturation, partial upload, corrupt block, dm-flakey on Linux.

### SDK

- Per-SDK smoke: connect, insert, query-latest, radius query, delete, ttl-set/extend/clear, status.
- Parity: fixture-driven comparison for all GA operations.
- Negative tests: invalid coordinates, malformed polygons, oversized batches, timeout/retry behavior.

### Operator Surface

- CLI golden tests for help/output/error semantics.
- Live tests for upgrade status, verify, import, export, coordinator status, shard/ttl management.
- Text and JSON output parsing checks.

### Performance And Benchmarks

- Reproducible benchmark runs with retained raw JSON/CSV.
- Hardware/profile metadata captured with each artifact.
- Separate “developer quick run” and “release candidate run” profiles.

## Required Artifacts Per Release Candidate

- `reports/parity.json`
- benchmark raw outputs and summaries
- topology/failover logs
- durability run logs
- backup/restore integration logs
- SDK smoke summaries
- release artifact manifest with checksums

## Immediate Closure Queue

These are the next blocking tasks in strict execution order. The repo is not finalized until each item is either completed or explicitly de-scoped from GA with matching docs and tests.

1. Startup stability
- Reproduce the current single-node startup blocker from a clean formatted file.
- Identify the exact initialization stage where the process stops progressing after early startup logs.
- Land the smallest safe fix and re-run `start` plus `/health/ready`.

2. Exact local backup runtime
- Replace the current approximate free-set scan in [backup_runtime.zig](/home/g/archerdb/src/archerdb/backup_runtime.zig) with exact checkpoint-rooted block enumeration.
- Use durable checkpoint trailers, manifest reconstruction, index-block decoding, and checksum-addressed block reads.
- Re-run live local backup smoke only after startup stability is green.

3. Restore integrity completion
- Keep local block checksum validation strict.
- Add corruption tests for `.block`, `.ts`, and metadata sidecars.
- Re-run PITR coverage against locally produced backup artifacts.

4. Operator control-plane closure
- Finish real upgrade flow beyond discovery/probing.
- Implement CSV import.
- Keep `inspect` decode coverage and unit wiring current as new supported block/op types are added.
- Decide and enforce the multi-region GA boundary in code and docs.

5. CDC, observability, and security
- Replace CDC placeholder batch flush with real publish behavior.
- Add OTLP span events.
- Complete breach-template rendering.
- Replace or de-scope simplified CRL parsing.

6. SDK and parity proof
- Re-run the newly unskipped Python and Node cases live.
- Refresh parity artifacts from the current commit.
- Relabel skeleton-only tests honestly.
- Tighten or de-scope Java multi-region routing.

## Detailed Task Board

Status legend:
- `done`: implemented and locally validated on the current commit.
- `in_progress`: code exists or partial proof exists, but at least one correctness gap remains.
- `queued`: not started or only analyzed.

### Track A: Startup And Durability

1. Startup and ready-state stability
- Status: `done`
- Scope: single-node `start`, `/health/ready`, metrics initialization, admin smoke.
- Validation: live startup on a freshly formatted file, health endpoint check.

2. Local backup runtime wiring
- Status: `done`
- Scope: `command_start()` ownership, queue/coordinator/state wiring, `.checkpoint_durable` event hookup, local provider upload loop, persisted sequence state, metrics.
- Validation: live node with `--backup-enabled --backup-provider=local`, imported workload, metrics/logs, produced `.block/.ts/.meta` artifacts.

3. Exact checkpoint-rooted backup scan
- Status: `done`
- Scope: free-set trailer traversal, client-sessions traversal, manifest chain walk, index/value block discovery, duplicate suppression.
- Validation: live backup repro with first-checkpoint workload plus logs proving non-zero uploads and no skipped references.

4. Restore integrity
- Status: `in_progress`
- Scope: local/S3/GCS/Azure listing, timestamp PITR, `.ts`/`.meta` parsing, local checksum verification, block download/write path.
- Progress:
  - backup runtime now persists a durable `.ckpt` sidecar after all referenced block sequences are durably uploaded
  - `RestoreManager` now selects the latest covered checkpoint artifact during local restore/PITR and the S3-compatible remote restore path has direct checkpoint-selection proof
  - restore now writes blocks back to their original grid offsets when address metadata is present
  - remote S3-compatible restore is now validated with `.meta` sidecars that drive addressed grid writes, while sidecar-light flows still preserve append-mode fallback
  - restore now synthesizes real superblock copies from the chosen checkpoint artifact instead of leaving `writeSuperblock()` as a stub
  - restore now writes a bootable WAL scaffold from durable checkpoint plus view-header metadata instead of leaving the restored file with an empty journal zone
  - restore journal synthesis now fills the contiguous in-journal prepare-header window needed by standalone-primary startup, instead of only checkpoint/head stubs
  - restored data files now prove openable under the real file-backed `Replica.open()` path for a clustered replica artifact
- restored local backup artifacts now prove bootable through the real `archerdb start` path for a standalone restored file
- Remaining work: add provider-specific live proof where only shared-path coverage exists.
- Validation: `RestoreManager` unit suite, `DurableCheckpointArtifact` round-trip test, local and remote S3-compatible checkpoint-selection tests, addressed-grid write test, remote S3-compatible addressed-grid restore test, restore-superblock write test, restore boot proof under `Replica.open()`, exact local backup-artifact round-trip integration, and a targeted `archerdb start` integration smoke on a restored file.

5. Live remote backup providers
- Status: `queued`
- Scope: S3/GCS/Azure runtime upload orchestration through the same runtime path as local.
- Validation: provider-backed integration tests with object listing and restore.

### Track B: Operator Control Plane

6. CSV import
- Status: `done`
- Scope: real CSV parsing, header detection, strict required fields, `--batch-size` enforcement.
- Validation: `CsvImporter` unit suite plus live import with multiple batches.

7. Rolling upgrade control plane
- Status: `done`
- Scope: live discovery/primary detection/status probing are real, JSON status output is implemented, and the supported GA surface is now explicitly `upgrade status` plus `upgrade start --dry-run`. Live rollout, pause/resume state, and rollback actuation are owned by external deployment tooling rather than the ArcherDB CLI.
- Validation: focused `upgrade.zig` unit tests plus live CLI integration for `upgrade status --format=json` and fail-closed/non-GA mutation verbs.

8. Cluster membership mutation
- Status: `done`
- Scope: `cluster status` reports real per-node membership state through `archerdb_get_status`, and live membership mutation is explicitly de-scoped from the current GA runtime surface because the underlying VSR/message-bus stack does not yet support honest dynamic membership changes.
- Blocking detail:
  - `vsr.ReconfigurationRequest` currently only permits permutations of the existing member set with unchanged replica/standby counts.
  - the live message-bus topology is allocated from startup `--addresses` and does not admit new peers at runtime.
  - `membership_config` is an in-memory overlay and is not the consensus/persistence source of truth.
- Validation: real `cluster status` integration proof plus explicit fail-closed behavior and docs/CLI help narrowed to the supported static-membership boundary.

9. Index resize control
- Status: `done`
- Scope: `index resize status` now reports real per-node resize state and progress through `archerdb_get_status`; `index resize start` and `index resize abort` use a live metrics/control actuator plus startup-loop sweeper. `start` also now accepts `--index-resize-batch-size` to throttle resize work per tick.
- Validation: live CLI proof against `TmpArcherDB` for `start/status/abort`, plus compile coverage.

10. Multi-region server runtime
- Status: `done`
- Scope: either fully plumb server-side multi-region flags or remove them from the GA runtime surface.
- Validation: startup config test plus documented/implemented boundary.

11. Inspect decoder completeness
- Status: `done`
- Scope: current supported block/op surfaces no longer emit `unimplemented`; reserved/future/corrupt fallbacks are labeled honestly, and reserved VSR operations no longer panic the variable-body decoder path.
- Validation: focused `src/archerdb/inspect.zig` module tests over representative WAL/checkpoint decoders plus enum-walk regression coverage for current VSR and ArcherDB operations.

### Track C: CDC, Observability, Security

12. CDC publish path
- Status: `done`
- Scope: replace placeholder AMQP flush logic with real publish/retry/reconnect behavior.
- Validation: broker-backed RabbitMQ test proving published JSON reaches a real queue.

13. OTLP span events
- Status: `done`
- Scope: include span events in exported OTLP payloads instead of serializing empty arrays.
- Validation: golden payload tests and collector compatibility check.

14. Breach notification templating
- Status: `done`
- Scope: substitute all documented variables instead of returning templates verbatim.
- Validation: rendering tests for every notification variant.

15. TLS CRL parsing
- Status: `done`
- Scope: explicitly narrow the supported feature surface and fail closed if in-process revocation checking is enabled.
- Validation: `tls: init rejects non-GA revocation checking` plus existing low-level CRL/OCSP helper tests.

### Track D: SDK, Parity, And Release Evidence

16. Python and Node parity reruns
- Status: `in_progress`
- Scope: stale skips are removed, the active Node harness now supports `ARCHERDB_ADDRESS` to bypass the brittle Python bootstrap, bootstrap failures surface immediately instead of timing out blindly, and the `query_latest` group-filter case now checks membership as well as count. The parity CLI now starts fixture-aware local clusters for topology cases instead of forcing all cases through a single-node cluster, waits for topology queryability instead of full `/health/ready` on large topology cases, skips stopped-node endpoints after leader failover, and no longer pulls in an undeclared `tenacity` dependency through topology helpers. The topology operation is now green across single-node, 3-node, 5-node, leader-failover, and unhealthy-node cases on the current commit. The remaining work is a fresh full parity sweep and artifact refresh across all SDKs.
- Validation: focused Python/Node fixture reruns, managed multi-node cluster topology proof, then full parity sweep.

17. Java parity runner
- Status: `in_progress`
- Scope: placeholder degraded fallback removed; still need current-commit parity artifact through the real runner.
- Validation: generated `reports/parity.json`.

18. Java multi-region client honesty
- Status: `done`
- Scope: tighten routing semantics or de-scope the feature from GA docs/tests.
- Validation: routing unit tests and docs alignment.

19. Skeleton-mode unit test labeling
- Status: `done`
- Scope: relabel Node/Java skeleton tests so they are not presented as integration evidence.
- Validation: doc/test naming pass and CI/report wording.

20. Release artifact identity
- Status: `in_progress`
- Scope: `build_java()` now stages the exact jar, sources jar, javadoc jar, and versioned POM into `zig-out/dist/java`; `publish_java()` now signs, checksums, bundles, and uploads those exact staged artifacts through Sonatype’s Publisher API instead of rebuilding from source.
- Validation: Zig-side helper tests and compile coverage are in place now; full closure still requires a release rehearsal with checksum identity from build to publish on a machine with Java/Maven and release credentials.

### Track E: Verification Fidelity

21. Vortex fault fidelity
- Status: `in_progress`
- Scope: the fault injector now has duplication, reordering, and rate-limiting modes in the proxy path, along with tracked timeout completions so delayed/rate-limited pipes are accounted for correctly during shutdown. Remaining closure is broader chaos validation rather than missing injector code paths.
- Validation: focused unit tests for fault reset and rate helpers; compile proof; environment-dependent Vortex smoke still needs a namespace-capable machine.

22. Vortex geometry realism
- Status: `done`
- Scope: replace fake S2 IDs with geometry-derived cells where correctness matters.
- Validation: focused workload generator test via the normal unit-test build graph.

23. Durability evidence bundle
- Status: `queued`
- Scope: regenerate parity, failover, durability, and benchmark artifacts from the current commit.
- Validation: release-candidate artifact set under `reports/` and attached logs.

## Execution Tracker

### Completed in current pass

- Parity harness cluster truthfulness: `tests/parity_tests/parity_runner.py` now supports managed local clusters with a real `--cluster-nodes` default, per-case topology cluster sizing, and fixture setup hooks for `stop_node` / `trigger_leader_failover` instead of forcing topology fixtures through a single-node cluster.
- Parity harness topology startup policy: topology cases now wait for an actual queryable topology response with real shard addresses instead of requiring all nodes to reach `/health/ready`, which was incorrectly blocking otherwise healthy 5-node topology clusters on this machine.
- Parity harness failover endpoint selection: `_cluster_server_url()` now skips stopped replicas when it falls back from leader detection, so `topology_after_leader_change` no longer loops against the node that was just killed.
- Topology helper dependency cleanup: `test_infrastructure/topology/consistency.py` no longer imports undeclared `tenacity`; it uses an in-tree retry loop instead.
- Python cluster harness dependency cleanup: `test_infrastructure/harness/cluster.py` no longer depends on third-party `requests` just to start a local cluster; readiness/metrics probes now use the stdlib HTTP stack.
- Python cluster harness startup alignment: the harness now formats/starts test nodes in development mode, uses explicit `127.0.0.1:port` address lists for multi-node startup, uses a smaller default test cache grid, and no longer gates leader detection on `/health/ready`.
- Python cluster harness sizing: the managed local-cluster defaults are now less toy-sized (`cache_grid=64MiB`, `ram_index_size=8MiB`, `memory_lsm_manifest=64MiB`), and restart paths now pass the same manifest-memory override as initial startup so topology/failover cases keep one consistent memory profile.
- Startup stability: a fresh single-node `start --development` now reaches `/health/ready` again after reducing dev-mode RAM-index defaults and runtime-sizing large LSM allocations.
- Multi-node startup root cause: the 3-node startup stall was traced to `GeoStateMachine.forest_options()` using the compile-time maximum insert batch for runtime tree sizing, which inflated the LSM radix scratch buffer to ~1.34 GiB per replica. Runtime sizing now uses the configured `batch_size_limit`, bringing the same buffer down to ~4.0 MiB in the managed local cluster profile.
- Live topology truthfulness: `GeoStateMachine` now receives the configured `--addresses` member list, derives the current primary from the durable VSR view, and `get_topology` returns real cluster addresses instead of the placeholder `127.0.0.1:5000`.
- Python SDK topology parsing: compact topology parsing now respects the real shard-array offset used by the server, and a dedicated regression test covers the compact wire layout so live topology no longer degrades to empty or truncated node lists.
- Local backup runtime: the exact checkpoint-rooted scan is wired into the live runtime and now has a proven end-to-end local-provider upload path.
- Backup validation note: on the default 1024-slot journal profile, backup proofs must cross roughly 920 committed ops before the first nonzero checkpoint becomes durable. A low-op import run is not a valid backup proof.
- CLI import batching: `archerdb import --batch-size=<n>` is now honored instead of being silently ignored.
- CSV import: the CLI now uses `data_export_csv.zig` for real CSV parsing and insertion.
- CSV validation: CSV rows without `entity_id` now fail during parsing instead of reaching the server and failing at insert time.
- Operator status wire-up: `archerdb_get_status` now carries real membership state/counts and index-resize state/progress without changing wire size.
- `cluster status`: now prints real per-node membership state and resize status instead of only RAM-index counters.
- `index resize status`: now prints real per-node resize state/progress instead of placeholder text.
- `index resize` control path: `start`, `status`, and `abort` now have a live CLI integration proof against a running node, and `start` accepts `--index-resize-batch-size` to make resize progress observable/tunable.
- Shard reshard boundary: live `shard reshard` execution now defaults to online mode, and offline mode is explicitly limited to planning with `--dry-run` rather than being advertised as the default stop-the-world path.
- Cluster membership boundary: `cluster status` is the supported GA surface, and `cluster add-node` / `cluster remove-node` now remain explicitly outside the current runtime contract because membership is fixed by startup `--addresses`.
- Cluster CLI help boundary: `archerdb cluster --help` now advertises only `status`; the parser no longer exposes reserved mutation verbs just to satisfy nested-command parsing constraints.
- Upgrade CLI boundary: `upgrade status` now supports real JSON output backed by live `/health/ready` and `/metrics` probing, `upgrade start` is limited to `--dry-run`, and live rollout/rollback remain owned by external deployment tooling rather than the ArcherDB CLI.
- Multi-region deployment doc boundary: `docs/multi-region-deployment.md` is now explicitly written as future-runtime design/reference material, and its flag examples are labeled as sketches rather than runnable `start` commands.
- Java release honesty: `publish_java()` now fails closed instead of rebuilding and publishing a different artifact set than the one staged during the build step.
- Java release artifact identity: `build_java()` now stages the exact publish inputs (jar, sources jar, javadoc jar, versioned POM), and `publish_java()` now signs, checksums, bundles, and uploads those exact staged files to Sonatype Central instead of rebuilding.
- Vortex geometry realism: the workload generator now derives S2 cell IDs from each generated event’s latitude/longitude instead of using random placeholder IDs.
- Vortex fault injector: the proxy now supports duplication, one-chunk reordering, and rate limiting in addition to delay/loss/corruption, and timer completions are tracked as real in-flight work so delayed pipes do not race connection teardown.
- Restore boot metadata: `RestoreManager.writeSuperblock()` now also reconstructs a minimal WAL scaffold from checkpoint and view-header metadata, so restored files are no longer superblock-only stubs.
- Restore boot proof: a restored clustered replica artifact now opens under the real file-backed `Replica.open()` path.
- `inspect` decoder closure: trailer blocks (`free_set`, `client_sessions`) and the remaining variable-length ArcherDB request/reply bodies now have dedicated decode paths and focused output checks in `src/archerdb/inspect.zig`.
- `inspect` fallback hardening: reserved/future/corrupt block/op fallbacks are now labeled honestly, `print_prepare_body_variable` / `print_reply_body_variable` no longer panic on VSR-reserved operations, and enum-walk regressions prove current ops do not emit `unimplemented`.
- Node SDK harness truthfulness: the active Jest path now accepts `ARCHERDB_ADDRESS` to reuse an external node, fails immediately on bootstrap stderr/exit instead of opaque timeout-only behavior, and `query_latest` fixture assertions now validate `events_contain` plus timestamp ordering.
- Replica membership snapshot: `Replica` now refreshes `membership_config` from the live runtime topology, including configured replica addresses and standby learner roles, and a focused unit test covers that mapping.
- Operator status sync-client teardown: `query_single_node_status()` now shuts down and drains its short-lived VSR client before deinit instead of freeing `message_bus` completions that are still owned by IO.
- `cluster status` live crash fix: the repeated-client `message_bus` panic on sequential node probes has been reproduced against a managed 3-node cluster, fixed in the sync shutdown path, and re-proven end to end on the same live topology.

### Verified artifacts and commands

- Live backup proof:
  - `archerdb start --development --experimental --limit-request=4KiB --backup-enabled --backup-provider=local ...`
  - `archerdb import --format=json ...` with 62,000 events
  - Result: `archerdb_vsr_op_number 2068`, `archerdb_backup_blocks_uploaded_total 14`, and local `.block/.ts/.meta` artifacts produced under the backup bucket.
- Committed live backup integration proof:
  - `./zig/zig build test:integration -- "integration: start path uploads backup blocks after live writes"`
  - Result: a fresh formatted `archerdb start` path with local backups enabled now survives startup, crosses the first durable checkpoint, reports `archerdb_backup_blocks_uploaded_total > 0`, and produces `.block`, `.block.ts`, `.block.meta`, and `.ckpt` artifacts under the local backup bucket.
- CSV importer tests:
  - `./zig/zig build test:unit -- "CsvImporter"`
- `inspect` decoder tests:
  - `./zig/zig test -freference-trace=10 ./.zig-cache/o/2d528e2ae1d1f32f395aaf32f34019fa/liblz4.a -ODebug -target x86_64-linux -mcpu x86_64_v3+aes -I ./.zig-cache/o/73dec1a6861949f77a4ef4e98c7118f1 --dep stdx --dep vsr -Mroot=./src/archerdb/inspect.zig -Mstdx=./src/stdx/stdx.zig ./.zig-cache/o/2d528e2ae1d1f32f395aaf32f34019fa/liblz4.a -I ./.zig-cache/o/73dec1a6861949f77a4ef4e98c7118f1 -I ./.zig-cache/o/73dec1a6861949f77a4ef4e98c7118f1 --dep stdx --dep vsr_options -Mvsr=./src/vsr.zig -Mvsr_options=./.zig-cache/c/a843935396e297b02a202cd66b68a113/options.zig -lc`
- Focused Node SDK rerun proof:
  - `cd tests/sdk_tests/node && npx tsc --noEmit`
  - `ARCHERDB_INTEGRATION=1 ARCHERDB_ADDRESS=127.0.0.1:3901 npx jest --runInBand test_all_operations.ts -t 'radius_with_group_filter|radius_with_timestamp_filter|polygon_with_group_filter|latest_with_group_filter'`
  - Result: 4 targeted group/timestamp cases passed on the active Jest path using the external-address bootstrap bypass.
- Parity harness smoke proof:
  - `python3 -m py_compile tests/parity_tests/parity_runner.py test_infrastructure/harness/cluster.py`
  - managed single-node cluster proof via `ArcherDBCluster(ClusterConfig(node_count=1))`: `started`, `ready True`, `leader 3100`, `stopped`
- Multi-node topology proof:
  - `./zig/zig build test:unit -- "get_topology builds real addresses from configured members"`
  - `./zig/zig build -j2`
  - `PYTHONPATH=/home/g/archerdb/src/clients/python/src:/home/g/archerdb python3 -m unittest src.clients.python.src.archerdb.test_topology.TestTopologyResponse.test_from_bytes_parses_compact_topology_layout`
  - managed 3-node cluster proof via `ArcherDBCluster(ClusterConfig(node_count=3, data_dir='/tmp/archerdb-multinode-smoke'))`: `ready True`, stable leader election, and real topology nodes reported on both the original smoke profile and the new default harness profile.
  - focused topology parity rerun: `python3 -u tests/parity_tests/parity_runner.py --start-cluster --cluster-port 6200 --cluster-nodes 1 --ops topology ...` with `single_node_topology`, `three_node_topology`, `five_node_topology`, and `topology_includes_addresses` all passing on the managed harness after the queryability fix.
  - isolated failover topology proof via inline script on base port `7600`: `topology_after_leader_change` passed across Python, Node, Go, Java, and C after leader failover.
  - isolated unhealthy-node topology proof via inline script on base port `7700`: `topology_with_unhealthy_node` passed across Python, Node, Go, Java, and C after stopping one replica.
- Membership runtime proof:
  - `./zig/zig build test:unit -- "Replica: membership config reflects runtime addresses and standby learners"`
- CSV import live proof:
  - `archerdb import --format=csv --batch-size=2 ... sample_with_ids.csv`
  - Result: 5 parsed, 5 sent, 0 failed, 3 batches.
- Operator status compile/unit proof:
  - `./zig/zig build check -j2`
  - `./zig/zig build test:unit -- "ArcherDB admin operations: ping and get_status"`
  - `./zig/zig build test:unit -- "StatusResponse helper methods decode operator status extensions"`
- Operator status teardown proof:
  - `./zig/zig build test:integration -- "integration: cluster status reuses sync clients without crashing"`
  - live 3-node command proof: `./zig-out/bin/archerdb cluster status --addresses=127.0.0.1:3100,127.0.0.1:3101,127.0.0.1:3102 --cluster=0 --format=json`
- Upgrade control-plane proof:
  - `./zig/zig test src/archerdb/upgrade.zig`
  - `./zig/zig build test:integration -- "integration: upgrade status emits json and live start fails closed"`
  - `./zig/zig build check -j2`
- Java release-path proof:
  - `./zig/zig test src/scripts/release.zig`
  - `./zig/zig build check -j2`
  - `./zig/zig build test:unit -- "parse_remote_checksum"`
  - `./zig/zig build test:unit -- "compute_file_sha256_hex"`
  - Note: the publish path now includes a post-publish SHA-256 comparison against Central; the remaining gap is a credentialed Central rehearsal on a real release cut.
- Vortex geometry proof:
  - `./zig/zig build test:unit -- "random_insert_events derives S2 cell ids from generated coordinates"`
  - `./zig/zig build check -j2`
- Vortex fault-injector proof:
  - `./zig/zig build test:unit -- "Faults heal clears all injected network modes"`
  - `./zig/zig build test:unit -- "Pipe rate helpers bound chunk size and compute delay"`
  - `./zig/zig build test:unit -- "Pipe advance_after_send"`
  - `./zig/zig build check -j2`
  - `./zig/zig build test:integration -- "vortex smoke"` currently skips in this environment because Linux user namespaces are unavailable.
- Index resize live CLI proof:
  - `./zig/zig build test:integration -- "integration: index resize control reports live status"`
- Restore compile/unit proof:
  - `./zig/zig build test:unit -- "RestoreManager: writeSuperblock installs restore superblock copies"`
  - `./zig/zig build test:unit -- "RestoreManager: restored data file boots under Replica.open"`
  - `./zig/zig build test:unit -- "RestoreManager:"`
  - `./zig/zig build check -j2`

### Next items

1. Restore integrity completion
- Re-run restore and PITR against locally produced checkpoints.
- Upgrade restore from artifact recovery to a bootable data-file flow in this order:
  1. persist durable checkpoint metadata during backup. Status: done via `.ckpt` artifacts gated on durable upload completion.
  2. restore blocks to original grid addresses. Status: done for metadata-bearing flows.
  3. extend remote restore inputs to consume `.meta` and `.ckpt` sidecars. Status: done for the shared S3/GCS-style path; Azure still needs live proof.
  4. synthesize a valid superblock/checkpoint from the selected checkpoint artifact. Status: done.
  5. write a bootable WAL scaffold from checkpoint/view-header metadata. Status: done.
  6. boot a restored replica under `Replica.open()` or `archerdb start`. Status: done. `Replica.open()` is covered for clustered restore artifacts, and a real `archerdb start` smoke now passes for a standalone restored file after hardening restore journal synthesis for the contiguous prepare-header window that startup expects.

2. Operator control-plane closure
- `archerdb upgrade` is now explicitly status/dry-run-only around the existing VSR multiversion path; no in-CLI process/deployment actuator is part of the current GA surface.
- `cluster add/remove node` is explicitly de-scoped from the current GA surface until VSR reconfiguration and transport topology can support it honestly; `cluster status` remains supported.
- Keep `inspect` output coverage current as additional block/op surfaces become GA; the current `free_set`, `client_sessions`, and variable-length request/reply gaps are closed.

3. Release artifact identity completion
- Rehearse the new Java publish flow end-to-end on a machine with Java, Maven, GPG key material, and Central credentials.
- Confirm checksum identity between the staged dist artifacts and the published Maven Central component set.

3. CDC, observability, and security
- CDC broker-backed publish proof is now in place.
- OTLP span events are exported.
- Breach-template substitution is complete.
- In-process revocation checking is now explicitly non-GA and rejected at init.

4. Validation and release proof
- Refresh parity and SDK evidence from the current commit now that the topology path is green.
- Run the full 5-SDK parity artifact on a machine with the required `go`, `java`, and `mvn` toolchains available.
- Fix synthetic benchmark/release-artifact drift.

7. Verification and release evidence
- Expand Vortex fault fidelity.
- Fix release artifact identity issues.
- Regenerate the release evidence bundle only after all earlier tracks are green.

## Execution Tracker

Status key:
- done
- in_progress
- pending

### Track 0: Truthfulness And Fail-Closed Behavior

- T0.1 `done` Make S3 relay fail closed by default and require explicit simulation in tests/dev.
- T0.2 `done` Reject backup flags on the live `start` path until real runtime wiring exists.
- T0.3 `done` Remove misleading Java parity placeholder fallback.
- T0.4 `done` Remove stale SDK fixture skips where real support already exists.

### Track 1: Backup Runtime

- T1.1 `done` Add a process-owned backup runtime module under `src/archerdb/`.
- T1.2 `done` Add a `ReplicaEvent.checkpoint_durable` hook in `src/vsr/replica.zig`.
- T1.3 `done` Supersede compaction-time capture hooks with an exact checkpoint-rooted durable scan.
- T1.4 `done` Supersede manifest-log capture hooks with an exact checkpoint-rooted durable scan.
- T1.5 `done` Release buffered block refs only after checkpoint durability.
- T1.6 `done` Implement local-provider upload/write path for blocks and timestamp sidecars.
- T1.7 `done` Persist upload progress via `BackupStateManager`.
- T1.8 `done` Export backup health/queue metrics from the live process.
- T1.9 `done` Add end-to-end local backup->restore integration coverage.

### Track 2: Restore Integrity

- T2.1 `done` Replace local restore checksum stub with real checksum validation.
- T2.2 `done` Add corruption tests for invalid block payloads and timestamp sidecars.
- T2.3 `done` Verify PITR ordering and filtering across local and object-store-backed restore listings.

### Track 3: Operator Control Plane

- T3.1 `done` Replace simulated upgrade replica discovery with real interrogation.
- T3.2 `done` Replace simulated primary detection with health/status-derived role detection.
- T3.3 `done` Replace simulated health probing with real endpoint checks.
- T3.4 `done` Permanently narrow the GA upgrade surface to status and dry-run planning; keep live mutation verbs fail closed outside that boundary.
- T3.5 `done` Implement CSV import.
- T3.6 `done` Extend `inspect` coverage for the currently supported block/op types and keep it under dedicated module-test verification.
- T3.7 `done` De-scope multi-region server start flags from the GA runtime surface.
- T3.8 `done` Drain short-lived control clients before deinit so sequential operator probes do not leave stale `message_bus` completions in IO.

### Track 4: CDC, Observability, Security

- T4.1 `done` Wire CDC batch flush to the real AMQP publish API.
- T4.2 `done` Add OTLP span-event export.
- T4.3 `done` Complete breach-template substitution.
- T4.4 `done` Explicitly de-scope in-process revocation checking from GA and reject it at init.

### Track 5: SDK And Parity

- T5.1 `done` Remove stale Python fixture skips.
- T5.2 `done` Remove stale Node timestamp-filter skips.
- T5.3 `done` Re-run the newly unskipped Python/Node cases against a live cluster.
- T5.4 `done` Refresh parity output after the harness truthfulness fixes.
- T5.5 `done` Relabel Java/Node skeleton-mode unit tests honestly.
- T5.6 `done` Tighten Java multi-region routing semantics or de-scope it from GA docs/tests.

### Track 6: Verification And Release

- T6.1 `done` Add Vortex duplication fault injection.
- T6.2 `done` Add Vortex reordering fault injection.
- T6.3 `done` Add Vortex rate-shaping fault injection.
- T6.4 `done` Replace fake S2 workload cell generation where correctness matters.
- T6.5 `done` Fix Java release publishing so deployed artifacts match built artifacts.
- T6.6 `in_progress` Regenerate full release-candidate evidence bundle on the final commit.

## Recommended Implementation Order

1. Remove simulated-success upload behavior.
2. Wire backup runtime and real restore checksum validation.
3. Make upgrade orchestration use real cluster state.
4. Close CSV import and wire `inspect` coverage into normal verification.
5. Replace CDC placeholder publish path.
6. Close SDK/parity placeholders.
7. Raise fault-injection and release-publishing fidelity.

## Current Implementation Tranche

Start immediately with:

1. S3 relay fail-closed behavior and tests.
2. Backup runtime wiring reconnaissance and first integration slice.
3. Upgrade path reconnaissance and first real health-probe slice.

## Execution Tracker

Status legend:

- `[x]` completed
- `[-]` in progress
- `[ ]` not started
- `[!]` blocked / needs product decision

### Tranche 0: Fail Closed, Truthful Defaults

- [x] Make `S3RelayTransport` fail closed unless simulation is explicitly enabled for tests.
- [x] Add unit coverage for the new S3 relay default behavior.
- [x] Reject incomplete backup runtime startup config in `start` until the live runtime path exists.
- [x] Remove stale SDK test skips where support already exists in Python.
- [x] Remove stale Node timestamp-filter skips in integration suites.
- [x] Replace Java parity placeholder fallback with an explicit error path.
- [x] Audit remaining production-visible “simulated success” paths and remove or gate them.
  Remaining simulated S3 upload behavior is explicitly test-gated via `allow_simulated_uploads`; no production-visible success fallback remains on the default path.
- [x] Make public-facing helper scripts fail closed or execute real validation instead of emitting placeholder guidance.
  `scripts/key_rotation.sh` now rejects unsupported live file/env rotation, `scripts/dr-test.sh` performs restore-and-verify inside Kubernetes instead of skipping, and `scripts/competitor-benchmarks/generate-comparison.py` exits nonzero when no real results are present.

### Tranche 1: Backup And Restore Completeness

- [x] Identify the correct runtime seam for backup integration.
  The current design target is `command_start()` + `Replica.event_callback` + checkpoint durability.
- [x] Add a dedicated `backup_runtime.zig` module.
- [x] Instantiate backup runtime from `command_start()` when backups are enabled.
- [x] Extend `ReplicaEvent` with a checkpoint-durable notification.
- [x] Buffer closed backupable block refs until checkpoint durability.
- [x] Implement a real local-provider upload path that writes block objects, `.ts` sidecars, and block metadata.
- [x] Persist upload progress via `BackupStateManager`.
- [x] Export backup queue/progress metrics from the live runtime.
- [x] Add integration coverage for startup -> write workload -> uploaded block objects.
- [x] Upgrade local restore checksum verification from “header readable” to real checksum validation.
- [x] Add corruption tests for restore checksum failure.
- [x] Add exact local backup artifact -> `RestoreManager` round-trip coverage.
- [x] Reconstruct a bootable restore WAL scaffold from durable checkpoint plus view-header metadata.
- [x] Prove a restored clustered replica file opens under the real file-backed `Replica.open()` path.
- [x] Add a CLI `archerdb start` smoke on a restored file.

### Tranche 1A: Startup Stability

- [x] Reproduce the current single-node startup blocker with a clean formatted file.
  Outcome: stale tracker item. A fresh formatted node now reaches `/health/ready` and elects a leader under the managed harness.
- [x] Identify the exact blocking or hanging initialization stage after the early startup logs.
  Outcome: no current blocker remained after the multi-node sizing and topology fixes; no additional startup hang stage was reproducible on April 9, 2026.
- [x] Land the smallest safe fix.
  The already-landed runtime sizing and topology fixes removed the stale startup blocker.
- [x] Re-run `start`, `status`, and backup live smokes from a clean temp directory.
  Validation now includes the managed clean-start proof, `cluster status` regression coverage, and the committed backup integration test on a freshly formatted node.

### Tranche 2: Operator Control Plane

- [x] Replace simulated replica discovery in `upgrade.zig` with real interrogation.
- [x] Replace simulated primary detection in `upgrade.zig` with real role detection.
- [x] Replace simulated health probing in `upgrade.zig` with live endpoint checks.
- [x] De-scope primary upgrade / rollback actuation from the GA CLI surface; keep status and dry-run planning supported.
- [x] Remove reserved non-functional upgrade subcommands from the public CLI surface.
  `archerdb upgrade --help` now exposes only `status` and `start`; `pause`, `resume`, and `rollback` are no longer advertised or parsed.
- [x] Implement CSV import.
- [x] Extend `archerdb_get_status` to carry operator state without changing wire size.
- [x] Make `cluster status` consume real membership state and resize status from the live RPC path.
- [x] Make `index resize status` consume real resize state and progress from the live RPC path.
- [x] Wire `index resize start/abort` through a live control path and startup-loop actuator.
- [x] Add live CLI integration coverage for `index resize start/status/abort`.
- [x] Make unsupported `cluster add/remove node` commands fail closed instead of printing placeholder guidance.
- [x] Extend `inspect` decoder coverage for remaining supported block and operation types.
  `inspect` now decodes `free_set`, `client_sessions`, and the remaining variable-length ArcherDB request/reply bodies, with focused output checks exercised through a dedicated `zig test` invocation for `src/archerdb/inspect.zig`.
- [x] Decide whether multi-region server flags are GA or must remain non-GA.
  Current decision: non-GA. The server-side flags are removed from the public `archerdb start` CLI surface, and the deployment guide is now explicitly design/reference material for a future runtime shape.

### Tranche 3: CDC, Observability, Security Hardening

- [x] Wire CDC batch flush to the real AMQP publish path.
- [x] Add broker-backed CDC integration coverage.
  Validation: `./zig/zig build test:unit -- "CDC Runner publishes to a live RabbitMQ broker"`.
- [x] Export span events in OTLP payloads.
- [x] Complete breach-notification template substitution.
- [x] Replace simplified CRL parsing with a correct parser, or explicitly de-scope it from GA.
  Current decision: de-scoped. `TlsConfig.init()` rejects non-disabled revocation modes with `error.UnsupportedRevocationChecking`.

### Tranche 4: SDK And Parity Closure

- [x] Remove stale Python group/timestamp filter skips.
- [x] Remove stale Node timestamp-filter skips.
- [x] Make Java parity fallback fail honestly instead of returning placeholder output.
- [x] Run focused Python integration coverage for the previously skipped filter cases.
- [x] Run focused Node integration coverage for the previously skipped filter cases.
- [x] Refresh `reports/parity.json` from the current commit.
  Validation: `python3 -u tests/parity_tests/parity_runner.py --start-cluster --cluster-port 4000 --cluster-nodes 1 -v --output reports/parity.json --markdown docs/PARITY.md` completed with `79/79 passed, 0 failed` on April 9, 2026 after adding packaged-client refreshes and Go native-artifact-aware rebuild checks.
- [x] Relabel Java/Node skeleton-mode unit tests as unit/wire-format coverage.
- [x] Tighten or de-scope Java multi-region routing.
  Current decision: non-GA in the Java SDK. The docs and Javadocs now state the real behavior explicitly (`FOLLOWER` deterministic, `NEAREST` not latency-aware).

### Tranche 5: Verification Fidelity And Release Evidence

- [x] Add duplication faults to Vortex.
- [x] Add reordering faults to Vortex.
- [x] Add rate-limiting faults to Vortex.
- [x] Replace fake S2 workload IDs where correctness claims depend on geometry.
- [x] Fix Java release publishing so the published artifact matches the verified build output.
- [x] Regenerate release-candidate evidence artifacts from the current commit.
  Current state on April 9, 2026:
  - parity is refreshed and green from the current commit (`79/79`)
  - the benchmark harness now uses the supported SDK/client surface instead of raw HTTP against the replica port
  - failed benchmark operations are rejected instead of being counted as samples
  - current-commit quick benchmark artifacts are regenerated for 1-node, 3-node, 5-node, and 6-node runs under `reports/benchmarks/release-20260409-sdkquick/`
  - the 6-node local benchmark path is stabilized on this shared machine by:
    - formatting 6-node local benchmark clusters as `5` voters plus `1` standby
    - passing `--replica-count` through `start`
    - staggering large-topology startup until each replica completes local init
    - using a tighter 6-node machine-fit benchmark memory profile
    - ordering benchmark client endpoints as leader-first, then the remaining voters
  - the remaining release-proofing task is external to the repo: a credentialed Java Central rehearsal for the post-publish checksum verifier
  - there are no remaining repo-side placeholder or fake-success helper paths in `scripts/` or public docs after the key-rotation, DR, and competitor-benchmark cleanup pass
  - `zig build scripts -- release --language=java --publish --preflight --sha=<commit>` now performs a no-side-effects prerequisite check for that rehearsal and fails clearly when Java, Maven Central credentials, GPG key material, or staged artifacts are missing
