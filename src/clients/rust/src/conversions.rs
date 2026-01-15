// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

//! Type conversions for ArcherDB Rust SDK.
//!
//! This module provides conversions between Rust types and native C bindings.

use crate::arch_client as tbc;
use crate::{GeoEvent, GeoEventFlags, InsertGeoEventResult};

// ============================================================================
// GeoEvent Conversions
// ============================================================================

impl From<tbc::geo_event_t> for GeoEvent {
    fn from(c: tbc::geo_event_t) -> Self {
        GeoEvent {
            id: c.id,
            entity_id: c.entity_id,
            correlation_id: c.correlation_id,
            user_data: c.user_data,
            lat_nano: c.lat_nano,
            lon_nano: c.lon_nano,
            group_id: c.group_id,
            timestamp: c.timestamp,
            altitude_mm: c.altitude_mm,
            velocity_mms: c.velocity_mms,
            ttl_seconds: c.ttl_seconds,
            accuracy_mm: c.accuracy_mm,
            heading_cdeg: c.heading_cdeg,
            flags: GeoEventFlags::from_bits_truncate(c.flags),
            reserved: c.reserved,
        }
    }
}

impl From<GeoEvent> for tbc::geo_event_t {
    fn from(e: GeoEvent) -> Self {
        tbc::geo_event_t {
            id: e.id,
            entity_id: e.entity_id,
            correlation_id: e.correlation_id,
            user_data: e.user_data,
            lat_nano: e.lat_nano,
            lon_nano: e.lon_nano,
            group_id: e.group_id,
            timestamp: e.timestamp,
            altitude_mm: e.altitude_mm,
            velocity_mms: e.velocity_mms,
            ttl_seconds: e.ttl_seconds,
            accuracy_mm: e.accuracy_mm,
            heading_cdeg: e.heading_cdeg,
            flags: e.flags.bits(),
            reserved: e.reserved,
        }
    }
}

// ============================================================================
// InsertGeoEventResult Conversions
// ============================================================================

impl From<tbc::INSERT_GEO_EVENT_RESULT> for InsertGeoEventResult {
    fn from(value: tbc::INSERT_GEO_EVENT_RESULT) -> Self {
        use tbc::*;
        match value {
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_OK => InsertGeoEventResult::Ok,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LINKED_EVENT_FAILED => InsertGeoEventResult::LinkedEventFailed,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LINKED_EVENT_CHAIN_OPEN => InsertGeoEventResult::LinkedEventChainOpen,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_TIMESTAMP_MUST_BE_ZERO => InsertGeoEventResult::TimestampMustBeZero,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_RESERVED_FIELD => InsertGeoEventResult::ReservedField,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_RESERVED_FLAG => InsertGeoEventResult::ReservedFlag,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_ID_MUST_NOT_BE_ZERO => InsertGeoEventResult::IdMustNotBeZero,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_ENTITY_ID_MUST_NOT_BE_ZERO => InsertGeoEventResult::EntityIdMustNotBeZero,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_INVALID_COORDINATES => InsertGeoEventResult::InvalidCoordinates,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LAT_OUT_OF_RANGE => InsertGeoEventResult::LatOutOfRange,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LON_OUT_OF_RANGE => InsertGeoEventResult::LonOutOfRange,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_EXISTS_WITH_DIFFERENT_ENTITY_ID => InsertGeoEventResult::ExistsWithDifferentEntityId,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_EXISTS_WITH_DIFFERENT_COORDINATES => InsertGeoEventResult::ExistsWithDifferentCoordinates,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_EXISTS => InsertGeoEventResult::Exists,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_HEADING_OUT_OF_RANGE => InsertGeoEventResult::HeadingOutOfRange,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_TTL_INVALID => InsertGeoEventResult::TtlInvalid,
            INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_ENTITY_ID_MUST_NOT_BE_INT_MAX => InsertGeoEventResult::EntityIdMustNotBeIntMax,
            _ => InsertGeoEventResult::Ok,
        }
    }
}

impl From<InsertGeoEventResult> for tbc::INSERT_GEO_EVENT_RESULT {
    fn from(value: InsertGeoEventResult) -> Self {
        use tbc::*;
        match value {
            InsertGeoEventResult::Ok => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_OK,
            InsertGeoEventResult::LinkedEventFailed => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LINKED_EVENT_FAILED,
            InsertGeoEventResult::LinkedEventChainOpen => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LINKED_EVENT_CHAIN_OPEN,
            InsertGeoEventResult::TimestampMustBeZero => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_TIMESTAMP_MUST_BE_ZERO,
            InsertGeoEventResult::ReservedField => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_RESERVED_FIELD,
            InsertGeoEventResult::ReservedFlag => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_RESERVED_FLAG,
            InsertGeoEventResult::IdMustNotBeZero => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_ID_MUST_NOT_BE_ZERO,
            InsertGeoEventResult::EntityIdMustNotBeZero => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_ENTITY_ID_MUST_NOT_BE_ZERO,
            InsertGeoEventResult::InvalidCoordinates => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_INVALID_COORDINATES,
            InsertGeoEventResult::LatOutOfRange => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LAT_OUT_OF_RANGE,
            InsertGeoEventResult::LonOutOfRange => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_LON_OUT_OF_RANGE,
            InsertGeoEventResult::ExistsWithDifferentEntityId => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_EXISTS_WITH_DIFFERENT_ENTITY_ID,
            InsertGeoEventResult::ExistsWithDifferentCoordinates => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_EXISTS_WITH_DIFFERENT_COORDINATES,
            InsertGeoEventResult::Exists => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_EXISTS,
            InsertGeoEventResult::HeadingOutOfRange => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_HEADING_OUT_OF_RANGE,
            InsertGeoEventResult::TtlInvalid => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_TTL_INVALID,
            InsertGeoEventResult::EntityIdMustNotBeIntMax => INSERT_GEO_EVENT_RESULT_INSERT_GEO_EVENT_ENTITY_ID_MUST_NOT_BE_INT_MAX,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_geo_event_roundtrip() {
        let event = GeoEvent {
            entity_id: 12345,
            lat_nano: 37_774_900_000,
            lon_nano: -122_419_400_000,
            group_id: 1,
            ttl_seconds: 86400,
            flags: GeoEventFlags::STATIONARY,
            ..Default::default()
        };

        let c_event: tbc::geo_event_t = event.into();
        let back: GeoEvent = c_event.into();

        assert_eq!(back.entity_id, 12345);
        assert_eq!(back.lat_nano, 37_774_900_000);
        assert_eq!(back.lon_nano, -122_419_400_000);
        assert_eq!(back.group_id, 1);
        assert_eq!(back.ttl_seconds, 86400);
        assert!(back.flags.contains(GeoEventFlags::STATIONARY));
    }

    #[test]
    fn test_insert_result_roundtrip() {
        let result = InsertGeoEventResult::InvalidCoordinates;
        let c_result: tbc::INSERT_GEO_EVENT_RESULT = result.into();
        let back: InsertGeoEventResult = c_result.into();
        assert_eq!(back, InsertGeoEventResult::InvalidCoordinates);
    }
}
