// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

/**
 * @file main.c
 * @brief ArcherDB C SDK Sample - Demonstrates all geospatial operations
 *
 * This sample demonstrates:
 * - Client initialization and cleanup
 * - Insert events (batch)
 * - Upsert events (insert or update)
 * - Query by UUID (get latest event for an entity)
 * - Query by radius with pagination
 * - Query by polygon
 * - Query latest events
 * - Delete entities
 * - Comprehensive error handling
 *
 * @par Build Instructions
 * From the archerdb root directory:
 *   ./zig/zig build clients:c:sample
 *
 * @par Usage
 * Set ARCHERDB_ADDRESS environment variable to server address (default: "3000")
 *   ARCHERDB_ADDRESS=127.0.0.1:3001 ./zig-out/bin/c_sample
 *
 * @par Coordinate Units
 * - lat_nano, lon_nano: nanodegrees (1e-9 degrees)
 * - altitude_mm: millimeters above sea level
 * - velocity_mms: millimeters per second
 * - accuracy_mm: location accuracy in millimeters
 * - heading_cdeg: centidegrees (0-35999, where 0=North, 9000=East)
 * - radius_mm: query radius in millimeters
 * - timestamp: server-assigned nanoseconds since epoch (set to 0 on insert)
 */

#define IS_POSIX __unix__ || __APPLE__ || !_WIN32

#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>

#if IS_POSIX
#include <pthread.h>
#include <time.h>
#elif _WIN32
#include <windows.h>
#endif

#include "../arch_client.h"

// config.message_size_max - @sizeOf(vsr.Header):
#define MAX_MESSAGE_SIZE (1024 * 1024) - 256

// Synchronization context between the callback and the main thread.
typedef struct completion_context {
    uint8_t reply[MAX_MESSAGE_SIZE];
    int size;
    bool completed;

    // In this example we synchronize using a condition variable:
    #if IS_POSIX
    pthread_mutex_t lock;
    pthread_cond_t cv;
    #elif _WIN32
    CRITICAL_SECTION lock;
    CONDITION_VARIABLE cv;
    #endif

} completion_context_t;

void completion_context_init(completion_context_t *ctx);
void completion_context_destroy(completion_context_t *ctx);

// Sends and blocks the current thread until the reply arrives.
ARCH_CLIENT_STATUS send_request(
    arch_client_t *client,
    arch_packet_t *packet,
    completion_context_t *ctx
);

// For benchmarking purposes.
long long get_time_ms(void);

// Completion function, called by arch_client to notify that a request has completed.
void on_completion(
    uintptr_t context,
    arch_packet_t *packet,
    uint64_t timestamp,
    const uint8_t *data,
    uint32_t size
);

/**
 * @brief Convert degrees to nanodegrees.
 * @param degrees Latitude or longitude in decimal degrees
 * @return Value in nanodegrees (1e-9 degrees)
 */
static int64_t degrees_to_nano(double degrees) {
    return (int64_t)(degrees * 1e9);
}

/**
 * @brief Convert nanodegrees to degrees.
 * @param nano Value in nanodegrees
 * @return Value in decimal degrees
 */
static double nano_to_degrees(int64_t nano) {
    return nano / 1e9;
}

// Simple pseudo-random ID generator
static arch_uint128_t next_id = 1;
static arch_uint128_t generate_id(void) {
    return next_id++;
}

/**
 * @brief Print a human-readable description of an INSERT_GEO_EVENT_RESULT error.
 * @param result The error code from insert_geo_events_result_t
 */
