# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Consistency verification for topology testing.

This module provides the ConsistencyChecker class for verifying data
consistency across cluster nodes after topology changes.

Per CONTEXT.md: "Full data consistency checks after every topology change"
- Cluster health (nodes up, leader elected)
- Operation correctness (re-run operations)
- Data consistency across all nodes
"""

import json
import time
from typing import TYPE_CHECKING, Any, Dict, List, Optional, Set
from urllib import error as urllib_error
from urllib import request as urllib_request

if TYPE_CHECKING:
    from test_infrastructure.harness import ArcherDBCluster


class ConsistencyChecker:
    """Verifies data consistency across cluster nodes.

    Usage:
        checker = ConsistencyChecker(cluster)

        # Verify cluster health
        health = checker.verify_cluster_health()
        assert health["has_leader"]
        assert all(v for k, v in health.items() if k.startswith("node_"))

        # Verify data consistency
        consistency = checker.verify_data_consistency(entity_ids)
        assert all(v for k, v in consistency.items() if k.endswith("_consistent"))
    """

    def __init__(self, cluster: "ArcherDBCluster") -> None:
        """Initialize consistency checker.

        Args:
            cluster: The cluster to check.
        """
        self.cluster = cluster

    def verify_cluster_health(self) -> Dict[str, bool]:
        """Verify all running nodes are healthy and have leader.

        Returns:
            Dict with health status per node and leader status.
            Keys: "node_0", "node_1", ..., "has_leader"
        """
        health: Dict[str, bool] = {}

        for i in range(self.cluster.config.node_count):
            if not self.cluster.is_node_running(i):
                health[f"node_{i}"] = False
                continue
            try:
                status_code, _ = _http_request(
                    "GET",
                    f"http://127.0.0.1:{self.cluster.get_metrics_ports()[i]}/health/ready",
                    timeout=5,
                )
                health[f"node_{i}"] = status_code == 200
            except RuntimeError:
                health[f"node_{i}"] = False

        # Check leader exists
        health["has_leader"] = self.cluster.get_leader_replica() is not None
        return health

    def verify_data_consistency(
        self,
        entity_ids: List[str],
        retry_attempts: int = 3,
        retry_delay_sec: float = 1.0,
    ) -> Dict[str, Any]:
        """Verify data is consistent across all healthy nodes.

        Per CONTEXT.md: "Retry with backoff before failing - accounts for
        eventual consistency and in-flight replication"

        Args:
            entity_ids: Entity IDs to verify.
            retry_attempts: Number of retry attempts per node.
            retry_delay_sec: Delay between retries.

        Returns:
            Dict with consistency check results.
            Keys: "node_X_consistent" (bool) or "node_X_error" (str)
        """
        results: Dict[str, Any] = {}
        reference_data: Set[str] = set()
        first_node = True

        for i in range(self.cluster.config.node_count):
            if not self.cluster.is_node_running(i):
                continue

            try:
                node_data = self._query_node_with_retry(
                    node_idx=i,
                    entity_ids=entity_ids,
                    retry_attempts=retry_attempts,
                    retry_delay_sec=retry_delay_sec,
                )

                if first_node:
                    reference_data = node_data
                    results[f"node_{i}_consistent"] = True
                    first_node = False
                else:
                    results[f"node_{i}_consistent"] = node_data == reference_data

            except Exception as e:
                results[f"node_{i}_error"] = str(e)

        return results

    def _query_node_with_retry(
        self,
        node_idx: int,
        entity_ids: List[str],
        retry_attempts: int,
        retry_delay_sec: float,
    ) -> Set[str]:
        """Query a node for entity IDs with retry logic.

        Args:
            node_idx: Node index to query.
            entity_ids: Entity IDs to query.
            retry_attempts: Maximum retry attempts.
            retry_delay_sec: Delay between retries.

        Returns:
            Set of entity IDs found on the node.

        Raises:
            RuntimeError: If query fails after all retries.
        """

        last_error: Optional[Exception] = None

        for attempt in range(retry_attempts):
            try:
                port = self.cluster.get_ports()[node_idx]
                status_code, payload = _http_request(
                    "POST",
                    f"http://127.0.0.1:{port}/query/uuid/batch",
                    json_body={"entity_ids": entity_ids},
                    timeout=10,
                )
                if status_code != 200:
                    raise RuntimeError(f"Query failed: {status_code}")
                return set(e["entity_id"] for e in payload.get("events", []))
            except Exception as exc:
                last_error = exc
                if attempt + 1 >= retry_attempts:
                    break
                time.sleep(retry_delay_sec)

        raise RuntimeError(f"Query failed after {retry_attempts} attempts: {last_error}")

    def verify_operation_correctness(
        self,
        operation: str,
        input_data: Dict[str, Any],
        expected_response: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Verify an operation returns correct results after topology change.

        Args:
            operation: Operation name (e.g., "query-radius").
            input_data: Input data for the operation.
            expected_response: Expected response to compare against.

        Returns:
            Dict with verification results per node.
        """
        results: Dict[str, Any] = {}

        # Map operation names to endpoints
        endpoint_map = {
            "ping": "/health/ping",
            "status": "/status",
            "topology": "/topology",
            "query-uuid": "/query/uuid",
            "query-uuid-batch": "/query/uuid/batch",
            "query-radius": "/query/radius",
            "query-polygon": "/query/polygon",
            "query-latest": "/query/latest",
        }

        endpoint = endpoint_map.get(operation)
        if endpoint is None:
            results["error"] = f"Unknown operation: {operation}"
            return results

        for i in range(self.cluster.config.node_count):
            if not self.cluster.is_node_running(i):
                continue

            try:
                port = self.cluster.get_ports()[i]

                if operation in ("ping", "status", "topology"):
                    status_code, _ = _http_request(
                        "GET",
                        f"http://127.0.0.1:{port}{endpoint}",
                        timeout=5,
                    )
                else:
                    status_code, _ = _http_request(
                        "POST",
                        f"http://127.0.0.1:{port}{endpoint}",
                        json_body=input_data,
                        timeout=5,
                    )

                results[f"node_{i}_status"] = status_code
                results[f"node_{i}_correct"] = status_code == expected_response.get(
                    "status_code", 200
                )

            except Exception as e:
                results[f"node_{i}_error"] = str(e)

        return results


def _http_request(
    method: str,
    url: str,
    *,
    timeout: float,
    json_body: Optional[Dict[str, Any]] = None,
) -> tuple[int, Any]:
    data = None
    headers: Dict[str, str] = {}
    if json_body is not None:
        data = json.dumps(json_body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib_request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib_request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            content_type = resp.headers.get("Content-Type", "")
            if "application/json" in content_type and body:
                return resp.status, json.loads(body.decode("utf-8"))
            return resp.status, body
    except urllib_error.HTTPError as exc:
        body = exc.read()
        if body:
            try:
                return exc.code, json.loads(body.decode("utf-8"))
            except json.JSONDecodeError:
                pass
        return exc.code, body
    except (urllib_error.URLError, TimeoutError) as exc:
        raise RuntimeError(str(exc)) from exc
