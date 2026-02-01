# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Failover simulation and recovery measurement.

This module provides the FailoverSimulator class for testing leader
failures and measuring cluster recovery times.

Per CONTEXT.md decisions:
- Both graceful (SIGTERM) and ungraceful (SIGKILL) scenarios
- Random timing (mid-operation and between operations)
- Multiple sequential failovers per test
- Recovery SLA enforcement
"""

import time
from dataclasses import dataclass
from typing import TYPE_CHECKING, Callable, Optional

if TYPE_CHECKING:
    from test_infrastructure.harness import ArcherDBCluster


@dataclass
class FailoverResult:
    """Result of a failover operation.

    Attributes:
        old_leader: Replica index of the leader that was stopped.
        new_leader: Replica index of the new leader, or None if election failed.
        recovery_time_ms: Time in milliseconds from leader stop to new leader.
        data_loss: True if acknowledged writes were lost (checked separately).
        operations_during_failover: Total operations attempted during failover.
        operations_succeeded: Number of operations that succeeded during failover.
    """

    old_leader: int
    new_leader: Optional[int]
    recovery_time_ms: float
    data_loss: bool
    operations_during_failover: int
    operations_succeeded: int


class FailoverSimulator:
    """Simulates leader failures and measures recovery.

    Recovery SLA targets per RESEARCH.md:
    - 3-node: < 10 seconds
    - 5-node: < 15 seconds
    - 6-node: < 20 seconds

    Usage:
        simulator = FailoverSimulator(cluster, recovery_timeout_sec=15.0)

        # Trigger graceful leader failure
        result = simulator.trigger_leader_failure(graceful=True)
        assert result.new_leader is not None
        assert result.recovery_time_ms < 10000  # 10 second SLA

        # Trigger crash (SIGKILL)
        result = simulator.trigger_leader_failure(graceful=False)
    """

    def __init__(
        self,
        cluster: "ArcherDBCluster",
        recovery_timeout_sec: float = 30.0,
    ) -> None:
        """Initialize failover simulator.

        Args:
            cluster: Running cluster to test.
            recovery_timeout_sec: Maximum time to wait for recovery.
        """
        self.cluster = cluster
        self.recovery_timeout = recovery_timeout_sec

    def trigger_leader_failure(
        self,
        graceful: bool = True,
    ) -> FailoverResult:
        """Trigger leader node failure and measure recovery.

        Args:
            graceful: True for SIGTERM, False for SIGKILL (crash).

        Returns:
            FailoverResult with timing and data integrity info.

        Raises:
            RuntimeError: If no leader found to fail.
        """
        # Find current leader
        old_leader = self.cluster.get_leader_replica()
        if old_leader is None:
            raise RuntimeError("No leader found to fail")

        # Record time and stop leader
        start_time = time.time()
        self.cluster.stop_node(old_leader, graceful=graceful)

        # Wait for new leader election
        new_leader = self._wait_for_new_leader(old_leader)
        recovery_time = (time.time() - start_time) * 1000

        return FailoverResult(
            old_leader=old_leader,
            new_leader=new_leader,
            recovery_time_ms=recovery_time,
            data_loss=False,  # Verified separately by ConsistencyChecker
            operations_during_failover=0,
            operations_succeeded=0,
        )

    def _wait_for_new_leader(self, old_leader: int) -> Optional[int]:
        """Wait for a new leader different from the old one.

        Args:
            old_leader: Replica index of the old leader to exclude.

        Returns:
            Replica index of the new leader, or None on timeout.
        """
        deadline = time.time() + self.recovery_timeout
        while time.time() < deadline:
            new_leader = self.cluster.get_leader_replica()
            if new_leader is not None and new_leader != old_leader:
                return new_leader
            time.sleep(0.5)
        return None

    def run_operations_during_failover(
        self,
        operation: Callable[[], bool],
        duration_sec: float = 5.0,
    ) -> tuple:
        """Run operations while failover is in progress.

        This method continuously executes the provided operation for the
        specified duration, counting successes and failures. Useful for
        testing client behavior during failover.

        Args:
            operation: Callable that returns True on success, False on failure.
            duration_sec: How long to run operations.

        Returns:
            Tuple of (total_attempted, successful).
        """
        total = 0
        successful = 0
        deadline = time.time() + duration_sec

        while time.time() < deadline:
            total += 1
            try:
                if operation():
                    successful += 1
            except Exception:
                pass  # Expected during failover

        return total, successful

    def trigger_sequential_failovers(
        self,
        count: int = 2,
        graceful: bool = True,
        restart_old_leader: bool = True,
    ) -> list:
        """Trigger multiple sequential failovers.

        Per CONTEXT.md: "Multiple sequential failovers per test - validate
        repeated recovery and state consistency"

        Args:
            count: Number of failovers to trigger.
            graceful: True for SIGTERM, False for SIGKILL.
            restart_old_leader: Whether to restart the old leader after each failover.

        Returns:
            List of FailoverResult for each failover.
        """
        results = []

        for i in range(count):
            result = self.trigger_leader_failure(graceful=graceful)
            results.append(result)

            if restart_old_leader and result.new_leader is not None:
                # Wait a bit for cluster to stabilize
                time.sleep(2.0)
                # Restart the old leader so it can participate in future failovers
                self.cluster.start_node(result.old_leader)
                # Wait for it to rejoin
                time.sleep(2.0)

        return results
