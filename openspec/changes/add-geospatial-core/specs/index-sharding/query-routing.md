# Shard-Aware Query Routing (F2.6.3)

**Status**: Planning (Deferred for v2)
**Related Issues**: #144

## Overview

Query routing determines how client requests are directed to the appropriate shard(s). The routing strategy depends on the query type:

- **Point queries** (UUID lookup): Single shard
- **Spatial queries** (radius, polygon): Fan-out to all shards

## Query Classification

### Single-Shard Queries

These queries target a specific entity and can be routed to exactly one shard:

| Query Type | Routing Key | Shards Hit |
|------------|-------------|------------|
| `query_uuid` | entity_id | 1 |
| `query_latest_by_entity` | entity_id | 1 |
| `query_history_by_entity` | entity_id | 1 |
| `delete_entities` | entity_id | 1 per entity |
| `insert_events` | entity_id | 1 per event |

**Routing formula**:
```
shard = computeShardBucket(entity_id, num_shards)
```

### Multi-Shard Queries (Fan-out)

Spatial queries cannot be routed to a single shard because entities are distributed by entity_id, not by location:

| Query Type | Routing Strategy | Shards Hit |
|------------|-----------------|------------|
| `query_radius` | Fan-out to all | All |
| `query_polygon` | Fan-out to all | All |
| `query_bounding_box` | Fan-out to all | All |

**Note**: Future optimization could use spatial-aware sharding (by geohash) but this adds complexity for entity updates that change location.

## Routing Architecture

### Option A: Smart Client (Recommended for v2.0)

Client computes shard routing locally:

```
┌──────────────┐
│   Client     │
│  ┌────────┐  │      ┌─────────┐
│  │ Shard  │  │─────>│ Shard 0 │
│  │ Router │  │      └─────────┘
│  └────────┘  │      ┌─────────┐
│              │─────>│ Shard 1 │
│  Topology    │      └─────────┘
│  Cache       │      ┌─────────┐
│              │─────>│ Shard N │
└──────────────┘      └─────────┘
```

**Pros**:
- No coordinator bottleneck
- Lowest latency for single-shard queries
- Scales linearly with clients

**Cons**:
- Clients must maintain topology
- SDK complexity
- Topology changes require client updates

### Option B: Proxy/Coordinator

All requests go through coordinator:

```
┌────────┐      ┌─────────────┐      ┌─────────┐
│ Client │─────>│ Coordinator │─────>│ Shard 0 │
└────────┘      │   (Proxy)   │      └─────────┘
                │             │      ┌─────────┐
                │             │─────>│ Shard 1 │
                │             │      └─────────┘
                │             │      ┌─────────┐
                │             │─────>│ Shard N │
                └─────────────┘      └─────────┘
```

**Pros**:
- Simple client implementation
- Centralized topology management
- Easier debugging/monitoring

**Cons**:
- Coordinator is bottleneck
- Additional hop latency
- Single point of failure (must cluster coordinators)

### Recommendation

**v2.0**: Smart Client with topology discovery
**v2.1+**: Optional coordinator for complex deployments

## Topology Discovery

### Client Bootstrap

1. Client configured with seed nodes: `["shard-0:5000", "shard-5:5000"]`
2. Client connects to any seed node
3. Seed node returns full topology
4. Client caches topology locally

### Topology Format

```json
{
  "version": 42,
  "shards": [
    {
      "id": 0,
      "primary": "node-0:5000",
      "replicas": ["node-1:5000", "node-2:5000"],
      "bucket_mask": "0x0000_0000_0000_000F",
      "status": "active"
    },
    // ... more shards
  ],
  "num_shards": 16
}
```

### Topology Updates

Clients refresh topology when:
1. Periodic refresh (every 60 seconds)
2. Connection failure to expected shard
3. Server returns "shard moved" error

## Query Execution Flow

### Single-Shard Query (query_uuid)

```
1. Client receives: query_uuid(entity_id=0xABCD...)
2. Client computes: shard = hash(0xABCD...) % 16 = 7
3. Client looks up: topology.shards[7].primary = "node-21:5000"
4. Client sends: direct request to node-21:5000
5. Shard executes: ram_index.get(entity_id)
6. Shard returns: GeoEvent or NOT_FOUND
7. Client returns: result to application
```

**Latency**: 1 network round-trip

### Multi-Shard Query (query_radius)

```
1. Client receives: query_radius(lat=37.7, lon=-122.4, radius=1000m)
2. Client identifies: all 16 shards needed
3. Client sends: parallel requests to all shards
4. Each shard executes: spatial_index.query_radius(...)
5. Each shard returns: matching GeoEvents
6. Client aggregates: merge results from all shards
7. Client applies: LIMIT, ORDER BY
8. Client returns: final result set
```

**Latency**: max(shard_latencies) + aggregation

### Batched Write (insert_events)

```
1. Client receives: insert_events([event1, event2, event3, ...])
2. Client groups: events by entity_id → shard
3. Client sends: parallel batch to each affected shard
4. Each shard executes: insert events in batch
5. Each shard returns: results
6. Client merges: results into single response
```

