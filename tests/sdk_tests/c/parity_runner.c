// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 ArcherDB Contributors

/**
 * @file parity_runner.c
 * @brief C SDK parity runner binary (JSON stdin -> JSON stdout)
 *
 * Usage:
 *   ARCHERDB_URL=http://127.0.0.1:7000 ./parity_runner <operation> < input.json
 */

#include <ctype.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "fixture_adapter.h"
#include "../../../src/clients/c/arch_client.h"

// Reuse simple JSON parser + parse_input() helpers already used by C SDK tests.
#include "fixture_adapter.c"

#define PR_RESPONSE_BUFFER_SIZE (4 * 1024 * 1024)

typedef struct {
    uint8_t data[PR_RESPONSE_BUFFER_SIZE];
    uint32_t len;
    bool received;
    ARCH_PACKET_STATUS status;
} parity_response_t;

static arch_client_t g_client;
static bool g_client_initialized = false;
static pthread_mutex_t g_completion_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_completion_cond = PTHREAD_COND_INITIALIZER;
static int g_pending_requests = 0;
static parity_response_t g_last_response;

static void pr_print_json_string(const char* value);
static void pr_print_errorf(const char* fmt, ...);
static bool pr_setup_client(void);
static void pr_teardown_client(void);
static bool pr_submit_and_wait(arch_packet_t* packet, int timeout_ms);
static bool pr_parse_input_json(const char* input_json, TestCase* tc);
static bool pr_decode_query_response(
    const uint8_t* data,
    uint32_t len,
    query_response_t* header_out,
    const geo_event_t** events_out,
    uint32_t* count_out
);
static bool pr_query_uuid_entity(arch_uint128_t entity_id, bool* found_out, geo_event_t* event_out);
static bool pr_decode_topology_response(const uint8_t* data, uint32_t len);
static void pr_decode_address(const uint8_t* src, size_t len, char* dst, size_t dst_len);

static void pr_u128_to_decimal(arch_uint128_t value, char* out, size_t out_len) {
    if (out_len == 0) return;
    if (value == 0) {
        out[0] = '0';
        if (out_len > 1) out[1] = '\0';
        return;
    }

    char digits[64];
    size_t count = 0;
    while (value != 0 && count < sizeof(digits)) {
        uint32_t digit = (uint32_t)(value % 10);
        digits[count++] = (char)('0' + digit);
        value /= 10;
    }

    size_t out_pos = 0;
    while (count > 0 && out_pos + 1 < out_len) {
        out[out_pos++] = digits[--count];
    }
    out[out_pos] = '\0';
}

static void pr_print_u128(arch_uint128_t value) {
    char buf[64];
    pr_u128_to_decimal(value, buf, sizeof(buf));
    fputs(buf, stdout);
}

static void pr_print_json_string(const char* value) {
    putchar('"');
    if (value) {
        for (const unsigned char* p = (const unsigned char*)value; *p != '\0'; ++p) {
            unsigned char c = *p;
            switch (c) {
                case '"':
                    fputs("\\\"", stdout);
                    break;
                case '\\':
                    fputs("\\\\", stdout);
                    break;
                case '\n':
                    fputs("\\n", stdout);
                    break;
                case '\r':
                    fputs("\\r", stdout);
                    break;
                case '\t':
                    fputs("\\t", stdout);
                    break;
                default:
                    if (c < 0x20) {
                        fprintf(stdout, "\\u%04x", (unsigned)c);
                    } else {
                        putchar((char)c);
                    }
                    break;
            }
        }
    }
    putchar('"');
}

static void pr_print_errorf(const char* fmt, ...) {
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    fputs("{\"error\":", stdout);
    pr_print_json_string(message);
    fputs("}\n", stdout);
}

