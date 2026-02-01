# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Parity test fixtures for edge cases.

This package contains test fixtures for geographic edge cases
that must be verified across all SDKs:

- Polar regions (latitude +/-90 where longitude is ambiguous)
- Antimeridian (longitude +/-180, date line crossing)
- Equator and prime meridian (zero crossings)
"""
