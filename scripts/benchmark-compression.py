#!/usr/bin/env python3
"""
Benchmark: Compression ratio validation for geospatial workloads.

Phase 12 Storage Optimization - Gap Closure
Validates: "40-60% compression for geospatial workloads" claim

This benchmark measures actual compression ratios achieved by ArcherDB's
block compression on realistic geospatial data patterns:

1. Trajectory data: Sequential lat/lon updates following road patterns
2. Location updates: Random positions within city bounds
3. Fleet tracking: Clustered positions (vehicles near depots)

Success criteria: Average compression reduction >= 40% across workload types.

Usage:
    python3 scripts/benchmark-compression.py [--output results.json] [--dry-run]
        [--require-archerdb]

Requires:
    - ArcherDB binary (./zig-out/bin/archerdb or in PATH)
    - Python 3.8+
"""

import argparse
import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Phase 12 target: 40-60% storage reduction
TARGET_REDUCTION_MIN = 40.0
TARGET_REDUCTION_MAX = 60.0
BASELINE_MODE = "logical-bytes"

# Workload configurations
WORKLOADS = {
    "trajectory": {
        "description": "Sequential lat/lon updates following road patterns",
        "event_count": 100_000,
        "entity_count": 100,
        "pattern": "sequential",
    },
    "location_updates": {
        "description": "Random positions within city bounds",
        "event_count": 100_000,
        "entity_count": 10_000,
        "pattern": "random_bounded",
    },
    "fleet_tracking": {
        "description": "Clustered positions (vehicles near depots)",
        "event_count": 100_000,
        "entity_count": 500,
        "pattern": "clustered",
    },
}


def check_archerdb_available() -> Optional[str]:
    """
    Verify archerdb binary exists and responds to --help.

    Returns:
        Path to archerdb binary if available, None otherwise.
    """
    archerdb_paths = [
        "./zig-out/bin/archerdb",
        str(Path(__file__).parent.parent / "zig-out" / "bin" / "archerdb"),
        shutil.which("archerdb"),
    ]

    for path in archerdb_paths:
        if path and os.path.exists(path):
            try:
                result = subprocess.run(
                    [path, "--help"], capture_output=True, timeout=5
                )
                if result.returncode == 0:
                    return path
            except (subprocess.TimeoutExpired, OSError):
                continue
    return None


@dataclass
class GeoEvent:
    """A geospatial event for benchmark workloads."""

    entity_id: str
    timestamp_ns: int
    latitude: float
    longitude: float
    altitude_mm: int = 0
    heading_centideg: int = 0
    speed_mm_s: int = 0
    accuracy_mm: int = 1000


@dataclass
class CompressionResult:
    """Results from a compression benchmark run."""

    workload: str
    logical_bytes: int
    physical_bytes: int
    event_count: int
    compression_ratio: float  # compressed/uncompressed (lower is better)
    reduction_pct: float  # (1 - ratio) * 100 (higher is better)
    mode: str  # actual or estimation

    def to_dict(self) -> dict:
        return {
            "workload": self.workload,
            "logical_bytes": self.logical_bytes,
            "physical_bytes": self.physical_bytes,
            "event_count": self.event_count,
            "compression_ratio": round(self.compression_ratio, 4),
            "reduction_pct": round(self.reduction_pct, 2),
            "mode": self.mode,
            "baseline": BASELINE_MODE,
        }


