/**
 * @file arch_client_errors_test.c
 * @brief Tests for ArcherDB C Client Error Helpers
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "arch_client_errors.h"

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name, condition) do { \
    if (condition) { \
        printf("✓ %s\n", name); \
        tests_passed++; \
    } else { \
        printf("✗ %s\n", name); \
        tests_failed++; \
    } \
} while(0)

/* Test state error range detection */
void test_is_state_error(void) {
    printf("\n=== State Error Range Tests ===\n\n");
    
    TEST("199 is not a state error", !arch_error_is_state_error(199));
    TEST("200 is a state error", arch_error_is_state_error(200));
    TEST("205 is a state error", arch_error_is_state_error(205));
    TEST("210 is a state error", arch_error_is_state_error(210));
    TEST("211 is not a state error", !arch_error_is_state_error(211));
}

/* Test multi-region error range detection */
void test_is_multi_region_error(void) {
    printf("\n=== Multi-Region Error Range Tests ===\n\n");
    
    TEST("212 is not a multi-region error", !arch_error_is_multi_region_error(212));
    TEST("213 is a multi-region error", arch_error_is_multi_region_error(213));
    TEST("216 is a multi-region error", arch_error_is_multi_region_error(216));
    TEST("218 is a multi-region error", arch_error_is_multi_region_error(218));
    TEST("219 is not a multi-region error", !arch_error_is_multi_region_error(219));
}

/* Test sharding error range detection */
void test_is_sharding_error(void) {
    printf("\n=== Sharding Error Range Tests ===\n\n");
    
    TEST("219 is not a sharding error", !arch_error_is_sharding_error(219));
    TEST("220 is a sharding error", arch_error_is_sharding_error(220));
    TEST("222 is a sharding error", arch_error_is_sharding_error(222));
    TEST("224 is a sharding error", arch_error_is_sharding_error(224));
    TEST("225 is not a sharding error", !arch_error_is_sharding_error(225));
}

/* Test encryption error range detection */
void test_is_encryption_error(void) {
    printf("\n=== Encryption Error Range Tests ===\n\n");
    
    TEST("409 is not an encryption error", !arch_error_is_encryption_error(409));
    TEST("410 is an encryption error", arch_error_is_encryption_error(410));
    TEST("412 is an encryption error", arch_error_is_encryption_error(412));
    TEST("414 is an encryption error", arch_error_is_encryption_error(414));
    TEST("415 is not an encryption error", !arch_error_is_encryption_error(415));
}

/* Test retryability classification */
void test_is_retryable(void) {
    printf("\n=== Retryability Tests ===\n\n");
    
    /* State errors - not retryable */
    TEST("ENTITY_NOT_FOUND is not retryable", !arch_error_is_retryable(ARCH_ERR_ENTITY_NOT_FOUND));
    TEST("ENTITY_EXPIRED is not retryable", !arch_error_is_retryable(ARCH_ERR_ENTITY_EXPIRED));
    
    /* Multi-region errors - mixed */
    TEST("FOLLOWER_READ_ONLY is not retryable", !arch_error_is_retryable(ARCH_ERR_FOLLOWER_READ_ONLY));
    TEST("STALE_FOLLOWER is retryable", arch_error_is_retryable(ARCH_ERR_STALE_FOLLOWER));
    TEST("PRIMARY_UNREACHABLE is retryable", arch_error_is_retryable(ARCH_ERR_PRIMARY_UNREACHABLE));
    TEST("REPLICATION_TIMEOUT is retryable", arch_error_is_retryable(ARCH_ERR_REPLICATION_TIMEOUT));
    TEST("CONFLICT_DETECTED is not retryable", !arch_error_is_retryable(ARCH_ERR_CONFLICT_DETECTED));
    TEST("GEO_SHARD_MISMATCH is not retryable", !arch_error_is_retryable(ARCH_ERR_GEO_SHARD_MISMATCH));
    
    /* Sharding errors - mixed */
    TEST("NOT_SHARD_LEADER is retryable", arch_error_is_retryable(ARCH_ERR_NOT_SHARD_LEADER));
    TEST("SHARD_UNAVAILABLE is retryable", arch_error_is_retryable(ARCH_ERR_SHARD_UNAVAILABLE));
    TEST("RESHARDING_IN_PROGRESS is retryable", arch_error_is_retryable(ARCH_ERR_RESHARDING_IN_PROGRESS));
    TEST("INVALID_SHARD_COUNT is not retryable", !arch_error_is_retryable(ARCH_ERR_INVALID_SHARD_COUNT));
    TEST("SHARD_MIGRATION_FAILED is not retryable", !arch_error_is_retryable(ARCH_ERR_SHARD_MIGRATION_FAILED));
    
    /* Encryption errors - mixed */
    TEST("ENCRYPTION_KEY_UNAVAILABLE is retryable", arch_error_is_retryable(ARCH_ERR_ENCRYPTION_KEY_UNAVAILABLE));
    TEST("DECRYPTION_FAILED is not retryable", !arch_error_is_retryable(ARCH_ERR_DECRYPTION_FAILED));
    TEST("ENCRYPTION_NOT_ENABLED is not retryable", !arch_error_is_retryable(ARCH_ERR_ENCRYPTION_NOT_ENABLED));
    TEST("KEY_ROTATION_IN_PROGRESS is retryable", arch_error_is_retryable(ARCH_ERR_KEY_ROTATION_IN_PROGRESS));
    TEST("UNSUPPORTED_ENCRYPTION_VERSION is not retryable", !arch_error_is_retryable(ARCH_ERR_UNSUPPORTED_ENCRYPTION_VERSION));
    
    /* Unknown codes */
    TEST("Unknown code 999 is not retryable", !arch_error_is_retryable(999));
    TEST("Success (0) is not retryable", !arch_error_is_retryable(0));
}