static void pr_print_event_json(const geo_event_t* event) {
    fputs("{\"entity_id\":", stdout);
    pr_print_u128(event->entity_id);
    fprintf(
        stdout,
        ",\"latitude\":%.9f,\"longitude\":%.9f,\"timestamp\":%llu,\"correlation_id\":",
        nano_to_degrees(event->lat_nano),
        nano_to_degrees(event->lon_nano),
        (unsigned long long)event->timestamp
    );
    pr_print_u128(event->correlation_id);
    fputs(",\"user_data\":", stdout);
    pr_print_u128(event->user_data);
    fprintf(
        stdout,
        ",\"group_id\":%llu,\"ttl_seconds\":%u}",
        (unsigned long long)event->group_id,
        event->ttl_seconds
    );
}

static bool pr_is_http_prefix(const char* s, const char* prefix) {
    size_t prefix_len = strlen(prefix);
    return strncmp(s, prefix, prefix_len) == 0;
}

static void pr_parse_server_address(const char* raw_url, char* out, size_t out_len) {
    const char* fallback = "127.0.0.1:7000";
    if (out_len == 0) return;
    out[0] = '\0';

    if (!raw_url || raw_url[0] == '\0') {
        snprintf(out, out_len, "%s", fallback);
        return;
    }

    const char* start = raw_url;
    if (pr_is_http_prefix(start, "http://")) {
        start += 7;
    } else if (pr_is_http_prefix(start, "https://")) {
        start += 8;
    }

    size_t i = 0;
    while (start[i] != '\0' && start[i] != '/' && i + 1 < out_len) {
        out[i] = start[i];
        i++;
    }
    out[i] = '\0';

    if (i == 0) {
        snprintf(out, out_len, "%s", fallback);
    }
}

static void pr_on_complete(
    uintptr_t completion_ctx,
    arch_packet_t* packet,
    uint64_t timestamp,
    const uint8_t* data,
    uint32_t len
) {
    (void)completion_ctx;
    (void)timestamp;

    pthread_mutex_lock(&g_completion_mutex);
    g_last_response.status = (ARCH_PACKET_STATUS)packet->status;

    if (data && len > 0 && len <= sizeof(g_last_response.data)) {
        memcpy(g_last_response.data, data, len);
        g_last_response.len = len;
    } else {
        g_last_response.len = 0;
    }
    g_last_response.received = true;
    g_pending_requests--;

    pthread_cond_signal(&g_completion_cond);
    pthread_mutex_unlock(&g_completion_mutex);
}

static bool pr_wait_for_completion(int timeout_ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (timeout_ms % 1000) * 1000000;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&g_completion_mutex);
    while (g_pending_requests > 0) {
        int rc = pthread_cond_timedwait(&g_completion_cond, &g_completion_mutex, &ts);
        if (rc != 0) {
            pthread_mutex_unlock(&g_completion_mutex);
            return false;
        }
    }
    pthread_mutex_unlock(&g_completion_mutex);
    return true;
}

static bool pr_submit_and_wait(arch_packet_t* packet, int timeout_ms) {
    pthread_mutex_lock(&g_completion_mutex);
    g_last_response.received = false;
    g_last_response.len = 0;
    g_pending_requests++;
    pthread_mutex_unlock(&g_completion_mutex);

    ARCH_CLIENT_STATUS submit_status = arch_client_submit(&g_client, packet);
    if (submit_status != ARCH_CLIENT_OK) {
        pthread_mutex_lock(&g_completion_mutex);
        g_pending_requests--;
        pthread_mutex_unlock(&g_completion_mutex);
        return false;
    }

    return pr_wait_for_completion(timeout_ms);
}

static bool pr_setup_client(void) {
    const char* env_url = getenv("ARCHERDB_URL");
    char address[256];
    pr_parse_server_address(env_url, address, sizeof(address));

    uint8_t cluster_id[16] = {0};
    ARCH_INIT_STATUS init_status = arch_client_init(
        &g_client,
        cluster_id,
        address,
        (uint32_t)strlen(address),
        0,
        pr_on_complete
    );
    if (init_status != ARCH_INIT_SUCCESS) {
        return false;
    }
    g_client_initialized = true;

    // Wait for registration handshake.
    arch_init_parameters_t params;
    for (int retry = 0; retry < 60; retry++) {
        usleep(100000);  // 100ms
        if (arch_client_init_parameters(&g_client, &params) == ARCH_CLIENT_OK) {
            return true;
        }
    }
    return false;
}

