# ArcherDB Protocol Reference

ArcherDB uses HTTP/JSON for client communication. This document provides complete wire format details for custom client implementers.

> **Note:** For most use cases, we recommend using one of the official [SDKs](api-reference.md) rather than implementing the protocol directly.

## Data Types

### Coordinate Encoding

ArcherDB uses integer coordinates for precision and performance:

| Type | Unit | Range | Description |
|------|------|-------|-------------|
| `lat_nano` | nanodegrees (i64) | -90,000,000,000 to +90,000,000,000 | Latitude |
| `lon_nano` | nanodegrees (i64) | -180,000,000,000 to +180,000,000,000 | Longitude |
| `altitude_mm` | millimeters (i32) | -10,000,000 to +100,000,000 | Altitude (-10km to +100km) |
| `velocity_mms` | mm/second (u32) | 0 to 1,000,000,000 | Speed (0 to 1000 m/s) |
| `accuracy_mm` | millimeters (u32) | 0 to 4,294,967,295 | GPS accuracy radius |
| `heading_cdeg` | centidegrees (u16) | 0 to 35,999 | Heading (0 = North, 9000 = East) |
| `radius_mm` | millimeters (u64) | 1 to 40,000,000,000 | Query radius |

**Conversion formulas:**
```
latitude_nano = latitude_degrees * 1,000,000,000
longitude_nano = longitude_degrees * 1,000,000,000
altitude_mm = altitude_meters * 1,000
velocity_mms = velocity_mps * 1,000
heading_cdeg = heading_degrees * 100
radius_mm = radius_meters * 1,000
```

**Example:** San Francisco (37.7749, -122.4194) becomes:
- `lat_nano`: 37,774,900,000
- `lon_nano`: -122,419,400,000

**Precision:** Nanodegrees provide ~0.1mm precision at the equator.

### ID Encoding

| Type | Size | JSON Representation | Description |
|------|------|---------------------|-------------|
| Entity ID | u128 | String (decimal or UUID) | Unique identifier for tracked entity |
| Correlation ID | u128 | String | Trip, session, or job correlation |
| User Data | u128 | String | Application-specific metadata |
| Group ID | u64 | Number | Fleet, region, or tenant identifier |

**Entity ID formats accepted:**
- Decimal string: `"1001"`, `"340282366920938463463374607431768211455"`
- UUID string: `"550e8400-e29b-41d4-a716-446655440000"`

### Timestamp

| Type | Unit | Description |
|------|------|-------------|
| `timestamp_ns` | nanoseconds (u64) | Unix epoch nanoseconds |

**Example:** `1706745600000000000` = 2024-02-01 00:00:00 UTC

### TTL (Time-to-Live)

| Type | Unit | Range | Description |
|------|------|-------|-------------|
| `ttl_seconds` | seconds (u32) | 0 to 4,294,967,295 | 0 = never expire |

---

## Operations

ArcherDB supports 14 operations. Each section documents the HTTP method, endpoint, request format, and response format.

### 1. Insert Events (POST /events)

Insert new geo events. Fails if an event with the same `entity_id` already exists (use upsert for idempotent operations).

