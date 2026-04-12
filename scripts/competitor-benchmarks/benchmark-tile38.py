#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
Tile38 Benchmark Driver (BENCH-04)

Runs the same geospatial workload against Tile38 that ArcherDB uses,
enabling fair performance comparison.

Usage:
    python3 benchmark-tile38.py --entity-count 10000 --event-count 100000
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
    import redis
except ImportError:
    print("Error: redis not installed. Run: pip install redis")
    sys.exit(1)


class Tile38Benchmark:
    """Tile38 benchmark driver using Redis protocol."""

    def __init__(
        self,
        host: str = "localhost",
        port: int = 9851,
    ):
        self.host = host
        self.port = port
        self.client = None

    def connect(self):
        """Establish connection to Tile38."""
        self.client = redis.Redis(host=self.host, port=self.port, decode_responses=True)
        # Verify connection
        response = self.client.execute_command("PING")
        if response != "PONG":
            raise ConnectionError(f"Unexpected PING response: {response}")

    def close(self):
        """Close connection."""
        if self.client:
            self.client.close()

    def clear_data(self):
        """Clear all benchmark data."""
        try:
            self.client.execute_command("DROP", "geobench")
        except redis.exceptions.ResponseError:
            pass  # Collection may not exist

    def benchmark_insert(
        self,
        events: list,
        batch_size: int = 1000
    ) -> BenchmarkResult:
        """
        Benchmark inserts using SET command.

        Tile38 SET command: SET key id [FIELD name value...] POINT lat lon

        Args:
            events: List of GeoEvent objects to insert
            batch_size: Number of events per pipeline batch

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
                        pipe = self.client.pipeline()
                        for e in batch:
                            # SET geobench <entity_id> FIELD timestamp <ts> POINT <lat> <lon>
                            pipe.execute_command(
                                "SET", "geobench", e.entity_id,
                                "FIELD", "timestamp_ns", e.timestamp_ns,
                                "FIELD", "altitude_mm", e.altitude_mm,
                                "FIELD", "heading_centideg", e.heading_centideg,
                                "FIELD", "speed_mm_s", e.speed_mm_s,
                                "FIELD", "accuracy_mm", e.accuracy_mm,
                                "POINT", e.latitude, e.longitude
                            )
                        pipe.execute()
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
        Benchmark entity lookups using GET command.

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
                try:
                    with measure_latency(latencies):
                        self.client.execute_command("GET", "geobench", entity_id)
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
        Benchmark radius/proximity queries using NEARBY command.

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
                        # NEARBY geobench LIMIT 1000 POINT lat lon radius
                        self.client.execute_command(
                            "NEARBY", "geobench",
                            "LIMIT", 1000,
                            "POINT", lat, lon, radius_meters
                        )
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
        Benchmark polygon containment queries using WITHIN command.

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
                # Random 1-degree box as GeoJSON polygon
                min_lat = random.uniform(-89, 88)
                min_lon = random.uniform(-179, 178)
                max_lat = min_lat + 1
                max_lon = min_lon + 1

                # GeoJSON polygon (closed ring)
                geojson = {
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
                        # WITHIN geobench LIMIT 1000 OBJECT <geojson>
                        self.client.execute_command(
                            "WITHIN", "geobench",
                            "LIMIT", 1000,
                            "OBJECT", json.dumps(geojson)
                        )
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
        description="Tile38 Benchmark Driver (BENCH-04)"
    )
    parser.add_argument(
        "--host", default=os.getenv("TILE38_HOST", "localhost"),
        help="Tile38 host"
    )
    parser.add_argument(
        "--port", type=int, default=int(os.getenv("TILE38_PORT", "9851")),
        help="Tile38 port"
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

    print(f"Tile38 Benchmark (BENCH-04)")
    print(f"  Host: {args.host}:{args.port}")
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
    bench = Tile38Benchmark(
        host=args.host,
        port=args.port,
    )

    results = []

    try:
        bench.connect()
        print("Connected to Tile38")

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
    database_name = "Tile38"

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
