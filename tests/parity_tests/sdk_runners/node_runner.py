# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Node.js SDK runner for parity tests.

Runs Node.js SDK operations via subprocess with JSON input/output.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

# Path to Node.js SDK and parity runner script
SDK_DIR = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "node"
PARITY_SCRIPT = Path(__file__).parent.parent / "scripts" / "node_parity_runner.js"


def run_operation(server_url: str, operation: str, input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Run Node.js SDK operation via subprocess.

    The Node.js runner accepts:
    - ARCHERDB_URL env var for server address
    - operation as first argument
    - input_data as JSON on stdin

    It outputs the result as JSON on stdout.

    Args:
        server_url: ArcherDB server URL
        operation: Operation name
        input_data: Operation input data

    Returns:
        Dict with operation result
    """
    env = os.environ.copy()
    env["ARCHERDB_URL"] = server_url
    env["NODE_PATH"] = str(SDK_DIR / "src")

    # Build inline runner script if dedicated script doesn't exist
    script = _get_runner_script(operation)

    try:
        result = subprocess.run(
            ["node", "-e", script],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
            cwd=str(SDK_DIR),
        )

        if result.returncode != 0:
            error_msg = result.stderr.strip() if result.stderr else "Node.js runner failed"
            return {"error": error_msg}

        stdout = result.stdout.strip()
        if not stdout:
            return {"error": "No output from Node.js runner"}

        return json.loads(stdout)

    except subprocess.TimeoutExpired:
        return {"error": "Node.js runner timed out (30s)"}
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON output: {e}"}
    except FileNotFoundError:
        return {"error": "Node.js not found. Install Node.js to run parity tests."}
    except Exception as e:
        return {"error": str(e)}


def _get_runner_script(operation: str) -> str:
    """Get Node.js script for running the operation.

    Args:
        operation: Operation to run

    Returns:
        Node.js script as string
    """
    return f'''
const fs = require('fs');
const {{ GeoClient }} = require('./src');

async function main() {{
    const input = JSON.parse(fs.readFileSync(0, 'utf-8'));
    const url = process.env.ARCHERDB_URL || 'http://127.0.0.1:7000';

    const client = new GeoClient({{ url }});

    try {{
        const result = await runOperation(client, '{operation}', input);
        console.log(JSON.stringify(result));
    }} catch (e) {{
        console.log(JSON.stringify({{ error: e.message }}));
    }} finally {{
        await client.close();
    }}
}}

async function runOperation(client, operation, input) {{
    switch (operation) {{
        case 'ping':
            const pingResult = await client.ping();
            return {{ success: pingResult.success || true }};

        case 'status':
            const statusResult = await client.status();
            return {{
                status: statusResult.status || 'unknown',
                version: statusResult.version || 'unknown'
            }};

        case 'topology':
            const topoResult = await client.topology();
            return {{
                nodes: (topoResult.nodes || []).map(n => ({{
                    address: n.address,
                    role: n.role
                }}))
            }};

        case 'insert':
            const insertEvents = (input.events || []).map(e => ({{
                entityId: e.entity_id,
                latitude: e.latitude,
                longitude: e.longitude,
                correlationId: e.correlation_id || 0,
                userData: e.user_data || 0,
                groupId: e.group_id || 0,
                altitudeM: e.altitude_m || 0,
                velocityMps: e.velocity_mps || 0,
                ttlSeconds: e.ttl_seconds || 0,
                accuracyM: e.accuracy_m || 0,
                heading: e.heading || 0,
                flags: e.flags || 0
            }}));
            const insertResult = await client.insertEvents(insertEvents);
            return {{
                result_code: insertResult.resultCode || 0,
                count: insertEvents.length,
                results: (insertResult.results || []).map(r => ({{
                    status: r.status,
                    code: r.code
                }}))
            }};

        case 'upsert':
            const upsertEvents = (input.events || []).map(e => ({{
                entityId: e.entity_id,
                latitude: e.latitude,
                longitude: e.longitude
            }}));
            const upsertResult = await client.upsertEvents(upsertEvents);
            return {{
                result_code: upsertResult.resultCode || 0,
                count: upsertEvents.length
            }};

        case 'delete':
            const deleteResult = await client.deleteEntities(input.entity_ids || []);
            return {{
                result_code: deleteResult.resultCode || 0,
                count: (input.entity_ids || []).length
            }};

        case 'query-uuid':
            const uuidResult = await client.queryUuid(input.entity_id);
            return formatQueryResult(uuidResult);

        case 'query-uuid-batch':
            const batchResult = await client.queryUuidBatch(input.entity_ids || []);
            return formatQueryResult(batchResult);

        case 'query-radius':
            const radiusResult = await client.queryRadius(
                input.latitude,
                input.longitude,
                input.radius_m
            );
            return formatQueryResult(radiusResult);

        case 'query-polygon':
            const polygonResult = await client.queryPolygon(input.vertices || []);
            return formatQueryResult(polygonResult);

        case 'query-latest':
            const latestResult = await client.queryLatest(input.limit || 100);
            return formatQueryResult(latestResult);

        case 'ttl-set':
            const ttlSetResult = await client.ttlSet(input.entity_id, input.ttl_seconds);
            return {{ result_code: ttlSetResult.resultCode || 0 }};

        case 'ttl-extend':
            const ttlExtendResult = await client.ttlExtend(input.entity_id, input.extension_seconds);
            return {{ result_code: ttlExtendResult.resultCode || 0 }};

        case 'ttl-clear':
            const ttlClearResult = await client.ttlClear(input.entity_id);
            return {{ result_code: ttlClearResult.resultCode || 0 }};

        default:
            return {{ error: 'Unknown operation: ' + operation }};
    }}
}}

function formatQueryResult(result) {{
    const events = (result.events || []).map(e => ({{
        entity_id: e.entityId,
        latitude: e.latitude,
        longitude: e.longitude,
        correlation_id: e.correlationId || 0,
        user_data: e.userData || 0
    }}));

    return {{
        result_code: result.resultCode || 0,
        count: result.count || events.length,
        events: events
    }};
}}

main().catch(e => {{
    console.log(JSON.stringify({{ error: e.message }}));
    process.exit(1);
}});
'''
