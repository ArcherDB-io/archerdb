/**
 * @file arch_client_errors.h
 * @brief ArcherDB C Client Error Helpers
 * @version 0.1.0
 *
 * @details This header provides human-readable error names, retryability
 *          classification, and error category helpers for ArcherDB error codes.
 *
 * @section error_ranges Error Code Ranges
 * - 0: Success
 * - 1-99: Protocol errors (message format, checksums, version)
 * - 100-199: Validation errors (invalid inputs, constraint violations)
 * - 200-210: State errors (entity not found, expired)
 * - 213-218: Multi-region errors (replication, follower status)
 * - 220-224: Sharding errors (shard routing, resharding)
 * - 300-399: Resource errors (limits exceeded, capacity)
 * - 410-414: Encryption errors (key management, decryption)
 * - 500-599: Internal errors (bugs, should not occur)
 *
 * @section retryability Retryability
 * Use arch_error_is_retryable() to check if an operation can be retried:
 * - Retryable: Transient failures that may succeed on retry
 * - Non-retryable: Permanent failures requiring user intervention
 *
 * @example
 * @code
 * int error_code = operation_result;
 * if (error_code != 0) {
 *     printf("Error: %s\n", arch_error_name(error_code));
 *     if (arch_error_is_retryable(error_code)) {
 *         // Schedule retry with exponential backoff
 *     } else {
 *         // Handle permanent failure
 *     }
 * }
 * @endcode
 */

#ifndef ARCH_CLIENT_ERRORS_H
#define ARCH_CLIENT_ERRORS_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>  /* For NULL */
#include <string.h>  /* For strncpy */

/* ============================================================================
 * Operation Types
 * ============================================================================ */

/** @brief Type of operation that caused an error. */
typedef enum {
    ARCH_OP_UNKNOWN = 0,
    ARCH_OP_INSERT = 1,
    ARCH_OP_UPDATE = 2,
    ARCH_OP_DELETE = 3,
    ARCH_OP_QUERY = 4,
    ARCH_OP_GET = 5,
} arch_operation_type_t;

/** @brief Maximum length for entity ID strings. */
#define ARCH_MAX_ENTITY_ID_LEN 64

/**
 * @brief Operation context for error reporting.
 *
 * This struct holds optional context about the operation that caused an error.
 * All fields are optional - check has_entity_id, has_shard_id, and has_operation_type
 * before using the corresponding values.
 */
typedef struct {
    char entity_id[ARCH_MAX_ENTITY_ID_LEN];  /**< Entity ID involved in error (null-terminated) */
    int shard_id;                              /**< Shard ID involved in error (-1 if not set) */
    arch_operation_type_t operation_type;      /**< Type of operation that caused error */
    bool has_entity_id;                        /**< True if entity_id is set */
    bool has_shard_id;                         /**< True if shard_id is set */
    bool has_operation_type;                   /**< True if operation_type is set */
} arch_error_context_t;

/**
 * @brief Initialize an error context to empty/default values.
 * @param ctx Pointer to context to initialize.
 */
static inline void arch_error_context_init(arch_error_context_t* ctx) {
    if (ctx == NULL) return;
    ctx->entity_id[0] = '\0';
    ctx->shard_id = -1;
    ctx->operation_type = ARCH_OP_UNKNOWN;
    ctx->has_entity_id = false;
    ctx->has_shard_id = false;
    ctx->has_operation_type = false;
}

/**
 * @brief Set the entity ID in an error context.
 * @param ctx Pointer to context.
 * @param entity_id The entity ID (will be truncated if too long).
 */
static inline void arch_error_context_set_entity_id(arch_error_context_t* ctx, const char* entity_id) {
    if (ctx == NULL || entity_id == NULL) return;
    strncpy(ctx->entity_id, entity_id, ARCH_MAX_ENTITY_ID_LEN - 1);
    ctx->entity_id[ARCH_MAX_ENTITY_ID_LEN - 1] = '\0';
    ctx->has_entity_id = true;
}

/**
 * @brief Set the shard ID in an error context.
 * @param ctx Pointer to context.
 * @param shard_id The shard ID.
 */
static inline void arch_error_context_set_shard_id(arch_error_context_t* ctx, int shard_id) {
    if (ctx == NULL) return;
    ctx->shard_id = shard_id;
    ctx->has_shard_id = true;
}

