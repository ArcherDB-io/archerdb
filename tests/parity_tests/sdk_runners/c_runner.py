# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""C SDK runner for parity tests.

Runs C SDK operations via Zig-built test binary.
"""

from __future__ import annotations

import json
import os
import platform
import subprocess
from pathlib import Path
from typing import Any, Dict

# Paths for C SDK
SDK_DIR = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "c"
TEST_DIR = Path(__file__).parent.parent.parent / "sdk_tests" / "c"
PARITY_BINARY = TEST_DIR / "zig-out" / "bin" / "parity_runner"
ZIG_BINARY = Path(__file__).parent.parent.parent.parent / "zig" / "zig"
LIB_ROOT = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "c" / "lib"


def _c_sdk_lib_dir() -> Path | None:
    """Resolve platform-specific C SDK library directory."""
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Darwin":
        return LIB_ROOT / ("aarch64-macos" if machine in {"arm64", "aarch64"} else "x86_64-macos")
    if system == "Linux":
        return LIB_ROOT / ("aarch64-linux-gnu.2.27" if machine in {"arm64", "aarch64"} else "x86_64-linux-gnu.2.27")
    return None


def run_operation(server_url: str, operation: str, input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Run C SDK operation via compiled test binary.

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
    lib_dir = _c_sdk_lib_dir()
    if lib_dir and lib_dir.exists():
        if platform.system() == "Darwin":
            existing = env.get("DYLD_LIBRARY_PATH", "")
            env["DYLD_LIBRARY_PATH"] = (
                f"{lib_dir}:{existing}" if existing else str(lib_dir)
            )
        elif platform.system() == "Linux":
            existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = (
                f"{lib_dir}:{existing}" if existing else str(lib_dir)
            )

    # Build binary if needed
    binary_path = str(PARITY_BINARY)
    if not os.path.exists(binary_path):
        build_result = _build_binary(env)
        if build_result is not None:
            return build_result

    # If the binary still does not exist, fail closed instead of inventing a result.
    if not os.path.exists(binary_path):
        return {
            "error": f"C SDK parity runner not built. Expected at: {binary_path}"
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
            error_msg = result.stderr.strip() if result.stderr else "C runner failed"
            return {"error": error_msg}

        stdout = result.stdout.strip()
        if not stdout:
            return {"error": "No output from C runner"}

        return json.loads(stdout)

    except subprocess.TimeoutExpired:
        return {"error": "C runner timed out (30s)"}
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON output: {e}"}
    except Exception as e:
        return {"error": str(e)}


def _build_binary(env: Dict[str, str]) -> Dict[str, Any] | None:
    """Build C parity runner binary using Zig build system.

    Args:
        env: Environment variables

    Returns:
        Error dict if build failed, None if successful
    """
    # Check if Zig is available
    zig_path = str(ZIG_BINARY) if ZIG_BINARY.exists() else "zig"

    # Check for build.zig in test directory
    build_file = TEST_DIR / "build.zig"
    if not build_file.exists():
        return {
            "error": f"C parity runner build.zig not found at {build_file}. "
            "Create parity_runner target in tests/sdk_tests/c/build.zig"
        }

    try:
        result = subprocess.run(
            [zig_path, "build", "parity_runner"],
            cwd=str(TEST_DIR),
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
        )

        if result.returncode != 0:
            return {"error": f"C build failed: {result.stderr}"}

        return None

    except subprocess.TimeoutExpired:
        return {"error": "C build timed out"}
    except FileNotFoundError:
        return {"error": f"Zig not found at {zig_path}"}
    except Exception as e:
        return {"error": f"C build error: {e}"}
