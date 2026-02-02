# Java SDK queryPolygon Bug Fix

## Problem

The Java SDK's `queryPolygon()` method was causing "client eviction" when called, while the same operation worked correctly in Python, Node.js, and Go SDKs.

## Root Cause

The `NativeQueryPolygonBatch` class was incorrectly implementing the wire format serialization:

1. **Old Implementation Problem:**
   - `NativeQueryPolygonBatch` extended `Batch` and created a separate `variableBuffer` to store polygon data
   - It wrote data to `variableBuffer` but never overrode `getBuffer()` and `getBufferLen()` methods
   - When `Request` class called `batch.getBuffer()` and `batch.getBufferLen()`, it got the base class's buffer (64 bytes) instead of the `variableBuffer` containing all the polygon data
   - The server received an incomplete/malformed request and evicted the client

2. **Wire Format Mismatch:**
   - Old code header comment claimed 64-byte header, but actual wire format uses 128-byte header
   - Python/Go implementations correctly use 128-byte header format

## Wire Format Specification

Correct wire format for `queryPolygon`:

```
Header (128 bytes):
  offset 0:   vertex_count (u32, 4 bytes)
  offset 4:   hole_count (u32, 4 bytes)
  offset 8:   limit (u32, 4 bytes)
  offset 12:  _reserved_align (u32, 4 bytes)
  offset 16:  timestamp_min (u64, 8 bytes)
  offset 24:  timestamp_max (u64, 8 bytes)
  offset 32:  group_id (u64, 8 bytes)
  offset 40:  reserved (88 bytes)

Followed by:
  - Outer ring vertices (vertex_count * 16 bytes each)
    Each vertex: lat_nano (i64), lon_nano (i64)
  - Hole descriptors (hole_count * 8 bytes each)
    Each descriptor: hole_vertex_count (u32), reserved (u32)
  - Hole vertices (sum of all hole vertex counts * 16 bytes each)
    Each vertex: lat_nano (i64), lon_nano (i64)
```

## Solution

Completely rewrote `NativeQueryPolygonBatch` to follow the same pattern as `NativeQueryUuidBatchRequest`:

1. **Build buffer upfront** - Construct the entire ByteBuffer with correct wire format before passing to parent constructor
2. **Use Batch(ByteBuffer, int) constructor** - Pass pre-built buffer to parent, so base class's `getBuffer()` and `getBufferLen()` methods work correctly
3. **Static factory method** - Implemented `static NativeQueryPolygonBatch create(QueryPolygonFilter filter)` that builds the complete wire format
4. **Correct header size** - Changed from 64 bytes to 128 bytes to match Python/Go implementations

## Files Modified

### `/home/g/archerdb/src/clients/java/src/main/java/com/archerdb/geo/NativeQueryPolygonBatch.java`

Complete rewrite:
- Removed incremental buffer building approach
- Added static `create()` factory method
- Builds complete wire format with correct 128-byte header
- Uses `super(buffer, HEADER_SIZE)` constructor pattern

### `/home/g/archerdb/src/clients/java/src/main/java/com/archerdb/geo/GeoClientImpl.java`

Simplified `createPolygonBatch()` method:
```java
private NativeQueryPolygonBatch createPolygonBatch(QueryPolygonFilter filter) {
    return NativeQueryPolygonBatch.create(filter);
}
```

## Verification

The fix ensures:
1. Correct 128-byte header with proper field layout matching Python/Go
2. Complete buffer passed to native bridge (not just header)
3. Vertices and holes serialized in correct order
4. Buffer size calculation includes header + vertices + hole descriptors + hole vertices

## Testing

To verify the fix works:
1. Compile Java SDK: `cd src/clients/java && mvn clean compile`
2. Start ArcherDB server on port 3006
3. Run test program that executes `queryPolygon()`
4. Should complete without "client eviction" error

The wire format now matches the working Python/Go implementations exactly.
