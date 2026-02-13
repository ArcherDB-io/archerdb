# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Python SDK runner for parity tests.

Runs operations using the Python SDK directly (no subprocess).
Python SDK serves as the golden reference per CONTEXT.md.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path
from typing import Any, Dict, List

# Add Python SDK to path
SDK_PATH = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "python" / "src"
PROJECT_ROOT = Path(__file__).parent.parent.parent.parent
sys.path.insert(0, str(SDK_PATH))
sys.path.insert(0, str(PROJECT_ROOT))


def run_operation(server_url: str, operation: str, input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Run operation using Python SDK and return result as dict.

    Args:
        server_url: ArcherDB server URL (e.g., 'http://127.0.0.1:7000')
        operation: Operation name (e.g., 'insert', 'query-radius')
        input_data: Input data for the operation

    Returns:
        Dict with operation result, suitable for comparison

    Raises:
        ValueError: If operation is unknown
        Exception: If SDK operation fails
    """
    try:
        from archerdb import GeoClientSync, GeoClientConfig
    except ImportError as e:
        return {"error": f"Python SDK not available: {e}"}

    # Parse server URL to extract host and port
    url = server_url.replace("http://", "").replace("https://", "")

    try:
        config = GeoClientConfig(cluster_id=0, addresses=[url])

        with GeoClientSync(config) as client:
            # Some fixture operations require deterministic setup data first.
            if "setup" in input_data:
                from tests.sdk_tests.common.fixture_adapter import setup_test_data
                setup_test_data(client, input_data["setup"])
            return _execute_operation(client, operation, input_data)
    except Exception as e:
        return {"error": str(e)}


def _execute_operation(
    client: Any,
    operation: str,
    input_data: Dict[str, Any],
) -> Dict[str, Any]:
    """Execute specific operation on client.

    Args:
        client: Connected GeoClientSync instance
        operation: Operation to execute
        input_data: Operation input data

    Returns:
        Operation result as dict
    """
    if operation == "ping":
        return {"success": bool(client.ping())}

    elif operation == "status":
        result = client.get_status()
        return {
            "ram_index_count": getattr(result, "ram_index_count", 0),
            "ram_index_capacity": getattr(result, "ram_index_capacity", 0),
            "ram_index_load_pct": getattr(result, "ram_index_load_pct", 0),
            "tombstone_count": getattr(result, "tombstone_count", 0),
            "ttl_expirations": getattr(result, "ttl_expirations", 0),
            "deletion_count": getattr(result, "deletion_count", 0),
        }

    elif operation == "topology":
        topology = client.get_topology()
        return {"nodes": _format_topology_nodes(topology)}

    elif operation == "insert":
        events = _build_events(input_data.get("events", []))
        result = client.insert_events(events)
        return {
            "result_code": 0,
            "count": len(events),
            "results": [
                {"index": err.index, "code": int(err.result)}
                for err in result
            ],
        }

    elif operation == "upsert":
        events = _build_events(input_data.get("events", []))
        result = client.upsert_events(events)
        return {
            "result_code": 0,
            "count": len(events),
            "results": [
                {"index": err.index, "code": int(err.result)}
                for err in result
            ],
        }

    elif operation == "delete":
        entity_ids = _normalize_entity_ids(input_data.get("entity_ids", []))
        result = client.delete_entities(entity_ids)
        return {
            "deleted_count": getattr(result, "deleted_count", 0),
            "not_found_count": getattr(result, "not_found_count", 0),
        }

    elif operation == "query-uuid":
        entity_id = _to_entity_id(input_data.get("entity_id"))
        result = client.get_latest_by_uuid(entity_id)
        return _format_query_uuid_result(result)

    elif operation == "query-uuid-batch":
        entity_ids = _entity_ids_from_input(input_data)
        result = client.get_latest_batch(entity_ids)
        return _format_query_uuid_batch_result(entity_ids, result)

    elif operation == "query-radius":
        latitude = input_data.get(
            "latitude",
            input_data.get("center_latitude", input_data.get("center_lat")),
        )
        longitude = input_data.get(
            "longitude",
            input_data.get("center_longitude", input_data.get("center_lon")),
        )
        radius_m = input_data.get("radius_m")
        if latitude is None or longitude is None or radius_m is None:
            return {"error": "query-radius requires latitude/longitude/radius_m"}

        result = client.query_radius(
            latitude=latitude,
            longitude=longitude,
            radius_m=radius_m,
            limit=input_data.get("limit", 1000),
            timestamp_min=input_data.get("timestamp_min", 0),
            timestamp_max=input_data.get("timestamp_max", 0),
            group_id=input_data.get("group_id", 0),
        )
        return _format_query_result(result)

    elif operation == "query-polygon":
        vertices = _parse_polygon_vertices(input_data.get("vertices", []))
        holes = input_data.get("holes")
        parsed_holes = (
            [_parse_polygon_vertices(hole) for hole in holes]
            if holes
            else None
        )
        result = client.query_polygon(
            vertices,
            holes=parsed_holes,
            limit=input_data.get("limit", 1000),
            timestamp_min=input_data.get("timestamp_min", 0),
            timestamp_max=input_data.get("timestamp_max", 0),
            group_id=input_data.get("group_id", 0),
        )
        return _format_query_result(result)

    elif operation == "query-latest":
        limit = input_data.get("limit", 100)
        result = client.query_latest(
            limit=limit,
            group_id=input_data.get("group_id", 0),
            cursor_timestamp=input_data.get("cursor_timestamp", 0),
        )
        return _format_query_result(result)

    elif operation == "ttl-set":
        entity_id = _to_entity_id(input_data.get("entity_id"))
        ttl_seconds = input_data.get("ttl_seconds")
        result = client.set_ttl(entity_id, ttl_seconds)
        return {
            "entity_id": result.entity_id,
            "previous_ttl_seconds": result.previous_ttl_seconds,
            "new_ttl_seconds": result.new_ttl_seconds,
            "result_code": int(result.result),
        }

    elif operation == "ttl-extend":
        entity_id = _to_entity_id(input_data.get("entity_id"))
        extension_seconds = input_data.get("extension_seconds")
        if extension_seconds is None:
            extension_seconds = input_data.get("extend_by_seconds")
        result = client.extend_ttl(entity_id, extension_seconds)
        return {
            "entity_id": result.entity_id,
            "previous_ttl_seconds": result.previous_ttl_seconds,
            "new_ttl_seconds": result.new_ttl_seconds,
            "result_code": int(result.result),
        }

    elif operation == "ttl-clear":
        if "query_entity_id" in input_data:
            entity_id = _to_entity_id(input_data.get("query_entity_id"))
            event = client.get_latest_by_uuid(entity_id)
            return {"entity_still_exists": event is not None}

        entity_id = _to_entity_id(input_data.get("entity_id"))
        result = client.clear_ttl(entity_id)
        return {
            "entity_id": result.entity_id,
            "previous_ttl_seconds": result.previous_ttl_seconds,
            "result_code": int(result.result),
        }

    else:
        return {"error": f"Unknown operation: {operation}"}


def _build_events(events_data: List[Dict[str, Any]]) -> List[Any]:
    """Build GeoEvent list from input data.

    Args:
        events_data: List of event dicts from fixture

    Returns:
        List of GeoEvent objects
    """
    from tests.sdk_tests.common.fixture_adapter import build_geo_event_from_fixture
    events = []
    for e in events_data:
        converted = dict(e)
        converted["entity_id"] = _to_entity_id(converted.get("entity_id"))
        if "latitude" not in converted and "lat_nano" in converted:
            converted["latitude"] = converted["lat_nano"] / 1_000_000_000.0
        if "longitude" not in converted and "lon_nano" in converted:
            converted["longitude"] = converted["lon_nano"] / 1_000_000_000.0
        events.append(build_geo_event_from_fixture(converted))
    return events


def _format_query_result(result: Any) -> Dict[str, Any]:
    """Format query result for comparison.

    Args:
        result: SDK query result object

    Returns:
        Dict with standardized fields
    """
    events = [_format_event(e) for e in getattr(result, "events", [])]
    return {"count": len(events), "has_more": getattr(result, "has_more", False), "events": events}


def _format_query_uuid_result(event: Any) -> Dict[str, Any]:
    if event is None:
        return {"found": False, "event": None}
    return {"found": True, "event": _format_event(event)}


def _format_query_uuid_batch_result(
    entity_ids: List[int], result: Dict[int, Any]
) -> Dict[str, Any]:
    found = []
    not_found = []
    for entity_id in entity_ids:
        event = result.get(entity_id)
        if event is None:
            not_found.append(entity_id)
        else:
            found.append(_format_event(event))
    return {
        "found_count": len(found),
        "not_found_count": len(not_found),
        "events": found,
        "not_found_entity_ids": not_found,
    }


def _format_event(event: Any) -> Dict[str, Any]:
    return {
        "entity_id": event.entity_id,
        "latitude": event.lat_nano / 1_000_000_000.0,
        "longitude": event.lon_nano / 1_000_000_000.0,
        "timestamp": event.timestamp,
        "correlation_id": getattr(event, "correlation_id", 0),
        "user_data": getattr(event, "user_data", 0),
        "group_id": getattr(event, "group_id", 0),
        "ttl_seconds": getattr(event, "ttl_seconds", 0),
    }


def _parse_polygon_vertices(vertices: List[Any]) -> List[tuple[float, float]]:
    parsed: List[tuple[float, float]] = []
    for v in vertices:
        if isinstance(v, dict):
            parsed.append((float(v["lat"]), float(v["lon"])))
        elif isinstance(v, (list, tuple)) and len(v) == 2:
            parsed.append((float(v[0]), float(v[1])))
    return parsed


def _normalize_entity_ids(entity_ids: List[Any]) -> List[int]:
    return [_to_entity_id(entity_id) for entity_id in entity_ids]


def _entity_ids_from_input(input_data: Dict[str, Any]) -> List[int]:
    if "entity_ids" in input_data:
        return _normalize_entity_ids(input_data.get("entity_ids", []))

    range_spec = input_data.get("entity_ids_range")
    if isinstance(range_spec, dict):
        start = int(range_spec.get("start", 0))
        count = int(range_spec.get("count", 0))
        return [start + i for i in range(max(count, 0))]

    return []


def _to_entity_id(entity_id: Any) -> int:
    if entity_id is None:
        return 0
    if isinstance(entity_id, int):
        return entity_id
    if isinstance(entity_id, str):
        stripped = entity_id.strip()
        if stripped.isdigit():
            return int(stripped)
        try:
            return int(stripped, 16)
        except ValueError:
            digest = hashlib.sha256(stripped.encode("utf-8")).digest()
            value = int.from_bytes(digest[:16], byteorder="little")
            return value if value != 0 else 1
    raise TypeError(f"Unsupported entity_id type: {type(entity_id)}")


def _format_topology_nodes(topology: Any) -> List[Dict[str, Any]]:
    # TopologyResponse currently exposes per-shard primary/replica addresses.
    roles_by_address: Dict[str, str] = {}

    for shard in getattr(topology, "shards", []):
        primary = getattr(shard, "primary", "")
        if primary:
            roles_by_address[primary] = "primary"
        for replica in getattr(shard, "replicas", []):
            if replica and replica not in roles_by_address:
                roles_by_address[replica] = "replica"

    return [
        {"address": address, "role": role}
        for address, role in sorted(roles_by_address.items())
    ]
