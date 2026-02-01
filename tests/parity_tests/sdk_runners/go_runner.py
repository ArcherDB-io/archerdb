# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Go SDK runner for parity tests.

Runs Go SDK operations via compiled test binary with JSON input/output.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

# Paths for Go SDK
SDK_DIR = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "go"
PARITY_BINARY = SDK_DIR / "bin" / "parity_runner"
PARITY_SRC = SDK_DIR / "cmd" / "parity_runner"


def run_operation(server_url: str, operation: str, input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Run Go SDK operation via compiled binary.

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

    # Check if binary exists after build attempt
    if not os.path.exists(binary_path):
        # Fall back to go run
        return _run_with_go_run(server_url, operation, input_data, env)

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


def _build_binary(env: Dict[str, str]) -> Dict[str, Any] | None:
    """Build Go parity runner binary.

    Args:
        env: Environment variables

    Returns:
        Error dict if build failed, None if successful
    """
    if not PARITY_SRC.exists():
        return {"error": f"Go parity runner source not found at {PARITY_SRC}"}

    try:
        # Ensure bin directory exists
        PARITY_BINARY.parent.mkdir(parents=True, exist_ok=True)

        result = subprocess.run(
            ["go", "build", "-o", str(PARITY_BINARY), f"./{PARITY_SRC.name}"],
            cwd=str(SDK_DIR),
            capture_output=True,
            text=True,
            env=env,
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


def _run_with_go_run(
    server_url: str,
    operation: str,
    input_data: Dict[str, Any],
    env: Dict[str, str],
) -> Dict[str, Any]:
    """Fall back to running Go code directly with go run.

    This is slower but doesn't require a pre-built binary.

    Args:
        server_url: Server URL
        operation: Operation name
        input_data: Input data
        env: Environment variables

    Returns:
        Dict with operation result
    """
    # Create temporary Go file with inline runner
    go_code = _get_go_runner_code()

    try:
        # Write temporary Go file
        temp_file = SDK_DIR / "_parity_runner_temp.go"
        with open(temp_file, "w") as f:
            f.write(go_code)

        result = subprocess.run(
            ["go", "run", str(temp_file), operation],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
            cwd=str(SDK_DIR),
        )

        # Clean up temp file
        if temp_file.exists():
            temp_file.unlink()

        if result.returncode != 0:
            return {"error": result.stderr.strip() or "Go run failed"}

        return json.loads(result.stdout.strip())

    except Exception as e:
        return {"error": str(e)}


def _get_go_runner_code() -> str:
    """Get Go code for inline parity runner.

    Returns:
        Go source code as string
    """
    return '''
package main

import (
    "encoding/json"
    "fmt"
    "io"
    "os"
)

// Minimal parity runner - actual SDK calls would go here
// This is a placeholder that returns error indicating SDK not configured

type Input map[string]interface{}
type Output map[string]interface{}

func main() {
    if len(os.Args) < 2 {
        outputError("operation argument required")
        return
    }
    operation := os.Args[1]

    inputBytes, err := io.ReadAll(os.Stdin)
    if err != nil {
        outputError(fmt.Sprintf("failed to read input: %v", err))
        return
    }

    var input Input
    if err := json.Unmarshal(inputBytes, &input); err != nil {
        outputError(fmt.Sprintf("failed to parse input: %v", err))
        return
    }

    result := runOperation(operation, input)
    outputJSON(result)
}

func runOperation(operation string, input Input) Output {
    // Placeholder - would use actual Go SDK here
    return Output{
        "error": fmt.Sprintf("Go SDK parity runner not fully implemented for: %s", operation),
    }
}

func outputJSON(data Output) {
    bytes, _ := json.Marshal(data)
    fmt.Println(string(bytes))
}

func outputError(msg string) {
    outputJSON(Output{"error": msg})
}
'''
