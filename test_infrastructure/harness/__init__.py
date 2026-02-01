# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""ArcherDB test harness for programmatic cluster management.

This package provides tools for starting, stopping, and managing ArcherDB
clusters in test environments. Key features:

- Automatic port allocation for parallel test safety
- Health check polling and leader election detection
- Log capture for debugging test failures
- Context manager support for automatic cleanup

Example:
    from test_infrastructure.harness import ArcherDBCluster, ClusterConfig

    config = ClusterConfig(node_count=3)
    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready()
        leader = cluster.wait_for_leader()
        # ... run tests ...
"""

from .cluster import ArcherDBCluster, ClusterConfig
from .port_allocator import allocate_ports, find_available_port

__all__ = [
    "ArcherDBCluster",
    "ClusterConfig",
    "allocate_ports",
    "find_available_port",
]
