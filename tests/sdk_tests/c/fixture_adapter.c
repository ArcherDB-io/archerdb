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
        } else if (strcmp(key, "timestamp") == 0) {
            int64_t ts;
            if (!parse_int(p, &ts)) return false;
            event->timestamp = (uint64_t)ts * 1000000000ULL;
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

// Parse events array and append to existing list
static bool parse_events_array_append(JsonParser* p, geo_event_t* events, int* count) {
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

static bool parse_vertices_array(JsonParser* p, TestCase* tc) {
    tc->polygon_vertex_count = 0;
    if (!expect_char(p, '[')) return false;

    skip_whitespace(p);
    if (p->pos < p->len && p->json[p->pos] == ']') {
        p->pos++;
        return true;
    }

    while (tc->polygon_vertex_count < MAX_EVENTS_PER_CASE) {
        if (!expect_char(p, '[')) return false;
        double lat = 0.0;
        double lon = 0.0;
        if (!parse_number(p, &lat)) return false;
        if (!expect_char(p, ',')) return false;
        if (!parse_number(p, &lon)) return false;
        if (!expect_char(p, ']')) return false;

        tc->polygon_vertices[tc->polygon_vertex_count][0] = lat;
        tc->polygon_vertices[tc->polygon_vertex_count][1] = lon;
        tc->polygon_vertex_count++;

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

static bool parse_results_array(JsonParser* p, TestCase* tc) {
    tc->expected_result_code_count = 0;
    if (!expect_char(p, '[')) return false;

    skip_whitespace(p);
    if (p->pos < p->len && p->json[p->pos] == ']') {
        p->pos++;
        return true;
    }

    while (tc->expected_result_code_count < MAX_EVENTS_PER_CASE) {
        int64_t code = 0;
        skip_whitespace(p);
        if (p->pos >= p->len) return false;

        if (p->json[p->pos] == '{') {
            if (!expect_char(p, '{')) return false;
            while (true) {
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == '}') {
                    p->pos++;
                    break;
                }
                char key[64];
                if (!parse_string(p, key, sizeof(key))) return false;
                if (!expect_char(p, ':')) return false;
                if (strcmp(key, "code") == 0) {
                    if (!parse_int(p, &code)) return false;
                } else {
                    if (!skip_value(p)) return false;
                }
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == ',') {
                    p->pos++;
                }
            }
        } else {
            if (!skip_value(p)) return false;
        }

        tc->expected_result_codes[tc->expected_result_code_count++] = (uint32_t)code;

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

static bool parse_setup_operations(JsonParser* p, TestCase* tc) {
    if (!expect_char(p, '[')) return false;
    skip_whitespace(p);
    if (p->pos < p->len && p->json[p->pos] == ']') {
        p->pos++;
        return true;
    }

    while (tc->setup_operation_count < MAX_SETUP_OPERATIONS) {
        if (!expect_char(p, '{')) return false;
        char type[64] = "";
        int64_t count = 0;
        while (true) {
            skip_whitespace(p);
            if (p->pos < p->len && p->json[p->pos] == '}') {
                p->pos++;
                break;
            }
            char key[64];
            if (!parse_string(p, key, sizeof(key))) return false;
            if (!expect_char(p, ':')) return false;
            if (strcmp(key, "type") == 0) {
                if (!parse_string(p, type, sizeof(type))) return false;
            } else if (strcmp(key, "count") == 0) {
                if (!parse_int(p, &count)) return false;
            } else {
                if (!skip_value(p)) return false;
            }
            skip_whitespace(p);
            if (p->pos < p->len && p->json[p->pos] == ',') {
                p->pos++;
            }
        }

        if (type[0] != '\0' && count > 0) {
            setup_operation_type_t op_type = 0;
            if (strcmp(type, "insert") == 0) {
                op_type = SETUP_OP_INSERT;
            } else if (strcmp(type, "query_radius") == 0) {
                op_type = SETUP_OP_QUERY_RADIUS;
            }
            if (op_type != 0) {
                tc->setup_operations[tc->setup_operation_count].type = op_type;
                tc->setup_operations[tc->setup_operation_count].count = (int)count;
                tc->setup_operation_count++;
            }
        }

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

static void append_setup_event(TestCase* tc, const geo_event_t* event) {
    if (tc->setup_event_count < MAX_EVENTS_PER_CASE) {
        tc->setup_events[tc->setup_event_count++] = *event;
    }
}

static void init_event_basic(geo_event_t* event, arch_uint128_t entity_id,
                             double lat, double lon, uint64_t group_id) {
    memset(event, 0, sizeof(*event));
    event->entity_id = entity_id;
    event->id = entity_id;
    event->lat_nano = degrees_to_nano(lat);
    event->lon_nano = degrees_to_nano(lon);
    event->group_id = group_id;
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
                if (!parse_events_array_append(p, tc->setup_events, &tc->setup_event_count)) {
                    return false;
                }
            } else if (p->json[p->pos] == '{') {
                geo_event_t ev;
                if (!parse_event(p, &ev)) return false;
                append_setup_event(tc, &ev);
            } else {
                if (!skip_value(p)) return false;
            }
        } else if (strcmp(key, "insert_first_range") == 0) {
            if (!expect_char(p, '{')) return false;
            int64_t start_id = 0;
            int64_t count = 0;
            double base_lat = 0.0;
            double base_lon = 0.0;
            double spread_m = 0.0;
            uint64_t group_id = 0;
            while (true) {
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == '}') {
                    p->pos++;
                    break;
                }
                char range_key[64];
                if (!parse_string(p, range_key, sizeof(range_key))) return false;
                if (!expect_char(p, ':')) return false;
                if (strcmp(range_key, "start_entity_id") == 0) {
                    if (!parse_int(p, &start_id)) return false;
                } else if (strcmp(range_key, "count") == 0) {
                    if (!parse_int(p, &count)) return false;
                } else if (strcmp(range_key, "base_latitude") == 0) {
                    if (!parse_number(p, &base_lat)) return false;
                } else if (strcmp(range_key, "base_longitude") == 0) {
                    if (!parse_number(p, &base_lon)) return false;
                } else if (strcmp(range_key, "spread_m") == 0) {
                    if (!parse_number(p, &spread_m)) return false;
                } else if (strcmp(range_key, "group_id") == 0) {
                    int64_t gid;
                    if (!parse_int(p, &gid)) return false;
                    group_id = (uint64_t)gid;
                } else {
                    if (!skip_value(p)) return false;
                }
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == ',') {
                    p->pos++;
                }
            }

            if (count > 0) {
                double spread_deg = spread_m / 111000.0;
                int cols = (count < 10) ? (int)count : 10;
                if (cols <= 0) cols = 1;
                int rows = ((int)count + cols - 1) / cols;
                for (int i = 0; i < count; i++) {
                    if (tc->setup_event_count >= MAX_EVENTS_PER_CASE) break;
                    int row = i / cols;
                    int col = i % cols;
                    double row_frac = rows <= 1 ? 0.5 : (double)row / (double)(rows - 1);
                    double col_frac = cols <= 1 ? 0.5 : (double)col / (double)(cols - 1);
                    double lat = base_lat + (row_frac - 0.5) * spread_deg;
                    double lon = base_lon + (col_frac - 0.5) * spread_deg;
                    geo_event_t ev;
                    init_event_basic(&ev, (arch_uint128_t)(start_id + i), lat, lon, group_id);
                    append_setup_event(tc, &ev);
                }
            }
        } else if (strcmp(key, "insert_hotspot") == 0) {
            if (!expect_char(p, '{')) return false;
            int64_t count = 0;
            int64_t start_id = 1;
            double center_lat = 0.0;
            double center_lon = 0.0;
            double concentration = 100.0;
            uint64_t group_id = 0;
            while (true) {
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == '}') {
                    p->pos++;
                    break;
                }
                char hot_key[64];
                if (!parse_string(p, hot_key, sizeof(hot_key))) return false;
                if (!expect_char(p, ':')) return false;
                if (strcmp(hot_key, "count") == 0) {
                    if (!parse_int(p, &count)) return false;
                } else if (strcmp(hot_key, "start_entity_id") == 0) {
                    if (!parse_int(p, &start_id)) return false;
                } else if (strcmp(hot_key, "center_latitude") == 0) {
                    if (!parse_number(p, &center_lat)) return false;
                } else if (strcmp(hot_key, "center_longitude") == 0) {
                    if (!parse_number(p, &center_lon)) return false;
                } else if (strcmp(hot_key, "concentration_percentage") == 0) {
                    if (!parse_number(p, &concentration)) return false;
                } else if (strcmp(hot_key, "group_id") == 0) {
                    int64_t gid;
                    if (!parse_int(p, &gid)) return false;
                    group_id = (uint64_t)gid;
                } else {
                    if (!skip_value(p)) return false;
                }
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == ',') {
                    p->pos++;
                }
            }

            if (count > 0) {
                int hotspot_count = (int)round((double)count * (concentration / 100.0));
                if (hotspot_count > count) hotspot_count = (int)count;
                int spread_count = (int)count - hotspot_count;
                for (int i = 0; i < count; i++) {
                    if (tc->setup_event_count >= MAX_EVENTS_PER_CASE) break;
                    bool in_hotspot = i < hotspot_count;
                    int total = in_hotspot ? hotspot_count : spread_count;
                    int idx = in_hotspot ? i : (i - hotspot_count);
                    double spread_deg = in_hotspot ? 0.005 : 0.05;
                    if (total <= 0) total = 1;
                    int cols = total < 10 ? total : 10;
                    if (cols <= 0) cols = 1;
                    int rows = (total + cols - 1) / cols;
                    int row = idx / cols;
                    int col = idx % cols;
                    double row_frac = rows <= 1 ? 0.5 : (double)row / (double)(rows - 1);
                    double col_frac = cols <= 1 ? 0.5 : (double)col / (double)(cols - 1);
                    double lat = center_lat + (row_frac - 0.5) * spread_deg;
                    double lon = center_lon + (col_frac - 0.5) * spread_deg;
                    geo_event_t ev;
                    init_event_basic(&ev, (arch_uint128_t)(start_id + i), lat, lon, group_id);
                    append_setup_event(tc, &ev);
                }
            }
        } else if (strcmp(key, "insert_with_timestamps") == 0) {
            if (!parse_events_array_append(p, tc->setup_events, &tc->setup_event_count)) {
                return false;
            }
        } else if (strcmp(key, "then_upsert") == 0) {
            skip_whitespace(p);
            if (p->json[p->pos] == '[') {
                if (!parse_events_array(p, tc->setup_upsert_events, &tc->setup_upsert_event_count)) {
                    return false;
                }
            } else if (p->json[p->pos] == '{') {
                geo_event_t ev;
                if (!parse_event(p, &ev)) return false;
                if (tc->setup_upsert_event_count < MAX_EVENTS_PER_CASE) {
                    tc->setup_upsert_events[tc->setup_upsert_event_count++] = ev;
                }
            } else {
                if (!skip_value(p)) return false;
            }
        } else if (strcmp(key, "then_clear_ttl") == 0) {
            int64_t id;
            if (!parse_int(p, &id)) return false;
            tc->setup_clear_ttl_id = (arch_uint128_t)id;
            tc->has_setup_clear_ttl = true;
        } else if (strcmp(key, "then_wait_seconds") == 0) {
            double seconds;
            if (!parse_number(p, &seconds)) return false;
            tc->setup_wait_seconds = (uint32_t)seconds;
            tc->has_setup_wait_seconds = true;
        } else if (strcmp(key, "perform_operations") == 0) {
            if (!parse_setup_operations(p, tc)) return false;
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
        } else if (strcmp(key, "entity_id") == 0) {
            int64_t id;
            if (!parse_int(p, &id)) return false;
            tc->entity_ids[0] = (arch_uint128_t)id;
            tc->entity_id_count = 1;
        } else if (strcmp(key, "entity_ids") == 0) {
            if (!parse_entity_ids_array(p, tc->entity_ids, &tc->entity_id_count)) return false;
        } else if (strcmp(key, "entity_ids_range") == 0) {
            if (!expect_char(p, '{')) return false;
            int64_t start_id = 0;
            int64_t count = 0;
            while (true) {
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == '}') {
                    p->pos++;
                    break;
                }
                char range_key[64];
                if (!parse_string(p, range_key, sizeof(range_key))) return false;
                if (!expect_char(p, ':')) return false;
                if (strcmp(range_key, "start") == 0) {
                    if (!parse_int(p, &start_id)) return false;
                } else if (strcmp(range_key, "count") == 0) {
                    if (!parse_int(p, &count)) return false;
                } else {
                    if (!skip_value(p)) return false;
                }
                skip_whitespace(p);
                if (p->pos < p->len && p->json[p->pos] == ',') {
                    p->pos++;
                }
            }
            tc->entity_id_count = 0;
            for (int i = 0; i < count && i < MAX_EVENTS_PER_CASE; i++) {
                tc->entity_ids[tc->entity_id_count++] = (arch_uint128_t)(start_id + i);
            }
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
        } else if (strcmp(key, "vertices") == 0) {
            if (!parse_vertices_array(p, tc)) return false;
        } else if (strcmp(key, "timestamp_min") == 0) {
            int64_t ts;
            if (!parse_int(p, &ts)) return false;
            tc->timestamp_min = (uint64_t)ts * 1000000000ULL;
        } else if (strcmp(key, "timestamp_max") == 0) {
            int64_t ts;
            if (!parse_int(p, &ts)) return false;
            tc->timestamp_max = (uint64_t)ts * 1000000000ULL;
        } else if (strcmp(key, "query_entity_id") == 0) {
            int64_t id;
            if (!parse_int(p, &id)) return false;
            tc->query_entity_id = (arch_uint128_t)id;
            tc->has_query_entity_id = true;
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
        } else if (strcmp(key, "results") == 0) {
            if (!parse_results_array(p, tc)) return false;
        } else if (strcmp(key, "count") == 0) {
            int64_t count;
            if (!parse_int(p, &count)) return false;
            tc->expected_count = (int)count;
            tc->expected_count_is_min = false;
            tc->has_expected_count = true;
        } else if (strcmp(key, "count_in_range") == 0) {
            int64_t count;
            if (!parse_int(p, &count)) return false;
            tc->expected_count = (int)count;
            tc->expected_count_is_min = true;
            tc->has_expected_count = true;
        } else if (strcmp(key, "count_in_range_min") == 0 || strcmp(key, "count_min") == 0) {
            int64_t count;
            if (!parse_int(p, &count)) return false;
            tc->expected_count = (int)count;
            tc->expected_count_is_min = true;
            tc->has_expected_count = true;
        } else if (strcmp(key, "events_contain") == 0) {
            if (!parse_entity_ids_array(p, tc->expected_entity_ids, &tc->expected_entity_id_count)) {
                return false;
            }
        } else if (strcmp(key, "events_exclude") == 0) {
            if (!parse_entity_ids_array(p, tc->expected_excluded_ids, &tc->expected_excluded_id_count)) {
                return false;
            }
        } else if (strcmp(key, "found_count") == 0) {
            int64_t count;
            if (!parse_int(p, &count)) return false;
            tc->expected_found_count = (int)count;
            tc->has_expected_found_count = true;
        } else if (strcmp(key, "found") == 0) {
            bool val;
            if (!parse_bool(p, &val)) return false;
            tc->expected_found = val;
            tc->has_expected_found = true;
        } else if (strcmp(key, "new_ttl_min_seconds") == 0) {
            int64_t ttl;
            if (!parse_int(p, &ttl)) return false;
            tc->expected_new_ttl_min_seconds = (uint32_t)ttl;
            tc->has_expected_new_ttl_min_seconds = true;
        } else if (strcmp(key, "entity_still_exists") == 0) {
            bool val;
            if (!parse_bool(p, &val)) return false;
            tc->expected_entity_still_exists = val;
            tc->has_expected_entity_still_exists = true;
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

    // Try multiple paths to find fixtures
    const char* search_paths[] = {
        // From tests/sdk_tests/c directory
        "../../../test_infrastructure/fixtures/v1/%s.json",
        // From project root
        "test_infrastructure/fixtures/v1/%s.json",
        // Absolute path (user-specific, update if needed)
        "/Users/g/.cursor/worktrees/archerdb/ear/test_infrastructure/fixtures/v1/%s.json",
        NULL
    };

    FILE* f = NULL;
    for (int i = 0; search_paths[i] != NULL; i++) {
        char try_path[512];
        snprintf(try_path, sizeof(try_path), search_paths[i], operation);
        f = fopen(try_path, "r");
        if (f) {
            snprintf(path, sizeof(path), "%s", try_path);
            break;
        }
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