static void pr_teardown_client(void) {
    if (g_client_initialized) {
        arch_client_deinit(&g_client);
        g_client_initialized = false;
    }
}

static bool pr_parse_input_json(const char* input_json, TestCase* tc) {
    memset(tc, 0, sizeof(*tc));
    JsonParser parser = {
        .json = input_json,
        .pos = 0,
        .len = strlen(input_json),
    };
    return parse_input(&parser, tc);
}

static bool pr_decode_query_response(
    const uint8_t* data,
    uint32_t len,
    query_response_t* header_out,
    const geo_event_t** events_out,
    uint32_t* count_out
) {
    memset(header_out, 0, sizeof(*header_out));
    *events_out = NULL;
    *count_out = 0;

    if (len == 0 || len == sizeof(uint32_t)) {
        return true;
    }
    if (len < sizeof(query_response_t)) {
        return false;
    }

    memcpy(header_out, data, sizeof(query_response_t));
    uint32_t expected = (uint32_t)(sizeof(query_response_t) + header_out->count * sizeof(geo_event_t));
    if (len < expected) {
        return false;
    }

    *count_out = header_out->count;
    *events_out = (const geo_event_t*)(data + sizeof(query_response_t));
    return true;
}

static bool pr_query_uuid_entity(arch_uint128_t entity_id, bool* found_out, geo_event_t* event_out) {
    *found_out = false;
    memset(event_out, 0, sizeof(*event_out));

    query_uuid_filter_t filter = {0};
    filter.entity_id = entity_id;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_QUERY_UUID;
    packet.data = &filter;
    packet.data_size = sizeof(filter);

    if (!pr_submit_and_wait(&packet, 30000)) {
        return false;
    }
    if (g_last_response.status != ARCH_PACKET_OK) {
        return false;
    }

    if (g_last_response.len >= sizeof(query_uuid_response_t) + sizeof(geo_event_t)) {
        query_uuid_response_t header;
        memcpy(&header, g_last_response.data, sizeof(header));
        if (header.status == 0) {
            memcpy(
                event_out,
                g_last_response.data + sizeof(query_uuid_response_t),
                sizeof(geo_event_t)
            );
            *found_out = true;
        }
        return true;
    }

    // Compatibility fallback: event-only payload.
    if (g_last_response.len >= sizeof(geo_event_t)) {
        memcpy(event_out, g_last_response.data, sizeof(geo_event_t));
        *found_out = true;
    }

    return true;
}

static void pr_decode_address(const uint8_t* src, size_t len, char* dst, size_t dst_len) {
    size_t copy_len = 0;
    if (dst_len == 0) return;
    while (copy_len < len && src[copy_len] != 0 && copy_len + 1 < dst_len) {
        dst[copy_len] = (char)src[copy_len];
        copy_len++;
    }
    dst[copy_len] = '\0';
}

static bool pr_decode_topology_response(const uint8_t* data, uint32_t len) {
    const uint32_t topology_header_size = 56;
    const uint32_t max_address_len = 64;
    const uint32_t max_replicas = 6;
    const uint32_t shard_info_size = 472;

    if (len < topology_header_size) {
        pr_print_errorf("invalid topology response");
        return false;
    }

    uint32_t num_shards = 0;
    memcpy(&num_shards, data + 8, sizeof(num_shards));

    fputs("{\"nodes\":[", stdout);
    bool first = true;
    for (uint32_t shard_index = 0; shard_index < num_shards; shard_index++) {
        uint32_t offset = topology_header_size + (shard_index * shard_info_size);
        if (offset + shard_info_size > len) {
            break;
        }

        uint32_t cursor = offset + 4;  // skip shard id
        char address[65];

        pr_decode_address(data + cursor, max_address_len, address, sizeof(address));
        cursor += max_address_len;
        if (address[0] != '\0') {
            if (!first) putchar(',');
            first = false;
            fputs("{\"address\":", stdout);
            pr_print_json_string(address);
            fputs(",\"role\":\"primary\"}", stdout);
        }

        for (uint32_t replica_index = 0; replica_index < max_replicas; replica_index++) {
            pr_decode_address(data + cursor, max_address_len, address, sizeof(address));
            cursor += max_address_len;
            if (address[0] == '\0') {
                continue;
            }
            if (!first) putchar(',');
            first = false;
            fputs("{\"address\":", stdout);
            pr_print_json_string(address);
            fputs(",\"role\":\"replica\"}", stdout);
        }
    }
    fputs("]}\n", stdout);
    return true;
}

