# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Throughput workload for measuring insert events/sec.

Measures batch insert throughput by sending batches of events via HTTP POST
and recording latency per batch operation.
"""

import time
from typing import Any, Dict, List, Optional

import requests

from ..executor import Sample
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
        host: str,
        port: int,
        data_config: DatasetConfig,
        batch_size: int = 1000,
        timeout: float = 30.0,
    ) -> None:
        """Initialize throughput workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            data_config: Configuration for test data generation.
            batch_size: Number of events per batch insert.
            timeout: HTTP request timeout in seconds.
        """
        self.host = host
        self.port = port
        self.data_config = data_config
        self.batch_size = batch_size
        self.timeout = timeout

        self._base_url = f"http://{host}:{port}"
        self._batches: List[List[Dict[str, Any]]] = []
        self._batch_index = 0
        self._session: Optional[requests.Session] = None

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
            batch = events[i:i + self.batch_size]
            self._batches.append(batch)

        self._batch_index = 0

        # Create reusable session for connection pooling
        self._session = requests.Session()

    def execute_one(self) -> Sample:
        """Execute one batch insert and measure latency.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if not self._batches:
            raise RuntimeError("Workload not setup. Call setup() first.")

        if self._session is None:
            self._session = requests.Session()

        # Get current batch (cycle through batches)
        batch = self._batches[self._batch_index % len(self._batches)]
        self._batch_index += 1

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

    def get_events_per_batch(self) -> int:
        """Return the number of events per batch for throughput calculation.

        Returns:
            Batch size (events per insert operation).
        """
        return self.batch_size

    def cleanup(self) -> None:
        """Clean up resources."""
        if self._session:
            self._session.close()
            self._session = None
        self._batches.clear()
        self._batch_index = 0
