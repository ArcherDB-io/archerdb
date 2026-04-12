# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Mixed workload for interleaved read/write operations."""

import random
import time
from dataclasses import dataclass
from typing import List, Optional, Sequence

from ..executor import Sample
from ..sdk_adapter import batch_to_geo_events, build_client, normalize_addresses
from ...generators.data_generator import DatasetConfig, generate_events


@dataclass
class MixedSample(Sample):
    """Extended sample with operation type tracking.

    Attributes:
        latency_ns: Latency in nanoseconds.
        timestamp_ns: Timestamp when sample was taken.
        success: Whether the operation succeeded.
        operation_type: "read" or "write".
    """

    operation_type: str = "read"


class MixedWorkload:
    """Workload for mixed read/write operations.

    Interleaves reads and writes based on read_ratio:
    - read_ratio=0.8 means 80% reads, 20% writes
    - read_ratio=1.0 means 100% reads
    - read_ratio=0.0 means 100% writes

    Per CONTEXT.md: "Mixed workloads - combine reads and writes in realistic
    ratios (e.g., 80% reads, 20% writes)"

    Usage:
        workload = MixedWorkload(
            host="127.0.0.1",
            port=3101,
            data_config=DatasetConfig(size=10000, pattern="uniform"),
            read_ratio=0.8,  # 80% reads, 20% writes
        )
        workload.setup()
        sample = workload.execute_one()
        # sample.operation_type tells you if it was a read or write
    """

    def __init__(
        self,
        host: Optional[str],
        port: Optional[int],
        data_config: DatasetConfig,
        read_ratio: float = 0.8,
        timeout: float = 30.0,
        seed: Optional[int] = None,
        *,
        addresses: Optional[Sequence[str]] = None,
        cluster_id: int = 0,
    ) -> None:
        """Initialize mixed workload.

        Args:
            host: ArcherDB host address.
            port: ArcherDB port number.
            data_config: Configuration for test data generation.
            read_ratio: Fraction of reads (0.8 = 80% reads, 20% writes).
            timeout: HTTP request timeout in seconds.
            seed: Random seed for operation selection (None = random).
            addresses: Optional list of ArcherDB replica addresses.
            cluster_id: ArcherDB cluster identifier.
        """
        if not 0.0 <= read_ratio <= 1.0:
            raise ValueError(f"read_ratio must be 0.0-1.0, got {read_ratio}")

        self.cluster_id = cluster_id
        self.data_config = data_config
        self.read_ratio = read_ratio
        self.timeout = timeout

        self._addresses = normalize_addresses(addresses=addresses, host=host, port=port)
        self._rng = random.Random(seed)

        # Pre-generated data
        self._read_entity_ids: List[int] = []
        self._write_events: List[object] = []
        self._write_index = 0

        # Sample tracking for separate read/write metrics
        self._read_samples: List[MixedSample] = []
        self._write_samples: List[MixedSample] = []

        self._client = None

    def setup(self) -> None:
        """Pre-insert initial data for reads and generate events for writes.

        Generates two sets of events:
        1. Events to insert initially (for read queries)
        2. Events for write operations during the benchmark
        """
        # Generate initial data for reads (50% of data_size)
        initial_config = DatasetConfig(
            size=self.data_config.size // 2,
            pattern=self.data_config.pattern,
            seed=self.data_config.seed,
            cities=self.data_config.cities,
            hotspots=self.data_config.hotspots,
        )
        initial_events = batch_to_geo_events(generate_events(initial_config))
        self._read_entity_ids = [event.entity_id for event in initial_events]

        # Generate events for writes (50% of data_size)
        write_seed = (self.data_config.seed + 1) if self.data_config.seed else None
        write_config = DatasetConfig(
            size=self.data_config.size // 2,
            pattern=self.data_config.pattern,
            seed=write_seed,
            cities=self.data_config.cities,
            hotspots=self.data_config.hotspots,
        )
        self._write_events = batch_to_geo_events(generate_events(write_config))
        self._write_index = 0

        self._client = build_client(
            cluster_id=self.cluster_id,
            addresses=self._addresses,
            timeout=self.timeout,
        )

        # Pre-insert initial events for reads
        if initial_events:
            try:
                _ = self._client.insert_events(initial_events)
            except Exception:
                pass  # Continue even if initial insert fails

        # Clear sample tracking
        self._read_samples.clear()
        self._write_samples.clear()

    def execute_one(self) -> MixedSample:
        """Execute one read or write operation based on read_ratio.

        Returns:
            MixedSample with latency, success status, and operation_type.
        """
        if not self._read_entity_ids and not self._write_events:
            raise RuntimeError("Workload not setup. Call setup() first.")

        if self._client is None:
            self._client = build_client(
                cluster_id=self.cluster_id,
                addresses=self._addresses,
                timeout=self.timeout,
            )

        # Decide operation type based on read_ratio
        is_read = self._rng.random() < self.read_ratio

        if is_read and self._read_entity_ids:
            sample = self._execute_read()
        elif self._write_events:
            sample = self._execute_write()
        elif self._read_entity_ids:
            # Fallback to read if no write events left
            sample = self._execute_read()
        else:
            # No data available
            sample = MixedSample(
                latency_ns=0,
                timestamp_ns=time.perf_counter_ns(),
                success=False,
                operation_type="none",
            )

        # Track sample
        if sample.operation_type == "read":
            self._read_samples.append(sample)
        elif sample.operation_type == "write":
            self._write_samples.append(sample)

        return sample

    def _execute_read(self) -> MixedSample:
        """Execute a read operation."""
        entity_id = self._rng.choice(self._read_entity_ids)

        start_ns = time.perf_counter_ns()
        try:
            success = self._client.get_latest_by_uuid(entity_id) is not None
        except Exception:
            success = False
        end_ns = time.perf_counter_ns()

        return MixedSample(
            latency_ns=end_ns - start_ns,
            timestamp_ns=end_ns,
            success=success,
            operation_type="read",
        )

    def _execute_write(self) -> MixedSample:
        """Execute a write operation."""
        event = self._write_events[self._write_index % len(self._write_events)]
        self._write_index += 1

        # Add written entity to read pool for future reads
        self._read_entity_ids.append(event.entity_id)

        start_ns = time.perf_counter_ns()
        try:
            errors = self._client.insert_events([event])
            success = len(errors) == 0
        except Exception:
            success = False
        end_ns = time.perf_counter_ns()

        return MixedSample(
            latency_ns=end_ns - start_ns,
            timestamp_ns=end_ns,
            success=success,
            operation_type="write",
        )

    def get_read_samples(self) -> List[MixedSample]:
        """Get all read operation samples.

        Returns:
            List of samples from read operations.
        """
        return list(self._read_samples)

    def get_write_samples(self) -> List[MixedSample]:
        """Get all write operation samples.

        Returns:
            List of samples from write operations.
        """
        return list(self._write_samples)

    def cleanup(self) -> None:
        """Clean up resources."""
        if self._client:
            self._client.close()
            self._client = None
        self._read_entity_ids.clear()
        self._write_events.clear()
        self._read_samples.clear()
        self._write_samples.clear()
        self._write_index = 0
