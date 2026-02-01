#!/usr/bin/env python3
"""Load and apply warmup protocols for SDK benchmarks.

This module provides utilities to load warmup protocol configurations
and apply them to benchmark runs, ensuring stable and comparable results.
"""

import json
import os
from pathlib import Path
from dataclasses import dataclass
from typing import Optional, Dict


@dataclass
class WarmupProtocol:
    """Warmup configuration for a specific SDK."""
    sdk: str
    warmup_iterations: int
    measurement_iterations: int
    notes: str


def get_protocol_path() -> Path:
    """Get path to warmup_protocols.json file."""
    # First try relative to this file
    this_dir = Path(__file__).parent
    protocol_file = this_dir / "warmup_protocols.json"
    if protocol_file.exists():
        return protocol_file

    # Try project root
    project_root = Path(__file__).parent.parent.parent
    protocol_file = project_root / "test_infrastructure/ci/warmup_protocols.json"
    if protocol_file.exists():
        return protocol_file

    raise FileNotFoundError("warmup_protocols.json not found")


def load_warmup_protocol(sdk: str) -> WarmupProtocol:
    """Load warmup protocol for specified SDK.

    Args:
        sdk: SDK name (python, nodejs, java, go, c, zig)

    Returns:
        WarmupProtocol with iteration counts for the SDK

    Raises:
        KeyError: If SDK not found in protocols
        FileNotFoundError: If warmup_protocols.json not found
    """
    protocol_path = get_protocol_path()

    with open(protocol_path) as f:
        data = json.load(f)

    if sdk not in data["protocols"]:
        available = list(data["protocols"].keys())
        raise KeyError(f"SDK '{sdk}' not found. Available: {available}")

    proto = data["protocols"][sdk]
    return WarmupProtocol(
        sdk=sdk,
        warmup_iterations=proto["warmup_iterations"],
        measurement_iterations=proto["measurement_iterations"],
        notes=proto.get("notes", "")
    )


def load_all_protocols() -> Dict[str, WarmupProtocol]:
    """Load all warmup protocols.

    Returns:
        Dict mapping SDK name to WarmupProtocol
    """
    protocol_path = get_protocol_path()

    with open(protocol_path) as f:
        data = json.load(f)

    result = {}
    for sdk, proto in data["protocols"].items():
        result[sdk] = WarmupProtocol(
            sdk=sdk,
            warmup_iterations=proto["warmup_iterations"],
            measurement_iterations=proto["measurement_iterations"],
            notes=proto.get("notes", "")
        )
    return result


def get_variance_threshold() -> float:
    """Get acceptable coefficient of variation threshold.

    Returns:
        Float threshold (e.g., 0.05 for 5%)
    """
    protocol_path = get_protocol_path()

    with open(protocol_path) as f:
        data = json.load(f)

    return data["variance_threshold"]["acceptable_cv"]


if __name__ == "__main__":
    # Self-test: verify protocols can be loaded
    print("Testing warmup protocol loader...")

    # Test loading individual protocols
    for sdk in ["python", "nodejs", "java", "go", "c", "zig"]:
        proto = load_warmup_protocol(sdk)
        print(f"  {sdk}: warmup={proto.warmup_iterations}, measure={proto.measurement_iterations}")

    # Test loading all at once
    all_protos = load_all_protocols()
    assert len(all_protos) == 6, f"Expected 6 protocols, got {len(all_protos)}"

    # Test variance threshold
    cv = get_variance_threshold()
    assert cv == 0.05, f"Expected 0.05, got {cv}"

    print("All warmup protocol tests passed!")
