// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

//! Integration tests for ArcherDB Rust SDK geospatial operations.

use archerdb::*;

#[test]
fn test_geo_event_creation() {
    let event = GeoEvent::from_options(GeoEventOptions {
        entity_id: id(),
        latitude: 37.7749,
        longitude: -122.4194,
        group_id: 1,
        ttl_seconds: 86400,
        altitude_m: 10.0,
        velocity_mps: 15.5,
        accuracy_m: 5.0,
        heading: 180.0,
        flags: GeoEventFlags::STATIONARY,
        ..Default::default()
    })
    .unwrap();

    assert_eq!(event.lat_nano, 37_774_900_000);
    assert_eq!(event.lon_nano, -122_419_400_000);
    assert_eq!(event.group_id, 1);
    assert_eq!(event.ttl_seconds, 86400);
    assert_eq!(event.altitude_mm, 10_000);
    assert_eq!(event.velocity_mms, 15_500);
    assert_eq!(event.accuracy_mm, 5_000);
    assert_eq!(event.heading_cdeg, 18000);
    assert!(event.flags.contains(GeoEventFlags::STATIONARY));
}

#[test]
fn test_geo_event_validation() {
    // Invalid latitude
    let result = GeoEvent::from_options(GeoEventOptions {
        latitude: 91.0,
        longitude: 0.0,
        ..Default::default()
    });
    assert!(matches!(result, Err(GeoError::InvalidLatitude(_))));

    // Invalid longitude
    let result = GeoEvent::from_options(GeoEventOptions {
        latitude: 0.0,
        longitude: 181.0,
        ..Default::default()
    });
    assert!(matches!(result, Err(GeoError::InvalidLongitude(_))));
}

#[test]
fn test_radius_query_creation() {
    let query = RadiusQuery::new(37.7749, -122.4194, 1000.0, 100)
        .unwrap()
        .with_group(42)
        .with_time_range(1000, 2000);

    assert_eq!(query.center_lat_nano, 37_774_900_000);
    assert_eq!(query.center_lon_nano, -122_419_400_000);
    assert_eq!(query.radius_mm, 1_000_000);
    assert_eq!(query.limit, 100);
    assert_eq!(query.group_id, 42);
    assert_eq!(query.timestamp_min, 1000);
    assert_eq!(query.timestamp_max, 2000);
}

#[test]
fn test_radius_query_validation() {
    // Invalid latitude
    let result = RadiusQuery::new(91.0, 0.0, 1000.0, 100);
    assert!(matches!(result, Err(GeoError::InvalidLatitude(_))));

    // Invalid radius
    let result = RadiusQuery::new(0.0, 0.0, -100.0, 100);
    assert!(matches!(result, Err(GeoError::InvalidRadius(_))));
}

#[test]
fn test_polygon_query_creation() {
    let vertices = [
        [37.7749, -122.4194],
        [37.7850, -122.4094],
        [37.7650, -122.4094],
    ];

    let query = PolygonQuery::new(&vertices, 100)
        .unwrap()
        .with_group(42)
        .with_time_range(1000, 2000);

    assert_eq!(query.vertices.len(), 3);
    assert_eq!(query.limit, 100);
    assert_eq!(query.group_id, 42);
}

#[test]
fn test_polygon_query_with_holes() {
    let vertices = [
        [37.7749, -122.4194],
        [37.7850, -122.4094],
        [37.7650, -122.4094],
    ];
    let hole = [
        [37.7700, -122.4150],
        [37.7750, -122.4100],
        [37.7650, -122.4100],
    ];

    let query = PolygonQuery::new(&vertices, 100)
        .unwrap()
        .with_hole(&hole)
        .unwrap();

    assert_eq!(query.vertices.len(), 3);
    assert_eq!(query.holes.len(), 1);
    assert_eq!(query.holes[0].vertices.len(), 3);
}

#[test]
fn test_polygon_query_validation() {
    // Too few vertices
    let result = PolygonQuery::new(&[[0.0, 0.0], [1.0, 1.0]], 100);
    assert!(matches!(result, Err(GeoError::InvalidPolygon(_))));

    // Invalid coordinates
    let result = PolygonQuery::new(
        &[[91.0, 0.0], [37.0, -122.0], [37.5, -122.5]],
        100,
    );
    assert!(matches!(result, Err(GeoError::InvalidLatitude(_))));
}

#[test]
fn test_latest_query_creation() {
    let query = LatestQuery::new(100)
        .with_group(42)
        .with_cursor(12345);

    assert_eq!(query.limit, 100);
    assert_eq!(query.group_id, 42);
    assert_eq!(query.cursor_timestamp, 12345);
}

