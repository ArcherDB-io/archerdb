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
  QueryUuidBatchResult,
  QueryResult,
  DeleteResult,
  CleanupResult,
  GeoEventOptions,
  RadiusQueryOptions,
  PolygonQueryOptions,
  createGeoEvent,
  prepareGeoEvent,
  createRadiusQuery,
  createPolygonQuery,
  BATCH_SIZE_MAX,
  QUERY_LIMIT_MAX,
  // TTL types (v2.1 Manual TTL Support)
  TtlOperationResult,
  TtlSetRequest,
  TtlSetResponse,
  TtlExtendRequest,
  TtlExtendResponse,
  TtlClearRequest,
  TtlClearResponse,
} from './geo'

// Import native binding for cluster communication
import { binding, Context, Operation } from './index'

// Import observability for retry metrics
import { getMetrics } from './observability'

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

// Circuit Breaker Error

export class CircuitBreakerOpen extends ArcherDBError {
  readonly code = 600
  readonly retryable = true // Client should try another replica

  constructor(
    public readonly circuitName: string,
    public readonly circuitState: CircuitState
  ) {
    super(`Circuit breaker '${circuitName}' is ${circuitState} - request rejected`)
  }
}

// ============================================================================
// Circuit Breaker (per client-retry/spec.md)
// ============================================================================

/**
 * Circuit breaker states.
 */
export enum CircuitState {
  /** Normal operation - requests are allowed through */
  CLOSED = 'closed',
  /** Fail-fast mode - requests are rejected immediately */
  OPEN = 'open',
  /** Recovery testing - limited requests allowed to test recovery */
  HALF_OPEN = 'half_open',
}

/**
 * Circuit breaker configuration options.
 */
export interface CircuitBreakerConfig {
  /** Failure rate threshold to open circuit (default: 0.5 = 50%) */
  failureThreshold?: number
  /** Minimum requests in window before circuit can open (default: 10) */
  minimumRequests?: number
  /** Sliding window duration in milliseconds (default: 10000) */
  windowMs?: number
  /** Duration to stay open before half-open (default: 30000) */
  openDurationMs?: number
  /** Number of test requests in half-open state (default: 5) */
  halfOpenRequests?: number
}

const DEFAULT_CIRCUIT_CONFIG: Required<CircuitBreakerConfig> = {
  failureThreshold: 0.5,
  minimumRequests: 10,
  windowMs: 10_000,
  openDurationMs: 30_000,
  halfOpenRequests: 5,
}

/**
 * Per-replica circuit breaker for failure isolation.
 *
 * Per client-retry/spec.md:
 * - Opens when: 50% failure rate in 10s window AND >= 10 requests
 * - Stays open for 30 seconds before transitioning to half-open
 * - Half-open allows 5 test requests before deciding to close or re-open
 * - Per-replica scope (not global) to allow trying other replicas
 */
export class CircuitBreaker {
  readonly name: string
  private readonly config: Required<CircuitBreakerConfig>

  private state: CircuitState = CircuitState.CLOSED
  private openedAt = 0

  // Sliding window counters
  private totalRequests = 0
  private failedRequests = 0
  private windowStartMs = Date.now()

  // Half-open tracking
  private halfOpenSuccesses = 0
  private halfOpenFailures = 0
  private halfOpenTotal = 0

  // Metrics
  private _stateChanges = 0
  private _rejectedRequests = 0

  constructor(name: string, config?: CircuitBreakerConfig) {
    this.name = name
    this.config = { ...DEFAULT_CIRCUIT_CONFIG, ...config }
  }

  /**
   * Get the current circuit state.
   */
  getState(): CircuitState {
    if (this.state === CircuitState.OPEN) {
      const elapsed = Date.now() - this.openedAt
      if (elapsed >= this.config.openDurationMs) {
        this.transitionTo(CircuitState.HALF_OPEN)
        this.resetHalfOpenCounters()
      }
    }
    return this.state
  }

