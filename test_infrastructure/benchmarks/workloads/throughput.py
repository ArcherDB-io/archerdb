# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Throughput workload for measuring insert events/sec."""

import time
from typing import List, Optional, Sequence

from ..executor import Sample
from ..sdk_adapter import batch_to_geo_events, build_client, normalize_addresses
from ...generators.data_generator import DatasetConfig, generate_events


class ThroughputWorkload:
    """Workload for measuring insert throughput.

    Pre-generates events in batches and measures time to insert each batch.
    Throughput is calculated as total_events / total_time.

    Usage:
        workload = ThroughputWorkload(
            host="127.0.0.1",
            port=3101,
            data_config=DatasetConfig(size=100000, pattern="uniform"),
        )
        workload.setup()
        sample = workload.execute_one()
        throughput = workload.get_events_per_batch() / (sample.latency_ns / 1e9)
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
        """Initialize throughput workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            data_config: Configuration for test data generation.
            batch_size: Number of events per batch insert.
            timeout: HTTP request timeout in seconds.
            addresses: Optional list of ArcherDB replica addresses.
            cluster_id: ArcherDB cluster identifier.
        """
        self.cluster_id = cluster_id
        self.data_config = data_config
        self.batch_size = batch_size
        self.timeout = timeout

        self._addresses = normalize_addresses(addresses=addresses, host=host, port=port)
        self._batches: List[list] = []
        self._batch_index = 0
        self._client = None

    def setup(self) -> None:
        """Pre-generate events and create batches.

        Generates all events upfront to avoid generation time affecting
        throughput measurements.
        """
        # Generate all events
        events = generate_events(self.data_config)

        # Split into batches
        self._batches = []
        for i in range(0, len(events), self.batch_size):
            batch = batch_to_geo_events(events[i:i + self.batch_size])
            self._batches.append(batch)

        self._batch_index = 0

        self._client = build_client(
            cluster_id=self.cluster_id,
            addresses=self._addresses,
            timeout=self.timeout,
        )

    def execute_one(self) -> Sample:
        """Execute one batch insert and measure latency.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if not self._batches:
            raise RuntimeError("Workload not setup. Call setup() first.")

        if self._client is None:
            self._client = build_client(
                cluster_id=self.cluster_id,
                addresses=self._addresses,
                timeout=self.timeout,
            )

        # Get current batch (cycle through batches)
        batch = self._batches[self._batch_index % len(self._batches)]
        self._batch_index += 1

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

    def get_events_per_batch(self) -> int:
        """Return the number of events per batch for throughput calculation.

        Returns:
            Batch size (events per insert operation).
        """
        return self.batch_size

    def cleanup(self) -> None:
        """Clean up resources."""
        if self._client:
            self._client.close()
            self._client = None
        self._batches.clear()
        self._batch_index = 0
