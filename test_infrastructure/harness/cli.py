# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""CLI wrapper for ArcherDB test harness.

Provides command-line access to cluster management functionality for
manual testing and debugging.

Usage:
    python -m test_infrastructure.harness.cli start --nodes=3
    python -m test_infrastructure.harness.cli status
    python -m test_infrastructure.harness.cli logs --replica=0
    python -m test_infrastructure.harness.cli stop
"""

import argparse
import json
import os
import sys
import signal
import time
from pathlib import Path

from .cluster import ArcherDBCluster, ClusterConfig


# Global cluster reference for signal handling
_active_cluster: ArcherDBCluster | None = None


def _signal_handler(signum: int, frame) -> None:
    """Handle shutdown signals gracefully."""
    global _active_cluster
    if _active_cluster:
        print("\nReceived shutdown signal, stopping cluster...")
        _active_cluster.stop()
        _active_cluster = None
    sys.exit(0)


def cmd_start(args: argparse.Namespace) -> int:
    """Start an ArcherDB cluster."""
    global _active_cluster

    config = ClusterConfig(
        node_count=args.nodes,
        base_port=args.base_port,
        data_dir=args.data_dir,
        cache_grid=args.cache_grid,
        startup_timeout=args.timeout,
    )

    # State file for tracking cluster info
    state_file = Path(args.data_dir or ".") / ".cluster-state.json"

    print(f"Starting {args.nodes}-node ArcherDB cluster...")

    cluster = ArcherDBCluster(config)
    _active_cluster = cluster

    # Setup signal handlers
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    try:
        cluster.start()
        print("Waiting for cluster to be ready...")

        if not cluster.wait_for_ready(timeout=args.timeout):
            print("ERROR: Cluster failed to become ready within timeout")
            cluster.stop()
            return 1

        addresses = cluster.get_addresses()
        leader = cluster.wait_for_leader(timeout=30)

        # Save state for status/stop commands
        state = {
            "addresses": addresses,
            "ports": cluster._ports,
            "metrics_ports": cluster._metrics_ports,
            "data_dir": str(cluster._data_dir),
            "node_count": args.nodes,
            "leader_port": leader,
        }
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps(state, indent=2))

        print(f"\nCluster started successfully!")
        print(f"  Addresses: {addresses}")
        print(f"  Leader: port {leader}")
        print(f"  Data dir: {cluster._data_dir}")
        print(f"  State file: {state_file}")
        print(f"\nTo connect:")
        print(f"  archerdb repl --cluster=0 --addresses={addresses}")
        print(f"\nPress Ctrl+C to stop the cluster...")

        # Keep running until interrupted
        while True:
            time.sleep(1)
            # Check if processes are still alive
            for i, proc in cluster._processes.items():
                if proc.poll() is not None:
                    print(f"\nERROR: Replica {i} died unexpectedly")
                    print(cluster.get_logs(i))
                    cluster.stop()
                    return 1

    except KeyboardInterrupt:
        print("\nStopping cluster...")
        cluster.stop()
        if state_file.exists():
            state_file.unlink()
        return 0
    except Exception as e:
        print(f"ERROR: {e}")
        cluster.stop()
        return 1


def cmd_stop(args: argparse.Namespace) -> int:
    """Stop a running cluster."""
    state_file = Path(args.data_dir or ".") / ".cluster-state.json"

    if not state_file.exists():
        print("No cluster state found. Is a cluster running?")
        return 1

    state = json.loads(state_file.read_text())
    print(f"Stopping cluster with {state['node_count']} nodes...")

    # Create a minimal cluster config to stop it
    config = ClusterConfig(
        node_count=state["node_count"],
        data_dir=state["data_dir"],
    )
    cluster = ArcherDBCluster(config)

    # Manually set the ports from saved state
    cluster._ports = state["ports"]
    cluster._metrics_ports = state["metrics_ports"]
    cluster._data_dir = Path(state["data_dir"])
    cluster._started = True

    # Find and terminate processes by port
    import subprocess
    for port in state["ports"]:
        result = subprocess.run(
            ["lsof", "-t", "-i", f":{port}"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            pids = result.stdout.strip().split()
            for pid in pids:
                try:
                    os.kill(int(pid), signal.SIGTERM)
                    print(f"  Terminated process {pid} on port {port}")
                except ProcessLookupError:
                    pass

    state_file.unlink()
    print("Cluster stopped.")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Show cluster status."""
    state_file = Path(args.data_dir or ".") / ".cluster-state.json"

    if not state_file.exists():
        print("No cluster running (no state file found)")
        return 0

    state = json.loads(state_file.read_text())
    print(f"Cluster status:")
    print(f"  Nodes: {state['node_count']}")
    print(f"  Addresses: {state['addresses']}")
    print(f"  Data dir: {state['data_dir']}")

    # Check each node's health
    import requests
    for i, port in enumerate(state["metrics_ports"]):
        try:
            resp = requests.get(f"http://127.0.0.1:{port}/health/ready", timeout=1)
            status = "READY" if resp.status_code == 200 else f"NOT READY ({resp.status_code})"
        except requests.RequestException as e:
            status = f"UNREACHABLE ({type(e).__name__})"
        print(f"  Replica {i} (port {state['ports'][i]}): {status}")

    return 0


