# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Write latency workload for measuring single insert performance."""

import time
from typing import List, Optional, Sequence

from ..executor import Sample
from ..sdk_adapter import batch_to_geo_events, build_client, normalize_addresses
from ...generators.data_generator import DatasetConfig, generate_events


class LatencyWriteWorkload:
    """Workload for measuring write latency.

    Inserts single events (not batches) to measure per-operation write latency.
    Pre-generates events to avoid generation overhead during measurement.

    Usage:
        workload = LatencyWriteWorkload(
            host="127.0.0.1",
            port=3101,
            data_config=DatasetConfig(size=10000, pattern="uniform"),
        )
        workload.setup()
        sample = workload.execute_one()
        # sample.latency_ns contains single insert time in nanoseconds
    """

    def __init__(
        self,
        host: Optional[str],
        port: Optional[int],
        data_config: DatasetConfig,
        timeout: float = 30.0,
        *,
        addresses: Optional[Sequence[str]] = None,
        cluster_id: int = 0,
    ) -> None:
        """Initialize write latency workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            data_config: Configuration for test data generation.
            timeout: HTTP request timeout in seconds.
            addresses: Optional list of ArcherDB replica addresses.
            cluster_id: ArcherDB cluster identifier.
        """
        self.cluster_id = cluster_id
        self.data_config = data_config
        self.timeout = timeout

        self._addresses = normalize_addresses(addresses=addresses, host=host, port=port)
        self._events: List[object] = []
        self._event_index = 0
        self._client = None

    def setup(self) -> None:
        """Pre-generate events for single inserts.

        Generates all events upfront to avoid generation time affecting
        latency measurements.
        """
        # Generate events
        self._events = batch_to_geo_events(generate_events(self.data_config))
        self._event_index = 0

        self._client = build_client(
            cluster_id=self.cluster_id,
            addresses=self._addresses,
            timeout=self.timeout,
        )

    def execute_one(self) -> Sample:
        """Execute one single-event insert and measure latency.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if not self._events:
            raise RuntimeError("Workload not setup. Call setup() first.")

        if self._client is None:
            self._client = build_client(
                cluster_id=self.cluster_id,
                addresses=self._addresses,
                timeout=self.timeout,
            )

        # Get current event (cycle through events)
        event = self._events[self._event_index % len(self._events)]
        self._event_index += 1

        # Insert single event (as array of 1)
        start_ns = time.perf_counter_ns()
        try:
            errors = self._client.insert_events([event])
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

    def cleanup(self) -> None:
        """Clean up resources."""
        if self._client:
            self._client.close()
            self._client = None
        self._events.clear()
        self._event_index = 0
