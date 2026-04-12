# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""ArcherDB cluster management for testing.

This module provides programmatic control over ArcherDB clusters, enabling
tests to start, stop, and interact with single and multi-node clusters.
"""

import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from urllib import error as urllib_error
from urllib import request as urllib_request

from .log_capture import LogCapture
from .port_allocator import allocate_ports, release_port


class _HttpRequestError(Exception):
    """Raised when a local HTTP probe fails."""


@dataclass
class _HttpResponse:
    status_code: int
    text: str


def _http_get(url: str, timeout: float = 1.0) -> _HttpResponse:
    """Issue a small local HTTP GET without third-party dependencies."""
    try:
        with urllib_request.urlopen(url, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            return _HttpResponse(status_code=response.getcode(), text=body)
    except urllib_error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return _HttpResponse(status_code=exc.code, text=body)
    except (urllib_error.URLError, TimeoutError, OSError) as exc:
        raise _HttpRequestError(str(exc)) from exc


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
        replica_count: Number of voting replicas. If omitted, defaults to
            node_count. Additional nodes beyond replica_count are formatted as
            standbys/learners.
        base_port: Base port for node communication. 0 = auto-allocate.
        data_dir: Directory for data files. None = auto-create temp dir.
        cluster_id: Cluster identifier.
        cache_grid: Cache grid size (e.g., "64MiB").
        ram_index_size: RAM index budget (e.g., "8MiB").
        memory_lsm_manifest: LSM manifest memory budget (e.g., "64MiB").
        preserve_on_failure: Keep data after failures for debugging.
        archerdb_bin: Path to archerdb binary. Empty = auto-detect.
        startup_timeout: Timeout in seconds for cluster startup.
        metrics_base_port: Base port for metrics endpoints. 0 = auto-allocate.
        primary_head_start_timeout: Optional time to wait for replica 0 to bind its
            data-plane port before starting the remaining replicas.
    """

    node_count: int = 1
    replica_count: Optional[int] = None
    base_port: int = 0
    data_dir: Optional[str] = None
    cluster_id: int = 0
    cache_grid: str = "64MiB"
    ram_index_size: str = "8MiB"
    memory_lsm_manifest: str = "64MiB"
    preserve_on_failure: bool = field(default_factory=lambda: os.getenv("PRESERVE_ON_FAILURE", "") == "1")
    archerdb_bin: str = ""
    startup_timeout: float = 60.0
    metrics_base_port: int = 0
    primary_head_start_timeout: float = 0.0


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
        replica_count = self.config.replica_count or self.config.node_count
        if replica_count <= 0 or replica_count > self.config.node_count:
            raise RuntimeError(
                "replica_count must be between 1 and node_count "
                f"(got replica_count={replica_count}, node_count={self.config.node_count})"
            )

        self._ports = allocate_ports(
            self.config.node_count,
            base_port=self.config.base_port,
        )
        self._metrics_ports = allocate_ports(
            self.config.node_count,
            base_port=self.config.metrics_base_port if self.config.metrics_base_port > 0 else self._ports[-1] + 100,
        )

        # Generate addresses string
        addresses = ",".join(f"127.0.0.1:{p}" for p in self._ports)

        # Format data files
        for i in range(self.config.node_count):
            data_file = self._data_dir / f"replica-{i}.archerdb"
            if not data_file.exists():
                result = subprocess.run(
                    [
                        str(self._bin_path),
                        "format",
                        "--development=true",
                        f"--cluster={self.config.cluster_id}",
                        f"--replica-count={replica_count}",
                        f"--{'replica' if i < replica_count else 'standby'}={i}",
                        str(data_file),
                    ],
                    capture_output=True,
                    text=True,
                )
                if result.returncode != 0:
                    raise RuntimeError(f"Format failed for replica {i}: {result.stderr}")

        try:
            # Start all replicas
            for i in range(self.config.node_count):
                data_file = self._data_dir / f"replica-{i}.archerdb"
                log_capture = LogCapture()
                self._log_captures[i] = log_capture

                cmd = [
                    str(self._bin_path),
                    "start",
                    "--development=true",
                    "--experimental=true",
                    f"--addresses={addresses}",
                    f"--replica-count={replica_count}",
                    f"--cache-grid={self.config.cache_grid}",
                    f"--ram-index-size={self.config.ram_index_size}",
                    f"--memory-lsm-manifest={self.config.memory_lsm_manifest}",
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

                # On larger local clusters, stagger replica startup until each
                # process has finished its expensive local init path. Waiting
                # only for a bound TCP listener was too early: the next wave of
                # replicas could still overlap forest init and push the shared
                # machine into OOM/SIGKILL territory.
                if self.config.node_count >= 5:
                    start_timeout = (
                        self.config.primary_head_start_timeout
                        if self.config.primary_head_start_timeout > 0
                        else min(120.0, self.config.startup_timeout)
                    )
                    if not self._wait_for_node_started(replica=i, timeout=start_timeout):
                        logs = self._log_captures[i].get_logs(max_lines=120)
                        self._failed = True
                        raise RuntimeError(
                            f"Replica {i} did not finish startup init "
                            f"(timeout={start_timeout:.0f}s):\n{logs}"
                        )

            # Brief wait to check initial startup
            time.sleep(0.5)
            for i, proc in self._processes.items():
                if proc.poll() is not None:
                    logs = self._log_captures[i].get_logs(max_lines=50)
                    self._failed = True
                    raise RuntimeError(
                        f"Replica {i} failed to start (exit_code={proc.returncode}):\n{logs}"
                    )
        except Exception:
            self._failed = True
            self.stop()
            raise

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

    def _wait_for_node_listener(self, replica: int, timeout: float) -> bool:
        """Wait until a replica's data-plane TCP port accepts connections."""
        deadline = time.time() + timeout
        port = self._ports[replica]
        while time.time() < deadline:
            proc = self._processes[replica]
            if proc.poll() is not None:
                return False
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                    return True
            except OSError:
                time.sleep(0.25)
        return False

    def _wait_for_node_started(self, replica: int, timeout: float) -> bool:
        """Wait until a replica finishes local startup init.

        The `listening on` log line is emitted after `replica.open()` returns
        and the heavy local forest/grid initialization is complete. Using that
        marker for large shared-machine clusters avoids overlapping the most
        memory-intensive startup phase across too many replicas at once.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            proc = self._processes[replica]
            if proc.poll() is not None:
                return False

            if "listening on" in self._log_captures[replica].get_all():
                return True

            time.sleep(0.25)
        return False

    def wait_for_ready(self, timeout: Optional[float] = None) -> bool:
        """Wait for all nodes to be ready.

        Args:
            timeout: Maximum time to wait in seconds.

        Returns:
            True if all nodes are ready, False on timeout.
        """
        if not self._started:
            raise RuntimeError("Cluster not started")

        if timeout is None:
            timeout = self.config.startup_timeout

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
                    raise RuntimeError(
                        f"Replica {i} crashed (exit_code={self._processes[i].returncode}):\n{logs}"
                    )

                # Check health endpoint
                try:
                    resp = _http_get(
                        f"http://127.0.0.1:{self._metrics_ports[i]}/health/ready",
                        timeout=1,
                    )
                    if resp.status_code == 200:
                        nodes_ready.add(i)
                except _HttpRequestError:
                    pass

            if len(nodes_ready) == self.config.node_count:
                return True

            time.sleep(0.5)

        return False

    def wait_for_leader(self, timeout: Optional[float] = None) -> Optional[int]:
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

        if timeout is None:
            timeout = self.config.startup_timeout

        if self.config.node_count == 1:
            # Single node is always the leader
            return self._ports[0]

        deadline = time.time() + timeout

        while time.time() < deadline:
            for i in range(self.config.node_count):
                try:
                    # Check metrics for region role (primary = can accept writes).
                    # Multi-node clusters can surface role information before
                    # /health/ready flips to 200, so do not gate leader discovery
                    # on the readiness endpoint here.
                    resp = _http_get(
                        f"http://127.0.0.1:{self._metrics_ports[i]}/metrics",
                        timeout=1,
                    )
                    if resp.status_code == 200:
                        # Look for: archerdb_region_info{region_id="0",role="primary"} 1
                        if re.search(r'archerdb_region_info\{[^}]*role="primary"[^}]*\}\s+1', resp.text):
                            return self._ports[i]
                except _HttpRequestError:
                    pass

            time.sleep(0.5)

        return None

    def get_addresses(self) -> str:
        """Get comma-separated addresses for SDK connection.

        Returns:
            Address string like "127.0.0.1:3101,127.0.0.1:3102,127.0.0.1:3103".
        """
        return ",".join(f"127.0.0.1:{p}" for p in self._ports)

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

    def get_recent_logs(self, max_lines_per_replica: int = 12) -> str:
        """Get a compact recent log summary for all replicas."""
        sections = []
        for replica in range(self.config.node_count):
            logs = self.get_logs(replica)
            tail = logs.splitlines()[-max_lines_per_replica:]
            body = "\n".join(tail) if tail else "(no logs)"
            sections.append(f"replica {replica}:\n{body}")
        return "\n\n".join(sections)

    def stop_node(self, replica: int, graceful: bool = True) -> None:
        """Stop a specific cluster node.

        Args:
            replica: Replica index (0-based).
            graceful: If True, send SIGTERM and wait up to 10s before SIGKILL.
                     If False, send SIGKILL immediately.

        Raises:
            ValueError: If replica index is invalid.
        """
        if replica not in self._processes:
            raise ValueError(f"Replica {replica} not found")

        proc = self._processes[replica]
        if proc.poll() is not None:
            return  # Already stopped

        if graceful:
            proc.terminate()  # SIGTERM
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()  # Escalate to SIGKILL
                proc.wait()
        else:
            proc.kill()  # SIGKILL immediately
            proc.wait()

    def start_node(self, replica: int) -> None:
        """Restart a previously stopped node.

        Re-spawns the process with the same configuration. Does not format
        the data file since it already exists from initial start.

        Args:
            replica: Replica index to restart.

        Raises:
            ValueError: If replica index is invalid.
            RuntimeError: If data directory is not set or node fails to start.
        """
        if replica < 0 or replica >= self.config.node_count:
            raise ValueError(f"Invalid replica index: {replica}")

        if self._data_dir is None:
            raise RuntimeError("Cluster data directory not set")

        # Data file already exists - no format needed
        data_file = self._data_dir / f"replica-{replica}.archerdb"
        addresses = ",".join(f"127.0.0.1:{p}" for p in self._ports)

        # Create fresh log capture
        log_capture = LogCapture()
        self._log_captures[replica] = log_capture

        cmd = [
            str(self._bin_path),
            "start",
            "--development=true",
            "--experimental=true",
            f"--addresses={addresses}",
            f"--cache-grid={self.config.cache_grid}",
            f"--ram-index-size={self.config.ram_index_size}",
            f"--memory-lsm-manifest={self.config.memory_lsm_manifest}",
            f"--metrics-port={self._metrics_ports[replica]}",
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
        self._processes[replica] = process

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
        self._log_threads[replica] = thread

        # Brief wait to check initial startup
        time.sleep(0.5)
        if process.poll() is not None:
            logs = log_capture.get_logs(max_lines=50)
            raise RuntimeError(
                f"Replica {replica} failed to restart (exit_code={process.returncode}):\n{logs}"
            )

    def kill_node(self, replica: int) -> None:
        """Kill a specific cluster node immediately (SIGKILL).

        Shorthand for stop_node(replica, graceful=False). Simulates crash scenario.

        Args:
            replica: Replica index (0-based).
        """
        self.stop_node(replica, graceful=False)

    def is_node_running(self, replica: int) -> bool:
        """Check if a specific node is running.

        Args:
            replica: Replica index (0-based).

        Returns:
            True if the process exists and poll() is None (still running).
        """
        if replica not in self._processes:
            return False
        return self._processes[replica].poll() is None

    def get_leader_replica(self) -> Optional[int]:
        """Get the index of the current leader replica.

        Checks all running nodes' metrics for archerdb_region_info with role="primary".

        Returns:
            Replica index (0-based) of the leader, or None if no leader found.
        """
        if self.config.node_count == 1:
            # Single node is always the leader if running
            if self.is_node_running(0):
                return 0
            return None

        for i in range(self.config.node_count):
            if not self.is_node_running(i):
                continue
            try:
                resp = _http_get(
                    f"http://127.0.0.1:{self._metrics_ports[i]}/metrics",
                    timeout=1,
                )
                if resp.status_code == 200:
                    # Look for: archerdb_region_info{region_id="0",role="primary"} 1
                    if re.search(r'archerdb_region_info\{[^}]*role="primary"[^}]*\}\s+1', resp.text):
                        return i
            except _HttpRequestError:
                pass
        return None

    def get_ports(self) -> List[int]:
        """Get cluster node ports.

        Returns:
            Copy of the ports list for all cluster nodes.
        """
        return list(self._ports)

    def get_metrics_ports(self) -> List[int]:
        """Get cluster metrics ports.

        Returns:
            Copy of the metrics ports list for all cluster nodes.
        """
        return list(self._metrics_ports)

    def __enter__(self) -> "ArcherDBCluster":
        """Context manager entry."""
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        """Context manager exit."""
        if exc_type is not None:
            self._failed = True
        self.stop()
