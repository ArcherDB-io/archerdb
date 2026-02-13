# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Java SDK runner for parity tests."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

# Paths for Java SDK
SDK_DIR = Path(__file__).parent.parent.parent.parent / "src" / "clients" / "java"
TEST_DIR = Path(__file__).parent.parent.parent / "sdk_tests" / "java"


def run_operation(server_url: str, operation: str, input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Run one Java SDK parity operation."""
    env = os.environ.copy()
    env["ARCHERDB_URL"] = server_url

    # Check if Maven project exists
    pom_path = TEST_DIR / "pom.xml"
    if not pom_path.exists():
        return _run_with_inline_java(server_url, operation, input_data, env)

    try:
        result = subprocess.run(
            [
                "mvn",
                "-q",
                "test-compile",
                "org.codehaus.mojo:exec-maven-plugin:3.1.0:java",
                "-Dexec.mainClass=com.archerdb.sdktests.ParityRunner",
                "-Dexec.classpathScope=test",
                f"-Dexec.args={operation}",
            ],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            cwd=str(TEST_DIR),
            env=env,
            timeout=120,
        )

        if result.returncode != 0:
            error_msg = (
                result.stderr.strip()
                or result.stdout.strip()
                or "Java runner failed"
            )
            return {"error": error_msg}

        stdout = result.stdout.strip()
        if not stdout:
            return {"error": "No output from Java runner"}

        # Find JSON in output (Maven may print other things)
        for line in stdout.split("\n"):
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line)

        return {"error": f"No JSON found in output: {stdout[:200]}"}

    except subprocess.TimeoutExpired:
        return {"error": "Java runner timed out (60s)"}
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON output: {e}"}
    except FileNotFoundError:
        return {"error": "Maven not found. Install Maven to run Java parity tests."}
    except Exception as e:
        return {"error": str(e)}


def _run_with_inline_java(
    server_url: str,
    operation: str,
    input_data: Dict[str, Any],
    env: Dict[str, str],
) -> Dict[str, Any]:
    """Fall back to running Java with javac/java directly.

    Args:
        server_url: Server URL
        operation: Operation name
        input_data: Input data
        env: Environment variables

    Returns:
        Dict with operation result
    """
    # Check if Java is available
    try:
        subprocess.run(
            ["java", "-version"],
            capture_output=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {"error": "Java not found. Install Java to run parity tests."}

    java_code = _get_java_runner_code(operation)

    try:
        # Create temporary directory for Java files
        temp_dir = SDK_DIR / "_parity_temp"
        temp_dir.mkdir(parents=True, exist_ok=True)

        # Write Java source
        java_file = temp_dir / "ParityRunner.java"
        with open(java_file, "w") as f:
            f.write(java_code)

        # Compile
        compile_result = subprocess.run(
            ["javac", str(java_file)],
            capture_output=True,
            text=True,
            cwd=str(temp_dir),
            timeout=30,
        )

        if compile_result.returncode != 0:
            return {"error": f"Java compile failed: {compile_result.stderr}"}

        # Run
        result = subprocess.run(
            ["java", "ParityRunner"],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            cwd=str(temp_dir),
            env=env,
            timeout=30,
        )

        # Cleanup
        import shutil

        shutil.rmtree(temp_dir, ignore_errors=True)

        if result.returncode != 0:
            return {"error": result.stderr.strip() or "Java run failed"}

        return json.loads(result.stdout.strip())

    except Exception as e:
        return {"error": str(e)}


def _get_java_runner_code(operation: str) -> str:
    """Get Java code for inline parity runner.

    Args:
        operation: Operation name

    Returns:
        Java source code as string
    """
    return f'''
import java.io.*;
import java.util.*;

public class ParityRunner {{
    public static void main(String[] args) throws Exception {{
        // Read input from stdin
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {{
            sb.append(line);
        }}
        String input = sb.toString();

        String url = System.getenv("ARCHERDB_URL");
        if (url == null) url = "http://127.0.0.1:7000";

        // Placeholder - would use actual Java SDK here
        System.out.println("{{\\"error\\":\\"Java SDK parity runner not fully implemented for: {operation}\\"}}");
    }}
}}
'''
