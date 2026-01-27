/**
 * ArcherDB Error Codes and Exceptions
 *
 * This module provides comprehensive error handling for ArcherDB operations:
 *
 * **Error Code Ranges:**
 * - 1001-1002: Connection errors (retryable)
 * - 2001-2003: Cluster errors (retryable)
 * - 3001-3004: Validation errors (not retryable)
 * - 4001-4004: Operation errors (varies)
 * - 213-218: Multi-region errors (v2)
 * - 220-224: Sharding errors (v2)
 * - 410-414: Encryption errors (v2)
 *
 * **Type Guards:**
 * - isArcherDBError(): Check if error is an ArcherDB error
 * - isNetworkError(): Check if error is network-related
 * - isValidationError(): Check if error is a validation error
 * - isOperationError(): Check if error is an operation error
 * - isRetryableError(): Check if error can be safely retried
 *
 * @example
 * ```typescript
 * import {
 *   ArcherDBError,
 *   ValidationError,
 *   isArcherDBError,
 *   isRetryableError,
 * } from 'archerdb-node'
 *
 * try {
 *   await client.queryRadius(options)
 * } catch (error) {
 *   if (isArcherDBError(error)) {
 *     console.log(`Error code: ${error.code}`)
 *     if (isRetryableError(error)) {
 *       // Implement retry logic
 *     }
 *   }
 * }
 * ```
 *
 * @module errors
 */

// Re-export base error types from geo_client
export {
  ArcherDBError,
  ConnectionFailed,
  ConnectionTimeout,
  ClusterUnavailable,
  ViewChangeInProgress,
  NotPrimary,
  InvalidCoordinates,
  PolygonTooComplex,
  BatchTooLarge,
  InvalidEntityId,
  OperationTimeout,
  QueryResultTooLarge,
  OutOfSpace,
  SessionExpired,
  CircuitBreakerOpen,
  RetryExhausted,
} from './geo_client'

import {
  ArcherDBError,
  ConnectionFailed,
  ConnectionTimeout,
  ClusterUnavailable,
  ViewChangeInProgress,
  NotPrimary,
  InvalidCoordinates,
  PolygonTooComplex,
  BatchTooLarge,
  InvalidEntityId,
  OperationTimeout,
  QueryResultTooLarge,
  OutOfSpace,
} from './geo_client'

// ============================================================================
// Type Guards for Base Error Types
// ============================================================================

/**
 * Type guard to check if an error is any ArcherDB error.
 *
 * Use this to distinguish ArcherDB errors from other JavaScript errors
 * for centralized error handling.
 *
 * @param error - The error to check
 * @returns true if error is an ArcherDBError instance
 *
 * @example
 * ```typescript
 * try {
 *   await client.queryRadius(filter)
 * } catch (error) {
 *   if (isArcherDBError(error)) {
 *     console.log(`ArcherDB error code: ${error.code}`)
 *     console.log(`Retryable: ${error.retryable}`)
 *   } else {
 *     // Not an ArcherDB error - network issue, etc.
 *     throw error
 *   }
 * }
 * ```
 */
export function isArcherDBError(error: unknown): error is ArcherDBError {
  return error instanceof ArcherDBError
}

/**
 * Type guard to check if an error is network-related.
 *
 * Network errors are typically transient and can be retried.
 * Includes connection errors and cluster availability errors.
 *
 * @param error - The error to check
 * @returns true if error is a network/connection error
 *
 * @example
 * ```typescript
 * try {
 *   await client.insertEvents(events)
 * } catch (error) {
 *   if (isNetworkError(error)) {
 *     // Wait and retry - network is likely temporarily unavailable
 *     await sleep(1000)
 *     await client.insertEvents(events)
 *   }
 * }
 * ```
 */
