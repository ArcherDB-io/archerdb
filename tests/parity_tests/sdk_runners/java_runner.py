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
PARITY_MAIN_CLASS = "com.archerdb.sdktests.ParityRunner"
CLASSPATH_FILE = TEST_DIR / ".parity.classpath"
TEST_CLASSES_DIR = TEST_DIR / "target" / "test-classes"
MAIN_CLASSES_DIR = TEST_DIR / "target" / "classes"
_JAVA_RUNTIME: dict[str, str] | None = None


def run_operation(server_url: str, operation: str, input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Run one Java SDK parity operation."""
    env = os.environ.copy()
    env["ARCHERDB_URL"] = server_url

    # Check if Maven project exists
    pom_path = TEST_DIR / "pom.xml"
    if not pom_path.exists():
        return _run_with_inline_java(server_url, operation, input_data, env)

    try:
        runtime = _ensure_runtime(env)
        if "error" in runtime:
            return runtime

        result = subprocess.run(
            [
                runtime["java"],
                "-cp",
                runtime["classpath"],
                PARITY_MAIN_CLASS,
                operation,
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
        return {"error": "Java runner timed out (120s)"}
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON output: {e}"}
    except FileNotFoundError:
        return {"error": "Java runtime not found. Install Java/Maven to run Java parity tests."}
    except Exception as e:
        return {"error": str(e)}


def _ensure_runtime(env: Dict[str, str]) -> Dict[str, str]:
    """Compile the parity test project once and cache its runtime classpath."""
    global _JAVA_RUNTIME
    if _JAVA_RUNTIME is not None:
        return _JAVA_RUNTIME

    compile_result = _compile_test_project(env)
    if compile_result is not None:
        return compile_result

    try:
        raw_classpath = CLASSPATH_FILE.read_text(encoding="utf-8").strip()
    except OSError as e:
        return {"error": f"Failed to read Java parity classpath: {e}"}

    classpath_entries = [str(TEST_CLASSES_DIR)]
    if MAIN_CLASSES_DIR.exists():
        classpath_entries.append(str(MAIN_CLASSES_DIR))
    if raw_classpath:
        classpath_entries.append(raw_classpath)

    java_home = env.get("JAVA_HOME")
    java_bin = str(Path(java_home) / "bin" / "java") if java_home else "java"
    _JAVA_RUNTIME = {
        "java": java_bin,
        "classpath": os.pathsep.join(classpath_entries),
    }
    return _JAVA_RUNTIME


def _compile_test_project(env: Dict[str, str]) -> Dict[str, str] | None:
    """Compile the parity test project and emit a reusable test runtime classpath."""
    install_result = _install_java_sdk(env)
    if install_result is not None:
        return install_result

    result = _run_maven(
        TEST_DIR,
        [
            "-q",
            "-DskipTests",
            "test-compile",
            "dependency:build-classpath",
            f"-Dmdep.outputFile={CLASSPATH_FILE.name}",
            f"-Dmdep.pathSeparator={os.pathsep}",
            "-Dmdep.includeScope=test",
        ],
        env,
        timeout=180,
    )
    if result.returncode == 0:
        return None
    output = (result.stderr or "") + "\n" + (result.stdout or "")
    return {"error": _trim_error(output) or "Java parity compile failed"}


def _install_java_sdk(env: Dict[str, str]) -> Dict[str, str] | None:
    """Install the local ArcherDB Java SDK into the active Maven repository."""
    if not (SDK_DIR / "pom.xml").exists():
        return {"error": f"Java SDK pom.xml not found at {pom_path_string(SDK_DIR / 'pom.xml')}"}

    result = _run_maven(
        SDK_DIR,
        [
            "-q",
            "-DskipTests",
            "-Dmaven.javadoc.skip=true",
            "install",
        ],
        env,
        timeout=300,
    )
    if result.returncode == 0:
        return None
    output = (result.stderr or "") + "\n" + (result.stdout or "")
    return {"error": _trim_error(output) or "Java SDK install failed"}


def _run_maven(
    cwd: Path,
    args: list[str],
    env: Dict[str, str],
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["mvn", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
    )


def _requires_local_sdk_install(output: str) -> bool:
    return (
        "Could not find artifact com.archerdb:archerdb-java:0.1.0-SNAPSHOT" in output
        or "Failed to collect dependencies" in output and "archerdb-java" in output
    )


def _trim_error(output: str) -> str:
    stripped = output.strip()
    if not stripped:
        return ""
    for line in stripped.splitlines():
        candidate = line.strip()
        if candidate:
            return candidate
    return stripped


def _run_with_inline_java(
    server_url: str,
    operation: str,
    input_data: Dict[str, Any],
    env: Dict[str, str],
) -> Dict[str, Any]:
    """Fail explicitly when the Maven-backed Java parity runner is unavailable.

    Args:
        server_url: Server URL
        operation: Operation name
        input_data: Input data
        env: Environment variables

    Returns:
        Dict with operation result
    """
    _ = server_url
    _ = operation
    _ = input_data
    _ = env
    return {
        "error": (
            "Java parity runner requires the Maven-backed test project at "
            f"{pom_path_string(TEST_DIR / 'pom.xml')}; inline fallback is intentionally disabled."
        )
    }


def pom_path_string(path: Path) -> str:
    return str(path)