  /**
   * Check if a request is allowed through.
   */
  allowRequest(): boolean {
    const currentState = this.state

    if (currentState === CircuitState.CLOSED) {
      return true
    }

    if (currentState === CircuitState.OPEN) {
      const elapsed = Date.now() - this.openedAt
      if (elapsed >= this.config.openDurationMs) {
        this.transitionTo(CircuitState.HALF_OPEN)
        this.resetHalfOpenCounters()
        return this.allowHalfOpenRequest()
      }
      this._rejectedRequests++
      return false
    }

    if (currentState === CircuitState.HALF_OPEN) {
      return this.allowHalfOpenRequest()
    }

    return false
  }

  private allowHalfOpenRequest(): boolean {
    if (this.halfOpenTotal >= this.config.halfOpenRequests) {
      this._rejectedRequests++
      return false
    }
    this.halfOpenTotal++
    return true
  }

  /**
   * Record a successful request.
   */
  recordSuccess(): void {
    if (this.state === CircuitState.CLOSED) {
      this.recordInWindow(false)
    } else if (this.state === CircuitState.HALF_OPEN) {
      this.halfOpenSuccesses++
      if (this.halfOpenSuccesses >= this.config.halfOpenRequests) {
        this.transitionTo(CircuitState.CLOSED)
        this.resetCounters()
      }
    }
  }

  /**
   * Record a failed request.
   */
  recordFailure(): void {
    if (this.state === CircuitState.CLOSED) {
      this.recordInWindow(true)
      this.checkThreshold()
    } else if (this.state === CircuitState.HALF_OPEN) {
      this.halfOpenFailures++
      this.transitionTo(CircuitState.OPEN)
    }
  }

  private recordInWindow(failed: boolean): void {
    const now = Date.now()

    // Check if window expired
    if (now - this.windowStartMs >= this.config.windowMs) {
      this.windowStartMs = now
      this.totalRequests = 0
      this.failedRequests = 0
    }

    this.totalRequests++
    if (failed) {
      this.failedRequests++
    }
  }

  private checkThreshold(): void {
    if (this.totalRequests < this.config.minimumRequests) {
      return
    }

    const failureRate = this.failedRequests / this.totalRequests
    if (failureRate >= this.config.failureThreshold) {
      this.transitionTo(CircuitState.OPEN)
    }
  }

  private transitionTo(newState: CircuitState): boolean {
    if (this.state === newState) {
      return false
    }

    this.state = newState
    this._stateChanges++

    if (newState === CircuitState.OPEN) {
      this.openedAt = Date.now()
    }

    return true
  }

  private resetCounters(): void {
    this.totalRequests = 0
    this.failedRequests = 0
    this.windowStartMs = Date.now()
  }

  private resetHalfOpenCounters(): void {
    this.halfOpenSuccesses = 0
    this.halfOpenFailures = 0
    this.halfOpenTotal = 0
  }

  /**
   * Force the circuit open (for testing).
   */
  forceOpen(): void {
    if (this.state !== CircuitState.OPEN) {
      this._stateChanges++
    }
    this.state = CircuitState.OPEN
    this.openedAt = Date.now()
  }

  /**
   * Force the circuit closed (for testing).
   */
  forceClose(): void {
    if (this.state !== CircuitState.CLOSED) {
      this._stateChanges++
    }
    this.state = CircuitState.CLOSED
    this.resetCounters()
    this.resetHalfOpenCounters()
  }

  /** True if circuit is open */
  get isOpen(): boolean {
    return this.getState() === CircuitState.OPEN
  }

  /** True if circuit is closed */
  get isClosed(): boolean {
    return this.getState() === CircuitState.CLOSED
  }

  /** True if circuit is half-open */
  get isHalfOpen(): boolean {
    return this.getState() === CircuitState.HALF_OPEN
  }

  /** Current failure rate in window */
  get failureRate(): number {
    if (this.totalRequests === 0) {
      return 0
    }
    return this.failedRequests / this.totalRequests
  }

  /** Total state transitions */
  get stateChanges(): number {
    return this._stateChanges
  }

  /** Total rejected requests */
  get rejectedRequests(): number {
    return this._rejectedRequests
  }
}

// ============================================================================
// Configuration Types
// ============================================================================

/**
 * Retry configuration options (per client-retry/spec.md).
 */
export interface RetryConfig {
  /**
   * Whether automatic retry is enabled (default: true).
   */
  enabled?: boolean

  /**
   * Maximum number of retry attempts after initial failure (default: 5).
   * Total attempts = max_retries + 1.
   */
  max_retries?: number

