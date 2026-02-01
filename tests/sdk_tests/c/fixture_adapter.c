// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

/**
 * @file fixture_adapter.c
 * @brief Implementation of test fixture loading utilities
 *
 * This file provides functions to load JSON test fixtures from Phase 11
 * and convert them to C SDK data structures for testing all 14 operations.
 *
 * Uses a simple JSON parser since the fixture format is well-defined.
 */

#include "fixture_adapter.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include <time.h>

// Simple JSON parsing state
typedef struct {
    const char* json;
    size_t pos;
    size_t len;
} JsonParser;

// Forward declarations for JSON parsing
static void skip_whitespace(JsonParser* p);
static bool parse_string(JsonParser* p, char* out, size_t max_len);
static bool parse_number(JsonParser* p, double* out);
static bool parse_int(JsonParser* p, int64_t* out);
static bool expect_char(JsonParser* p, char c);
static bool parse_bool(JsonParser* p, bool* out);
static bool skip_value(JsonParser* p);

// Hash function for entity ID generation
static uint64_t hash_string(const char* str) {
    uint64_t hash = 5381;
    int c;
    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c;
    }
    return hash;
}

// Counter for unique IDs
static uint64_t entity_id_counter = 0;

int64_t degrees_to_nano(double degrees) {
    return (int64_t)round(degrees * 1000000000.0);
}

double nano_to_degrees(int64_t nano) {
    return (double)nano / 1000000000.0;
}

arch_uint128_t generate_entity_id(const char* test_name) {
    uint64_t hash = hash_string(test_name);
    uint64_t counter = ++entity_id_counter;
    // Combine hash and counter to create a unique 128-bit ID
    return ((arch_uint128_t)hash << 64) | counter;
}

void print_diff(const char* expected, const char* actual) {
    // Use ANSI colors for diff output
    printf("\033[31m- Expected:\033[0m %s\n", expected);
    printf("\033[32m+ Actual:\033[0m   %s\n", actual);
}

void print_test_failure(const TestCase* tc, const char* reason) {
    printf("\033[31mFAIL:\033[0m %s\n", tc->name);
    printf("  Description: %s\n", tc->description);
    printf("  Reason: %s\n", reason);
}

bool has_tag(const TestCase* tc, const char* tag) {
    for (int i = 0; i < tc->tag_count; i++) {
        if (strcmp(tc->tags[i], tag) == 0) {
            return true;
        }
    }
    return false;
}

// JSON parsing helper functions

static void skip_whitespace(JsonParser* p) {
    while (p->pos < p->len && isspace((unsigned char)p->json[p->pos])) {
        p->pos++;
    }
}

static bool expect_char(JsonParser* p, char c) {
    skip_whitespace(p);
    if (p->pos < p->len && p->json[p->pos] == c) {
        p->pos++;
        return true;
    }
    return false;
}

static bool parse_string(JsonParser* p, char* out, size_t max_len) {
    skip_whitespace(p);
    if (p->pos >= p->len || p->json[p->pos] != '"') {
        return false;
    }
    p->pos++;  // skip opening quote

    size_t out_pos = 0;
    while (p->pos < p->len && p->json[p->pos] != '"') {
        if (p->json[p->pos] == '\\' && p->pos + 1 < p->len) {
            p->pos++;  // skip backslash
            char escaped = p->json[p->pos];
            switch (escaped) {
                case 'n': escaped = '\n'; break;
                case 't': escaped = '\t'; break;
                case 'r': escaped = '\r'; break;
                case '"': escaped = '"'; break;
                case '\\': escaped = '\\'; break;
                default: break;
            }
            if (out_pos < max_len - 1) {
                out[out_pos++] = escaped;
            }
        } else {
            if (out_pos < max_len - 1) {
                out[out_pos++] = p->json[p->pos];
            }
        }
        p->pos++;
    }
    out[out_pos] = '\0';

    if (p->pos < p->len && p->json[p->pos] == '"') {
        p->pos++;  // skip closing quote
        return true;
    }
    return false;
}

static bool parse_number(JsonParser* p, double* out) {
    skip_whitespace(p);
    char* end;
    *out = strtod(p->json + p->pos, &end);
    if (end == p->json + p->pos) {
        return false;
    }
    p->pos = end - p->json;
    return true;
}

