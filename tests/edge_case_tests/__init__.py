# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Edge case test suite for ArcherDB.

This module provides comprehensive edge case testing covering:

Requirements Covered:
    EDGE-01: Polar coordinate handling (lat=+/-90, longitude convergence)
    EDGE-02: Anti-meridian crossing (lon=+/-180, date line spanning)
    EDGE-03: Concave polygon queries (point-in-polygon edge cases)
    EDGE-04: Large batch inserts (10K entities in single batch)
    EDGE-05: High volume testing (100K+ events)
    EDGE-06: TTL expiration verification
    EDGE-07: Empty result handling (valid responses, not errors)
    EDGE-08: Adversarial workload patterns (boundary conditions)

Test Files:
    test_polar_coordinates.py - EDGE-01
    test_antimeridian.py - EDGE-02
    test_concave_polygon.py - EDGE-03
    test_scale.py - EDGE-04, EDGE-05
    test_ttl_expiration.py - EDGE-06
    test_empty_results.py - EDGE-07
    test_adversarial.py - EDGE-08

Usage:
    # Run all edge case tests (requires cluster)
    ARCHERDB_INTEGRATION=1 pytest tests/edge_case_tests/

    # Run specific test file
    ARCHERDB_INTEGRATION=1 pytest tests/edge_case_tests/test_polar_coordinates.py

    # Collect tests only (no cluster needed)
    pytest tests/edge_case_tests/ --collect-only

Fixtures:
    Uses fixtures from tests/parity_tests/fixtures/edge_cases/ for
    polar_coordinates.json, antimeridian.json, equator_prime_meridian.json.

    Additional fixtures in tests/edge_case_tests/fixtures/ for
    concave_polygons.json and scale_test_config.json.
"""
