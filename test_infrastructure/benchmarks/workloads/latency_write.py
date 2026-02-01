# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Write latency workload for measuring single insert performance.

Measures write latency by inserting single events and recording response time.
"""

import time
from typing import Any, Dict, List, Optional

import requests

from ..executor import Sample
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
        host: str,
        port: int,
        data_config: DatasetConfig,
        timeout: float = 30.0,
    ) -> None:
        """Initialize write latency workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            data_config: Configuration for test data generation.
            timeout: HTTP request timeout in seconds.
        """
        self.host = host
        self.port = port
        self.data_config = data_config
        self.timeout = timeout

        self._base_url = f"http://{host}:{port}"
        self._events: List[Dict[str, Any]] = []
        self._event_index = 0
        self._session: Optional[requests.Session] = None

    def setup(self) -> None:
        """Pre-generate events for single inserts.

        Generates all events upfront to avoid generation time affecting
        latency measurements.
        """
        # Generate events
        self._events = generate_events(self.data_config)
        self._event_index = 0

        # Create reusable session for connection pooling
        self._session = requests.Session()

    def execute_one(self) -> Sample:
        """Execute one single-event insert and measure latency.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if not self._events:
            raise RuntimeError("Workload not setup. Call setup() first.")

        if self._session is None:
            self._session = requests.Session()

        # Get current event (cycle through events)
        event = self._events[self._event_index % len(self._events)]
        self._event_index += 1

        # Insert single event (as array of 1)
        start_ns = time.perf_counter_ns()
        try:
            response = self._session.post(
                f"{self._base_url}/insert",
                json=[event],  # Single event in array
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

    def cleanup(self) -> None:
        """Clean up resources."""
        if self._session:
            self._session.close()
            self._session = None
        self._events.clear()
        self._event_index = 0
