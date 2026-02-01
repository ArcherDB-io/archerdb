# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Network partition simulation using iptables.

This module provides the NetworkPartitioner class for simulating network
partitions in cluster tests. It uses iptables DROP rules to block TCP
traffic between node groups.

WARNING: Requires root/sudo privileges for iptables manipulation.
Use SKIP_PARTITION_TESTS=1 to skip in unprivileged environments.
"""

import os
import subprocess
from typing import List


class NetworkPartitioner:
    """Simulate network partitions using iptables.

    Creates network partitions by blocking TCP traffic between specified
    node groups. Requires root/sudo privileges.

    Usage:
        ports = cluster.get_ports()  # [3101, 3102, 3103]
        partitioner = NetworkPartitioner(ports)

        # Isolate node 0 from nodes 1, 2
        partitioner.partition(minority=[0], majority=[1, 2])

        # ... run tests ...

        # Restore connectivity
        partitioner.heal()

    As context manager:
        with NetworkPartitioner(ports) as p:
            p.partition(minority=[0], majority=[1, 2])
            # ... tests ...
        # Automatically heals on exit
    """

    def __init__(self, ports: List[int]) -> None:
        """Initialize with cluster ports.

        Args:
            ports: List of cluster node ports.
        """
        self.ports = ports
        self._active_rules: List[tuple] = []

    def partition(self, minority: List[int], majority: List[int]) -> None:
        """Create network partition between node groups.

        Blocks all TCP traffic between minority and majority groups
        in both directions using iptables DROP rules.

        Args:
            minority: List of node indices in minority partition.
            majority: List of node indices in majority partition.

        Raises:
            subprocess.CalledProcessError: If iptables command fails.
        """
        # Drop packets from minority -> majority
        for m in minority:
            for j in majority:
                self._block_port_pair(self.ports[m], self.ports[j])

        # Drop packets from majority -> minority
        for j in majority:
            for m in minority:
                self._block_port_pair(self.ports[j], self.ports[m])

    def _block_port_pair(self, from_port: int, to_port: int) -> None:
        """Block TCP traffic between two ports.

        Args:
            from_port: Source port.
            to_port: Destination port.
        """
        # Block by source port
        subprocess.run(
            [
                "sudo", "iptables", "-A", "INPUT", "-p", "tcp",
                "--sport", str(from_port), "--dport", str(to_port), "-j", "DROP"
            ],
            check=True,
            capture_output=True,
        )
        self._active_rules.append((from_port, to_port))

    def heal(self) -> None:
        """Remove all partition rules, restoring connectivity.

        Flushes the INPUT chain to remove all DROP rules created
        by this partitioner.
        """
        if self._active_rules:
            # Flush INPUT chain rules
            subprocess.run(
                ["sudo", "iptables", "-F", "INPUT"],
                check=True,
                capture_output=True,
            )
            self._active_rules.clear()

    @staticmethod
    def is_available() -> bool:
        """Check if iptables is available and we have sudo privileges.

        Returns:
            True if iptables can be used for partition simulation.
        """
        # Check if SKIP_PARTITION_TESTS is set
        if os.getenv("SKIP_PARTITION_TESTS", "") == "1":
            return False

        try:
            # Check sudo access without password
            result = subprocess.run(
                ["sudo", "-n", "iptables", "-L"],
                capture_output=True,
                timeout=5,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def __enter__(self) -> "NetworkPartitioner":
        """Context manager entry."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        """Context manager exit - ensures partition is healed."""
        self.heal()
