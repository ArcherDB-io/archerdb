# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Cross-SDK parity test infrastructure.

This package provides tools for verifying all 6 SDKs (Python, Node.js, Go,
Java, C, Zig) produce identical results for identical operations.

Per Phase 14 CONTEXT.md:
- Python SDK as golden reference for tie-breaking
- Server responses as ultimate truth
- Exact match required for coordinates (nanodegrees, no epsilon tolerance)
"""

from .parity_runner import run_parity_tests, OPERATIONS, SDK_RUNNERS
from .parity_verifier import ParityVerifier, ParityResult

__all__ = [
    "run_parity_tests",
    "OPERATIONS",
    "SDK_RUNNERS",
    "ParityVerifier",
    "ParityResult",
]
