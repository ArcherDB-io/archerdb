///////////////////////////////////////////////////////
// ArcherDB Node.js SDK - v2 Error Codes Tests       //
// Tests for state, multi-region, sharding, encryption //
///////////////////////////////////////////////////////

import * as assert from 'assert'
import {
  // State
  StateError,
  StateException,
  STATE_ERROR_MESSAGES,
  STATE_ERROR_RETRYABLE,
  isStateError,
  stateErrorMessage,
  // Multi-region
  MultiRegionError,
  MultiRegionException,
  MULTI_REGION_ERROR_MESSAGES,
  MULTI_REGION_ERROR_RETRYABLE,
  isMultiRegionError,
  multiRegionErrorMessage,
  // Sharding
  ShardingError,
  ShardingException,
  SHARDING_ERROR_MESSAGES,
  SHARDING_ERROR_RETRYABLE,
  isShardingError,
  shardingErrorMessage,
  // Encryption
  EncryptionError,
  EncryptionException,
  ENCRYPTION_ERROR_MESSAGES,
  ENCRYPTION_ERROR_RETRYABLE,
  isEncryptionError,
  encryptionErrorMessage,
  // Utilities
  isRetryable,
  errorMessage,
  // Operation context
  OperationType,
} from './errors'

// Test runner
let passed = 0
let failed = 0

function test(name: string, fn: () => void) {
  try {
    fn()
    passed++
    console.log(`✓ ${name}`)
  } catch (e) {
    failed++
    console.error(`✗ ${name}`)
    console.error(`  ${e instanceof Error ? e.message : e}`)
  }
}

function section(name: string) {
  console.log(`\n=== ${name} ===\n`)
}

// ============================================================================
// State Error Tests
// ============================================================================

section('State Error Tests')

test('StateError code values', () => {
  assert.strictEqual(StateError.ENTITY_NOT_FOUND, 200)
  assert.strictEqual(StateError.ENTITY_EXPIRED, 210)
})

test('StateError retry semantics (all non-retryable)', () => {
  assert.strictEqual(STATE_ERROR_RETRYABLE[StateError.ENTITY_NOT_FOUND], false)
  assert.strictEqual(STATE_ERROR_RETRYABLE[StateError.ENTITY_EXPIRED], false)
})

test('isStateError', () => {
  assert.strictEqual(isStateError(199), false)
  assert.strictEqual(isStateError(200), true)
  assert.strictEqual(isStateError(205), true)
  assert.strictEqual(isStateError(210), true)
  assert.strictEqual(isStateError(211), false)
})

test('StateError messages', () => {
  assert.ok(STATE_ERROR_MESSAGES[StateError.ENTITY_NOT_FOUND].includes('not found'))
  assert.ok(STATE_ERROR_MESSAGES[StateError.ENTITY_EXPIRED].includes('expired'))
})

test('stateErrorMessage', () => {
  assert.ok(stateErrorMessage(200)?.includes('not found'))
  assert.ok(stateErrorMessage(210)?.includes('expired'))
  assert.strictEqual(stateErrorMessage(199), undefined)
  assert.strictEqual(stateErrorMessage(211), undefined)
})

test('StateException creation', () => {
  const exc = new StateException(StateError.ENTITY_NOT_FOUND)
  assert.strictEqual(exc.code, 200)
  assert.strictEqual(exc.retryable, false)
  assert.strictEqual(exc.error, StateError.ENTITY_NOT_FOUND)
  assert.ok(exc.message.includes('[200]'))
  assert.strictEqual(exc.name, 'StateException')
  assert.ok(exc instanceof Error)
})

test('StateException for ENTITY_EXPIRED', () => {
  const exc = new StateException(StateError.ENTITY_EXPIRED)
  assert.strictEqual(exc.code, 210)
  assert.strictEqual(exc.retryable, false)
  assert.strictEqual(exc.error, StateError.ENTITY_EXPIRED)
  assert.ok(exc.message.includes('expired'))
})

// ============================================================================
// Multi-Region Error Tests
// ============================================================================

section('Multi-Region Error Tests')

test('MultiRegionError code values', () => {
  assert.strictEqual(MultiRegionError.FOLLOWER_READ_ONLY, 213)
  assert.strictEqual(MultiRegionError.STALE_FOLLOWER, 214)
  assert.strictEqual(MultiRegionError.PRIMARY_UNREACHABLE, 215)
  assert.strictEqual(MultiRegionError.REPLICATION_TIMEOUT, 216)
  assert.strictEqual(MultiRegionError.CONFLICT_DETECTED, 217)
  assert.strictEqual(MultiRegionError.GEO_SHARD_MISMATCH, 218)
})