#[test]
fn test_coordinate_conversions() {
    // Degrees to nano
    assert_eq!(degrees_to_nano(37.7749), 37_774_900_000);
    assert_eq!(degrees_to_nano(-122.4194), -122_419_400_000);

    // Nano to degrees
    assert!((nano_to_degrees(37_774_900_000) - 37.7749).abs() < 1e-9);
    assert!((nano_to_degrees(-122_419_400_000) - (-122.4194)).abs() < 1e-9);

    // Meters to mm
    assert_eq!(meters_to_mm(10.0), 10_000);
    assert_eq!(meters_to_mm(-5.5), -5_500);

    // MM to meters
    assert!((mm_to_meters(10_000) - 10.0).abs() < 1e-9);

    // Heading conversions
    assert_eq!(heading_to_centidegrees(180.0), 18000);
    assert!((centidegrees_to_heading(18000) - 180.0).abs() < 1e-9);
}

#[test]
fn test_coordinate_validation() {
    assert!(is_valid_latitude(0.0));
    assert!(is_valid_latitude(90.0));
    assert!(is_valid_latitude(-90.0));
    assert!(!is_valid_latitude(90.1));
    assert!(!is_valid_latitude(-90.1));

    assert!(is_valid_longitude(0.0));
    assert!(is_valid_longitude(180.0));
    assert!(is_valid_longitude(-180.0));
    assert!(!is_valid_longitude(180.1));
    assert!(!is_valid_longitude(-180.1));
}

#[test]
fn test_s2_cell_id_computation() {
    let cell_id = compute_s2_cell_id(37_774_900_000, -122_419_400_000);
    assert!(cell_id > 0);

    // Should be deterministic
    let cell_id2 = compute_s2_cell_id(37_774_900_000, -122_419_400_000);
    assert_eq!(cell_id, cell_id2);

    // Different coordinates should give different IDs
    let cell_id3 = compute_s2_cell_id(40_712_800_000, -74_006_000_000);
    assert_ne!(cell_id, cell_id3);
}

#[test]
fn test_id_generation() {
    let id1 = id();
    let id2 = id();
    let id3 = id();

    // IDs should be unique
    assert_ne!(id1, id2);
    assert_ne!(id2, id3);
    assert_ne!(id1, id3);

    // IDs should be monotonically increasing
    assert!(id2 > id1);
    assert!(id3 > id2);
}

#[test]
fn test_geo_event_size() {
    assert_eq!(std::mem::size_of::<GeoEvent>(), 128);
}

#[test]
fn test_geo_event_flags() {
    // Default is empty
    let flags = GeoEventFlags::default();
    assert!(flags.is_empty());

    // Single flag
    let flags = GeoEventFlags::LINKED;
    assert!(flags.contains(GeoEventFlags::LINKED));
    assert!(!flags.contains(GeoEventFlags::STATIONARY));

    // Combined flags
    let flags = GeoEventFlags::LINKED | GeoEventFlags::STATIONARY | GeoEventFlags::OFFLINE;
    assert!(flags.contains(GeoEventFlags::LINKED));
    assert!(flags.contains(GeoEventFlags::STATIONARY));
    assert!(flags.contains(GeoEventFlags::OFFLINE));
    assert!(!flags.contains(GeoEventFlags::DELETED));
}

#[test]
fn test_insert_result_enum() {
    assert_eq!(InsertGeoEventResult::Ok as u32, 0);
    assert_eq!(InsertGeoEventResult::InvalidCoordinates as u32, 8);
    assert_eq!(InsertGeoEventResult::TtlInvalid as u32, 15);
}

#[test]
fn test_ttl_result_enum() {
    assert_eq!(TtlOperationResult::Success as u8, 0);
    assert_eq!(TtlOperationResult::EntityNotFound as u8, 1);
    assert_eq!(TtlOperationResult::InvalidTtl as u8, 2);
    assert_eq!(TtlOperationResult::NotPermitted as u8, 3);
    assert_eq!(TtlOperationResult::EntityImmutable as u8, 4);
}

// ========================================================================
// TTL Operation Tests
// ========================================================================

#[test]
fn test_ttl_set_response_structure() {
    let response = TtlSetResponse {
        entity_id: 12345,
        previous_ttl_seconds: 3600,
        new_ttl_seconds: 7200,
        result: TtlOperationResult::Success,
    };

    assert_eq!(response.entity_id, 12345);
    assert_eq!(response.previous_ttl_seconds, 3600);
    assert_eq!(response.new_ttl_seconds, 7200);
    assert_eq!(response.result, TtlOperationResult::Success);
}

