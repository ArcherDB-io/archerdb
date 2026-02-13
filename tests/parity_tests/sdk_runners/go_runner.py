# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Go SDK runner for parity tests."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

TEST_DIR = Path(__file__).parent.parent.parent / "sdk_tests" / "go"
PARITY_BINARY = TEST_DIR / "bin" / "parity_runner"
PARITY_SRC = TEST_DIR / "cmd" / "parity_runner"


def run_operation(
    server_url: str,
    operation: str,
    input_data: Dict[str, Any],
) -> Dict[str, Any]:
    """Run one Go SDK parity operation."""
    # Build binary if needed
    binary_path = str(PARITY_BINARY)
    if (not PARITY_BINARY.exists()) or _binary_is_stale():
        build_result = _build_binary()
        if build_result is not None:
            return build_result

    if not PARITY_BINARY.exists():
        return {"error": f"Go parity runner binary not found at {PARITY_BINARY}"}

    try:
        result = subprocess.run(
            [binary_path, operation],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            env={**os.environ, "ARCHERDB_URL": server_url},
            timeout=30,
            cwd=str(TEST_DIR),
        )

        if result.returncode != 0:
            error_msg = result.stderr.strip() if result.stderr else "Go runner failed"
            return {"error": error_msg}

        stdout = result.stdout.strip()
        if not stdout:
            return {"error": "No output from Go runner"}

        return json.loads(stdout)

    except subprocess.TimeoutExpired:
        return {"error": "Go runner timed out (30s)"}
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON output: {e}"}
    except Exception as e:
        return {"error": str(e)}


def _build_binary() -> Dict[str, Any] | None:
    """Build Go parity runner binary."""
    if not PARITY_SRC.exists():
        return {"error": f"Go parity runner source not found at {PARITY_SRC}"}

    try:
        # Ensure bin directory exists
        PARITY_BINARY.parent.mkdir(parents=True, exist_ok=True)

        result = subprocess.run(
            ["go", "build", "-o", str(PARITY_BINARY), "./cmd/parity_runner"],
            cwd=str(TEST_DIR),
            capture_output=True,
            text=True,
            timeout=60,
        )

        if result.returncode != 0:
            return {"error": f"Go build failed: {result.stderr}"}

        return None

    except subprocess.TimeoutExpired:
        return {"error": "Go build timed out"}
    except FileNotFoundError:
        return {"error": "Go not found. Install Go to run parity tests."}
    except Exception as e:
        return {"error": f"Go build error: {e}"}


def _binary_is_stale() -> bool:
    """Check whether parity binary is older than any source file."""
    if not PARITY_BINARY.exists():
        return True

    binary_mtime = PARITY_BINARY.stat().st_mtime
    for source in PARITY_SRC.rglob("*.go"):
        if source.stat().st_mtime > binary_mtime:
            return True
    return False