test('MultiRegionError retry semantics', () => {
  assert.strictEqual(MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.FOLLOWER_READ_ONLY], false)
  assert.strictEqual(MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.STALE_FOLLOWER], true)
  assert.strictEqual(MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.PRIMARY_UNREACHABLE], true)
  assert.strictEqual(MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.REPLICATION_TIMEOUT], true)
  assert.strictEqual(MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.CONFLICT_DETECTED], false)
  assert.strictEqual(MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.GEO_SHARD_MISMATCH], false)
})

test('isMultiRegionError', () => {
  assert.strictEqual(isMultiRegionError(212), false)
  assert.strictEqual(isMultiRegionError(213), true)
  assert.strictEqual(isMultiRegionError(216), true)
  assert.strictEqual(isMultiRegionError(218), true)
  assert.strictEqual(isMultiRegionError(219), false)
})

test('MultiRegionError messages', () => {
  assert.ok(MULTI_REGION_ERROR_MESSAGES[MultiRegionError.FOLLOWER_READ_ONLY].includes('follower'))
  assert.ok(MULTI_REGION_ERROR_MESSAGES[MultiRegionError.STALE_FOLLOWER].includes('staleness'))
  assert.ok(MULTI_REGION_ERROR_MESSAGES[MultiRegionError.PRIMARY_UNREACHABLE].includes('primary'))
})

test('multiRegionErrorMessage', () => {
  assert.ok(multiRegionErrorMessage(213)?.includes('follower'))
  assert.strictEqual(multiRegionErrorMessage(212), undefined)
  assert.strictEqual(multiRegionErrorMessage(219), undefined)
})

test('MultiRegionException creation', () => {
  const exc = new MultiRegionException(MultiRegionError.FOLLOWER_READ_ONLY)
  assert.strictEqual(exc.code, 213)
  assert.strictEqual(exc.retryable, false)
  assert.strictEqual(exc.error, MultiRegionError.FOLLOWER_READ_ONLY)
  assert.ok(exc.message.includes('[213]'))
  assert.strictEqual(exc.name, 'MultiRegionException')
  assert.ok(exc instanceof Error)
})

// ============================================================================
// Sharding Error Tests
// ============================================================================

section('Sharding Error Tests')

test('ShardingError code values', () => {
  assert.strictEqual(ShardingError.NOT_SHARD_LEADER, 220)
  assert.strictEqual(ShardingError.SHARD_UNAVAILABLE, 221)
  assert.strictEqual(ShardingError.RESHARDING_IN_PROGRESS, 222)
  assert.strictEqual(ShardingError.INVALID_SHARD_COUNT, 223)
  assert.strictEqual(ShardingError.SHARD_MIGRATION_FAILED, 224)
})

test('ShardingError retry semantics', () => {
  assert.strictEqual(SHARDING_ERROR_RETRYABLE[ShardingError.NOT_SHARD_LEADER], true)
  assert.strictEqual(SHARDING_ERROR_RETRYABLE[ShardingError.SHARD_UNAVAILABLE], true)
  assert.strictEqual(SHARDING_ERROR_RETRYABLE[ShardingError.RESHARDING_IN_PROGRESS], true)
  assert.strictEqual(SHARDING_ERROR_RETRYABLE[ShardingError.INVALID_SHARD_COUNT], false)
  assert.strictEqual(SHARDING_ERROR_RETRYABLE[ShardingError.SHARD_MIGRATION_FAILED], false)
})

test('isShardingError', () => {
  assert.strictEqual(isShardingError(219), false)
  assert.strictEqual(isShardingError(220), true)
  assert.strictEqual(isShardingError(222), true)
  assert.strictEqual(isShardingError(224), true)
  assert.strictEqual(isShardingError(225), false)
})

test('ShardingError messages', () => {
  assert.ok(SHARDING_ERROR_MESSAGES[ShardingError.NOT_SHARD_LEADER].includes('leader'))
  // Message says "no available" instead of "unavailable"
  assert.ok(SHARDING_ERROR_MESSAGES[ShardingError.SHARD_UNAVAILABLE].includes('available'))
  assert.ok(SHARDING_ERROR_MESSAGES[ShardingError.RESHARDING_IN_PROGRESS].includes('resharding'))
})

