# ArcherDB Rust SDK Status

## Current State

The Rust SDK has **partially migrated** to ArcherDB geospatial types:

### Completed
- ✅ `rust_bindings.zig` - Updated type mappings from financial to geospatial
- ✅ `tb_client.rs` - Regenerated with geospatial structs (geo_event_t, query filters)
- ✅ `tb_client.h` - Regenerated with geospatial C headers
- ✅ Signed integer support added (i8/i16/i32/i64/i128) for lat_nano, lon_nano, altitude_mm

### Needs Rewrite (~2600 lines)
- ❌ `lib.rs` (1829 lines) - Still contains TigerBeetle Account/Transfer API
- ❌ `README.md` (752 lines) - Still documents TigerBeetle financial operations

## Required Changes for lib.rs

Replace financial types with geospatial equivalents:

| TigerBeetle (Remove) | ArcherDB (Add) |
|---------------------|----------------|
| `Account` | `GeoEvent` |
| `Transfer` | (not applicable) |
| `AccountFlags` | `GeoEventFlags` |
| `TransferFlags` | (not applicable) |
| `CreateAccountResult` | `InsertGeoEventResult` |
| `CreateTransferResult` | (not applicable) |
| `AccountFilter` | `QueryUuidFilter`, `QueryRadiusFilter`, `QueryPolygonFilter`, `QueryLatestFilter` |

Replace client methods:

| TigerBeetle (Remove) | ArcherDB (Add) |
|---------------------|----------------|
| `create_accounts()` | `insert_events()`, `upsert_events()` |
| `create_transfers()` | (not applicable) |
| `lookup_accounts()` | `query_uuid()` |
| `lookup_transfers()` | (not applicable) |
| `get_account_transfers()` | `query_radius()`, `query_polygon()` |
| `get_account_balances()` | (not applicable) |
| `query_accounts()` | `query_latest()` |
| `query_transfers()` | (not applicable) |

## Wire Format

The low-level bindings in `tb_client.rs` now correctly define:

```rust
pub struct geo_event_t {
    pub id: u128,
    pub entity_id: u128,
    pub correlation_id: u128,
    pub user_data: u128,
    pub lat_nano: i64,      // Signed for coordinates
    pub lon_nano: i64,      // Signed for coordinates
    pub group_id: u64,
    pub timestamp: u64,
    pub altitude_mm: i32,   // Signed for below sea level
    pub velocity_mms: u32,
    pub ttl_seconds: u32,
    pub accuracy_mm: u32,
    pub heading_cdeg: u16,
    pub flags: u16,
    pub reserved: [u8; 12],
}  // Total: 128 bytes
```

## Reference Implementations

Other SDKs that have completed the migration can be used as reference:

- **Go**: `src/clients/go/pkg/archerdb/` - Complete geospatial API
- **Java**: `src/clients/java/src/main/java/com/archerdb/geo/` - Complete with builders
- **Python**: `src/clients/python/src/archerdb/` - Complete with type hints
- **Node.js**: `src/clients/node/src/` - Complete TypeScript implementation

## Estimated Effort

- High-level API rewrite: ~400-500 lines of new Rust code
- Documentation rewrite: ~300 lines of new README
- Test updates: Additional test file updates
- Sample projects: Update `samples/basic/`, remove `samples/two-phase/`
