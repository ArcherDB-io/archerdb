# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Helpers for benchmark workloads using the supported SDK surface."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[2]
PYTHON_SDK_SRC = PROJECT_ROOT / "src" / "clients" / "python" / "src"
if str(PYTHON_SDK_SRC) not in sys.path:
    sys.path.insert(0, str(PYTHON_SDK_SRC))

from archerdb.client import GeoClientConfig, GeoClientSync, RetryConfig
from archerdb.types import GeoEvent, GeoEventFlags, create_geo_event


def normalize_addresses(
    *,
    addresses: Sequence[str] | None = None,
    host: str | None = None,
    port: int | None = None,
) -> List[str]:
    """Normalize benchmark connection inputs into SDK addresses."""
    if addresses:
        return [str(address) for address in addresses]
    if host is not None and port is not None:
        return [f"{host}:{port}"]
    raise ValueError("Either addresses or host+port must be provided")


def build_client(
    *,
    cluster_id: int,
    addresses: Sequence[str],
    timeout: float,
) -> GeoClientSync:
    """Create a benchmark SDK client with bounded retry time."""
    timeout_ms = max(1, int(timeout * 1000))
    return GeoClientSync(
        GeoClientConfig(
            cluster_id=cluster_id,
            addresses=list(addresses),
            request_timeout_ms=timeout_ms,
            retry=RetryConfig(
                enabled=True,
                max_retries=3,
                base_backoff_ms=50,
                total_timeout_ms=timeout_ms,
            ),
        )
    )


def parse_entity_id(value: Any) -> int:
    """Parse an entity identifier used by benchmark fixtures."""
    if isinstance(value, int):
        return value

    text = str(value).strip()
    if not text:
        raise ValueError("entity_id must not be empty")

    lowered = text.lower()
    if lowered.startswith("0x"):
        return int(lowered, 16)

    compact = text.replace("-", "")
    if len(compact) == 32:
        return int(compact, 16)

    if any(ch in "abcdef" for ch in lowered):
        return int(lowered, 16)

    return int(text, 10)


def event_dict_to_geo_event(event: Dict[str, Any]) -> GeoEvent:
    """Convert a benchmark event fixture into a Python SDK GeoEvent."""
    entity_id = parse_entity_id(event["entity_id"])
    correlation_id = parse_entity_id(event.get("correlation_id", 0))
    user_data = parse_entity_id(event.get("user_data", 0))
    group_id = int(event.get("group_id", 0))
    ttl_seconds = int(event.get("ttl_seconds", 0))
    flags = GeoEventFlags(int(event.get("flags", 0)))

    if "lat_nano" in event and "lon_nano" in event:
        return GeoEvent(
            id=parse_entity_id(event.get("id", 0)),
            entity_id=entity_id,
            correlation_id=correlation_id,
            user_data=user_data,
            lat_nano=int(event["lat_nano"]),
            lon_nano=int(event["lon_nano"]),
            group_id=group_id,
            timestamp=int(event.get("timestamp", 0)),
            altitude_mm=int(event.get("altitude_mm", 0)),
            velocity_mms=int(event.get("velocity_mms", 0)),
            ttl_seconds=ttl_seconds,
            accuracy_mm=int(event.get("accuracy_mm", 0)),
            heading_cdeg=int(event.get("heading_cdeg", 0)),
            flags=flags,
        )

    return create_geo_event(
        entity_id=entity_id,
        latitude=float(event["latitude"]),
        longitude=float(event["longitude"]),
        correlation_id=correlation_id,
        user_data=user_data,
        group_id=group_id,
        altitude_m=float(event.get("altitude_m", 0.0)),
        velocity_mps=float(event.get("velocity_mps", 0.0)),
        ttl_seconds=ttl_seconds,
        accuracy_m=float(event.get("accuracy_m", 0.0)),
        heading=float(event.get("heading", 0.0)),
        flags=flags,
    )


def batch_to_geo_events(events: Iterable[Dict[str, Any]]) -> List[GeoEvent]:
    """Convert a batch of benchmark event dicts into SDK GeoEvents."""
    return [event_dict_to_geo_event(event) for event in events]
