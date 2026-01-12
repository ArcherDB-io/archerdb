///////////////////////////////////////////////////////
// ArcherDB Node.js SDK - Observability Module        //
// Logging, Metrics, Health Check (per client-sdk spec) //
///////////////////////////////////////////////////////

import { performance } from 'perf_hooks'

/**
 * SDK Observability per client-sdk/spec.md and client-retry/spec.md
 *
 * Logging:
 *   - DEBUG: Connection state changes, request/response details
 *   - INFO: Successful connection, session registration
 *   - WARN: Reconnection, view change handling, retries
 *   - ERROR: Connection failures, unrecoverable errors
 *
 * Metrics:
 *   - archerdb_client_requests_total{operation, status}
 *   - archerdb_client_request_duration_seconds{operation}
 *   - archerdb_client_connections_active
 *   - archerdb_client_reconnections_total
 *   - archerdb_client_session_renewals_total
 *   - archerdb_client_retries_total (per client-retry/spec.md)
 *   - archerdb_client_retry_exhausted_total (per client-retry/spec.md)
 *   - archerdb_client_primary_discoveries_total (per client-retry/spec.md)
 *
 * Health Check:
 *   - Connection status monitoring
 *   - Last successful operation timestamp
 */

// ============================================================================
// Logging Infrastructure
// ============================================================================

/**
 * Log levels for SDK logging.
 */
export enum LogLevel {
  DEBUG = 10,
  INFO = 20,
  WARN = 30,
  ERROR = 40,
}

/**
 * Logger interface for SDK logging.
 * Implement this interface to integrate with your application's logging.
 */
export interface SDKLogger {
  /** Log debug message (connection state, request/response details). */
  debug(message: string, context?: Record<string, unknown>): void

  /** Log info message (successful connection, session registration). */
  info(message: string, context?: Record<string, unknown>): void

  /** Log warning message (reconnection, view change, retries). */
  warn(message: string, context?: Record<string, unknown>): void

  /** Log error message (connection failures, unrecoverable errors). */
  error(message: string, context?: Record<string, unknown>): void
}

/**
 * Default logger using console.
 */
export class ConsoleLogger implements SDKLogger {
  private level: LogLevel
  private name: string

  constructor(name: string = 'archerdb', level: LogLevel = LogLevel.INFO) {
    this.name = name
    this.level = level
  }

  debug(message: string, context?: Record<string, unknown>): void {
    if (this.level <= LogLevel.DEBUG) {
      const contextStr = context ? ` ${JSON.stringify(context)}` : ''
      console.debug(`[${this.name}] DEBUG: ${message}${contextStr}`)
    }
  }

  info(message: string, context?: Record<string, unknown>): void {
    if (this.level <= LogLevel.INFO) {
      const contextStr = context ? ` ${JSON.stringify(context)}` : ''
      console.info(`[${this.name}] INFO: ${message}${contextStr}`)
    }
  }

  warn(message: string, context?: Record<string, unknown>): void {
    if (this.level <= LogLevel.WARN) {
      const contextStr = context ? ` ${JSON.stringify(context)}` : ''
      console.warn(`[${this.name}] WARN: ${message}${contextStr}`)
    }
  }

  error(message: string, context?: Record<string, unknown>): void {
    if (this.level <= LogLevel.ERROR) {
      const contextStr = context ? ` ${JSON.stringify(context)}` : ''
      console.error(`[${this.name}] ERROR: ${message}${contextStr}`)
    }
  }
}

/**
 * Null logger that discards all messages (for testing or disabled logging).
 */
export class NullLogger implements SDKLogger {
  debug(_message: string, _context?: Record<string, unknown>): void {}
  info(_message: string, _context?: Record<string, unknown>): void {}
  warn(_message: string, _context?: Record<string, unknown>): void {}
  error(_message: string, _context?: Record<string, unknown>): void {}
}

// Global default logger
let defaultLogger: SDKLogger = new NullLogger()

/**
 * Configure SDK logging.
 *
 * @param logger - Custom logger instance (defaults to ConsoleLogger)
 * @param debug - If true, enable debug logging (only if using ConsoleLogger)
 *
 * @example
 * ```typescript
 * // Enable debug logging with console logger
 * configureLogging({ debug: true })
 *
 * // Use custom logger
 * configureLogging({ logger: myCustomLogger })
 * ```
 */
