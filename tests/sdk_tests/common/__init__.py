# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Common utilities for SDK operation tests.

This package provides shared test infrastructure including:
- fixture_adapter: Cross-SDK fixture loading and conversion helpers
"""

from .fixture_adapter import (
    load_operation_fixture,
    convert_fixture_events,
    get_case_by_name,
    filter_cases_by_tag,
    generate_unique_entity_id,
    clean_database,
    assert_json_match,
    setup_test_data,
)

__all__ = [
    "load_operation_fixture",
    "convert_fixture_events",
    "get_case_by_name",
    "filter_cases_by_tag",
    "generate_unique_entity_id",
    "clean_database",
    "assert_json_match",
    "setup_test_data",
]
