#!/usr/bin/env python3

import argparse
import json
import math
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Optional, Tuple

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "src/clients/python/src"))

from archerdb import GeoClientConfig, GeoClientSync, GeoEvent, GeoEventFlags

TIER_CHOICES = ("lite", "standard", "pro", "enterprise", "ultra")
OPTIMIZE_CHOICES = ("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall")


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def sample_process(pid: int) -> Tuple[Optional[int], Optional[float]]:
    try:
        output = subprocess.check_output(
            ["ps", "-o", "rss=,pcpu=", "-p", str(pid)],
            text=True,
        ).strip()
    except subprocess.SubprocessError:
        return None, None

    if not output:
        return None, None

    parts = output.split()
    if len(parts) < 2:
        return None, None

    try:
        rss_kib = float(parts[0])
        cpu_percent = float(parts[1])
    except ValueError:
        return None, None

    return int(rss_kib * 1024), cpu_percent


def wait_ready(metrics_port: int, process: subprocess.Popen, timeout_s: float) -> None:
    ready_url = f"http://127.0.0.1:{metrics_port}/health/ready"
    deadline = time.time() + timeout_s

    while time.time() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited early with code {process.returncode}")
        try:
            with urllib.request.urlopen(ready_url, timeout=1.0) as response:
                if response.status == 200:
                    return
        except urllib.error.URLError:
            pass
        except Exception:
            pass
        time.sleep(0.5)

    raise TimeoutError("server readiness probe timed out")


class SharedState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.next_event_id = 1
        self.total_inserted = 0
        self.first_error_code: Optional[int] = None
        self.failure_reason: Optional[str] = None

    def reserve_ids(self, count: int) -> int:
        with self.lock:
            start_id = self.next_event_id
            self.next_event_id += count
            return start_id

    def add_inserted(self, count: int) -> None:
        if count <= 0:
            return
        with self.lock:
            self.total_inserted += count

    def fail(self, reason: str, error_code: Optional[int] = None) -> None:
        with self.lock:
            if self.failure_reason is None:
                self.failure_reason = reason
            if error_code is not None and self.first_error_code is None:
                self.first_error_code = int(error_code)
        self.stop_event.set()


class Metrics:
    def __init__(self) -> None:
        self.cpu_sum = 0.0
        self.cpu_count = 0
        self.cpu_peak = 0.0
        self.rss_sum = 0
        self.rss_count = 0
        self.rss_peak = 0

    def add(self, rss_bytes: Optional[int], cpu_percent: Optional[float]) -> None:
        if rss_bytes is not None:
            self.rss_sum += rss_bytes
            self.rss_count += 1
            if rss_bytes > self.rss_peak:
                self.rss_peak = rss_bytes
        if cpu_percent is not None and not math.isnan(cpu_percent):
            self.cpu_sum += cpu_percent
            self.cpu_count += 1
            if cpu_percent > self.cpu_peak:
                self.cpu_peak = cpu_percent

    @property
    def cpu_avg(self) -> Optional[float]:
        return (self.cpu_sum / self.cpu_count) if self.cpu_count > 0 else None

    @property
    def rss_avg(self) -> Optional[int]:
        return int(self.rss_sum / self.rss_count) if self.rss_count > 0 else None


def build_artifacts(config: str, optimize: str, jobs: int) -> str:
    print(f"Building Python client + server for config={config}, optimize={optimize} ...")
    subprocess.run(
        [
            "./zig/zig",
            "build",
            f"-j{jobs}",
            f"-Dconfig={config}",
            f"-Doptimize={optimize}",
            "clients:python",
        ],
        check=True,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "./zig/zig",
            "build",
            f"-j{jobs}",
            f"-Dconfig={config}",
            f"-Doptimize={optimize}",
        ],
        check=True,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    binary = os.path.join(ROOT, "zig-out/bin/archerdb")
    if not os.path.exists(binary):
        raise FileNotFoundError(f"Expected binary missing: {binary}")
    return binary