export function configureLogging(options?: {
  logger?: SDKLogger
  debug?: boolean
}): void {
  if (options?.logger) {
    defaultLogger = options.logger
  } else {
    const level = options?.debug ? LogLevel.DEBUG : LogLevel.INFO
    defaultLogger = new ConsoleLogger('archerdb', level)
  }
}

/**
 * Get the current SDK logger.
 */
export function getLogger(): SDKLogger {
  return defaultLogger
}

// ============================================================================
// Metrics Infrastructure
// ============================================================================

/**
 * Labels for a metric.
 */
export interface MetricLabels {
  operation?: string
  status?: string
}

/**
 * Thread-safe counter metric.
 */
export class Counter {
  readonly name: string
  readonly description: string
  private values: Map<string, number> = new Map()

  constructor(name: string, description: string) {
    this.name = name
    this.description = description
  }

  /**
   * Increment counter by value.
   */
  inc(labels?: MetricLabels, value: number = 1): void {
    const key = this.labelKey(labels)
    const current = this.values.get(key) ?? 0
    this.values.set(key, current + value)
  }

  /**
   * Get current value for labels.
   */
  get(labels?: MetricLabels): number {
    const key = this.labelKey(labels)
    return this.values.get(key) ?? 0
  }

  /**
   * Get all values with labels.
   */
  getAll(): Array<{ labels: MetricLabels; value: number }> {
    const result: Array<{ labels: MetricLabels; value: number }> = []
    for (const [key, value] of this.values) {
      result.push({ labels: this.parseKey(key), value })
    }
    return result
  }

  /**
   * Reset the counter.
   */
  reset(): void {
    this.values.clear()
  }

  private labelKey(labels?: MetricLabels): string {
    if (!labels) return ''
    return `${labels.operation ?? ''}:${labels.status ?? ''}`
  }

  private parseKey(key: string): MetricLabels {
    if (!key) return {}
    const [operation, status] = key.split(':')
    return {
      operation: operation || undefined,
      status: status || undefined,
    }
  }
}

/**
 * Thread-safe gauge metric.
 */
export class Gauge {
  readonly name: string
  readonly description: string
  private value: number = 0

  constructor(name: string, description: string) {
    this.name = name
    this.description = description
  }

  /**
   * Set gauge value.
   */
  set(value: number): void {
    this.value = value
  }

  /**
   * Increment gauge by value.
   */
  inc(value: number = 1): void {
    this.value += value
  }

  /**
   * Decrement gauge by value.
   */
  dec(value: number = 1): void {
    this.value -= value
  }

  /**
   * Get current value.
   */
  get(): number {
    return this.value
  }

  /**
   * Reset the gauge to zero.
   */
  reset(): void {
    this.value = 0
  }
}

/**
 * Thread-safe histogram metric for request durations.
 */
export class Histogram {
  readonly name: string
  readonly description: string
  readonly buckets: number[]

  private counts: Map<string, Map<number, number>> = new Map()
  private sums: Map<string, number> = new Map()
  private totals: Map<string, number> = new Map()

  static readonly DEFAULT_BUCKETS = [
    0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5,
    0.75, 1.0, 2.5, 5.0, 7.5, 10.0, Infinity,
  ]

  constructor(
    name: string,
    description: string,
    buckets: number[] = Histogram.DEFAULT_BUCKETS
  ) {
    this.name = name
    this.description = description
    this.buckets = buckets
  }

  /**
   * Record an observation.
   */
  observe(value: number, labels?: MetricLabels): void {
    const key = this.labelKey(labels)

    // Update sum and total
    this.sums.set(key, (this.sums.get(key) ?? 0) + value)
    this.totals.set(key, (this.totals.get(key) ?? 0) + 1)

    // Update buckets
    let bucketMap = this.counts.get(key)
    if (!bucketMap) {
      bucketMap = new Map()
      for (const b of this.buckets) {
        bucketMap.set(b, 0)
      }
      this.counts.set(key, bucketMap)
    }

    for (const bucket of this.buckets) {
      if (value <= bucket) {
        bucketMap.set(bucket, (bucketMap.get(bucket) ?? 0) + 1)
      }
    }
  }

