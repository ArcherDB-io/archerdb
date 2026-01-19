# Implementation Gap Matrix (Initial)

Legend: IMPLEMENTED / PARTIAL / MISSING / UNKNOWN

## Global Gaps

- OpenSpec is not finalized: `openspec/specs/` is empty, so approved specs are missing. All work is still in `openspec/changes/`.
- Spec conflict: `openspec/changes/add-geospatial-core/specs/security/spec.md` explicitly states **no TLS** and OS-level encryption, while `openspec/changes/add-v2-distributed-features/specs/security/spec.md` requires built-in encryption, key management, and audit. Code includes `src/archerdb/tls_config.zig` (TLS config) but CLI/server wiring is absent.
- Tests: `./zig/zig build test:unit` spawns long-running `test-unit` processes and does not complete in a reasonable time; integration tests run by default but skip the in-place upgrade scenario unless `-Dintegration-past=/path/to/archerdb` is provided.

## Change-Level Matrix (Spot-Checked)

| Change | Spec Area | Status | Evidence / Notes |
| --- | --- | --- | --- |
| add-v2-distributed-features | replication | PARTIAL | S3 relay is simulated (`src/replication.zig` logs TODO). Transport is not authenticated/encrypted; spec requires authenticated, encrypted channels. Disk spillover works but lacked validation (fixed). |
| add-v2-distributed-features | security | PARTIAL | Encryption module exists (`src/encryption.zig`) with KMS/Vault integration via CLI tools; TLS revocation checks are stubbed (`src/archerdb/tls_config.zig`) and not wired to CLI/server. |
| add-geospatial-core | query-engine | PARTIAL | Merge difference was unimplemented; now implemented with tests (`src/lsm/scan_merge.zig`, `src/lsm/scan_builder.zig`). TTL/query correctness and full S2 behavior still need audit. |
| add-geospatial-core | security | CONFLICT | Spec says no TLS + OS-level encryption; code includes TLS config and built-in encryption. Needs decision and spec reconciliation. |
| add-geospatial-core | testing-simulation | PARTIAL | Unit tests hang; integration tests run by default but skip the in-place upgrade scenario unless `-Dintegration-past=/path/to/archerdb` is provided. |
| add-aesni-encryption | configuration/observability/security | PARTIAL | AES-NI startup checks exist in `src/encryption.zig` and `src/archerdb/main.zig`, but broader spec coverage still needs verification. |
| add-geojson-wkt-protocol | client-protocol | UNKNOWN | Not yet audited. |
| add-polygon-holes / validation | query-engine / client-sdk / error-codes | PARTIAL | Hole count/vertex validation and containment/overlap checks implemented in `src/geo_state_machine.zig` with input validation tests; SDK-side coverage still needs full audit. |
| add-spatial-sharding / jump-consistent-hash | index-sharding | UNKNOWN | Not yet audited. |
| add-ttl-aware-compaction / per-level-ttl-stats | storage-engine / observability | UNKNOWN | Not yet audited. |
| add-coordinator-mode / dynamic-membership | coordinator / replication | UNKNOWN | Not yet audited. |

## Completed Fixes Since Initial Review

- Replication spillover recovery now validates headers and checksum and bounds body size; added unit tests.
- Query scan difference implemented with unit tests.
- Startup now enforces `--limit-storage` against existing data file size.
- Query UUID wire format aligned to 32-byte request + 16-byte status header; all SDKs parse status (including TTL expiry) and bindings regenerated.
- Unit-test filter for `QueryUuidResponse` now runs clean after fixing a `repl/parser.zig` const issue.
- S2 golden vector validation fixed (antimeridian normalization, Hilbert orientation, face orientation) and tests now require zero errors.
- Node.js echo test now uses `insert_events` with GeoEvent payloads; Go echo test now exercises echo mode.
- Java JNI callback dispatch now uses virtual `endRequest` (GeoNativeBridge echo works); Java client defaults to native enabled (tests force-disable via Maven), and Java echo test added to client matrix. 
- Polygon queries now validate hole wire format, winding, containment, and overlap (with input_valid tests); Node/Go query decoders now honor `QueryResponse` headers with a legacy raw-array fallback.
- Node query_polygon now serializes variable-length polygons (outer ring + holes) into the correct wire format for the native client.
- Node and Go clients now implement query_uuid_batch encoding/decoding (Go includes a response parser unit test).
- .NET client now implements query_uuid_batch encoding/decoding with wire-format tests.
- Rust client now integrates the native arch_client path for core geo operations and implements query_uuid_batch encode/decode with unit tests.
