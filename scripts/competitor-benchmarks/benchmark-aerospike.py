#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
Aerospike Benchmark Driver (BENCH-06)

Runs the same geospatial workload against Aerospike that ArcherDB uses,
enabling fair performance comparison.

Usage:
    python3 benchmark-aerospike.py --entity-count 10000 --event-count 100000
"""

import argparse
import json
import os
import sys

# Add parent directory to path for common module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import (
    BenchmarkResult, GeoEvent, Timer, measure_latency,
    generate_events, generate_entity_ids, generate_query_points,
    format_results, save_results_csv,
)

try:
    import aerospike
    from aerospike import GeoJSON, predicates
except ImportError:
    print("Error: aerospike not installed. Run: pip install aerospike")
    sys.exit(1)


class AerospikeBenchmark:
    """Aerospike geospatial benchmark driver."""

    def __init__(
        self,
        host: str = "localhost",
        port: int = 3000,
        namespace: str = "geobench",
        set_name: str = "geo_events",
    ):
        self.config = {
            "hosts": [(host, port)],
            "policies": {
                "timeout": 5000,  # 5 second timeout
            }
        }
        self.namespace = namespace
        self.set_name = set_name
        self.client = None

    def connect(self):
        """Establish connection to Aerospike."""
        self.client = aerospike.client(self.config).connect()

    def close(self):
        """Close connection."""
        if self.client:
            self.client.close()

    def clear_data(self):
        """Clear all benchmark data by truncating the set."""
        try:
            self.client.truncate(self.namespace, self.set_name, 0)
        except aerospike.exception.AerospikeError:
            pass  # Set may not exist

    def benchmark_insert(
        self,
        events: list,
        batch_size: int = 1000
    ) -> BenchmarkResult:
        """
        Benchmark inserts using put() with GeoJSON.

        Args:
            events: List of GeoEvent objects to insert
            batch_size: Number of events per batch (for latency measurement)

        Returns:
            BenchmarkResult with insert performance data
        """
        latencies = []
        errors = 0

        with Timer() as timer:
            for i in range(0, len(events), batch_size):
                batch = events[i:i + batch_size]

                try:
                    with measure_latency(latencies):
                        for e in batch:
                            key = (self.namespace, self.set_name, e.entity_id)

                            # Create GeoJSON point
                            location = GeoJSON({
                                "type": "Point",
                                "coordinates": [e.longitude, e.latitude]
                            })

                            bins = {
                                "entity_id": e.entity_id,
                                "timestamp_ns": e.timestamp_ns,
                                "location": location,
                                "altitude_mm": e.altitude_mm,
                                "heading_centideg": e.heading_centideg,
                                "speed_mm_s": e.speed_mm_s,
                                "accuracy_mm": e.accuracy_mm,
                            }

                            self.client.put(key, bins)
                except Exception as ex:
                    errors += 1
                    print(f"Insert error: {ex}")

        return BenchmarkResult(
            operation="insert",
            count=len(events),
            duration_sec=timer.duration_sec,
            latencies_ms=latencies,
            errors=errors,
        )

    def benchmark_uuid_lookup(
        self,
        entity_ids: list,
        query_count: int = 10000
    ) -> BenchmarkResult:
        """
        Benchmark entity lookups using get().

        Args:
            entity_ids: List of entity IDs to query
            query_count: Number of queries to perform

        Returns:
            BenchmarkResult with lookup performance data
        """
        latencies = []
        errors = 0

        with Timer() as timer:
            for i in range(query_count):
                entity_id = entity_ids[i % len(entity_ids)]
                key = (self.namespace, self.set_name, entity_id)

                try:
                    with measure_latency(latencies):
                        self.client.get(key)
                except aerospike.exception.RecordNotFound:
                    pass  # Expected for some queries
                except Exception as ex:
                    errors += 1
                    print(f"Lookup error: {ex}")

        return BenchmarkResult(
            operation="uuid_lookup",
            count=query_count,
            duration_sec=timer.duration_sec,
            latencies_ms=latencies,
            errors=errors,
        )

    def benchmark_radius_query(
        self,
        query_points: list,
        radius_meters: float = 10000,
        query_count: int = 1000
    ) -> BenchmarkResult:
        """
        Benchmark radius/proximity queries using geo_within_radius.

        Args:
            query_points: List of (lat, lon) query centers
            radius_meters: Search radius in meters
            query_count: Number of queries to perform

        Returns:
            BenchmarkResult with query performance data
        """
        latencies = []
        errors = 0

        with Timer() as timer:
            for i in range(query_count):
                lat, lon = query_points[i % len(query_points)]

                try:
                    with measure_latency(latencies):
                        query = self.client.query(self.namespace, self.set_name)
                        query.where(
                            predicates.geo_within_radius(
                                "location", lon, lat, radius_meters
                            )
                        )

                        # Execute and consume results
                        results = []
                        for record in query.results():
                            results.append(record)
                            if len(results) >= 1000:
                                break

                except Exception as ex:
                    errors += 1
                    print(f"Radius query error: {ex}")

        return BenchmarkResult(
            operation="radius_query",
            count=query_count,
            duration_sec=timer.duration_sec,
            latencies_ms=latencies,
            errors=errors,
        )

    def benchmark_polygon_query(
        self,
        query_count: int = 100
    ) -> BenchmarkResult:
        """
        Benchmark polygon containment queries using geo_within_geojson_region.

        Args:
            query_count: Number of queries to perform

        Returns:
            BenchmarkResult with query performance data
        """
        import random
        random.seed(54321)

        latencies = []
        errors = 0

        with Timer() as timer:
            for _ in range(query_count):
                # Random 1-degree box
                min_lat = random.uniform(-89, 88)
                min_lon = random.uniform(-179, 178)
                max_lat = min_lat + 1
                max_lon = min_lon + 1

                # GeoJSON polygon (closed ring)
                polygon = {
                    "type": "Polygon",
                    "coordinates": [[
                        [min_lon, min_lat],
                        [max_lon, min_lat],
                        [max_lon, max_lat],
                        [min_lon, max_lat],
                        [min_lon, min_lat],  # Close the ring
                    ]]
                }

                try:
                    with measure_latency(latencies):
                        query = self.client.query(self.namespace, self.set_name)
                        query.where(
                            predicates.geo_within_geojson_region(
                                "location", json.dumps(polygon)
                            )
                        )

                        # Execute and consume results
                        results = []
                        for record in query.results():
                            results.append(record)
                            if len(results) >= 1000:
                                break

                except Exception as ex:
                    errors += 1
                    print(f"Polygon query error: {ex}")

        return BenchmarkResult(
            operation="polygon_query",
            count=query_count,
            duration_sec=timer.duration_sec,
            latencies_ms=latencies,
            errors=errors,
        )


def main():
    parser = argparse.ArgumentParser(
        description="Aerospike Benchmark Driver (BENCH-06)"
    )
    parser.add_argument(
        "--host", default=os.getenv("AEROSPIKE_HOST", "localhost"),
        help="Aerospike host"
    )
    parser.add_argument(
        "--port", type=int, default=int(os.getenv("AEROSPIKE_PORT", "3000")),
        help="Aerospike port"
    )
    parser.add_argument(
        "--namespace", default="geobench",
        help="Aerospike namespace"
    )
    parser.add_argument(
        "--entity-count", type=int, default=10000,
        help="Number of unique entities"
    )
    parser.add_argument(
        "--event-count", type=int, default=100000,
        help="Number of events to insert"
    )
    parser.add_argument(
        "--query-count", type=int, default=10000,
        help="Number of queries to perform"
    )
    parser.add_argument(
        "--radius-meters", type=float, default=10000,
        help="Radius for proximity queries in meters"
    )
    parser.add_argument(
        "--batch-size", type=int, default=1000,
        help="Batch size for inserts"
    )
    parser.add_argument(
        "--output", "-o", default=None,
        help="Output CSV file path"
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output results as JSON"
    )

    args = parser.parse_args()

    print(f"Aerospike Benchmark (BENCH-06)")
    print(f"  Host: {args.host}:{args.port}")
    print(f"  Namespace: {args.namespace}")
    print(f"  Entities: {args.entity_count:,}")
    print(f"  Events: {args.event_count:,}")
    print(f"  Queries: {args.query_count:,}")
    print()

    # Generate test data
    print("Generating test data...")
    events = generate_events(args.entity_count, args.event_count)
    entity_ids = generate_entity_ids(args.entity_count)
    query_points = generate_query_points(args.query_count)

    # Run benchmark
    bench = AerospikeBenchmark(
        host=args.host,
        port=args.port,
        namespace=args.namespace,
    )

    results = []

    try:
        bench.connect()
        print("Connected to Aerospike")

        # Clear existing data
        print("Clearing existing data...")
        bench.clear_data()

        # Insert benchmark
        print(f"Running insert benchmark ({args.event_count:,} events)...")
        result = bench.benchmark_insert(events, args.batch_size)
        results.append(result)
        print(f"  {result}")

        # UUID lookup benchmark
        print(f"Running UUID lookup benchmark ({args.query_count:,} queries)...")
        result = bench.benchmark_uuid_lookup(entity_ids, args.query_count)
        results.append(result)
        print(f"  {result}")

        # Radius query benchmark
        print(f"Running radius query benchmark ({args.query_count:,} queries)...")
        result = bench.benchmark_radius_query(
            query_points, args.radius_meters, args.query_count
        )
        results.append(result)
        print(f"  {result}")

        # Polygon query benchmark
        polygon_queries = min(100, args.query_count)
        print(f"Running polygon query benchmark ({polygon_queries:,} queries)...")
        result = bench.benchmark_polygon_query(polygon_queries)
        results.append(result)
        print(f"  {result}")

    finally:
        bench.close()

    # Output results
    print()
    database_name = "Aerospike"

    if args.json:
        output = {
            "database": database_name,
            "entity_count": args.entity_count,
            "event_count": args.event_count,
            "results": [r.to_dict() for r in results],
        }
        print(json.dumps(output, indent=2))
    else:
        print(format_results(results, database_name))

    if args.output:
        save_results_csv(results, database_name, args.output)
        print(f"\nResults saved to: {args.output}")


if __name__ == "__main__":
    main()
