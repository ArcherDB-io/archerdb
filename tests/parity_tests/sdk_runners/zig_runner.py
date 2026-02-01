# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Zig SDK runner for parity tests.

Runs Zig SDK operations via Zig-built test binary.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

# Paths for Zig SDK
SDK_DIR = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "zig"
PARITY_BINARY = SDK_DIR / "zig-out" / "bin" / "parity_runner"
ZIG_BINARY = Path(__file__).parent.parent.parent.parent / "zig" / "zig"


def run_operation(server_url: str, operation: str, input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Run Zig SDK operation via test binary.

    The parity_runner binary accepts:
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

    # Build binary if needed
    binary_path = str(PARITY_BINARY)
    if not os.path.exists(binary_path):
        build_result = _build_binary(env)
        if build_result is not None:
            return build_result

    # If binary still doesn't exist, return placeholder
    if not os.path.exists(binary_path):
        return {
            "error": f"Zig SDK parity runner not built. Expected at: {binary_path}"
        }

    try:
        result = subprocess.run(
            [binary_path, operation],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
        )

        if result.returncode != 0:
            error_msg = result.stderr.strip() if result.stderr else "Zig runner failed"
            return {"error": error_msg}

        stdout = result.stdout.strip()
        if not stdout:
            return {"error": "No output from Zig runner"}

        return json.loads(stdout)

    except subprocess.TimeoutExpired:
        return {"error": "Zig runner timed out (30s)"}
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON output: {e}"}
    except Exception as e:
        return {"error": str(e)}


def _build_binary(env: Dict[str, str]) -> Dict[str, Any] | None:
    """Build Zig parity runner binary.

    Args:
        env: Environment variables

    Returns:
        Error dict if build failed, None if successful
    """
    # Check if Zig is available
    zig_path = str(ZIG_BINARY) if ZIG_BINARY.exists() else "zig"

    # Check for build.zig in SDK directory
    build_file = SDK_DIR / "build.zig"
    if not build_file.exists():
        return {
            "error": f"Zig SDK build.zig not found at {build_file}. "
            "Create parity_runner target in src/clients/zig/build.zig"
        }

    try:
        result = subprocess.run(
            [zig_path, "build", "-Dconfig=lite", "parity_runner"],
            cwd=str(SDK_DIR),
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
        )

        if result.returncode != 0:
            # Check if target doesn't exist
            if "no target" in result.stderr.lower() or "unknown" in result.stderr.lower():
                return {
                    "error": "Zig parity_runner target not defined. "
                    "Add parity_runner step to src/clients/zig/build.zig"
                }
            return {"error": f"Zig build failed: {result.stderr}"}

        return None

    except subprocess.TimeoutExpired:
        return {"error": "Zig build timed out"}
    except FileNotFoundError:
        return {"error": f"Zig not found at {zig_path}"}
    except Exception as e:
        return {"error": f"Zig build error: {e}"}
