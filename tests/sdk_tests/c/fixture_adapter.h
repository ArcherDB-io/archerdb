// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

/**
 * @file fixture_adapter.h
 * @brief Test fixture loading utilities for C SDK tests
 *
 * This header provides functions to load JSON test fixtures from Phase 11
 * and convert them to C SDK data structures for testing all 14 operations.
 */

#ifndef FIXTURE_ADAPTER_H
#define FIXTURE_ADAPTER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "../../../src/clients/c/arch_client.h"

/**
 * @brief Maximum number of test cases per fixture
 */
#define MAX_TEST_CASES 32

/**
 * @brief Maximum number of events per test case
 */
#define MAX_EVENTS_PER_CASE 128

/**
 * @brief Maximum string length for names/descriptions
 */
#define MAX_STRING_LEN 256

/**
 * @brief Maximum number of tags per test case
 */
#define MAX_TAGS 8

/**
 * @brief A single test case from a fixture file
 */
typedef struct {
    char name[MAX_STRING_LEN];
    char description[MAX_STRING_LEN];
    char tags[MAX_TAGS][32];
    int tag_count;

    // Input data (depends on operation type)
    geo_event_t events[MAX_EVENTS_PER_CASE];
    int event_count;

    // Entity IDs for delete/query operations
    arch_uint128_t entity_ids[MAX_EVENTS_PER_CASE];
    int entity_id_count;

    // Query parameters
    double center_latitude;
    double center_longitude;
    uint32_t radius_m;
    uint32_t limit;
    uint64_t group_id;

    // TTL parameters
    uint32_t ttl_seconds;

    // Expected output
    int expected_result_code;
    bool expect_success;
    int expected_count;
    arch_uint128_t expected_entity_ids[MAX_EVENTS_PER_CASE];
    int expected_entity_id_count;

    // Setup data (events to insert before test)
    geo_event_t setup_events[MAX_EVENTS_PER_CASE];
    int setup_event_count;
} TestCase;

/**
 * @brief A fixture file containing multiple test cases for an operation
 */
typedef struct {
    char operation[64];
    char version[16];
    char description[MAX_STRING_LEN];
    TestCase cases[MAX_TEST_CASES];
    int case_count;
} Fixture;

/**
 * @brief Load a fixture from a JSON file
 *
 * @param operation The operation name (e.g., "insert", "query-radius")
 * @return Pointer to allocated Fixture, or NULL on error
 *
 * The fixture is loaded from:
 *   test_infrastructure/fixtures/v1/{operation}.json
 */
Fixture* load_fixture(const char* operation);

/**
 * @brief Free a previously loaded fixture
 *
 * @param fixture Pointer to fixture to free
 */
void free_fixture(Fixture* fixture);

/**
 * @brief Convert degrees to nanodegrees for coordinates
 *
 * @param degrees Coordinate in degrees
 * @return Coordinate in nanodegrees (1e-9 degrees)
 */
int64_t degrees_to_nano(double degrees);

/**
 * @brief Convert nanodegrees to degrees for display
 *
 * @param nano Coordinate in nanodegrees
 * @return Coordinate in degrees
 */
double nano_to_degrees(int64_t nano);

/**
 * @brief Generate a unique entity ID for testing
 *
 * Uses a hash of the test name combined with a counter to generate
 * unique entity IDs that are reproducible across test runs.
 *
 * @param test_name Name of the test case
 * @return Unique 128-bit entity ID
 */
arch_uint128_t generate_entity_id(const char* test_name);

/**
 * @brief Print a diff between expected and actual values
 *
 * Outputs colored diff showing mismatches between expected and actual
 * results for debugging test failures.
 *
 * @param expected Expected value as string
 * @param actual Actual value as string
 */
void print_diff(const char* expected, const char* actual);

/**
 * @brief Print test case details on failure
 *
 * @param tc Test case that failed
 * @param reason Reason for failure
 */
void print_test_failure(const TestCase* tc, const char* reason);

/**
 * @brief Check if a tag is in the test case's tag list
 *
 * @param tc Test case to check
 * @param tag Tag to look for (e.g., "smoke", "pr", "nightly")
 * @return true if tag is present, false otherwise
 */
bool has_tag(const TestCase* tc, const char* tag);

#endif // FIXTURE_ADAPTER_H
