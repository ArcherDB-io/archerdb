// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
///////////////////////////////////////////////////////
// ArcherDB Node.js SDK - Topology Tests              //
// Smart Client Topology Discovery (F5.1)             //
///////////////////////////////////////////////////////

import assert from 'assert'
import {
  ShardStatus,
  shardStatusIsReadable,
  shardStatusIsWritable,
  TopologyChangeType,
  ShardInfo,
  createShardInfo,
  TopologyResponse,
  isResharding,
  TopologyChangeNotification,
  TopologyCache,
  ShardRoutingError,
  NotShardLeaderError,
  ShardRouter,
  ScatterGatherConfig,
  DEFAULT_SCATTER_GATHER_CONFIG,
  ScatterGatherResult,
  mergeResults,
  MAX_SHARDS,
  MAX_REPLICAS_PER_SHARD,
} from './topology'
import { GeoEvent, QueryResult } from './geo'

// ============================================================================
// Test Helpers
// ============================================================================

function createTestTopology(numShards: number, version: bigint): TopologyResponse {
  const shards: ShardInfo[] = []
  for (let i = 0; i < numShards; i++) {
    shards.push(createShardInfo(i, `node${i}:8080`, ShardStatus.active))
  }
  return {
    version,
    cluster_id: 1n,
    num_shards: numShards,
    resharding_status: 0,
    flags: 0,
    shards,
    last_change_ns: BigInt(Date.now() * 1000000),
  }
}

function createTestEvent(entityId: bigint, timestamp: bigint): GeoEvent {
  return {
    id: 0n,
    entity_id: entityId,
    correlation_id: 0n,
    user_data: 0n,
    lat_nano: 0n,
    lon_nano: 0n,
    group_id: 0n,
    timestamp,
    altitude_mm: 0,
    velocity_mms: 0,
    ttl_seconds: 0,
    accuracy_mm: 0,
    heading_cdeg: 0,
    flags: 0,
  }
}

function createTestQueryResult(events: GeoEvent[], has_more = false): QueryResult {
  return { events, has_more }
}

// ============================================================================
// ShardStatus Tests
// ============================================================================

console.log('\n--- ShardStatus Tests ---\n')

{
  console.log('✓ ShardStatus_values')
  assert.strictEqual(ShardStatus.active, 0)
  assert.strictEqual(ShardStatus.syncing, 1)
  assert.strictEqual(ShardStatus.unavailable, 2)
  assert.strictEqual(ShardStatus.migrating, 3)
  assert.strictEqual(ShardStatus.decommissioning, 4)
}

{
  console.log('✓ ShardStatus_isReadable')
  assert.strictEqual(shardStatusIsReadable(ShardStatus.active), true)
  assert.strictEqual(shardStatusIsReadable(ShardStatus.syncing), true)
  assert.strictEqual(shardStatusIsReadable(ShardStatus.unavailable), false)
  assert.strictEqual(shardStatusIsReadable(ShardStatus.migrating), false)
  assert.strictEqual(shardStatusIsReadable(ShardStatus.decommissioning), false)
}

{
  console.log('✓ ShardStatus_isWritable')
  assert.strictEqual(shardStatusIsWritable(ShardStatus.active), true)
  assert.strictEqual(shardStatusIsWritable(ShardStatus.syncing), false)
  assert.strictEqual(shardStatusIsWritable(ShardStatus.unavailable), false)
}

// ============================================================================
// TopologyChangeType Tests
// ============================================================================

console.log('\n--- TopologyChangeType Tests ---\n')

{
  console.log('✓ TopologyChangeType_values')
  assert.strictEqual(TopologyChangeType.leader_change, 0)
  assert.strictEqual(TopologyChangeType.replica_added, 1)
  assert.strictEqual(TopologyChangeType.replica_removed, 2)
  assert.strictEqual(TopologyChangeType.resharding_started, 3)
  assert.strictEqual(TopologyChangeType.resharding_completed, 4)
  assert.strictEqual(TopologyChangeType.status_change, 5)
}

// ============================================================================
// ShardInfo Tests
// ============================================================================

console.log('\n--- ShardInfo Tests ---\n')

{
  console.log('✓ ShardInfo_creation')
  const shard: ShardInfo = {
    id: 0,
    primary: 'node1:8080',
    replicas: ['node2:8080', 'node3:8080'],
    status: ShardStatus.active,
    entity_count: 1000n,
    size_bytes: 2048n,
  }
  assert.strictEqual(shard.id, 0)
  assert.strictEqual(shard.primary, 'node1:8080')
  assert.strictEqual(shard.replicas.length, 2)
  assert.strictEqual(shard.status, ShardStatus.active)
  assert.strictEqual(shard.entity_count, 1000n)
  assert.strictEqual(shard.size_bytes, 2048n)
}

