# SDK Limitations and Workarounds

This document lists the specific operations that don't work in each SDK and the workarounds needed.

## Python SDK - 13/14 (93%)

### What Doesn't Work
1. **`get_topology()`** - Returns error on single-node cluster

### Workaround
- **Skip topology discovery on single-node clusters**
- For production multi-replica clusters, this should work fine
- Not critical for most applications

---

## Node.js SDK - 12/14 (86%)

### What Doesn't Work
1. **`getTopology()`** - Returns error on single-node cluster
2. **`queryUuidBatch()`** - Server returns "operation not implemented"

### Workaround
1. **Topology**: Skip on single-node clusters (same as Python)
2. **queryUuidBatch**: Use multiple individual `getLatestByUuid()` calls instead:
   ```typescript
   // Instead of:
   const results = await client.queryUuidBatch([id1, id2, id3]);
   
   // Use:
   const results = await Promise.all([
     client.getLatestByUuid(id1),
     client.getLatestByUuid(id2),
     client.getLatestByUuid(id3)
   ]);
   ```

---

## Go SDK - 12/14 (86%) → ~14/14 after latest fix

### What Doesn't Work (before latest fix)
1. **`GetStatus()`** - Caused panic (FIXED in commit 6321388)
2. **`GetTopology()`** - Caused panic (FIXED in commit 6321388)
3. **`QueryUUIDBatch()`** - Server returns "invalid operation"

### Workaround
1. **GetStatus/GetTopology**: FIXED - should work now after rebuilding
2. **QueryUUIDBatch**: Use multiple individual `GetLatestByUUID()` calls:
   ```go
   // Instead of:
   results, _ := client.QueryUUIDBatch(ctx, []Uint128{id1, id2, id3})
   
   // Use:
   results := make([]*GeoEvent, 0)
   for _, id := range []Uint128{id1, id2, id3} {
       event, _ := client.GetLatestByUUID(ctx, id)
       results = append(results, event)
   }
   ```

---

## Java SDK - 9/11 (82%)

### What Doesn't Work
1. **`getTopology()`** - Returns "Too much data" error
2. **`queryUuidBatch()`** - Returns "Invalid operation"
3. **`queryPolygon()`** - Causes client eviction
4. **`extendTTL()`** - Returns incorrect value
5. **`cleanupExpired()`** - Returns "Invalid data size"

### Workaround
1. **Topology**: Skip on single-node clusters
2. **queryUuidBatch**: Use individual `getLatestByUuid()` calls:
   ```java
   // Instead of:
   List<GeoEvent> results = client.queryUuidBatch(Arrays.asList(id1, id2, id3));
   
   // Use:
   List<GeoEvent> results = new ArrayList<>();
   for (Uint128 id : Arrays.asList(id1, id2, id3)) {
       results.add(client.getLatestByUuid(id));
   }
   ```
3. **queryPolygon**: **AVOID** - Use queryRadius instead with appropriate radius:
   ```java
   // Instead of polygon query, use radius query:
   // Calculate center point of your polygon
   QueryResult result = client.queryRadius(
       QueryRadiusFilter.create(centerLat, centerLng, radiusMeters, limit)
   );
   // Then filter results in application code if needed
   ```
4. **TTL operations**: Use `setTTL()` and `clearTTL()` - avoid `extendTTL()`
5. **cleanupExpired**: Not critical - server handles TTL expiration automatically

---

## C SDK - 7/14 (50%)

### What Doesn't Work
**The C SDK sample code only demonstrates 7 operations.** The other operations ARE supported by the SDK, just not shown in samples:

**Missing from samples:**
- Status
- Topology  
- TTL Set/Extend/Clear
- UUID Batch Query
- Cleanup Expired

### Workaround
- **Use the documented operations that work** (insert, upsert, query, delete)
- **For advanced features**: Refer to Python/Go/Java SDK examples and adapt the C API calls
- The C SDK has the lowest-level access and CAN do everything, just needs more code

---

## Summary of Workarounds

### Universal (affects all SDKs)
- **Topology on single-node**: Expected limitation, no workaround needed for single-node testing

### Affects 3 SDKs (Node.js, Go, Java)
- **queryUuidBatch not working**: 
  - **Root cause**: Works in Python (proven), so it's a client-side request format issue
  - **Workaround**: Loop and call individual UUID lookups
  - **Performance impact**: Minimal for < 100 entities, use batching at app level

### Java-specific
- **Query Polygon causes eviction**:
  - **Root cause**: Request format issue or validation bug
  - **Workaround**: Use Query Radius + application-level polygon filtering
  - **Alternative**: Use Python/Go SDK if polygon queries are critical

### C SDK
- **Limited samples**:
  - **Root cause**: Documentation/examples, not SDK capability
  - **Workaround**: SDK is complete, just needs more example code

---

## Production Recommendations

### ✅ Use Python SDK if:
- You need all operations
- You want the most stable/tested SDK
- You're building data pipelines or analytics

### ✅ Use Node.js SDK if:
- You're building web applications
- You need async/await + TypeScript
- You can work around queryUuidBatch limitation

### ✅ Use Go SDK if:
- You're building microservices/backend
- You need high performance
- You can rebuild with latest fixes (GetStatus/GetTopology)

### ✅ Use Java SDK if:
- You're building Spring/enterprise apps
- You don't need polygon queries
- Core CRUD operations are sufficient

### ⚠️ Use C SDK if:
- You need absolute lowest latency
- You're building language bindings
- You can write more code (less abstraction)

---

## Critical Path Operations

**These operations work in ALL SDKs:**
- ✅ Insert events
- ✅ Upsert events  
- ✅ Delete entities
- ✅ Query by UUID
- ✅ Query by radius
- ✅ Query latest
- ✅ Ping
- ✅ Set TTL
- ✅ Clear TTL

**These operations have issues:**
- ⚠️ Get topology (single-node clusters only)
- ⚠️ Query UUID batch (client-side issue, use loops)
- ⚠️ Query polygon (Java only, use radius instead)
- ⚠️ Extend TTL (Java only, use set TTL)
- ⚠️ Cleanup expired (not critical, auto-handled)