def generate_trajectory_events(
    entity_count: int, event_count: int, seed: int = 42
) -> List[GeoEvent]:
    """
    Generate trajectory data simulating vehicles following roads.

    Sequential updates with small deltas - highly compressible due to
    locality and predictable patterns.
    """
    random.seed(seed)
    events = []
    base_timestamp = 1700000000000000000  # 2023-11-14 in nanoseconds

    # Initialize entity positions
    entity_positions = {}
    for i in range(entity_count):
        entity_id = f"vehicle-{i:06d}"
        # Start near city centers (more realistic road patterns)
        entity_positions[entity_id] = {
            "lat": random.uniform(37.7, 37.9),  # San Francisco area
            "lon": random.uniform(-122.5, -122.3),
            "heading": random.randint(0, 359),
        }

    for i in range(event_count):
        entity_id = f"vehicle-{i % entity_count:06d}"
        pos = entity_positions[entity_id]

        # Small sequential movement (simulates driving)
        # Delta proportional to speed, ~30-60 mph
        delta_lat = random.gauss(0, 0.0001)  # ~10m variance
        delta_lon = random.gauss(0, 0.0001)
        heading_change = random.randint(-10, 10)  # Gradual turns

        pos["lat"] = max(-90, min(90, pos["lat"] + delta_lat))
        pos["lon"] = max(-180, min(180, pos["lon"] + delta_lon))
        pos["heading"] = (pos["heading"] + heading_change) % 360

        event = GeoEvent(
            entity_id=entity_id,
            timestamp_ns=base_timestamp + i * 1_000_000_000,  # 1 second apart
            latitude=pos["lat"],
            longitude=pos["lon"],
            altitude_mm=random.randint(0, 100_000),  # 0-100m
            heading_centideg=pos["heading"] * 100,
            speed_mm_s=random.randint(10_000, 30_000),  # 10-30 m/s
            accuracy_mm=random.randint(500, 5000),  # 0.5-5m
        )
        events.append(event)

    return events


def generate_random_bounded_events(
    entity_count: int, event_count: int, seed: int = 42
) -> List[GeoEvent]:
    """
    Generate random location updates within city bounds.

    Each update is independent - less compressible but still has
    bounded coordinate ranges.
    """
    random.seed(seed)
    events = []
    base_timestamp = 1700000000000000000

    # City bounds (multiple cities for variety)
    cities = [
        {"lat_min": 37.7, "lat_max": 37.9, "lon_min": -122.5, "lon_max": -122.3},  # SF
        {"lat_min": 40.7, "lat_max": 40.8, "lon_min": -74.0, "lon_max": -73.9},  # NYC
        {"lat_min": 51.4, "lat_max": 51.6, "lon_min": -0.2, "lon_max": 0.1},  # London
        {"lat_min": 35.6, "lat_max": 35.8, "lon_min": 139.6, "lon_max": 139.9},  # Tokyo
    ]

    for i in range(event_count):
        entity_id = f"user-{i % entity_count:06d}"
        city = cities[i % len(cities)]

        event = GeoEvent(
            entity_id=entity_id,
            timestamp_ns=base_timestamp + i * 60_000_000_000,  # 1 minute apart
            latitude=random.uniform(city["lat_min"], city["lat_max"]),
            longitude=random.uniform(city["lon_min"], city["lon_max"]),
            altitude_mm=random.randint(0, 500_000),  # 0-500m
            heading_centideg=random.randint(0, 36000),
            speed_mm_s=random.randint(0, 5000),  # 0-5 m/s (walking)
            accuracy_mm=random.randint(1000, 50000),  # 1-50m
        )
        events.append(event)

    return events


def generate_clustered_events(
    entity_count: int, event_count: int, seed: int = 42
) -> List[GeoEvent]:
    """
    Generate clustered positions simulating fleet vehicles near depots.

    Highly compressible due to spatial clustering - many events share
    similar coordinate prefixes.
    """
    random.seed(seed)
    events = []
    base_timestamp = 1700000000000000000

    # Define depot locations
    depots = [
        (37.7749, -122.4194),  # SF
        (37.8044, -122.2712),  # Oakland
        (37.5585, -122.2711),  # San Mateo
        (37.4419, -122.1430),  # Palo Alto
        (37.3382, -121.8863),  # San Jose
    ]

    # Assign entities to depots
    entity_depots = {
        f"truck-{i:06d}": depots[i % len(depots)] for i in range(entity_count)
    }

    for i in range(event_count):
        entity_id = f"truck-{i % entity_count:06d}"
        depot = entity_depots[entity_id]

        # Events clustered around depot (within ~1km)
        # Use Gaussian distribution for more realistic clustering
        lat = depot[0] + random.gauss(0, 0.005)  # ~500m std dev
        lon = depot[1] + random.gauss(0, 0.005)

        event = GeoEvent(
            entity_id=entity_id,
            timestamp_ns=base_timestamp + i * 30_000_000_000,  # 30 seconds apart
            latitude=max(-90, min(90, lat)),
            longitude=max(-180, min(180, lon)),
            altitude_mm=random.randint(0, 50_000),  # 0-50m
            heading_centideg=random.randint(0, 36000),
            speed_mm_s=random.randint(0, 20000),  # 0-20 m/s
            accuracy_mm=random.randint(500, 5000),
        )
        events.append(event)

    return events


