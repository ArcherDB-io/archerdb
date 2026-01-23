#!/usr/bin/env python3
"""
PostGIS Benchmark Driver (BENCH-03)

Runs the same geospatial workload against PostGIS that ArcherDB uses,
enabling fair performance comparison.

Usage:
    python3 benchmark-postgis.py --entity-count 10000 --event-count 100000
    python3 benchmark-postgis.py --default  # Use default config instance
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
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("Error: psycopg2 not installed. Run: pip install psycopg2-binary")
    sys.exit(1)


class PostGISBenchmark:
    """PostGIS benchmark driver."""

    def __init__(
        self,
        host: str = "localhost",
        port: int = 5432,
        user: str = "bench",
        password: str = "bench",
        database: str = "geobench",
    ):
        self.conn_params = {
            "host": host,
            "port": port,
            "user": user,
            "password": password,
            "database": database,
        }
        self.conn = None

    def connect(self):
        """Establish database connection."""
        self.conn = psycopg2.connect(**self.conn_params)
        self.conn.autocommit = False

    def close(self):
        """Close database connection."""
        if self.conn:
            self.conn.close()

    def clear_data(self):
        """Clear all benchmark data."""
        with self.conn.cursor() as cur:
            cur.execute("TRUNCATE TABLE geo_events")
        self.conn.commit()

    def benchmark_insert(
        self,
        events: list,
        batch_size: int = 1000
    ) -> BenchmarkResult:
        """
        Benchmark batch inserts.

        Args:
            events: List of GeoEvent objects to insert
            batch_size: Number of events per batch

        Returns:
            BenchmarkResult with insert performance data
        """
        latencies = []
        errors = 0

        insert_sql = """
            INSERT INTO geo_events (
                entity_id, timestamp_ns, latitude, longitude,
                altitude_mm, heading_centideg, speed_mm_s, accuracy_mm, content
            ) VALUES %s
        """

        with Timer() as timer:
            for i in range(0, len(events), batch_size):
                batch = events[i:i + batch_size]
                values = [
                    (
                        e.entity_id, e.timestamp_ns, e.latitude, e.longitude,
                        e.altitude_mm, e.heading_centideg, e.speed_mm_s,
                        e.accuracy_mm, e.content
                    )
                    for e in batch
                ]

                try:
                    with measure_latency(latencies):
                        with self.conn.cursor() as cur:
                            psycopg2.extras.execute_values(
                                cur, insert_sql, values, page_size=batch_size
                            )
                        self.conn.commit()
                except Exception as ex:
                    errors += 1
                    self.conn.rollback()
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
        Benchmark UUID/entity_id lookups.

        Args:
            entity_ids: List of entity IDs to query
            query_count: Number of queries to perform

        Returns:
            BenchmarkResult with lookup performance data
        """
        latencies = []
        errors = 0

        query_sql = """
            SELECT entity_id, timestamp_ns, latitude, longitude,
                   altitude_mm, heading_centideg, speed_mm_s, accuracy_mm
            FROM geo_events
            WHERE entity_id = %s
            ORDER BY timestamp_ns DESC
            LIMIT 1
        """

        with Timer() as timer:
            for i in range(query_count):
                entity_id = entity_ids[i % len(entity_ids)]
                try:
                    with measure_latency(latencies):
                        with self.conn.cursor() as cur:
                            cur.execute(query_sql, (entity_id,))
                            cur.fetchall()
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
        Benchmark radius/proximity queries using ST_DWithin.

        Args:
            query_points: List of (lat, lon) query centers
            radius_meters: Search radius in meters
            query_count: Number of queries to perform

        Returns:
            BenchmarkResult with query performance data
        """
        latencies = []
        errors = 0

        # ST_DWithin with geography type for accurate distance
        query_sql = """
            SELECT entity_id, timestamp_ns, latitude, longitude
            FROM geo_events
            WHERE ST_DWithin(
                location,
                ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                %s
            )
            LIMIT 1000
        """

        with Timer() as timer:
            for i in range(query_count):
                lat, lon = query_points[i % len(query_points)]
                try:
                    with measure_latency(latencies):
                        with self.conn.cursor() as cur:
                            cur.execute(query_sql, (lon, lat, radius_meters))
                            cur.fetchall()
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
        Benchmark polygon containment queries.

        Args:
            query_count: Number of queries to perform

        Returns:
            BenchmarkResult with query performance data
        """
        import random
        random.seed(54321)

        latencies = []
        errors = 0

        # Generate random rectangular polygons
        query_sql = """
            SELECT entity_id, timestamp_ns, latitude, longitude
            FROM geo_events
            WHERE ST_Within(
                location::geometry,
                ST_MakeEnvelope(%s, %s, %s, %s, 4326)
            )
            LIMIT 1000
        """

        with Timer() as timer:
            for _ in range(query_count):
                # Random 1-degree box
                min_lat = random.uniform(-89, 88)
                min_lon = random.uniform(-179, 178)
                max_lat = min_lat + 1
                max_lon = min_lon + 1

                try:
                    with measure_latency(latencies):
                        with self.conn.cursor() as cur:
                            cur.execute(query_sql, (min_lon, min_lat, max_lon, max_lat))
                            cur.fetchall()
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
        description="PostGIS Benchmark Driver (BENCH-03)"
    )
    parser.add_argument(
        "--host", default=os.getenv("POSTGRES_HOST", "localhost"),
        help="PostgreSQL host"
    )
    parser.add_argument(
        "--port", type=int, default=int(os.getenv("POSTGRES_PORT", "5432")),
        help="PostgreSQL port"
    )
    parser.add_argument(
        "--default", action="store_true",
        help="Use default configuration instance (port 5433)"
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

    # Use default config port if requested
    port = 5433 if args.default else args.port
    config_name = "default" if args.default else "tuned"

    print(f"PostGIS Benchmark (BENCH-03)")
    print(f"  Host: {args.host}:{port}")
    print(f"  Configuration: {config_name}")
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
    bench = PostGISBenchmark(
        host=args.host,
        port=port,
    )

    results = []

    try:
        bench.connect()
        print("Connected to PostGIS")

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
    database_name = f"PostGIS ({config_name})"

    if args.json:
        output = {
            "database": database_name,
            "config": config_name,
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
