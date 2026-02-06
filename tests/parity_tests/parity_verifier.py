# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Cross-SDK result verification with exact nanodegree matching.

Per CONTEXT.md:
- Exact match required for coordinates (nanodegrees)
- No epsilon tolerance
- Python as golden reference
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from tests.parity_tests.sdk_runners import (
    python_runner,
    node_runner,
    go_runner,
    java_runner,
    c_runner,
)


@dataclass
class ParityResult:
    """Result of a single parity test across SDKs.

    Attributes:
        operation: Operation being tested (e.g., 'insert', 'query-radius')
        test_case: Test case identifier/name
        passed: True if all SDKs returned identical results
        sdk_results: Raw results from each SDK
        mismatches: Details of any mismatches found
        error: Error message if test couldn't complete
    """

    operation: str
    test_case: str
    passed: bool
    sdk_results: Dict[str, Any] = field(default_factory=dict)
    mismatches: List[Dict[str, Any]] = field(default_factory=list)
    error: Optional[str] = None


class ParityVerifier:
    """Verify SDK results match across all implementations.

    Uses Python SDK as golden reference per CONTEXT.md.
    Requires exact match for coordinates (nanodegree precision, no epsilon).
    """

    # Ordered list of SDKs for consistent matrix display
    SDK_ORDER = ["python", "node", "go", "java", "c"]

    def __init__(self, server_url: str):
        """Initialize verifier with server URL.

        Args:
            server_url: ArcherDB server URL for SDK connections
        """
        self.server_url = server_url
        self._runners = {
            "python": python_runner,
            "node": node_runner,
            "go": go_runner,
            "java": java_runner,
            "c": c_runner,
        }

    def verify_parity(
        self,
        operation: str,
        input_data: Dict[str, Any],
        sdks: List[str],
        test_case_name: str = "unnamed",
    ) -> ParityResult:
        """Run operation across SDKs and verify results match.

        Args:
            operation: Operation to test (e.g., 'insert')
            input_data: Input data for the operation
            sdks: List of SDKs to test
            test_case_name: Name of the test case for reporting

        Returns:
            ParityResult with pass/fail status and any mismatches
        """
        results: Dict[str, Any] = {}

        # Run operation on each SDK
        for sdk in sdks:
            try:
                runner = self._runners.get(sdk)
                if runner is None:
                    results[sdk] = {"error": f"Unknown SDK: {sdk}"}
                    continue
                results[sdk] = runner.run_operation(self.server_url, operation, input_data)
            except Exception as e:
                results[sdk] = {"error": str(e)}

        # Python as golden reference (per CONTEXT.md)
        if "python" not in results:
            return ParityResult(
                operation=operation,
                test_case=test_case_name,
                passed=False,
                sdk_results=results,
                error="Python reference not available",
            )

        python_result = results["python"]

        # Check if Python itself failed
        if isinstance(python_result, dict) and "error" in python_result:
            return ParityResult(
                operation=operation,
                test_case=test_case_name,
                passed=False,
                sdk_results=results,
                error=f"Python reference failed: {python_result['error']}",
            )

        # Compare all other SDKs against Python
        mismatches: List[Dict[str, Any]] = []

        for sdk in sdks:
            if sdk == "python":
                continue

            sdk_result = results[sdk]

            # Handle SDK errors
            if isinstance(sdk_result, dict) and "error" in sdk_result:
                mismatches.append(
                    {
                        "sdk": sdk,
                        "type": "error",
                        "expected": python_result,
                        "actual": sdk_result,
                        "diff": {"error": sdk_result["error"]},
                    }
                )
                continue

            # Compare results
            if not self._compare_results(python_result, sdk_result):
                mismatches.append(
                    {
                        "sdk": sdk,
                        "type": "mismatch",
                        "expected": python_result,
                        "actual": sdk_result,
                        "diff": self._compute_diff(python_result, sdk_result),
                    }
                )

        return ParityResult(
            operation=operation,
            test_case=test_case_name,
            passed=len(mismatches) == 0,
            sdk_results=results,
            mismatches=mismatches,
        )

    def _compare_results(self, expected: Any, actual: Any) -> bool:
        """Compare results with exact nanodegree matching (per CONTEXT.md).

        No epsilon tolerance - coordinates must match exactly.

        Args:
            expected: Expected result (from Python SDK)
            actual: Actual result (from other SDK)

        Returns:
            True if results are identical, False otherwise
        """
        if type(expected) != type(actual):
            return False

        if isinstance(expected, dict):
            if set(expected.keys()) != set(actual.keys()):
                return False
            return all(
                self._compare_results(expected[k], actual[k]) for k in expected.keys()
            )

        if isinstance(expected, list):
            if len(expected) != len(actual):
                return False
            return all(
                self._compare_results(e, a) for e, a in zip(expected, actual)
            )

        # Exact match for numbers (no epsilon per CONTEXT.md)
        # This ensures nanodegree precision is verified
        return expected == actual

    def _compute_diff(self, expected: Any, actual: Any) -> Dict[str, Any]:
        """Compute semantic diff between results.

        Args:
            expected: Expected result
            actual: Actual result

        Returns:
            Dict describing differences
        """
        # Use deepdiff if available for detailed comparison
        try:
            from deepdiff import DeepDiff

            diff = DeepDiff(expected, actual, significant_digits=15)
            return diff.to_dict() if diff else {}
        except ImportError:
            # Fallback to simple comparison
            return {"expected": expected, "actual": actual}

    def write_reports(
        self,
        results: List[ParityResult],
        json_path: str,
        markdown_path: str,
    ) -> None:
        """Generate JSON and Markdown reports (per CONTEXT.md).

        Args:
            results: List of ParityResult objects
            json_path: Output path for JSON report (CI automation)
            markdown_path: Output path for Markdown report (human review)
        """
        # Ensure output directories exist
        Path(json_path).parent.mkdir(parents=True, exist_ok=True)
        Path(markdown_path).parent.mkdir(parents=True, exist_ok=True)

        # JSON report for CI automation
        json_report = self._generate_json_report(results)
        with open(json_path, "w") as f:
            json.dump(json_report, f, indent=2, default=str)

        # Markdown report for human review
        self._write_markdown(results, markdown_path)

    def _generate_json_report(self, results: List[ParityResult]) -> Dict[str, Any]:
        """Generate machine-readable JSON report.

        Args:
            results: List of ParityResult objects

        Returns:
            Dict suitable for JSON serialization
        """
        passed = sum(1 for r in results if r.passed)
        failed = sum(1 for r in results if not r.passed)

        return {
            "generated": datetime.utcnow().isoformat() + "Z",
            "summary": {
                "total_tests": len(results),
                "passed": passed,
                "failed": failed,
                "pass_rate": f"{100 * passed / max(len(results), 1):.1f}%",
                "target": "70 cells (14 ops x 5 SDKs)",
            },
            "results": [
                {
                    "operation": r.operation,
                    "test_case": r.test_case,
                    "passed": r.passed,
                    "error": r.error,
                    "mismatches": [
                        {
                            "sdk": m.get("sdk"),
                            "type": m.get("type"),
                            "diff": m.get("diff"),
                        }
                        for m in r.mismatches
                    ],
                }
                for r in results
            ],
        }

    def _write_markdown(self, results: List[ParityResult], path: str) -> None:
        """Generate human-readable parity matrix.

        Args:
            results: List of ParityResult objects
            path: Output path for Markdown file
        """
        lines = [
            "# SDK Parity Matrix",
            "",
            "Cross-SDK parity verification for ArcherDB. All 5 SDKs must produce "
            "identical results for identical operations.",
            "",
            f"**Generated:** {datetime.utcnow().isoformat()}Z",
            "",
            "## Summary",
            "",
            f"- Total tests: {len(results)}",
            f"- Passed: {sum(1 for r in results if r.passed)}",
            f"- Failed: {sum(1 for r in results if not r.passed)}",
            "",
            "## Methodology",
            "",
            "Per Phase 14 CONTEXT.md decisions:",
            "- **Verification strategy:** Layered approach",
            "  1. Direct comparison between all SDKs",
            "  2. Python SDK as golden reference for tie-breaking",
            "  3. Server responses as ultimate truth",
            "- **Equality definition:** Exact match required",
            "  - Structural equality (same fields, types, values)",
            "  - Exact byte equality for coordinates (nanodegrees, no epsilon tolerance)",
            "",
            "## Matrix (14 ops x 5 SDKs = 70 cells)",
            "",
            "| Operation | Python | Node.js | Go | Java | C |",
            "|-----------|--------|---------|----|----|---|",
        ]

        # Group results by operation
        by_op: Dict[str, Dict[str, bool]] = {}
        for r in results:
            if r.operation not in by_op:
                by_op[r.operation] = {sdk: True for sdk in self.SDK_ORDER}

            # Mark SDK as failed if any test case failed
            if not r.passed:
                # Mark Python (reference) and all mismatched SDKs
                for mismatch in r.mismatches:
                    sdk = mismatch.get("sdk")
                    if sdk:
                        by_op[r.operation][sdk] = False

        # Generate rows for each operation
        for op in sorted(by_op.keys()):
            row = f"| {op} |"
            for sdk in self.SDK_ORDER:
                if sdk in by_op[op]:
                    symbol = "PASS" if by_op[op][sdk] else "FAIL"
                    row += f" {symbol} |"
                else:
                    row += " - |"
            lines.append(row)

        # Add any missing operations from the standard list
        from tests.parity_tests.parity_runner import OPERATIONS

        for op in OPERATIONS:
            if op not in by_op:
                row = f"| {op} |"
                for _ in self.SDK_ORDER:
                    row += " - |"
                lines.append(row)

        lines.extend(
            [
                "",
                "Legend: PASS = identical results, FAIL = mismatch, - = not tested",
                "",
                "## Edge Cases Verified",
                "",
                "Per CONTEXT.md, all geographic edge cases are high priority:",
                "",
                "### Polar Regions",
                "- North pole (lat=90, any longitude)",
                "- South pole (lat=-90, any longitude)",
                "- Longitude ambiguity at poles",
                "",
                "### Antimeridian (Date Line)",
                "- lon=180 and lon=-180 (same line)",
                "- Queries spanning date line",
                "- Points near antimeridian",
                "",
                "### Zero Crossings",
                "- Equator (lat=0)",
                "- Prime meridian (lon=0)",
                "- Intersection (0, 0)",
                "",
                "## Running Parity Tests",
                "",
                "```bash",
                "# Start server",
                "./zig/zig build run -- --config=lite",
                "",
                "# Run all parity tests",
                "python tests/parity_tests/parity_runner.py",
                "",
                "# Run specific operation",
                "python tests/parity_tests/parity_runner.py --ops insert query-radius",
                "",
                "# Run specific SDKs",
                "python tests/parity_tests/parity_runner.py --sdks python node go",
                "```",
                "",
                "## CI Integration",
                "",
                "Machine-readable report: `reports/parity.json`",
                "",
                "---",
                f"*Last updated: {datetime.utcnow().isoformat()}Z*",
            ]
        )

        with open(path, "w") as f:
            f.write("\n".join(lines))