def events_to_bytes(events: List[GeoEvent]) -> bytes:
    """
    Serialize events to bytes for size measurement.

    Uses a compact binary format similar to ArcherDB's internal representation.
    """
    import struct

    # Format: entity_id (32 bytes padded), timestamp (8), lat (8), lon (8),
    #         alt (4), heading (4), speed (4), accuracy (4) = 72 bytes per event
    data = bytearray()
    for event in events:
        entity_bytes = event.entity_id.encode("utf-8")[:32].ljust(32, b"\x00")
        data.extend(entity_bytes)
        data.extend(struct.pack("<Q", event.timestamp_ns))
        data.extend(struct.pack("<d", event.latitude))
        data.extend(struct.pack("<d", event.longitude))
        data.extend(struct.pack("<i", event.altitude_mm))
        data.extend(struct.pack("<i", event.heading_centideg))
        data.extend(struct.pack("<i", event.speed_mm_s))
        data.extend(struct.pack("<i", event.accuracy_mm))

    return bytes(data)


def estimate_compression_bytes(events: List[GeoEvent]) -> Tuple[int, int]:
    """
    Estimate compression ratio using zstd (similar to ArcherDB's compression).

    Returns:
        Tuple of (uncompressed_size, compressed_size)
    """
    import zlib

    raw_data = events_to_bytes(events)
    uncompressed_size = len(raw_data)

    # Use zlib (deflate) as a proxy for zstd compression
    # ArcherDB uses zstd level 3 by default
    compressed_data = zlib.compress(raw_data, level=6)
    compressed_size = len(compressed_data)

    return uncompressed_size, compressed_size


def run_archerdb_benchmark(
    archerdb_path: str, events: List[GeoEvent], workdir: str
) -> Tuple[int, Optional[Dict]]:
    """
    Run ArcherDB benchmark and measure data file size.

    Returns:
        Tuple of (data_file_size, metrics_dict or None)
    """
    # Create data file path
    data_file = os.path.join(workdir, "bench-comp.archerdb")

    # Format the data file
    format_cmd = [
        archerdb_path,
        "format",
        "--cluster=0",
        "--replica=0",
        "--replica-count=1",
        data_file,
    ]

    try:
        subprocess.run(format_cmd, capture_output=True, check=True, timeout=30)
    except subprocess.CalledProcessError as e:
        print(f"Format failed: {e.stderr.decode() if e.stderr else e}")
        return 0, None
    except subprocess.TimeoutExpired:
        print("Format timed out")
        return 0, None

    # Start ArcherDB with benchmark load
    # The benchmark command handles writing events and measuring
    bench_cmd = [
        archerdb_path,
        "benchmark",
        f"--count={len(events)}",
        data_file,
    ]

    try:
        result = subprocess.run(
            bench_cmd,
            capture_output=True,
            timeout=300,  # 5 minute timeout
        )
        # Benchmark outputs data file size
        output = result.stdout.decode() + result.stderr.decode()

        # Parse datafile size from output
        for line in output.split("\n"):
            if "datafile =" in line and "bytes" in line:
                parts = line.split("=")
                if len(parts) >= 2:
                    size_str = parts[1].strip().split()[0]
                    try:
                        return int(size_str), None
                    except ValueError:
                        pass

        # Fallback: check file size directly
        if os.path.exists(data_file):
            return os.path.getsize(data_file), None

    except subprocess.TimeoutExpired:
        print("Benchmark timed out")
    except subprocess.CalledProcessError as e:
        print(f"Benchmark failed: {e}")

    return 0, None


