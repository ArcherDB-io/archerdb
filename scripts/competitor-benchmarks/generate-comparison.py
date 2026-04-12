#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
Benchmark Comparison Report Generator

Parses CSV results from all benchmarks and generates a comprehensive
markdown comparison report.

Usage:
    python3 generate-comparison.py --results-dir ./benchmark-results/comparison-*
"""

import argparse
import csv
import os
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional


@dataclass
class BenchmarkEntry:
    """Single benchmark result entry."""
    database: str
    operation: str
    count: int
    duration_sec: float
    ops_per_sec: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    p999_ms: float
    errors: int


def parse_csv_file(filepath: str) -> List[BenchmarkEntry]:
    """Parse a benchmark CSV file."""
    entries = []
    with open(filepath, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            entries.append(BenchmarkEntry(
                database=row['database'],
                operation=row['operation'],
                count=int(row['count']),
                duration_sec=float(row['duration_sec']),
                ops_per_sec=float(row['ops_per_sec']),
                p50_ms=float(row['p50_ms']),
                p95_ms=float(row['p95_ms']),
                p99_ms=float(row['p99_ms']),
                p999_ms=float(row['p999_ms']),
                errors=int(row['errors']),
            ))
    return entries


def load_all_results(results_dir: str) -> Dict[str, List[BenchmarkEntry]]:
    """Load all CSV results from directory."""
    results = {}
    results_path = Path(results_dir)

    for csv_file in results_path.glob("*.csv"):
        name = csv_file.stem
        try:
            entries = parse_csv_file(str(csv_file))
            results[name] = entries
        except Exception as e:
            print(f"Warning: Could not parse {csv_file}: {e}")

    return results


def calculate_advantage(
    archerdb_value: float,
    competitor_value: float,
    higher_is_better: bool = True
) -> str:
    """Calculate advantage ratio."""
    if competitor_value == 0:
        return "N/A"

    if higher_is_better:
        ratio = archerdb_value / competitor_value
    else:
        ratio = competitor_value / archerdb_value

    if ratio >= 1:
        return f"{ratio:.1f}x faster"
    else:
        return f"{1/ratio:.1f}x slower"


def generate_operation_table(
    results: Dict[str, List[BenchmarkEntry]],
    operation: str,
    archerdb_key: str = "archerdb"
) -> str:
    """Generate comparison table for a specific operation."""
    lines = []

    # Header
    lines.append(f"| Database | Ops/sec | p50 (ms) | p95 (ms) | p99 (ms) | p99.9 (ms) | vs ArcherDB |")
    lines.append("|----------|---------|----------|----------|----------|------------|-------------|")

    # Get ArcherDB baseline
    archerdb_entry = None
    for name, entries in results.items():
        if archerdb_key in name.lower():
            for entry in entries:
                if entry.operation == operation:
                    archerdb_entry = entry
                    break

    # Generate rows
    for name, entries in sorted(results.items()):
        for entry in entries:
            if entry.operation == operation:
                if archerdb_entry and archerdb_key not in name.lower():
                    advantage = calculate_advantage(
                        archerdb_entry.ops_per_sec,
                        entry.ops_per_sec,
                        higher_is_better=True
                    )
                else:
                    advantage = "-"

                lines.append(
                    f"| {entry.database} | {entry.ops_per_sec:,.0f} | "
                    f"{entry.p50_ms:.3f} | {entry.p95_ms:.3f} | "
                    f"{entry.p99_ms:.3f} | {entry.p999_ms:.3f} | {advantage} |"
                )

    return "\n".join(lines)


def generate_report(results: Dict[str, List[BenchmarkEntry]], output_path: str) -> None:
    """Generate markdown comparison report."""
    lines = []

    # Header
    lines.append("# ArcherDB Competitor Benchmark Comparison")
    lines.append("")
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")

    # Table of contents
    lines.append("## Table of Contents")
    lines.append("")
    lines.append("- [Summary](#summary)")
    lines.append("- [Insert Throughput](#insert-throughput)")
    lines.append("- [UUID Lookup](#uuid-lookup)")
    lines.append("- [Radius Query](#radius-query)")
    lines.append("- [Polygon Query](#polygon-query)")
    lines.append("- [Methodology](#methodology)")
    lines.append("")

    # Summary
    lines.append("## Summary")
    lines.append("")
    lines.append("This report compares ArcherDB's geospatial performance against:")
    lines.append("")
    lines.append("- **PostGIS** - PostgreSQL with PostGIS extension (BENCH-03)")
    lines.append("- **Tile38** - Dedicated geospatial database (BENCH-04)")
    lines.append("- **Elasticsearch** - Search engine with geo capabilities (BENCH-05)")
    lines.append("- **Aerospike** - High-performance key-value with geo (BENCH-06)")
    lines.append("")

    # Operations
    operations = [
        ("insert", "Insert Throughput", "Batch insert performance for geospatial events."),
        ("uuid_lookup", "UUID Lookup", "Point lookup by entity UUID."),
        ("radius_query", "Radius Query", "Proximity search within a radius."),
        ("polygon_query", "Polygon Query", "Containment search within a polygon."),
    ]

    for op_name, op_title, op_desc in operations:
        lines.append(f"## {op_title}")
        lines.append("")
        lines.append(op_desc)
        lines.append("")
        lines.append(generate_operation_table(results, op_name))
        lines.append("")

    # Methodology
    lines.append("## Methodology")
    lines.append("")
    lines.append("### Workload")
    lines.append("")
    lines.append("All databases were tested with identical workload parameters:")
    lines.append("")
    lines.append("- **Event generation**: Random global distribution with reproducible seed")
    lines.append("- **Batch size**: 1000 events per batch")
    lines.append("- **Radius queries**: 10km search radius")
    lines.append("- **Polygon queries**: 1-degree bounding boxes")
    lines.append("")
    lines.append("### Configuration")
    lines.append("")
    lines.append("Each database was tested with both default and tuned configurations:")
    lines.append("")
    lines.append("| Database | Default Config | Tuned Config |")
    lines.append("|----------|----------------|--------------|")
    lines.append("| PostGIS | PostgreSQL defaults | shared_buffers=2GB, effective_cache_size=6GB |")
    lines.append("| Tile38 | Default | (optimized by default) |")
    lines.append("| Elasticsearch | 1GB heap | 4GB heap, memory lock |")
    lines.append("| Aerospike | Default | 4GB memory, geo index |")
    lines.append("")
    lines.append("### Hardware")
    lines.append("")
    lines.append("All benchmarks run on the same hardware with 8GB memory limit per container.")
    lines.append("")
    lines.append("### Reproduction")
    lines.append("")
    lines.append("To reproduce these results:")
    lines.append("")
    lines.append("```bash")
    lines.append("cd scripts/competitor-benchmarks")
    lines.append("./run-comparison.sh")
    lines.append("```")
    lines.append("")

    # Write report
    with open(output_path, 'w') as f:
        f.write("\n".join(lines))

    print(f"Report generated: {output_path}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate benchmark comparison report"
    )
    parser.add_argument(
        "--results-dir", required=True,
        help="Directory containing benchmark CSV files"
    )
    parser.add_argument(
        "--output", "-o", default="comparison-report.md",
        help="Output markdown file path"
    )

    args = parser.parse_args()

    # Load results
    results = load_all_results(args.results_dir)

    if not results:
        print(f"error: no benchmark results found in {args.results_dir}", file=sys.stderr)
        print("Run ./run-comparison.sh to generate real comparison CSVs before writing a report.", file=sys.stderr)
        return 1

    # Generate report
    generate_report(results, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