def cmd_logs(args: argparse.Namespace) -> int:
    """Show logs for a replica."""
    state_file = Path(args.data_dir or ".") / ".cluster-state.json"

    if not state_file.exists():
        print("No cluster running (no state file found)")
        return 1

    state = json.loads(state_file.read_text())
    replica = args.replica

    if replica >= state["node_count"]:
        print(f"Invalid replica {replica}. Cluster has {state['node_count']} nodes.")
        return 1

    # Read logs from log file
    log_file = Path(state["data_dir"]) / f"replica-{replica}.log"
    if log_file.exists():
        print(f"=== Logs for replica {replica} ===")
        print(log_file.read_text())
    else:
        print(f"No log file found for replica {replica}")

    return 0


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="ArcherDB Test Cluster Management",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s start --nodes=3              Start a 3-node cluster
  %(prog)s start --nodes=1              Start a single-node cluster
  %(prog)s status                       Check cluster status
  %(prog)s logs --replica=0             View replica 0 logs
  %(prog)s stop                         Stop the cluster
        """,
    )

    parser.add_argument(
        "--data-dir",
        default=None,
        help="Directory for cluster data (default: auto-create temp dir)",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # start command
    start_parser = subparsers.add_parser("start", help="Start a cluster")
    start_parser.add_argument(
        "--nodes",
        type=int,
        default=3,
        help="Number of nodes (1, 3, 5, 7...) (default: 3)",
    )
    start_parser.add_argument(
        "--base-port",
        type=int,
        default=0,
        help="Base port (0 = auto-allocate) (default: 0)",
    )
    start_parser.add_argument(
        "--cache-grid",
        default="512MiB",
        help="Cache grid size (default: 512MiB)",
    )
    start_parser.add_argument(
        "--timeout",
        type=float,
        default=60.0,
        help="Startup timeout in seconds (default: 60)",
    )

    # stop command
    subparsers.add_parser("stop", help="Stop the cluster")

    # status command
    subparsers.add_parser("status", help="Show cluster status")

    # logs command
    logs_parser = subparsers.add_parser("logs", help="Show replica logs")
    logs_parser.add_argument(
        "--replica",
        type=int,
        default=0,
        help="Replica index (default: 0)",
    )

    args = parser.parse_args()

    if args.command == "start":
        return cmd_start(args)
    elif args.command == "stop":
        return cmd_stop(args)
    elif args.command == "status":
        return cmd_status(args)
    elif args.command == "logs":
        return cmd_logs(args)

    return 1


if __name__ == "__main__":
    sys.exit(main())