/* Test error names */
void test_error_names(void) {
    printf("\n=== Error Name Tests ===\n\n");
    
    TEST("Success name", strcmp(arch_error_name(0), "SUCCESS") == 0);
    TEST("ENTITY_NOT_FOUND name", strcmp(arch_error_name(ARCH_ERR_ENTITY_NOT_FOUND), "ENTITY_NOT_FOUND") == 0);
    TEST("ENTITY_EXPIRED name", strcmp(arch_error_name(ARCH_ERR_ENTITY_EXPIRED), "ENTITY_EXPIRED") == 0);
    TEST("FOLLOWER_READ_ONLY name", strcmp(arch_error_name(ARCH_ERR_FOLLOWER_READ_ONLY), "FOLLOWER_READ_ONLY") == 0);
    TEST("NOT_SHARD_LEADER name", strcmp(arch_error_name(ARCH_ERR_NOT_SHARD_LEADER), "NOT_SHARD_LEADER") == 0);
    TEST("ENCRYPTION_KEY_UNAVAILABLE name", strcmp(arch_error_name(ARCH_ERR_ENCRYPTION_KEY_UNAVAILABLE), "ENCRYPTION_KEY_UNAVAILABLE") == 0);
    TEST("Unknown code returns UNKNOWN_ERROR", strcmp(arch_error_name(999), "UNKNOWN_ERROR") == 0);
}

/* Test error messages */
void test_error_messages(void) {
    printf("\n=== Error Message Tests ===\n\n");
    
    TEST("Success message exists", arch_error_message(0) != NULL);
    TEST("ENTITY_NOT_FOUND message contains 'not found'", 
         strstr(arch_error_message(ARCH_ERR_ENTITY_NOT_FOUND), "not found") != NULL);
    TEST("ENTITY_EXPIRED message contains 'expired'",
         strstr(arch_error_message(ARCH_ERR_ENTITY_EXPIRED), "expired") != NULL);
    TEST("FOLLOWER_READ_ONLY message contains 'read-only'",
         strstr(arch_error_message(ARCH_ERR_FOLLOWER_READ_ONLY), "read-only") != NULL);
    TEST("NOT_SHARD_LEADER message contains 'leader'",
         strstr(arch_error_message(ARCH_ERR_NOT_SHARD_LEADER), "leader") != NULL);
    TEST("Unknown code returns NULL", arch_error_message(999) == NULL);
}

int main(void) {
    printf("ArcherDB C SDK Error Helpers Test Suite\n");
    printf("========================================\n");
    
    test_is_state_error();
    test_is_multi_region_error();
    test_is_sharding_error();
    test_is_encryption_error();
    test_is_retryable();
    test_error_names();
    test_error_messages();
    
    printf("\n========================================\n");
    printf("Summary: %d passed, %d failed\n", tests_passed, tests_failed);
    
    return tests_failed > 0 ? 1 : 0;
}