/**
 * @brief Set the operation type in an error context.
 * @param ctx Pointer to context.
 * @param op_type The operation type.
 */
static inline void arch_error_context_set_operation_type(arch_error_context_t* ctx, arch_operation_type_t op_type) {
    if (ctx == NULL) return;
    ctx->operation_type = op_type;
    ctx->has_operation_type = true;
}

/**
 * @brief Get human-readable name for an operation type.
 * @param op_type The operation type.
 * @return Constant string with the operation name.
 */
static inline const char* arch_operation_type_name(arch_operation_type_t op_type) {
    switch (op_type) {
        case ARCH_OP_INSERT: return "insert";
        case ARCH_OP_UPDATE: return "update";
        case ARCH_OP_DELETE: return "delete";
        case ARCH_OP_QUERY: return "query";
        case ARCH_OP_GET: return "get";
        default: return "unknown";
    }
}

/* ============================================================================
 * State Error Codes (200-210)
 * ============================================================================ */

/** @brief Entity UUID not found in index. Non-retryable. */
#define ARCH_ERR_ENTITY_NOT_FOUND 200

/** @brief Entity has expired due to TTL. Non-retryable. */
#define ARCH_ERR_ENTITY_EXPIRED 210

/* ============================================================================
 * Multi-Region Error Codes (213-218)
 * ============================================================================ */

/** @brief Write rejected: follower regions are read-only. Non-retryable. */
#define ARCH_ERR_FOLLOWER_READ_ONLY 213

/** @brief Follower data exceeds maximum staleness threshold. Retryable. */
#define ARCH_ERR_STALE_FOLLOWER 214

/** @brief Cannot connect to primary region. Retryable. */
#define ARCH_ERR_PRIMARY_UNREACHABLE 215

/** @brief Cross-region replication timeout. Retryable. */
#define ARCH_ERR_REPLICATION_TIMEOUT 216

/** @brief Write conflict in active-active replication. Non-retryable. */
#define ARCH_ERR_CONFLICT_DETECTED 217

/** @brief Entity geo-shard does not match target region. Non-retryable. */
#define ARCH_ERR_GEO_SHARD_MISMATCH 218

/* ============================================================================
 * Sharding Error Codes (220-224)
 * ============================================================================ */

/** @brief This node is not the leader for target shard. Retryable. */
#define ARCH_ERR_NOT_SHARD_LEADER 220

/** @brief Target shard has no available replicas. Retryable. */
#define ARCH_ERR_SHARD_UNAVAILABLE 221

/** @brief Cluster is currently resharding. Retryable. */
#define ARCH_ERR_RESHARDING_IN_PROGRESS 222

/** @brief Target shard count is invalid. Non-retryable. */
#define ARCH_ERR_INVALID_SHARD_COUNT 223

/** @brief Data migration to new shard failed. Non-retryable. */
#define ARCH_ERR_SHARD_MIGRATION_FAILED 224

/* ============================================================================
 * Encryption Error Codes (410-414)
 * ============================================================================ */

/** @brief Cannot retrieve encryption key from provider. Retryable. */
#define ARCH_ERR_ENCRYPTION_KEY_UNAVAILABLE 410

/** @brief Failed to decrypt data (auth tag mismatch). Non-retryable. */
#define ARCH_ERR_DECRYPTION_FAILED 411

/** @brief Encryption required but not configured. Non-retryable. */
#define ARCH_ERR_ENCRYPTION_NOT_ENABLED 412

/** @brief Key rotation in progress. Retryable. */
#define ARCH_ERR_KEY_ROTATION_IN_PROGRESS 413

/** @brief File encrypted with unsupported version. Non-retryable. */
#define ARCH_ERR_UNSUPPORTED_ENCRYPTION_VERSION 414

/* ============================================================================
 * Error Category Detection
 * ============================================================================ */

/**
 * @brief Check if error code is a state error (200-210).
 * @param code The error code to check.
 * @return true if code is in the state error range.
 */
static inline bool arch_error_is_state_error(int code) {
    return code >= 200 && code <= 210;
}

/**
 * @brief Check if error code is a multi-region error (213-218).
 * @param code The error code to check.
 * @return true if code is in the multi-region error range.
 */
static inline bool arch_error_is_multi_region_error(int code) {
    return code >= 213 && code <= 218;
}

