# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Benchmark orchestrator for full suite execution.

Coordinates benchmark runs across different topologies (1/3/5/6 nodes),
manages cluster lifecycle, and collects comprehensive results.
"""

import json
import os
import socket
import time
from contextlib import contextmanager
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Generator, List, Optional

from .config import BenchmarkConfig
from .executor import BenchmarkExecutor, BenchmarkResult, Sample
from .histogram import LatencyHistogram
from .reporter import BenchmarkReporter
from .sdk_adapter import batch_to_geo_events, build_client
from .stats import confidence_interval, coefficient_of_variation, summarize
from .workloads.throughput import ThroughputWorkload
from .workloads.latency_read import LatencyReadWorkload
from .workloads.latency_write import LatencyWriteWorkload
from .workloads.mixed import MixedWorkload

from ..harness.cluster import ArcherDBCluster, ClusterConfig
from ..generators.data_generator import DatasetConfig, generate_events


# Performance targets from CONTEXT.md
PERFORMANCE_TARGETS = {
    "throughput_3node_baseline": 770_000,  # events/sec
    "throughput_3node_stretch": 1_000_000,  # events/sec
    "read_latency_p95_ms": 1.0,
    "read_latency_p99_ms": 10.0,
    "write_latency_p95_ms": 10.0,
    "write_latency_p99_ms": 50.0,
}


class BenchmarkOrchestrator:
    """Orchestrates benchmark runs across cluster topologies.

    Manages the full benchmark lifecycle:
    1. Start fresh cluster per benchmark (isolated measurements)
    2. Run warmup phase
    3. Execute benchmark workload
    4. Collect and analyze results
    5. Stop cluster and cleanup

    Usage:
        orchestrator = BenchmarkOrchestrator()
        results = orchestrator.run_full_suite(topologies=[1, 3, 5, 6])
    """

    def __init__(
        self,
        output_dir: str = "reports/benchmarks",
        history_dir: str = "reports/history",
    ) -> None:
        """Initialize orchestrator.

        Args:
            output_dir: Directory for benchmark result files.
            history_dir: Directory for historical baselines.
        """
        self.output_dir = output_dir
        self.history_dir = history_dir

        # Ensure directories exist
        Path(output_dir).mkdir(parents=True, exist_ok=True)
        Path(history_dir).mkdir(parents=True, exist_ok=True)

    @staticmethod
    def _utc_now_iso() -> str:
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    @staticmethod
    def _cluster_profile_for_topology(
        topology: int,
        cache_grid: Optional[str],
    ) -> Dict[str, Any]:
        """Choose a machine-fit benchmark cluster profile.

        Benchmarks run all replicas on one machine. Larger topologies need a
        tighter per-node memory profile to avoid startup stalls or OOM kills.
        """
        if topology == 6:
            return {
                "cache_grid": cache_grid or "64MiB",
                "ram_index_size": "2MiB",
                "memory_lsm_manifest": "8MiB",
                "startup_timeout": max(240.0, 60.0 * topology),
                "primary_head_start_timeout": 180.0,
            }

        if topology >= 5:
            return {
                "cache_grid": cache_grid or "64MiB",
                "ram_index_size": "4MiB",
                "memory_lsm_manifest": "16MiB",
                "startup_timeout": max(180.0, 40.0 * topology),
                "primary_head_start_timeout": 120.0,
            }

        return {
            "cache_grid": cache_grid or "512MiB",
            "ram_index_size": "8MiB",
            "memory_lsm_manifest": "64MiB",
            "startup_timeout": max(60.0, 30.0 * topology),
            "primary_head_start_timeout": 0.0,
        }

    @contextmanager
    def _isolated_cluster(
        self,
        topology: int,
        cache_grid: Optional[str] = None,
    ) -> Generator[ArcherDBCluster, None, None]:
        """Context manager for isolated cluster lifecycle.

        Per CONTEXT.md: "Fresh cluster per run - start clean cluster, load data,
        run benchmark, stop cluster (isolated measurements, no shared state)"

        Args:
            topology: Number of nodes.
            cache_grid: Cache grid size.

        Yields:
            Ready ArcherDBCluster instance.
        """
        profile = self._cluster_profile_for_topology(topology, cache_grid)

        config = ClusterConfig(
            node_count=topology,
            replica_count=5 if topology == 6 else topology,
            cache_grid=profile["cache_grid"],
            ram_index_size=profile["ram_index_size"],
            memory_lsm_manifest=profile["memory_lsm_manifest"],
            startup_timeout=profile["startup_timeout"],
            primary_head_start_timeout=profile["primary_head_start_timeout"],
        )

        cluster = ArcherDBCluster(config)
        try:
            cluster.start()
            # Benchmarks only require a routable data plane. Larger local
            # topologies can accept SDK traffic before every replica's
            # /health/ready probe turns green.
            leader_port = cluster.wait_for_leader(timeout=config.startup_timeout)
            if leader_port is None:
                logs = cluster.get_recent_logs()
                raise RuntimeError(
                    "Timed out waiting for benchmark cluster leader "
                    f"({topology} nodes, timeout={config.startup_timeout:.0f}s)\n{logs}"
                )
            yield cluster
        finally:
            cluster.stop()

    def _get_leader_port(self, cluster: ArcherDBCluster) -> int:
        """Get a healthy replica port for write operations.

        Args:
            cluster: Running cluster.

        Returns:
            Leader port number.

        Raises:
            RuntimeError: If no leader found.
        """
        leader_port = cluster.wait_for_leader(timeout=30)
        if leader_port is None:
            raise RuntimeError("Failed to find cluster leader")
        return leader_port

    def _get_cluster_addresses(self, cluster: ArcherDBCluster) -> List[str]:
        """Get benchmark client endpoints.

        Order the current leader first, then the remaining voting replicas.
        This keeps the warm path pointed at the primary while still giving the
        SDK enough endpoints to recover if the current leader dies during a
        stressed local benchmark run. Standbys are excluded because they do not
        need direct client traffic for benchmark measurement.
        """
        leader_port = self._get_leader_port(cluster)
        replica_count = cluster.config.replica_count or cluster.config.node_count
        voter_ports = cluster._ports[:replica_count]
        ordered_ports = [leader_port] + [port for port in voter_ports if port != leader_port]
        return [f"127.0.0.1:{port}" for port in ordered_ports]

    def _wait_for_data_plane_ready(
        self,
        cluster: ArcherDBCluster,
        timeout: float = 30.0,
    ) -> None:
        """Wait until the benchmark SDK surface is actually usable.

        Leader metrics can be stale during large-cluster convergence, so probing
        only the reported primary can spin on the wrong node. For benchmark
        bring-up, a live data-plane listener is the least flaky readiness gate:
        the first real benchmark operation will exercise the supported SDK
        surface with retries, while native ping requests have proven to time out
        spuriously on larger shared-machine local clusters.
        """
        effective_timeout = max(timeout, cluster.config.startup_timeout)
        deadline = time.time() + effective_timeout
        addresses = self._get_cluster_addresses(cluster)
        while time.time() < deadline:
            for address in addresses:
                host, port_text = address.rsplit(":", 1)
                try:
                    with socket.create_connection((host, int(port_text)), timeout=0.5):
                        return
                except OSError:
                    continue

            time.sleep(0.25)

        logs = cluster.get_recent_logs()
        raise RuntimeError(
            "Timed out waiting for benchmark data plane readiness "
            f"({cluster.config.node_count} nodes, timeout={effective_timeout:.0f}s)\n{logs}"
        )

    @staticmethod
    def _require_success(result: BenchmarkResult, benchmark_name: str) -> None:
        """Reject benchmark runs that measured failed operations."""
        failures = sum(1 for sample in result.samples if not sample.success)
        if failures:
            raise RuntimeError(
                f"{benchmark_name} recorded {failures}/{len(result.samples)} failed operations"
            )

    def _calculate_percentiles(
        self,
        samples: List[Sample],
    ) -> Dict[str, float]:
        """Calculate percentiles from samples using HDR histogram.

        Args:
            samples: List of benchmark samples.

        Returns:
            Dict with p50, p95, p99 in milliseconds.
        """
        histogram = LatencyHistogram()
        for sample in samples:
            # Convert ns to us for histogram
            histogram.record(sample.latency_ns // 1000)

        return {
            "p50_ms": histogram.percentile(50) / 1000,  # us to ms
            "p95_ms": histogram.percentile(95) / 1000,
            "p99_ms": histogram.percentile(99) / 1000,
        }

    def run_throughput_benchmark(
        self,
        topology: int,
        config: BenchmarkConfig,
    ) -> Dict[str, Any]:
        """Run throughput benchmark on specified topology.

        Measures insert throughput in events/second.

        Args:
            topology: Number of nodes.
            config: Benchmark configuration.

        Returns:
            Result dict with throughput, percentiles, configuration.
        """
        with self._isolated_cluster(topology) as cluster:
            self._wait_for_data_plane_ready(cluster)
            addresses = self._get_cluster_addresses(cluster)

            # Create workload
            data_config = DatasetConfig(
                size=config.data_size,
                pattern=config.data_pattern,
                seed=config.seed,
            )
            workload = ThroughputWorkload(
                host=None,
                port=None,
                data_config=data_config,
                batch_size=1000,
                addresses=addresses,
                cluster_id=cluster.config.cluster_id,
            )
            workload.setup()

            try:
                # Create executor
                executor = BenchmarkExecutor(config, show_progress=True)

                # Run warmup
                stable = executor.warmup(workload.execute_one)

                # Run measurement
                result = executor.run(workload.execute_one)
                result.warmup_stable = stable
                self._require_success(result, "throughput")

                # Calculate metrics
                duration_sec = result.duration_ns / 1e9
                total_events = len(result.samples) * workload.get_events_per_batch()
                throughput = total_events / duration_sec if duration_sec > 0 else 0

                percentiles = self._calculate_percentiles(result.samples)

                return {
                    "benchmark_type": "throughput",
                    "topology": topology,
                    "throughput_events_per_sec": throughput,
                    "total_events": total_events,
                    "total_batches": len(result.samples),
                    "batch_size": workload.get_events_per_batch(),
                    "duration_sec": duration_sec,
                    "warmup_stable": result.warmup_stable,
                    **percentiles,
                    "config": asdict(config),
                    "timestamp": self._utc_now_iso(),
                }
            finally:
                workload.cleanup()

    def run_latency_read_benchmark(
        self,
        topology: int,
        config: BenchmarkConfig,
    ) -> Dict[str, Any]:
        """Run read latency benchmark on specified topology.

        Pre-loads data, then measures query latency.

        Args:
            topology: Number of nodes.
            config: Benchmark configuration.

        Returns:
            Result dict with percentiles (P50/P95/P99) and configuration.
        """
        with self._isolated_cluster(topology) as cluster:
            self._wait_for_data_plane_ready(cluster)
            addresses = self._get_cluster_addresses(cluster)

            # Pre-load data for reads
            data_config = DatasetConfig(
                size=config.data_size,
                pattern=config.data_pattern,
                seed=config.seed,
            )
            events = generate_events(data_config)
            entity_ids = [e["entity_id"] for e in events]

            # Bulk insert events over the supported SDK/client path.
            preload_client = None
            try:
                preload_client = build_client(
                    cluster_id=cluster.config.cluster_id,
                    addresses=addresses,
                    timeout=60.0,
                )
                errors = preload_client.insert_events(batch_to_geo_events(events))
                if errors:
                    raise RuntimeError(f"Failed to pre-load data: {len(errors)} insert errors")
            finally:
                if preload_client is not None:
                    preload_client.close()

            # Create workload
            workload = LatencyReadWorkload(
                host=None,
                port=None,
                entity_ids=entity_ids,
                addresses=addresses,
                cluster_id=cluster.config.cluster_id,
            )
            workload.setup()

            try:
                # Create executor
                executor = BenchmarkExecutor(config, show_progress=True)

                # Run warmup
                stable = executor.warmup(workload.execute_one)

                # Run measurement
                result = executor.run(workload.execute_one)
                result.warmup_stable = stable
                self._require_success(result, "latency_read")

                # Calculate metrics
                percentiles = self._calculate_percentiles(result.samples)
                latencies_ms = [s.latency_ns / 1e6 for s in result.samples]
                stats = summarize(latencies_ms)

                return {
                    "benchmark_type": "latency_read",
                    "topology": topology,
                    "sample_count": len(result.samples),
                    "duration_sec": result.duration_ns / 1e9,
                    "warmup_stable": result.warmup_stable,
                    **percentiles,
                    "mean_ms": stats["mean"],
                    "std_ms": stats["std"],
                    "cv": stats["cv"],
                    "ci_low_ms": stats["ci_low"],
                    "ci_high_ms": stats["ci_high"],
                    "config": asdict(config),
                    "timestamp": self._utc_now_iso(),
                }
            finally:
                workload.cleanup()

    def run_latency_write_benchmark(
        self,
        topology: int,
        config: BenchmarkConfig,
    ) -> Dict[str, Any]:
        """Run write latency benchmark on specified topology.

        Measures single-event insert latency.

        Args:
            topology: Number of nodes.
            config: Benchmark configuration.

        Returns:
            Result dict with percentiles (P50/P95/P99) and configuration.
        """
        with self._isolated_cluster(topology) as cluster:
            self._wait_for_data_plane_ready(cluster)
            addresses = self._get_cluster_addresses(cluster)

            # Create workload
            data_config = DatasetConfig(
                size=config.data_size,
                pattern=config.data_pattern,
                seed=config.seed,
            )
            workload = LatencyWriteWorkload(
                host=None,
                port=None,
                data_config=data_config,
                addresses=addresses,
                cluster_id=cluster.config.cluster_id,
            )
            workload.setup()

            try:
                # Create executor
                executor = BenchmarkExecutor(config, show_progress=True)

                # Run warmup
                stable = executor.warmup(workload.execute_one)

                # Run measurement
                result = executor.run(workload.execute_one)
                result.warmup_stable = stable
                self._require_success(result, "latency_write")

                # Calculate metrics
                percentiles = self._calculate_percentiles(result.samples)
                latencies_ms = [s.latency_ns / 1e6 for s in result.samples]
                stats = summarize(latencies_ms)

                return {
                    "benchmark_type": "latency_write",
                    "topology": topology,
                    "sample_count": len(result.samples),
                    "duration_sec": result.duration_ns / 1e9,
                    "warmup_stable": result.warmup_stable,
                    **percentiles,
                    "mean_ms": stats["mean"],
                    "std_ms": stats["std"],
                    "cv": stats["cv"],
                    "ci_low_ms": stats["ci_low"],
                    "ci_high_ms": stats["ci_high"],
                    "config": asdict(config),
                    "timestamp": self._utc_now_iso(),
                }
            finally:
                workload.cleanup()

    def run_mixed_workload_benchmark(
        self,
        topology: int,
        config: BenchmarkConfig,
    ) -> Dict[str, Any]:
        """Run mixed read/write workload benchmark.

        Interleaves reads and writes based on config.read_write_ratio.
        Per CONTEXT.md: "Mixed workloads - combine reads and writes in
        realistic ratios (e.g., 80% reads, 20% writes)"

        Args:
            topology: Number of nodes.
            config: Benchmark configuration (uses read_write_ratio).

        Returns:
            Result dict with separate read/write percentiles.
        """
        with self._isolated_cluster(topology) as cluster:
            self._wait_for_data_plane_ready(cluster)
            addresses = self._get_cluster_addresses(cluster)

            # Create workload
            data_config = DatasetConfig(
                size=config.data_size,
                pattern=config.data_pattern,
                seed=config.seed,
            )
            workload = MixedWorkload(
                host=None,
                port=None,
                data_config=data_config,
                read_ratio=config.read_write_ratio,
                addresses=addresses,
                cluster_id=cluster.config.cluster_id,
            )
            workload.setup()

            try:
                # Create executor
                executor = BenchmarkExecutor(config, show_progress=True)

                # Run warmup
                stable = executor.warmup(workload.execute_one)

                # Run measurement
                result = executor.run(workload.execute_one)
                result.warmup_stable = stable
                self._require_success(result, "mixed")

                # Get separate read/write samples
                read_samples = workload.get_read_samples()
                write_samples = workload.get_write_samples()

                # Calculate overall metrics
                overall_percentiles = self._calculate_percentiles(result.samples)

                # Calculate read metrics
                read_metrics = {}
                if len(read_samples) >= 2:
                    read_percentiles = self._calculate_percentiles(read_samples)
                    read_latencies_ms = [s.latency_ns / 1e6 for s in read_samples]
                    read_stats = summarize(read_latencies_ms)
                    read_metrics = {
                        "read_count": len(read_samples),
                        "read_p50_ms": read_percentiles["p50_ms"],
                        "read_p95_ms": read_percentiles["p95_ms"],
                        "read_p99_ms": read_percentiles["p99_ms"],
                        "read_mean_ms": read_stats["mean"],
                    }

                # Calculate write metrics
                write_metrics = {}
                if len(write_samples) >= 2:
                    write_percentiles = self._calculate_percentiles(write_samples)
                    write_latencies_ms = [s.latency_ns / 1e6 for s in write_samples]
                    write_stats = summarize(write_latencies_ms)
                    write_metrics = {
                        "write_count": len(write_samples),
                        "write_p50_ms": write_percentiles["p50_ms"],
                        "write_p95_ms": write_percentiles["p95_ms"],
                        "write_p99_ms": write_percentiles["p99_ms"],
                        "write_mean_ms": write_stats["mean"],
                    }

                return {
                    "benchmark_type": "mixed",
                    "topology": topology,
                    "read_write_ratio": config.read_write_ratio,
                    "total_operations": len(result.samples),
                    "duration_sec": result.duration_ns / 1e9,
                    "warmup_stable": result.warmup_stable,
                    **overall_percentiles,
                    **read_metrics,
                    **write_metrics,
                    "config": asdict(config),
                    "timestamp": self._utc_now_iso(),
                }
            finally:
                workload.cleanup()

    def run_full_suite(
        self,
        topologies: Optional[List[int]] = None,
        include_mixed: bool = True,
        config: Optional[BenchmarkConfig] = None,
        checkpoint_path: Optional[Path] = None,
    ) -> Dict[str, Any]:
        """Run complete benchmark suite across all topologies.

        Executes throughput, read latency, write latency, and optionally
        mixed workload benchmarks for each topology.

        Args:
            topologies: List of node counts to test (default: [1, 3, 5, 6]).
            include_mixed: Whether to run mixed workload benchmarks.
            config: Benchmark configuration (default: 60s, 10K ops).

        Returns:
            Combined results dict with all benchmark results.
        """
        if topologies is None:
            topologies = [1, 3, 5, 6]

        if config is None:
            config = BenchmarkConfig(
                time_limit_sec=60.0,
                op_count_limit=10_000,
            )

        def checkpoint() -> None:
            if checkpoint_path is None:
                return
            checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
            with open(checkpoint_path, "w") as f:
                json.dump(results, f, indent=2)

        results: Dict[str, Any] = {
            "suite_start": self._utc_now_iso(),
            "topologies": topologies,
            "include_mixed": include_mixed,
            "benchmarks": {
                "throughput": {},
                "latency_read": {},
                "latency_write": {},
                "mixed": {},
            },
        }

        for topology in topologies:
            print(f"\n{'='*60}")
            print(f"Running benchmarks for {topology}-node topology")
            print(f"{'='*60}")

            # Update config topology
            topo_config = BenchmarkConfig(
                topology=topology,
                time_limit_sec=config.time_limit_sec,
                op_count_limit=config.op_count_limit,
                min_samples=config.min_samples,
                warmup_iterations=config.warmup_iterations,
                data_pattern=config.data_pattern,
                data_size=config.data_size,
                seed=config.seed,
                read_write_ratio=config.read_write_ratio,
            )

            # Run throughput benchmark
            print(f"\n--- Throughput Benchmark ({topology}-node) ---")
            try:
                throughput_result = self.run_throughput_benchmark(topology, topo_config)
                results["benchmarks"]["throughput"][str(topology)] = throughput_result
            except Exception as e:
                results["benchmarks"]["throughput"][str(topology)] = {"error": str(e)}
            checkpoint()

            # Run read latency benchmark
            print(f"\n--- Read Latency Benchmark ({topology}-node) ---")
            try:
                read_result = self.run_latency_read_benchmark(topology, topo_config)
                results["benchmarks"]["latency_read"][str(topology)] = read_result
            except Exception as e:
                results["benchmarks"]["latency_read"][str(topology)] = {"error": str(e)}
            checkpoint()

            # Run write latency benchmark
            print(f"\n--- Write Latency Benchmark ({topology}-node) ---")
            try:
                write_result = self.run_latency_write_benchmark(topology, topo_config)
                results["benchmarks"]["latency_write"][str(topology)] = write_result
            except Exception as e:
                results["benchmarks"]["latency_write"][str(topology)] = {"error": str(e)}
            checkpoint()

            # Run mixed workload benchmark
            if include_mixed:
                print(f"\n--- Mixed Workload Benchmark ({topology}-node) ---")
                try:
                    mixed_result = self.run_mixed_workload_benchmark(topology, topo_config)
                    results["benchmarks"]["mixed"][str(topology)] = mixed_result
                except Exception as e:
                    results["benchmarks"]["mixed"][str(topology)] = {"error": str(e)}
                checkpoint()

        results["suite_end"] = self._utc_now_iso()
        checkpoint()

        # Save results
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        output_path = Path(self.output_dir) / f"{timestamp}-full-suite.json"
        with open(output_path, "w") as f:
            json.dump(results, f, indent=2)

        print(f"\nResults saved to: {output_path}")

        return results

    def check_targets(self, results: Dict[str, Any]) -> Dict[str, Any]:
        """Check benchmark results against performance targets.

        Args:
            results: Results from benchmark run.

        Returns:
            Dict with pass/fail status for each target.
        """
        checks = {}

        # Check 3-node throughput
        throughput_3 = results.get("benchmarks", {}).get("throughput", {}).get("3", {})
        if "throughput_events_per_sec" in throughput_3:
            tp = throughput_3["throughput_events_per_sec"]
            checks["throughput_3node_baseline"] = {
                "value": tp,
                "target": PERFORMANCE_TARGETS["throughput_3node_baseline"],
                "passed": tp >= PERFORMANCE_TARGETS["throughput_3node_baseline"],
            }
            checks["throughput_3node_stretch"] = {
                "value": tp,
                "target": PERFORMANCE_TARGETS["throughput_3node_stretch"],
                "passed": tp >= PERFORMANCE_TARGETS["throughput_3node_stretch"],
            }

        # Check read latency (use 3-node as representative)
        read_3 = results.get("benchmarks", {}).get("latency_read", {}).get("3", {})
        if "p95_ms" in read_3:
            checks["read_latency_p95"] = {
                "value": read_3["p95_ms"],
                "target": PERFORMANCE_TARGETS["read_latency_p95_ms"],
                "passed": read_3["p95_ms"] < PERFORMANCE_TARGETS["read_latency_p95_ms"],
            }
        if "p99_ms" in read_3:
            checks["read_latency_p99"] = {
                "value": read_3["p99_ms"],
                "target": PERFORMANCE_TARGETS["read_latency_p99_ms"],
                "passed": read_3["p99_ms"] < PERFORMANCE_TARGETS["read_latency_p99_ms"],
            }

        # Check write latency (use 3-node as representative)
        write_3 = results.get("benchmarks", {}).get("latency_write", {}).get("3", {})
        if "p95_ms" in write_3:
            checks["write_latency_p95"] = {
                "value": write_3["p95_ms"],
                "target": PERFORMANCE_TARGETS["write_latency_p95_ms"],
                "passed": write_3["p95_ms"] < PERFORMANCE_TARGETS["write_latency_p95_ms"],
            }
        if "p99_ms" in write_3:
            checks["write_latency_p99"] = {
                "value": write_3["p99_ms"],
                "target": PERFORMANCE_TARGETS["write_latency_p99_ms"],
                "passed": write_3["p99_ms"] < PERFORMANCE_TARGETS["write_latency_p99_ms"],
            }

        return checks