export function isNetworkError(error: unknown): error is
  | ConnectionFailed
  | ConnectionTimeout
  | ClusterUnavailable
  | ViewChangeInProgress
  | NotPrimary {
  return (
    error instanceof ConnectionFailed ||
    error instanceof ConnectionTimeout ||
    error instanceof ClusterUnavailable ||
    error instanceof ViewChangeInProgress ||
    error instanceof NotPrimary
  )
}

/**
 * Type guard to check if an error is a validation error.
 *
 * Validation errors indicate invalid input that will never succeed.
 * Do not retry these - fix the input data instead.
 *
 * @param error - The error to check
 * @returns true if error is a validation error
 *
 * @example
 * ```typescript
 * try {
 *   await client.queryRadius({ latitude: 200, ... }) // Invalid
 * } catch (error) {
 *   if (isValidationError(error)) {
 *     // Don't retry - fix the input
 *     console.error(`Invalid input: ${error.message}`)
 *   }
 * }
 * ```
 */
export function isValidationError(error: unknown): error is
  | InvalidCoordinates
  | PolygonTooComplex
  | BatchTooLarge
  | InvalidEntityId {
  return (
    error instanceof InvalidCoordinates ||
    error instanceof PolygonTooComplex ||
    error instanceof BatchTooLarge ||
    error instanceof InvalidEntityId
  )
}

/**
 * Type guard to check if an error is an operation error.
 *
 * Operation errors occur during query/write execution.
 * Some are retryable (timeouts), others are not (result too large).
 *
 * @param error - The error to check
 * @returns true if error is an operation error
 */
export function isOperationError(error: unknown): error is
  | OperationTimeout
  | QueryResultTooLarge
  | OutOfSpace {
  return (
    error instanceof OperationTimeout ||
    error instanceof QueryResultTooLarge ||
    error instanceof OutOfSpace
  )
}

/**
 * Type guard to check if an error can be safely retried.
 *
 * This is the recommended way to implement retry logic.
 * Checks the `retryable` property on ArcherDB errors.
 *
 * @param error - The error to check
 * @returns true if the error may succeed on retry
 *
 * @example
 * ```typescript
 * async function withRetry<T>(fn: () => Promise<T>, maxRetries = 3): Promise<T> {
 *   let lastError: Error
 *   for (let i = 0; i < maxRetries; i++) {
 *     try {
 *       return await fn()
 *     } catch (error) {
 *       lastError = error as Error
 *       if (!isRetryableError(error)) {
 *         throw error // Don't retry non-retryable errors
 *       }
 *       await sleep(100 * Math.pow(2, i)) // Exponential backoff
 *     }
 *   }
 *   throw lastError!
 * }
 * ```
 */
export function isRetryableError(error: unknown): boolean {
  if (isArcherDBError(error)) {
    return error.retryable
  }
  // Check for v2 exception types
  if (error instanceof StateException) {
    return error.retryable // Always false for state errors
  }
  if (error instanceof MultiRegionException) {
    return error.retryable
  }
  if (error instanceof ShardingException) {
    return error.retryable
  }
  if (error instanceof EncryptionException) {
    return error.retryable
  }
  return false
}

// ============================================================================
// State Error Codes (200-210)
// ============================================================================

/**
 * State error codes (200-210) for entity state issues.
 *
 * These errors indicate definitive state about an entity (not found, expired).
 * All state errors are non-retryable - the entity state is authoritative.
 */
export enum StateError {
  /** Query UUID not found in index. */
  ENTITY_NOT_FOUND = 200,

  /** Entity has expired due to TTL. */
  ENTITY_EXPIRED = 210,
}

/** Error messages for state errors. */
export const STATE_ERROR_MESSAGES: Record<StateError, string> = {
  [StateError.ENTITY_NOT_FOUND]: 'Entity not found',
  [StateError.ENTITY_EXPIRED]: 'Entity has expired due to TTL',
}