test('shardingErrorMessage', () => {
  assert.ok(shardingErrorMessage(220)?.includes('leader'))
  assert.strictEqual(shardingErrorMessage(219), undefined)
  assert.strictEqual(shardingErrorMessage(225), undefined)
})

test('ShardingException creation', () => {
  const exc = new ShardingException(ShardingError.NOT_SHARD_LEADER)
  assert.strictEqual(exc.code, 220)
  assert.strictEqual(exc.retryable, true)
  assert.strictEqual(exc.error, ShardingError.NOT_SHARD_LEADER)
  assert.ok(exc.message.includes('[220]'))
  assert.strictEqual(exc.name, 'ShardingException')
  assert.strictEqual(exc.shardId, undefined)
  assert.ok(exc instanceof Error)
})

test('ShardingException with shard ID', () => {
  const exc = new ShardingException(ShardingError.SHARD_UNAVAILABLE, 5)
  assert.strictEqual(exc.shardId, 5)
  assert.strictEqual(exc.code, 221)
})

// ============================================================================
// Encryption Error Tests
// ============================================================================

section('Encryption Error Tests')

test('EncryptionError code values', () => {
  assert.strictEqual(EncryptionError.ENCRYPTION_KEY_UNAVAILABLE, 410)
  assert.strictEqual(EncryptionError.DECRYPTION_FAILED, 411)
  assert.strictEqual(EncryptionError.ENCRYPTION_NOT_ENABLED, 412)
  assert.strictEqual(EncryptionError.KEY_ROTATION_IN_PROGRESS, 413)
  assert.strictEqual(EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION, 414)
})

test('EncryptionError retry semantics', () => {
  assert.strictEqual(ENCRYPTION_ERROR_RETRYABLE[EncryptionError.ENCRYPTION_KEY_UNAVAILABLE], true)
  assert.strictEqual(ENCRYPTION_ERROR_RETRYABLE[EncryptionError.DECRYPTION_FAILED], false)
  assert.strictEqual(ENCRYPTION_ERROR_RETRYABLE[EncryptionError.ENCRYPTION_NOT_ENABLED], false)
  assert.strictEqual(ENCRYPTION_ERROR_RETRYABLE[EncryptionError.KEY_ROTATION_IN_PROGRESS], true)
  assert.strictEqual(ENCRYPTION_ERROR_RETRYABLE[EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION], false)
})

test('isEncryptionError', () => {
  assert.strictEqual(isEncryptionError(409), false)
  assert.strictEqual(isEncryptionError(410), true)
  assert.strictEqual(isEncryptionError(412), true)
  assert.strictEqual(isEncryptionError(414), true)
  assert.strictEqual(isEncryptionError(415), false)
})

test('EncryptionError messages', () => {
  assert.ok(ENCRYPTION_ERROR_MESSAGES[EncryptionError.ENCRYPTION_KEY_UNAVAILABLE].includes('key'))
  assert.ok(ENCRYPTION_ERROR_MESSAGES[EncryptionError.DECRYPTION_FAILED].includes('decrypt'))
  assert.ok(ENCRYPTION_ERROR_MESSAGES[EncryptionError.KEY_ROTATION_IN_PROGRESS].includes('rotation'))
})

test('encryptionErrorMessage', () => {
  assert.ok(encryptionErrorMessage(410)?.includes('key'))
  assert.strictEqual(encryptionErrorMessage(409), undefined)
  assert.strictEqual(encryptionErrorMessage(415), undefined)
})

test('EncryptionException creation', () => {
  const exc = new EncryptionException(EncryptionError.DECRYPTION_FAILED)
  assert.strictEqual(exc.code, 411)
  assert.strictEqual(exc.retryable, false)
  assert.strictEqual(exc.error, EncryptionError.DECRYPTION_FAILED)
  assert.ok(exc.message.includes('[411]'))
  assert.strictEqual(exc.name, 'EncryptionException')
  assert.ok(exc instanceof Error)
})

// ============================================================================
// Utility Function Tests
// ============================================================================

section('Utility Function Tests')

test('isRetryable state errors (all non-retryable)', () => {
  assert.strictEqual(isRetryable(200), false) // ENTITY_NOT_FOUND
  assert.strictEqual(isRetryable(210), false) // ENTITY_EXPIRED
})

test('isRetryable multi-region', () => {
  assert.strictEqual(isRetryable(213), false) // FOLLOWER_READ_ONLY
  assert.strictEqual(isRetryable(214), true)  // STALE_FOLLOWER
  assert.strictEqual(isRetryable(215), true)  // PRIMARY_UNREACHABLE
})

