# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Uniform distribution workload for benchmarking."""

import random
import time
import uuid
from typing import Any, Dict, List, Optional, Sequence

from ..executor import Sample
from ..sdk_adapter import batch_to_geo_events, build_client, normalize_addresses
from ...generators.data_generator import DatasetConfig


class UniformWorkload:
    """Workload using uniform random distribution across globe.

    Generates events with lat/lon uniformly distributed:
    - lat: [-90, +90]
    - lon: [-180, +180]

    Uses seeded RNG for reproducibility.

    Usage:
        workload = UniformWorkload(
            host="127.0.0.1",
            port=3101,
            data_config=DatasetConfig(size=10000),
            batch_size=1000,
        )
        workload.setup()
        sample = workload.execute_one()
    """

    def __init__(
        self,
        host: Optional[str],
        port: Optional[int],
        data_config: DatasetConfig,
        batch_size: int = 1000,
        timeout: float = 30.0,
        *,
        addresses: Optional[Sequence[str]] = None,
        cluster_id: int = 0,
    ) -> None:
        """Initialize uniform workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            data_config: Configuration for test data generation.
            batch_size: Number of events per batch insert.
            timeout: HTTP request timeout in seconds.
        """
        self.cluster_id = cluster_id
        self.data_config = data_config
        self.batch_size = batch_size
        self.timeout = timeout

        self._addresses = normalize_addresses(addresses=addresses, host=host, port=port)
        self._client = None
        self._rng: Optional[random.Random] = None

    def setup(self) -> None:
        """Initialize session and RNG.

        Creates HTTP session for connection pooling and seeds RNG
        for reproducible data generation.
        """
        self._client = build_client(
            cluster_id=self.cluster_id,
            addresses=self._addresses,
            timeout=self.timeout,
        )

        # Use seeded RNG for reproducibility
        seed = self.data_config.seed if self.data_config.seed is not None else 42
        self._rng = random.Random(seed)

    def execute_one(self) -> Sample:
        """Execute one batch insert and measure latency.

        Generates a batch of events with uniform distribution and inserts them.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if self._rng is None:
            raise RuntimeError("Workload not setup. Call setup() first.")
        if self._client is None:
            self._client = build_client(
                cluster_id=self.cluster_id,
                addresses=self._addresses,
                timeout=self.timeout,
            )

        # Generate batch with uniform distribution
        batch = batch_to_geo_events(self._generate_uniform_batch())

        # Measure insert time
        start_ns = time.perf_counter_ns()
        try:
            errors = self._client.insert_events(batch)
            success = len(errors) == 0
        except Exception:
            success = False
        end_ns = time.perf_counter_ns()

        latency_ns = end_ns - start_ns
        return Sample(
            latency_ns=latency_ns,
            timestamp_ns=end_ns,
            success=success,
        )

    def _generate_uniform_batch(self) -> List[Dict[str, Any]]:
        """Generate batch of events with uniform distribution.

        Returns:
            List of event dicts ready for insertion.
        """
        if self._rng is None:
            raise RuntimeError("RNG not initialized")

        events = []
        for _ in range(self.batch_size):
            # Uniform distribution across entire valid range
            lat = self._rng.uniform(-90.0, 90.0)
            lon = self._rng.uniform(-180.0, 180.0)

            event = {
                "entity_id": str(uuid.uuid4()),
                "latitude": lat,
                "longitude": lon,
                "correlation_id": self._rng.randint(0, 2**31 - 1),
                "user_data": 0,
            }
            events.append(event)

        return events

    def cleanup(self) -> None:
        """Clean up resources."""
        if self._client:
            self._client.close()
            self._client = None
        self._rng = None

    def get_pattern_name(self) -> str:
        """Return workload pattern name.

        Returns:
            Pattern identifier string.
        """
        return "uniform"

    def get_events_per_batch(self) -> int:
        """Return the number of events per batch.

        Returns:
            Batch size (events per insert operation).
        """
        return self.batch_size