static void print_insert_error(uint32_t result) {
    switch (result) {
        case INSERT_GEO_EVENT_OK:
            printf("Success");
            break;
        case INSERT_GEO_EVENT_LINKED_EVENT_FAILED:
            printf("Linked event failed");
            break;
        case INSERT_GEO_EVENT_LINKED_EVENT_CHAIN_OPEN:
            printf("Linked event chain still open");
            break;
        case INSERT_GEO_EVENT_TIMESTAMP_MUST_BE_ZERO:
            printf("Timestamp must be zero (server assigns)");
            break;
        case INSERT_GEO_EVENT_RESERVED_FIELD:
            printf("Reserved field must be zero");
            break;
        case INSERT_GEO_EVENT_RESERVED_FLAG:
            printf("Reserved flag must not be set");
            break;
        case INSERT_GEO_EVENT_ID_MUST_NOT_BE_ZERO:
            printf("Event ID cannot be zero");
            break;
        case INSERT_GEO_EVENT_ENTITY_ID_MUST_NOT_BE_ZERO:
            printf("Entity ID cannot be zero");
            break;
        case INSERT_GEO_EVENT_INVALID_COORDINATES:
            printf("Invalid coordinates");
            break;
        case INSERT_GEO_EVENT_LAT_OUT_OF_RANGE:
            printf("Latitude out of range [-90, 90]");
            break;
        case INSERT_GEO_EVENT_LON_OUT_OF_RANGE:
            printf("Longitude out of range [-180, 180]");
            break;
        case INSERT_GEO_EVENT_EXISTS_WITH_DIFFERENT_ENTITY_ID:
            printf("Event ID exists with different entity");
            break;
        case INSERT_GEO_EVENT_EXISTS_WITH_DIFFERENT_COORDINATES:
            printf("Event exists with different coordinates");
            break;
        case INSERT_GEO_EVENT_EXISTS:
            printf("Event already exists");
            break;
        case INSERT_GEO_EVENT_HEADING_OUT_OF_RANGE:
            printf("Heading out of range [0, 35999]");
            break;
        case INSERT_GEO_EVENT_TTL_INVALID:
            printf("Invalid TTL value");
            break;
        case INSERT_GEO_EVENT_ENTITY_ID_MUST_NOT_BE_INT_MAX:
            printf("Entity ID cannot be INT_MAX");
            break;
        default:
            printf("Unknown error code %d", result);
    }
}

