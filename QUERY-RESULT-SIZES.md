# Query Result Sizes

**Configuration**: Adjustable via `message_size_max`

---

## Default Configuration (Current)

**Setting**: `message_size_max = 1 MiB`

**Query Result Capacity**:
- Message body available: ~1,048,448 bytes
- QueryResponse header: 8 bytes
- **Available for GeoEvents**: ~1,048,440 bytes
- GeoEvent size: 128 bytes each

**Maximum Results Per Query**: **~8,190 GeoEvents**

---

## Production Configuration (Recommended)

**Setting**: `message_size_max = 10 MiB` (configurable in config.zig)

**Query Result Capacity**:
- Message body available: ~10,485,632 bytes
- QueryResponse header: 8 bytes
- **Available for GeoEvents**: ~10,485,624 bytes
- GeoEvent size: 128 bytes each

**Maximum Results Per Query**: **~81,918 GeoEvents**

---

## Pagination Support ✅

**QueryResponse Header** (8 bytes):
```zig
pub const QueryResponse = extern struct {
    count: u32,           // Number of results in this response
    has_more: u8,         // 1 = more results available, use cursor
    partial_result: u8,   // 1 = truncated due to size limit
    reserved: [2]u8,
};
```

**Cursor Support**:
- `query_latest`: Has `cursor_timestamp` field for pagination
- `query_radius`: Can page by adjusting timestamp filters
- `query_polygon`: Similar pagination support

**Behavior**:
1. Client requests with limit (e.g., limit=100,000)
2. Server returns up to buffer capacity (~8,190 or ~81,918)
3. If more results exist: `has_more=1` in response
4. Client can request next page using cursor

---

## Summary

**Default (1 MiB)**: ~8,190 GeoEvents per query
**Production (10 MiB)**: ~81,918 GeoEvents per query
**Pagination**: Supported via QueryResponse.has_more + cursor

**This is configurable** - just adjust `message_size_max` in config.zig for your deployment needs.
