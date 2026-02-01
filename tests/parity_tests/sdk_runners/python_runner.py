# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Python SDK runner for parity tests.

Runs operations using the Python SDK directly (no subprocess).
Python SDK serves as the golden reference per CONTEXT.md.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List

# Add Python SDK to path
SDK_PATH = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "python" / "src"
sys.path.insert(0, str(SDK_PATH))


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
        from archerdb import GeoClientSync, GeoClientConfig, GeoEvent
    except ImportError as e:
        return {"error": f"Python SDK not available: {e}"}

    # Parse server URL to extract host and port
    url = server_url.replace("http://", "").replace("https://", "")

    try:
        config = GeoClientConfig(cluster_id=0, addresses=[url])

        with GeoClientSync(config) as client:
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
    from archerdb import GeoEvent

    if operation == "ping":
        result = client.ping()
        return {"success": result.success if hasattr(result, "success") else True}

    elif operation == "status":
        result = client.status()
        return {
            "status": getattr(result, "status", "unknown"),
            "version": getattr(result, "version", "unknown"),
        }

    elif operation == "topology":
        result = client.topology()
        return {
            "nodes": [
                {"address": n.address, "role": n.role}
                for n in getattr(result, "nodes", [])
            ]
        }

    elif operation == "insert":
        events = _build_events(input_data.get("events", []))
        result = client.insert_events(events)
        return {
            "result_code": getattr(result, "result_code", 0),
            "count": len(events),
            "results": [
                {"status": r.status, "code": r.code}
                for r in getattr(result, "results", [])
            ],
        }

    elif operation == "upsert":
        events = _build_events(input_data.get("events", []))
        result = client.upsert_events(events)
        return {
            "result_code": getattr(result, "result_code", 0),
            "count": len(events),
        }

    elif operation == "delete":
        entity_ids = input_data.get("entity_ids", [])
        result = client.delete_entities(entity_ids)
        return {
            "result_code": getattr(result, "result_code", 0),
            "count": len(entity_ids),
        }

    elif operation == "query-uuid":
        entity_id = input_data.get("entity_id")
        result = client.query_uuid(entity_id)
        return _format_query_result(result)

    elif operation == "query-uuid-batch":
        entity_ids = input_data.get("entity_ids", [])
        result = client.query_uuid_batch(entity_ids)
        return _format_query_result(result)

    elif operation == "query-radius":
        result = client.query_radius(
            latitude=input_data["latitude"],
            longitude=input_data["longitude"],
            radius_m=input_data["radius_m"],
        )
        return _format_query_result(result)

    elif operation == "query-polygon":
        vertices = input_data.get("vertices", [])
        result = client.query_polygon(vertices)
        return _format_query_result(result)

    elif operation == "query-latest":
        limit = input_data.get("limit", 100)
        result = client.query_latest(limit=limit)
        return _format_query_result(result)

    elif operation == "ttl-set":
        entity_id = input_data.get("entity_id")
        ttl_seconds = input_data.get("ttl_seconds")
        result = client.ttl_set(entity_id, ttl_seconds)
        return {"result_code": getattr(result, "result_code", 0)}

    elif operation == "ttl-extend":
        entity_id = input_data.get("entity_id")
        extension_seconds = input_data.get("extension_seconds")
        result = client.ttl_extend(entity_id, extension_seconds)
        return {"result_code": getattr(result, "result_code", 0)}

    elif operation == "ttl-clear":
        entity_id = input_data.get("entity_id")
        result = client.ttl_clear(entity_id)
        return {"result_code": getattr(result, "result_code", 0)}

    else:
        return {"error": f"Unknown operation: {operation}"}


def _build_events(events_data: List[Dict[str, Any]]) -> List[Any]:
    """Build GeoEvent list from input data.

    Args:
        events_data: List of event dicts from fixture

    Returns:
        List of GeoEvent objects
    """
    from archerdb import GeoEvent

    events = []
    for e in events_data:
        event = GeoEvent(
            entity_id=e["entity_id"],
            latitude=e["latitude"],
            longitude=e["longitude"],
            correlation_id=e.get("correlation_id", 0),
            user_data=e.get("user_data", 0),
            group_id=e.get("group_id", 0),
            altitude_m=e.get("altitude_m", 0.0),
            velocity_mps=e.get("velocity_mps", 0.0),
            ttl_seconds=e.get("ttl_seconds", 0),
            accuracy_m=e.get("accuracy_m", 0.0),
            heading=e.get("heading", 0.0),
            flags=e.get("flags", 0),
        )
        events.append(event)
    return events


def _format_query_result(result: Any) -> Dict[str, Any]:
    """Format query result for comparison.

    Args:
        result: SDK query result object

    Returns:
        Dict with standardized fields
    """
    events = []
    for e in getattr(result, "events", []):
        events.append(
            {
                "entity_id": e.entity_id,
                "latitude": e.latitude,
                "longitude": e.longitude,
                "correlation_id": getattr(e, "correlation_id", 0),
                "user_data": getattr(e, "user_data", 0),
            }
        )

    return {
        "result_code": getattr(result, "result_code", 0),
        "count": getattr(result, "count", len(events)),
        "events": events,
    }