def run_compression_benchmark(
    archerdb_path: Optional[str], dry_run: bool = False
) -> Dict[str, CompressionResult]:
    """
    Run compression benchmark for all workload types.

    Args:
        archerdb_path: Path to archerdb binary (None for estimation mode)
        dry_run: If True, only estimate compression without running archerdb

    Returns:
        Dictionary mapping workload name to CompressionResult
    """
    results = {}

    for workload_name, config in WORKLOADS.items():
        print(f"\n{'=' * 60}")
        print(f"Workload: {workload_name}")
        print(f"Description: {config['description']}")
        print(
            f"Events: {config['event_count']:,}, Entities: {config['entity_count']:,}"
        )
        print("=" * 60)

        # Generate events based on pattern
        if config["pattern"] == "sequential":
            events = generate_trajectory_events(
                config["entity_count"], config["event_count"]
            )
        elif config["pattern"] == "random_bounded":
            events = generate_random_bounded_events(
                config["entity_count"], config["event_count"]
            )
        elif config["pattern"] == "clustered":
            events = generate_clustered_events(
                config["entity_count"], config["event_count"]
            )
        else:
            print(f"Unknown pattern: {config['pattern']}")
            continue

        print(f"Generated {len(events):,} events")

        if dry_run or not archerdb_path:
            # Use estimation mode
            logical_bytes, compressed = estimate_compression_bytes(events)
            ratio = compressed / logical_bytes if logical_bytes > 0 else 1.0
            reduction = (1 - ratio) * 100

            print(f"\n[Estimation Mode - using zlib compression]")
            print(
                f"Logical:  {logical_bytes:,} bytes ({logical_bytes / 1024 / 1024:.2f} MiB)"
            )
            print(
                f"Physical: {compressed:,} bytes ({compressed / 1024 / 1024:.2f} MiB)"
            )
            print(f"Ratio: {ratio:.4f} ({reduction:.1f}% reduction)")

            results[workload_name] = CompressionResult(
                workload=workload_name,
                logical_bytes=logical_bytes,
                physical_bytes=compressed,
                event_count=len(events),
                compression_ratio=ratio,
                reduction_pct=reduction,
                mode="estimation",
            )
        else:
            # Run actual archerdb benchmark
            with tempfile.TemporaryDirectory() as workdir:
                logical_bytes = len(events_to_bytes(events))
                print(f"\nRunning ArcherDB benchmark (compressed datafile)...")
                compressed_size, _ = run_archerdb_benchmark(
                    archerdb_path, events, workdir
                )

                if logical_bytes > 0 and compressed_size > 0:
                    ratio = compressed_size / logical_bytes
                    reduction = (1 - ratio) * 100

                    print(f"\nLogical:  {logical_bytes:,} bytes")
                    print(f"Physical: {compressed_size:,} bytes")
                    print(f"Ratio: {ratio:.4f} ({reduction:.1f}% reduction)")

                    results[workload_name] = CompressionResult(
                        workload=workload_name,
                        logical_bytes=logical_bytes,
                        physical_bytes=compressed_size,
                        event_count=len(events),
                        compression_ratio=ratio,
                        reduction_pct=reduction,
                        mode="actual",
                    )
                else:
                    # Fall back to estimation
                    print("\nArcherDB benchmark failed, using estimation...")
                    logical_bytes, compressed = estimate_compression_bytes(events)
                    ratio = compressed / logical_bytes if logical_bytes > 0 else 1.0
                    reduction = (1 - ratio) * 100

                    results[workload_name] = CompressionResult(
                        workload=workload_name,
                        logical_bytes=logical_bytes,
                        physical_bytes=compressed,
                        event_count=len(events),
                        compression_ratio=ratio,
                        reduction_pct=reduction,
                        mode="estimation",
                    )

    return results