## Aggregation Strategies

### LIMIT Pushdown

For `query_radius(..., limit=100)`:

1. Each shard returns up to 100 results
2. Client merges all results (up to 16 × 100 = 1600)
3. Client sorts merged results
4. Client takes top 100

**Optimization**: If limit is small, request `limit * 2` from each shard to reduce over-fetching.

### ORDER BY Handling

For `query_radius(..., order_by=timestamp DESC)`:

1. Each shard returns results in order
2. Client performs k-way merge of ordered streams
3. Result is correctly ordered without full sort

### COUNT Aggregation

For `count(query_radius(...))`:

1. Each shard returns local count
2. Client sums: `total = sum(shard_counts)`

## Error Handling

### Shard Unavailable

```
1. Client attempts: connect to shard 7 primary
2. Connection fails
3. Client retries: shard 7 replica 1
4. Connection fails
5. Client retries: shard 7 replica 2
6. If all fail: return error to application
7. Trigger: topology refresh
```

### Partial Failure in Fan-out

```
1. Client sends: query_radius to all 16 shards
2. Shards 0-14 return: results
3. Shard 15: times out
4. Client options:
   a. Return partial results with warning
   b. Retry shard 15
   c. Fail entire query
```

**Recommendation**: Configurable per-query behavior
- Default: Return partial results with metadata indicating missing shards
- Strict mode: Fail if any shard fails

### Stale Topology

```
1. Client sends: request to shard 7 at node-21
2. Node-21 responds: "SHARD_MOVED" error with new location
3. Client updates: topology cache
4. Client retries: at new location
```

## Performance Considerations

### Connection Pooling

Clients maintain persistent connections to all shards:
- Pool size per shard: 2-10 connections
- Health check: periodic ping
- Reconnection: exponential backoff

### Request Pipelining

For batch operations, pipeline multiple requests per connection:
- Reduces round-trip overhead
- Requires response correlation

### Compression

For large result sets:
- Enable gzip/lz4 compression
- Threshold: compress if > 1KB
- Benefit: 60-80% size reduction for GeoEvents

## Metrics

### Client-Side Metrics

```
archerdb_client_requests_total{shard="N",type="query_uuid"}
archerdb_client_latency_seconds{shard="N",type="query_radius",quantile="0.99"}
archerdb_client_errors_total{shard="N",error="timeout"}
archerdb_client_topology_refreshes_total
```

### Shard-Side Metrics

```
archerdb_shard_requests_received_total{type="query_uuid"}
archerdb_shard_fanout_latency_seconds{quantile="0.99"}
archerdb_shard_aggregation_size_bytes
```

## SDK Interface

### Zig Client

```zig
const ShardedClient = struct {
    topology: Topology,
    shard_connections: []Connection,

    pub fn queryUuid(self: *ShardedClient, entity_id: u128) !?GeoEvent {
        const shard = self.topology.computeShard(entity_id);
        return self.shard_connections[shard].queryUuid(entity_id);
    }

    pub fn queryRadius(
        self: *ShardedClient,
        lat: f64,
        lon: f64,
        radius_m: f64,
        limit: u32,
    ) ![]GeoEvent {
        // Fan-out to all shards
        var results = std.ArrayList(GeoEvent).init(self.allocator);
        var futures: [MAX_SHARDS]Future = undefined;

        for (self.shard_connections) |conn, i| {
            futures[i] = conn.queryRadiusAsync(lat, lon, radius_m, limit);
        }

        // Gather results
        for (futures[0..self.topology.num_shards]) |future| {
            const shard_results = try future.await();
            try results.appendSlice(shard_results);
        }

        // Sort and limit
        std.sort.sort(GeoEvent, results.items, {}, timestampCompare);
        if (results.items.len > limit) {
            results.shrinkRetainingCapacity(limit);
        }

        return results.toOwnedSlice();
    }
};
```

### Python Client

```python
class ShardedClient:
    def __init__(self, seed_nodes: List[str]):
        self.topology = self._discover_topology(seed_nodes)
        self.connections = self._connect_all_shards()

    def query_uuid(self, entity_id: int) -> Optional[GeoEvent]:
        shard = self.topology.compute_shard(entity_id)
        return self.connections[shard].query_uuid(entity_id)

    def query_radius(self, lat: float, lon: float, radius_m: float, limit: int = 100) -> List[GeoEvent]:
        # Fan-out to all shards in parallel
        with ThreadPoolExecutor(max_workers=len(self.connections)) as executor:
            futures = [
                executor.submit(conn.query_radius, lat, lon, radius_m, limit)
                for conn in self.connections
            ]
            results = []
            for future in as_completed(futures):
                results.extend(future.result())

        # Sort and limit
        results.sort(key=lambda e: e.timestamp, reverse=True)
        return results[:limit]
```

## Testing Plan

1. **Unit tests**: Shard computation correctness
2. **Integration tests**: Multi-shard query correctness
3. **Chaos tests**: Shard failure during fan-out
4. **Performance tests**: Fan-out latency at scale
5. **Consistency tests**: Verify no data loss in aggregation
