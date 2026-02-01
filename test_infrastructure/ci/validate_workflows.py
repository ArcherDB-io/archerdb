#!/usr/bin/env python3
"""Validate CI workflow configurations."""

import yaml
import json
import sys
from pathlib import Path


def validate_workflow(path: Path) -> list:
    """Validate a single workflow file."""
    errors = []
    with open(path) as f:
        workflow = yaml.safe_load(f)

    if not workflow:
        errors.append(f"{path}: Empty workflow")
        return errors

    # Check all jobs have timeout-minutes
    for job_name, job in workflow.get('jobs', {}).items():
        if 'timeout-minutes' not in job:
            errors.append(f"{path}: Job '{job_name}' missing timeout-minutes")

    return errors


def validate_fixtures(fixtures_dir: Path) -> list:
    """Validate all fixture files."""
    errors = []
    required_ops = [
        'insert', 'upsert', 'delete',
        'query-uuid', 'query-uuid-batch', 'query-radius', 'query-polygon', 'query-latest',
        'ping', 'status',
        'ttl-set', 'ttl-extend', 'ttl-clear',
        'topology'
    ]

    for op in required_ops:
        fixture_path = fixtures_dir / f"{op}.json"
        if not fixture_path.exists():
            errors.append(f"Missing fixture: {fixture_path}")
            continue

        with open(fixture_path) as f:
            try:
                data = json.load(f)
            except json.JSONDecodeError as e:
                errors.append(f"{fixture_path}: Invalid JSON - {e}")
                continue

        if 'cases' not in data:
            errors.append(f"{fixture_path}: Missing 'cases' array")
        elif len(data['cases']) == 0:
            errors.append(f"{fixture_path}: Empty 'cases' array")

        # Check each case has required fields
        for i, case in enumerate(data.get('cases', [])):
            if 'name' not in case:
                errors.append(f"{fixture_path}: Case {i} missing 'name'")
            if 'tags' not in case:
                errors.append(f"{fixture_path}: Case {i} missing 'tags'")
            if 'input' not in case:
                errors.append(f"{fixture_path}: Case {i} missing 'input'")

    return errors


def main():
    root = Path(__file__).parent.parent.parent
    errors = []

    # Validate workflows
    workflows = [
        root / '.github/workflows/sdk-smoke.yml',
        root / '.github/workflows/sdk-pr.yml',
        root / '.github/workflows/sdk-nightly.yml',
    ]
    for wf in workflows:
        if wf.exists():
            errors.extend(validate_workflow(wf))
        else:
            errors.append(f"Missing workflow: {wf}")

    # Validate fixtures
    fixtures_dir = root / 'test_infrastructure/fixtures/v1'
    if fixtures_dir.exists():
        errors.extend(validate_fixtures(fixtures_dir))
    else:
        errors.append(f"Missing fixtures directory: {fixtures_dir}")

    if errors:
        print("Validation errors:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    else:
        print("All validations passed!")
        sys.exit(0)


if __name__ == '__main__':
    main()
