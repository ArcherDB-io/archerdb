# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Dynamic port allocation for parallel test safety.

This module provides functions to find and allocate available ports dynamically,
ensuring parallel test runs don't conflict on port usage.
"""

import socket
import threading
from typing import List

# Lock to prevent race conditions when allocating multiple ports
_allocation_lock = threading.Lock()

# Track allocated ports to avoid reuse within same process
_allocated_ports: set = set()


def find_available_port(start: int = 3100, end: int = 4100) -> int:
    """Find a single available port using socket binding.

    Args:
        start: Beginning of port range to search (inclusive).
        end: End of port range to search (exclusive).

    Returns:
        An available port number.

    Raises:
        RuntimeError: If no available port found in range.
    """
    with _allocation_lock:
        for port in range(start, end):
            if port in _allocated_ports:
                continue
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind(("127.0.0.1", port))
                    _allocated_ports.add(port)
                    return port
            except OSError:
                continue
        raise RuntimeError(f"No available port found in range {start}-{end}")


def allocate_ports(count: int, base_port: int = 0) -> List[int]:
    """Allocate multiple consecutive-ish ports for cluster nodes.

    Args:
        count: Number of ports to allocate.
        base_port: Starting port hint. If 0, auto-select from default range.

    Returns:
        List of available port numbers (not necessarily consecutive).

    Raises:
        RuntimeError: If unable to allocate requested number of ports.
    """
    ports: List[int] = []
    start = base_port if base_port > 0 else 3100

    for _ in range(count):
        port = find_available_port(start=start, end=start + 1000)
        ports.append(port)
        start = port + 1

    return ports


def release_port(port: int) -> None:
    """Release a previously allocated port for reuse.

    Args:
        port: Port number to release.
    """
    with _allocation_lock:
        _allocated_ports.discard(port)


def release_all_ports() -> None:
    """Release all tracked ports. Useful for test cleanup."""
    with _allocation_lock:
        _allocated_ports.clear()
