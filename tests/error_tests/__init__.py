# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Error handling test suite for ArcherDB SDKs.

This package contains comprehensive error handling tests that validate:
- Connection failure handling (ERR-01)
- Timeout error handling (ERR-02)
- Input validation errors (ERR-03)
- Empty result handling (ERR-04)
- Server error handling (ERR-05)
- Retry behavior with backoff (ERR-06)
- Batch size limit errors (ERR-07)

All tests verify error CODES, not message text, per CONTEXT.md decision.
"""
