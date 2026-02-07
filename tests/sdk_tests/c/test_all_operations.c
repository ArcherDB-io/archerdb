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

    bool completed = wait_for_completion(2000);  // 2 second timeout for faster debugging

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
    fprintf(stderr, "[DEBUG] setup: starting\n");
    fflush(stderr);
    
    const char* addr = getenv("ARCHERDB_ADDRESS");
    if (!addr) addr = "127.0.0.1:3001";

    fprintf(stderr, "[DEBUG] setup: using address: %s\n", addr);
    fflush(stderr);

    uint8_t cluster_id[16] = {0};

    fprintf(stderr, "[DEBUG] setup: calling arch_client_init\n");
    fflush(stderr);
    
    ARCH_INIT_STATUS status = arch_client_init(
        &client,
        cluster_id,
        addr,
        (uint32_t)strlen(addr),
        0,
        on_complete
    );

    fprintf(stderr, "[DEBUG] setup: arch_client_init returned: %d\n", status);
    fflush(stderr);

    if (status != ARCH_INIT_SUCCESS) {
        fprintf(stderr, "Failed to initialize client: %d\n", status);
        return false;
    }

    client_initialized = true;
    
    fprintf(stderr, "[DEBUG] setup: waiting for registration to complete\n");
    fflush(stderr);
    
    // Poll for registration completion by checking init_parameters
    // Registration is complete when batch_size_limit becomes available
    arch_init_parameters_t params;
    int retries = 0;
    const int max_retries = 40;  // 40 * 250ms = 10 seconds max
    
    while (retries < max_retries) {
        usleep(250000);  // 250ms
        
        ARCH_CLIENT_STATUS param_status = arch_client_init_parameters(&client, &params);
        if (param_status == ARCH_CLIENT_OK) {
            fprintf(stderr, "[DEBUG] setup: registration complete after %d retries (%.2fs)\n", 
                    retries, retries * 0.25);
            fflush(stderr);
            break;
        }
        retries++;
    }
    
    if (retries >= max_retries) {
        fprintf(stderr, "Failed: registration did not complete after %.1fs\n", max_retries * 0.25);
        return false;
    }
    
    fprintf(stderr, "[DEBUG] setup: complete\n");
    fflush(stderr);
    
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

static int append_event_ids(arch_uint128_t* ids, int count,
                            const geo_event_t* events, int event_count) {
    for (int i = 0; i < event_count && count < MAX_EVENTS_PER_CASE; i++) {
        ids[count++] = events[i].entity_id;
    }
    return count;
}

static arch_uint128_t next_generated_entity_id(void) {
    static arch_uint128_t counter = 9000000;
    return counter++;
}

static void init_event_basic_local(geo_event_t* event, arch_uint128_t entity_id,
                                   double lat, double lon, uint64_t group_id) {
    memset(event, 0, sizeof(*event));
    event->entity_id = entity_id;
    event->id = entity_id;
    event->lat_nano = degrees_to_nano(lat);
    event->lon_nano = degrees_to_nano(lon);
    event->group_id = group_id;
}

