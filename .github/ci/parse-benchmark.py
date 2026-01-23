#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2025 ArcherDB Contributors
"""Parse ArcherDB benchmark output into github-action-benchmark JSON format.

This script parses the text output from `archerdb benchmark` and converts
it to the JSON format expected by github-action-benchmark for tracking
performance regressions over time.

Usage:
    python3 parse-benchmark.py benchmark-results.txt > benchmark-results.json
"""
import json
import re
import sys


def parse_benchmark(filename: str) -> list[dict]:
    """Parse benchmark output file and return metrics list.

    Args:
        filename: Path to the benchmark results text file.

    Returns:
        List of metric dictionaries in github-action-benchmark format.
    """
    results = []

    try:
        with open(filename) as f:
            content = f.read()
    except FileNotFoundError:
        # Return empty results if file not found
        print(json.dumps([]))
        return []

    # Parse insert throughput (events/s)
    match = re.search(r'throughput\s*[=:]\s*(\d+(?:,\d+)?)\s*events/s', content, re.IGNORECASE)
    if match:
        value = int(match.group(1).replace(',', ''))
        results.append({
            'name': 'Insert Throughput',
            'unit': 'events/s',
            'value': value,
            'biggerIsBetter': True
        })

    # Parse insert latency p99
    match = re.search(r'insert\s+(?:batch\s+)?latency\s+p99\s*[=:]\s*(\d+(?:\.\d+)?)\s*(?:ms|us)', content, re.IGNORECASE)
    if match:
        results.append({
            'name': 'Insert p99 Latency',
            'unit': 'ms',
            'value': float(match.group(1))
        })

    # Parse UUID query latency p99
    match = re.search(r'(?:uuid|point)\s+query\s+(?:latency\s+)?p99\s*[=:]\s*(\d+(?:\.\d+)?)\s*(?:ms|us)', content, re.IGNORECASE)
    if match:
        results.append({
            'name': 'UUID Query p99 Latency',
            'unit': 'ms',
            'value': float(match.group(1))
        })

    # Parse radius query latency p99
    match = re.search(r'radius\s+query\s+(?:latency\s+)?p99\s*[=:]\s*(\d+(?:\.\d+)?)\s*(?:ms|us)', content, re.IGNORECASE)
    if match:
        results.append({
            'name': 'Radius Query p99 Latency',
            'unit': 'ms',
            'value': float(match.group(1))
        })

    # Parse polygon query latency p99
    match = re.search(r'polygon\s+query\s+(?:latency\s+)?p99\s*[=:]\s*(\d+(?:\.\d+)?)\s*(?:ms|us)', content, re.IGNORECASE)
    if match:
        results.append({
            'name': 'Polygon Query p99 Latency',
            'unit': 'ms',
            'value': float(match.group(1))
        })

    # Parse memory usage if present
    match = re.search(r'peak\s+memory\s*[=:]\s*(\d+(?:\.\d+)?)\s*(?:MB|GB)', content, re.IGNORECASE)
    if match:
        unit_match = re.search(r'(MB|GB)', content, re.IGNORECASE)
        value = float(match.group(1))
        if unit_match and unit_match.group(1).upper() == 'GB':
            value *= 1024  # Convert to MB
        results.append({
            'name': 'Peak Memory',
            'unit': 'MB',
            'value': value
        })

    # Parse total events processed
    match = re.search(r'total\s+events\s*[=:]\s*(\d+(?:,\d+)?)', content, re.IGNORECASE)
    if match:
        results.append({
            'name': 'Total Events',
            'unit': 'count',
            'value': int(match.group(1).replace(',', ''))
        })

    return results


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: python3 parse-benchmark.py <benchmark-results.txt>", file=sys.stderr)
        sys.exit(1)

    results = parse_benchmark(sys.argv[1])
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