/**
 * @brief Check if error code is a sharding error (220-224).
 * @param code The error code to check.
 * @return true if code is in the sharding error range.
 */
static inline bool arch_error_is_sharding_error(int code) {
    return code >= 220 && code <= 224;
}

/**
 * @brief Check if error code is an encryption error (410-414).
 * @param code The error code to check.
 * @return true if code is in the encryption error range.
 */
static inline bool arch_error_is_encryption_error(int code) {
    return code >= 410 && code <= 414;
}

/* ============================================================================
 * Retryability Classification
 * ============================================================================ */

/**
 * @brief Check if an error is retryable.
 *
 * Retryable errors are transient failures that may succeed if retried.
 * Non-retryable errors indicate permanent failures requiring user intervention.
 *
 * @param code The error code to check.
 * @return true if the error may succeed on retry, false if permanent.
 *
 * @par Retryable errors include:
 * - ARCH_ERR_STALE_FOLLOWER (214)
 * - ARCH_ERR_PRIMARY_UNREACHABLE (215)
 * - ARCH_ERR_REPLICATION_TIMEOUT (216)
 * - ARCH_ERR_NOT_SHARD_LEADER (220)
 * - ARCH_ERR_SHARD_UNAVAILABLE (221)
 * - ARCH_ERR_RESHARDING_IN_PROGRESS (222)
 * - ARCH_ERR_ENCRYPTION_KEY_UNAVAILABLE (410)
 * - ARCH_ERR_KEY_ROTATION_IN_PROGRESS (413)
 *
 * @par Non-retryable errors include:
 * - ARCH_ERR_ENTITY_NOT_FOUND (200)
 * - ARCH_ERR_ENTITY_EXPIRED (210)
 * - ARCH_ERR_FOLLOWER_READ_ONLY (213)
 * - ARCH_ERR_CONFLICT_DETECTED (217)
 * - ARCH_ERR_GEO_SHARD_MISMATCH (218)
 * - ARCH_ERR_INVALID_SHARD_COUNT (223)
 * - ARCH_ERR_SHARD_MIGRATION_FAILED (224)
 * - ARCH_ERR_DECRYPTION_FAILED (411)
 * - ARCH_ERR_ENCRYPTION_NOT_ENABLED (412)
 * - ARCH_ERR_UNSUPPORTED_ENCRYPTION_VERSION (414)
 */
static inline bool arch_error_is_retryable(int code) {
    switch (code) {
        /* Retryable multi-region errors */
        case ARCH_ERR_STALE_FOLLOWER:
        case ARCH_ERR_PRIMARY_UNREACHABLE:
        case ARCH_ERR_REPLICATION_TIMEOUT:
        /* Retryable sharding errors */
        case ARCH_ERR_NOT_SHARD_LEADER:
        case ARCH_ERR_SHARD_UNAVAILABLE:
        case ARCH_ERR_RESHARDING_IN_PROGRESS:
        /* Retryable encryption errors */
        case ARCH_ERR_ENCRYPTION_KEY_UNAVAILABLE:
        case ARCH_ERR_KEY_ROTATION_IN_PROGRESS:
            return true;
        default:
            return false;
    }
}

/* ============================================================================
 * Human-Readable Error Names
 * ============================================================================ */

/**
 * @brief Get human-readable name for an error code.
 *
 * @param code The error code.
 * @return Constant string with the error name, or "UNKNOWN_ERROR" if not recognized.
 *
 * @note The returned string is statically allocated and should not be freed.
 */
