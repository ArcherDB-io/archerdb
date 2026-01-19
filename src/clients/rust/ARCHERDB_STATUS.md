# ArcherDB Rust SDK Status

## Current State

The Rust SDK is migrated to ArcherDB geospatial types and operations.

### Completed
- ✅ `rust_bindings.zig` - Updated type mappings to geospatial
- ✅ `arch_client.rs` / `arch_client.h` - Regenerated with geospatial structs
- ✅ `lib.rs` - GeoEvent API (insert/upsert/query/delete/TTL/topology)
- ✅ `README.md` - Geospatial usage and samples
- ✅ Samples - Basic and walkthrough updated to GeoEvent operations

## Follow-up Work

- Add radius/polygon sample projects for Rust if parity with other SDKs is required.
- Exercise end-to-end integration tests using the Rust client (insert/query/delete).