**Request:**
```json
{
  "events": [
    {
      "entity_id": "1001",
      "lat_nano": 37774900000,
      "lon_nano": -122419400000,
      "group_id": 1,
      "ttl_seconds": 86400,
      "altitude_mm": 100000,
      "velocity_mms": 15000,
      "accuracy_mm": 5000,
      "heading_cdeg": 9000,
      "correlation_id": "11111",
      "user_data": "42",
      "flags": 0
    }
  ],
  "mode": "insert"
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `events` | array | Yes | Array of events (1 to 10,000) |
| `events[].entity_id` | string | Yes | Unique entity identifier (non-zero) |
| `events[].lat_nano` | i64 | Yes | Latitude in nanodegrees |
| `events[].lon_nano` | i64 | Yes | Longitude in nanodegrees |
| `events[].group_id` | u64 | No | Fleet/tenant identifier |
| `events[].ttl_seconds` | u32 | No | Time-to-live (0 = never expire) |
| `events[].altitude_mm` | i32 | No | Altitude in millimeters |
| `events[].velocity_mms` | u32 | No | Speed in mm/second |
| `events[].accuracy_mm` | u32 | No | GPS accuracy in mm |
| `events[].heading_cdeg` | u16 | No | Heading in centidegrees |
| `events[].correlation_id` | string | No | Correlation identifier |
| `events[].user_data` | string | No | Application metadata |
| `events[].flags` | u16 | No | Application-defined flags |
| `mode` | string | No | `"insert"` (default) or `"upsert"` |

**Response (success):**
```json
{
  "results": [
    {"index": 0, "code": 0}
  ],
  "committed": true
}
```

**Response (validation error):**
```json
{
  "results": [
    {"index": 0, "code": 9, "message": "LAT_OUT_OF_RANGE"}
  ],
  "committed": false
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `results` | array | Per-event results (same order as request) |
| `results[].index` | u32 | Index in original batch |
| `results[].code` | u16 | Result code (0 = success) |
| `results[].message` | string | Error message (if code != 0) |
| `committed` | bool | True if batch committed |

**Common Error Codes:**

| Code | Name | Description |
|------|------|-------------|
| 0 | OK | Success |
| 7 | ENTITY_ID_MUST_NOT_BE_ZERO | Entity ID cannot be zero |
| 9 | LAT_OUT_OF_RANGE | Latitude outside -90 to +90 |
| 10 | LON_OUT_OF_RANGE | Longitude outside -180 to +180 |

---

### 2. Upsert Events (POST /events with mode=upsert)

Insert or update geo events. If an event with the same `entity_id` exists, it is updated. Recommended for idempotent operations.

**Request:**
```json
{
  "events": [
    {
      "entity_id": "1001",
      "lat_nano": 37774900000,
      "lon_nano": -122419400000,
      "group_id": 1
    }
  ],
  "mode": "upsert"
}
```

**Response (created new):**
```json
{
  "results": [
    {"index": 0, "code": 0, "updated": false}
  ],
  "committed": true
}
```

**Response (updated existing):**
```json
{
  "results": [
    {"index": 0, "code": 0, "updated": true}
  ],
  "committed": true
}
```

**Additional Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `results[].updated` | bool | True if existing event was updated |

---

### 3. Delete Entities (DELETE /entities)

Permanently delete all data for specified entities (supports GDPR erasure).

**Request:**
```json
{
  "entity_ids": ["1001", "1002", "1003"]
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_ids` | array | Yes | Entity IDs to delete (1 to 10,000) |

**Response (success):**
```json
{
  "deleted_count": 2,
  "not_found_count": 1
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `deleted_count` | u32 | Number of entities deleted |
| `not_found_count` | u32 | Number of entities that didn't exist |

**Response (empty request):**
```json
{
  "error": {
    "code": 101,
    "message": "EMPTY_REQUEST",
    "details": "entity_ids array is empty"
  }
}
```

---

### 4. Query by UUID (GET /entity/{id})

Get the most recent location for a single entity.

**Request:**
```
GET /entity/1001
GET /entity/550e8400-e29b-41d4-a716-446655440000
```

**Response (found):**
```json
{
  "event": {
    "entity_id": "1001",
    "lat_nano": 37774900000,
    "lon_nano": -122419400000,
    "group_id": 1,
    "timestamp_ns": 1706745600000000000,
    "ttl_seconds": 86400,
    "altitude_mm": 100000,
    "velocity_mms": 15000,
    "accuracy_mm": 5000,
    "heading_cdeg": 9000
  },
  "found": true
}
```

**Response (not found):**
```json
{
  "event": null,
  "found": false
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `event` | object | GeoEvent data (null if not found) |
| `found` | bool | True if entity exists |

---

### 5. Query UUID Batch (POST /entities/batch)

Get the most recent location for multiple entities in a single request.

**Request:**
```json
{
  "entity_ids": ["1001", "1002", "1003"]
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_ids` | array | Yes | Entity IDs to look up (1 to 10,000) |

**Response (partial match):**
```json
{
  "events": [
    {
      "entity_id": "1001",
      "lat_nano": 37774900000,
      "lon_nano": -122419400000,
      "group_id": 1,
      "timestamp_ns": 1706745600000000000
    },
    null,
    {
      "entity_id": "1003",
      "lat_nano": 40712800000,
      "lon_nano": -74006000000,
      "group_id": 2,
      "timestamp_ns": 1706745700000000000
    }
  ]
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `events` | array | Events in same order as request (null for not found) |

**Response (batch too large):**
```json
{
  "error": {
    "code": 300,
    "message": "BATCH_TOO_LARGE",
    "details": "Maximum batch size is 10000"
  }
}
```

---

### 6. Query Radius (POST /query/radius)

Find all entities within a radius of a center point.

**Request:**
```json
{
  "center_lat_nano": 37774900000,
  "center_lon_nano": -122419400000,
  "radius_mm": 1000000,
  "limit": 100,
  "group_id": 1,
  "cursor": null
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `center_lat_nano` | i64 | Yes | Center latitude in nanodegrees |
| `center_lon_nano` | i64 | Yes | Center longitude in nanodegrees |
| `radius_mm` | u64 | Yes | Radius in millimeters (1 to 40,000,000,000) |
| `limit` | u32 | No | Maximum results per page (default: 1000, max: 10000) |
| `group_id` | u64 | No | Filter by group ID |
| `cursor` | string | No | Pagination cursor from previous response |

**Note:** `radius_mm` is radius in millimeters. 1,000,000 mm = 1 km.

**Response (with results):**
```json
{
  "events": [
    {
      "entity_id": "1001",
      "lat_nano": 37774500000,
      "lon_nano": -122419000000,
      "distance_mm": 50000,
      "group_id": 1,
      "timestamp_ns": 1706745600000000000
    },
    {
      "entity_id": "1002",
      "lat_nano": 37775000000,
      "lon_nano": -122418000000,
      "distance_mm": 150000,
      "group_id": 1,
      "timestamp_ns": 1706745650000000000
    }
  ],
  "has_more": true,
  "cursor": "eyJsYXN0X2lkIjogMTAwMn0="
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `events` | array | Matching events |
| `events[].distance_mm` | u64 | Distance from center in millimeters |
| `has_more` | bool | True if more results available |
| `cursor` | string | Cursor for next page (present if has_more) |

**Response (empty):**
```json
{
  "events": [],
  "has_more": false,
  "cursor": null
}
```

**Response (invalid radius):**
```json
{
  "error": {
    "code": 101,
    "message": "INVALID_RADIUS",
    "details": "radius_mm must be positive"
  }
}
```

---

### 7. Query Polygon (POST /query/polygon)

Find all entities within a polygon boundary.

**Request:**
```json
{
  "vertices": [
    {"lat_nano": 37790000000, "lon_nano": -122420000000},
    {"lat_nano": 37790000000, "lon_nano": -122390000000},
    {"lat_nano": 37760000000, "lon_nano": -122390000000},
    {"lat_nano": 37760000000, "lon_nano": -122420000000}
  ],
  "limit": 100,
  "group_id": null,
  "cursor": null
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `vertices` | array | Yes | Polygon vertices (3 to 1000 points) |
| `vertices[].lat_nano` | i64 | Yes | Vertex latitude in nanodegrees |
| `vertices[].lon_nano` | i64 | Yes | Vertex longitude in nanodegrees |
| `limit` | u32 | No | Maximum results per page (default: 1000, max: 10000) |
| `group_id` | u64 | No | Filter by group ID |
| `cursor` | string | No | Pagination cursor from previous response |

**Winding Order:**
- Outer boundary: Counter-clockwise
- Polygon is auto-closed if first and last vertices differ

**Response (with results):**
```json
{
  "events": [
    {
      "entity_id": "1001",
      "lat_nano": 37774900000,
      "lon_nano": -122419400000,
      "group_id": 1,
      "timestamp_ns": 1706745600000000000
    }
  ],
  "has_more": false,
  "cursor": null
}
```

**Response (invalid polygon):**
```json
{
  "error": {
    "code": 103,
    "message": "INVALID_POLYGON",
    "details": "Polygon must have at least 3 vertices"
  }
}
```

---

### 8. Query Latest (POST /query/latest)

Get the most recent events across all entities.

**Request:**
```json
{
  "limit": 100,
  "group_id": 1,
  "since_ns": 1706745600000000000,
  "cursor": null
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `limit` | u32 | No | Maximum results per page (default: 1000, max: 10000) |
| `group_id` | u64 | No | Filter by group ID |
| `since_ns` | u64 | No | Only return events after this timestamp |
| `cursor` | string | No | Pagination cursor from previous response |

**Response (with results):**
```json
{
  "events": [
    {
      "entity_id": "1005",
      "lat_nano": 37774900000,
      "lon_nano": -122419400000,
      "timestamp_ns": 1706745700000000000,
      "group_id": 1
    },
    {
      "entity_id": "1004",
      "lat_nano": 40712800000,
      "lon_nano": -74006000000,
      "timestamp_ns": 1706745650000000000,
      "group_id": 1
    }
  ],
  "has_more": true,
  "cursor": "eyJ0cyI6IDE3MDY3NDU2NTAwMDAwMDAwMDB9"
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `events` | array | Events ordered by timestamp (most recent first) |
| `has_more` | bool | True if more results available |
| `cursor` | string | Cursor for next page (present if has_more) |

**Response (empty):**
```json
{
  "events": [],
  "has_more": false,
  "cursor": null
}
```

---

### 9. Ping (GET /ping)

Health check endpoint. Returns server availability status.

**Request:**
```
GET /ping
```

**Response (healthy):**
```json
{
  "pong": true
}
```

**Response (unhealthy):**

HTTP 503 Service Unavailable
```json
{
  "pong": false,
  "reason": "cluster not ready"
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `pong` | bool | True if server is healthy |
| `reason` | string | Reason for unhealthy status (only if pong=false) |

---

### 10. Status (GET /status)

Get server status and statistics.

**Request:**
```
GET /status
```

**Response:**
```json
{
  "events_count": 125000,
  "entities_count": 42000,
  "index_bytes": 56789012,
  "uptime_seconds": 86400,
  "version": "1.0.0",
  "cluster_state": "healthy",
  "node_id": "node-1"
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `events_count` | u64 | Total number of events stored |
| `entities_count` | u64 | Number of unique entities |
| `index_bytes` | u64 | Size of geospatial index in bytes |
| `uptime_seconds` | u64 | Server uptime in seconds |
| `version` | string | ArcherDB version |
| `cluster_state` | string | Cluster health status |
| `node_id` | string | Identifier of responding node |

---

### 11. Get Topology (GET /topology)

Get cluster topology including shard and replica information.

**Request:**
```
GET /topology
```

**Response (single node):**
```json
{
  "version": 1,
  "num_shards": 1,
  "replication_factor": 1,
  "shards": [
    {
      "shard_id": 0,
      "primary": {
        "node_id": "node-1",
        "address": "127.0.0.1:3001",
        "status": "healthy"
      },
      "replicas": []
    }
  ]
}
```

**Response (clustered):**
```json
{
  "version": 3,
  "num_shards": 4,
  "replication_factor": 3,
  "shards": [
    {
      "shard_id": 0,
      "primary": {
        "node_id": "node-1",
        "address": "10.0.0.1:3001",
        "status": "healthy"
      },
      "replicas": [
        {
          "node_id": "node-2",
          "address": "10.0.0.2:3001",
          "status": "healthy"
        },
        {
          "node_id": "node-3",
          "address": "10.0.0.3:3001",
          "status": "healthy"
        }
      ]
    }
  ]
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `version` | u64 | Topology version (increments on changes) |
| `num_shards` | u32 | Number of shards in cluster |
| `replication_factor` | u32 | Number of replicas per shard |
| `shards` | array | Shard information |
| `shards[].shard_id` | u32 | Shard identifier |
| `shards[].primary` | object | Primary node for this shard |
| `shards[].primary.node_id` | string | Node identifier |
| `shards[].primary.address` | string | Node address (host:port) |
| `shards[].primary.status` | string | Node health status |
| `shards[].replicas` | array | Replica nodes for this shard |

---

### 12. Set TTL (POST /ttl/set)

Set or replace the time-to-live for an entity.

**Request:**
```json
{
  "entity_id": "1001",
  "ttl_seconds": 86400
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_id` | string | Yes | Entity to set TTL on |
| `ttl_seconds` | u32 | Yes | TTL in seconds (0 = never expire) |

**Response (success):**
```json
{
  "success": true,
  "expires_at_ns": 1706832000000000000
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `success` | bool | True if TTL was set |
| `expires_at_ns` | u64 | Expiration timestamp in nanoseconds |

**Response (entity not found):**
```json
{
  "error": {
    "code": 3,
    "message": "ENTITY_NOT_FOUND",
    "details": "Entity 1001 does not exist"
  }
}
```

---

### 13. Extend TTL (POST /ttl/extend)

Extend the time-to-live for an entity by a specified duration.

**Request:**
```json
{
  "entity_id": "1001",
  "extend_by_seconds": 3600
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_id` | string | Yes | Entity to extend TTL on |
| `extend_by_seconds` | u32 | Yes | Seconds to add to current TTL |

**Response (success):**
```json
{
  "success": true,
  "previous_expires_at_ns": 1706832000000000000,
  "new_expires_at_ns": 1706835600000000000
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `success` | bool | True if TTL was extended |
| `previous_expires_at_ns` | u64 | Previous expiration timestamp |
| `new_expires_at_ns` | u64 | New expiration timestamp |

**Response (no existing TTL):**
```json
{
  "error": {
    "code": 106,
    "message": "NO_TTL_SET",
    "details": "Entity 1001 has no TTL to extend"
  }
}
```

---

### 14. Clear TTL (POST /ttl/clear)

Remove the time-to-live for an entity (entity will never expire).

**Request:**
```json
{
  "entity_id": "1001"
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_id` | string | Yes | Entity to clear TTL on |

**Response (success):**
```json
{
  "success": true,
  "previous_expires_at_ns": 1706832000000000000
}
```

**Response (no existing TTL):**
```json
{
  "success": true,
  "previous_expires_at_ns": null
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `success` | bool | Always true if entity exists |
| `previous_expires_at_ns` | u64 | Previous expiration (null if no TTL was set) |

---

## Error Handling

### HTTP Status Codes

| Status | Description |
|--------|-------------|
| 200 | Success |
| 400 | Validation error (bad request format, invalid coordinates) |
| 404 | Not found (entity lookup only) |
| 500 | Internal error |
| 503 | Cluster unavailable |

### Error Response Format

All errors return a JSON object with error details:

```json
{
  "error": {
    "code": 100,
    "message": "INVALID_COORDINATES",
    "details": "latitude 100.0 out of range [-90, +90]"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `error.code` | u16 | Numeric error code |
| `error.message` | string | Error name |
| `error.details` | string | Human-readable description |

### Error Code Ranges

| Range | Category | General Handling |
|-------|----------|------------------|
| 0 | Success | Operation completed |
| 1-99 | Protocol | Check client version, message format |
| 100-199 | Validation | Fix request parameters |
| 200-299 | State | Check cluster health, retry if transient |
| 300-399 | Resource | Reduce batch size, check limits |
| 400-499 | Security | Check authentication, permissions |
| 500-599 | Internal | Contact support |

### Retryable vs Non-Retryable Errors

**Retryable errors** (safe to retry with backoff):
- `211` - Cluster unavailable (no quorum)
- `220` - Not shard leader
- `222` - Resharding in progress
- Network timeouts

**Non-retryable errors** (fix request first):
- `7` - Entity ID must not be zero
- `9` - Latitude out of range
- `10` - Longitude out of range
- `100-199` - Validation errors
- `300` - Batch too large

For complete error reference, see [Error Codes](error-codes.md).

---

## Pagination

All query operations (radius, polygon, latest) use cursor-based pagination.

### Request Parameters

| Field | Type | Description |
|-------|------|-------------|
| `limit` | u32 | Maximum events per page (default: 1000, max: 10000) |
| `cursor` | string | Opaque pagination token from previous response |

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `has_more` | bool | True if more results exist |
| `cursor` | string | Token for next page (present if has_more) |

### Pagination Flow

**1. First request:**
```json
{
  "center_lat_nano": 37774900000,
  "center_lon_nano": -122419400000,
  "radius_mm": 10000000,
  "limit": 100
}
```

**2. Response with cursor:**
```json
{
  "events": [...],
  "has_more": true,
  "cursor": "abc123..."
}
```

**3. Next page request:**
```json
{
  "center_lat_nano": 37774900000,
  "center_lon_nano": -122419400000,
  "radius_mm": 10000000,
  "limit": 100,
  "cursor": "abc123..."
}
```

**4. Continue until:**
```json
{
  "events": [...],
  "has_more": false,
  "cursor": null
}
```

### Best Practices

- Use limit of 1000 for most cases (good balance of latency vs round trips)
- Treat cursors as opaque - do not parse or modify them
- Cursors may expire if underlying data changes significantly
- Results are returned in deterministic order (S2 cell ID based)

---

## Authentication

Authentication is not currently required. All endpoints are open.

Future versions may add:
- API key authentication
- JWT token authentication

---

## Content Types

### Request

All POST/DELETE requests must include:
```
Content-Type: application/json
```

### Response

All responses return:
```
Content-Type: application/json
```

---

## See Also

- [API Reference](api-reference.md) - Operation details and SDK examples
- [Error Codes](error-codes.md) - Complete error reference
- [curl Examples](curl-examples.md) - Working curl examples for all operations