/** Retryable status for state errors (all are non-retryable). */
export const STATE_ERROR_RETRYABLE: Record<StateError, boolean> = {
  [StateError.ENTITY_NOT_FOUND]: false,
  [StateError.ENTITY_EXPIRED]: false,
}

/**
 * Returns true if the given code is a state error (200-210).
 */
export function isStateError(code: number): boolean {
  return code >= 200 && code <= 210
}

/**
 * Returns the message for a state error code.
 */
export function stateErrorMessage(code: number): string | undefined {
  return STATE_ERROR_MESSAGES[code as StateError]
}

// ============================================================================
// Multi-Region Error Codes (213-218)
// ============================================================================

/**
 * Multi-region error codes (213-218) per v2 replication/spec.md.
 */
export enum MultiRegionError {
  /** Write operation rejected: follower regions are read-only. */
  FOLLOWER_READ_ONLY = 213,

  /** Follower data exceeds maximum staleness threshold. */
  STALE_FOLLOWER = 214,

  /** Cannot connect to primary region. */
  PRIMARY_UNREACHABLE = 215,

  /** Cross-region replication timeout. */
  REPLICATION_TIMEOUT = 216,

  /** Write conflict detected in active-active replication. */
  CONFLICT_DETECTED = 217,

  /** Entity geo-shard does not match target region. */
  GEO_SHARD_MISMATCH = 218,
}

/** Error messages for multi-region errors. */
export const MULTI_REGION_ERROR_MESSAGES: Record<MultiRegionError, string> = {
  [MultiRegionError.FOLLOWER_READ_ONLY]: 'Write operation rejected: follower regions are read-only',
  [MultiRegionError.STALE_FOLLOWER]: 'Follower data exceeds maximum staleness threshold',
  [MultiRegionError.PRIMARY_UNREACHABLE]: 'Cannot connect to primary region',
  [MultiRegionError.REPLICATION_TIMEOUT]: 'Cross-region replication timeout',
  [MultiRegionError.CONFLICT_DETECTED]: 'Write conflict detected in active-active replication',
  [MultiRegionError.GEO_SHARD_MISMATCH]: 'Entity geo-shard does not match target region',
}

/** Retryable status for multi-region errors. */
export const MULTI_REGION_ERROR_RETRYABLE: Record<MultiRegionError, boolean> = {
  [MultiRegionError.FOLLOWER_READ_ONLY]: false,
  [MultiRegionError.STALE_FOLLOWER]: true,
  [MultiRegionError.PRIMARY_UNREACHABLE]: true,
  [MultiRegionError.REPLICATION_TIMEOUT]: true,
  [MultiRegionError.CONFLICT_DETECTED]: false,
  [MultiRegionError.GEO_SHARD_MISMATCH]: false,
}

/**
 * Returns true if the given code is a multi-region error (213-218).
 */
export function isMultiRegionError(code: number): boolean {
  return code >= 213 && code <= 218
}

/**
 * Returns the message for a multi-region error code.
 */
export function multiRegionErrorMessage(code: number): string | undefined {
  return MULTI_REGION_ERROR_MESSAGES[code as MultiRegionError]
}

// ============================================================================
// Sharding Error Codes (220-224)
// ============================================================================

/**
 * Sharding error codes (220-224) per v2 index-sharding/spec.md.
 */
export enum ShardingError {
  /** This node is not the leader for target shard. */
  NOT_SHARD_LEADER = 220,

  /** Target shard has no available replicas. */
  SHARD_UNAVAILABLE = 221,

  /** Cluster is currently resharding. */
  RESHARDING_IN_PROGRESS = 222,

  /** Target shard count is invalid. */
  INVALID_SHARD_COUNT = 223,

  /** Data migration to new shard failed. */
  SHARD_MIGRATION_FAILED = 224,
}