  /**
   * Get total observation count.
   */
  getCount(labels?: MetricLabels): number {
    const key = this.labelKey(labels)
    return this.totals.get(key) ?? 0
  }

  /**
   * Get sum of all observations.
   */
  getSum(labels?: MetricLabels): number {
    const key = this.labelKey(labels)
    return this.sums.get(key) ?? 0
  }

  /**
   * Get count for a specific bucket.
   */
  getBucket(bucket: number, labels?: MetricLabels): number {
    const key = this.labelKey(labels)
    const bucketMap = this.counts.get(key)
    return bucketMap?.get(bucket) ?? 0
  }

  /**
   * Reset the histogram.
   */
  reset(): void {
    this.counts.clear()
    this.sums.clear()
    this.totals.clear()
  }

  private labelKey(labels?: MetricLabels): string {
    return labels?.operation ?? ''
  }
}

/**
 * SDK metrics registry.
 *
 * Metrics exposed per client-sdk/spec.md and client-retry/spec.md.
 */
export class SDKMetrics {
  // Request metrics
  readonly requestsTotal = new Counter(
    'archerdb_client_requests_total',
    'Total number of requests by operation and status'
  )
  readonly requestDuration = new Histogram(
    'archerdb_client_request_duration_seconds',
    'Request duration in seconds by operation'
  )

  // Connection metrics
  readonly connectionsActive = new Gauge(
    'archerdb_client_connections_active',
    'Number of active connections'
  )
  readonly reconnectionsTotal = new Counter(
    'archerdb_client_reconnections_total',
    'Total number of reconnection attempts'
  )
  readonly sessionRenewalsTotal = new Counter(
    'archerdb_client_session_renewals_total',
    'Total number of session renewals'
  )

  // Retry metrics (per client-retry/spec.md)
  readonly retriesTotal = new Counter(
    'archerdb_client_retries_total',
    'Total number of retry attempts'
  )
  readonly retryExhaustedTotal = new Counter(
    'archerdb_client_retry_exhausted_total',
    'Total number of operations that exhausted all retry attempts'
  )
  readonly primaryDiscoveriesTotal = new Counter(
    'archerdb_client_primary_discoveries_total',
    'Total number of primary discovery events'
  )

  /**
   * Record a completed request.
   */
  recordRequest(operation: string, status: string, durationSeconds: number): void {
    const labels = { operation, status }
    this.requestsTotal.inc(labels)
    this.requestDuration.observe(durationSeconds, { operation })
  }

  /**
   * Record a new connection being opened.
   */
  recordConnectionOpened(): void {
    this.connectionsActive.inc()
  }

  /**
   * Record a connection being closed.
   */
  recordConnectionClosed(): void {
    this.connectionsActive.dec()
  }

  /**
   * Record a reconnection attempt.
   */
  recordReconnection(): void {
    this.reconnectionsTotal.inc()
  }

  /**
   * Record a session renewal.
   */
  recordSessionRenewal(): void {
    this.sessionRenewalsTotal.inc()
  }

  /**
   * Record a retry attempt (per client-retry/spec.md).
   */
  recordRetry(): void {
    this.retriesTotal.inc()
  }

  /**
   * Record that all retry attempts were exhausted (per client-retry/spec.md).
   */
  recordRetryExhausted(): void {
    this.retryExhaustedTotal.inc()
  }

  /**
   * Record a primary discovery event (per client-retry/spec.md).
   */
  recordPrimaryDiscovery(): void {
    this.primaryDiscoveriesTotal.inc()
  }