def start_server(
    binary: str,
    config: str,
    data_file: str,
    log_file: str,
    data_port: int,
    metrics_port: int,
    request_limit: Optional[str],
    ram_index_size: Optional[str],
    ready_timeout_s: float,
) -> subprocess.Popen:
    os.makedirs(os.path.dirname(data_file), exist_ok=True)

    subprocess.run(
        [
            binary,
            "format",
            "--cluster=0",
            "--replica=0",
            "--replica-count=1",
            data_file,
        ],
        check=True,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    start_cmd = [
        binary,
        "start",
        f"--addresses={data_port}",
        f"--metrics-port={metrics_port}",
    ]
    experimental_args = []
    if request_limit:
        experimental_args.append(f"--limit-request={request_limit}")
    if ram_index_size:
        experimental_args.append(f"--ram-index-size={ram_index_size}")
    if experimental_args:
        start_cmd += ["--experimental", *experimental_args]
    start_cmd.append(data_file)

    log_handle = open(log_file, "w", encoding="utf-8")
    process = subprocess.Popen(
        start_cmd,
        cwd=ROOT,
        stdout=log_handle,
        stderr=log_handle,
    )
    # Keep handle attached to process object for cleanup.
    process._log_handle = log_handle  # type: ignore[attr-defined]

    wait_ready(metrics_port, process, timeout_s=ready_timeout_s)
    return process


def stop_server(process: Optional[subprocess.Popen]) -> None:
    if process is None:
        return

    try:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
    finally:
        log_handle = getattr(process, "_log_handle", None)
        if log_handle is not None:
            try:
                log_handle.flush()
            except Exception:
                pass
            try:
                log_handle.close()
            except Exception:
                pass


def cleanup_artifacts(paths: list[str]) -> None:
    for path in paths:
        try:
            if os.path.exists(path):
                os.remove(path)
                print(f"Cleaned up artifact: {path}")
        except OSError as exc:
            print(f"Warning: failed to delete artifact {path}: {exc}")


def worker_loop(
    worker_id: int,
    state: SharedState,
    batch_size: int,
    min_batch_size: int,
    entity_mod: int,
    address: str,
    connect_timeout_ms: int,
    request_timeout_ms: int,
) -> None:
    client = GeoClientSync(
        GeoClientConfig(
            cluster_id=0,
            addresses=[address],
            connect_timeout_ms=connect_timeout_ms,
            request_timeout_ms=request_timeout_ms,
        )
    )

    current_batch_size = batch_size

    try:
        while not state.stop_event.is_set():
            base_id = state.reserve_ids(current_batch_size)
            now_ms = int(time.time() * 1000)
            events = []
            for offset in range(current_batch_size):
                event_id = base_id + offset
                events.append(
                    GeoEvent(
                        id=event_id,
                        entity_id=(event_id % entity_mod) + 1,
                        correlation_id=0,
                        user_data=0,
                        lat_nano=37_774_900_000,
                        lon_nano=-122_419_400_000,
                        group_id=1,
                        timestamp=now_ms + offset,
                        altitude_mm=0,
                        velocity_mms=0,
                        ttl_seconds=86_400,
                        accuracy_mm=5_000,
                        heading_cdeg=0,
                        flags=GeoEventFlags.NONE,
                    )
                )

            try:
                errors = client.insert_events(events)
            except Exception as exc:
                error_text = str(exc)
                if "status=1" in error_text and current_batch_size > min_batch_size:
                    next_batch = max(min_batch_size, current_batch_size // 2)
                    if next_batch < current_batch_size:
                        current_batch_size = next_batch
                        print(
                            f"worker={worker_id} reducing batch_size to {current_batch_size} "
                            "after TOO_MUCH_DATA"
                        )
                        continue
                state.fail(f"exception:{type(exc).__name__}:{exc}")
                break

            inserted = current_batch_size - len(errors)
            state.add_inserted(inserted)

            if errors:
                first_result = int(errors[0].result)
                if first_result == 1 and current_batch_size > min_batch_size:
                    next_batch = max(min_batch_size, current_batch_size // 2)
                    if next_batch < current_batch_size:
                        current_batch_size = next_batch
                        print(
                            f"worker={worker_id} reducing batch_size to {current_batch_size} "
                            "after TOO_MUCH_DATA response"
                        )
                        continue
                state.fail(
                    reason=f"server_rejected_events:{len(errors)}",
                    error_code=first_result,
                )
                break
    finally:
        try:
            client.close()
        except Exception:
            pass
        # No extra work for worker teardown.
        _ = worker_id


def capacity_test(args: argparse.Namespace) -> int:
    run_id = int(time.time())
    data_dir = args.data_dir
    os.makedirs(data_dir, exist_ok=True)

    data_file = os.path.join(
        data_dir, f"{args.config}_{args.optimize.lower()}_real_{run_id}.archer"
    )
    log_file = os.path.join(
        data_dir, f"{args.config}_{args.optimize.lower()}_real_{run_id}.log"
    )

    request_limit = args.limit_request
    if request_limit is None and args.config != "lite":
        request_limit = "10MiB"

    data_port = free_port()
    metrics_port = free_port()
    address = f"127.0.0.1:{data_port}"

    binary = build_artifacts(
        config=args.config,
        optimize=args.optimize,
        jobs=args.jobs,
    )

    print(f"Run ID: {run_id}")
    print(f"Data file: {data_file}")
    print(f"Server log: {log_file}")
    print(
        f"Load params: workers={args.workers}, batch_size={args.batch_size}, "
        f"min_batch_size={args.min_batch_size}, entity_mod={args.entity_mod}"
    )

    state = SharedState()
    metrics = Metrics()
    server_proc: Optional[subprocess.Popen] = None
    start_time = None

    try:
        server_proc = start_server(
            binary=binary,
            config=args.config,
            data_file=data_file,
            log_file=log_file,
            data_port=data_port,
            metrics_port=metrics_port,
            request_limit=request_limit,
            ram_index_size=args.ram_index_size,
            ready_timeout_s=args.ready_timeout_seconds,
        )
        start_time = time.time()

        workers = []
        for worker_id in range(args.workers):
            thread = threading.Thread(
                target=worker_loop,
                args=(
                    worker_id,
                    state,
                    args.batch_size,
                    args.min_batch_size,
                    args.entity_mod,
                    address,
                    args.connect_timeout_ms,
                    args.request_timeout_ms,
                ),
                daemon=True,
            )
            thread.start()
            workers.append(thread)

        last_status = 0.0
        while True:
            rss_bytes, cpu_percent = sample_process(server_proc.pid)
            metrics.add(rss_bytes, cpu_percent)

            if server_proc.poll() is not None and not state.stop_event.is_set():
                state.fail(f"server_exited:{server_proc.returncode}")

            now = time.time()
            if now - last_status >= args.status_interval_seconds:
                elapsed = max(now - start_time, 1e-9)
                rate = state.total_inserted / elapsed
                rss_mib = (rss_bytes / (1024 * 1024)) if rss_bytes else 0.0
                cpu_now = cpu_percent if cpu_percent is not None else 0.0
                print(
                    f"Inserted={state.total_inserted:,} "
                    f"Rate={rate:,.0f}/s CPU={cpu_now:.1f}% RSS={rss_mib:,.0f}MiB"
                )
                last_status = now

            if state.stop_event.is_set():
                break
            if not any(thread.is_alive() for thread in workers):
                break

            time.sleep(args.sample_interval_seconds)

        # Ensure all workers stop quickly.
        state.stop_event.set()
        for thread in workers:
            thread.join(timeout=2)
    except KeyboardInterrupt:
        state.fail("interrupted_by_user")
    finally:
        stop_server(server_proc)

    end_time = time.time()
    elapsed_s = (end_time - start_time) if start_time else 0.0

    logical_size = os.path.getsize(data_file) if os.path.exists(data_file) else 0
    physical_size = 0
    if os.path.exists(data_file):
        stat_result = os.stat(data_file)
        physical_size = stat_result.st_blocks * 512

    du_bytes = None
    if os.path.exists(data_file):
        try:
            output = subprocess.check_output(["du", "-k", data_file], text=True).strip()
            du_kib = int(output.split()[0])
            du_bytes = du_kib * 1024
        except Exception:
            du_bytes = None

    summary = {
        "run_id": run_id,
        "config": args.config,
        "optimize": args.optimize,
        "workers": args.workers,
        "batch_size": args.batch_size,
        "ram_index_size": args.ram_index_size,
        "entity_mod": args.entity_mod,
        "events_inserted": state.total_inserted,
        "unique_entries": min(state.total_inserted, args.entity_mod),
        "failure_reason": state.failure_reason,
        "first_error_code": state.first_error_code,
        "elapsed_seconds": elapsed_s,
        "avg_insert_rate_events_per_sec": (
            state.total_inserted / elapsed_s if elapsed_s > 0 else 0.0
        ),
        "cpu_percent_avg": metrics.cpu_avg,
        "cpu_percent_peak": metrics.cpu_peak if metrics.cpu_count > 0 else None,
        "ram_rss_avg_bytes": metrics.rss_avg,
        "ram_rss_peak_bytes": metrics.rss_peak if metrics.rss_count > 0 else None,
        "disk_logical_bytes": logical_size,
        "disk_physical_bytes_from_stat": physical_size,
        "disk_physical_bytes_from_du": du_bytes,
        "data_file": data_file,
        "server_log": log_file,
    }

    print("RESULT_JSON_START")
    print(json.dumps(summary, indent=2, sort_keys=True))
    print("RESULT_JSON_END")

    if args.cleanup:
        cleanup_artifacts([data_file, log_file])

    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run real ArcherDB capacity tests")
    parser.add_argument("--config", choices=TIER_CHOICES, default="lite")
    parser.add_argument("--optimize", choices=OPTIMIZE_CHOICES, default="ReleaseFast")
    parser.add_argument("--workers", type=int, default=4, help="Parallel insert workers")
    parser.add_argument(
        "--batch-size",
        type=int,
        default=200,
        help="Events per request per worker",
    )
    parser.add_argument(
        "--min-batch-size",
        type=int,
        default=1,
        help="Smallest worker batch size after TOO_MUCH_DATA backoff",
    )
    parser.add_argument(
        "--entity-mod",
        type=int,
        default=100_000_000,
        help="entity_id wraps at this modulus to control unique cardinality",
    )
    parser.add_argument(
        "--data-dir",
        default="/tmp/archerdb_capacity_runs",
        help="Directory for data and log files (default: /tmp/archerdb_capacity_runs)",
    )
    parser.add_argument(
        "--limit-request",
        default=None,
        help="Optional --limit-request value (auto 10MiB for non-lite if omitted)",
    )
    parser.add_argument(
        "--ram-index-size",
        default=None,
        help="Optional --ram-index-size override (requires --experimental at server start)",
    )
    parser.add_argument("--jobs", type=int, default=4, help="Build parallelism")
    parser.add_argument("--connect-timeout-ms", type=int, default=20_000)
    parser.add_argument("--request-timeout-ms", type=int, default=120_000)
    parser.add_argument("--ready-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--sample-interval-seconds", type=float, default=1.0)
    parser.add_argument("--status-interval-seconds", type=float, default=5.0)
    parser.set_defaults(cleanup=True)
    parser.add_argument(
        "--cleanup",
        dest="cleanup",
        action="store_true",
        help="Delete generated artifacts at end (default: enabled)",
    )
    parser.add_argument(
        "--no-cleanup",
        dest="cleanup",
        action="store_false",
        help="Keep generated artifacts (.archer/.log) for debugging",
    )
    return parser.parse_args()


if __name__ == "__main__":
    os.chdir(ROOT)
    arguments = parse_args()
    if arguments.batch_size < 1:
        raise SystemExit("--batch-size must be >= 1")
    if arguments.min_batch_size < 1:
        raise SystemExit("--min-batch-size must be >= 1")
    if arguments.min_batch_size > arguments.batch_size:
        raise SystemExit("--min-batch-size cannot exceed --batch-size")
    raise SystemExit(capacity_test(arguments))
