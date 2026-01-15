// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

//! Wire format compatibility tests.
//!
//! Tests that the Rust SDK produces wire format compatible with the canonical
//! test data from wire-format-test-cases.json and other language SDKs.
//! Values are inlined from the canonical test data file.

use archerdb::{
    degrees_to_nano, heading_to_centidegrees, is_valid_latitude, is_valid_longitude,
    meters_to_mm, nano_to_degrees, GeoEvent, GeoEventFlags, GeoEventOptions,
    InsertGeoEventResult, PolygonQuery, RadiusQuery, BATCH_SIZE_MAX, CENTIDEGREES_PER_DEGREE,
    LAT_MAX, LON_MAX, MM_PER_METER, NANODEGREES_PER_DEGREE, POLYGON_VERTICES_MAX,
    QUERY_LIMIT_MAX,
};

// ============================================================================
// Canonical Constants (from wire-format-test-cases.json)
// ============================================================================

const CANONICAL_LAT_MAX: f64 = 90.0;
const CANONICAL_LON_MAX: f64 = 180.0;
const CANONICAL_NANODEGREES_PER_DEGREE: i64 = 1_000_000_000;
const CANONICAL_MM_PER_METER: i64 = 1000;
const CANONICAL_CENTIDEGREES_PER_DEGREE: i64 = 100;
const CANONICAL_BATCH_SIZE_MAX: usize = 10_000;
const CANONICAL_QUERY_LIMIT_MAX: usize = 81_000;
const CANONICAL_POLYGON_VERTICES_MAX: usize = 10_000;

// ============================================================================
// Constants Tests
// ============================================================================

#[test]
fn test_constants_lat_max() {
    assert_eq!(LAT_MAX, CANONICAL_LAT_MAX, "LAT_MAX mismatch");
}

#[test]
fn test_constants_lon_max() {
    assert_eq!(LON_MAX, CANONICAL_LON_MAX, "LON_MAX mismatch");
}

#[test]
fn test_constants_nanodegrees_per_degree() {
    assert_eq!(
        NANODEGREES_PER_DEGREE, CANONICAL_NANODEGREES_PER_DEGREE,
        "NANODEGREES_PER_DEGREE mismatch"
    );
}

#[test]
fn test_constants_mm_per_meter() {
    assert_eq!(MM_PER_METER, CANONICAL_MM_PER_METER, "MM_PER_METER mismatch");
}

#[test]
fn test_constants_centidegrees_per_degree() {
    assert_eq!(
        CENTIDEGREES_PER_DEGREE, CANONICAL_CENTIDEGREES_PER_DEGREE,
        "CENTIDEGREES_PER_DEGREE mismatch"
    );
}

#[test]
fn test_constants_batch_size_max() {
    assert_eq!(
        BATCH_SIZE_MAX, CANONICAL_BATCH_SIZE_MAX,
        "BATCH_SIZE_MAX mismatch"
    );
}

#[test]
fn test_constants_query_limit_max() {
    assert_eq!(
        QUERY_LIMIT_MAX, CANONICAL_QUERY_LIMIT_MAX,
        "QUERY_LIMIT_MAX mismatch"
    );
}

#[test]
fn test_constants_polygon_vertices_max() {
    assert_eq!(
        POLYGON_VERTICES_MAX, CANONICAL_POLYGON_VERTICES_MAX,
        "POLYGON_VERTICES_MAX mismatch"
    );
}

// ============================================================================
// GeoEvent Flags Tests (from wire-format-test-cases.json geo_event_flags)
// ============================================================================

#[test]
fn test_flag_none() {
    assert_eq!(GeoEventFlags::empty().bits(), 0u16, "NONE flag mismatch");
}

#[test]
fn test_flag_linked() {
    assert_eq!(GeoEventFlags::LINKED.bits(), 1u16, "LINKED flag mismatch");
}

#[test]
fn test_flag_imported() {
    assert_eq!(GeoEventFlags::IMPORTED.bits(), 2u16, "IMPORTED flag mismatch");
}

#[test]
fn test_flag_stationary() {
    assert_eq!(GeoEventFlags::STATIONARY.bits(), 4u16, "STATIONARY flag mismatch");
}

#[test]
fn test_flag_low_accuracy() {
    assert_eq!(GeoEventFlags::LOW_ACCURACY.bits(), 8u16, "LOW_ACCURACY flag mismatch");
}

#[test]
fn test_flag_offline() {
    assert_eq!(GeoEventFlags::OFFLINE.bits(), 16u16, "OFFLINE flag mismatch");
}

