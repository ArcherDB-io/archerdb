# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Test data generation for ArcherDB.

Provides configurable test data generation with various distribution patterns,
size tiers, and randomness options for comprehensive testing scenarios.
"""

import json
import random
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .distributions import (
    city_concentrated,
    hotspot_pattern,
    uniform_distribution,
)


@dataclass
class DatasetConfig:
    """Configuration for test dataset generation.

    Attributes:
        size: Number of events to generate.
        pattern: Distribution pattern ('uniform', 'city_concentrated', 'hotspot').
        cities: List of city names for city_concentrated pattern.
        hotspots: List of (lat, lon) tuples for hotspot pattern.
        concentration: Fraction concentrated in cities (for city_concentrated).
        hotspot_ratio: Fraction at hotspots (for hotspot pattern).
        seed: Random seed. None = truly random (non-reproducible).
        ttl_range: Tuple of (min_ttl, max_ttl) in seconds.
        std_km: Standard deviation in km for Gaussian clusters.
        include_user_data: Whether to include random user_data field.
    """

    size: int = 100
    pattern: str = "uniform"
    cities: Optional[List[str]] = None
    hotspots: Optional[List[Tuple[float, float]]] = None
    concentration: float = 0.8
    hotspot_ratio: float = 0.95
    seed: Optional[int] = None
    ttl_range: Tuple[int, int] = (60, 3600)
    std_km: float = 20.0
    include_user_data: bool = True


def generate_events(config: DatasetConfig) -> List[Dict[str, Any]]:
    """Generate test events based on configuration.

    Args:
        config: Dataset configuration.

    Returns:
        List of event dictionaries matching SDK expected structure:
        {
            "entity_id": str (hex),
            "latitude": float,
            "longitude": float,
            "ttl_seconds": int,
            "user_data": int (optional),
        }

    Raises:
        ValueError: If pattern is unknown or configuration is invalid.
    """
    # Setup RNG
    if config.seed is not None:
        rng = random.Random(config.seed)
    else:
        # Truly random - use current time and random bytes for uniqueness
        rng = random.Random()
        # Re-seed with additional entropy to ensure different results
        rng.seed(time.time_ns() ^ random.getrandbits(64))

    # Generate coordinates based on pattern
    if config.pattern == "uniform":
        coords = uniform_distribution(config.size, rng=rng)
    elif config.pattern == "city_concentrated":
        if not config.cities:
            raise ValueError("city_concentrated pattern requires 'cities' list")
        coords = city_concentrated(
            cities=config.cities,
            count=config.size,
            concentration=config.concentration,
            std_km=config.std_km,
            rng=rng,
        )
    elif config.pattern == "hotspot":
        if not config.hotspots:
            raise ValueError("hotspot pattern requires 'hotspots' list")
        coords = hotspot_pattern(
            hotspot_coords=config.hotspots,
            count=config.size,
            hotspot_ratio=config.hotspot_ratio,
            hotspot_std_km=0.5,  # Very tight clustering for hotspots
            rng=rng,
        )
    else:
        raise ValueError(f"Unknown pattern: {config.pattern}")

    # Generate events
    events = []
    min_ttl, max_ttl = config.ttl_range

    for lat, lon in coords:
        # Generate entity_id using the seeded RNG for reproducibility
        # Format: 32 hex chars (like uuid4 without dashes)
        entity_id = format(rng.getrandbits(128), '032x')

        event: Dict[str, Any] = {
            "entity_id": entity_id,
            "latitude": lat,
            "longitude": lon,
            "ttl_seconds": rng.randint(min_ttl, max_ttl),
        }

        if config.include_user_data:
            event["user_data"] = rng.randint(0, 1000)

        events.append(event)

    return events


def generate_dataset_file(config: DatasetConfig, output_path: str) -> None:
    """Generate events and write to JSON file with metadata.

    Args:
        config: Dataset configuration.
        output_path: Path to output JSON file.
    """
    events = generate_events(config)

    # Build metadata
    metadata = {
        "pattern": config.pattern,
        "size": config.size,
        "seed": config.seed,
        "concentration": config.concentration if config.pattern == "city_concentrated" else None,
        "hotspot_ratio": config.hotspot_ratio if config.pattern == "hotspot" else None,
        "cities": config.cities,
        "hotspots": config.hotspots,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "ttl_range": config.ttl_range,
    }

    output = {
        "metadata": metadata,
        "events": events,
    }

    # Write to file
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(output, f, indent=2)


# Convenience functions for common dataset sizes


def small_dataset(pattern: str = "uniform", seed: int = 42, **kwargs) -> List[Dict[str, Any]]:
    """Generate small dataset (100 events) for quick smoke tests.

    Args:
        pattern: Distribution pattern.
        seed: Random seed (default 42 for reproducibility).
        **kwargs: Additional DatasetConfig options.

    Returns:
        List of 100 events.
    """
    config = DatasetConfig(size=100, pattern=pattern, seed=seed, **kwargs)
    return generate_events(config)


def medium_dataset(pattern: str = "uniform", seed: int = 42, **kwargs) -> List[Dict[str, Any]]:
    """Generate medium dataset (10,000 events) for realistic workloads.

    Args:
        pattern: Distribution pattern.
        seed: Random seed (default 42 for reproducibility).
        **kwargs: Additional DatasetConfig options.

    Returns:
        List of 10,000 events.
    """
    config = DatasetConfig(size=10_000, pattern=pattern, seed=seed, **kwargs)
    return generate_events(config)


def large_dataset(pattern: str = "uniform", seed: int = 42, **kwargs) -> List[Dict[str, Any]]:
    """Generate large dataset (100,000 events) for stress testing.

    Args:
        pattern: Distribution pattern.
        seed: Random seed (default 42 for reproducibility).
        **kwargs: Additional DatasetConfig options.

    Returns:
        List of 100,000 events.
    """
    config = DatasetConfig(size=100_000, pattern=pattern, seed=seed, **kwargs)
    return generate_events(config)