static bool parse_int(JsonParser* p, int64_t* out) {
    skip_whitespace(p);
    char* end;
    *out = strtoll(p->json + p->pos, &end, 10);
    if (end == p->json + p->pos) {
        return false;
    }
    p->pos = end - p->json;
    return true;
}

static bool parse_bool(JsonParser* p, bool* out) {
    skip_whitespace(p);
    if (strncmp(p->json + p->pos, "true", 4) == 0) {
        *out = true;
        p->pos += 4;
        return true;
    }
    if (strncmp(p->json + p->pos, "false", 5) == 0) {
        *out = false;
        p->pos += 5;
        return true;
    }
    return false;
}

static bool skip_value(JsonParser* p) {
    skip_whitespace(p);
    if (p->pos >= p->len) return false;

    char c = p->json[p->pos];

    // String
    if (c == '"') {
        char buf[1024];
        return parse_string(p, buf, sizeof(buf));
    }

    // Number
    if (c == '-' || isdigit((unsigned char)c)) {
        double d;
        return parse_number(p, &d);
    }

    // Boolean or null
    if (strncmp(p->json + p->pos, "true", 4) == 0) {
        p->pos += 4;
        return true;
    }
    if (strncmp(p->json + p->pos, "false", 5) == 0) {
        p->pos += 5;
        return true;
    }
    if (strncmp(p->json + p->pos, "null", 4) == 0) {
        p->pos += 4;
        return true;
    }

    // Array
    if (c == '[') {
        p->pos++;
        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == ']') {
            p->pos++;
            return true;
        }
        while (true) {
            if (!skip_value(p)) return false;
            skip_whitespace(p);
            if (p->pos >= p->len) return false;
            if (p->json[p->pos] == ']') {
                p->pos++;
                return true;
            }
            if (p->json[p->pos] != ',') return false;
            p->pos++;
        }
    }

    // Object
    if (c == '{') {
        p->pos++;
        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == '}') {
            p->pos++;
            return true;
        }
        while (true) {
            char key[256];
            if (!parse_string(p, key, sizeof(key))) return false;
            if (!expect_char(p, ':')) return false;
            if (!skip_value(p)) return false;
            skip_whitespace(p);
            if (p->pos >= p->len) return false;
            if (p->json[p->pos] == '}') {
                p->pos++;
                return true;
            }
            if (p->json[p->pos] != ',') return false;
            p->pos++;
        }
    }

    return false;
}

// Parse a single event from JSON
static bool parse_event(JsonParser* p, geo_event_t* event) {
    memset(event, 0, sizeof(*event));

    if (!expect_char(p, '{')) return false;

    while (true) {
        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == '}') {
            p->pos++;
            return true;
        }

        char key[64];
        if (!parse_string(p, key, sizeof(key))) return false;
        if (!expect_char(p, ':')) return false;

        if (strcmp(key, "entity_id") == 0) {
            int64_t id;
            if (!parse_int(p, &id)) return false;
            event->entity_id = (arch_uint128_t)id;
            event->id = event->entity_id;  // Use same ID for both
        } else if (strcmp(key, "latitude") == 0) {
            double lat;
            if (!parse_number(p, &lat)) return false;
            event->lat_nano = degrees_to_nano(lat);
        } else if (strcmp(key, "longitude") == 0) {
            double lon;
            if (!parse_number(p, &lon)) return false;
            event->lon_nano = degrees_to_nano(lon);
        } else if (strcmp(key, "group_id") == 0) {
            int64_t gid;
            if (!parse_int(p, &gid)) return false;
            event->group_id = (uint64_t)gid;
        } else if (strcmp(key, "correlation_id") == 0) {
            int64_t cid;
            if (!parse_int(p, &cid)) return false;
            event->correlation_id = (arch_uint128_t)cid;
        } else if (strcmp(key, "user_data") == 0) {
            int64_t ud;
            if (!parse_int(p, &ud)) return false;
            event->user_data = (arch_uint128_t)ud;
        } else if (strcmp(key, "altitude_m") == 0) {
            double alt;
            if (!parse_number(p, &alt)) return false;
            event->altitude_mm = (int32_t)(alt * 1000.0);
        } else if (strcmp(key, "velocity_mps") == 0) {
            double vel;
            if (!parse_number(p, &vel)) return false;
            event->velocity_mms = (uint32_t)(vel * 1000.0);
        } else if (strcmp(key, "ttl_seconds") == 0) {
            int64_t ttl;
            if (!parse_int(p, &ttl)) return false;
            event->ttl_seconds = (uint32_t)ttl;
        } else if (strcmp(key, "accuracy_m") == 0) {
            double acc;
            if (!parse_number(p, &acc)) return false;
            event->accuracy_mm = (uint32_t)(acc * 1000.0);
        } else if (strcmp(key, "heading") == 0) {
            double hdg;
            if (!parse_number(p, &hdg)) return false;
            event->heading_cdeg = (uint16_t)(hdg * 100.0);
        } else if (strcmp(key, "flags") == 0) {
            int64_t flags;
            if (!parse_int(p, &flags)) return false;
            event->flags = (uint16_t)flags;
        } else {
            if (!skip_value(p)) return false;
        }

        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == ',') {
            p->pos++;
        }
    }
}

