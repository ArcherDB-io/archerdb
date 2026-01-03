///////////////////////////////////////////////////////
// ArcherDB Node.js SDK - GeoClient                  //
// Connection lifecycle, batching, and query APIs    //
///////////////////////////////////////////////////////

import {
  GeoEvent,
  GeoEventFlags,
  GeoOperation,
  InsertGeoEventError,
  InsertGeoEventsError,
  DeleteEntityError,
  DeleteEntitiesError,
  QueryUuidFilter,
  QueryRadiusFilter,
  QueryPolygonFilter,
  QueryLatestFilter,
  QueryResult,
  DeleteResult,
  GeoEventOptions,
  RadiusQueryOptions,
  PolygonQueryOptions,
  createGeoEvent,
  createRadiusQuery,
  createPolygonQuery,
  BATCH_SIZE_MAX,
  QUERY_LIMIT_MAX,
} from './geo'

// Re-export types for convenience
export * from './geo'

// ============================================================================
// Error Types (per SDK spec)
// ============================================================================

/**
 * Base class for ArcherDB errors.
 * All errors include an error code, message, and retryable flag.
 */
export abstract class ArcherDBError extends Error {
  /**
   * Error code for programmatic handling.
   */
  abstract readonly code: number

  /**
   * Whether this error is safe to retry.
   */
  abstract readonly retryable: boolean

  constructor(message: string) {
    super(message)
    this.name = this.constructor.name
  }
}

// Connection Errors

export class ConnectionFailed extends ArcherDBError {
  readonly code = 1001
  readonly retryable = true
}

export class ConnectionTimeout extends ArcherDBError {
  readonly code = 1002
  readonly retryable = true
}

export class TLSError extends ArcherDBError {
  readonly code = 1003
  readonly retryable = false
}

// Cluster Errors

export class ClusterUnavailable extends ArcherDBError {
  readonly code = 2001
  readonly retryable = true
}

export class ViewChangeInProgress extends ArcherDBError {
  readonly code = 2002
  readonly retryable = true
}

export class NotPrimary extends ArcherDBError {
  readonly code = 2003
  readonly retryable = true
}

// Validation Errors

export class InvalidCoordinates extends ArcherDBError {
  readonly code = 3001
  readonly retryable = false
}

export class PolygonTooComplex extends ArcherDBError {
  readonly code = 3002
  readonly retryable = false
}

export class BatchTooLarge extends ArcherDBError {
  readonly code = 3003
  readonly retryable = false
}

export class InvalidEntityId extends ArcherDBError {
  readonly code = 3004
  readonly retryable = false
}

// Operation Errors

export class OperationTimeout extends ArcherDBError {
  readonly code = 4001
  readonly retryable = true // With caution - may have committed
}

export class QueryResultTooLarge extends ArcherDBError {
  readonly code = 4002
  readonly retryable = false
}

export class OutOfSpace extends ArcherDBError {
  readonly code = 4003
  readonly retryable = false
}

export class SessionExpired extends ArcherDBError {
  readonly code = 4004
  readonly retryable = true
}

// ============================================================================
// Configuration Types
// ============================================================================

/**
 * TLS configuration for secure connections.
 */
export interface TLSConfig {
  /**
   * Path to client certificate file (for mTLS).
   */
  cert_path?: string

  /**
   * Path to client private key file.
   */
  key_path?: string

  /**
   * Path to CA certificate for server validation.
   */
  ca_path?: string
}

/**
 * Client configuration options.
 */
export interface GeoClientConfig {
  /**
   * Cluster ID for connection validation.
   */
  cluster_id: bigint

  /**
   * List of replica addresses (host:port).
   */
  addresses: string[]

  /**
   * TLS configuration (optional).
   */
  tls?: TLSConfig

  /**
   * Connection timeout in milliseconds (default: 5000).
   */
  connect_timeout_ms?: number

  /**
   * Request timeout in milliseconds (default: 30000).
   */
  request_timeout_ms?: number

  /**
   * Number of connection pool slots (default: 1).
   */
  pool_size?: number
}

// ============================================================================
// Batch Builder
// ============================================================================

/**
 * Batch builder for accumulating events before commit.
 *
 * Events are validated immediately when added.
 * The batch enforces a maximum of 10,000 events.
 *
 * @example
 * ```typescript
 * const batch = client.createBatch()
 *
 * // Add events
 * batch.add(event1)
 * batch.add(event2)
 *
 * // Commit atomically
 * const results = await batch.commit()
 * for (const result of results) {
 *   if (result.result !== InsertGeoEventError.ok) {
 *     console.error(`Event ${result.index} failed: ${result.result}`)
 *   }
 * }
 * ```
 */