{
  console.log('✓ createShardInfo_helper')
  const shard = createShardInfo(1, 'node1:8080', ShardStatus.syncing)
  assert.strictEqual(shard.id, 1)
  assert.strictEqual(shard.primary, 'node1:8080')
  assert.strictEqual(shard.replicas.length, 0)
  assert.strictEqual(shard.status, ShardStatus.syncing)
}

// ============================================================================
// TopologyResponse Tests
// ============================================================================

console.log('\n--- TopologyResponse Tests ---\n')

{
  console.log('✓ TopologyResponse_creation')
  const topology = createTestTopology(2, 1n)
  assert.strictEqual(topology.version, 1n)
  assert.strictEqual(topology.num_shards, 2)
  assert.strictEqual(topology.resharding_status, 0)
  assert.strictEqual(topology.shards.length, 2)
}

{
  console.log('✓ TopologyResponse_resharding')
  const topology: TopologyResponse = {
    version: 2n,
    cluster_id: 1n,
    num_shards: 4,
    resharding_status: 2,
    flags: 0,
    shards: [],
    last_change_ns: 0n,
  }
  assert.strictEqual(isResharding(topology), true)
}

{
  console.log('✓ TopologyResponse_notResharding')
  const topology = createTestTopology(2, 1n)
  assert.strictEqual(isResharding(topology), false)
}

// ============================================================================
// TopologyCache Tests
// ============================================================================

console.log('\n--- TopologyCache Tests ---\n')

{
  console.log('✓ TopologyCache_initialState')
  const cache = new TopologyCache()
  assert.strictEqual(cache.get(), null)
  assert.strictEqual(cache.getVersion(), 0n)
  assert.strictEqual(cache.getLastRefresh(), null)
  assert.strictEqual(cache.getRefreshCount(), 0)
}

{
  console.log('✓ TopologyCache_update')
  const cache = new TopologyCache()
  const topology = createTestTopology(2, 1n)
  cache.update(topology)
  assert.strictEqual(cache.get(), topology)
  assert.strictEqual(cache.getVersion(), 1n)
  assert.notStrictEqual(cache.getLastRefresh(), null)
  assert.strictEqual(cache.getRefreshCount(), 1)
}

{
  console.log('✓ TopologyCache_computeShard')
  const cache = new TopologyCache()
  cache.update(createTestTopology(4, 1n))

  // Test that different entity IDs get distributed
  const shard1 = cache.computeShard(1n)
  const shard2 = cache.computeShard(2n)
  const shard3 = cache.computeShard(3n)
  const shard4 = cache.computeShard(4n)

  // All should be in valid range
  assert.ok(shard1 >= 0 && shard1 < 4)
  assert.ok(shard2 >= 0 && shard2 < 4)
  assert.ok(shard3 >= 0 && shard3 < 4)
  assert.ok(shard4 >= 0 && shard4 < 4)
}

{
  console.log('✓ TopologyCache_computeShardConsistent')
  const cache = new TopologyCache()
  cache.update(createTestTopology(4, 1n))

  const entityId = 12345n
  const shard1 = cache.computeShard(entityId)
  const shard2 = cache.computeShard(entityId)
  const shard3 = cache.computeShard(entityId)

  assert.strictEqual(shard1, shard2)
  assert.strictEqual(shard2, shard3)
}

{
  console.log('✓ TopologyCache_computeShardNoTopology')
  const cache = new TopologyCache()
  assert.strictEqual(cache.computeShard(123n), 0)
}

{
  console.log('✓ TopologyCache_getShardPrimary')
  const cache = new TopologyCache()
  cache.update(createTestTopology(2, 1n))

  assert.strictEqual(cache.getShardPrimary(0), 'node0:8080')
  assert.strictEqual(cache.getShardPrimary(1), 'node1:8080')
  assert.strictEqual(cache.getShardPrimary(2), null)
  assert.strictEqual(cache.getShardPrimary(-1), null)
}

{
  console.log('✓ TopologyCache_getAllShardPrimaries')
  const cache = new TopologyCache()
  cache.update(createTestTopology(3, 1n))

  const primaries = cache.getAllShardPrimaries()
  assert.strictEqual(primaries.length, 3)
  assert.ok(primaries.includes('node0:8080'))
  assert.ok(primaries.includes('node1:8080'))
  assert.ok(primaries.includes('node2:8080'))
}