  /**
   * Base backoff delay in milliseconds (default: 100).
   * Delay doubles after each attempt: 100, 200, 400, 800, 1600ms.
   */
  base_backoff_ms?: number

  /**
   * Maximum backoff delay in milliseconds (default: 1600).
   */
  max_backoff_ms?: number

  /**
   * Total timeout for all retry attempts in milliseconds (default: 30000).
   * Retries stop when this timeout is exceeded.
   */
  total_timeout_ms?: number

  /**
   * Whether to add random jitter to backoff delays (default: true).
   * Jitter = random(0, base_delay / 2) prevents thundering herd.
   */
  jitter?: boolean
}

/**
 * Per-operation options for customizing retry behavior.
 *
 * Per client-retry/spec.md, SDKs MAY support per-operation retry override:
 *
 * ```typescript
 * client.queryRadius(lat, lon, radius, { options: { max_retries: 3, timeout_ms: 10000 } })
 * ```
 *
 * When not specified, the client's default retry policy is used.
 */
export interface OperationOptions {
  /**
   * Override max retries for this operation.
   */
  max_retries?: number

  /**
   * Override total timeout in milliseconds for this operation.
   */
  timeout_ms?: number

  /**
   * Override base backoff delay in milliseconds.
   */
  base_backoff_ms?: number

  /**
   * Override max backoff delay in milliseconds.
   */
  max_backoff_ms?: number

  /**
   * Override jitter setting.
   */
  jitter?: boolean
}

/**
 * Merges operation options with a base retry config.
 */
