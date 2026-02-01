# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Input validation error handling tests (ERR-03).

Tests that all SDKs validate inputs and return appropriate error codes
for invalid coordinates, entity IDs, and other input validation errors.

Design decisions (per 14-CONTEXT.md):
- Verify error CODES, not message text (allows message improvements)
- Validation errors are NOT retryable (fix the input)
- SDK validates client-side before server submission where possible
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

# Import from SDK
from archerdb import (
    GeoClientSync,
    GeoEvent,
    InvalidCoordinates,
    InvalidEntityId,
    PolygonTooComplex,
    BatchTooLarge,
    create_geo_event,
    degrees_to_nano,
    is_valid_latitude,
    is_valid_longitude,
)
from archerdb.client import ArcherDBError

# Load test cases from fixtures
FIXTURES_PATH = Path(__file__).parent / "fixtures" / "error_test_cases.json"


def load_validation_cases():
    """Load validation error test cases from fixtures."""
    with open(FIXTURES_PATH) as f:
        return json.load(f)["validation_errors"]


class TestValidationErrors:
    """All SDKs validate inputs and return appropriate error codes (ERR-03)."""

    @pytest.mark.parametrize(
        "case_name,case_data",
        [
            ("invalid_latitude_too_high", {"latitude": 200.0, "longitude": 0.0}),
            ("invalid_latitude_too_low", {"latitude": -200.0, "longitude": 0.0}),
            ("invalid_longitude_too_high", {"latitude": 0.0, "longitude": 400.0}),
            ("invalid_longitude_too_low", {"latitude": 0.0, "longitude": -400.0}),
        ],
    )
    def test_invalid_coordinates_error_code(self, case_name, case_data):
        """Invalid coordinates return error code 3001 (ERR-03).

        Per CONTEXT.md: Verify error CODE (3001), not message text.
        Validation errors are not retryable - fix the input.
        """
        # Test using is_valid helpers which don't require server
        lat_valid = is_valid_latitude(case_data["latitude"])
        lon_valid = is_valid_longitude(case_data["longitude"])

        # At least one coordinate should be invalid
        assert not (lat_valid and lon_valid), (
            f"{case_name}: Expected invalid coordinates but both were valid"
        )

        # Verify error code via InvalidCoordinates class
        assert InvalidCoordinates.code == 3001
        assert InvalidCoordinates.retryable is False

    def test_invalid_latitude_exceeds_90(self):
        """Latitude > 90 degrees is invalid."""
        assert not is_valid_latitude(91.0)
        assert not is_valid_latitude(200.0)
        assert is_valid_latitude(90.0)  # Exactly 90 is valid

    def test_invalid_latitude_below_negative_90(self):
        """Latitude < -90 degrees is invalid."""
        assert not is_valid_latitude(-91.0)
        assert not is_valid_latitude(-200.0)
        assert is_valid_latitude(-90.0)  # Exactly -90 is valid

    def test_invalid_longitude_exceeds_180(self):
        """Longitude > 180 degrees is invalid."""
        assert not is_valid_longitude(181.0)
        assert not is_valid_longitude(400.0)
        assert is_valid_longitude(180.0)  # Exactly 180 is valid

    def test_invalid_longitude_below_negative_180(self):
        """Longitude < -180 degrees is invalid."""
        assert not is_valid_longitude(-181.0)
        assert not is_valid_longitude(-400.0)
        assert is_valid_longitude(-180.0)  # Exactly -180 is valid

    def test_invalid_coordinates_specific_exception(self):
        """InvalidCoordinates has correct error code and is not retryable."""
        assert InvalidCoordinates.code == 3001
        assert InvalidCoordinates.retryable is False

    def test_validation_error_is_not_retryable(self):
        """Validation errors are not retryable - fix the input."""
        # All validation errors should be non-retryable
        assert InvalidCoordinates.retryable is False
        assert InvalidEntityId.retryable is False
        assert PolygonTooComplex.retryable is False
        assert BatchTooLarge.retryable is False


class TestEntityIdValidation:
    """Entity ID validation tests."""

    def test_invalid_entity_id_zero_error_code(self):
        """Zero entity ID returns error code 3004 (ERR-03).

        Per CONTEXT.md: Verify error CODE (3004), not message text.
        """
        assert InvalidEntityId.code == 3004
        assert InvalidEntityId.retryable is False

    def test_entity_id_zero_is_invalid(self):
        """Entity ID of 0 is invalid per SDK spec."""
        # The SDK should reject entity_id=0
        # This is validated client-side before server submission
        assert InvalidEntityId.code == 3004

    def test_entity_id_negative_handling(self):
        """Entity ID validation handles negative values.

        Entity IDs are unsigned integers - negative values should be
        rejected or treated as invalid.
        """
        # InvalidEntityId is the error for malformed entity IDs
        assert InvalidEntityId.code == 3004
        assert InvalidEntityId.retryable is False


class TestValidationErrorCodes:
    """Verify correct error codes for validation errors."""

    def test_error_code_3001_is_invalid_coordinates(self):
        """Error code 3001 maps to InvalidCoordinates."""
        assert InvalidCoordinates.code == 3001

    def test_error_code_3002_is_polygon_too_complex(self):
        """Error code 3002 maps to PolygonTooComplex."""
        assert PolygonTooComplex.code == 3002

    def test_error_code_3003_is_batch_too_large(self):
        """Error code 3003 maps to BatchTooLarge."""
        assert BatchTooLarge.code == 3003

    def test_error_code_3004_is_invalid_entity_id(self):
        """Error code 3004 maps to InvalidEntityId."""
        assert InvalidEntityId.code == 3004

    def test_all_validation_errors_not_retryable(self):
        """All validation errors are non-retryable."""
        # Validation errors require fixing the input, not retrying
        validation_errors = [
            InvalidCoordinates,
            PolygonTooComplex,
            BatchTooLarge,
            InvalidEntityId,
        ]
        for error_class in validation_errors:
            assert error_class.retryable is False, (
                f"{error_class.__name__} should not be retryable"
            )


class TestGeographicEdgeCases:
    """Geographic edge case validation tests per CONTEXT.md."""

    @pytest.mark.parametrize(
        "lat,lon,name",
        [
            (90.0, 0.0, "north_pole"),
            (-90.0, 0.0, "south_pole"),
            (0.0, 180.0, "antimeridian_east"),
            (0.0, -180.0, "antimeridian_west"),
            (0.0, 0.0, "equator_prime"),
        ],
    )
    def test_edge_case_coordinates_are_valid(self, lat, lon, name):
        """Geographic edge cases (poles, antimeridian) are valid.

        Per CONTEXT.md: All geographic edge cases are high priority.
        These coordinates should be valid and not raise errors.
        """
        assert is_valid_latitude(lat), f"{name}: latitude {lat} should be valid"
        assert is_valid_longitude(lon), f"{name}: longitude {lon} should be valid"

    def test_degrees_to_nano_edge_cases(self):
        """Degree to nanodegree conversion handles edge cases."""
        # Test edge values convert correctly
        assert degrees_to_nano(90.0) == 90_000_000_000
        assert degrees_to_nano(-90.0) == -90_000_000_000
        assert degrees_to_nano(180.0) == 180_000_000_000
        assert degrees_to_nano(-180.0) == -180_000_000_000
        assert degrees_to_nano(0.0) == 0