{
  console.log('✓ TopologyCache_invalidate')
  const cache = new TopologyCache()
  cache.update(createTestTopology(2, 5n))
  assert.strictEqual(cache.getVersion(), 5n)

  cache.invalidate()
  assert.strictEqual(cache.getVersion(), 0n)
}

{
  console.log('✓ TopologyCache_onChange')
  const cache = new TopologyCache()
  let receivedNotification: TopologyChangeNotification | null = null

  cache.onChange((notification) => {
    receivedNotification = notification
  })

  // Initial update (oldVersion=0) should not notify
  cache.update(createTestTopology(2, 1n))
  assert.strictEqual(receivedNotification, null)

  // Version change should notify
  cache.update(createTestTopology(2, 2n))
  assert.notStrictEqual(receivedNotification, null)
  assert.strictEqual(receivedNotification!.new_version, 2n)
  assert.strictEqual(receivedNotification!.old_version, 1n)
}

{
  console.log('✓ TopologyCache_onChangeUnsubscribe')
  const cache = new TopologyCache()
  let callCount = 0

  const unsubscribe = cache.onChange(() => {
    callCount++
  })

  cache.update(createTestTopology(2, 1n))
  unsubscribe()
  cache.update(createTestTopology(2, 2n))

  assert.strictEqual(callCount, 0)
}

{
  console.log('✓ TopologyCache_getActiveShards')
  const cache = new TopologyCache()
  const topology: TopologyResponse = {
    version: 1n,
    cluster_id: 1n,
    num_shards: 3,
    resharding_status: 0,
    flags: 0,
    shards: [
      createShardInfo(0, 'node0:8080', ShardStatus.active),
      createShardInfo(1, 'node1:8080', ShardStatus.syncing),
      createShardInfo(2, 'node2:8080', ShardStatus.active),
    ],
    last_change_ns: 0n,
  }
  cache.update(topology)

  const active = cache.getActiveShards()
  assert.strictEqual(active.length, 2)
  assert.ok(active.includes(0))
  assert.ok(active.includes(2))
  assert.ok(!active.includes(1))
}

{
  console.log('✓ TopologyCache_getShardCount')
  const cache = new TopologyCache()
  assert.strictEqual(cache.getShardCount(), 0)

  cache.update(createTestTopology(5, 1n))
  assert.strictEqual(cache.getShardCount(), 5)
}

// ============================================================================
// ShardRouter Tests
// ============================================================================

console.log('\n--- ShardRouter Tests ---\n')

{
  console.log('✓ ShardRouter_routeByEntityId')
  const cache = new TopologyCache()
  cache.update(createTestTopology(4, 1n))
  const router = new ShardRouter(cache)

  const result = router.routeByEntityId(12345n)
  assert.ok(result.shardId >= 0 && result.shardId < 4)
  assert.ok(result.primary.includes(':8080'))
}

{
  console.log('✓ ShardRouter_routeByEntityIdNoPrimary')
  const cache = new TopologyCache()
  const router = new ShardRouter(cache)

  assert.throws(() => {
    router.routeByEntityId(1n)
  }, ShardRoutingError)
}

{
  console.log('✓ ShardRouter_handleNotShardLeader')
  const cache = new TopologyCache()
  let refreshCalled = false
  const router = new ShardRouter(cache, async () => {
    refreshCalled = true
    return true
  })

  const error = new NotShardLeaderError(0, 'newleader:8080')
  router.handleNotShardLeader(error).then((shouldRetry) => {
    assert.strictEqual(shouldRetry, true)
    assert.strictEqual(refreshCalled, true)
    console.log('✓ ShardRouter_handleNotShardLeader (async)')
  })
}

{
  console.log('✓ ShardRouter_getAllPrimaries')
  const cache = new TopologyCache()
  cache.update(createTestTopology(3, 1n))
  const router = new ShardRouter(cache)

  const primaries = router.getAllPrimaries()
  assert.strictEqual(primaries.length, 3)
}

// ============================================================================
// Exception Tests
// ============================================================================

console.log('\n--- Exception Tests ---\n')

{
  console.log('✓ ShardRoutingError')
  const error = new ShardRoutingError(5, 'No primary for shard')
  assert.strictEqual(error.shardId, 5)
  assert.strictEqual(error.message, 'No primary for shard')
  assert.strictEqual(error.name, 'ShardRoutingError')
}