export class GeoEventBatch {
  private events: GeoEvent[] = []
  private client: GeoClient
  private operation: 'insert' | 'upsert'

  constructor(client: GeoClient, operation: 'insert' | 'upsert' = 'insert') {
    this.client = client
    this.operation = operation
  }

  /**
   * Adds a GeoEvent to the batch.
   *
   * @param event - GeoEvent to add
   * @throws BatchTooLarge if batch is full
   * @throws InvalidCoordinates if coordinates are invalid
   */
  add(event: GeoEvent): void {
    if (this.events.length >= BATCH_SIZE_MAX) {
      throw new BatchTooLarge(`Batch is full (max ${BATCH_SIZE_MAX} events)`)
    }

    // Validate event
    this.validateEvent(event)

    this.events.push(event)
  }

  /**
   * Adds a GeoEvent using user-friendly options.
   *
   * @param options - Event options with user-friendly units
   * @throws BatchTooLarge if batch is full
   * @throws InvalidCoordinates if coordinates are invalid
   */
  addFromOptions(options: GeoEventOptions): void {
    this.add(createGeoEvent(options))
  }

  /**
   * Returns the number of events in the batch.
   */
  count(): number {
    return this.events.length
  }

  /**
   * Returns true if the batch is full (10,000 events).
   */
  isFull(): boolean {
    return this.events.length >= BATCH_SIZE_MAX
  }

  /**
   * Clears all events from the batch.
   */
  clear(): void {
    this.events = []
  }

  /**
   * Commits the batch to the cluster.
   *
   * Blocks until all events are replicated to quorum.
   *
   * @returns Per-event results (only errors are included)
   * @throws OperationTimeout if commit times out
   * @throws ClusterUnavailable if cluster is unreachable
   */
  async commit(): Promise<InsertGeoEventsError[]> {
    if (this.events.length === 0) {
      return []
    }

    const op = this.operation === 'insert'
      ? GeoOperation.insert_events
      : GeoOperation.upsert_events

    const results = await this.client._submitBatch<InsertGeoEventsError>(
      op,
      this.events
    )

    // Clear batch after successful commit
    this.events = []

    return results
  }

  /**
   * Validates a GeoEvent before adding to batch.
   */
  private validateEvent(event: GeoEvent): void {
    // Validate entity_id
    if (event.entity_id === 0n) {
      throw new InvalidEntityId('entity_id must not be zero')
    }

    // Validate latitude (-90 to +90 degrees = -90e9 to +90e9 nanodegrees)
    const lat = event.lat_nano
    if (lat < -90_000_000_000n || lat > 90_000_000_000n) {
      throw new InvalidCoordinates(`Latitude ${lat} out of range [-90e9, +90e9]`)
    }

    // Validate longitude (-180 to +180 degrees = -180e9 to +180e9 nanodegrees)
    const lon = event.lon_nano
    if (lon < -180_000_000_000n || lon > 180_000_000_000n) {
      throw new InvalidCoordinates(`Longitude ${lon} out of range [-180e9, +180e9]`)
    }

    // Validate heading (0-36000 centidegrees)
    if (event.heading_cdeg < 0 || event.heading_cdeg > 36000) {
      throw new InvalidCoordinates(`Heading ${event.heading_cdeg} out of range [0, 36000]`)
    }

    // Validate reserved flag bits are zero
    const reservedFlags = event.flags & ~(
      GeoEventFlags.linked |
      GeoEventFlags.imported |
      GeoEventFlags.stationary |
      GeoEventFlags.low_accuracy |
      GeoEventFlags.offline |
      GeoEventFlags.deleted
    )
    if (reservedFlags !== 0) {
      throw new InvalidEntityId(`Reserved flag bits must be zero, got ${reservedFlags}`)
    }
  }
}

/**
 * Batch builder for entity deletion.
 */
export class DeleteEntityBatch {
  private entityIds: bigint[] = []
  private client: GeoClient

  constructor(client: GeoClient) {
    this.client = client
  }

  /**
   * Adds an entity ID for deletion.
   *
   * @param entityId - Entity UUID to delete
   * @throws BatchTooLarge if batch is full
   */
  add(entityId: bigint): void {
    if (this.entityIds.length >= BATCH_SIZE_MAX) {
      throw new BatchTooLarge(`Batch is full (max ${BATCH_SIZE_MAX} entities)`)
    }
    if (entityId === 0n) {
      throw new InvalidEntityId('entity_id must not be zero')
    }
    this.entityIds.push(entityId)
  }