  /**
   * Export metrics in Prometheus text format.
   */
  toPrometheus(): string {
    const lines: string[] = []

    // requestsTotal
    lines.push(`# HELP ${this.requestsTotal.name} ${this.requestsTotal.description}`)
    lines.push(`# TYPE ${this.requestsTotal.name} counter`)
    for (const { labels, value } of this.requestsTotal.getAll()) {
      const labelStr = Object.entries(labels)
        .filter(([_, v]) => v)
        .map(([k, v]) => `${k}="${v}"`)
        .join(',')
      if (labelStr) {
        lines.push(`${this.requestsTotal.name}{${labelStr}} ${value}`)
      } else {
        lines.push(`${this.requestsTotal.name} ${value}`)
      }
    }

    // requestDuration histogram
    lines.push(`# HELP ${this.requestDuration.name} ${this.requestDuration.description}`)
    lines.push(`# TYPE ${this.requestDuration.name} histogram`)
    lines.push(`${this.requestDuration.name}_count ${this.requestDuration.getCount()}`)
    lines.push(`${this.requestDuration.name}_sum ${this.requestDuration.getSum()}`)

    // connectionsActive
    lines.push(`# HELP ${this.connectionsActive.name} ${this.connectionsActive.description}`)
    lines.push(`# TYPE ${this.connectionsActive.name} gauge`)
    lines.push(`${this.connectionsActive.name} ${this.connectionsActive.get()}`)

    // reconnectionsTotal
    lines.push(`# HELP ${this.reconnectionsTotal.name} ${this.reconnectionsTotal.description}`)
    lines.push(`# TYPE ${this.reconnectionsTotal.name} counter`)
    lines.push(`${this.reconnectionsTotal.name} ${this.reconnectionsTotal.get()}`)

    // sessionRenewalsTotal
    lines.push(`# HELP ${this.sessionRenewalsTotal.name} ${this.sessionRenewalsTotal.description}`)
    lines.push(`# TYPE ${this.sessionRenewalsTotal.name} counter`)
    lines.push(`${this.sessionRenewalsTotal.name} ${this.sessionRenewalsTotal.get()}`)

    // Retry metrics (per client-retry/spec.md)
    lines.push(`# HELP ${this.retriesTotal.name} ${this.retriesTotal.description}`)
    lines.push(`# TYPE ${this.retriesTotal.name} counter`)
    lines.push(`${this.retriesTotal.name} ${this.retriesTotal.get()}`)

    lines.push(`# HELP ${this.retryExhaustedTotal.name} ${this.retryExhaustedTotal.description}`)
    lines.push(`# TYPE ${this.retryExhaustedTotal.name} counter`)
    lines.push(`${this.retryExhaustedTotal.name} ${this.retryExhaustedTotal.get()}`)

    lines.push(`# HELP ${this.primaryDiscoveriesTotal.name} ${this.primaryDiscoveriesTotal.description}`)
    lines.push(`# TYPE ${this.primaryDiscoveriesTotal.name} counter`)
    lines.push(`${this.primaryDiscoveriesTotal.name} ${this.primaryDiscoveriesTotal.get()}`)

    return lines.join('\n')
  }

  /**
   * Reset all metrics (for testing).
   */
  reset(): void {
    this.requestsTotal.reset()
    this.requestDuration.reset()
    this.connectionsActive.reset()
    this.reconnectionsTotal.reset()
    this.sessionRenewalsTotal.reset()
    this.retriesTotal.reset()
    this.retryExhaustedTotal.reset()
    this.primaryDiscoveriesTotal.reset()
  }
}

// Global metrics registry
let globalMetrics: SDKMetrics | null = null

/**
 * Get or create the global metrics registry.
 */
export function getMetrics(): SDKMetrics {
  if (!globalMetrics) {
    globalMetrics = new SDKMetrics()
  }
  return globalMetrics
}

/**
 * Reset the global metrics registry (for testing).
 */
export function resetMetrics(): void {
  globalMetrics = new SDKMetrics()
}

// ============================================================================
// Health Check Infrastructure
// ============================================================================

/**
 * Connection health states.
 */
export enum ConnectionState {
  CONNECTED = 'connected',
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  RECONNECTING = 'reconnecting',
  FAILED = 'failed',
}

/**
 * Health check result.
 */
export interface HealthStatus {
  /** Overall health status. */
  healthy: boolean

  /** Current connection state. */
  state: ConnectionState

  /** Timestamp of last successful operation (nanoseconds since epoch). */
  lastSuccessfulOpNs: number

  /** Number of consecutive failures. */
  consecutiveFailures: number

  /** Additional details about health status. */
  details: string
}

/**
 * Tracks connection health status.
 */
export class HealthTracker {
  private state: ConnectionState = ConnectionState.DISCONNECTED
  private lastSuccessfulOpNs: number = 0
  private consecutiveFailures: number = 0
  private failureThreshold: number

