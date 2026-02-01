# ArcherDB curl Examples

Complete curl examples for all 14 ArcherDB operations. All JSON is minified for easy copy-paste.

## Prerequisites

Start a local ArcherDB server before running these examples:

```bash
# Single node (development)
./zig/zig build run -- --port 3001

# Or run the pre-built binary
./archerdb --port 3001

# Or using Docker
docker run -p 3001:3001 archerdb/archerdb
```

## Quick Health Check

```bash
curl http://localhost:3001/ping
# Response: {"pong":true}
```

---

## Insert Operations

### 1. Insert Single Event

Insert a single geo event with minimal required fields.

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"1001","lat_nano":37774900000,"lon_nano":-122419400000}]}'
```

**Expected response:**
```json
{"results":[{"index":0,"code":0}],"committed":true}
```

### Insert with All Fields

Insert with all optional fields populated.

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"2001","lat_nano":37774900000,"lon_nano":-122419400000,"group_id":1,"ttl_seconds":3600,"altitude_mm":100000,"velocity_mms":15000,"accuracy_mm":5000,"heading_cdeg":9000,"correlation_id":"11111","user_data":"42","flags":4}]}'
```

### Insert Batch (Multiple Events)

Insert 3 events in a single batch.

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"3001","lat_nano":40712800000,"lon_nano":-74006000000},{"entity_id":"3002","lat_nano":40712900000,"lon_nano":-74006100000},{"entity_id":"3003","lat_nano":40713000000,"lon_nano":-74006200000}]}'
```

### Insert Error: Invalid Latitude

Latitude must be in range -90 to +90 degrees (i.e., -90e9 to +90e9 nanodegrees).

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"1001","lat_nano":100000000000,"lon_nano":0}]}'
```

**Expected response:**
```json
{"results":[{"index":0,"code":9,"message":"LAT_OUT_OF_RANGE"}],"committed":false}
```

### Insert Error: Invalid Longitude

Longitude must be in range -180 to +180 degrees.

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"1001","lat_nano":0,"lon_nano":200000000000}]}'
```

**Expected response:**
```json
{"results":[{"index":0,"code":10,"message":"LON_OUT_OF_RANGE"}],"committed":false}
```

### Insert Error: Zero Entity ID

Entity ID cannot be zero.

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"0","lat_nano":40712800000,"lon_nano":-74006000000}]}'
```

**Expected response:**
```json
{"results":[{"index":0,"code":7,"message":"ENTITY_ID_MUST_NOT_BE_ZERO"}],"committed":false}
```

---

## Upsert Operations

### 2. Upsert Event