/** Error messages for sharding errors. */
export const SHARDING_ERROR_MESSAGES: Record<ShardingError, string> = {
  [ShardingError.NOT_SHARD_LEADER]: 'This node is not the leader for target shard',
  [ShardingError.SHARD_UNAVAILABLE]: 'Target shard has no available replicas',
  [ShardingError.RESHARDING_IN_PROGRESS]: 'Cluster is currently resharding',
  [ShardingError.INVALID_SHARD_COUNT]: 'Target shard count is invalid',
  [ShardingError.SHARD_MIGRATION_FAILED]: 'Data migration to new shard failed',
}

/** Retryable status for sharding errors. */
export const SHARDING_ERROR_RETRYABLE: Record<ShardingError, boolean> = {
  [ShardingError.NOT_SHARD_LEADER]: true,
  [ShardingError.SHARD_UNAVAILABLE]: true,
  [ShardingError.RESHARDING_IN_PROGRESS]: true,
  [ShardingError.INVALID_SHARD_COUNT]: false,
  [ShardingError.SHARD_MIGRATION_FAILED]: false,
}

/**
 * Returns true if the given code is a sharding error (220-224).
 */
export function isShardingError(code: number): boolean {
  return code >= 220 && code <= 224
}

/**
 * Returns the message for a sharding error code.
 */
export function shardingErrorMessage(code: number): string | undefined {
  return SHARDING_ERROR_MESSAGES[code as ShardingError]
}

// ============================================================================
// Encryption Error Codes (410-414)
// ============================================================================

/**
 * Encryption error codes (410-414) per v2 security/spec.md.
 */
export enum EncryptionError {
  /** Cannot retrieve encryption key from provider. */
  ENCRYPTION_KEY_UNAVAILABLE = 410,

  /** Failed to decrypt data (auth tag mismatch). */
  DECRYPTION_FAILED = 411,

  /** Encryption required but not configured. */
  ENCRYPTION_NOT_ENABLED = 412,

  /** Key rotation in progress, retry later. */
  KEY_ROTATION_IN_PROGRESS = 413,

  /** File encrypted with unsupported version. */
  UNSUPPORTED_ENCRYPTION_VERSION = 414,
}

/** Error messages for encryption errors. */
export const ENCRYPTION_ERROR_MESSAGES: Record<EncryptionError, string> = {
  [EncryptionError.ENCRYPTION_KEY_UNAVAILABLE]: 'Cannot retrieve encryption key from provider',
  [EncryptionError.DECRYPTION_FAILED]: 'Failed to decrypt data (auth tag mismatch)',
  [EncryptionError.ENCRYPTION_NOT_ENABLED]: 'Encryption required but not configured',
  [EncryptionError.KEY_ROTATION_IN_PROGRESS]: 'Key rotation in progress, retry later',
  [EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION]: 'File encrypted with unsupported version',
}

/** Retryable status for encryption errors. */
export const ENCRYPTION_ERROR_RETRYABLE: Record<EncryptionError, boolean> = {
  [EncryptionError.ENCRYPTION_KEY_UNAVAILABLE]: true,
  [EncryptionError.DECRYPTION_FAILED]: false,
  [EncryptionError.ENCRYPTION_NOT_ENABLED]: false,
  [EncryptionError.KEY_ROTATION_IN_PROGRESS]: true,
  [EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION]: false,
}

/**
 * Returns true if the given code is an encryption error (410-414).
 */
export function isEncryptionError(code: number): boolean {
  return code >= 410 && code <= 414
}

/**
 * Returns the message for an encryption error code.
 */
export function encryptionErrorMessage(code: number): string | undefined {
  return ENCRYPTION_ERROR_MESSAGES[code as EncryptionError]
}

// ============================================================================
// Exception Classes
// ============================================================================

/**
 * Exception for state errors (entity not found, expired).
 *
 * State errors are never retryable - they represent definitive entity state.
 *
 * @example
 * ```typescript
 * try {
 *   const event = await client.getLatestByUuid(entityId)
 * } catch (error) {
 *   if (error instanceof StateException) {
 *     if (error.error === StateError.ENTITY_NOT_FOUND) {
 *       console.log('Entity does not exist')
 *     } else if (error.error === StateError.ENTITY_EXPIRED) {
 *       console.log('Entity has expired')
 *     }
 *   }
 * }
 * ```
 */