{
  console.log('✓ NotShardLeaderError_withHint')
  const error = new NotShardLeaderError(2, 'newleader:8080')
  assert.strictEqual(error.shardId, 2)
  assert.strictEqual(error.leaderHint, 'newleader:8080')
  assert.ok(error.message.includes('newleader:8080'))
}

{
  console.log('✓ NotShardLeaderError_withoutHint')
  const error = new NotShardLeaderError(3)
  assert.strictEqual(error.shardId, 3)
  assert.strictEqual(error.leaderHint, null)
  assert.ok(error.message.includes('shard 3'))
}

// ============================================================================
// ScatterGatherConfig Tests
// ============================================================================

console.log('\n--- ScatterGatherConfig Tests ---\n')

{
  console.log('✓ ScatterGatherConfig_defaults')
  assert.strictEqual(DEFAULT_SCATTER_GATHER_CONFIG.maxConcurrency, 0)
  assert.strictEqual(DEFAULT_SCATTER_GATHER_CONFIG.allowPartialResults, true)
  assert.strictEqual(DEFAULT_SCATTER_GATHER_CONFIG.timeoutMs, 30000)
}

{
  console.log('✓ ScatterGatherConfig_custom')
  const config: ScatterGatherConfig = {
    maxConcurrency: 4,
    allowPartialResults: false,
    timeoutMs: 10000,
  }
  assert.strictEqual(config.maxConcurrency, 4)
  assert.strictEqual(config.allowPartialResults, false)
  assert.strictEqual(config.timeoutMs, 10000)
}

// ============================================================================
// ScatterGatherResult Tests
// ============================================================================

console.log('\n--- ScatterGatherResult Tests ---\n')

{
  console.log('✓ mergeResults_basic')
  const results: QueryResult[] = [
    createTestQueryResult([createTestEvent(100n, 100n), createTestEvent(200n, 200n)]),
    createTestQueryResult([createTestEvent(150n, 150n), createTestEvent(250n, 250n)]),
  ]

  const merged = mergeResults(results)
  assert.strictEqual(merged.events.length, 4)
  // Verify sorted by timestamp descending
  for (let i = 0; i < merged.events.length - 1; i++) {
    assert.ok(merged.events[i].timestamp >= merged.events[i + 1].timestamp)
  }
}

{
  console.log('✓ mergeResults_deduplicate')
  const oldEvent = createTestEvent(1n, 100n)
  const newEvent = createTestEvent(1n, 200n)

  const results: QueryResult[] = [createTestQueryResult([oldEvent]), createTestQueryResult([newEvent])]

  const merged = mergeResults(results)
  assert.strictEqual(merged.events.length, 1)
  assert.strictEqual(merged.events[0].timestamp, 200n)
}

{
  console.log('✓ mergeResults_withLimit')
  const results: QueryResult[] = [
    createTestQueryResult([createTestEvent(100n, 100n), createTestEvent(200n, 200n), createTestEvent(300n, 300n)]),
    createTestQueryResult([createTestEvent(150n, 150n), createTestEvent(250n, 250n), createTestEvent(350n, 350n)]),
  ]

  const merged = mergeResults(results, 3)
  assert.strictEqual(merged.events.length, 3)
  assert.strictEqual(merged.hasMore, true)
}

{
  console.log('✓ mergeResults_hasMore')
  const results: QueryResult[] = [createTestQueryResult([], true), createTestQueryResult([], false)]

  const merged = mergeResults(results)
  assert.strictEqual(merged.hasMore, true)
}

{
  console.log('✓ mergeResults_shardResults')
  const results: QueryResult[] = [
    createTestQueryResult([createTestEvent(100n, 100n), createTestEvent(200n, 200n)]),
    createTestQueryResult([createTestEvent(150n, 150n)]),
  ]

  const merged = mergeResults(results)
  assert.strictEqual(merged.shardResults.get(0), 2)
  assert.strictEqual(merged.shardResults.get(1), 1)
}

// ============================================================================
// Constants Tests
// ============================================================================

console.log('\n--- Constants Tests ---\n')

{
  console.log('✓ MAX_SHARDS')
  assert.strictEqual(MAX_SHARDS, 256)
}

{
  console.log('✓ MAX_REPLICAS_PER_SHARD')
  assert.strictEqual(MAX_REPLICAS_PER_SHARD, 6)
}

console.log('\n=== All topology tests passed! ===\n')
