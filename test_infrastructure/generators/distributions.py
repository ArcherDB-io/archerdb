# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Geospatial distribution patterns for test data generation.

Provides various distribution patterns:
- Uniform: Even distribution across coordinate space
- Gaussian: Normal distribution around a center point
- City-concentrated: Mix of city clusters and scattered points
- Hotspot: Extreme concentration for stress testing
"""

import math
import random
from typing import List, Tuple, Optional

from .city_coordinates import CITIES, get_city_coords


def uniform_distribution(
    count: int,
    lat_range: Tuple[float, float] = (-90.0, 90.0),
    lon_range: Tuple[float, float] = (-180.0, 180.0),
    rng: Optional[random.Random] = None,
) -> List[Tuple[float, float]]:
    """Generate uniformly distributed lat/lon pairs.

    Args:
        count: Number of points to generate.
        lat_range: Tuple of (min_lat, max_lat).
        lon_range: Tuple of (min_lon, max_lon).
        rng: Random number generator. If None, uses global random.

    Returns:
        List of (lat, lon) tuples.
    """
    if rng is None:
        rng = random.Random()

    lat_min, lat_max = lat_range
    lon_min, lon_max = lon_range

    points = []
    for _ in range(count):
        lat = rng.uniform(lat_min, lat_max)
        lon = rng.uniform(lon_min, lon_max)
        points.append((lat, lon))

    return points


def gaussian_cluster(
    center_lat: float,
    center_lon: float,
    count: int,
    std_km: float = 10.0,
    rng: Optional[random.Random] = None,
) -> List[Tuple[float, float]]:
    """Generate points around a center with Gaussian distribution.

    Points are distributed with a 2D normal distribution where std_km
    controls the spread in kilometers.

    Args:
        center_lat: Center latitude.
        center_lon: Center longitude.
        count: Number of points to generate.
        std_km: Standard deviation in kilometers (10km = city center, 50km = metro).
        rng: Random number generator. If None, uses global random.

    Returns:
        List of (lat, lon) tuples, clamped to valid coordinate ranges.
    """
    if rng is None:
        rng = random.Random()

    # Convert km to degrees (approximate)
    # 1 degree latitude ~= 111 km
    # 1 degree longitude ~= 111 km * cos(lat)
    lat_std = std_km / 111.0
    cos_lat = math.cos(math.radians(center_lat))
    lon_std = std_km / (111.0 * max(cos_lat, 0.01))  # Avoid division by near-zero

    points = []
    for _ in range(count):
        lat = rng.gauss(center_lat, lat_std)
        lon = rng.gauss(center_lon, lon_std)

        # Clamp to valid ranges
        lat = max(-90.0, min(90.0, lat))

        # Handle longitude wraparound
        while lon > 180.0:
            lon -= 360.0
        while lon < -180.0:
            lon += 360.0

        points.append((lat, lon))

    return points


def city_concentrated(
    cities: List[str],
    count: int,
    concentration: float = 0.8,
    std_km: float = 20.0,
    rng: Optional[random.Random] = None,
) -> List[Tuple[float, float]]:
    """Generate points concentrated around selected cities.

    Args:
        cities: List of city names (must be in CITIES database).
        count: Total number of points to generate.
        concentration: Fraction concentrated in cities (0.8 = 80% in cities).
        std_km: Standard deviation for city clusters in km.
        rng: Random number generator. If None, uses global random.

    Returns:
        List of (lat, lon) tuples.

    Raises:
        KeyError: If a city name is not found.
    """
    if rng is None:
        rng = random.Random()

    if not cities:
        # No cities specified, return uniform distribution
        return uniform_distribution(count, rng=rng)

    city_count = int(count * concentration)
    scattered_count = count - city_count

    points = []

    # Distribute city events evenly across cities
    events_per_city = city_count // len(cities)
    remainder = city_count % len(cities)

    for i, city_name in enumerate(cities):
        city_coords = get_city_coords(city_name)
        n = events_per_city + (1 if i < remainder else 0)
        city_points = gaussian_cluster(
            city_coords[0], city_coords[1], n, std_km=std_km, rng=rng
        )
        points.extend(city_points)

    # Add scattered events
    scattered = uniform_distribution(scattered_count, rng=rng)
    points.extend(scattered)

    # Shuffle to mix city and scattered events
    rng.shuffle(points)

    return points


def hotspot_pattern(
    hotspot_coords: List[Tuple[float, float]],
    count: int,
    hotspot_ratio: float = 0.95,
    hotspot_std_km: float = 0.5,
    rng: Optional[random.Random] = None,
) -> List[Tuple[float, float]]:
    """Generate points with extreme concentration at hotspots.

    Used for stress testing worst-case concentration scenarios.

    Args:
        hotspot_coords: List of (lat, lon) hotspot center coordinates.
        count: Total number of points to generate.
        hotspot_ratio: Fraction at hotspots (0.95 = 95% at hotspots).
        hotspot_std_km: Standard deviation for hotspot clusters (very tight).
        rng: Random number generator. If None, uses global random.

    Returns:
        List of (lat, lon) tuples with hotspot_ratio concentrated at hotspots.
    """
    if rng is None:
        rng = random.Random()

    if not hotspot_coords:
        # No hotspots, return uniform
        return uniform_distribution(count, rng=rng)

    hotspot_count = int(count * hotspot_ratio)
    scattered_count = count - hotspot_count

    points = []

    # Distribute hotspot events evenly across hotspots
    events_per_hotspot = hotspot_count // len(hotspot_coords)
    remainder = hotspot_count % len(hotspot_coords)

    for i, (lat, lon) in enumerate(hotspot_coords):
        n = events_per_hotspot + (1 if i < remainder else 0)
        hotspot_points = gaussian_cluster(
            lat, lon, n, std_km=hotspot_std_km, rng=rng
        )
        points.extend(hotspot_points)

    # Add scattered events
    scattered = uniform_distribution(scattered_count, rng=rng)
    points.extend(scattered)

    # Shuffle to mix hotspot and scattered events
    rng.shuffle(points)

    return points
