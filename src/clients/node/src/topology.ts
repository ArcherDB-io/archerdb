// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
///////////////////////////////////////////////////////
// ArcherDB Node.js SDK - Topology Types              //
// Smart Client Topology Discovery (F5.1)             //
///////////////////////////////////////////////////////

import { GeoEvent, QueryResult } from './geo'

// ============================================================================
// Constants
// ============================================================================

/** Maximum number of shards supported. */
export const MAX_SHARDS = 256

/** Maximum number of replicas per shard. */
export const MAX_REPLICAS_PER_SHARD = 6

// ============================================================================
// Shard Status
// ============================================================================

/**
 * Status of a shard in the cluster.
 */
export enum ShardStatus {
  /** Shard is active and accepting requests. */
  active = 0,
  /** Shard is syncing data (read-only). */
  syncing = 1,
  /** Shard is unavailable. */
  unavailable = 2,
  /** Shard is being migrated during resharding. */
  migrating = 3,
  /** Shard is being decommissioned. */
  decommissioning = 4,
}

/**
 * Returns true if the shard status allows reads.
 */
export function shardStatusIsReadable(status: ShardStatus): boolean {
  return status === ShardStatus.active || status === ShardStatus.syncing
}

/**
 * Returns true if the shard status allows writes.
 */
export function shardStatusIsWritable(status: ShardStatus): boolean {
  return status === ShardStatus.active
}

// ============================================================================
// Topology Change Type
// ============================================================================

/**
 * Type of topology change event.
 */
export enum TopologyChangeType {
  /** Shard leader changed (failover). */
  leader_change = 0,
  /** Replica was added to a shard. */
  replica_added = 1,
  /** Replica was removed from a shard. */
  replica_removed = 2,
  /** Resharding has started. */
  resharding_started = 3,
  /** Resharding has completed. */
  resharding_completed = 4,
  /** Shard status changed. */
  status_change = 5,
}

// ============================================================================
// Shard Info
// ============================================================================

/**
 * Information about a single shard.
 */
export type ShardInfo = {
  /** Shard identifier (0 to num_shards-1). */
  id: number
  /** Primary/leader node address. */
  primary: string
  /** Replica node addresses. */
  replicas: string[]
  /** Current shard status. */
  status: ShardStatus
  /** Approximate number of entities in the shard. */
  entity_count: bigint
  /** Approximate size of the shard in bytes. */
  size_bytes: bigint
}

/**
 * Creates a new ShardInfo with minimal fields.
 */
export function createShardInfo(
  id: number,
  primary: string,
  status: ShardStatus = ShardStatus.active
): ShardInfo {
  return {
    id,
    primary,
    replicas: [],
    status,
    entity_count: 0n,
    size_bytes: 0n,
  }
}

// ============================================================================
// Topology Response
// ============================================================================

/**
 * Cluster topology information.
 */
export type TopologyResponse = {
  /** Topology version number (increments on changes). */
  version: bigint
  /** Cluster identifier. */
  cluster_id: bigint
  /** Number of shards in the cluster. */
  num_shards: number
  /** Resharding status (0=idle, 1=preparing, 2=migrating, 3=finalizing). */
  resharding_status: number
  /** Reserved flags for future use. */
  flags: number
  /** Information about each shard. */
  shards: ShardInfo[]
  /** Timestamp of last topology change (nanoseconds since epoch). */
  last_change_ns: bigint
}

/**
 * Request for topology information (8 bytes).
 */
export type TopologyRequest = {
  reserved: bigint
}

/**
 * Returns true if the cluster is resharding.
 */
export function isResharding(topology: TopologyResponse): boolean {
  return topology.resharding_status !== 0
}

// ============================================================================
// Topology Change Notification
// ============================================================================

/**
 * Notification about a topology change event.
 */
export type TopologyChangeNotification = {
  /** New topology version. */
  new_version: bigint
  /** Previous topology version. */
  old_version: bigint
  /** Type of change (optional). */
  change_type?: TopologyChangeType
  /** Affected shard (optional, -1 if not applicable). */
  affected_shard?: number
  /** Timestamp of change (nanoseconds since epoch). */
  timestamp_ns: bigint
}

// ============================================================================
// Topology Cache
// ============================================================================

