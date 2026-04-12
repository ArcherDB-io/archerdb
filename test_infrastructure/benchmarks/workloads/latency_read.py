# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Read latency workload for measuring query performance."""

import random
import time
from typing import Iterable, List, Optional, Sequence

from ..executor import Sample
from ..sdk_adapter import build_client, normalize_addresses, parse_entity_id


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
        host: Optional[str],
        port: Optional[int],
        entity_ids: Iterable[str | int],
        timeout: float = 30.0,
        seed: Optional[int] = None,
        *,
        addresses: Optional[Sequence[str]] = None,
        cluster_id: int = 0,
    ) -> None:
        """Initialize read latency workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            entity_ids: List of entity IDs to query (must be pre-inserted).
            timeout: HTTP request timeout in seconds.
            seed: Random seed for entity selection (None = random).
            addresses: Optional list of ArcherDB replica addresses.
            cluster_id: ArcherDB cluster identifier.
        """
        self.cluster_id = cluster_id
        self.entity_ids = [parse_entity_id(entity_id) for entity_id in entity_ids]
        self.timeout = timeout

        self._addresses = normalize_addresses(addresses=addresses, host=host, port=port)
        self._rng = random.Random(seed)
        self._client = None

    def setup(self) -> None:
        """Prepare workload for execution.

        Entity IDs should already be inserted in the database.
        This method validates we have entity IDs and creates the session.
        """
        if not self.entity_ids:
            raise ValueError("No entity_ids provided. Load data first.")

        self._client = build_client(
            cluster_id=self.cluster_id,
            addresses=self._addresses,
            timeout=self.timeout,
        )

    def execute_one(self) -> Sample:
        """Execute one read query and measure latency.

        Randomly selects an entity ID and queries by UUID.

        Returns:
            Sample with latency in nanoseconds and success status.
        """
        if not self.entity_ids:
            raise RuntimeError("Workload not setup. Call setup() first.")

        if self._client is None:
            self._client = build_client(
                cluster_id=self.cluster_id,
                addresses=self._addresses,
                timeout=self.timeout,
            )

        # Select random entity
        entity_id = self._rng.choice(self.entity_ids)

        # Measure query time
        start_ns = time.perf_counter_ns()
        try:
            success = self._client.get_latest_by_uuid(entity_id) is not None
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