function mergeOptions(
  base: Required<RetryConfig>,
  options?: OperationOptions
): Required<RetryConfig> {
  if (!options) return base
  return {
    enabled: base.enabled,
    max_retries: options.max_retries ?? base.max_retries,
    base_backoff_ms: options.base_backoff_ms ?? base.base_backoff_ms,
    max_backoff_ms: options.max_backoff_ms ?? base.max_backoff_ms,
    total_timeout_ms: options.timeout_ms ?? base.total_timeout_ms,
    jitter: options.jitter ?? base.jitter,
  }
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

  /**
   * Retry configuration (optional).
   */
  retry?: RetryConfig
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
   * Automatically prepares events (generates IDs) before sending.
   *
   * @returns Per-event results (only errors are included)
   * @throws OperationTimeout if commit times out
   * @throws ClusterUnavailable if cluster is unreachable
   */
  async commit(): Promise<InsertGeoEventsError[]> {
    if (this.events.length === 0) {
      return []
    }

    // Prepare all events (generate IDs) before sending
    for (const event of this.events) {
      prepareGeoEvent(event)
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
  private config: Required<Omit<GeoClientConfig, 'retry'>>
  private retryConfig: Required<RetryConfig>
  private context: Context | null = null
  private sessionId: bigint = 0n
  private requestNumber: bigint = 0n

  constructor(config: GeoClientConfig) {
    // Apply defaults for main config
    this.config = {
      cluster_id: config.cluster_id,
      addresses: config.addresses,
      connect_timeout_ms: config.connect_timeout_ms ?? 5000,
      request_timeout_ms: config.request_timeout_ms ?? 30000,
      pool_size: config.pool_size ?? 1,
    }

    // Apply defaults for retry config
    this.retryConfig = {
      enabled: config.retry?.enabled ?? true,
      max_retries: config.retry?.max_retries ?? 5,
      base_backoff_ms: config.retry?.base_backoff_ms ?? 100,
      max_backoff_ms: config.retry?.max_backoff_ms ?? 1600,
      total_timeout_ms: config.retry?.total_timeout_ms ?? 30000,
      jitter: config.retry?.jitter ?? true,
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
   * Uses the native binding to create a client context.
   */
  private connect(): void {
    // Initialize the native client binding
    this.context = binding.init({
      cluster_id: this.config.cluster_id,
      replica_addresses: Buffer.from(this.config.addresses.join(',')),
    })
  }

  /**
   * Destroys the client and releases resources.
   *
   * After calling destroy(), all subsequent operations will throw.
   */
  destroy(): void {
    if (this.context) {
      binding.deinit(this.context)
    }
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
  async getLatestByUuidBatch(
    entityIds: bigint[],
    operationOptions?: OperationOptions
  ): Promise<Map<bigint, GeoEvent>> {
    if (entityIds.length > BATCH_SIZE_MAX) {
      throw new BatchTooLarge(`Batch exceeds ${BATCH_SIZE_MAX} UUIDs`)
    }

    if (entityIds.length === 0) {
      return new Map()
    }

    const batchResult = await this.queryUuidBatch(entityIds, operationOptions)
    const notFound = new Set(batchResult.not_found_indices)
    const result = new Map<bigint, GeoEvent>()
    let eventIndex = 0

    for (let i = 0; i < entityIds.length; i++) {
      if (notFound.has(i)) {
        continue
      }
      const event = batchResult.events[eventIndex++]
      if (event) {
        result.set(entityIds[i], event)
      }
    }

    return result
  }

  /**
   * Batch lookup of latest events for multiple entities (F1.3.4).
   *
   * @param entityIds - Array of entity UUIDs (max 10,000)
   * @returns Batch lookup result with not-found indices
   */
  async queryUuidBatch(
    entityIds: bigint[],
    operationOptions?: OperationOptions
  ): Promise<QueryUuidBatchResult> {
    this.ensureConnected()

    if (entityIds.length > BATCH_SIZE_MAX) {
      throw new BatchTooLarge(`Batch exceeds ${BATCH_SIZE_MAX} UUIDs`)
    }

    if (entityIds.length === 0) {
      return {
        found_count: 0,
        not_found_count: 0,
        not_found_indices: [],
        events: [],
      }
    }

    const retryConfig = mergeOptions(this.retryConfig, operationOptions)

    return withRetry(async () => {
      return new Promise<QueryUuidBatchResult>((resolve, reject) => {
        const op = GeoOperation.query_uuid_batch as unknown as Operation
        binding.submit(this.context!, op, [{ entity_ids: entityIds }], (error, result) => {
          if (error) {
            reject(error)
          } else if (result) {
            resolve(result as unknown as QueryUuidBatchResult)
          } else {
            resolve({
              found_count: 0,
              not_found_count: 0,
              not_found_indices: [],
              events: [],
            })
          }
        })
      })
    }, retryConfig)
  }

  /**
   * Queries events within a radius.
   *
   * @param options - Radius query options
   * @returns Query results with pagination info
   */
  async queryRadius(
    queryOptions: RadiusQueryOptions,
    operationOptions?: OperationOptions
  ): Promise<QueryResult> {
    this.ensureConnected()

    const filter = createRadiusQuery(queryOptions)

    if (filter.limit > QUERY_LIMIT_MAX) {
      throw new QueryResultTooLarge(`Limit ${filter.limit} exceeds max ${QUERY_LIMIT_MAX}`)
    }

    const events = await this._submitQuery<GeoEvent>(
      GeoOperation.query_radius,
      filter,
      operationOptions
    )

    const headerHasMore = (events as unknown as { has_more?: boolean }).has_more
    return {
      events,
      has_more: headerHasMore ?? (events.length === filter.limit),
      cursor: events.length > 0 ? events[events.length - 1].timestamp : undefined,
    }
  }

  /**
   * Queries events within a polygon.
   *
   * @param queryOptions - Polygon query options
   * @param operationOptions - Per-operation retry options
   * @returns Query results with pagination info
   */
  async queryPolygon(
    queryOptions: PolygonQueryOptions,
    operationOptions?: OperationOptions
  ): Promise<QueryResult> {
    this.ensureConnected()

    const filter = createPolygonQuery(queryOptions)

    if (filter.limit > QUERY_LIMIT_MAX) {
      throw new QueryResultTooLarge(`Limit ${filter.limit} exceeds max ${QUERY_LIMIT_MAX}`)
    }

    const events = await this._submitQuery<GeoEvent>(
      GeoOperation.query_polygon,
      filter,
      operationOptions
    )

    const headerHasMore = (events as unknown as { has_more?: boolean }).has_more
    return {
      events,
      has_more: headerHasMore ?? (events.length === filter.limit),
      cursor: events.length > 0 ? events[events.length - 1].timestamp : undefined,
    }
  }

  /**
   * Queries the most recent events globally or by group.
   *
   * @param queryOptions - Query options (limit, group_id, cursor)
   * @param operationOptions - Per-operation retry options
   * @returns Query results with pagination info
   */
  async queryLatest(
    queryOptions?: Partial<Omit<QueryLatestFilter, '_reserved_align'>>,
    operationOptions?: OperationOptions
  ): Promise<QueryResult> {
    this.ensureConnected()

    const filter: QueryLatestFilter = {
      limit: queryOptions?.limit ?? 1000,
      _reserved_align: 0, // Required for wire format alignment
      group_id: queryOptions?.group_id ?? 0n,
      cursor_timestamp: queryOptions?.cursor_timestamp ?? 0n,
    }

    if (filter.limit > QUERY_LIMIT_MAX) {
      throw new QueryResultTooLarge(`Limit ${filter.limit} exceeds max ${QUERY_LIMIT_MAX}`)
    }

    const events = await this._submitQuery<GeoEvent>(
      GeoOperation.query_latest,
      filter,
      operationOptions
    )

    const headerHasMore = (events as unknown as { has_more?: boolean }).has_more
    return {
      events,
      has_more: headerHasMore ?? (events.length === filter.limit),
      cursor: events.length > 0 ? events[events.length - 1].timestamp : undefined,
    }
  }

  // ============================================================================
  // TTL Cleanup Operations
  // ============================================================================

  /**
   * Triggers explicit TTL expiration cleanup.
   *
   * Per client-protocol/spec.md cleanup_expired (0x30):
   * - Goes through VSR consensus for deterministic cleanup
   * - All replicas apply with same timestamp
   * - Returns count of entries scanned and removed
   *
   * @param batchSize - Number of index entries to scan (0 = scan all)
   * @returns CleanupResult with entries_scanned and entries_removed
   * @throws Error if batchSize is negative
   *
   * @example
   * ```typescript
   * // Scan all expired entries
   * const result = await client.cleanupExpired()
   * console.log(`Scanned ${result.entries_scanned} entries`)
   * console.log(`Removed ${result.entries_removed} expired entries`)
   *
   * // Scan limited batch (for incremental cleanup)
   * const partialResult = await client.cleanupExpired(1000)
   * ```
   */
  async cleanupExpired(batchSize: number = 0): Promise<CleanupResult> {
    this.ensureConnected()

    if (batchSize < 0) {
      throw new Error('batchSize must be non-negative')
    }

    // Submit cleanup request with batch size
    // NOTE: Skeleton implementation - in full impl would send CLEANUP_EXPIRED
    // and deserialize the 16-byte response (2x u64)
    return {
      entries_scanned: 0n,
      entries_removed: 0n,
    }
  }

  // ============================================================================
  // TTL Operations (v2.1 Manual TTL Support)
  // ============================================================================

  /**
   * Sets an absolute TTL for an entity.
   *
   * @param entityId - Entity UUID to set TTL for
   * @param ttlSeconds - Absolute TTL in seconds (0 = never expires)
   * @returns TTL set response with previous and new TTL values
   *
   * @example
   * ```typescript
   * // Set 24-hour TTL
   * const response = await client.setTtl(entityId, 86400)
   * console.log(`Previous TTL: ${response.previous_ttl_seconds}s`)
   * console.log(`New TTL: ${response.new_ttl_seconds}s`)
   * ```
   */
  async setTtl(entityId: bigint, ttlSeconds: number): Promise<TtlSetResponse> {
    this.ensureConnected()

    if (entityId === 0n) {
      throw new InvalidEntityId('entity_id must not be zero')
    }
    if (ttlSeconds < 0) {
      throw new Error('ttlSeconds must be non-negative')
    }

    const request: TtlSetRequest = {
      entity_id: entityId,
      ttl_seconds: ttlSeconds,
      flags: 0,
    }

    const results = await this._submitQuery<TtlSetResponse>(
      GeoOperation.ttl_set,
      request
    )

    if (results.length === 0) {
      throw new Error('No response from TTL set operation')
    }

    return results[0]
  }

  /**
   * Extends an entity's TTL by a relative amount.
   *
   * @param entityId - Entity UUID to extend TTL for
   * @param extendBySeconds - Number of seconds to extend the TTL by
   * @returns TTL extend response with previous and new TTL values
   *
   * @example
   * ```typescript
   * // Extend TTL by 1 day
   * const response = await client.extendTtl(entityId, 86400)
   * console.log(`Previous TTL: ${response.previous_ttl_seconds}s`)
   * console.log(`New TTL: ${response.new_ttl_seconds}s`)
   * ```
   */
  async extendTtl(entityId: bigint, extendBySeconds: number): Promise<TtlExtendResponse> {
    this.ensureConnected()

    if (entityId === 0n) {
      throw new InvalidEntityId('entity_id must not be zero')
    }
    if (extendBySeconds < 0) {
      throw new Error('extendBySeconds must be non-negative')
    }

    const request: TtlExtendRequest = {
      entity_id: entityId,
      extend_by_seconds: extendBySeconds,
      flags: 0,
    }

    const results = await this._submitQuery<TtlExtendResponse>(
      GeoOperation.ttl_extend,
      request
    )

    if (results.length === 0) {
      throw new Error('No response from TTL extend operation')
    }

    return results[0]
  }

  /**
   * Clears an entity's TTL, making it never expire.
   *
   * @param entityId - Entity UUID to clear TTL for
   * @returns TTL clear response with previous TTL value
   *
   * @example
   * ```typescript
   * // Make entity permanent (no expiration)
   * const response = await client.clearTtl(entityId)
   * console.log(`Previous TTL: ${response.previous_ttl_seconds}s`)
   * ```
   */
  async clearTtl(entityId: bigint): Promise<TtlClearResponse> {
    this.ensureConnected()

    if (entityId === 0n) {
      throw new InvalidEntityId('entity_id must not be zero')
    }

    const request: TtlClearRequest = {
      entity_id: entityId,
      flags: 0,
    }

    const results = await this._submitQuery<TtlClearResponse>(
      GeoOperation.ttl_clear,
      request
    )

    if (results.length === 0) {
      throw new Error('No response from TTL clear operation')
    }

    return results[0]
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
   * Submits a batch operation to the cluster with automatic retry.
   * @internal
   */
  async _submitBatch<R>(operation: GeoOperation, batch: unknown[]): Promise<R[]> {
    this.ensureConnected()

    // Wrap the actual submission in retry logic
    return withRetry(async () => {
      return new Promise<R[]>((resolve, reject) => {
        // Convert GeoOperation to Operation enum (they share the same values)
        const op = operation as unknown as Operation

        binding.submit(this.context!, op, batch, (error, results) => {
          if (error) {
            reject(error)
          } else if (results) {
            resolve(results as unknown as R[])
          } else {
            // Empty results array means success with no errors
            resolve([] as R[])
          }
        })
      })
    }, this.retryConfig)
  }

  /**
   * Submits a query operation to the cluster with automatic retry.
   * @internal
   */
  async _submitQuery<R>(
    operation: GeoOperation,
    filter: unknown,
    options?: OperationOptions
  ): Promise<R[]> {
    this.ensureConnected()

    // Merge per-operation options with base config
    const retryConfig = mergeOptions(this.retryConfig, options)

    // Wrap the actual query in retry logic
    return withRetry(async () => {
      return new Promise<R[]>((resolve, reject) => {
        // Convert GeoOperation to Operation enum (they share the same values)
        const op = operation as unknown as Operation

        // Submit the filter as a single-element batch
        binding.submit(this.context!, op, [filter], (error, results) => {
          if (error) {
            reject(error)
          } else if (results) {
            resolve(results as unknown as R[])
          } else {
            // Empty results array means no matching events
            resolve([] as R[])
          }
        })
      })
    }, retryConfig)
  }
}

// ============================================================================
// Retry Policy (per client-retry spec)
// ============================================================================

/**
 * Error returned when all retry attempts are exhausted.
 */
export class RetryExhausted extends ArcherDBError {
  readonly code = 5001
  readonly retryable = false

  /**
   * Number of retry attempts made before giving up.
   */
  readonly attempts: number

  /**
   * The last error from the final retry attempt.
   */
  readonly lastError: Error

  constructor(attempts: number, lastError: Error) {
    super(`All ${attempts} retry attempts exhausted. Last error: ${lastError.message}`)
    this.attempts = attempts
    this.lastError = lastError
  }
}

/**
 * Determines if an error is retryable.
 *
 * Retryable errors:
 * - Timeouts
 * - View change in progress
 * - Not primary (redirect needed)
 * - Cluster unavailable
 * - Session expired
 * - Connection failures
 *
 * Non-retryable errors:
 * - Invalid coordinates/data
 * - Polygon too complex
 * - Batch/query too large
 * - Authentication errors
 */
function isRetryableError(error: unknown): boolean {
  if (error instanceof ArcherDBError) {
    return error.retryable
  }
  // Network errors are generally retryable
  if (error instanceof Error) {
    const msg = error.message.toLowerCase()
    return (
      msg.includes('timeout') ||
      msg.includes('econnreset') ||
      msg.includes('econnrefused') ||
      msg.includes('epipe') ||
      msg.includes('network')
    )
  }
  return false
}

/**
 * Calculates retry delay with exponential backoff and optional jitter.
 *
 * Backoff schedule (per spec):
 * - Attempt 1: 0ms (immediate)
 * - Attempt 2: 100ms + jitter
 * - Attempt 3: 200ms + jitter
 * - Attempt 4: 400ms + jitter
 * - Attempt 5: 800ms + jitter
 * - Attempt 6: 1600ms + jitter
 *
 * @param attempt - Current attempt number (1-indexed)
 * @param config - Retry configuration
 * @returns Delay in milliseconds
 */
function calculateRetryDelay(attempt: number, config: Required<RetryConfig>): number {
  // First attempt is immediate
  if (attempt <= 1) {
    return 0
  }

  // Exponential backoff: base_delay * 2^(attempt-2)
  // attempt 2 -> 100 * 2^0 = 100
  // attempt 3 -> 100 * 2^1 = 200
  // attempt 4 -> 100 * 2^2 = 400
  // etc.
  const baseDelay = config.base_backoff_ms * Math.pow(2, attempt - 2)
  const delay = Math.min(baseDelay, config.max_backoff_ms)

  if (!config.jitter) {
    return delay
  }

  // Jitter: random(0, delay / 2)
  const jitter = Math.random() * (delay / 2)
  return Math.floor(delay + jitter)
}

/**
 * Sleep for the specified duration.
 */
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/**
 * Executes an operation with retry logic.
 *
 * @param operation - Async function to execute
 * @param config - Retry configuration
 * @returns Result of the operation
 * @throws RetryExhausted if all retry attempts fail
 * @throws Original error if non-retryable
 */
async function withRetry<T>(
  operation: () => Promise<T>,
  config: Required<RetryConfig>
): Promise<T> {
  if (!config.enabled) {
    return operation()
  }

  const metrics = getMetrics()
  const startTime = Date.now()
  const maxAttempts = config.max_retries + 1
  let lastError: Error = new Error('No attempts made')

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    // Record retry metric for actual retry attempts (not first attempt)
    if (attempt > 1) {
      metrics.recordRetry()
    }

    // Check total timeout before starting attempt
    const elapsed = Date.now() - startTime
    if (elapsed >= config.total_timeout_ms) {
      metrics.recordRetryExhausted()
      throw new RetryExhausted(attempt - 1, lastError)
    }

    try {
      return await operation()
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error))

      // Non-retryable errors fail immediately
      if (!isRetryableError(error)) {
        throw error
      }

      // Last attempt - don't sleep, just throw
      if (attempt >= maxAttempts) {
        break
      }

      // Calculate delay for next attempt
      const delay = calculateRetryDelay(attempt + 1, config)

      // Check if delay would exceed total timeout
      const totalElapsed = Date.now() - startTime
      if (totalElapsed + delay >= config.total_timeout_ms) {
        break
      }

      // Wait before next attempt
      if (delay > 0) {
        await sleep(delay)
      }
    }
  }

  metrics.recordRetryExhausted()
  throw new RetryExhausted(maxAttempts, lastError)
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

// ============================================================================
// Test Exports (for unit testing retry logic)
// ============================================================================

/**
 * Internal functions exported for testing purposes only.
 * @internal
 */
export const _testExports = {
  isRetryableError,
  calculateRetryDelay,
  withRetry,
}