int main(int argc, char **argv) {
    printf("ArcherDB C Sample - Geospatial Operations\n");
    fflush(stdout);
    printf("Connecting...\n");
    fflush(stdout);
    arch_client_t client;

    const char *address = getenv("ARCHERDB_ADDRESS");
    if (address == NULL) address = "3000";

    uint8_t cluster_id[16];
    memset(&cluster_id, 0, 16);

    ARCH_INIT_STATUS init_status = arch_client_init(
        &client,              // Output client.
        cluster_id,           // Cluster ID.
        address,              // Cluster addresses.
        strlen(address),      //
        (uintptr_t)NULL,      // No need for a global context.
        &on_completion        // Completion callback.
    );

    if (init_status != ARCH_INIT_SUCCESS) {
        printf("Failed to initialize arch_client\n");
        exit(-1);
    }

    completion_context_t ctx;
    completion_context_init(&ctx);

    arch_packet_t packet;

    ////////////////////////////////////////////////////////////
    // Submitting a batch of geo events:                      //
    ////////////////////////////////////////////////////////////

    #define EVENTS_LEN 2
    #define EVENTS_SIZE sizeof(geo_event_t) * EVENTS_LEN
    geo_event_t events[EVENTS_LEN];

    // Zeroing the memory, so we don't have to initialize every field.
    memset(&events, 0, EVENTS_SIZE);

    // Event 1: San Francisco
    events[0].id = generate_id();
    events[0].entity_id = 1001;
    events[0].lat_nano = degrees_to_nano(37.7749);
    events[0].lon_nano = degrees_to_nano(-122.4194);
    events[0].group_id = 1;
    events[0].altitude_mm = 10000;  // 10 meters
    events[0].velocity_mms = 5000;  // 5 m/s
    events[0].accuracy_mm = 3000;   // 3 meters
    events[0].heading_cdeg = 9000;  // 90 degrees (East)

    // Event 2: Near San Francisco
    events[1].id = generate_id();
    events[1].entity_id = 1002;
    events[1].lat_nano = degrees_to_nano(37.7850);
    events[1].lon_nano = degrees_to_nano(-122.4094);
    events[1].group_id = 1;
    events[1].altitude_mm = 15000;  // 15 meters
    events[1].velocity_mms = 0;     // Stationary
    events[1].accuracy_mm = 5000;   // 5 meters
    events[1].heading_cdeg = 0;
    events[1].flags = GEO_EVENT_STATIONARY;

    packet.operation = ARCH_OPERATION_INSERT_EVENTS;  // The operation to be performed.
    packet.data = events;                             // The data to be sent.
    packet.data_size = EVENTS_SIZE;                   //
    packet.user_data = &ctx;                          // User-defined context.
    packet.status = ARCH_PACKET_OK;                   // Will be set when the reply arrives.

    printf("Inserting geo events...\n");

    ARCH_CLIENT_STATUS client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send the request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        // Checking if the request failed:
        printf("Error calling insert_events (ret=%d)\n", packet.status);
        exit(-1);
    }

    if (ctx.size != 0) {
        // Server returned explicit results for each event.
        // Check if any event had an actual error (ret != 0).
        insert_geo_events_result_t *results = (insert_geo_events_result_t*)ctx.reply;
        int results_len = ctx.size / sizeof(insert_geo_events_result_t);
        bool has_errors = false;
        for(int i=0;i<results_len;i++) {
            if (results[i].result != INSERT_GEO_EVENT_OK) {
                has_errors = true;
                break;
            }
        }

        if (has_errors) {
            printf("insert_events errors:\n");
            for(int i=0;i<results_len;i++) {
                if (results[i].result != INSERT_GEO_EVENT_OK) {
                    printf("index=%d, ret=%d: ", results[i].index, results[i].result);
                    print_insert_error(results[i].result);
                    printf("\n");
                }
            }
            exit(-1);
        }
        // All results were OK (ret=0), continue
    }

    printf("Geo events inserted successfully\n");

    ////////////////////////////////////////////////////////////
    // Submitting multiple batches of geo events:             //
    ////////////////////////////////////////////////////////////

    printf("Creating more events for performance test...\n");
    #define MAX_BATCHES 100
    #define EVENTS_PER_BATCH ((MAX_MESSAGE_SIZE) / sizeof(geo_event_t))
    #define BATCH_EVENTS_SIZE (sizeof(geo_event_t) * EVENTS_PER_BATCH)
    long max_latency_ms = 0;
    long total_time_ms = 0;
    for (int i=0; i< MAX_BATCHES;i++) {
        geo_event_t batch_events[EVENTS_PER_BATCH];

        // Zeroing the memory, so we don't have to initialize every field.
        memset(batch_events, 0, BATCH_EVENTS_SIZE);

        for (int j=0; j<EVENTS_PER_BATCH; j++) {
            batch_events[j].id = generate_id();
            batch_events[j].entity_id = 2000 + j;
            // Spread events around San Francisco
            batch_events[j].lat_nano = degrees_to_nano(37.7 + (j % 100) * 0.001);
            batch_events[j].lon_nano = degrees_to_nano(-122.4 + (j % 100) * 0.001);
            batch_events[j].group_id = 1;
            batch_events[j].accuracy_mm = 5000;
        }

        packet.operation = ARCH_OPERATION_INSERT_EVENTS;  // The operation to be performed.
        packet.data = batch_events;                       // The data to be sent.
        packet.data_size = BATCH_EVENTS_SIZE;             //
        packet.user_data = &ctx;                          // User-defined context.
        packet.status = ARCH_PACKET_OK;                   // Will be set when the reply arrives.

        long long now = get_time_ms();

        client_status = send_request(&client, &packet, &ctx);
        if (client_status != ARCH_CLIENT_OK) {
            printf("Failed to send the request\n");
            exit(-1);
        }


        long elapsed_ms = get_time_ms() - now;
        if (elapsed_ms > max_latency_ms) max_latency_ms = elapsed_ms;
        total_time_ms += elapsed_ms;

        if (packet.status != ARCH_PACKET_OK) {
            // Checking if the request failed:
            printf("Error calling insert_events (ret=%d)\n", packet.status);
            exit(-1);
        }

        if (ctx.size != 0) {
            // Server returned explicit results - check for actual errors.
            insert_geo_events_result_t *results = (insert_geo_events_result_t*)ctx.reply;
            int results_len = ctx.size / sizeof(insert_geo_events_result_t);
            bool has_errors = false;
            for(int j=0;j<results_len;j++) {
                if (results[j].result != INSERT_GEO_EVENT_OK) {
                    has_errors = true;
                    break;
                }
            }

            if (has_errors) {
                printf("insert_events errors in batch %d:\n", i);
                for(int j=0;j<results_len;j++) {
                    if (results[j].result != INSERT_GEO_EVENT_OK) {
                        printf("index=%d, ret=%d: ", results[j].index, results[j].result);
                        print_insert_error(results[j].result);
                        printf("\n");
                    }
                }
                exit(-1);
            }
            // All results were OK, continue
        }
    }

    printf("Geo events created successfully\n");
    printf("============================================\n");

    printf("%llu events per second\n", (MAX_BATCHES * EVENTS_PER_BATCH * 1000) / total_time_ms);
    printf("insert_events max p100 latency per %llu events = %ldms\n", EVENTS_PER_BATCH, max_latency_ms);
    printf("total %llu events in %ldms\n", MAX_BATCHES * EVENTS_PER_BATCH, total_time_ms);
    printf("\n");

    ////////////////////////////////////////////////////////////
    // Upsert events (insert or update):                      //
    ////////////////////////////////////////////////////////////

    printf("\n");
    printf("============================================\n");
    printf("Upserting events...\n");

    // Upsert allows updating existing events or inserting new ones
    // This is useful when you want to update an entity's location
    geo_event_t upsert_event;
    memset(&upsert_event, 0, sizeof(upsert_event));

    upsert_event.id = generate_id();
    upsert_event.entity_id = 1001;  // Same entity as before
    upsert_event.lat_nano = degrees_to_nano(37.7800);  // New location
    upsert_event.lon_nano = degrees_to_nano(-122.4100);
    upsert_event.group_id = 1;
    upsert_event.velocity_mms = 10000;  // 10 m/s - entity is moving
    upsert_event.heading_cdeg = 4500;   // 45 degrees (Northeast)

    packet.operation = ARCH_OPERATION_UPSERT_EVENTS;
    packet.data = &upsert_event;
    packet.data_size = sizeof(geo_event_t);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send upsert request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        printf("Error calling upsert_events (status=%d)\n", packet.status);
        exit(-1);
    }

    if (ctx.size != 0) {
        // Server returned explicit results - check for actual errors.
        insert_geo_events_result_t *results = (insert_geo_events_result_t*)ctx.reply;
        int results_len = ctx.size / sizeof(insert_geo_events_result_t);
        bool has_errors = false;
        for (int i = 0; i < results_len; i++) {
            if (results[i].result != INSERT_GEO_EVENT_OK) {
                has_errors = true;
                break;
            }
        }

        if (has_errors) {
            printf("Upsert validation errors:\n");
            for (int i = 0; i < results_len; i++) {
                if (results[i].result != INSERT_GEO_EVENT_OK) {
                    printf("  index=%d: ", results[i].index);
                    print_insert_error(results[i].result);
                    printf("\n");
                }
            }
            exit(-1);
        }
        // All results were OK, continue
    }

    printf("Event upserted successfully\n");

    ////////////////////////////////////////////////////////////
    // Query by UUID (get latest event for entity):           //
    ////////////////////////////////////////////////////////////

    printf("\n");
    printf("============================================\n");
    printf("Querying by UUID (entity_id=1001)...\n");

    // Query the latest event for a specific entity
    query_uuid_filter_t uuid_filter;
    memset(&uuid_filter, 0, sizeof(uuid_filter));
    uuid_filter.entity_id = 1001;

    packet.operation = ARCH_OPERATION_QUERY_UUID;
    packet.data = &uuid_filter;
    packet.data_size = sizeof(query_uuid_filter_t);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send query_uuid request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        printf("Error calling query_uuid (status=%d)\n", packet.status);
        exit(-1);
    }

    // Parse response: header followed by optional event
    if (ctx.size >= sizeof(query_uuid_response_t)) {
        query_uuid_response_t *uuid_response = (query_uuid_response_t*)ctx.reply;

        if (uuid_response->status == 0) {
            // Found the entity - event follows the header
            if (ctx.size >= sizeof(query_uuid_response_t) + sizeof(geo_event_t)) {
                geo_event_t *event_result = (geo_event_t*)(ctx.reply + sizeof(query_uuid_response_t));
                printf("Found entity 1001:\n");
                printf("  location: (%.6f, %.6f)\n",
                       nano_to_degrees(event_result->lat_nano),
                       nano_to_degrees(event_result->lon_nano));
                printf("  velocity: %d mm/s\n", event_result->velocity_mms);
                printf("  heading: %.2f degrees\n", event_result->heading_cdeg / 100.0);
            }
        } else {
            printf("Entity 1001 not found (status=%d)\n", uuid_response->status);
        }
    } else {
        printf("Invalid response size for query_uuid\n");
    }

    ////////////////////////////////////////////////////////////
    // Querying events by radius with pagination:             //
    ////////////////////////////////////////////////////////////

    printf("\n");
    printf("============================================\n");
    printf("Querying events by radius (5 km from San Francisco)...\n");

    query_radius_filter_t radius_filter;
    memset(&radius_filter, 0, sizeof(radius_filter));

    // Center point: San Francisco (37.7749, -122.4194)
    // Coordinates in nanodegrees (1e-9 degrees)
    radius_filter.center_lat_nano = degrees_to_nano(37.7749);
    radius_filter.center_lon_nano = degrees_to_nano(-122.4194);
    radius_filter.radius_mm = 5000000;  // 5 km = 5,000,000 mm
    radius_filter.limit = 10;           // Return up to 10 events
    radius_filter.group_id = 1;         // Filter by group_id
    // timestamp_min/max = 0 means no time filter

    packet.operation = ARCH_OPERATION_QUERY_RADIUS;
    packet.data = &radius_filter;
    packet.data_size = sizeof(query_radius_filter_t);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send query_radius request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        printf("Error calling query_radius (status=%d)\n", packet.status);
        exit(-1);
    }

    if (ctx.size >= sizeof(query_response_t)) {
        query_response_t *response = (query_response_t*)ctx.reply;
        printf("Found %d event(s) in radius query\n", response->count);
        printf("  has_more: %s (pagination needed: %s)\n",
               response->has_more ? "yes" : "no",
               response->has_more ? "use cursor" : "no");
        printf("  partial_result: %s\n", response->partial_result ? "yes (query timed out)" : "no");

        // Events follow the response header
        geo_event_t *results = (geo_event_t*)(ctx.reply + sizeof(query_response_t));
        int print_count = response->count < 5 ? response->count : 5;

        for (int i = 0; i < print_count; i++) {
            printf("  [%d] entity_id=%llu, lat=%.6f, lon=%.6f\n",
                   i,
                   (unsigned long long)results[i].entity_id,
                   nano_to_degrees(results[i].lat_nano),
                   nano_to_degrees(results[i].lon_nano));
        }
        if (response->count > 5) {
            printf("  ... and %d more events\n", response->count - 5);
        }
    } else {
        printf("No events found in radius\n");
    }

    ////////////////////////////////////////////////////////////
    // Querying events by polygon:                            //
    ////////////////////////////////////////////////////////////

    printf("\n");
    printf("============================================\n");
    printf("Querying events by polygon (San Francisco area)...\n");

    // Define a polygon covering downtown San Francisco
    // Vertices must be in counter-clockwise order for exterior ring
    polygon_vertex_t polygon_vertices[4];
    polygon_vertices[0].lat_nano = degrees_to_nano(37.70);
    polygon_vertices[0].lon_nano = degrees_to_nano(-122.50);  // SW corner
    polygon_vertices[1].lat_nano = degrees_to_nano(37.70);
    polygon_vertices[1].lon_nano = degrees_to_nano(-122.35);  // SE corner
    polygon_vertices[2].lat_nano = degrees_to_nano(37.85);
    polygon_vertices[2].lon_nano = degrees_to_nano(-122.35);  // NE corner
    polygon_vertices[3].lat_nano = degrees_to_nano(37.85);
    polygon_vertices[3].lon_nano = degrees_to_nano(-122.50);  // NW corner

    // Build request: filter header followed by vertices
    // For polygons with holes, hole_descriptor_t and hole vertices follow
    uint8_t polygon_request[sizeof(query_polygon_filter_t) + sizeof(polygon_vertices)];
    query_polygon_filter_t *polygon_filter = (query_polygon_filter_t*)polygon_request;
    memset(polygon_filter, 0, sizeof(query_polygon_filter_t));

    polygon_filter->vertex_count = 4;  // Number of exterior polygon vertices
    polygon_filter->hole_count = 0;    // No interior holes
    polygon_filter->limit = 100;
    polygon_filter->group_id = 1;

    // Copy vertices after the filter header
    memcpy(polygon_request + sizeof(query_polygon_filter_t),
           polygon_vertices,
           sizeof(polygon_vertices));

    packet.operation = ARCH_OPERATION_QUERY_POLYGON;
    packet.data = polygon_request;
    packet.data_size = sizeof(polygon_request);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send query_polygon request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        printf("Error calling query_polygon (status=%d)\n", packet.status);
        exit(-1);
    }

    if (ctx.size >= sizeof(query_response_t)) {
        query_response_t *response = (query_response_t*)ctx.reply;
        printf("Found %d event(s) in polygon query\n", response->count);

        geo_event_t *results = (geo_event_t*)(ctx.reply + sizeof(query_response_t));
        int print_count = response->count < 5 ? response->count : 5;

        for (int i = 0; i < print_count; i++) {
            printf("  [%d] entity_id=%llu at (%.6f, %.6f)\n",
                   i,
                   (unsigned long long)results[i].entity_id,
                   nano_to_degrees(results[i].lat_nano),
                   nano_to_degrees(results[i].lon_nano));
        }
        if (response->count > 5) {
            printf("  ... and %d more events\n", response->count - 5);
        }
    } else {
        printf("No events found in polygon\n");
    }

    ////////////////////////////////////////////////////////////
    // Querying latest events (global):                       //
    ////////////////////////////////////////////////////////////

    printf("\n");
    printf("============================================\n");
    printf("Querying latest events (most recent across all entities)...\n");

    query_latest_filter_t latest_filter;
    memset(&latest_filter, 0, sizeof(latest_filter));

    latest_filter.limit = 5;           // Return 5 most recent events
    latest_filter.group_id = 1;        // Filter by group
    latest_filter.cursor_timestamp = 0; // Start from most recent (no cursor)

    packet.operation = ARCH_OPERATION_QUERY_LATEST;
    packet.data = &latest_filter;
    packet.data_size = sizeof(query_latest_filter_t);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send query_latest request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        printf("Error calling query_latest (status=%d)\n", packet.status);
        exit(-1);
    }

    if (ctx.size >= sizeof(query_response_t)) {
        query_response_t *response = (query_response_t*)ctx.reply;
        printf("Found %d latest event(s)\n", response->count);

        geo_event_t *results = (geo_event_t*)(ctx.reply + sizeof(query_response_t));
        for (uint32_t i = 0; i < response->count; i++) {
            printf("  [%d] entity_id=%llu, timestamp=%llu\n",
                   i,
                   (unsigned long long)results[i].entity_id,
                   (unsigned long long)results[i].timestamp);
        }
    } else {
        printf("No events found\n");
    }

    ////////////////////////////////////////////////////////////
    // Deleting entities:                                     //
    ////////////////////////////////////////////////////////////

    printf("\n");
    printf("============================================\n");
    printf("Deleting entities (entity_id=1002)...\n");

    // Delete entities by their entity_id (not event_id)
    // This deletes ALL events for the specified entities
    arch_uint128_t entities_to_delete[1];
    entities_to_delete[0] = 1002;

    packet.operation = ARCH_OPERATION_DELETE_ENTITIES;
    packet.data = entities_to_delete;
    packet.data_size = sizeof(entities_to_delete);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send delete_entities request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        printf("Error calling delete_entities (status=%d)\n", packet.status);
        exit(-1);
    }

    // Response contains results for each entity
    if (ctx.size > 0) {
        delete_entities_result_t *results = (delete_entities_result_t*)ctx.reply;
        int results_len = ctx.size / sizeof(delete_entities_result_t);
        printf("Delete results:\n");
        for (int i = 0; i < results_len; i++) {
            printf("  index=%d, result=%d\n", results[i].index, results[i].result);
        }
    } else {
        printf("Entities deleted successfully (no errors)\n");
    }

    // Verify entity was deleted by querying it
    printf("Verifying entity 1002 was deleted...\n");
    uuid_filter.entity_id = 1002;

    packet.operation = ARCH_OPERATION_QUERY_UUID;
    packet.data = &uuid_filter;
    packet.data_size = sizeof(query_uuid_filter_t);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status == ARCH_CLIENT_OK && packet.status == ARCH_PACKET_OK) {
        if (ctx.size >= sizeof(query_uuid_response_t)) {
            query_uuid_response_t *uuid_response = (query_uuid_response_t*)ctx.reply;
            if (uuid_response->status != 0) {
                printf("  Confirmed: entity 1002 not found (deleted)\n");
            } else {
                printf("  Warning: entity 1002 still exists\n");
            }
        }
    }

    ////////////////////////////////////////////////////////////
    // Cleanup:                                               //
    ////////////////////////////////////////////////////////////

    printf("\n");
    printf("============================================\n");
    printf("Cleaning up...\n");

    completion_context_destroy(&ctx);
    client_status = arch_client_deinit(&client);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to deinit the client\n");
        exit(-1);
    }

    printf("Client closed successfully\n");
    printf("\nDone! All operations completed.\n");
    return 0;
}