#[test]
fn test_flag_deleted() {
    assert_eq!(GeoEventFlags::DELETED.bits(), 32u16, "DELETED flag mismatch");
}

// ============================================================================
// Insert Result Codes Tests (from wire-format-test-cases.json insert_result_codes)
// ============================================================================

#[test]
fn test_insert_result_ok() {
    assert_eq!(InsertGeoEventResult::Ok as u32, 0, "OK code mismatch");
}

#[test]
fn test_insert_result_linked_event_failed() {
    assert_eq!(
        InsertGeoEventResult::LinkedEventFailed as u32,
        1,
        "LINKED_EVENT_FAILED code mismatch"
    );
}

#[test]
fn test_insert_result_invalid_coordinates() {
    assert_eq!(
        InsertGeoEventResult::InvalidCoordinates as u32,
        8,
        "INVALID_COORDINATES code mismatch"
    );
}

#[test]
fn test_insert_result_exists() {
    assert_eq!(InsertGeoEventResult::Exists as u32, 13, "EXISTS code mismatch");
}

// ============================================================================
// Coordinate Conversion Tests (from wire-format-test-cases.json coordinate_conversions)
// ============================================================================

#[test]
fn test_degrees_to_nano_zero() {
    assert_eq!(degrees_to_nano(0.0), 0, "Zero coordinates");
}

#[test]
fn test_degrees_to_nano_max_lat() {
    assert_eq!(degrees_to_nano(90.0), 90_000_000_000, "Maximum latitude");
}

#[test]
fn test_degrees_to_nano_min_lat() {
    assert_eq!(degrees_to_nano(-90.0), -90_000_000_000, "Minimum latitude");
}

#[test]
fn test_degrees_to_nano_max_lon() {
    assert_eq!(degrees_to_nano(180.0), 180_000_000_000, "Maximum longitude");
}

#[test]
fn test_degrees_to_nano_min_lon() {
    assert_eq!(degrees_to_nano(-180.0), -180_000_000_000, "Minimum longitude");
}

#[test]
fn test_degrees_to_nano_san_francisco_lat() {
    assert_eq!(degrees_to_nano(37.7749), 37_774_900_000, "San Francisco latitude");
}

#[test]
fn test_degrees_to_nano_san_francisco_lon() {
    assert_eq!(
        degrees_to_nano(-122.4194),
        -122_419_400_000,
        "San Francisco longitude"
    );
}

#[test]
fn test_degrees_to_nano_tokyo_lat() {
    assert_eq!(degrees_to_nano(35.6762), 35_676_200_000, "Tokyo latitude");
}

#[test]
fn test_degrees_to_nano_small_positive() {
    assert_eq!(degrees_to_nano(0.000000001), 1, "Small positive");
}

#[test]
fn test_degrees_to_nano_precision() {
    assert_eq!(degrees_to_nano(45.123456789), 45_123_456_789, "Precision test");
}

// ============================================================================
// Coordinate Roundtrip Tests
// ============================================================================

#[test]
fn test_coordinate_roundtrip() {
    let test_values: &[(f64, i64)] = &[
        (0.0, 0),
        (90.0, 90_000_000_000),
        (-90.0, -90_000_000_000),
        (180.0, 180_000_000_000),
        (-180.0, -180_000_000_000),
        (37.7749, 37_774_900_000),
        (-122.4194, -122_419_400_000),
        (35.6762, 35_676_200_000),
        (0.000000001, 1),
        (45.123456789, 45_123_456_789),
    ];

    for &(_, expected_nano) in test_values {
        let degrees = nano_to_degrees(expected_nano);
        let round_trip = degrees_to_nano(degrees);
        assert_eq!(
            round_trip, expected_nano,
            "Roundtrip failed for nano={}",
            expected_nano
        );
    }
}

// ============================================================================
// Distance Conversion Tests (from wire-format-test-cases.json distance_conversions)
// ============================================================================

#[test]
fn test_meters_to_mm_zero() {
    assert_eq!(meters_to_mm(0.0), 0, "Zero meters");
}

#[test]
fn test_meters_to_mm_one() {
    assert_eq!(meters_to_mm(1.0), 1000, "One meter");
}

#[test]
fn test_meters_to_mm_kilometer() {
    assert_eq!(meters_to_mm(1000.0), 1_000_000, "One kilometer");
}

#[test]
fn test_meters_to_mm_fractional() {
    assert_eq!(meters_to_mm(1.5), 1500, "Fractional meters");
}