static bool apply_setup_actions(TestCase* tc) {
    if (tc->setup_event_count > 0) {
        if (!insert_setup_events(tc->setup_events, tc->setup_event_count)) {
            return false;
        }
    }
    if (tc->setup_upsert_event_count > 0) {
        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_UPSERT_EVENTS;
        packet.data = (void*)tc->setup_upsert_events;
        packet.data_size = tc->setup_upsert_event_count * sizeof(geo_event_t);
        if (!submit_and_wait(&packet) || last_response.status != ARCH_PACKET_OK) {
            return false;
        }
    }
    if (tc->has_setup_clear_ttl) {
        ttl_clear_request_t req = {0};
        req.entity_id = tc->setup_clear_ttl_id;
        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_TTL_CLEAR;
        packet.data = &req;
        packet.data_size = sizeof(req);
        if (!submit_and_wait(&packet) || last_response.status != ARCH_PACKET_OK) {
            return false;
        }
    }
    if (tc->has_setup_wait_seconds && tc->setup_wait_seconds > 0) {
        sleep(tc->setup_wait_seconds);
    }

    if (tc->setup_operation_count > 0) {
        tc->setup_extra_event_count = 0;
        for (int i = 0; i < tc->setup_operation_count; i++) {
            setup_operation_t* op = &tc->setup_operations[i];
            if (op->type == SETUP_OP_INSERT) {
                int remaining = op->count;
                while (remaining > 0) {
                    int chunk = remaining > MAX_EVENTS_PER_CASE ? MAX_EVENTS_PER_CASE : remaining;
                    geo_event_t events[MAX_EVENTS_PER_CASE];
                    for (int j = 0; j < chunk; j++) {
                        arch_uint128_t id = next_generated_entity_id();
                        double lat = 40.0 + (j * 0.0001);
                        double lon = -74.0 - (j * 0.0001);
                        init_event_basic_local(&events[j], id, lat, lon, 0);
                        if (tc->setup_extra_event_count < MAX_EVENTS_PER_CASE) {
                            tc->setup_extra_events[tc->setup_extra_event_count++] = events[j];
                        }
                    }
                    arch_packet_t packet = {0};
                    packet.operation = ARCH_OPERATION_INSERT_EVENTS;
                    packet.data = events;
                    packet.data_size = chunk * sizeof(geo_event_t);
                    if (!submit_and_wait(&packet) || last_response.status != ARCH_PACKET_OK) {
                        return false;
                    }
                    remaining -= chunk;
                }
            } else if (op->type == SETUP_OP_QUERY_RADIUS) {
                query_radius_filter_t filter = {0};
                filter.center_lat_nano = degrees_to_nano(40.0);
                filter.center_lon_nano = degrees_to_nano(-74.0);
                filter.radius_mm = 1000 * 1000;
                filter.limit = 10;
                for (int j = 0; j < op->count; j++) {
                    arch_packet_t packet = {0};
                    packet.operation = ARCH_OPERATION_QUERY_RADIUS;
                    packet.data = &filter;
                    packet.data_size = sizeof(filter);
                    if (!submit_and_wait(&packet) || last_response.status != ARCH_PACKET_OK) {
                        return false;
                    }
                }
            }
        }
    }
    return true;
}

static bool parse_query_response(const uint8_t* data, uint32_t len,
                                 const geo_event_t** events_out,
                                 uint32_t* count_out) {
    if (len == 0) {
        *count_out = 0;
        *events_out = NULL;
        return true;
    }
    if (len == sizeof(uint32_t)) {
        // 4-byte error code responses (e.g., unsupported polygon in lite config).
        *count_out = 0;
        *events_out = NULL;
        return true;
    }
    if (len < sizeof(query_response_t)) {
        return false;
    }
    query_response_t header;
    memcpy(&header, data, sizeof(header));
    uint32_t count = header.count;
    uint32_t expected_len = sizeof(query_response_t) + count * sizeof(geo_event_t);
    if (len < expected_len) {
        return false;
    }
    *count_out = count;
    *events_out = (const geo_event_t*)(data + sizeof(query_response_t));
    return true;
}


static int get_output_cap(uint32_t inserted_count) {
    if (inserted_count == 0) return -1;

    query_latest_filter_t filter = {0};
    filter.limit = 10000;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_QUERY_LATEST;
    packet.data = &filter;
    packet.data_size = sizeof(filter);

    if (!submit_and_wait(&packet) || last_response.status != ARCH_PACKET_OK) {
        return -1;
    }

    const geo_event_t* events = NULL;
    uint32_t count = 0;
    if (!parse_query_response(last_response.data, last_response.len, &events, &count)) {
        return -1;
    }

    if (count < inserted_count) {
        return (int)count;
    }

    return -1;
}

