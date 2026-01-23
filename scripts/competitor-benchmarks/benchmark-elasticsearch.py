#!/usr/bin/env python3
"""
Elasticsearch Geo Benchmark Driver (BENCH-05)

Runs the same geospatial workload against Elasticsearch that ArcherDB uses,
enabling fair performance comparison.

Usage:
    python3 benchmark-elasticsearch.py --entity-count 10000 --event-count 100000
    python3 benchmark-elasticsearch.py --default  # Use default config instance
"""

import argparse
import json
import os
import sys
import time

# Add parent directory to path for common module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import (
    BenchmarkResult, GeoEvent, Timer, measure_latency,
    generate_events, generate_entity_ids, generate_query_points,
    format_results, save_results_csv,
)

try:
    from elasticsearch import Elasticsearch, helpers
except ImportError:
    print("Error: elasticsearch not installed. Run: pip install elasticsearch")
    sys.exit(1)


class ElasticsearchBenchmark:
    """Elasticsearch geo benchmark driver."""

    def __init__(
        self,
        host: str = "localhost",
        port: int = 9200,
    ):
        self.url = f"http://{host}:{port}"
        self.client = None
        self.index_name = "geo_events"

    def connect(self):
        """Establish connection to Elasticsearch."""
        self.client = Elasticsearch(self.url)
        # Verify connection
        if not self.client.ping():
            raise ConnectionError(f"Cannot connect to Elasticsearch at {self.url}")

    def close(self):
        """Close connection."""
        if self.client:
            self.client.close()

    def clear_data(self):
        """Clear all benchmark data."""
        try:
            self.client.indices.delete(index=self.index_name, ignore_unavailable=True)
        except Exception:
            pass

        # Recreate index with mapping
        mapping = {
            "settings": {
                "number_of_shards": 1,
                "number_of_replicas": 0,
                "refresh_interval": "-1",  # Disable refresh during bulk insert
            },
            "mappings": {
                "properties": {
                    "entity_id": {"type": "keyword"},
                    "timestamp_ns": {"type": "long"},
                    "location": {"type": "geo_point"},
                    "altitude_mm": {"type": "integer"},
                    "heading_centideg": {"type": "integer"},
                    "speed_mm_s": {"type": "integer"},
                    "accuracy_mm": {"type": "integer"},
                }
            }
        }
        self.client.indices.create(index=self.index_name, body=mapping)

    def benchmark_insert(
        self,
        events: list,
        batch_size: int = 1000
    ) -> BenchmarkResult:
        """
        Benchmark bulk inserts.

        Args:
            events: List of GeoEvent objects to insert
            batch_size: Number of events per bulk request

        Returns:
            BenchmarkResult with insert performance data
        """
        latencies = []
        errors = 0

        def generate_actions(batch):
            for e in batch:
                yield {
                    "_index": self.index_name,
                    "_source": {
                        "entity_id": e.entity_id,
                        "timestamp_ns": e.timestamp_ns,
                        "location": {
                            "lat": e.latitude,
                            "lon": e.longitude,
                        },
                        "altitude_mm": e.altitude_mm,
                        "heading_centideg": e.heading_centideg,
                        "speed_mm_s": e.speed_mm_s,
                        "accuracy_mm": e.accuracy_mm,
                    }
                }

        with Timer() as timer:
            for i in range(0, len(events), batch_size):
                batch = events[i:i + batch_size]

                try:
                    with measure_latency(latencies):
                        helpers.bulk(self.client, generate_actions(batch))
                except Exception as ex:
                    errors += 1
                    print(f"Insert error: {ex}")

        # Re-enable refresh and force refresh
        self.client.indices.put_settings(
            index=self.index_name,
            body={"refresh_interval": "1s"}
        )
        self.client.indices.refresh(index=self.index_name)

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
        Benchmark entity lookups using term query.

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
                        self.client.search(
                            index=self.index_name,
                            body={
                                "query": {
                                    "term": {"entity_id": entity_id}
                                },
                                "size": 1,
                                "sort": [{"timestamp_ns": "desc"}]
                            }
                        )
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
        Benchmark radius/proximity queries using geo_distance.

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
                        self.client.search(
                            index=self.index_name,
                            body={
                                "query": {
                                    "bool": {
                                        "filter": {
                                            "geo_distance": {
                                                "distance": f"{radius_meters}m",
                                                "location": {
                                                    "lat": lat,
                                                    "lon": lon
                                                }
                                            }
                                        }
                                    }
                                },
                                "size": 1000
                            }
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
        Benchmark polygon containment queries using geo_polygon.

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

                try:
                    with measure_latency(latencies):
                        self.client.search(
                            index=self.index_name,
                            body={
                                "query": {
                                    "bool": {
                                        "filter": {
                                            "geo_bounding_box": {
                                                "location": {
                                                    "top_left": {
                                                        "lat": max_lat,
                                                        "lon": min_lon
                                                    },
                                                    "bottom_right": {
                                                        "lat": min_lat,
                                                        "lon": max_lon
                                                    }
                                                }
                                            }
                                        }
                                    }
                                },
                                "size": 1000
                            }
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
        description="Elasticsearch Geo Benchmark Driver (BENCH-05)"
    )
    parser.add_argument(
        "--host", default=os.getenv("ES_HOST", "localhost"),
        help="Elasticsearch host"
    )
    parser.add_argument(
        "--port", type=int, default=int(os.getenv("ES_PORT", "9200")),
        help="Elasticsearch port"
    )
    parser.add_argument(
        "--default", action="store_true",
        help="Use default configuration instance (port 9201)"
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
    port = 9201 if args.default else args.port
    config_name = "default" if args.default else "tuned"

    print(f"Elasticsearch Geo Benchmark (BENCH-05)")
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
    bench = ElasticsearchBenchmark(
        host=args.host,
        port=port,
    )

    results = []

    try:
        bench.connect()
        print("Connected to Elasticsearch")

        # Clear existing data and create index
        print("Setting up index...")
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
    database_name = f"Elasticsearch ({config_name})"

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