/**
 * Callback for topology change notifications.
 */
export type TopologyChangeCallback = (notification: TopologyChangeNotification) => void

/**
 * Thread-safe cache for cluster topology.
 */
export class TopologyCache {
  private topology: TopologyResponse | null = null
  private version = 0n
  private lastRefresh: Date | null = null
  private refreshCount = 0
  private listeners: (TopologyChangeCallback | null)[] = []

  /**
   * Returns the cached topology, or null if not yet fetched.
   */
  get(): TopologyResponse | null {
    return this.topology
  }

  /**
   * Returns the current cached topology version.
   */
  getVersion(): bigint {
    return this.version
  }

  /**
   * Updates the cached topology and notifies subscribers if version changed.
   */
  update(newTopology: TopologyResponse): void {
    if (!newTopology) return

    const oldVersion = this.version
    this.topology = newTopology
    this.version = newTopology.version
    this.lastRefresh = new Date()
    this.refreshCount++

    // Notify subscribers if version changed
    if (newTopology.version !== oldVersion && oldVersion !== 0n) {
      const notification: TopologyChangeNotification = {
        new_version: newTopology.version,
        old_version: oldVersion,
        timestamp_ns: BigInt(Date.now() * 1000000),
      }
      for (const listener of this.listeners) {
        if (listener) {
          try {
            listener(notification)
          } catch {
            // Listener exceptions should not affect other listeners
          }
        }
      }
    }
  }

  /**
   * Marks the cache as stale, forcing a refresh on next access.
   */
  invalidate(): void {
    this.version = 0n
  }

  /**
   * Returns the time of the last topology refresh.
   */
  getLastRefresh(): Date | null {
    return this.lastRefresh
  }

  /**
   * Returns the number of times the cache has been refreshed.
   */
  getRefreshCount(): number {
    return this.refreshCount
  }

  /**
   * Registers a callback to be invoked when the topology changes.
   * Returns a function to unregister the callback.
   */
  onChange(callback: TopologyChangeCallback): () => void {
    this.listeners.push(callback)
    const index = this.listeners.length - 1
    return () => {
      this.listeners[index] = null
    }
  }

  /**
   * Computes the shard ID for a given entity ID using consistent hashing.
   * Uses XOR folding: shard = (lo ^ hi) % num_shards
   */
  computeShard(entityId: bigint): number {
    if (!this.topology || this.topology.num_shards === 0) {
      return 0
    }
    const lo = entityId & 0xFFFFFFFFFFFFFFFFn
    const hi = (entityId >> 64n) & 0xFFFFFFFFFFFFFFFFn
    const hash = lo ^ hi
    // Use BigInt modulo then convert to number
    return Number(hash % BigInt(this.topology.num_shards))
  }

  /**
   * Returns the primary address for a given shard.
   */
  getShardPrimary(shardId: number): string | null {
    if (!this.topology || shardId < 0 || shardId >= this.topology.shards.length) {
      return null
    }
    return this.topology.shards[shardId].primary
  }

  /**
   * Returns all shard primary addresses.
   */
  getAllShardPrimaries(): string[] {
    if (!this.topology) {
      return []
    }
    return this.topology.shards.map((shard) => shard.primary)
  }

  /**
   * Returns true if the cluster is currently resharding.
   */
  isResharding(): boolean {
    return this.topology !== null && this.topology.resharding_status !== 0
  }

  /**
   * Returns the list of active shard IDs.
   */
  getActiveShards(): number[] {
    if (!this.topology) {
      return []
    }
    return this.topology.shards.filter((shard) => shard.status === ShardStatus.active).map((shard) => shard.id)
  }

  /**
   * Returns the number of shards in the cluster.
   */
  getShardCount(): number {
    return this.topology ? this.topology.num_shards : 0
  }
}

// ============================================================================
// Shard Routing Errors
// ============================================================================

/**
 * Error thrown when shard routing fails.
 */
export class ShardRoutingError extends Error {
  readonly shardId: number

  constructor(shardId: number, message: string) {
    super(message)
    this.name = 'ShardRoutingError'
    this.shardId = shardId
  }
}

/**
 * Error thrown when a request is sent to a node that is not the shard leader.
 */