#[test]
fn test_meters_to_mm_sub_millimeter_rounds_up() {
    // 0.0006 * 1000 = 0.6, rounds to 1
    assert_eq!(meters_to_mm(0.0006), 1, "Sub-millimeter (rounds up)");
}

// ============================================================================
// Heading Conversion Tests (from wire-format-test-cases.json heading_conversions)
// ============================================================================

#[test]
fn test_heading_north() {
    assert_eq!(heading_to_centidegrees(0.0), 0, "North");
}

#[test]
fn test_heading_east() {
    assert_eq!(heading_to_centidegrees(90.0), 9000, "East");
}

#[test]
fn test_heading_south() {
    assert_eq!(heading_to_centidegrees(180.0), 18000, "South");
}

#[test]
fn test_heading_west() {
    assert_eq!(heading_to_centidegrees(270.0), 27000, "West");
}

#[test]
fn test_heading_full_circle() {
    assert_eq!(heading_to_centidegrees(360.0), 36000, "Full circle");
}

#[test]
fn test_heading_fractional() {
    assert_eq!(heading_to_centidegrees(45.5), 4550, "Fractional heading");
}

// ============================================================================
// GeoEvent Creation Tests (from wire-format-test-cases.json geo_events)
// ============================================================================

#[test]
fn test_geo_event_basic_at_origin() {
    let event = GeoEvent::from_options(GeoEventOptions {
        entity_id: 12345,
        latitude: 0.0,
        longitude: 0.0,
        ..Default::default()
    })
    .unwrap();

    assert_eq!(event.entity_id, 12345);
    assert_eq!(event.lat_nano, 0);
    assert_eq!(event.lon_nano, 0);
    assert_eq!(event.id, 0);
    assert_eq!(event.timestamp, 0);
    assert_eq!(event.correlation_id, 0);
    assert_eq!(event.user_data, 0);
    assert_eq!(event.group_id, 0);
    assert_eq!(event.altitude_mm, 0);
    assert_eq!(event.velocity_mms, 0);
    assert_eq!(event.ttl_seconds, 0);
    assert_eq!(event.accuracy_mm, 0);
    assert_eq!(event.heading_cdeg, 0);
    assert_eq!(event.flags.bits(), 0);
}

#[test]
fn test_geo_event_san_francisco_all_fields() {
    let event = GeoEvent::from_options(GeoEventOptions {
        entity_id: 99999,
        latitude: 37.7749,
        longitude: -122.4194,
        correlation_id: 11111,
        user_data: 42,
        group_id: 1001,
        altitude_m: 100.5,
        velocity_mps: 15.0,
        ttl_seconds: 3600,
        accuracy_m: 5.0,
        heading: 90.0,
        flags: GeoEventFlags::STATIONARY,
    })
    .unwrap();

    assert_eq!(event.entity_id, 99999);
    assert_eq!(event.lat_nano, 37_774_900_000);
    assert_eq!(event.lon_nano, -122_419_400_000);
    assert_eq!(event.id, 0);
    assert_eq!(event.timestamp, 0);
    assert_eq!(event.correlation_id, 11111);
    assert_eq!(event.user_data, 42);
    assert_eq!(event.group_id, 1001);
    assert_eq!(event.altitude_mm, 100500);
    assert_eq!(event.velocity_mms, 15000);
    assert_eq!(event.ttl_seconds, 3600);
    assert_eq!(event.accuracy_mm, 5000);
    assert_eq!(event.heading_cdeg, 9000);
    assert_eq!(event.flags.bits(), 4);
}

#[test]
fn test_geo_event_at_poles() {
    let event = GeoEvent::from_options(GeoEventOptions {
        entity_id: 1,
        latitude: 90.0,
        longitude: 180.0,
        ..Default::default()
    })
    .unwrap();

    assert_eq!(event.entity_id, 1);
    assert_eq!(event.lat_nano, 90_000_000_000);
    assert_eq!(event.lon_nano, 180_000_000_000);
}

#[test]
fn test_geo_event_combined_flags() {
    let event = GeoEvent::from_options(GeoEventOptions {
        entity_id: 5555,
        latitude: 0.0,
        longitude: 0.0,
        flags: GeoEventFlags::from_bits_truncate(5), // LINKED | STATIONARY
        ..Default::default()
    })
    .unwrap();

    assert_eq!(event.entity_id, 5555);
    assert_eq!(event.flags.bits(), 5);
}

// ============================================================================
// Radius Query Tests (from wire-format-test-cases.json radius_queries)
// ============================================================================

