# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 Anthus Labs, Inc.
"""Pytest configuration for archerdb tests."""

import sys
from pathlib import Path

# Add src directory to Python path for development testing
src_path = Path(__file__).parent.parent / "src"
if str(src_path) not in sys.path:
    sys.path.insert(0, str(src_path))
