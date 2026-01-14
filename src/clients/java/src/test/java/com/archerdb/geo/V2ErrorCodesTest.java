package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

/**
 * Tests for v2.0 error codes (sharding 220-224, encryption 410-414).
 */
class V2ErrorCodesTest {

    // ============================================================================
    // Sharding Error Tests
    // ============================================================================

    @Test
    void shardingError_codeValues() {
        assertEquals(220, ShardingError.NOT_SHARD_LEADER.getCode());
        assertEquals(221, ShardingError.SHARD_UNAVAILABLE.getCode());
        assertEquals(222, ShardingError.RESHARDING_IN_PROGRESS.getCode());
        assertEquals(223, ShardingError.INVALID_SHARD_COUNT.getCode());
        assertEquals(224, ShardingError.SHARD_MIGRATION_FAILED.getCode());
    }

    @Test
    void shardingError_retrySemantics() {
        assertTrue(ShardingError.NOT_SHARD_LEADER.isRetryable());
        assertTrue(ShardingError.SHARD_UNAVAILABLE.isRetryable());
        assertTrue(ShardingError.RESHARDING_IN_PROGRESS.isRetryable());
        assertFalse(ShardingError.INVALID_SHARD_COUNT.isRetryable());
        assertFalse(ShardingError.SHARD_MIGRATION_FAILED.isRetryable());
    }

    @Test
    void shardingError_fromCode() {
        assertEquals(ShardingError.NOT_SHARD_LEADER, ShardingError.fromCode(220));
        assertEquals(ShardingError.SHARD_UNAVAILABLE, ShardingError.fromCode(221));
        assertEquals(ShardingError.RESHARDING_IN_PROGRESS, ShardingError.fromCode(222));
        assertEquals(ShardingError.INVALID_SHARD_COUNT, ShardingError.fromCode(223));
        assertEquals(ShardingError.SHARD_MIGRATION_FAILED, ShardingError.fromCode(224));
        assertNull(ShardingError.fromCode(219));
        assertNull(ShardingError.fromCode(225));
    }

    @Test
    void shardingError_isShardingError() {
        assertFalse(ShardingError.isShardingError(219));
        assertTrue(ShardingError.isShardingError(220));
        assertTrue(ShardingError.isShardingError(222));
        assertTrue(ShardingError.isShardingError(224));
        assertFalse(ShardingError.isShardingError(225));
    }

    @Test
    void shardingError_messages() {
        assertNotNull(ShardingError.NOT_SHARD_LEADER.getMessage());
        assertTrue(ShardingError.NOT_SHARD_LEADER.getMessage().contains("leader"));
        // Message says "no available" instead of "unavailable"
        assertTrue(ShardingError.SHARD_UNAVAILABLE.getMessage().contains("available"));
        assertTrue(ShardingError.RESHARDING_IN_PROGRESS.getMessage().contains("resharding"));
    }

    @Test
    void shardingError_toException() {
        ArcherDBException exception = ShardingError.NOT_SHARD_LEADER.toException();
        assertEquals(220, exception.getErrorCode());
        assertTrue(exception.isRetryable());
        assertNotNull(exception.getMessage());
    }

    // ============================================================================
    // Encryption Error Tests
    // ============================================================================

    @Test
    void encryptionError_codeValues() {
        assertEquals(410, EncryptionError.ENCRYPTION_KEY_UNAVAILABLE.getCode());
        assertEquals(411, EncryptionError.DECRYPTION_FAILED.getCode());
        assertEquals(412, EncryptionError.ENCRYPTION_NOT_ENABLED.getCode());
        assertEquals(413, EncryptionError.KEY_ROTATION_IN_PROGRESS.getCode());
        assertEquals(414, EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION.getCode());
    }

    @Test
    void encryptionError_retrySemantics() {
        assertTrue(EncryptionError.ENCRYPTION_KEY_UNAVAILABLE.isRetryable());
        assertFalse(EncryptionError.DECRYPTION_FAILED.isRetryable());
        assertFalse(EncryptionError.ENCRYPTION_NOT_ENABLED.isRetryable());
        assertTrue(EncryptionError.KEY_ROTATION_IN_PROGRESS.isRetryable());
        assertFalse(EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION.isRetryable());
    }

    @Test
    void encryptionError_fromCode() {
        assertEquals(EncryptionError.ENCRYPTION_KEY_UNAVAILABLE, EncryptionError.fromCode(410));
        assertEquals(EncryptionError.DECRYPTION_FAILED, EncryptionError.fromCode(411));
        assertEquals(EncryptionError.ENCRYPTION_NOT_ENABLED, EncryptionError.fromCode(412));
        assertEquals(EncryptionError.KEY_ROTATION_IN_PROGRESS, EncryptionError.fromCode(413));
        assertEquals(EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION, EncryptionError.fromCode(414));
        assertNull(EncryptionError.fromCode(409));
        assertNull(EncryptionError.fromCode(415));
    }

    @Test
    void encryptionError_isEncryptionError() {
        assertFalse(EncryptionError.isEncryptionError(409));
        assertTrue(EncryptionError.isEncryptionError(410));
        assertTrue(EncryptionError.isEncryptionError(412));
        assertTrue(EncryptionError.isEncryptionError(414));
        assertFalse(EncryptionError.isEncryptionError(415));
    }

    @Test
    void encryptionError_messages() {
        assertNotNull(EncryptionError.ENCRYPTION_KEY_UNAVAILABLE.getMessage());
        assertTrue(EncryptionError.ENCRYPTION_KEY_UNAVAILABLE.getMessage().contains("key"));
        assertTrue(EncryptionError.DECRYPTION_FAILED.getMessage().contains("decrypt"));
        assertTrue(EncryptionError.KEY_ROTATION_IN_PROGRESS.getMessage().contains("rotation"));
    }

    @Test
    void encryptionError_toException() {
        ArcherDBException exception = EncryptionError.DECRYPTION_FAILED.toException();
        assertEquals(411, exception.getErrorCode());
        assertFalse(exception.isRetryable());
        assertNotNull(exception.getMessage());
    }

    // ============================================================================
    // Multi-Region Error Tests (verify existing)
    // ============================================================================

    @Test
    void multiRegionError_codeValues() {
        assertEquals(213, MultiRegionError.FOLLOWER_READ_ONLY.getCode());
        assertEquals(214, MultiRegionError.STALE_FOLLOWER.getCode());
        assertEquals(215, MultiRegionError.PRIMARY_UNREACHABLE.getCode());
        assertEquals(216, MultiRegionError.REPLICATION_TIMEOUT.getCode());
        assertEquals(217, MultiRegionError.REGION_CONFIG_MISMATCH.getCode());
        assertEquals(218, MultiRegionError.UNKNOWN_REGION.getCode());
    }

    @Test
    void multiRegionError_isMultiRegionError() {
        assertFalse(MultiRegionError.isMultiRegionError(212));
        assertTrue(MultiRegionError.isMultiRegionError(213));
        assertTrue(MultiRegionError.isMultiRegionError(216));
        assertTrue(MultiRegionError.isMultiRegionError(218));
        assertFalse(MultiRegionError.isMultiRegionError(219));
    }
}
