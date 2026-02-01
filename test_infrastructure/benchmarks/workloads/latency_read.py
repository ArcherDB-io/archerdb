# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Read latency workload for measuring query performance.

Measures read latency by querying entities by UUID and recording response time.
"""

import random
import time
from typing import List, Optional

import requests

from ..executor import Sample


class LatencyReadWorkload:
    """Workload for measuring read latency.

    Queries pre-inserted entities by UUID and measures response time.
    Entity IDs must already exist in the database before running.

    Usage:
        workload = LatencyReadWorkload(
            host="127.0.0.1",
            port=3101,
            entity_ids=["abc123...", "def456...", ...],
        )
        workload.setup()
        sample = workload.execute_one()
        # sample.latency_ns contains query time in nanoseconds
    """

    def __init__(
        self,
        host: str,
        port: int,
        entity_ids: List[str],
        timeout: float = 30.0,
        seed: Optional[int] = None,
    ) -> None:
        """Initialize read latency workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            entity_ids: List of entity IDs to query (must be pre-inserted).
            timeout: HTTP request timeout in seconds.
            seed: Random seed for entity selection (None = random).
        """
        self.host = host
        self.port = port
        self.entity_ids = entity_ids
        self.timeout = timeout

        self._base_url = f"http://{host}:{port}"
        self._rng = random.Random(seed)
        self._session: Optional[requests.Session] = None

    def setup(self) -> None:
        """Prepare workload for execution.

        Entity IDs should already be inserted in the database.
        This method validates we have entity IDs and creates the session.
        """
        if not self.entity_ids:
            raise ValueError("No entity_ids provided. Load data first.")

        # Create reusable session for connection pooling
        self._session = requests.Session()

    def execute_one(self) -> Sample:
        """Execute one read query and measure latency.

        Randomly selects an entity ID and queries by UUID.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if not self.entity_ids:
            raise RuntimeError("Workload not setup. Call setup() first.")

        if self._session is None:
            self._session = requests.Session()

        # Select random entity
        entity_id = self._rng.choice(self.entity_ids)

        # Measure query time
        start_ns = time.perf_counter_ns()
        try:
            response = self._session.get(
                f"{self._base_url}/query/uuid/{entity_id}",
                timeout=self.timeout,
            )
            # Success if 200 (found) or 404 (not found but query worked)
            success = response.status_code in (200, 404)
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