static bool pr_run_ping(void) {
    ping_request_t req = {0};
    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_ARCHERDB_PING;
    packet.data = &req;
    packet.data_size = sizeof(req);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("ping request failed");
        return false;
    }

    fputs("{\"success\":true}\n", stdout);
    return true;
}

static bool pr_run_status(void) {
    status_request_t req = {0};
    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_ARCHERDB_GET_STATUS;
    packet.data = &req;
    packet.data_size = sizeof(req);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("status request failed");
        return false;
    }
    if (g_last_response.len < sizeof(status_response_t)) {
        pr_print_errorf("invalid status response");
        return false;
    }

    status_response_t resp;
    memcpy(&resp, g_last_response.data, sizeof(resp));
    fprintf(
        stdout,
        "{\"ram_index_count\":%llu,\"ram_index_capacity\":%llu,\"ram_index_load_pct\":%u,"
        "\"tombstone_count\":%llu,\"ttl_expirations\":%llu,\"deletion_count\":%llu}\n",
        (unsigned long long)resp.ram_index_count,
        (unsigned long long)resp.ram_index_capacity,
        resp.ram_index_load_pct,
        (unsigned long long)resp.tombstone_count,
        (unsigned long long)resp.ttl_expirations,
        (unsigned long long)resp.deletion_count
    );
    return true;
}

static bool pr_run_topology(void) {
    topology_request_t req = {0};
    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_GET_TOPOLOGY;
    packet.data = &req;
    packet.data_size = sizeof(req);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("topology request failed");
        return false;
    }

    return pr_decode_topology_response(g_last_response.data, g_last_response.len);
}

static bool pr_run_insert_or_upsert(const TestCase* tc, bool upsert) {
    arch_packet_t packet = {0};
    packet.operation = upsert ? ARCH_OPERATION_UPSERT_EVENTS : ARCH_OPERATION_INSERT_EVENTS;
    packet.data = (void*)tc->events;
    packet.data_size = (uint32_t)(tc->event_count * sizeof(geo_event_t));

    if (tc->event_count == 0) {
        fputs("{\"result_code\":0,\"count\":0,\"results\":[]}\n", stdout);
        return true;
    }

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("%s request failed", upsert ? "upsert" : "insert");
        return false;
    }
    if (g_last_response.len % sizeof(insert_geo_events_result_t) != 0) {
        pr_print_errorf("invalid insert response");
        return false;
    }

    size_t result_count = g_last_response.len / sizeof(insert_geo_events_result_t);
    const insert_geo_events_result_t* results =
        (const insert_geo_events_result_t*)g_last_response.data;

    fprintf(stdout, "{\"result_code\":0,\"count\":%d,\"results\":[", tc->event_count);
    bool first = true;
    for (size_t i = 0; i < result_count; i++) {
        if (results[i].result == 0) {
            continue;
        }
        if (!first) putchar(',');
        first = false;
        fprintf(
            stdout,
            "{\"index\":%u,\"code\":%u}",
            results[i].index,
            results[i].result
        );
    }
    fputs("]}\n", stdout);
    return true;
}