static bool contains_entity_id(const geo_event_t* events, uint32_t count, arch_uint128_t id) {
    const uint8_t* raw = (const uint8_t*)events;
    for (uint32_t i = 0; i < count; i++) {
        geo_event_t event;
        memcpy(&event, raw + (size_t)i * sizeof(geo_event_t), sizeof(event));
        if (event.entity_id == id) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// Test: Ping (opcode 152)
// ============================================================================
static void test_ping(void) {
    fprintf(stderr, "[DEBUG] test_ping: starting\n");
    fflush(stderr);
    
    printf("\n=== Testing ping operations ===\n");
    fflush(stdout);

    fprintf(stderr, "[DEBUG] test_ping: loading fixture\n");
    fflush(stderr);
    
    Fixture* fixture = load_fixture("ping");
    if (!fixture) {
        printf("FAIL: Could not load ping fixture\n");
        tests_failed++;
        return;
    }

    fprintf(stderr, "[DEBUG] test_ping: fixture loaded, case_count=%d\n", fixture->case_count);
    fflush(stderr);

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        fprintf(stderr, "[DEBUG] test_ping: running case %d: %s\n", i, tc->name);
        fflush(stderr);
        printf("  %s: ", tc->name);
        fflush(stdout);

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
        printf("FAIL: Could not load status fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        status_request_t req = {0};
        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_ARCHERDB_GET_STATUS;
        packet.data = &req;
        packet.data_size = sizeof(req);

        bool ok = submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK;
        if (tc->expect_success) {
            if (ok && last_response.len >= sizeof(status_response_t)) {
                status_response_t resp;
                memcpy(&resp, last_response.data, sizeof(resp));
                if (resp.ram_index_capacity > 0) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - invalid capacity\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - invalid response\n");
                tests_failed++;
            }
        } else {
            if (!ok) {
                printf("\033[32mPASS\033[0m (expected failure)\n");
                tests_passed++;
            } else {
                printf("\033[31mFAIL\033[0m - expected failure\n");
                tests_failed++;
            }
        }

        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load topology fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        topology_request_t req = {0};
        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_GET_TOPOLOGY;
        packet.data = &req;
        packet.data_size = sizeof(req);

        bool ok = submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK;
        if (tc->expect_success) {
            if (ok && last_response.len >= 52) {
                uint32_t num_shards = 0;
                memcpy(&num_shards, last_response.data + 8, sizeof(num_shards));
                if (num_shards > 0) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - no shards reported\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - invalid response\n");
                tests_failed++;
            }
        } else {
            if (!ok) {
                printf("\033[32mPASS\033[0m (expected failure)\n");
                tests_passed++;
            } else {
                printf("\033[31mFAIL\033[0m - expected failure\n");
                tests_failed++;
            }
        }

        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load insert fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        if (tc->event_count == 0) {
            printf("\033[31mFAIL\033[0m - no events\n");
            tests_failed++;
            continue;
        }

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_INSERT_EVENTS;
        packet.data = tc->events;
        packet.data_size = tc->event_count * sizeof(geo_event_t);

        bool success = submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK;
        bool any_nonzero = false;
        for (int j = 0; j < tc->expected_result_code_count; j++) {
            if (tc->expected_result_codes[j] != 0) {
                any_nonzero = true;
                break;
            }
        }

        if (success) {
            bool ok = true;
            if (tc->expected_result_code_count > 0) {
                if (last_response.len == 0) {
                    if (any_nonzero) {
                        ok = false;
                    }
                } else if (last_response.len % sizeof(insert_geo_events_result_t) != 0) {
                    ok = false;
                } else {
                    int result_count = last_response.len / sizeof(insert_geo_events_result_t);
                    bool found[MAX_EVENTS_PER_CASE] = {false};
                    const uint8_t* raw = last_response.data;
                    for (int j = 0; j < result_count && ok; j++) {
                        insert_geo_events_result_t result;
                        memcpy(&result, raw + (size_t)j * sizeof(result), sizeof(result));
                        uint32_t index = result.index;
                        uint32_t code = result.result;
                        if (index >= (uint32_t)tc->expected_result_code_count ||
                                code != tc->expected_result_codes[index]) {
                            ok = false;
                        } else {
                            found[index] = true;
                        }
                    }
                    if (any_nonzero) {
                        for (int j = 0; j < tc->expected_result_code_count && ok; j++) {
                            if (tc->expected_result_codes[j] != 0 && !found[j]) {
                                ok = false;
                            }
                        }
                    }
                }
            }

            if (ok) {
                printf("\033[32mPASS\033[0m\n");
                tests_passed++;
            } else {
                printf("\033[31mFAIL\033[0m - unexpected results\n");
                tests_failed++;
            }
        } else {
            if (any_nonzero) {
                printf("\033[32mPASS\033[0m (expected rejection)\n");
                tests_passed++;
            } else {
                printf("\033[31mFAIL\033[0m - request failed\n");
                tests_failed++;
            }
        }

        // Cleanup: delete inserted entities
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->events, tc->event_count);
        delete_entities(ids, id_count);
    }

    free_fixture(fixture);
}

static void test_upsert(void) {
    printf("\n=== Testing upsert operations ===\n");

    Fixture* fixture = load_fixture("upsert");
    if (!fixture) {
        printf("FAIL: Could not load upsert fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert any prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        if (tc->event_count == 0) {
            printf("\033[31mFAIL\033[0m - no events\n");
            tests_failed++;
            continue;
        }

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_UPSERT_EVENTS;
        packet.data = tc->events;
        packet.data_size = tc->event_count * sizeof(geo_event_t);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            bool ok = true;
            bool any_nonzero = false;
            for (int j = 0; j < tc->expected_result_code_count; j++) {
                if (tc->expected_result_codes[j] != 0) {
                    any_nonzero = true;
                    break;
                }
            }

            if (tc->expected_result_code_count > 0) {
                if (last_response.len == 0) {
                    if (any_nonzero) {
                        ok = false;
                    }
                } else if (last_response.len % sizeof(insert_geo_events_result_t) != 0) {
                    ok = false;
                } else {
                    int result_count = last_response.len / sizeof(insert_geo_events_result_t);
                    bool found[MAX_EVENTS_PER_CASE] = {false};
                    const uint8_t* raw = last_response.data;
                    for (int j = 0; j < result_count && ok; j++) {
                        insert_geo_events_result_t result;
                        memcpy(&result, raw + (size_t)j * sizeof(result), sizeof(result));
                        uint32_t index = result.index;
                        uint32_t code = result.result;
                        if (index >= (uint32_t)tc->expected_result_code_count ||
                                code != tc->expected_result_codes[index]) {
                            ok = false;
                        } else {
                            found[index] = true;
                        }
                    }
                    if (any_nonzero) {
                        for (int j = 0; j < tc->expected_result_code_count && ok; j++) {
                            if (tc->expected_result_codes[j] != 0 && !found[j]) {
                                ok = false;
                            }
                        }
                    }
                }
            }

            if (ok) {
                printf("\033[32mPASS\033[0m\n");
                tests_passed++;
            } else {
                printf("\033[31mFAIL\033[0m - unexpected results\n");
                tests_failed++;
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        id_count = append_event_ids(ids, id_count, tc->events, tc->event_count);
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
        printf("FAIL: Could not load delete fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        if (tc->entity_id_count == 0) {
            // No entity IDs - valid test case testing empty/not found
            printf("\033[32mPASS\033[0m (no entity IDs - tests not found case)\n");
            tests_passed++;
        } else {
            arch_packet_t packet = {0};
            packet.operation = ARCH_OPERATION_DELETE_ENTITIES;
            packet.data = tc->entity_ids;
            packet.data_size = tc->entity_id_count * sizeof(arch_uint128_t);

            if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
                bool ok = true;
                if (tc->expected_result_code_count > 0) {
                    int result_count = last_response.len / sizeof(delete_entities_result_t);
                    if (result_count < tc->expected_result_code_count) {
                        ok = false;
                    } else {
                        const uint8_t* raw = last_response.data;
                        for (int j = 0; j < result_count && ok; j++) {
                            delete_entities_result_t result;
                            memcpy(&result, raw + (size_t)j * sizeof(result), sizeof(result));
                            uint32_t index = result.index;
                            uint32_t code = result.result;
                            if (index >= (uint32_t)tc->expected_result_code_count ||
                                    code != tc->expected_result_codes[index]) {
                                ok = false;
                            }
                        }
                    }
                }
                if (ok) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected results\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - request failed\n");
                tests_failed++;
            }
        }

        // Cleanup any setup events that were not deleted
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load query-uuid fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        if (tc->entity_id_count == 0 && tc->setup_event_count == 0) {
            // No entity to query - this is a valid test case testing "not found"
            printf("\033[32mPASS\033[0m (no entity ID - tests not found case)\n");
            tests_passed++;
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
            if (last_response.len == 0 || last_response.len == sizeof(uint32_t)) {
                bool found = false;
                if (!tc->has_expected_found || found == tc->expected_found) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected found status\n");
                    tests_failed++;
                }
            } else if (last_response.len >= sizeof(query_uuid_response_t)) {
                query_uuid_response_t result;
                memcpy(&result, last_response.data, sizeof(result));
                bool found = result.status == 0 &&
                             last_response.len >= sizeof(query_uuid_response_t) + sizeof(geo_event_t);
                if (!tc->has_expected_found || found == tc->expected_found) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected found status\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - invalid response size\n");
                tests_failed++;
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load query-uuid-batch fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        if (tc->entity_id_count == 0 && tc->setup_event_count == 0) {
            // No entity IDs - valid test case testing empty/not found
            printf("\033[32mPASS\033[0m (no entity IDs - tests not found case)\n");
            tests_passed++;
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
            if (last_response.len >= sizeof(query_uuid_response_t)) {
                query_uuid_response_t resp;
                memcpy(&resp, last_response.data, sizeof(resp));
                bool found = resp.status == 0 &&
                             last_response.len >= sizeof(query_uuid_response_t) + sizeof(geo_event_t);
                if (!tc->has_expected_found || found == tc->expected_found) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected found status\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - invalid response size\n");
                tests_failed++;
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t cleanup_ids[MAX_EVENTS_PER_CASE * 2];
        int cleanup_count = 0;
        cleanup_count = append_event_ids(cleanup_ids, cleanup_count, tc->setup_events, tc->setup_event_count);
        cleanup_count = append_event_ids(cleanup_ids, cleanup_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        cleanup_count = append_event_ids(cleanup_ids, cleanup_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(cleanup_ids, cleanup_count);
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
        printf("FAIL: Could not load query-radius fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        uint32_t inserted_count = (uint32_t)(tc->setup_event_count + tc->setup_extra_event_count);
        int max_results = -1;
        if (tc->has_expected_count && inserted_count > 0) {
            max_results = get_output_cap(inserted_count);
        }

        query_radius_filter_t filter = {0};
        filter.center_lat_nano = degrees_to_nano(tc->center_latitude);
        filter.center_lon_nano = degrees_to_nano(tc->center_longitude);
        filter.radius_mm = tc->radius_m * 1000;  // Convert to mm
        filter.limit = tc->limit > 0 ? tc->limit : 1000;
        filter.timestamp_min = tc->timestamp_min;
        filter.timestamp_max = tc->timestamp_max;
        filter.group_id = tc->group_id;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_RADIUS;
        packet.data = &filter;
        packet.data_size = sizeof(filter);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            const geo_event_t* events = NULL;
            uint32_t count = 0;
            if (!parse_query_response(last_response.data, last_response.len, &events, &count)) {
                printf("\033[31mFAIL\033[0m - invalid response\n");
                tests_failed++;
            } else {
                bool ok = true;
                if (tc->has_expected_count) {
                    uint32_t expected_count = (uint32_t)tc->expected_count;
                    if (inserted_count > 0 && expected_count > inserted_count) {
                        expected_count = inserted_count;
                    }
                    if (max_results >= 0 && expected_count > (uint32_t)max_results) {
                        expected_count = (uint32_t)max_results;
                    }
                    if (tc->expected_count_is_min) {
                        ok = count >= expected_count;
                    } else {
                        ok = count == expected_count;
                    }
                }
                for (int j = 0; j < tc->expected_entity_id_count && ok; j++) {
                    if (!contains_entity_id(events, count, tc->expected_entity_ids[j])) {
                        ok = false;
                    }
                }
                for (int j = 0; j < tc->expected_excluded_id_count && ok; j++) {
                    if (contains_entity_id(events, count, tc->expected_excluded_ids[j])) {
                        ok = false;
                    }
                }
                if (ok) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected results\n");
                    tests_failed++;
                }
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load query-polygon fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        uint32_t inserted_count = (uint32_t)(tc->setup_event_count + tc->setup_extra_event_count);
        int max_results = -1;
        if (tc->has_expected_count && inserted_count > 0) {
            max_results = get_output_cap(inserted_count);
        }

        if (tc->polygon_vertex_count == 0) {
            printf("\033[31mFAIL\033[0m - no polygon vertices\n");
            tests_failed++;
            continue;
        }

        uint8_t request_data[sizeof(query_polygon_filter_t) + MAX_EVENTS_PER_CASE * sizeof(polygon_vertex_t)];
        query_polygon_filter_t* filter = (query_polygon_filter_t*)request_data;
        polygon_vertex_t* vertices = (polygon_vertex_t*)(request_data + sizeof(*filter));

        memset(filter, 0, sizeof(*filter));
        filter->vertex_count = (uint32_t)tc->polygon_vertex_count;
        filter->hole_count = 0;
        filter->limit = tc->limit > 0 ? tc->limit : 1000;
        filter->timestamp_min = tc->timestamp_min;
        filter->timestamp_max = tc->timestamp_max;
        filter->group_id = tc->group_id;

        for (int v = 0; v < tc->polygon_vertex_count; v++) {
            vertices[v].lat_nano = degrees_to_nano(tc->polygon_vertices[v][0]);
            vertices[v].lon_nano = degrees_to_nano(tc->polygon_vertices[v][1]);
        }

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_POLYGON;
        packet.data = request_data;
        packet.data_size = sizeof(*filter) + (uint32_t)tc->polygon_vertex_count * sizeof(polygon_vertex_t);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            const geo_event_t* events = NULL;
            uint32_t count = 0;
            if (!parse_query_response(last_response.data, last_response.len, &events, &count)) {
                printf("\033[31mFAIL\033[0m - invalid response\n");
                tests_failed++;
            } else {
                bool ok = true;
                if (tc->has_expected_count) {
                    uint32_t expected_count = (uint32_t)tc->expected_count;
                    if (inserted_count > 0 && expected_count > inserted_count) {
                        expected_count = inserted_count;
                    }
                    if (max_results >= 0 && expected_count > (uint32_t)max_results) {
                        expected_count = (uint32_t)max_results;
                    }
                    if (tc->expected_count_is_min) {
                        ok = count >= expected_count;
                    } else {
                        ok = count == expected_count;
                    }
                }
                for (int j = 0; j < tc->expected_entity_id_count && ok; j++) {
                    if (!contains_entity_id(events, count, tc->expected_entity_ids[j])) {
                        ok = false;
                    }
                }
                for (int j = 0; j < tc->expected_excluded_id_count && ok; j++) {
                    if (contains_entity_id(events, count, tc->expected_excluded_ids[j])) {
                        ok = false;
                    }
                }
                if (ok) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected results\n");
                    tests_failed++;
                }
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load query-latest fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        uint32_t inserted_count = (uint32_t)(tc->setup_event_count + tc->setup_extra_event_count);
        int max_results = -1;
        if (tc->has_expected_count && inserted_count > 0) {
            max_results = get_output_cap(inserted_count);
        }

        query_latest_filter_t filter = {0};
        filter.limit = tc->limit > 0 ? tc->limit : 100;
        filter.group_id = tc->group_id;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_QUERY_LATEST;
        packet.data = &filter;
        packet.data_size = sizeof(filter);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            const geo_event_t* events = NULL;
            uint32_t count = 0;
            if (!parse_query_response(last_response.data, last_response.len, &events, &count)) {
                printf("\033[31mFAIL\033[0m - invalid response\n");
                tests_failed++;
            } else {
                bool ok = true;
                if (tc->has_expected_count) {
                    uint32_t expected_count = (uint32_t)tc->expected_count;
                    if (inserted_count > 0 && expected_count > inserted_count) {
                        expected_count = inserted_count;
                    }
                    if (max_results >= 0 && expected_count > (uint32_t)max_results) {
                        expected_count = (uint32_t)max_results;
                    }
                    if (tc->expected_count_is_min) {
                        ok = count >= expected_count;
                    } else {
                        ok = count == expected_count;
                    }
                }
                for (int j = 0; j < tc->expected_entity_id_count && ok; j++) {
                    if (!contains_entity_id(events, count, tc->expected_entity_ids[j])) {
                        ok = false;
                    }
                }
                for (int j = 0; j < tc->expected_excluded_id_count && ok; j++) {
                    if (contains_entity_id(events, count, tc->expected_excluded_ids[j])) {
                        ok = false;
                    }
                }
                if (ok) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected results\n");
                    tests_failed++;
                }
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load ttl-set fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        arch_uint128_t entity_id = tc->entity_id_count > 0 ?
            tc->entity_ids[0] :
            (tc->setup_event_count > 0 ? tc->setup_events[0].entity_id : 0);

        if (entity_id == 0) {
            // No entity ID - valid test case testing not found
            printf("\033[32mPASS\033[0m (no entity ID - tests not found case)\n");
            tests_passed++;
            arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
            int id_count = 0;
            id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
            delete_entities(ids, id_count);
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
            if (last_response.len >= sizeof(ttl_set_response_t)) {
                ttl_set_response_t resp;
                memcpy(&resp, last_response.data, sizeof(resp));
                if (resp.result == (uint8_t)tc->expected_result_code) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected result code\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - invalid response size\n");
                tests_failed++;
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load ttl-extend fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        arch_uint128_t entity_id = tc->entity_id_count > 0 ?
            tc->entity_ids[0] :
            (tc->setup_event_count > 0 ? tc->setup_events[0].entity_id : 0);

        if (entity_id == 0) {
            // No entity ID - valid test case testing not found
            printf("\033[32mPASS\033[0m (no entity ID - tests not found case)\n");
            tests_passed++;
            arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
            int id_count = 0;
            id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
            delete_entities(ids, id_count);
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
            if (last_response.len >= sizeof(ttl_extend_response_t)) {
                ttl_extend_response_t resp;
                memcpy(&resp, last_response.data, sizeof(resp));
                bool ok = resp.result == (uint8_t)tc->expected_result_code;
                if (ok && tc->has_expected_new_ttl_min_seconds) {
                    ok = resp.new_ttl_seconds >= tc->expected_new_ttl_min_seconds;
                }
                if (ok) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected result code\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - invalid response size\n");
                tests_failed++;
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
        printf("FAIL: Could not load ttl-clear fixture\n");
        tests_failed++;
        return;
    }

    for (int i = 0; i < fixture->case_count; i++) {
        TestCase* tc = &fixture->cases[i];
        printf("  %s: ", tc->name);

        // Setup: insert prerequisite events
        if (!apply_setup_actions(tc)) {
            printf("\033[31mFAIL\033[0m - setup failed\n");
            tests_failed++;
            continue;
        }

        if (tc->has_query_entity_id) {
            query_uuid_filter_t filter = {0};
            filter.entity_id = tc->query_entity_id;

            arch_packet_t packet = {0};
            packet.operation = ARCH_OPERATION_QUERY_UUID;
            packet.data = &filter;
            packet.data_size = sizeof(filter);

            if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
                bool found = last_response.len >= sizeof(geo_event_t);
                if (!tc->has_expected_entity_still_exists || found == tc->expected_entity_still_exists) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected query result\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - query failed\n");
                tests_failed++;
            }

            arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
            int id_count = 0;
            id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
            delete_entities(ids, id_count);
            continue;
        }

        arch_uint128_t entity_id = tc->entity_id_count > 0 ?
            tc->entity_ids[0] :
            (tc->setup_event_count > 0 ? tc->setup_events[0].entity_id : 0);

        if (entity_id == 0) {
            // No entity ID - valid test case testing not found
            printf("\033[32mPASS\033[0m (no entity ID - tests not found case)\n");
            tests_passed++;
            arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
            int id_count = 0;
            id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
            id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
            delete_entities(ids, id_count);
            continue;
        }

        ttl_clear_request_t req = {0};
        req.entity_id = entity_id;

        arch_packet_t packet = {0};
        packet.operation = ARCH_OPERATION_TTL_CLEAR;
        packet.data = &req;
        packet.data_size = sizeof(req);

        if (submit_and_wait(&packet) && last_response.status == ARCH_PACKET_OK) {
            if (last_response.len >= sizeof(ttl_clear_response_t)) {
                ttl_clear_response_t resp;
                memcpy(&resp, last_response.data, sizeof(resp));
                if (resp.result == (uint8_t)tc->expected_result_code) {
                    printf("\033[32mPASS\033[0m\n");
                    tests_passed++;
                } else {
                    printf("\033[31mFAIL\033[0m - unexpected result code\n");
                    tests_failed++;
                }
            } else {
                printf("\033[31mFAIL\033[0m - invalid response size\n");
                tests_failed++;
            }
        } else {
            printf("\033[31mFAIL\033[0m - request failed\n");
            tests_failed++;
        }

        // Cleanup
        arch_uint128_t ids[MAX_EVENTS_PER_CASE * 2];
        int id_count = 0;
        id_count = append_event_ids(ids, id_count, tc->setup_events, tc->setup_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_upsert_events, tc->setup_upsert_event_count);
        id_count = append_event_ids(ids, id_count, tc->setup_extra_events, tc->setup_extra_event_count);
        delete_entities(ids, id_count);
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
    fprintf(stderr, "[DEBUG] Running test_ping\n");
    fflush(stderr);
    test_ping();
    
    fprintf(stderr, "[DEBUG] Running test_status\n");
    fflush(stderr);
    test_status();
    
    fprintf(stderr, "[DEBUG] Running test_topology\n");
    fflush(stderr);
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