Insert or update an event. Recommended for idempotent operations.

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"1001","lat_nano":37774900000,"lon_nano":-122419400000}],"mode":"upsert"}'
```

**Expected response (new entity):**
```json
{"results":[{"index":0,"code":0,"updated":false}],"committed":true}
```

**Expected response (existing entity updated):**
```json
{"results":[{"index":0,"code":0,"updated":true}],"committed":true}
```

### Upsert with Updated Location

Update an existing entity's location.

```bash
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":"1001","lat_nano":37775000000,"lon_nano":-122420000000,"group_id":1}],"mode":"upsert"}'
```

---

## Delete Operations

### 3. Delete Entity

Delete all data for a single entity.

```bash
curl -X DELETE http://localhost:3001/entities -H "Content-Type: application/json" -d '{"entity_ids":["1001"]}'
```

**Expected response:**
```json
{"deleted_count":1,"not_found_count":0}
```

### Delete Multiple Entities

Delete multiple entities in one request.

```bash
curl -X DELETE http://localhost:3001/entities -H "Content-Type: application/json" -d '{"entity_ids":["1001","1002","1003"]}'
```

### Delete Non-existent Entity

Deleting an entity that doesn't exist is not an error.

```bash
curl -X DELETE http://localhost:3001/entities -H "Content-Type: application/json" -d '{"entity_ids":["9999999"]}'
```

**Expected response:**
```json
{"deleted_count":0,"not_found_count":1}
```

---

## Query Operations

### 4. Query by UUID (Get Latest)

Get the most recent location for a single entity.

```bash
curl http://localhost:3001/entity/1001
```

**Expected response (found):**
```json
{"event":{"entity_id":"1001","lat_nano":37774900000,"lon_nano":-122419400000,"timestamp_ns":1706745600000000000},"found":true}
```

**Expected response (not found):**
```json
{"event":null,"found":false}
```

### Query with UUID Format

Entity IDs can be in UUID format.

```bash
curl http://localhost:3001/entity/550e8400-e29b-41d4-a716-446655440000
```

### 5. Query UUID Batch

Get latest locations for multiple entities in one request.

```bash
curl -X POST http://localhost:3001/entities/batch -H "Content-Type: application/json" -d '{"entity_ids":["1001","1002","1003"]}'
```

**Expected response:**
```json
{"events":[{"entity_id":"1001","lat_nano":37774900000,"lon_nano":-122419400000},null,{"entity_id":"1003","lat_nano":40712800000,"lon_nano":-74006000000}]}
```

### 6. Query Radius

Find all entities within 1km of a point.

```bash
curl -X POST http://localhost:3001/query/radius -H "Content-Type: application/json" -d '{"center_lat_nano":37774900000,"center_lon_nano":-122419400000,"radius_mm":1000000,"limit":100}'
```

**Note:** `radius_mm` is in millimeters. 1,000,000 mm = 1 km.

**Expected response:**
```json
{"events":[{"entity_id":"1001","lat_nano":37774500000,"lon_nano":-122419000000,"distance_mm":50000}],"has_more":false,"cursor":null}
```

### Query Radius with Group Filter

Filter results by group ID.

```bash
curl -X POST http://localhost:3001/query/radius -H "Content-Type: application/json" -d '{"center_lat_nano":37774900000,"center_lon_nano":-122419400000,"radius_mm":5000000,"group_id":1,"limit":100}'
```

### Query Radius - Empty Result

Query returns empty array when no entities match.

```bash
curl -X POST http://localhost:3001/query/radius -H "Content-Type: application/json" -d '{"center_lat_nano":0,"center_lon_nano":0,"radius_mm":100000,"limit":100}'
```

**Expected response:**
```json
{"events":[],"has_more":false,"cursor":null}
```

### 7. Query Polygon

Find all entities within a rectangular area.

```bash
curl -X POST http://localhost:3001/query/polygon -H "Content-Type: application/json" -d '{"vertices":[{"lat_nano":37790000000,"lon_nano":-122420000000},{"lat_nano":37790000000,"lon_nano":-122390000000},{"lat_nano":37760000000,"lon_nano":-122390000000},{"lat_nano":37760000000,"lon_nano":-122420000000}],"limit":100}'
```

### Query Polygon with Group Filter

Filter polygon results by group ID.

```bash
curl -X POST http://localhost:3001/query/polygon -H "Content-Type: application/json" -d '{"vertices":[{"lat_nano":37790000000,"lon_nano":-122420000000},{"lat_nano":37790000000,"lon_nano":-122390000000},{"lat_nano":37760000000,"lon_nano":-122390000000},{"lat_nano":37760000000,"lon_nano":-122420000000}],"group_id":1,"limit":100}'
```

### Query Polygon Error: Too Few Vertices

Polygon must have at least 3 vertices.

```bash
curl -X POST http://localhost:3001/query/polygon -H "Content-Type: application/json" -d '{"vertices":[{"lat_nano":37790000000,"lon_nano":-122420000000},{"lat_nano":37760000000,"lon_nano":-122420000000}],"limit":100}'
```

**Expected response:**
```json
{"error":{"code":103,"message":"INVALID_POLYGON","details":"Polygon must have at least 3 vertices"}}
```

### 8. Query Latest

Get the most recent events across all entities.

```bash
curl -X POST http://localhost:3001/query/latest -H "Content-Type: application/json" -d '{"limit":100}'
```

**Expected response:**
```json
{"events":[{"entity_id":"1005","lat_nano":37774900000,"lon_nano":-122419400000,"timestamp_ns":1706745700000000000}],"has_more":false,"cursor":null}
```

### Query Latest with Group Filter

Filter latest events by group ID.

```bash
curl -X POST http://localhost:3001/query/latest -H "Content-Type: application/json" -d '{"limit":100,"group_id":1}'
```

### Query Latest with Timestamp Filter

Only return events after a specific timestamp.

```bash
curl -X POST http://localhost:3001/query/latest -H "Content-Type: application/json" -d '{"limit":100,"since_ns":1706745600000000000}'
```

---

## Server Operations

### 9. Ping

Health check endpoint.

```bash
curl http://localhost:3001/ping
```

**Expected response (healthy):**
```json
{"pong":true}
```

### 10. Status

Get server status and statistics.

```bash
curl http://localhost:3001/status
```

**Expected response:**
```json
{"events_count":1234,"entities_count":500,"index_bytes":56789012,"uptime_seconds":3600,"version":"1.0.0","cluster_state":"healthy","node_id":"node-1"}
```

### 11. Topology

Get cluster topology information.

```bash
curl http://localhost:3001/topology
```

**Expected response (single node):**
```json
{"version":1,"num_shards":1,"replication_factor":1,"shards":[{"shard_id":0,"primary":{"node_id":"node-1","address":"127.0.0.1:3001","status":"healthy"},"replicas":[]}]}
```

---

## TTL Operations

### 12. Set TTL

Set time-to-live for an entity (1 hour = 3600 seconds).

```bash
curl -X POST http://localhost:3001/ttl/set -H "Content-Type: application/json" -d '{"entity_id":"1001","ttl_seconds":3600}'
```

**Expected response:**
```json
{"success":true,"expires_at_ns":1706749200000000000}
```

### Set TTL - Entity Not Found

```bash
curl -X POST http://localhost:3001/ttl/set -H "Content-Type: application/json" -d '{"entity_id":"9999999","ttl_seconds":3600}'
```

**Expected response:**
```json
{"error":{"code":3,"message":"ENTITY_NOT_FOUND","details":"Entity 9999999 does not exist"}}
```

### 13. Extend TTL

Add 1 hour to the existing TTL.

```bash
curl -X POST http://localhost:3001/ttl/extend -H "Content-Type: application/json" -d '{"entity_id":"1001","extend_by_seconds":3600}'
```

**Expected response:**
```json
{"success":true,"previous_expires_at_ns":1706749200000000000,"new_expires_at_ns":1706752800000000000}
```

### Extend TTL - No Existing TTL

```bash
curl -X POST http://localhost:3001/ttl/extend -H "Content-Type: application/json" -d '{"entity_id":"1002","extend_by_seconds":3600}'
```

**Expected response:**
```json
{"error":{"code":106,"message":"NO_TTL_SET","details":"Entity 1002 has no TTL to extend"}}
```

### 14. Clear TTL

Remove TTL so entity never expires.

```bash
curl -X POST http://localhost:3001/ttl/clear -H "Content-Type: application/json" -d '{"entity_id":"1001"}'
```

**Expected response:**
```json
{"success":true,"previous_expires_at_ns":1706749200000000000}
```

### Clear TTL - No Existing TTL

Clearing TTL on an entity without TTL is not an error.

```bash
curl -X POST http://localhost:3001/ttl/clear -H "Content-Type: application/json" -d '{"entity_id":"1002"}'
```

**Expected response:**
```json
{"success":true,"previous_expires_at_ns":null}
```

---

## Pagination Example

For large result sets, use cursor-based pagination.

### First Page

```bash
curl -X POST http://localhost:3001/query/radius -H "Content-Type: application/json" -d '{"center_lat_nano":37774900000,"center_lon_nano":-122419400000,"radius_mm":10000000,"limit":100}'
```

**Response includes cursor if more results exist:**
```json
{"events":[...],"has_more":true,"cursor":"eyJsYXN0X2lkIjoxMDB9"}
```

### Next Page

Use the cursor from previous response.

```bash
curl -X POST http://localhost:3001/query/radius -H "Content-Type: application/json" -d '{"center_lat_nano":37774900000,"center_lon_nano":-122419400000,"radius_mm":10000000,"limit":100,"cursor":"eyJsYXN0X2lkIjoxMDB9"}'
```

### Continue Until Complete

Repeat until `has_more` is false:
```json
{"events":[...],"has_more":false,"cursor":null}
```

---

## Common Errors

| Error | Example | Fix |
|-------|---------|-----|
| Invalid latitude | `lat_nano > 90e9` | Use range [-90e9, +90e9] |
| Invalid longitude | `lon_nano > 180e9` | Use range [-180e9, +180e9] |
| Zero entity ID | `entity_id: "0"` | Use non-zero entity ID |
| Batch too large | >10000 events | Split into smaller batches |
| Entity not found | TTL on missing entity | Check entity exists |
| Invalid polygon | < 3 vertices | Provide at least 3 vertices |

---

## Coordinate Conversion Reference

| Location | Latitude | Longitude | lat_nano | lon_nano |
|----------|----------|-----------|----------|----------|
| San Francisco | 37.7749 | -122.4194 | 37774900000 | -122419400000 |
| New York | 40.7128 | -74.0060 | 40712800000 | -74006000000 |
| London | 51.5074 | -0.1278 | 51507400000 | -127800000 |
| Tokyo | 35.6762 | 139.6503 | 35676200000 | 139650300000 |
| Sydney | -33.8688 | 151.2093 | -33868800000 | 151209300000 |
| North Pole | 90.0 | 0.0 | 90000000000 | 0 |
| South Pole | -90.0 | 0.0 | -90000000000 | 0 |

**Formula:**
```
lat_nano = latitude_degrees * 1,000,000,000
lon_nano = longitude_degrees * 1,000,000,000
radius_mm = radius_meters * 1,000
```

---

## See Also

- [API Reference](api-reference.md) - Detailed operation documentation
- [Protocol Reference](protocol.md) - Wire format details
- [Error Codes](error-codes.md) - Complete error reference