static inline const char* arch_error_name(int code) {
    switch (code) {
        /* Success */
        case 0:
            return "SUCCESS";
        
        /* State errors (200-210) */
        case ARCH_ERR_ENTITY_NOT_FOUND:
            return "ENTITY_NOT_FOUND";
        case ARCH_ERR_ENTITY_EXPIRED:
            return "ENTITY_EXPIRED";
        
        /* Multi-region errors (213-218) */
        case ARCH_ERR_FOLLOWER_READ_ONLY:
            return "FOLLOWER_READ_ONLY";
        case ARCH_ERR_STALE_FOLLOWER:
            return "STALE_FOLLOWER";
        case ARCH_ERR_PRIMARY_UNREACHABLE:
            return "PRIMARY_UNREACHABLE";
        case ARCH_ERR_REPLICATION_TIMEOUT:
            return "REPLICATION_TIMEOUT";
        case ARCH_ERR_CONFLICT_DETECTED:
            return "CONFLICT_DETECTED";
        case ARCH_ERR_GEO_SHARD_MISMATCH:
            return "GEO_SHARD_MISMATCH";
        
        /* Sharding errors (220-224) */
        case ARCH_ERR_NOT_SHARD_LEADER:
            return "NOT_SHARD_LEADER";
        case ARCH_ERR_SHARD_UNAVAILABLE:
            return "SHARD_UNAVAILABLE";
        case ARCH_ERR_RESHARDING_IN_PROGRESS:
            return "RESHARDING_IN_PROGRESS";
        case ARCH_ERR_INVALID_SHARD_COUNT:
            return "INVALID_SHARD_COUNT";
        case ARCH_ERR_SHARD_MIGRATION_FAILED:
            return "SHARD_MIGRATION_FAILED";
        
        /* Encryption errors (410-414) */
        case ARCH_ERR_ENCRYPTION_KEY_UNAVAILABLE:
            return "ENCRYPTION_KEY_UNAVAILABLE";
        case ARCH_ERR_DECRYPTION_FAILED:
            return "DECRYPTION_FAILED";
        case ARCH_ERR_ENCRYPTION_NOT_ENABLED:
            return "ENCRYPTION_NOT_ENABLED";
        case ARCH_ERR_KEY_ROTATION_IN_PROGRESS:
            return "KEY_ROTATION_IN_PROGRESS";
        case ARCH_ERR_UNSUPPORTED_ENCRYPTION_VERSION:
            return "UNSUPPORTED_ENCRYPTION_VERSION";
        
        default:
            return "UNKNOWN_ERROR";
    }
}

/**
 * @brief Get human-readable message for an error code.
 *
 * @param code The error code.
 * @return Constant string with the error message, or NULL if not recognized.
 *
 * @note The returned string is statically allocated and should not be freed.
 */
static inline const char* arch_error_message(int code) {
    switch (code) {
        /* Success */
        case 0:
            return "Operation completed successfully";
        
        /* State errors (200-210) */
        case ARCH_ERR_ENTITY_NOT_FOUND:
            return "Entity not found";
        case ARCH_ERR_ENTITY_EXPIRED:
            return "Entity has expired due to TTL";
        
        /* Multi-region errors (213-218) */
        case ARCH_ERR_FOLLOWER_READ_ONLY:
            return "Write operation rejected: follower regions are read-only";
        case ARCH_ERR_STALE_FOLLOWER:
            return "Follower data exceeds maximum staleness threshold";
        case ARCH_ERR_PRIMARY_UNREACHABLE:
            return "Cannot connect to primary region";
        case ARCH_ERR_REPLICATION_TIMEOUT:
            return "Cross-region replication timeout";
        case ARCH_ERR_CONFLICT_DETECTED:
            return "Write conflict detected in active-active replication";
        case ARCH_ERR_GEO_SHARD_MISMATCH:
            return "Entity geo-shard does not match target region";
        
        /* Sharding errors (220-224) */
        case ARCH_ERR_NOT_SHARD_LEADER:
            return "This node is not the leader for target shard";
        case ARCH_ERR_SHARD_UNAVAILABLE:
            return "Target shard has no available replicas";
        case ARCH_ERR_RESHARDING_IN_PROGRESS:
            return "Cluster is currently resharding";
        case ARCH_ERR_INVALID_SHARD_COUNT:
            return "Target shard count is invalid";
        case ARCH_ERR_SHARD_MIGRATION_FAILED:
            return "Data migration to new shard failed";
        
        /* Encryption errors (410-414) */
        case ARCH_ERR_ENCRYPTION_KEY_UNAVAILABLE:
            return "Cannot retrieve encryption key from provider";
        case ARCH_ERR_DECRYPTION_FAILED:
            return "Failed to decrypt data (auth tag mismatch)";
        case ARCH_ERR_ENCRYPTION_NOT_ENABLED:
            return "Encryption required but not configured";
        case ARCH_ERR_KEY_ROTATION_IN_PROGRESS:
            return "Key rotation in progress, retry later";
        case ARCH_ERR_UNSUPPORTED_ENCRYPTION_VERSION:
            return "File encrypted with unsupported version";
        
        default:
            return NULL;
    }
}

#ifdef __cplusplus
}
#endif

#endif /* ARCH_CLIENT_ERRORS_H */