static bool pr_run_delete(const TestCase* tc) {
    if (tc->entity_id_count == 0) {
        fputs("{\"deleted_count\":0,\"not_found_count\":0}\n", stdout);
        return true;
    }

    for (int i = 0; i < tc->entity_id_count; i++) {
        if (tc->entity_ids[i] == 0) {
            pr_print_errorf("entity_id must not be zero");
            return false;
        }
    }

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_DELETE_ENTITIES;
    packet.data = (void*)tc->entity_ids;
    packet.data_size = (uint32_t)(tc->entity_id_count * sizeof(arch_uint128_t));

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("delete request failed");
        return false;
    }
    if (g_last_response.len % sizeof(delete_entities_result_t) != 0) {
        pr_print_errorf("invalid delete response");
        return false;
    }

    size_t result_count = g_last_response.len / sizeof(delete_entities_result_t);
    const delete_entities_result_t* results =
        (const delete_entities_result_t*)g_last_response.data;

    int not_found = 0;
    for (size_t i = 0; i < result_count; i++) {
        if (results[i].result == 3) {  // ENTITY_NOT_FOUND
            not_found++;
        }
    }

    int deleted = tc->entity_id_count - not_found;
    if (deleted < 0) deleted = 0;

    fprintf(
        stdout,
        "{\"deleted_count\":%d,\"not_found_count\":%d}\n",
        deleted,
        not_found
    );
    return true;
}

static bool pr_run_query_uuid(const TestCase* tc) {
    arch_uint128_t entity_id = tc->entity_id_count > 0 ? tc->entity_ids[0] : 0;
    bool found = false;
    geo_event_t event;
    if (!pr_query_uuid_entity(entity_id, &found, &event)) {
        pr_print_errorf("query-uuid request failed");
        return false;
    }

    fputs("{\"found\":", stdout);
    fputs(found ? "true" : "false", stdout);
    fputs(",\"event\":", stdout);
    if (found) {
        pr_print_event_json(&event);
    } else {
        fputs("null", stdout);
    }
    fputs("}\n", stdout);
    return true;
}

static bool pr_run_query_uuid_batch(const TestCase* tc) {
    fputs("{\"found_count\":", stdout);
    int found_count = 0;
    int not_found_count = 0;

    geo_event_t found_events[MAX_EVENTS_PER_CASE];
    arch_uint128_t not_found_ids[MAX_EVENTS_PER_CASE];
    int found_events_count = 0;

    for (int i = 0; i < tc->entity_id_count; i++) {
        bool found = false;
        geo_event_t event;
        if (!pr_query_uuid_entity(tc->entity_ids[i], &found, &event)) {
            pr_print_errorf("query-uuid-batch request failed");
            return false;
        }
        if (found) {
            if (found_events_count < MAX_EVENTS_PER_CASE) {
                found_events[found_events_count++] = event;
            }
            found_count++;
        } else {
            if (not_found_count < MAX_EVENTS_PER_CASE) {
                not_found_ids[not_found_count] = tc->entity_ids[i];
            }
            not_found_count++;
        }
    }

    fprintf(stdout, "%d,\"not_found_count\":%d,\"events\":[", found_count, not_found_count);
    for (int i = 0; i < found_events_count; i++) {
        if (i > 0) putchar(',');
        pr_print_event_json(&found_events[i]);
    }
    fputs("],\"not_found_entity_ids\":[", stdout);
    for (int i = 0; i < not_found_count && i < MAX_EVENTS_PER_CASE; i++) {
        if (i > 0) putchar(',');
        pr_print_u128(not_found_ids[i]);
    }
    fputs("]}\n", stdout);
    return true;
}