  constructor(failureThreshold: number = 3) {
    this.failureThreshold = failureThreshold
  }

  /**
   * Record a successful operation.
   */
  recordSuccess(): void {
    this.lastSuccessfulOpNs = Date.now() * 1_000_000 // Convert to nanoseconds
    this.consecutiveFailures = 0
    this.state = ConnectionState.CONNECTED
  }

  /**
   * Record a failed operation.
   */
  recordFailure(): void {
    this.consecutiveFailures++
    if (this.consecutiveFailures >= this.failureThreshold) {
      this.state = ConnectionState.FAILED
    }
  }

  /**
   * Mark as currently connecting.
   */
  setConnecting(): void {
    this.state = ConnectionState.CONNECTING
  }

  /**
   * Mark as currently reconnecting.
   */
  setReconnecting(): void {
    this.state = ConnectionState.RECONNECTING
  }

  /**
   * Mark as disconnected.
   */
  setDisconnected(): void {
    this.state = ConnectionState.DISCONNECTED
  }

  /**
   * Get current health status.
   */
  getStatus(): HealthStatus {
    const healthy =
      this.state === ConnectionState.CONNECTED &&
      this.consecutiveFailures < this.failureThreshold

    let details = ''
    switch (this.state) {
      case ConnectionState.FAILED:
        details = `Connection failed after ${this.consecutiveFailures} consecutive failures`
        break
      case ConnectionState.RECONNECTING:
        details = 'Attempting to reconnect'
        break
      case ConnectionState.CONNECTING:
        details = 'Initial connection in progress'
        break
      case ConnectionState.DISCONNECTED:
        details = 'Client is disconnected'
        break
      case ConnectionState.CONNECTED:
        details = ''
        break
    }

    return {
      healthy,
      state: this.state,
      lastSuccessfulOpNs: this.lastSuccessfulOpNs,
      consecutiveFailures: this.consecutiveFailures,
      details,
    }
  }

  /**
   * Convert health status to JSON-serializable object.
   */
  toJSON(): Record<string, unknown> {
    const status = this.getStatus()
    return {
      healthy: status.healthy,
      state: status.state,
      last_successful_operation_ns: status.lastSuccessfulOpNs,
      consecutive_failures: status.consecutiveFailures,
      details: status.details,
    }
  }
}

// ============================================================================
// Request Timer
// ============================================================================

/**
 * Timer for measuring operation duration and recording metrics.
 *
 * @example
 * ```typescript
 * const timer = new RequestTimer('query_radius', getMetrics())
 * try {
 *   const result = await doQuery()
 *   timer.success()
 *   return result
 * } catch (error) {
 *   timer.error()
 *   throw error
 * }
 * ```
 */
export class RequestTimer {
  private operation: string
  private metrics: SDKMetrics
  private logger?: SDKLogger
  private health?: HealthTracker
  private startTime: number
  private status: string = 'success'

  constructor(
    operation: string,
    metrics: SDKMetrics,
    options?: {
      logger?: SDKLogger
      health?: HealthTracker
    }
  ) {
    this.operation = operation
    this.metrics = metrics
    this.logger = options?.logger
    this.health = options?.health
    this.startTime = performance.now()

    this.logger?.debug('Starting operation', { operation })
  }

  /**
   * Mark the operation as successful and record metrics.
   */
  success(): void {
    this.status = 'success'
    this.finish()
  }

  /**
   * Mark the operation as failed and record metrics.
   */
  error(): void {
    this.status = 'error'
    this.finish()
  }

  /**
   * Override the status (e.g., for partial success).
   */
  setStatus(status: string): void {
    this.status = status
  }

  private finish(): void {
    const durationMs = performance.now() - this.startTime
    const durationSeconds = durationMs / 1000

    this.metrics.recordRequest(this.operation, this.status, durationSeconds)

    if (this.status === 'error') {
      this.logger?.error('Operation failed', {
        operation: this.operation,
        duration_ms: Math.round(durationMs),
      })
      this.health?.recordFailure()
    } else {
      this.logger?.debug('Operation completed', {
        operation: this.operation,
        duration_ms: Math.round(durationMs),
      })
      this.health?.recordSuccess()
    }
  }
}
