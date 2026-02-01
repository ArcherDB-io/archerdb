# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Topology testing infrastructure.

This package provides tools for testing ArcherDB across different cluster
configurations (1/3/5/6 nodes) with failover and partition handling.

Classes:
    NetworkPartitioner: Simulate network partitions using iptables.
    FailoverResult: Result data from a failover operation.
    FailoverSimulator: Trigger leader failures and measure recovery.
    ConsistencyChecker: Verify data consistency across nodes.
    TopologyTestRunner: Orchestrate full test suite across topologies.
"""

from .consistency import ConsistencyChecker
from .failover import FailoverResult, FailoverSimulator
from .partition import NetworkPartitioner
from .runner import TopologyTestRunner

__all__ = [
    "NetworkPartitioner",
    "FailoverResult",
    "FailoverSimulator",
    "ConsistencyChecker",
    "TopologyTestRunner",
]
