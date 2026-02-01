# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Test data generation utilities for ArcherDB.

This package provides tools for generating test datasets with various
distribution patterns:

- Uniform: Even distribution across coordinate space
- City-concentrated: Realistic urban clustering (Gaussian around city centers)
- Hotspot: Extreme concentration for stress testing

Example:
    from test_infrastructure.generators import generate_events, DatasetConfig

    # Generate 1000 events clustered around SF and Tokyo
    config = DatasetConfig(
        size=1000,
        pattern='city_concentrated',
        cities=['san_francisco', 'tokyo'],
        concentration=0.8,
        seed=42,  # Reproducible
    )
    events = generate_events(config)
"""

from .city_coordinates import CITIES, EDGE_CASES
from .data_generator import DatasetConfig, generate_events, generate_dataset_file
from .distributions import (
    city_concentrated,
    gaussian_cluster,
    hotspot_pattern,
    uniform_distribution,
)

__all__ = [
    # Data generator
    "DatasetConfig",
    "generate_events",
    "generate_dataset_file",
    # City data
    "CITIES",
    "EDGE_CASES",
    # Distribution functions
    "city_concentrated",
    "gaussian_cluster",
    "hotspot_pattern",
    "uniform_distribution",
]
