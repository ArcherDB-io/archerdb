# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Node.js SDK runner for parity tests."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

SDK_DIR = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "node"
PARITY_SCRIPT = Path(__file__).parent / "node_bridge.js"


def run_operation(
    server_url: str,
    operation: str,
    input_data: Dict[str, Any],
) -> Dict[str, Any]:
    """Run one Node SDK parity operation in a subprocess."""
    try:
        result = subprocess.run(
            ["node", str(PARITY_SCRIPT), operation],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            timeout=120,
            cwd=str(SDK_DIR),
            env={**os.environ, "ARCHERDB_URL": server_url},
        )

        stdout = result.stdout.strip()
        if not stdout:
            error_msg = result.stderr.strip() if result.stderr else "Node.js runner produced no output"
            return {"error": error_msg}

        return json.loads(stdout)

    except subprocess.TimeoutExpired:
        return {"error": "Node.js runner timed out (120s)"}
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON output: {e}"}
    except FileNotFoundError:
        return {"error": "Node.js not found. Install Node.js to run parity tests."}
    except Exception as e:
        return {"error": str(e)}
