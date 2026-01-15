// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

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

// Completion function, called by arch_client no notify that a request as completed.
void on_completion(
    uintptr_t context,
    arch_packet_t *packet,
    uint64_t timestamp,
    const uint8_t *data,
    uint32_t size
);

// Helper to convert degrees to nanodegrees
static int64_t degrees_to_nano(double degrees) {
    return (int64_t)(degrees * 1e9);
}

// Simple pseudo-random ID generator
static arch_uint128_t next_id = 1;
static arch_uint128_t generate_id(void) {
    return next_id++;
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
        // Checking for errors inserting the events:
        insert_geo_events_result_t *results = (insert_geo_events_result_t*)ctx.reply;
        int results_len = ctx.size / sizeof(insert_geo_events_result_t);
        printf("insert_events results:\n");
        for(int i=0;i<results_len;i++) {
            printf("index=%d, ret=%d\n", results[i].index, results[i].result);
        }
        exit(-1);
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
            // Checking for errors inserting the events:
            insert_geo_events_result_t *results = (insert_geo_events_result_t*)ctx.reply;
            int results_len = ctx.size / sizeof(insert_geo_events_result_t);
            printf("insert_events results:\n");
            for(int i=0;i<results_len;i++) {
                printf("index=%d, ret=%d\n", results[i].index, results[i].result);
            }
            exit(-1);
        }
    }

    printf("Geo events created successfully\n");
    printf("============================================\n");

    printf("%llu events per second\n", (MAX_BATCHES * EVENTS_PER_BATCH * 1000) / total_time_ms);
    printf("insert_events max p100 latency per %llu events = %ldms\n", EVENTS_PER_BATCH, max_latency_ms);
    printf("total %llu events in %ldms\n", MAX_BATCHES * EVENTS_PER_BATCH, total_time_ms);
    printf("\n");

    ////////////////////////////////////////////////////////////
    // Querying events by radius:                             //
    ////////////////////////////////////////////////////////////

    printf("Querying events by radius...\n");
    query_radius_filter_t radius_filter;
    memset(&radius_filter, 0, sizeof(radius_filter));

    radius_filter.center_lat_nano = degrees_to_nano(37.7749);
    radius_filter.center_lon_nano = degrees_to_nano(-122.4194);
    radius_filter.radius_mm = 5000000;  // 5 km radius
    radius_filter.limit = 100;
    radius_filter.group_id = 1;

    packet.operation = ARCH_OPERATION_QUERY_RADIUS;
    packet.data = &radius_filter;
    packet.data_size = sizeof(query_radius_filter_t);
    packet.user_data = &ctx;
    packet.status = ARCH_PACKET_OK;

    client_status = send_request(&client, &packet, &ctx);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to send the request\n");
        exit(-1);
    }

    if (packet.status != ARCH_PACKET_OK) {
        // Checking if the request failed:
        printf("Error calling query_radius (ret=%d)", packet.status);
        exit(-1);
    }

    if (ctx.size == 0) {
        printf("No events found in radius\n");
    } else {
        // Parse response header and events
        query_response_t *response = (query_response_t*)ctx.reply;
        printf("%d Event(s) found in radius query\n", response->count);
        printf("has_more=%d, partial_result=%d\n", response->has_more, response->partial_result);
        printf("============================================\n");

        geo_event_t *results = (geo_event_t*)(ctx.reply + sizeof(query_response_t));
        for(int i=0; i < response->count && i < 5; i++) {  // Print first 5
            printf("entity_id=%lu, lat=%.6f, lon=%.6f\n",
                (unsigned long)results[i].entity_id,
                results[i].lat_nano / 1e9,
                results[i].lon_nano / 1e9);
        }
        if (response->count > 5) {
            printf("... and %d more events\n", response->count - 5);
        }
    }

    // Cleanup:
    completion_context_destroy(&ctx);
    client_status = arch_client_deinit(&client);
    if (client_status != ARCH_CLIENT_OK) {
        printf("Failed to deinit the client\n");
        exit(-1);
    }

    printf("\nDone!\n");
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