#if IS_POSIX

void on_completion(
    uintptr_t context,
    arch_packet_t *packet,
    uint64_t timestamp,
    const uint8_t *data,
    uint32_t size
) {
    (void)timestamp; // Not used.

    // The user_data gives context to a request:
    completion_context_t *ctx = (completion_context_t*)packet->user_data;

    // Signaling the main thread we received the reply:
    pthread_mutex_lock(&ctx->lock);

    memcpy (ctx->reply, data, size);
    ctx->size = size;
    ctx->completed = true;

    pthread_cond_signal(&ctx->cv);
    pthread_mutex_unlock(&ctx->lock);
}

ARCH_CLIENT_STATUS send_request(
    arch_client_t *client,
    arch_packet_t *packet,
    completion_context_t *ctx
) {
    // Locks the mutex:
    if (pthread_mutex_lock(&ctx->lock) != 0) {
        printf("Failed to lock mutex\n");
        exit(-1);
    }

    // Submits the request asynchronously:
    ctx->completed = false;
    ARCH_CLIENT_STATUS client_status = arch_client_submit(client, packet);
    if (client_status == ARCH_CLIENT_OK) {
        // Uses a condvar to sync this thread with the callback:
        while (!ctx->completed) {
            if (pthread_cond_wait(&ctx->cv, &ctx->lock) != 0) {
                printf("Failed to wait condvar\n");
                exit(-1);
            }
        }
    }

    if (pthread_mutex_unlock(&ctx->lock) != 0) {
        printf("Failed to unlock mutex\n");
        exit(-1);
    }

    return client_status;
}