static bool pr_run_query_radius(const TestCase* tc) {
    uint64_t timestamp_min = tc->timestamp_min > 0 ? tc->timestamp_min / 1000000000ULL : 0;
    uint64_t timestamp_max = tc->timestamp_max > 0 ? tc->timestamp_max / 1000000000ULL : 0;

    query_radius_filter_t filter = {0};
    filter.center_lat_nano = degrees_to_nano(tc->center_latitude);
    filter.center_lon_nano = degrees_to_nano(tc->center_longitude);
    filter.radius_mm = tc->radius_m * 1000;
    filter.limit = tc->limit > 0 ? tc->limit : 1000;
    filter.timestamp_min = timestamp_min;
    filter.timestamp_max = timestamp_max;
    filter.group_id = tc->group_id;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_QUERY_RADIUS;
    packet.data = &filter;
    packet.data_size = sizeof(filter);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("query-radius request failed");
        return false;
    }

    query_response_t header;
    const geo_event_t* events = NULL;
    uint32_t count = 0;
    if (!pr_decode_query_response(g_last_response.data, g_last_response.len, &header, &events, &count)) {
        pr_print_errorf("invalid query-radius response");
        return false;
    }

    fprintf(
        stdout,
        "{\"count\":%u,\"has_more\":%s,\"events\":[",
        count,
        header.has_more ? "true" : "false"
    );
    const uint8_t* raw_events = (const uint8_t*)events;
    for (uint32_t i = 0; i < count; i++) {
        if (i > 0) putchar(',');
        geo_event_t event;
        memcpy(&event, raw_events + (size_t)i * sizeof(geo_event_t), sizeof(event));
        pr_print_event_json(&event);
    }
    fputs("]}\n", stdout);
    return true;
}

static bool pr_run_query_polygon(const TestCase* tc) {
    uint64_t timestamp_min = tc->timestamp_min > 0 ? tc->timestamp_min / 1000000000ULL : 0;
    uint64_t timestamp_max = tc->timestamp_max > 0 ? tc->timestamp_max / 1000000000ULL : 0;

    if (tc->polygon_vertex_count <= 0) {
        fputs("{\"count\":0,\"has_more\":false,\"events\":[]}\n", stdout);
        return true;
    }

    size_t req_size = sizeof(query_polygon_filter_t) +
        (size_t)tc->polygon_vertex_count * sizeof(polygon_vertex_t);
    uint8_t* request_data = (uint8_t*)malloc(req_size);
    if (!request_data) {
        pr_print_errorf("out of memory building polygon request");
        return false;
    }

    query_polygon_filter_t* filter = (query_polygon_filter_t*)request_data;
    polygon_vertex_t* vertices = (polygon_vertex_t*)(request_data + sizeof(*filter));
    memset(filter, 0, sizeof(*filter));
    filter->vertex_count = (uint32_t)tc->polygon_vertex_count;
    filter->hole_count = 0;
    filter->limit = tc->limit > 0 ? tc->limit : 1000;
    filter->timestamp_min = timestamp_min;
    filter->timestamp_max = timestamp_max;
    filter->group_id = tc->group_id;

    for (int i = 0; i < tc->polygon_vertex_count; i++) {
        vertices[i].lat_nano = degrees_to_nano(tc->polygon_vertices[i][0]);
        vertices[i].lon_nano = degrees_to_nano(tc->polygon_vertices[i][1]);
    }

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_QUERY_POLYGON;
    packet.data = request_data;
    packet.data_size = (uint32_t)req_size;

    bool ok = pr_submit_and_wait(&packet, 30000) && g_last_response.status == ARCH_PACKET_OK;
    free(request_data);

    if (!ok) {
        pr_print_errorf("query-polygon request failed");
        return false;
    }

    query_response_t header;
    const geo_event_t* events = NULL;
    uint32_t count = 0;
    if (!pr_decode_query_response(g_last_response.data, g_last_response.len, &header, &events, &count)) {
        pr_print_errorf("invalid query-polygon response");
        return false;
    }

    fprintf(
        stdout,
        "{\"count\":%u,\"has_more\":%s,\"events\":[",
        count,
        header.has_more ? "true" : "false"
    );
    const uint8_t* raw_events = (const uint8_t*)events;
    for (uint32_t i = 0; i < count; i++) {
        if (i > 0) putchar(',');
        geo_event_t event;
        memcpy(&event, raw_events + (size_t)i * sizeof(geo_event_t), sizeof(event));
        pr_print_event_json(&event);
    }
    fputs("]}\n", stdout);
    return true;
}