  /**
   * Returns the number of entities in the batch.
   */
  count(): number {
    return this.entityIds.length
  }

  /**
   * Clears all entity IDs from the batch.
   */
  clear(): void {
    this.entityIds = []
  }

  /**
   * Commits the delete batch to the cluster.
   *
   * @returns Delete operation results
   */
  async commit(): Promise<DeleteResult> {
    if (this.entityIds.length === 0) {
      return { deleted_count: 0, not_found_count: 0 }
    }

    const results = await this.client._submitBatch<DeleteEntitiesError>(
      GeoOperation.delete_entities,
      this.entityIds
    )

    // Calculate summary
    let deleted_count = this.entityIds.length
    let not_found_count = 0

    for (const result of results) {
      if (result.result === DeleteEntityError.entity_not_found) {
        not_found_count++
        deleted_count--
      } else if (result.result !== DeleteEntityError.ok) {
        deleted_count--
      }
    }

    // Clear batch after commit
    this.entityIds = []

    return { deleted_count, not_found_count }
  }
}

// ============================================================================
// GeoClient
// ============================================================================

/**
 * ArcherDB GeoClient for geospatial operations.
 *
 * Provides connection lifecycle management, batch operations,
 * and query APIs for GeoEvent data.
 *
 * @example
 * ```typescript
 * import { createGeoClient } from 'archerdb-node'
 *
 * // Create client
 * const client = createGeoClient({
 *   cluster_id: 0n,
 *   addresses: ['127.0.0.1:3000', '127.0.0.1:3001', '127.0.0.1:3002'],
 * })
 *
 * // Insert events
 * const batch = client.createBatch()
 * batch.addFromOptions({
 *   entity_id: archerdb.id(),
 *   latitude: 37.7749,
 *   longitude: -122.4194,
 * })
 * await batch.commit()
 *
 * // Query by radius
 * const results = await client.queryRadius({
 *   latitude: 37.7749,
 *   longitude: -122.4194,
 *   radius_m: 1000,
 * })
 *
 * // Clean up
 * client.destroy()
 * ```
 */
export class GeoClient {
  private config: Required<GeoClientConfig>
  private context: object | null = null
  private sessionId: bigint = 0n
  private requestNumber: bigint = 0n

  constructor(config: GeoClientConfig) {
    // Apply defaults
    this.config = {
      cluster_id: config.cluster_id,
      addresses: config.addresses,
      tls: config.tls ?? {},
      connect_timeout_ms: config.connect_timeout_ms ?? 5000,
      request_timeout_ms: config.request_timeout_ms ?? 30000,
      pool_size: config.pool_size ?? 1,
    }

    // Validate configuration
    if (this.config.addresses.length === 0) {
      throw new Error('At least one replica address is required')
    }

    // Initialize connection
    this.connect()
  }

  /**
   * Establishes connection to the cluster.
   * Performs primary discovery and session registration.
   */
  private connect(): void {
    // NOTE: This is a skeleton implementation.
    // In the full implementation, this would:
    // 1. Probe all replica addresses in parallel
    // 2. Identify current primary via ping response
    // 3. Establish TCP connection (with TLS if configured)
    // 4. Send register operation to obtain session ID
    // 5. Store session for request idempotency
    //
    // The actual native binding integration would happen here:
    // this.context = binding.init({
    //   cluster_id: this.config.cluster_id,
    //   replica_addresses: Buffer.from(this.config.addresses.join(',')),
    // })

    // Placeholder: mark as connected
    this.context = {}
  }

  /**
   * Destroys the client and releases resources.
   *
   * After calling destroy(), all subsequent operations will throw.
   */
  destroy(): void {
    // NOTE: In full implementation:
    // if (this.context) binding.deinit(this.context)
    this.context = null
  }

  /**
   * Returns true if the client is connected.
   */
  isConnected(): boolean {
    return this.context !== null
  }

  // ============================================================================
  // Batch Operations
  // ============================================================================

  /**
   * Creates a new batch for inserting events.
   *
   * @returns GeoEventBatch for accumulating events
   */
  createBatch(): GeoEventBatch {
    return new GeoEventBatch(this, 'insert')
  }

  /**
   * Creates a new batch for upserting events.
   *
   * Upsert will update existing events or insert new ones.
   *
   * @returns GeoEventBatch for accumulating events
   */
  createUpsertBatch(): GeoEventBatch {
    return new GeoEventBatch(this, 'upsert')
  }