void completion_context_init(completion_context_t *ctx) {
    if (pthread_mutex_init(&ctx->lock, NULL) != 0) {
        printf("Failed to initialize mutex\n");
        exit(-1);
    }

    if (pthread_cond_init(&ctx->cv, NULL) != 0) {
        printf("Failed to initialize condition var\n");
        exit(-1);
    }
}

void completion_context_destroy(completion_context_t *ctx) {
    pthread_cond_destroy(&ctx->cv);
    pthread_mutex_destroy(&ctx->lock);
}

long long get_time_ms(void) {
    struct timespec  ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        printf("Failed to call clock_gettime\n");
        exit(-1);
    }
    return (ts.tv_sec*1000)+(ts.tv_nsec/1000000);
}

#elif _WIN32

void on_completion(
    uintptr_t context,
    arch_packet_t *packet,
    uint64_t timestamp,
    const uint8_t *data,
    uint32_t size
) {
    (void)timestamp; // Not used.
    // The user_data gives context to a request:
    completion_context_t *ctx = (completion_context_t*)packet->user_data;

    // Signaling the main thread we received the reply:
    EnterCriticalSection(&ctx->lock);

    memcpy (ctx->reply, data, size);
    ctx->size = size;
    ctx->completed = true;

    WakeConditionVariable(&ctx->cv);
    LeaveCriticalSection(&ctx->lock);
}

ARCH_CLIENT_STATUS send_request(
    arch_client_t *client,
    arch_packet_t *packet,
    completion_context_t *ctx
) {
    // Locks the mutex:
    EnterCriticalSection(&ctx->lock);

    // Submits the request asynchronously:
    ctx->completed = false;
    ARCH_CLIENT_STATUS client_status = arch_client_submit(client, packet);
    if (client_status == ARCH_CLIENT_OK) {
        // Uses a condvar to sync this thread with the callback:
        while (!ctx->completed) {
            SleepConditionVariableCS (&ctx->cv, &ctx->lock, INFINITE);
        }
    }

    LeaveCriticalSection(&ctx->lock);
    return client_status;
}

void completion_context_init(completion_context_t *ctx) {
    InitializeCriticalSection(&ctx->lock);
    InitializeConditionVariable(&ctx->cv);
}

void completion_context_destroy(completion_context_t *ctx) {
    DeleteCriticalSection(&ctx->lock);
}

long long get_time_ms(void) {
    return GetTickCount64();
}

#endif
