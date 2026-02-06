# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""SDK runners for parity tests.

Each runner implements:
    run_operation(server_url: str, operation: str, input_data: dict) -> dict

Runners execute operations via their respective SDKs and return
results as dicts for cross-SDK comparison.
"""

from . import python_runner
from . import node_runner
from . import go_runner
from . import java_runner
from . import c_runner

__all__ = [
    "python_runner",
    "node_runner",
    "go_runner",
    "java_runner",
    "c_runner",
]