export class NotShardLeaderError extends ShardRoutingError {
  readonly leaderHint: string | null

  constructor(shardId: number, leaderHint: string | null = null) {
    const message = leaderHint ? `Not shard leader, hint: ${leaderHint}` : `Not shard leader for shard ${shardId}`
    super(shardId, message)
    this.name = 'NotShardLeaderError'
    this.leaderHint = leaderHint
  }
}

// ============================================================================
// Shard Router
// ============================================================================

/**
 * Route result containing shard ID and primary address.
 */
export type RouteResult = {
  shardId: number
  primary: string
}

/**
 * Shard-aware request routing.
 */
export class ShardRouter {
  private cache: TopologyCache
  private refreshCallback: (() => Promise<boolean>) | null

  constructor(cache: TopologyCache, refreshCallback?: () => Promise<boolean>) {
    this.cache = cache
    this.refreshCallback = refreshCallback ?? null
  }

  /**
   * Routes an entity ID to its shard and returns the primary address.
   */
  routeByEntityId(entityId: bigint): RouteResult {
    const shardId = this.cache.computeShard(entityId)
    const primary = this.cache.getShardPrimary(shardId)

    if (!primary) {
      throw new ShardRoutingError(shardId, `No primary address for shard ${shardId}`)
    }

    return { shardId, primary }
  }

  /**
   * Handles a NotShardLeaderError by refreshing the topology.
   * Returns true if topology was refreshed and retry should be attempted.
   */
  async handleNotShardLeader(error: NotShardLeaderError): Promise<boolean> {
    if (this.refreshCallback) {
      try {
        return await this.refreshCallback()
      } catch {
        return false
      }
    }
    return false
  }

  /**
   * Returns all shard primary addresses for scatter-gather queries.
   */
  getAllPrimaries(): string[] {
    return this.cache.getAllShardPrimaries()
  }

  /**
   * Returns the underlying topology cache.
   */
  getCache(): TopologyCache {
    return this.cache
  }
}

// ============================================================================
// Scatter-Gather Query Support
// ============================================================================

/**
 * Configuration for scatter-gather query execution.
 */
export type ScatterGatherConfig = {
  /** Maximum number of concurrent shard queries (0 = unlimited). */
  maxConcurrency: number
  /** Allow partial results when some shards fail. */
  allowPartialResults: boolean
  /** Per-shard query timeout in milliseconds. */
  timeoutMs: number
}

/**
 * Default scatter-gather configuration.
 */
export const DEFAULT_SCATTER_GATHER_CONFIG: ScatterGatherConfig = {
  maxConcurrency: 0,
  allowPartialResults: true,
  timeoutMs: 30000,
}

/**
 * Result from a scatter-gather query across multiple shards.
 */
export type ScatterGatherResult = {
  /** Merged events from all shards. */
  events: GeoEvent[]
  /** Per-shard result counts. */
  shardResults: Map<number, number>
  /** Shards that failed during query. */
  partialFailures: Map<number, Error>
  /** True if more results are available. */
  hasMore: boolean
}

/**
 * Merges results from multiple shards, deduplicating by entity ID.
 * Keeps the most recent event when duplicates are found.
 */
export function mergeResults(results: QueryResult[], limit: number = 0): ScatterGatherResult {
  const seen = new Map<bigint, GeoEvent>()
  const shardResults = new Map<number, number>()
  let hasMore = false

  for (let shardId = 0; shardId < results.length; shardId++) {
    const result = results[shardId]
    if (!result) continue

    shardResults.set(shardId, result.events.length)
    if (result.has_more) {
      hasMore = true
    }

    for (const event of result.events) {
      const existing = seen.get(event.entity_id)
      if (!existing || event.timestamp > existing.timestamp) {
        seen.set(event.entity_id, event)
      }
    }
  }

  // Sort by timestamp descending
  let events = Array.from(seen.values()).sort((a, b) => {
    if (b.timestamp > a.timestamp) return 1
    if (b.timestamp < a.timestamp) return -1
    return 0
  })

  // Apply limit
  if (limit > 0 && events.length > limit) {
    events = events.slice(0, limit)
    hasMore = true
  }

  return {
    events,
    shardResults,
    partialFailures: new Map(),
    hasMore,
  }
}
