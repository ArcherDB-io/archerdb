# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""City-concentrated workload for benchmarking.

Generates events clustered around major world cities (hotspots),
modeling realistic geographic distribution patterns.
"""

import math
import random
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple

import requests

from ..executor import Sample
from ...generators.data_generator import DatasetConfig
from ...generators.city_coordinates import CITIES


class CityConcentratedWorkload:
    """Workload using city-concentrated distribution with hotspots.

    Generates events clustered around major cities using Gaussian
    distribution. Each event is placed within a configurable radius
    of a randomly selected city.

    Uses city coordinates from test_infrastructure/generators/city_coordinates.py.

    Usage:
        workload = CityConcentratedWorkload(
            host="127.0.0.1",
            port=3101,
            data_config=DatasetConfig(size=10000),
            batch_size=1000,
            hotspot_radius_km=50,
        )
        workload.setup()
        sample = workload.execute_one()
    """

    # Earth radius in km for coordinate calculations
    EARTH_RADIUS_KM = 6371.0

    def __init__(
        self,
        host: str,
        port: int,
        data_config: DatasetConfig,
        batch_size: int = 1000,
        hotspot_radius_km: float = 50.0,
        timeout: float = 30.0,
    ) -> None:
        """Initialize city-concentrated workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            data_config: Configuration for test data generation.
            batch_size: Number of events per batch insert.
            hotspot_radius_km: Maximum distance from city center in km.
            timeout: HTTP request timeout in seconds.
        """
        self.host = host
        self.port = port
        self.data_config = data_config
        self.batch_size = batch_size
        self.hotspot_radius_km = hotspot_radius_km
        self.timeout = timeout

        self._base_url = f"http://{host}:{port}"
        self._session: Optional[requests.Session] = None
        self._rng: Optional[random.Random] = None
        self._city_coords: List[Tuple[float, float]] = []

    def setup(self) -> None:
        """Initialize session, RNG, and load city coordinates.

        Creates HTTP session for connection pooling, seeds RNG
        for reproducibility, and loads city coordinates.
        """
        self._session = requests.Session()

        # Use seeded RNG for reproducibility
        seed = self.data_config.seed if self.data_config.seed is not None else 42
        self._rng = random.Random(seed)

        # Load city coordinates
        self._city_coords = [
            (city["lat"], city["lon"])
            for city in CITIES.values()
        ]

    def execute_one(self) -> Sample:
        """Execute one batch insert and measure latency.

        Generates a batch of events clustered around cities and inserts them.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if self._session is None or self._rng is None:
            raise RuntimeError("Workload not setup. Call setup() first.")

        # Generate batch with city-concentrated distribution
        batch = self._generate_concentrated_batch()

        # Measure insert time
        start_ns = time.perf_counter_ns()
        try:
            response = self._session.post(
                f"{self._base_url}/insert",
                json=batch,
                timeout=self.timeout,
            )
            success = response.status_code == 200
        except requests.RequestException:
            success = False
        end_ns = time.perf_counter_ns()

        latency_ns = end_ns - start_ns
        return Sample(
            latency_ns=latency_ns,
            timestamp_ns=end_ns,
            success=success,
        )

    def _generate_concentrated_batch(self) -> List[Dict[str, Any]]:
        """Generate batch of events clustered around cities.

        Uses Gaussian distribution around city centers with
        std_dev = radius/3 (so ~99.7% of points within radius).

        Returns:
            List of event dicts ready for insertion.
        """
        if self._rng is None:
            raise RuntimeError("RNG not initialized")

        events = []
        # Gaussian std_dev: 3 sigma = radius
        std_dev_km = self.hotspot_radius_km / 3.0

        for _ in range(self.batch_size):
            # Select random city
            city_lat, city_lon = self._rng.choice(self._city_coords)

            # Generate offset using Gaussian distribution
            offset_lat_km = self._rng.gauss(0, std_dev_km)
            offset_lon_km = self._rng.gauss(0, std_dev_km)

            # Convert km offset to degrees
            lat, lon = self._offset_coords(
                city_lat, city_lon,
                offset_lat_km, offset_lon_km
            )

            # Clamp to valid range
            lat = max(-90.0, min(90.0, lat))
            lon = max(-180.0, min(180.0, lon))
            # Handle wraparound for longitude
            if lon > 180.0:
                lon -= 360.0
            elif lon < -180.0:
                lon += 360.0

            event = {
                "entity_id": str(uuid.uuid4()),
                "latitude": lat,
                "longitude": lon,
                "correlation_id": self._rng.randint(0, 2**31 - 1),
                "user_data": 0,
            }
            events.append(event)

        return events

    def _offset_coords(
        self,
        lat: float,
        lon: float,
        offset_lat_km: float,
        offset_lon_km: float,
    ) -> Tuple[float, float]:
        """Calculate new coordinates from offset in km.

        Args:
            lat: Center latitude in degrees.
            lon: Center longitude in degrees.
            offset_lat_km: North/south offset in km.
            offset_lon_km: East/west offset in km.

        Returns:
            Tuple of (new_lat, new_lon) in degrees.
        """
        # Convert lat offset: 1 degree latitude ~ 111 km
        new_lat = lat + (offset_lat_km / 111.0)

        # Convert lon offset: depends on latitude
        # 1 degree longitude ~ 111 * cos(lat) km
        lat_rad = math.radians(lat)
        km_per_deg_lon = 111.0 * math.cos(lat_rad)

        if km_per_deg_lon > 0.1:  # Avoid division by near-zero at poles
            new_lon = lon + (offset_lon_km / km_per_deg_lon)
        else:
            new_lon = lon  # Near poles, longitude is meaningless

        return (new_lat, new_lon)

    def cleanup(self) -> None:
        """Clean up resources."""
        if self._session:
            self._session.close()
            self._session = None
        self._rng = None
        self._city_coords.clear()

    def get_pattern_name(self) -> str:
        """Return workload pattern name.

        Returns:
            Pattern identifier string.
        """
        return "city_concentrated"

    def get_events_per_batch(self) -> int:
        """Return the number of events per batch.

        Returns:
            Batch size (events per insert operation).
        """
        return self.batch_size