export class StateException extends Error {
  public readonly error: StateError
  public readonly code: number
  public readonly retryable: boolean

  constructor(error: StateError) {
    const message = STATE_ERROR_MESSAGES[error]
    super(`[${error}] ${message}`)
    this.name = 'StateException'
    this.error = error
    this.code = error
    this.retryable = false // State errors are never retryable
  }
}

/**
 * Exception for multi-region errors.
 */
export class MultiRegionException extends Error {
  public readonly error: MultiRegionError
  public readonly code: number
  public readonly retryable: boolean

  constructor(error: MultiRegionError) {
    const message = MULTI_REGION_ERROR_MESSAGES[error]
    super(`[${error}] ${message}`)
    this.name = 'MultiRegionException'
    this.error = error
    this.code = error
    this.retryable = MULTI_REGION_ERROR_RETRYABLE[error]
  }
}

/**
 * Exception for sharding errors.
 */
export class ShardingException extends Error {
  public readonly error: ShardingError
  public readonly shardId: number | undefined
  public readonly code: number
  public readonly retryable: boolean

  constructor(error: ShardingError, shardId?: number) {
    const message = SHARDING_ERROR_MESSAGES[error]
    super(`[${error}] ${message}`)
    this.name = 'ShardingException'
    this.error = error
    this.shardId = shardId
    this.code = error
    this.retryable = SHARDING_ERROR_RETRYABLE[error]
  }
}

/**
 * Exception for encryption errors.
 */
export class EncryptionException extends Error {
  public readonly error: EncryptionError
  public readonly code: number
  public readonly retryable: boolean

  constructor(error: EncryptionError) {
    const message = ENCRYPTION_ERROR_MESSAGES[error]
    super(`[${error}] ${message}`)
    this.name = 'EncryptionException'
    this.error = error
    this.code = error
    this.retryable = ENCRYPTION_ERROR_RETRYABLE[error]
  }
}

// ============================================================================
// Error Code Utilities
// ============================================================================

/**
 * Returns true if the numeric error code indicates a retryable error.
 *
 * This function checks v2 error code ranges (multi-region, sharding, encryption).
 * For error objects, use `isRetryableError()` instead.
 *
 * @param code - Numeric error code
 * @returns true if the error code is retryable
 *
 * @example
 * ```typescript
 * if (isRetryableCode(error.code)) {
 *   // Retry the operation
 * }
 * ```
 */
export function isRetryableCode(code: number): boolean {
  if (isStateError(code)) {
    return STATE_ERROR_RETRYABLE[code as StateError] ?? false
  }
  if (isMultiRegionError(code)) {
    return MULTI_REGION_ERROR_RETRYABLE[code as MultiRegionError] ?? false
  }
  if (isShardingError(code)) {
    return SHARDING_ERROR_RETRYABLE[code as ShardingError] ?? false
  }
  if (isEncryptionError(code)) {
    return ENCRYPTION_ERROR_RETRYABLE[code as EncryptionError] ?? false
  }
  return false
}

/**
 * @deprecated Use `isRetryableCode()` for numeric codes or `isRetryableError()` for error objects
 */
export const isRetryable = isRetryableCode

/**
 * Returns the message for any v2 error code.
 */
export function errorMessage(code: number): string | undefined {
  if (isStateError(code)) {
    return stateErrorMessage(code)
  }
  if (isMultiRegionError(code)) {
    return multiRegionErrorMessage(code)
  }
  if (isShardingError(code)) {
    return shardingErrorMessage(code)
  }
  if (isEncryptionError(code)) {
    return encryptionErrorMessage(code)
  }
  return undefined
}