static bool pr_run_query_latest(const TestCase* tc) {
    query_latest_filter_t filter = {0};
    filter.limit = tc->limit > 0 ? tc->limit : 100;
    filter.group_id = tc->group_id;
    filter.cursor_timestamp = 0;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_QUERY_LATEST;
    packet.data = &filter;
    packet.data_size = sizeof(filter);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("query-latest request failed");
        return false;
    }

    query_response_t header;
    const geo_event_t* events = NULL;
    uint32_t count = 0;
    if (!pr_decode_query_response(g_last_response.data, g_last_response.len, &header, &events, &count)) {
        pr_print_errorf("invalid query-latest response");
        return false;
    }

    fprintf(
        stdout,
        "{\"count\":%u,\"has_more\":%s,\"events\":[",
        count,
        header.has_more ? "true" : "false"
    );
    const uint8_t* raw_events = (const uint8_t*)events;
    for (uint32_t i = 0; i < count; i++) {
        if (i > 0) putchar(',');
        geo_event_t event;
        memcpy(&event, raw_events + (size_t)i * sizeof(geo_event_t), sizeof(event));
        pr_print_event_json(&event);
    }
    fputs("]}\n", stdout);
    return true;
}

static bool pr_run_ttl_set(const TestCase* tc) {
    arch_uint128_t entity_id = tc->entity_id_count > 0 ? tc->entity_ids[0] : 0;
    ttl_set_request_t req = {0};
    req.entity_id = entity_id;
    req.ttl_seconds = tc->ttl_seconds;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_TTL_SET;
    packet.data = &req;
    packet.data_size = sizeof(req);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("ttl-set request failed");
        return false;
    }
    if (g_last_response.len < sizeof(ttl_set_response_t)) {
        pr_print_errorf("invalid ttl-set response");
        return false;
    }

    ttl_set_response_t resp;
    memcpy(&resp, g_last_response.data, sizeof(resp));
    fputs("{\"entity_id\":", stdout);
    pr_print_u128(entity_id);
    fprintf(
        stdout,
        ",\"previous_ttl_seconds\":%u,\"new_ttl_seconds\":%u,\"result_code\":%u}\n",
        resp.previous_ttl_seconds,
        resp.new_ttl_seconds,
        (unsigned)resp.result
    );
    return true;
}

static bool pr_run_ttl_extend(const TestCase* tc) {
    arch_uint128_t entity_id = tc->entity_id_count > 0 ? tc->entity_ids[0] : 0;
    ttl_extend_request_t req = {0};
    req.entity_id = entity_id;
    req.extend_by_seconds = tc->ttl_seconds;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_TTL_EXTEND;
    packet.data = &req;
    packet.data_size = sizeof(req);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("ttl-extend request failed");
        return false;
    }
    if (g_last_response.len < sizeof(ttl_extend_response_t)) {
        pr_print_errorf("invalid ttl-extend response");
        return false;
    }

    ttl_extend_response_t resp;
    memcpy(&resp, g_last_response.data, sizeof(resp));
    fputs("{\"entity_id\":", stdout);
    pr_print_u128(entity_id);
    fprintf(
        stdout,
        ",\"previous_ttl_seconds\":%u,\"new_ttl_seconds\":%u,\"result_code\":%u}\n",
        resp.previous_ttl_seconds,
        resp.new_ttl_seconds,
        (unsigned)resp.result
    );
    return true;
}