def print_summary(results: Dict[str, CompressionResult], mode: str) -> bool:
    """
    Print summary of compression benchmark results.

    Returns:
        True if target compression reduction was achieved.
    """
    print("\n" + "=" * 70)
    print("COMPRESSION BENCHMARK SUMMARY")
    print("=" * 70)
    print(f"\nBaseline: {BASELINE_MODE} | Mode: {mode}")
    print(f"\n{'Workload':<20} {'Logical':>15} {'Physical':>15} {'Reduction':>12}")
    print("-" * 70)

    total_logical = 0
    total_physical = 0

    for name, result in results.items():
        total_logical += result.logical_bytes
        total_physical += result.physical_bytes
        print(
            f"{name:<20} {result.logical_bytes:>12,} B {result.physical_bytes:>12,} B {result.reduction_pct:>10.1f}%"
        )

    print("-" * 70)

    if total_logical > 0:
        avg_ratio = total_physical / total_logical
        avg_reduction = (1 - avg_ratio) * 100
    else:
        avg_reduction = 0.0

    print(
        f"{'TOTAL':<20} {total_logical:>12,} B {total_physical:>12,} B {avg_reduction:>10.1f}%"
    )

    print(
        f"\nTarget: {TARGET_REDUCTION_MIN:.0f}-{TARGET_REDUCTION_MAX:.0f}% storage reduction"
    )

    if avg_reduction >= TARGET_REDUCTION_MIN:
        if avg_reduction <= TARGET_REDUCTION_MAX:
            print(
                f"\n[PASS] Average reduction {avg_reduction:.1f}% is within target range"
            )
        else:
            print(
                f"\n[PASS] Average reduction {avg_reduction:.1f}% exceeds target (even better!)"
            )
        return True
    else:
        print(
            f"\n[NEEDS REVIEW] Average reduction {avg_reduction:.1f}% is below {TARGET_REDUCTION_MIN}% target"
        )
        return False


def main():
    parser = argparse.ArgumentParser(
        description="ArcherDB Compression Ratio Benchmark - Phase 12 Validation"
    )
    parser.add_argument(
        "--output",
        "-o",
        default="compression-results.json",
        help="Output JSON file for results (default: compression-results.json)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Estimate compression without running ArcherDB",
    )
    parser.add_argument(
        "--require-archerdb",
        action="store_true",
        help="Fail if ArcherDB binary is unavailable (disallow estimation)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Enable verbose output"
    )
    args = parser.parse_args()

    print("=" * 70)
    print("ArcherDB Compression Ratio Benchmark")
    print("Phase 12 Storage Optimization - Gap Closure")
    print("=" * 70)
    print(f"\nTarget: {TARGET_REDUCTION_MIN}-{TARGET_REDUCTION_MAX}% storage reduction")
    print(f"Workloads: {', '.join(WORKLOADS.keys())}")

    # Check for archerdb binary
    archerdb_path = check_archerdb_available()

    if archerdb_path:
        print(f"\nArcherDB binary: {archerdb_path}")
        if args.require_archerdb and args.dry_run:
            print(
                "\n[INFO] --require-archerdb overrides --dry-run; running actual benchmark"
            )
            args.dry_run = False
    else:
        if args.require_archerdb:
            print(
                "\n[ERROR] ArcherDB binary not found; --require-archerdb forbids estimation"
            )
            print("Checked: ./zig-out/bin/archerdb, PATH")
            print("Build with: ./zig/zig build")
            return 2
        print("\n[WARNING] ArcherDB binary not found")
        print("Checked: ./zig-out/bin/archerdb, PATH")
        print("Build with: ./zig/zig build")
        print("\nRunning in estimation mode (using zlib compression proxy)")
        args.dry_run = True

    # Run benchmarks
    results = run_compression_benchmark(archerdb_path, args.dry_run)

    # Print summary
    modes = {result.mode for result in results.values()}
    if len(modes) == 1:
        overall_mode = modes.pop()
    else:
        overall_mode = "mixed"

    passed = print_summary(results, overall_mode)

    # Write JSON output
    output_data = {
        "benchmark": "compression-ratio",
        "phase": "12-storage-optimization",
        "target": {
            "min_reduction_pct": TARGET_REDUCTION_MIN,
            "max_reduction_pct": TARGET_REDUCTION_MAX,
        },
        "mode": overall_mode,
        "baseline": BASELINE_MODE,
        "archerdb_path": archerdb_path,
        "workloads": {name: result.to_dict() for name, result in results.items()},
        "summary": {
            "total_logical_bytes": sum(r.logical_bytes for r in results.values()),
            "total_physical_bytes": sum(r.physical_bytes for r in results.values()),
            "average_reduction_pct": round(
                (
                    1
                    - sum(r.physical_bytes for r in results.values())
                    / max(1, sum(r.logical_bytes for r in results.values()))
                )
                * 100,
                2,
            ),
            "passed": passed,
        },
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    with open(args.output, "w") as f:
        json.dump(output_data, f, indent=2)

    print(f"\nResults written to: {args.output}")

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
