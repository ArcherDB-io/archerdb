/**
 * ArcherDB v2 Error Codes and Exceptions
 *
 * Provides error code enums and exceptions for:
 * - Multi-region errors (213-218)
 * - Sharding errors (220-224)
 * - Encryption errors (410-414)
 */

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
 * Returns true if the error code indicates a retryable error.
 */
export function isRetryable(code: number): boolean {
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
 * Returns the message for any v2 error code.
 */
export function errorMessage(code: number): string | undefined {
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