// Parse events array
static bool parse_events_array(JsonParser* p, geo_event_t* events, int* count) {
    *count = 0;
    if (!expect_char(p, '[')) return false;

    skip_whitespace(p);
    if (p->pos < p->len && p->json[p->pos] == ']') {
        p->pos++;
        return true;
    }

    while (*count < MAX_EVENTS_PER_CASE) {
        if (!parse_event(p, &events[*count])) return false;
        (*count)++;

        skip_whitespace(p);
        if (p->pos >= p->len) return false;
        if (p->json[p->pos] == ']') {
            p->pos++;
            return true;
        }
        if (p->json[p->pos] != ',') return false;
        p->pos++;
    }
    return true;
}

// Parse entity_ids array
static bool parse_entity_ids_array(JsonParser* p, arch_uint128_t* ids, int* count) {
    *count = 0;
    if (!expect_char(p, '[')) return false;

    skip_whitespace(p);
    if (p->pos < p->len && p->json[p->pos] == ']') {
        p->pos++;
        return true;
    }

    while (*count < MAX_EVENTS_PER_CASE) {
        int64_t id;
        if (!parse_int(p, &id)) return false;
        ids[*count] = (arch_uint128_t)id;
        (*count)++;

        skip_whitespace(p);
        if (p->pos >= p->len) return false;
        if (p->json[p->pos] == ']') {
            p->pos++;
            return true;
        }
        if (p->json[p->pos] != ',') return false;
        p->pos++;
    }
    return true;
}

// Parse tags array
static bool parse_tags_array(JsonParser* p, char tags[][32], int* count) {
    *count = 0;
    if (!expect_char(p, '[')) return false;

    skip_whitespace(p);
    if (p->pos < p->len && p->json[p->pos] == ']') {
        p->pos++;
        return true;
    }

    while (*count < MAX_TAGS) {
        if (!parse_string(p, tags[*count], 32)) return false;
        (*count)++;

        skip_whitespace(p);
        if (p->pos >= p->len) return false;
        if (p->json[p->pos] == ']') {
            p->pos++;
            return true;
        }
        if (p->json[p->pos] != ',') return false;
        p->pos++;
    }
    return true;
}

// Parse setup section (insert_first)
static bool parse_setup(JsonParser* p, TestCase* tc) {
    if (!expect_char(p, '{')) return false;

    while (true) {
        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == '}') {
            p->pos++;
            return true;
        }

        char key[64];
        if (!parse_string(p, key, sizeof(key))) return false;
        if (!expect_char(p, ':')) return false;

        if (strcmp(key, "insert_first") == 0) {
            skip_whitespace(p);
            // Could be a single object or an array
            if (p->json[p->pos] == '[') {
                if (!parse_events_array(p, tc->setup_events, &tc->setup_event_count)) {
                    return false;
                }
            } else if (p->json[p->pos] == '{') {
                if (!parse_event(p, &tc->setup_events[0])) return false;
                tc->setup_event_count = 1;
            } else {
                if (!skip_value(p)) return false;
            }
        } else {
            if (!skip_value(p)) return false;
        }

        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == ',') {
            p->pos++;
        }
    }
}

