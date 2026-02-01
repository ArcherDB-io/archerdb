# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""City coordinate database for test data generation.

Provides geographic diversity across continents, timezones, and hemispheres
for comprehensive geospatial testing.
"""

from typing import Dict, Any

# Major world cities with geographic diversity
CITIES: Dict[str, Dict[str, Any]] = {
    # North America
    "new_york": {
        "lat": 40.7128,
        "lon": -74.0060,
        "region": "north_america_east",
    },
    "san_francisco": {
        "lat": 37.7749,
        "lon": -122.4194,
        "region": "north_america_west",
    },
    "los_angeles": {
        "lat": 34.0522,
        "lon": -118.2437,
        "region": "north_america_west",
    },
    "chicago": {
        "lat": 41.8781,
        "lon": -87.6298,
        "region": "north_america_central",
    },
    "toronto": {
        "lat": 43.6532,
        "lon": -79.3832,
        "region": "north_america_east",
    },
    "mexico_city": {
        "lat": 19.4326,
        "lon": -99.1332,
        "region": "north_america_south",
    },
    # Europe
    "london": {
        "lat": 51.5074,
        "lon": -0.1278,
        "region": "europe",
    },
    "paris": {
        "lat": 48.8566,
        "lon": 2.3522,
        "region": "europe",
    },
    "berlin": {
        "lat": 52.5200,
        "lon": 13.4050,
        "region": "europe",
    },
    "amsterdam": {
        "lat": 52.3676,
        "lon": 4.9041,
        "region": "europe",
    },
    "moscow": {
        "lat": 55.7558,
        "lon": 37.6173,
        "region": "europe_east",
    },
    # Asia Pacific
    "tokyo": {
        "lat": 35.6762,
        "lon": 139.6503,
        "region": "asia_pacific",
    },
    "singapore": {
        "lat": 1.3521,
        "lon": 103.8198,
        "region": "equatorial",
    },
    "mumbai": {
        "lat": 19.0760,
        "lon": 72.8777,
        "region": "south_asia",
    },
    "beijing": {
        "lat": 39.9042,
        "lon": 116.4074,
        "region": "asia_east",
    },
    "shanghai": {
        "lat": 31.2304,
        "lon": 121.4737,
        "region": "asia_east",
    },
    "hong_kong": {
        "lat": 22.3193,
        "lon": 114.1694,
        "region": "asia_east",
    },
    "seoul": {
        "lat": 37.5665,
        "lon": 126.9780,
        "region": "asia_east",
    },
    "bangkok": {
        "lat": 13.7563,
        "lon": 100.5018,
        "region": "asia_southeast",
    },
    # Southern Hemisphere
    "sydney": {
        "lat": -33.8688,
        "lon": 151.2093,
        "region": "oceania",
    },
    "melbourne": {
        "lat": -37.8136,
        "lon": 144.9631,
        "region": "oceania",
    },
    "sao_paulo": {
        "lat": -23.5505,
        "lon": -46.6333,
        "region": "south_america",
    },
    "buenos_aires": {
        "lat": -34.6037,
        "lon": -58.3816,
        "region": "south_america",
    },
    "cape_town": {
        "lat": -33.9249,
        "lon": 18.4241,
        "region": "africa",
    },
    "johannesburg": {
        "lat": -26.2041,
        "lon": 28.0473,
        "region": "africa",
    },
    "nairobi": {
        "lat": -1.2921,
        "lon": 36.8219,
        "region": "africa_east",
    },
    # Edge cases - extreme locations
    "auckland": {
        "lat": -36.8485,
        "lon": 174.7633,
        "region": "pacific_dateline",
    },
    "reykjavik": {
        "lat": 64.1466,
        "lon": -21.9426,
        "region": "high_latitude",
    },
    "anchorage": {
        "lat": 61.2181,
        "lon": -149.9003,
        "region": "high_latitude",
    },
}

# Geographic edge cases for boundary testing
EDGE_CASES: Dict[str, Dict[str, float]] = {
    "north_pole": {
        "lat": 90.0,
        "lon": 0.0,
    },
    "south_pole": {
        "lat": -90.0,
        "lon": 0.0,
    },
    "antimeridian_east": {
        "lat": 0.0,
        "lon": 180.0,
    },
    "antimeridian_west": {
        "lat": 0.0,
        "lon": -180.0,
    },
    "null_island": {
        "lat": 0.0,
        "lon": 0.0,
    },
    "max_lat_east": {
        "lat": 89.999,
        "lon": 179.999,
    },
    "max_lat_west": {
        "lat": 89.999,
        "lon": -179.999,
    },
    "min_lat_east": {
        "lat": -89.999,
        "lon": 179.999,
    },
    "min_lat_west": {
        "lat": -89.999,
        "lon": -179.999,
    },
}


def get_city_coords(city_name: str) -> tuple:
    """Get (lat, lon) tuple for a city name.

    Args:
        city_name: Name of city (lowercase with underscores).

    Returns:
        Tuple of (latitude, longitude).

    Raises:
        KeyError: If city name not found.
    """
    city = CITIES[city_name]
    return (city["lat"], city["lon"])


def list_cities_by_region(region: str) -> list:
    """Get list of city names in a specific region.

    Args:
        region: Region name to filter by.

    Returns:
        List of city names in the region.
    """
    return [name for name, data in CITIES.items() if data["region"] == region]


def get_regions() -> list:
    """Get list of all unique region names.

    Returns:
        Sorted list of region names.
    """
    return sorted(set(data["region"] for data in CITIES.values()))
