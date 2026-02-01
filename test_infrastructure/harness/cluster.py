# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""ArcherDB cluster management for testing.

This module provides programmatic control over ArcherDB clusters, enabling
tests to start, stop, and interact with single and multi-node clusters.
"""

import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

import requests

from .log_capture import LogCapture
from .port_allocator import allocate_ports, release_port


def _find_project_root() -> Path:
    """Find the ArcherDB project root directory."""
    # Start from this file's location and walk up
    current = Path(__file__).resolve().parent
    for _ in range(10):  # Max 10 levels up
        if (current / "zig-out" / "bin" / "archerdb").exists():
            return current
        if (current / "build.zig").exists():
            return current
        current = current.parent
    raise RuntimeError("Could not find ArcherDB project root")


@dataclass
class ClusterConfig:
    """Configuration for an ArcherDB cluster.

    Attributes:
        node_count: Number of nodes in the cluster (1, 3, 5, 7...).
        base_port: Base port for node communication. 0 = auto-allocate.
        data_dir: Directory for data files. None = auto-create temp dir.
        cluster_id: Cluster identifier.
        cache_grid: Cache grid size (e.g., "512MiB").
        preserve_on_failure: Keep data after failures for debugging.
        archerdb_bin: Path to archerdb binary. Empty = auto-detect.
        startup_timeout: Timeout in seconds for cluster startup.
        metrics_base_port: Base port for metrics endpoints. 0 = auto-allocate.
    """

    node_count: int = 1
    base_port: int = 0
    data_dir: Optional[str] = None
    cluster_id: int = 0
    cache_grid: str = "512MiB"
    preserve_on_failure: bool = field(default_factory=lambda: os.getenv("PRESERVE_ON_FAILURE", "") == "1")
    archerdb_bin: str = ""
    startup_timeout: float = 60.0
    metrics_base_port: int = 0


class ArcherDBCluster:
    """Manages an ArcherDB cluster for testing.

    Provides lifecycle management (start/stop), health checking, leader detection,
    and log access for ArcherDB clusters of 1 to N nodes.

    Usage:
        config = ClusterConfig(node_count=3)
        with ArcherDBCluster(config) as cluster:
            cluster.wait_for_ready()
            leader = cluster.wait_for_leader()
            # ... run tests ...
    """

    def __init__(self, config: ClusterConfig) -> None:
        """Initialize cluster manager.

        Args:
            config: Cluster configuration.
        """
        self.config = config
        self._processes: Dict[int, subprocess.Popen] = {}
        self._log_captures: Dict[int, LogCapture] = {}
        self._log_threads: Dict[int, threading.Thread] = {}
        self._ports: List[int] = []
        self._metrics_ports: List[int] = []
        self._data_dir: Optional[Path] = None
        self._temp_dir_created = False
        self._started = False
        self._failed = False

        # Resolve binary path
        if config.archerdb_bin:
            self._bin_path = Path(config.archerdb_bin)
        else:
            bin_from_env = os.getenv("ARCHERDB_BIN")
            if bin_from_env:
                self._bin_path = Path(bin_from_env)
            else:
                project_root = _find_project_root()
                self._bin_path = project_root / "zig-out" / "bin" / "archerdb"

        if not self._bin_path.exists():
            raise RuntimeError(f"ArcherDB binary not found: {self._bin_path}")

    def start(self) -> None:
        """Start all cluster nodes.

        Formats data files if needed, starts all replicas, and waits for
        initial process stability.

        Raises:
            RuntimeError: If cluster fails to start.
        """
        if self._started:
            raise RuntimeError("Cluster already started")

        # Setup data directory
        if self.config.data_dir:
            self._data_dir = Path(self.config.data_dir)
            self._data_dir.mkdir(parents=True, exist_ok=True)
        else:
            self._data_dir = Path(tempfile.mkdtemp(prefix="archerdb-test-"))
            self._temp_dir_created = True

        # Allocate ports
        self._ports = allocate_ports(
            self.config.node_count,
            base_port=self.config.base_port,
        )
        self._metrics_ports = allocate_ports(
            self.config.node_count,
            base_port=self.config.metrics_base_port if self.config.metrics_base_port > 0 else self._ports[-1] + 100,
        )

        # Generate addresses string
        addresses = ",".join(str(p) for p in self._ports)

        # Format data files
        for i in range(self.config.node_count):
            data_file = self._data_dir / f"replica-{i}.archerdb"
            if not data_file.exists():
                result = subprocess.run(
                    [
                        str(self._bin_path),
                        "format",
                        f"--cluster={self.config.cluster_id}",
                        f"--replica={i}",
                        f"--replica-count={self.config.node_count}",
                        str(data_file),
                    ],
                    capture_output=True,
                    text=True,
                )
                if result.returncode != 0:
                    raise RuntimeError(f"Format failed for replica {i}: {result.stderr}")

        # Start all replicas
        for i in range(self.config.node_count):
            data_file = self._data_dir / f"replica-{i}.archerdb"
            log_capture = LogCapture()
            self._log_captures[i] = log_capture

            cmd = [
                str(self._bin_path),
                "start",
                f"--addresses={addresses}",
                f"--cache-grid={self.config.cache_grid}",
                f"--metrics-port={self._metrics_ports[i]}",
                "--metrics-bind=127.0.0.1",
                str(data_file),
            ]

            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,  # Line buffered
            )
            self._processes[i] = process

            # Start log capture thread
            def capture_logs(proc: subprocess.Popen, capture: LogCapture) -> None:
                try:
                    if proc.stdout:
                        for line in proc.stdout:
                            capture.write(line)
                except Exception:
                    pass  # Process terminated

            thread = threading.Thread(
                target=capture_logs,
                args=(process, log_capture),
                daemon=True,
            )
            thread.start()
            self._log_threads[i] = thread

        # Brief wait to check initial startup
        time.sleep(0.5)
        for i, proc in self._processes.items():
            if proc.poll() is not None:
                logs = self._log_captures[i].get_logs(max_lines=50)
                self._failed = True
                raise RuntimeError(f"Replica {i} failed to start:\n{logs}")

        self._started = True

    def stop(self) -> None:
        """Stop all cluster nodes and cleanup resources."""
        # Terminate all processes
        for i, proc in self._processes.items():
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

        self._processes.clear()

        # Release ports
        for port in self._ports:
            release_port(port)
        for port in self._metrics_ports:
            release_port(port)
        self._ports.clear()
        self._metrics_ports.clear()

        # Cleanup data directory
        if self._temp_dir_created and self._data_dir:
            if not (self.config.preserve_on_failure and self._failed):
                shutil.rmtree(self._data_dir, ignore_errors=True)
            else:
                print(f"Preserving cluster data at: {self._data_dir}")

        self._started = False

    def wait_for_ready(self, timeout: float = 60.0) -> bool:
        """Wait for all nodes to be ready.

        Args:
            timeout: Maximum time to wait in seconds.

        Returns:
            True if all nodes are ready, False on timeout.
        """
        if not self._started:
            raise RuntimeError("Cluster not started")

        deadline = time.time() + timeout
        nodes_ready = set()

        while time.time() < deadline:
            for i in range(self.config.node_count):
                if i in nodes_ready:
                    continue

                # Check process is still alive
                if self._processes[i].poll() is not None:
                    logs = self._log_captures[i].get_logs(max_lines=50)
                    self._failed = True
                    raise RuntimeError(f"Replica {i} crashed:\n{logs}")

                # Check health endpoint
                try:
                    resp = requests.get(
                        f"http://127.0.0.1:{self._metrics_ports[i]}/health/ready",
                        timeout=1,
                    )
                    if resp.status_code == 200:
                        nodes_ready.add(i)
                except requests.RequestException:
                    pass

            if len(nodes_ready) == self.config.node_count:
                return True

            time.sleep(0.5)

        return False

    def wait_for_leader(self, timeout: float = 60.0) -> Optional[int]:
        """Wait for cluster to be ready for write operations.

        In a single-region cluster, ArcherDB handles Raft leader routing internally,
        so any healthy node can accept writes. This method waits for at least one
        node to be healthy with the primary region role.

        Args:
            timeout: Maximum time to wait in seconds.

        Returns:
            Port of a healthy node ready for writes, or None on timeout.
        """
        if not self._started:
            raise RuntimeError("Cluster not started")

        if self.config.node_count == 1:
            # Single node is always the leader
            return self._ports[0]

        deadline = time.time() + timeout

        while time.time() < deadline:
            for i in range(self.config.node_count):
                try:
                    # Check health endpoint first
                    health_resp = requests.get(
                        f"http://127.0.0.1:{self._metrics_ports[i]}/health/ready",
                        timeout=1,
                    )
                    if health_resp.status_code != 200:
                        continue

                    # Check metrics for region role (primary = can accept writes)
                    resp = requests.get(
                        f"http://127.0.0.1:{self._metrics_ports[i]}/metrics",
                        timeout=1,
                    )
                    if resp.status_code == 200:
                        # Look for: archerdb_region_info{region_id="0",role="primary"} 1
                        if re.search(r'archerdb_region_info\{[^}]*role="primary"[^}]*\}\s+1', resp.text):
                            return self._ports[i]
                except requests.RequestException:
                    pass

            time.sleep(0.5)

        return None

    def get_addresses(self) -> str:
        """Get comma-separated addresses for SDK connection.

        Returns:
            Address string like "3101,3102,3103".
        """
        return ",".join(str(p) for p in self._ports)

    def get_leader_address(self) -> Optional[str]:
        """Get the leader's address for write operations.

        Returns:
            Leader address like "127.0.0.1:3101", or None if no leader.
        """
        leader_port = self.wait_for_leader(timeout=5)
        if leader_port:
            return f"127.0.0.1:{leader_port}"
        return None

    def get_logs(self, replica: int = 0) -> str:
        """Get logs for a specific replica.

        Args:
            replica: Replica index (0-based).

        Returns:
            Log content string.
        """
        if replica not in self._log_captures:
            return ""
        return self._log_captures[replica].get_logs()

    def __enter__(self) -> "ArcherDBCluster":
        """Context manager entry."""
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        """Context manager exit."""
        if exc_type is not None:
            self._failed = True
        self.stop()