static bool pr_run_ttl_clear(const TestCase* tc) {
    if (tc->has_query_entity_id) {
        bool found = false;
        geo_event_t event;
        if (!pr_query_uuid_entity(tc->query_entity_id, &found, &event)) {
            pr_print_errorf("ttl-clear verification query failed");
            return false;
        }
        fprintf(stdout, "{\"entity_still_exists\":%s}\n", found ? "true" : "false");
        return true;
    }

    arch_uint128_t entity_id = tc->entity_id_count > 0 ? tc->entity_ids[0] : 0;
    ttl_clear_request_t req = {0};
    req.entity_id = entity_id;

    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_TTL_CLEAR;
    packet.data = &req;
    packet.data_size = sizeof(req);

    if (!pr_submit_and_wait(&packet, 30000) || g_last_response.status != ARCH_PACKET_OK) {
        pr_print_errorf("ttl-clear request failed");
        return false;
    }
    if (g_last_response.len < sizeof(ttl_clear_response_t)) {
        pr_print_errorf("invalid ttl-clear response");
        return false;
    }

    ttl_clear_response_t resp;
    memcpy(&resp, g_last_response.data, sizeof(resp));
    fputs("{\"entity_id\":", stdout);
    pr_print_u128(entity_id);
    fprintf(
        stdout,
        ",\"previous_ttl_seconds\":%u,\"result_code\":%u}\n",
        resp.previous_ttl_seconds,
        (unsigned)resp.result
    );
    return true;
}

static char* pr_read_stdin_all(void) {
    size_t cap = 4096;
    size_t len = 0;
    char* buffer = (char*)malloc(cap);
    if (!buffer) return NULL;

    while (1) {
        if (len + 2048 + 1 > cap) {
            size_t new_cap = cap * 2;
            char* grown = (char*)realloc(buffer, new_cap);
            if (!grown) {
                free(buffer);
                return NULL;
            }
            buffer = grown;
            cap = new_cap;
        }

        size_t n = fread(buffer + len, 1, 2048, stdin);
        len += n;
        if (n == 0) break;
    }

    buffer[len] = '\0';
    return buffer;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        pr_print_errorf("operation argument required");
        return 0;
    }

    char* input_json = pr_read_stdin_all();
    if (!input_json) {
        pr_print_errorf("failed to read stdin");
        return 0;
    }
    if (input_json[0] == '\0') {
        free(input_json);
        input_json = strdup("{}");
        if (!input_json) {
            pr_print_errorf("out of memory");
            return 0;
        }
    }

    TestCase tc;
    if (!pr_parse_input_json(input_json, &tc)) {
        pr_print_errorf("invalid input JSON");
        free(input_json);
        return 0;
    }

    if (!pr_setup_client()) {
        pr_print_errorf("failed to initialize C client");
        free(input_json);
        pr_teardown_client();
        return 0;
    }

    const char* operation = argv[1];
    bool ok = false;

    if (strcmp(operation, "ping") == 0) {
        ok = pr_run_ping();
    } else if (strcmp(operation, "status") == 0) {
        ok = pr_run_status();
    } else if (strcmp(operation, "topology") == 0) {
        ok = pr_run_topology();
    } else if (strcmp(operation, "insert") == 0) {
        ok = pr_run_insert_or_upsert(&tc, false);
    } else if (strcmp(operation, "upsert") == 0) {
        ok = pr_run_insert_or_upsert(&tc, true);
    } else if (strcmp(operation, "delete") == 0) {
        ok = pr_run_delete(&tc);
    } else if (strcmp(operation, "query-uuid") == 0) {
        ok = pr_run_query_uuid(&tc);
    } else if (strcmp(operation, "query-uuid-batch") == 0) {
        ok = pr_run_query_uuid_batch(&tc);
    } else if (strcmp(operation, "query-radius") == 0) {
        ok = pr_run_query_radius(&tc);
    } else if (strcmp(operation, "query-polygon") == 0) {
        ok = pr_run_query_polygon(&tc);
    } else if (strcmp(operation, "query-latest") == 0) {
        ok = pr_run_query_latest(&tc);
    } else if (strcmp(operation, "ttl-set") == 0) {
        ok = pr_run_ttl_set(&tc);
    } else if (strcmp(operation, "ttl-extend") == 0) {
        ok = pr_run_ttl_extend(&tc);
    } else if (strcmp(operation, "ttl-clear") == 0) {
        ok = pr_run_ttl_clear(&tc);
    } else {
        pr_print_errorf("Unknown operation: %s", operation);
    }

    if (!ok) {
        // Error JSON is already printed by the operation.
    }

    pr_teardown_client();
    free(input_json);
    return 0;
}
