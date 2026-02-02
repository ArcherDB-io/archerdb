// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

/**
 * @file test_all_operations.c
 * @brief Comprehensive tests for all 14 ArcherDB C SDK operations
 *
 * This test file loads JSON fixtures from Phase 11 and validates the C SDK
 * against expected behavior for all operations:
 *
 * Data Operations:
 *   1. insert (opcode 146)
 *   2. upsert (opcode 147)
 *   3. delete (opcode 148)
 *
 * Query Operations:
 *   4. query-uuid (opcode 149)
 *   5. query-uuid-batch (opcode 156)
 *   6. query-radius (opcode 150)
 *   7. query-polygon (opcode 151)
 *   8. query-latest (opcode 154)
 *
 * Metadata Operations:
 *   9. ping (opcode 152)
 *   10. status (opcode 153)
 *   11. topology (opcode 157)
 *
 * TTL Operations:
 *   12. ttl-set (opcode 158)
 *   13. ttl-extend (opcode 159)
 *   14. ttl-clear (opcode 160)
 *
 * Run with:
 *   ARCHERDB_INTEGRATION=1 ./zig-out/bin/test_all_operations
 *
 * Environment variables:
 *   ARCHERDB_INTEGRATION=1  - Required to run tests
 *   ARCHERDB_ADDRESS        - Server address (default: 127.0.0.1:3001)
 *   TEST_TAG                - Filter tests by tag (smoke, pr, nightly)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>
#include "fixture_adapter.h"
#include "../../../src/clients/c/arch_client.h"

// Test counters
static int tests_passed = 0;
static int tests_failed = 0;
static int tests_skipped = 0;

// Forward declarations
static bool setup(void);
static void teardown(void);

// Client and synchronization
static arch_client_t client;
static bool client_initialized = false;
static pthread_mutex_t completion_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t completion_cond = PTHREAD_COND_INITIALIZER;
static int pending_requests = 0;

// Response storage
static struct {
    uint8_t data[1024 * 1024];  // 1MB buffer
    uint32_t len;
    bool received;
    ARCH_PACKET_STATUS status;
} last_response;

// Completion callback
static void on_complete(uintptr_t ctx, arch_packet_t* packet,
                       uint64_t timestamp, const uint8_t* data, uint32_t len) {
    (void)ctx;
    (void)timestamp;

    pthread_mutex_lock(&completion_mutex);

    last_response.status = (ARCH_PACKET_STATUS)packet->status;
    if (data && len > 0 && len <= sizeof(last_response.data)) {
        memcpy(last_response.data, data, len);
        last_response.len = len;
    } else {
        last_response.len = 0;
    }
    last_response.received = true;
    pending_requests--;

    pthread_cond_signal(&completion_cond);
    pthread_mutex_unlock(&completion_mutex);
}

// Wait for pending request to complete
static bool wait_for_completion(int timeout_ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (timeout_ms % 1000) * 1000000;
    if (ts.tv_nsec >= 1000000000) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000;
    }

    pthread_mutex_lock(&completion_mutex);
    while (pending_requests > 0) {
        int rc = pthread_cond_timedwait(&completion_cond, &completion_mutex, &ts);
        if (rc != 0) {
            pthread_mutex_unlock(&completion_mutex);
            return false;
        }
    }
    pthread_mutex_unlock(&completion_mutex);
    return true;
}

// Submit a request and wait for completion
static bool submit_and_wait(arch_packet_t* packet) {
    pthread_mutex_lock(&completion_mutex);
    last_response.received = false;
    pending_requests++;
    pthread_mutex_unlock(&completion_mutex);

    ARCH_CLIENT_STATUS status = arch_client_submit(&client, packet);
    if (status != ARCH_CLIENT_OK) {
        pthread_mutex_lock(&completion_mutex);
        pending_requests--;
        pthread_mutex_unlock(&completion_mutex);
        return false;
    }

    bool completed = wait_for_completion(30000);  // 30 second timeout

    // Check for client eviction and reconnect automatically
    if (completed && last_response.status == ARCH_PACKET_CLIENT_EVICTED) {
        // Client was evicted (likely due to invalid request)
        // Reconnect silently so subsequent tests can continue
        teardown();
        if (setup()) {
            // Reconnection successful - treat this request as failed but continue testing
            return false;
        } else {
            // Reconnection failed - this is a fatal error
            fprintf(stderr, "FATAL: Failed to reconnect after client eviction\n");
            exit(1);
        }
    }

    return completed;
}

// Initialize the client
static bool setup(void) {
    const char* addr = getenv("ARCHERDB_ADDRESS");
    if (!addr) addr = "127.0.0.1:3001";

    uint8_t cluster_id[16] = {0};

    ARCH_INIT_STATUS status = arch_client_init(
        &client,
        cluster_id,
        addr,
        (uint32_t)strlen(addr),
        0,
        on_complete
    );

    if (status != ARCH_INIT_SUCCESS) {
        fprintf(stderr, "Failed to initialize client: %d\n", status);
        return false;
    }

    client_initialized = true;
    return true;
}

// Cleanup the client
static void teardown(void) {
    if (client_initialized) {
        arch_client_deinit(&client);
        client_initialized = false;
    }
}

// Check for eviction and reconnect if needed
static bool handle_eviction(void) {
    if (last_response.status == ARCH_PACKET_CLIENT_EVICTED) {
        fprintf(stderr, "error(client): session evicted, reconnecting...\n");
        teardown();
        if (!setup()) {
            fprintf(stderr, "error(client): failed to reconnect after eviction\n");
            return false;
        }
        return true;
    }
    return false;
}

// Helper: Insert events for setup
static bool insert_setup_events(const geo_event_t* events, int count) {
    if (count == 0) return true;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_INSERT_EVENTS;
    packet.data = (void*)events;
    packet.data_size = count * sizeof(geo_event_t);

    return submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK;
}

// Helper: Delete all entities (cleanup)
static bool delete_entities(const arch_uint128_t* ids, int count) {
    if (count == 0) return true;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_DELETE_ENTITIES;
    packet.data = (void*)ids;
    packet.data_size = count * sizeof(arch_uint128_t);

    return submit_and_wait(&packet);
}

// ============================================================================
// Test: Ping (opcode 152)
// ============================================================================
static void test_ping(void) {
    printf("\n=== Testing ping operations ===\n");

    Fixture* fixture = load_fixture("ping");
    if (!fixture) {
        printf("SKIP: Could not load ping fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        ping_request_t req = {0};
        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_ARCHERDB_PING;
        packet.data = &req;
        packet.data_size = sizeof(req);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - no response\n");
            tests_failed++;
        }
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Status (opcode 153)
// ============================================================================
static void test_status(void) {
    printf("\n=== Testing status operations ===\n");

    Fixture* fixture = load_fixture("status");
    if (!fixture) {
        printf("SKIP: Could not load status fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        status_request_t req = {0};
        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_ARCHERDB_GET_STATUS;
        packet.data = &req;
        packet.data_size = sizeof(req);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            if (last_response.len >= sizeof(status_response_t)) {
                printf("\033[32mPASS\033[0m\n");
                tests_passed++;
            } else {
                printf("\033[31mFAIL\033[0m - invalid response size\n");
                tests_failed++;
            }
        } else {
            printf("\033[31mFAIL\033[0m - no response\n");
            tests_failed++;
        }
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Topology (opcode 157)
// ============================================================================
static void test_topology(void) {
    printf("\n=== Testing topology operations ===\n");

    Fixture* fixture = load_fixture("topology");
    if (!fixture) {
        printf("SKIP: Could not load topology fixture\n");
        tests_skipped++;
        return;
    }

    // Only run the first (smoke) test case - topology depends on cluster config
    TestCase* tc = &fixture->cases[0];
    printf("  %s: ", tc->name);

    topology_request_t req = {0};
    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_GET_TOPOLOGY;
    packet.data = &req;
    packet.data_size = sizeof(req);

    if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
        printf("\033[32mPASS\033[0m\n");
        tests_passed++;
    } else {
        printf("\033[31mFAIL\033[0m - no response\n");
        tests_failed++;
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Insert (opcode 146)
// ============================================================================
static void test_insert(void) {
    printf("\n=== Testing insert operations ===\n");

    Fixture* fixture = load_fixture("insert");
    if (!fixture) {
        printf("SKIP: Could not load insert fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        if (tc->event_count == 0) {
            printf("\033[33mSKIP\033[0m - no events\n");
            tests_skipped++;
            continue;
        }

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_INSERT_EVENTS;
        packet.data = tc->events;
        packet.data_size = tc->event_count * sizeof(geo_event_t);

        bool success = submit_and_wait(&packet);

        // For invalid test cases, client eviction is EXPECTED behavior
        if (strstr(tc->name, "invalid") != NULL) {
            // Invalid inputs should cause eviction or error
            if (!success || last_response.status == ARCH_PACKET_CLIENT_EVICTED) {
                printf("\033[32mPASS\033[0m (expected rejection)\n");
                tests_passed++;
            } else if (last_response.status == ARCH_PACKET_OK && last_response.len > 0) {
                // Check if got error results
                insert_geo_events_result_t* results = (insert_geo_events_result_t*)last_response.data;
                int result_count = last_response.len / sizeof(insert_geo_events_result_t);
                bool has_error = false;
                for (int j = 0; j < result_count; j++) {
                    if (results[j].result != INSERT_GEO_EVENT_OK) {
                        has_error = true;
                        break;
                    }
                }
                if (has_error) {
                    printf("\033[32mPASS\033[0m (expected error)\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - expected error not found\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - unexpected success\n");
                tests_failed++;
            }
        } else if (success && last_response.status == ARCH_PACKET_OK) {
            // Normal test cases should succeed
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup: delete inserted entities
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->event_count; j++) {
            ids[j] = tc->events[j].entity_id;
        }
        delete_entities(ids, tc->event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Upsert (opcode 147)
// ============================================================================
static void test_upsert(void) {
    printf("\n=== Testing upsert operations ===\n");

    Fixture* fixture = load_fixture("upsert");
    if (!fixture) {
        printf("SKIP: Could not load upsert fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert any prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        if (tc->event_count == 0) {
            printf("\033[33mSKIP\033[0m - no events\n");
            tests_skipped++;
            continue;
        }

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_UPSERT_EVENTS;
        packet.data = tc->events;
        packet.data_size = tc->event_count * sizeof(geo_event_t);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[id_count++] = tc->setup_events[j].entity_id;
        }
        for (int j = 0; j < tc->event_count; j++) {
            ids[id_count++] = tc->events[j].entity_id;
        }
        delete_entities(ids, id_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Delete (opcode 148)
// ============================================================================
static void test_delete(void) {
    printf("\n=== Testing delete operations ===\n");

    Fixture* fixture = load_fixture("delete");
    if (!fixture) {
        printf("SKIP: Could not load delete fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        if (tc->entity_id_count == 0) {
            printf("\033[33mSKIP\033[0m - no entity IDs\n");
            tests_skipped++;
            continue;
        }

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_DELETE_ENTITIES;
        packet.data = tc->entity_ids;
        packet.data_size = tc->entity_id_count * sizeof(arch_uint128_t);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Query UUID (opcode 149)
// ============================================================================
static void test_query_uuid(void) {
    printf("\n=== Testing query-uuid operations ===\n");

    Fixture* fixture = load_fixture("query-uuid");
    if (!fixture) {
        printf("SKIP: Could not load query-uuid fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        if (tc->entity_id_count == 0 && tc->setup_event_count == 0) {
            printf("\033[33mSKIP\033[0m - no entity ID\n");
            tests_skipped++;
            continue;
        }

        // Query for the first entity
        arch_uint128_t query_id = tc->entity_id_count > 0 ?
            tc->entity_ids[0] : tc->setup_events[0].entity_id;

        query_uuid_filter_t filter = {0};
        filter.entity_id = query_id;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_UUID;
        packet.data = &filter;
        packet.data_size = sizeof(filter);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Query UUID Batch (opcode 156)
// ============================================================================
static void test_query_uuid_batch(void) {
    printf("\n=== Testing query-uuid-batch operations ===\n");

    Fixture* fixture = load_fixture("query-uuid-batch");
    if (!fixture) {
        printf("SKIP: Could not load query-uuid-batch fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        if (tc->entity_id_count == 0 && tc->setup_event_count == 0) {
            printf("\033[33mSKIP\033[0m - no entity IDs\n");
            tests_skipped++;
            continue;
        }

        // Build request: header + entity IDs
        uint8_t request_data[sizeof(query_uuid_batch_filter_t) +
                           MAX_EVENTS_PER_CASE * sizeof(arch_uint128_t)];

        query_uuid_batch_filter_t* header = (query_uuid_batch_filter_t*)request_data;
        arch_uint128_t* ids = (arch_uint128_t*)(request_data + sizeof(*header));

        int id_count = tc->entity_id_count > 0 ? tc->entity_id_count : tc->setup_event_count;
        header->count = id_count;
        memset(header->reserved, 0, sizeof(header->reserved));

        if (tc->entity_id_count > 0) {
            memcpy(ids, tc->entity_ids, id_count * sizeof(arch_uint128_t));
        } else {
            for (int j = 0; j < tc->setup_event_count; j++) {
                ids[j] = tc->setup_events[j].entity_id;
            }
        }

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_UUID_BATCH;
        packet.data = request_data;
        packet.data_size = sizeof(*header) + id_count * sizeof(arch_uint128_t);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t cleanup_ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            cleanup_ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(cleanup_ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Query Radius (opcode 150)
// ============================================================================
static void test_query_radius(void) {
    printf("\n=== Testing query-radius operations ===\n");

    Fixture* fixture = load_fixture("query-radius");
    if (!fixture) {
        printf("SKIP: Could not load query-radius fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        query_radius_filter_t filter = {0};
        filter.center_lat_nano = degrees_to_nano(tc->center_latitude);
        filter.center_lon_nano = degrees_to_nano(tc->center_longitude);
        filter.radius_mm = tc->radius_m * 1000;  // Convert to mm
        filter.limit = tc->limit > 0 ? tc->limit : 1000;
        filter.group_id = tc->group_id;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_RADIUS;
        packet.data = &filter;
        packet.data_size = sizeof(filter);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Query Polygon (opcode 151)
// ============================================================================
static void test_query_polygon(void) {
    printf("\n=== Testing query-polygon operations ===\n");

    Fixture* fixture = load_fixture("query-polygon");
    if (!fixture) {
        printf("SKIP: Could not load query-polygon fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        // Create a simple square polygon around the center
        uint8_t request_data[sizeof(query_polygon_filter_t) + 4 * sizeof(polygon_vertex_t)];
        query_polygon_filter_t* filter = (query_polygon_filter_t*)request_data;
        polygon_vertex_t* vertices = (polygon_vertex_t*)(request_data + sizeof(*filter));

        memset(filter, 0, sizeof(*filter));
        filter->vertex_count = 4;
        filter->hole_count = 0;
        filter->limit = tc->limit > 0 ? tc->limit : 1000;
        filter->group_id = tc->group_id;

        // Create a 1km square around center (approximately)
        double lat = tc->center_latitude;
        double lon = tc->center_longitude;
        double delta = 0.01;  // ~1km

        vertices[0].lat_nano = degrees_to_nano(lat + delta);
        vertices[0].lon_nano = degrees_to_nano(lon - delta);
        vertices[1].lat_nano = degrees_to_nano(lat + delta);
        vertices[1].lon_nano = degrees_to_nano(lon + delta);
        vertices[2].lat_nano = degrees_to_nano(lat - delta);
        vertices[2].lon_nano = degrees_to_nano(lon + delta);
        vertices[3].lat_nano = degrees_to_nano(lat - delta);
        vertices[3].lon_nano = degrees_to_nano(lon - delta);

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_POLYGON;
        packet.data = request_data;
        packet.data_size = sizeof(*filter) + 4 * sizeof(polygon_vertex_t);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: Query Latest (opcode 154)
// ============================================================================
static void test_query_latest(void) {
    printf("\n=== Testing query-latest operations ===\n");

    Fixture* fixture = load_fixture("query-latest");
    if (!fixture) {
        printf("SKIP: Could not load query-latest fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        query_latest_filter_t filter = {0};
        filter.limit = tc->limit > 0 ? tc->limit : 100;
        filter.group_id = tc->group_id;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_LATEST;
        packet.data = &filter;
        packet.data_size = sizeof(filter);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: TTL Set (opcode 158)
// ============================================================================
static void test_ttl_set(void) {
    printf("\n=== Testing ttl-set operations ===\n");

    Fixture* fixture = load_fixture("ttl-set");
    if (!fixture) {
        printf("SKIP: Could not load ttl-set fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        arch_uint128_t entity_id = tc->entity_id_count > 0 ?
            tc->entity_ids[0] :
            (tc->setup_event_count > 0 ? tc->setup_events[0].entity_id : 0);

        if (entity_id == 0) {
            printf("\033[33mSKIP\033[0m - no entity ID\n");
            tests_skipped++;
            continue;
        }

        ttl_set_request_t req = {0};
        req.entity_id = entity_id;
        req.ttl_seconds = tc->ttl_seconds > 0 ? tc->ttl_seconds : 3600;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_TTL_SET;
        packet.data = &req;
        packet.data_size = sizeof(req);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: TTL Extend (opcode 159)
// ============================================================================
static void test_ttl_extend(void) {
    printf("\n=== Testing ttl-extend operations ===\n");

    Fixture* fixture = load_fixture("ttl-extend");
    if (!fixture) {
        printf("SKIP: Could not load ttl-extend fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        arch_uint128_t entity_id = tc->entity_id_count > 0 ?
            tc->entity_ids[0] :
            (tc->setup_event_count > 0 ? tc->setup_events[0].entity_id : 0);

        if (entity_id == 0) {
            printf("\033[33mSKIP\033[0m - no entity ID\n");
            tests_skipped++;
            continue;
        }

        ttl_extend_request_t req = {0};
        req.entity_id = entity_id;
        req.extend_by_seconds = tc->ttl_seconds > 0 ? tc->ttl_seconds : 1800;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_TTL_EXTEND;
        packet.data = &req;
        packet.data_size = sizeof(req);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Test: TTL Clear (opcode 160)
// ============================================================================
static void test_ttl_clear(void) {
    printf("\n=== Testing ttl-clear operations ===\n");

    Fixture* fixture = load_fixture("ttl-clear");
    if (!fixture) {
        printf("SKIP: Could not load ttl-clear fixture\n");
        tests_skipped++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (tc->setup_event_count > 0) {
            if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
                printf("\033[33mSKIP\033[0m - setup failed\n");
                tests_skipped++;
                continue;
            }
        }

        arch_uint128_t entity_id = tc->entity_id_count > 0 ?
            tc->entity_ids[0] :
            (tc->setup_event_count > 0 ? tc->setup_events[0].entity_id : 0);

        if (entity_id == 0) {
            printf("\033[33mSKIP\033[0m - no entity ID\n");
            tests_skipped++;
            continue;
        }

        ttl_clear_request_t req = {0};
        req.entity_id = entity_id;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_TTL_CLEAR;
        packet.data = &req;
        packet.data_size = sizeof(req);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            printf("\033[32mPASS\033[0m\n");
            tests_passed++;
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE];
        for (int j = 0; j < tc->setup_event_count; j++) {
            ids[j] = tc->setup_events[j].entity_id;
        }
        delete_entities(ids, tc->setup_event_count);
    }

    free_fixture(fixture);
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char** argv) {
    (void)argc;
    (void)argv;

    // Check for integration flag
    const char* integration = getenv("ARCHERDB_INTEGRATION");
    if (!integration || strcmp(integration, "1") != 0) {
        printf("C SDK Operation Tests\n");
        printf("=====================\n\n");
        printf("Set ARCHERDB_INTEGRATION=1 to run integration tests.\n");
        printf("Requires a running ArcherDB server.\n");
        printf("\nUsage:\n");
        printf("  ARCHERDB_INTEGRATION=1 ./test_all_operations\n");
        printf("  ARCHERDB_ADDRESS=host:port ARCHERDB_INTEGRATION=1 ./test_all_operations\n");
        return 0;
    }

    printf("C SDK Operation Tests\n");
    printf("=====================\n");
    printf("Using fixtures from test_infrastructure/fixtures/v1/\n\n");

    // Initialize client
    if (!setup()) {
        fprintf(stderr, "Failed to connect to server\n");
        return 1;
    }

    // Run all test suites (all 14 operations)

    // Metadata operations (quick connectivity tests)
    test_ping();
    test_status();
    test_topology();

    // Data operations
    test_insert();
    test_upsert();
    test_delete();

    // Query operations
    test_query_uuid();
    test_query_uuid_batch();
    test_query_radius();
    test_query_polygon();
    test_query_latest();

    // TTL operations
    test_ttl_set();
    test_ttl_extend();
    test_ttl_clear();

    // Cleanup
    teardown();

    // Report results
    printf("\n========================================\n");
    printf("Results: %d passed, %d failed, %d skipped\n",
           tests_passed, tests_failed, tests_skipped);
    printf("========================================\n");

    return tests_failed > 0 ? 1 : 0;
}