// Parse input section
static bool parse_input(JsonParser* p, TestCase* tc) {
    if (!expect_char(p, '{')) return false;

    while (true) {
        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == '}') {
            p->pos++;
            return true;
        }

        char key[64];
        if (!parse_string(p, key, sizeof(key))) return false;
        if (!expect_char(p, ':')) return false;

        if (strcmp(key, "events") == 0) {
            if (!parse_events_array(p, tc->events, &tc->event_count)) return false;
        } else if (strcmp(key, "entity_ids") == 0) {
            if (!parse_entity_ids_array(p, tc->entity_ids, &tc->entity_id_count)) return false;
        } else if (strcmp(key, "setup") == 0) {
            if (!parse_setup(p, tc)) return false;
        } else if (strcmp(key, "center_latitude") == 0) {
            if (!parse_number(p, &tc->center_latitude)) return false;
        } else if (strcmp(key, "center_longitude") == 0) {
            if (!parse_number(p, &tc->center_longitude)) return false;
        } else if (strcmp(key, "radius_m") == 0) {
            double r;
            if (!parse_number(p, &r)) return false;
            tc->radius_m = (uint32_t)r;
        } else if (strcmp(key, "limit") == 0) {
            double l;
            if (!parse_number(p, &l)) return false;
            tc->limit = (uint32_t)l;
        } else if (strcmp(key, "group_id") == 0) {
            int64_t gid;
            if (!parse_int(p, &gid)) return false;
            tc->group_id = (uint64_t)gid;
        } else if (strcmp(key, "ttl_seconds") == 0 || strcmp(key, "extend_by_seconds") == 0) {
            int64_t ttl;
            if (!parse_int(p, &ttl)) return false;
            tc->ttl_seconds = (uint32_t)ttl;
        } else {
            if (!skip_value(p)) return false;
        }

        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == ',') {
            p->pos++;
        }
    }
}

// Parse expected_output section
static bool parse_expected_output(JsonParser* p, TestCase* tc) {
    if (!expect_char(p, '{')) return false;

    while (true) {
        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == '}') {
            p->pos++;
            return true;
        }

        char key[64];
        if (!parse_string(p, key, sizeof(key))) return false;
        if (!expect_char(p, ':')) return false;

        if (strcmp(key, "result_code") == 0) {
            int64_t code;
            if (!parse_int(p, &code)) return false;
            tc->expected_result_code = (int)code;
        } else if (strcmp(key, "count") == 0 || strcmp(key, "count_in_range") == 0) {
            int64_t count;
            if (!parse_int(p, &count)) return false;
            tc->expected_count = (int)count;
        } else if (strcmp(key, "events_contain") == 0) {
            if (!parse_entity_ids_array(p, tc->expected_entity_ids, &tc->expected_entity_id_count)) {
                return false;
            }
        } else if (strcmp(key, "status") == 0) {
            char status[64];
            if (!parse_string(p, status, sizeof(status))) return false;
            tc->expect_success = (strcmp(status, "OK") == 0);
        } else if (strcmp(key, "response_received") == 0 ||
                   strcmp(key, "healthy") == 0 ||
                   strcmp(key, "success") == 0) {
            bool val;
            if (!parse_bool(p, &val)) return false;
            tc->expect_success = val;
        } else {
            if (!skip_value(p)) return false;
        }

        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == ',') {
            p->pos++;
        }
    }
}

// Parse a single test case
static bool parse_test_case(JsonParser* p, TestCase* tc) {
    memset(tc, 0, sizeof(*tc));
    tc->expect_success = true;  // Default to expecting success

    if (!expect_char(p, '{')) return false;

    while (true) {
        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == '}') {
            p->pos++;
            return true;
        }

        char key[64];
        if (!parse_string(p, key, sizeof(key))) return false;
        if (!expect_char(p, ':')) return false;

        if (strcmp(key, "name") == 0) {
            if (!parse_string(p, tc->name, sizeof(tc->name))) return false;
        } else if (strcmp(key, "description") == 0) {
            if (!parse_string(p, tc->description, sizeof(tc->description))) return false;
        } else if (strcmp(key, "tags") == 0) {
            if (!parse_tags_array(p, tc->tags, &tc->tag_count)) return false;
        } else if (strcmp(key, "input") == 0) {
            if (!parse_input(p, tc)) return false;
        } else if (strcmp(key, "expected_output") == 0) {
            if (!parse_expected_output(p, tc)) return false;
        } else {
            if (!skip_value(p)) return false;
        }

        skip_whitespace(p);
        if (p->pos < p->len && p->json[p->pos] == ',') {
            p->pos++;
        }
    }
}