#[test]
fn test_radius_query_basic() {
    let query = RadiusQuery::new(37.7749, -122.4194, 1000.0, 1000).unwrap();

    assert_eq!(query.center_lat_nano, 37_774_900_000);
    assert_eq!(query.center_lon_nano, -122_419_400_000);
    assert_eq!(query.radius_mm, 1_000_000);
    assert_eq!(query.limit, 1000);
    assert_eq!(query.group_id, 0);
}

#[test]
fn test_radius_query_with_all_options() {
    let query = RadiusQuery::new(35.6762, 139.6503, 5000.0, 500)
        .unwrap()
        .with_time_range(1000, 2000)
        .with_group(42);

    assert_eq!(query.center_lat_nano, 35_676_200_000);
    assert_eq!(query.center_lon_nano, 139_650_300_000);
    assert_eq!(query.radius_mm, 5_000_000);
    assert_eq!(query.limit, 500);
    assert_eq!(query.timestamp_min, 1000);
    assert_eq!(query.timestamp_max, 2000);
    assert_eq!(query.group_id, 42);
}

// ============================================================================
// Polygon Query Tests (from wire-format-test-cases.json polygon_queries)
// ============================================================================

#[test]
fn test_polygon_query_triangle() {
    let vertices = [[37.0, -122.0], [38.0, -122.0], [37.5, -121.0]];
    let query = PolygonQuery::new(&vertices, 1000).unwrap();

    assert_eq!(query.vertices.len(), 3);
    assert_eq!(query.vertices[0].lat_nano, 37_000_000_000);
    assert_eq!(query.vertices[0].lon_nano, -122_000_000_000);
    assert_eq!(query.vertices[1].lat_nano, 38_000_000_000);
    assert_eq!(query.vertices[1].lon_nano, -122_000_000_000);
    assert_eq!(query.vertices[2].lat_nano, 37_500_000_000);
    assert_eq!(query.vertices[2].lon_nano, -121_000_000_000);
    assert_eq!(query.limit, 1000);
    assert_eq!(query.group_id, 0);
}

#[test]
fn test_polygon_query_rectangle_with_options() {
    let vertices = [
        [37.0, -122.5],
        [37.0, -122.0],
        [38.0, -122.0],
        [38.0, -122.5],
    ];
    let query = PolygonQuery::new(&vertices, 200).unwrap().with_group(10);

    assert_eq!(query.vertices.len(), 4);
    assert_eq!(query.vertices[0].lat_nano, 37_000_000_000);
    assert_eq!(query.vertices[0].lon_nano, -122_500_000_000);
    assert_eq!(query.vertices[1].lat_nano, 37_000_000_000);
    assert_eq!(query.vertices[1].lon_nano, -122_000_000_000);
    assert_eq!(query.vertices[2].lat_nano, 38_000_000_000);
    assert_eq!(query.vertices[2].lon_nano, -122_000_000_000);
    assert_eq!(query.vertices[3].lat_nano, 38_000_000_000);
    assert_eq!(query.vertices[3].lon_nano, -122_500_000_000);
    assert_eq!(query.limit, 200);
    assert_eq!(query.group_id, 10);
}

// ============================================================================
// Validation Tests (from wire-format-test-cases.json validation_cases)
// ============================================================================

#[test]
fn test_invalid_latitudes_rejected() {
    let invalid_latitudes = [91.0, -91.0, 180.0, -180.0, 1000.0];
    for lat in invalid_latitudes {
        assert!(!is_valid_latitude(lat), "Latitude {} should be invalid", lat);
    }
}

#[test]
fn test_invalid_longitudes_rejected() {
    let invalid_longitudes = [181.0, -181.0, 360.0, -360.0, 1000.0];
    for lon in invalid_longitudes {
        assert!(
            !is_valid_longitude(lon),
            "Longitude {} should be invalid",
            lon
        );
    }
}

#[test]
fn test_valid_boundary_latitudes_accepted() {
    let valid_latitudes = [90.0, -90.0, 0.0, 45.0, -45.0];
    for lat in valid_latitudes {
        assert!(is_valid_latitude(lat), "Latitude {} should be valid", lat);
    }
}

#[test]
fn test_valid_boundary_longitudes_accepted() {
    let valid_longitudes = [180.0, -180.0, 0.0, 90.0, -90.0];
    for lon in valid_longitudes {
        assert!(is_valid_longitude(lon), "Longitude {} should be valid", lon);
    }
}

// ============================================================================
// GeoEvent Size Test
// ============================================================================

#[test]
fn test_geo_event_size_is_128_bytes() {
    assert_eq!(
        std::mem::size_of::<GeoEvent>(),
        128,
        "GeoEvent must be exactly 128 bytes"
    );
}