  /**
   * Creates a new batch for deleting entities.
   *
   * @returns DeleteEntityBatch for accumulating entity IDs
   */
  createDeleteBatch(): DeleteEntityBatch {
    return new DeleteEntityBatch(this)
  }

  /**
   * Inserts a single event (convenience method).
   *
   * For high throughput, use createBatch() to batch multiple events.
   *
   * @param event - GeoEvent to insert
   * @returns Insert result (empty array on success)
   */
  async insertEvent(event: GeoEvent): Promise<InsertGeoEventsError[]> {
    const batch = this.createBatch()
    batch.add(event)
    return batch.commit()
  }

  /**
   * Inserts a single event from options (convenience method).
   *
   * @param options - Event options with user-friendly units
   * @returns Insert result
   */
  async insertEventFromOptions(options: GeoEventOptions): Promise<InsertGeoEventsError[]> {
    return this.insertEvent(createGeoEvent(options))
  }

  /**
   * Deletes entities by ID.
   *
   * @param entityIds - Array of entity UUIDs to delete
   * @returns Delete operation results
   */
  async deleteEntities(entityIds: bigint[]): Promise<DeleteResult> {
    const batch = this.createDeleteBatch()
    for (const id of entityIds) {
      batch.add(id)
    }
    return batch.commit()
  }

  // ============================================================================
  // Query Operations
  // ============================================================================

  /**
   * Looks up the latest event for an entity by UUID.
   *
   * @param entityId - Entity UUID to look up
   * @returns Latest GeoEvent or null if not found
   */
  async getLatestByUuid(entityId: bigint): Promise<GeoEvent | null> {
    this.ensureConnected()

    const filter: QueryUuidFilter = {
      entity_id: entityId,
      limit: 1,
    }

    const results = await this._submitQuery<GeoEvent>(
      GeoOperation.query_uuid,
      filter
    )

    return results.length > 0 ? results[0] : null
  }

  /**
   * Batch lookup of latest events for multiple entities.
   *
   * @param entityIds - Array of entity UUIDs (max 10,000)
   * @returns Map of entity_id to GeoEvent
   */
  async getLatestByUuidBatch(entityIds: bigint[]): Promise<Map<bigint, GeoEvent>> {
    if (entityIds.length > BATCH_SIZE_MAX) {
      throw new BatchTooLarge(`Batch exceeds ${BATCH_SIZE_MAX} UUIDs`)
    }

    const result = new Map<bigint, GeoEvent>()

    // NOTE: In full implementation, this would be a single batch query.
    // For skeleton, we iterate (production would batch these).
    for (const id of entityIds) {
      const event = await this.getLatestByUuid(id)
      if (event) {
        result.set(id, event)
      }
    }

    return result
  }

  /**
   * Queries events within a radius.
   *
   * @param options - Radius query options
   * @returns Query results with pagination info
   */
  async queryRadius(options: RadiusQueryOptions): Promise<QueryResult> {
    this.ensureConnected()

    const filter = createRadiusQuery(options)

    if (filter.limit > QUERY_LIMIT_MAX) {
      throw new QueryResultTooLarge(`Limit ${filter.limit} exceeds max ${QUERY_LIMIT_MAX}`)
    }

    const events = await this._submitQuery<GeoEvent>(
      GeoOperation.query_radius,
      filter
    )

    return {
      events,
      has_more: events.length === filter.limit,
      cursor: events.length > 0 ? events[events.length - 1].timestamp : undefined,
    }
  }

  /**
   * Queries events within a polygon.
   *
   * @param options - Polygon query options
   * @returns Query results with pagination info
   */
  async queryPolygon(options: PolygonQueryOptions): Promise<QueryResult> {
    this.ensureConnected()

    const filter = createPolygonQuery(options)

    if (filter.limit > QUERY_LIMIT_MAX) {
      throw new QueryResultTooLarge(`Limit ${filter.limit} exceeds max ${QUERY_LIMIT_MAX}`)
    }

    const events = await this._submitQuery<GeoEvent>(
      GeoOperation.query_polygon,
      filter
    )

    return {
      events,
      has_more: events.length === filter.limit,
      cursor: events.length > 0 ? events[events.length - 1].timestamp : undefined,
    }
  }