#[test]
fn test_ttl_extend_response_structure() {
    let response = TtlExtendResponse {
        entity_id: 67890,
        previous_ttl_seconds: 3600,
        new_ttl_seconds: 10800, // Extended by 2 hours
        result: TtlOperationResult::Success,
    };

    assert_eq!(response.entity_id, 67890);
    assert_eq!(response.previous_ttl_seconds, 3600);
    assert_eq!(response.new_ttl_seconds, 10800);
    assert_eq!(response.result, TtlOperationResult::Success);
}

#[test]
fn test_ttl_clear_response_structure() {
    let response = TtlClearResponse {
        entity_id: 11111,
        previous_ttl_seconds: 86400,
        result: TtlOperationResult::Success,
    };

    assert_eq!(response.entity_id, 11111);
    assert_eq!(response.previous_ttl_seconds, 86400);
    assert_eq!(response.result, TtlOperationResult::Success);
}

#[test]
fn test_ttl_set_response_entity_not_found() {
    let response = TtlSetResponse {
        entity_id: 99999,
        previous_ttl_seconds: 0,
        new_ttl_seconds: 0,
        result: TtlOperationResult::EntityNotFound,
    };

    assert_eq!(response.result, TtlOperationResult::EntityNotFound);
}

#[test]
fn test_ttl_extend_response_entity_not_found() {
    let response = TtlExtendResponse {
        entity_id: 99999,
        previous_ttl_seconds: 0,
        new_ttl_seconds: 0,
        result: TtlOperationResult::EntityNotFound,
    };

    assert_eq!(response.result, TtlOperationResult::EntityNotFound);
}

#[test]
fn test_ttl_clear_response_entity_not_found() {
    let response = TtlClearResponse {
        entity_id: 99999,
        previous_ttl_seconds: 0,
        result: TtlOperationResult::EntityNotFound,
    };

    assert_eq!(response.result, TtlOperationResult::EntityNotFound);
}

#[test]
fn test_ttl_values_zero_means_never_expires() {
    // TTL of 0 means the entity never expires
    let event = GeoEvent::from_options(GeoEventOptions {
        entity_id: id(),
        latitude: 37.7749,
        longitude: -122.4194,
        ttl_seconds: 0, // Never expires
        ..Default::default()
    })
    .unwrap();

    assert_eq!(event.ttl_seconds, 0);
}

#[test]
fn test_ttl_values_max_u32() {
    // Maximum TTL value should be valid
    let event = GeoEvent::from_options(GeoEventOptions {
        entity_id: id(),
        latitude: 37.7749,
        longitude: -122.4194,
        ttl_seconds: u32::MAX,
        ..Default::default()
    })
    .unwrap();

    assert_eq!(event.ttl_seconds, u32::MAX);
}

#[test]
fn test_status_response_load_factor() {
    let status = StatusResponse {
        ram_index_load_pct: 7500,
        ..Default::default()
    };
    assert!((status.load_factor() - 0.75).abs() < 1e-9);

    let status = StatusResponse {
        ram_index_load_pct: 0,
        ..Default::default()
    };
    assert!((status.load_factor() - 0.0).abs() < 1e-9);
}

#[test]
fn test_geo_event_accessors() {
    let event = GeoEvent {
        lat_nano: 37_774_900_000,
        lon_nano: -122_419_400_000,
        altitude_mm: 10_000,
        heading_cdeg: 18000,
        ..Default::default()
    };

    assert!((event.latitude() - 37.7749).abs() < 1e-9);
    assert!((event.longitude() - (-122.4194)).abs() < 1e-9);
    assert!((event.altitude() - 10.0).abs() < 1e-9);
    assert!((event.heading() - 180.0).abs() < 1e-9);
}

#[test]
fn test_geo_event_prepare() {
    let mut event = GeoEvent::from_options(GeoEventOptions {
        entity_id: id(),
        latitude: 37.7749,
        longitude: -122.4194,
        ..Default::default()
    })
    .unwrap();

    assert_eq!(event.id, 0);
    event.prepare();
    assert_ne!(event.id, 0);
    assert_eq!(event.timestamp, 0);
}

#[test]
fn test_geo_error_display() {
    let err = GeoError::InvalidLatitude(91.0);
    assert!(err.to_string().contains("91"));
    assert!(err.to_string().contains("latitude"));

    let err = GeoError::InvalidLongitude(181.0);
    assert!(err.to_string().contains("181"));
    assert!(err.to_string().contains("longitude"));

    let err = GeoError::InvalidRadius(-5.0);
    assert!(err.to_string().contains("-5"));
    assert!(err.to_string().contains("radius"));

    let err = GeoError::InvalidPolygon("too few vertices".into());
    assert!(err.to_string().contains("too few vertices"));
}

#[test]
fn test_geo_client_creation() {
    let client = GeoClient::new(0, "127.0.0.1:3000").unwrap();
    // Placeholder - actual connection would fail without server
    let _ = client;
}