Fixture* load_fixture(const char* operation) {
    // Build the fixture path
    char path[512];
    snprintf(path, sizeof(path),
             "%s/../../../test_infrastructure/fixtures/v1/%s.json",
             __FILE__, operation);

    // Try relative path from tests/sdk_tests/c directory
    char alt_path[512];
    snprintf(alt_path, sizeof(alt_path),
             "../../../test_infrastructure/fixtures/v1/%s.json", operation);

    FILE* f = fopen(alt_path, "r");
    if (!f) {
        // Try absolute path
        snprintf(path, sizeof(path),
                 "/home/g/archerdb/test_infrastructure/fixtures/v1/%s.json", operation);
        f = fopen(path, "r");
    }

    if (!f) {
        fprintf(stderr, "Failed to open fixture file: %s\n", operation);
        return NULL;
    }

    // Read the entire file
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    char* json = malloc(fsize + 1);
    if (!json) {
        fclose(f);
        return NULL;
    }

    size_t read_size = fread(json, 1, fsize, f);
    fclose(f);
    json[read_size] = '\0';

    // Allocate fixture
    Fixture* fixture = calloc(1, sizeof(Fixture));
    if (!fixture) {
        free(json);
        return NULL;
    }

    // Parse the JSON
    JsonParser parser = {
        .json = json,
        .pos = 0,
        .len = read_size
    };

    if (!expect_char(&parser, '{')) {
        free(json);
        free(fixture);
        return NULL;
    }

    while (true) {
        skip_whitespace(&parser);
        if (parser.pos < parser.len && parser.json[parser.pos] == '}') {
            break;
        }

        char key[64];
        if (!parse_string(&parser, key, sizeof(key))) {
            free(json);
            free(fixture);
            return NULL;
        }
        if (!expect_char(&parser, ':')) {
            free(json);
            free(fixture);
            return NULL;
        }

        if (strcmp(key, "operation") == 0) {
            if (!parse_string(&parser, fixture->operation, sizeof(fixture->operation))) {
                free(json);
                free(fixture);
                return NULL;
            }
        } else if (strcmp(key, "version") == 0) {
            if (!parse_string(&parser, fixture->version, sizeof(fixture->version))) {
                free(json);
                free(fixture);
                return NULL;
            }
        } else if (strcmp(key, "description") == 0) {
            if (!parse_string(&parser, fixture->description, sizeof(fixture->description))) {
                free(json);
                free(fixture);
                return NULL;
            }
        } else if (strcmp(key, "cases") == 0) {
            if (!expect_char(&parser, '[')) {
                free(json);
                free(fixture);
                return NULL;
            }

            skip_whitespace(&parser);
            if (parser.pos < parser.len && parser.json[parser.pos] == ']') {
                parser.pos++;
            } else {
                while (fixture->case_count < MAX_TEST_CASES) {
                    if (!parse_test_case(&parser, &fixture->cases[fixture->case_count])) {
                        free(json);
                        free(fixture);
                        return NULL;
                    }
                    fixture->case_count++;

                    skip_whitespace(&parser);
                    if (parser.pos >= parser.len) break;
                    if (parser.json[parser.pos] == ']') {
                        parser.pos++;
                        break;
                    }
                    if (parser.json[parser.pos] != ',') break;
                    parser.pos++;
                }
            }
        } else {
            if (!skip_value(&parser)) {
                free(json);
                free(fixture);
                return NULL;
            }
        }

        skip_whitespace(&parser);
        if (parser.pos < parser.len && parser.json[parser.pos] == ',') {
            parser.pos++;
        }
    }

    free(json);
    return fixture;
}

void free_fixture(Fixture* fixture) {
    if (fixture) {
        free(fixture);
    }
}