test('isRetryable sharding', () => {
  assert.strictEqual(isRetryable(220), true)  // NOT_SHARD_LEADER
  assert.strictEqual(isRetryable(223), false) // INVALID_SHARD_COUNT
  assert.strictEqual(isRetryable(224), false) // SHARD_MIGRATION_FAILED
})

test('isRetryable encryption', () => {
  assert.strictEqual(isRetryable(410), true)  // ENCRYPTION_KEY_UNAVAILABLE
  assert.strictEqual(isRetryable(411), false) // DECRYPTION_FAILED
  assert.strictEqual(isRetryable(413), true)  // KEY_ROTATION_IN_PROGRESS
})

test('isRetryable unknown codes', () => {
  assert.strictEqual(isRetryable(999), false)
  assert.strictEqual(isRetryable(0), false)
})

test('errorMessage state errors', () => {
  assert.ok(errorMessage(200)?.includes('not found'))
  assert.ok(errorMessage(210)?.includes('expired'))
})

test('errorMessage multi-region', () => {
  assert.ok(errorMessage(213)?.includes('follower'))
  assert.ok(errorMessage(216)?.includes('replication'))
})

test('errorMessage sharding', () => {
  assert.ok(errorMessage(220)?.includes('leader'))
  assert.ok(errorMessage(222)?.includes('resharding'))
})

test('errorMessage encryption', () => {
  assert.ok(errorMessage(410)?.includes('key'))
  assert.ok(errorMessage(414)?.includes('version'))
})

test('errorMessage unknown codes', () => {
  assert.strictEqual(errorMessage(999), undefined)
  assert.strictEqual(errorMessage(0), undefined)
})

// ============================================================================
// Operation Context Tests
// ============================================================================

section('Operation Context Tests')

test('OperationType enum values', () => {
  assert.strictEqual(OperationType.UNKNOWN, '')
  assert.strictEqual(OperationType.INSERT, 'insert')
  assert.strictEqual(OperationType.UPDATE, 'update')
  assert.strictEqual(OperationType.DELETE, 'delete')
  assert.strictEqual(OperationType.QUERY, 'query')
  assert.strictEqual(OperationType.GET, 'get')
})

test('StateException with context', () => {
  const exc = new StateException(StateError.ENTITY_NOT_FOUND, 'entity-abc', OperationType.GET)
  assert.strictEqual(exc.entityId, 'entity-abc')
  assert.strictEqual(exc.operationType, OperationType.GET)
  assert.strictEqual(exc.code, 200)
  assert.strictEqual(exc.retryable, false)
})

test('MultiRegionException with context', () => {
  const exc = new MultiRegionException(MultiRegionError.GEO_SHARD_MISMATCH, 'entity-xyz', 7, OperationType.INSERT)
  assert.strictEqual(exc.entityId, 'entity-xyz')
  assert.strictEqual(exc.shardId, 7)
  assert.strictEqual(exc.operationType, OperationType.INSERT)
  assert.strictEqual(exc.code, 218)
})

test('ShardingException with full context', () => {
  const exc = new ShardingException(ShardingError.NOT_SHARD_LEADER, 42, 'entity-789', OperationType.UPDATE)
  assert.strictEqual(exc.shardId, 42)
  assert.strictEqual(exc.entityId, 'entity-789')
  assert.strictEqual(exc.operationType, OperationType.UPDATE)
  assert.strictEqual(exc.retryable, true)
})

test('EncryptionException with context', () => {
  const exc = new EncryptionException(EncryptionError.DECRYPTION_FAILED, 'entity-def', 3, OperationType.QUERY)
  assert.strictEqual(exc.entityId, 'entity-def')
  assert.strictEqual(exc.shardId, 3)
  assert.strictEqual(exc.operationType, OperationType.QUERY)
  assert.strictEqual(exc.retryable, false)
})

test('Exception default context is undefined', () => {
  const exc = new ShardingException(ShardingError.SHARD_UNAVAILABLE)
  assert.strictEqual(exc.entityId, undefined)
  assert.strictEqual(exc.operationType, undefined)
})

// ============================================================================
// Summary
// ============================================================================

console.log(`\n=== Summary ===\n`)
console.log(`Passed: ${passed}`)
console.log(`Failed: ${failed}`)

if (failed > 0) {
  process.exit(1)
}