  /**
   * Queries the most recent events globally or by group.
   *
   * @param options - Query options (limit, group_id, cursor)
   * @returns Query results with pagination info
   */
  async queryLatest(options?: Partial<QueryLatestFilter>): Promise<QueryResult> {
    this.ensureConnected()

    const filter: QueryLatestFilter = {
      limit: options?.limit ?? 1000,
      group_id: options?.group_id ?? 0n,
      cursor_timestamp: options?.cursor_timestamp ?? 0n,
    }

    if (filter.limit > QUERY_LIMIT_MAX) {
      throw new QueryResultTooLarge(`Limit ${filter.limit} exceeds max ${QUERY_LIMIT_MAX}`)
    }

    const events = await this._submitQuery<GeoEvent>(
      GeoOperation.query_latest,
      filter
    )

    return {
      events,
      has_more: events.length === filter.limit,
      cursor: events.length > 0 ? events[events.length - 1].timestamp : undefined,
    }
  }

  // ============================================================================
  // Internal Methods
  // ============================================================================

  /**
   * Ensures the client is connected.
   * @internal
   */
  private ensureConnected(): void {
    if (!this.context) {
      throw new Error('Client is not connected. Call connect() or create a new client.')
    }
  }

  /**
   * Submits a batch operation to the cluster.
   * @internal
   */
  async _submitBatch<R>(operation: GeoOperation, batch: unknown[]): Promise<R[]> {
    this.ensureConnected()

    // NOTE: This is a skeleton implementation.
    // In the full implementation, this would:
    // 1. Serialize events to wire format
    // 2. Send operation via native binding
    // 3. Wait for quorum replication
    // 4. Parse per-event error codes
    // 5. Handle retries for retryable errors
    //
    // return new Promise((resolve, reject) => {
    //   binding.submit(this.context, operation, batch, (error, results) => {
    //     if (error) reject(error)
    //     else resolve(results as R[])
    //   })
    // })

    // Skeleton: return empty results (success)
    return []
  }

  /**
   * Submits a query operation to the cluster.
   * @internal
   */
  async _submitQuery<R>(operation: GeoOperation, filter: unknown): Promise<R[]> {
    this.ensureConnected()

    // NOTE: This is a skeleton implementation.
    // In the full implementation, this would:
    // 1. Serialize filter to wire format
    // 2. Send query via native binding
    // 3. Parse results
    //
    // return new Promise((resolve, reject) => {
    //   binding.submit(this.context, operation, [filter], (error, results) => {
    //     if (error) reject(error)
    //     else resolve(results as R[])
    //   })
    // })

    // Skeleton: return empty results
    return []
  }
}

// ============================================================================
// Batch Helpers (per client-retry spec)
// ============================================================================

/**
 * Splits a batch of items into smaller chunks for retry scenarios.
 *
 * When a large batch times out, the SDK cannot determine which events succeeded
 * vs failed. Use this helper to split the batch into smaller chunks and retry
 * each chunk individually. The server's idempotency guarantees ensure that
 * any already-committed events will not be duplicated.
 *
 * @param items - Array of events or entity IDs to split
 * @param chunkSize - Maximum size of each chunk (default: 1000)
 * @returns Array of arrays, each containing at most chunkSize items
 *
 * @example
 * ```typescript
 * // Original batch timed out
 * const events = generateLargeEventList()
 *
 * // Split into smaller batches for retry
 * const chunks = splitBatch(events, 500)
 *
 * for (const chunk of chunks) {
 *   const batch = client.createBatch()
 *   for (const event of chunk) {
 *     batch.add(event)
 *   }
 *   try {
 *     await batch.commit()
 *   } catch (e) {
 *     if (e instanceof OperationTimeout) {
 *       // Retry with even smaller chunks
 *       const smallerChunks = splitBatch(chunk, 100)
 *       // ...
 *     }
 *   }
 * }
 * ```
 */
export function splitBatch<T>(items: T[], chunkSize: number = 1000): T[][] {
  if (chunkSize <= 0) {
    throw new Error('chunkSize must be greater than 0')
  }

  if (items.length === 0) {
    return []
  }

  const chunks: T[][] = []
  for (let i = 0; i < items.length; i += chunkSize) {
    chunks.push(items.slice(i, i + chunkSize))
  }
  return chunks
}

// ============================================================================
// Factory Function
// ============================================================================

/**
 * Creates a new GeoClient connected to an ArcherDB cluster.
 *
 * @param config - Client configuration
 * @returns Connected GeoClient instance
 *
 * @example
 * ```typescript
 * const client = createGeoClient({
 *   cluster_id: 0n,
 *   addresses: ['127.0.0.1:3000'],
 * })
 * ```
 */
export function createGeoClient(config: GeoClientConfig): GeoClient {
  return new GeoClient(config)
}
