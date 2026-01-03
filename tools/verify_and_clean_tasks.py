#!/usr/bin/env python3
"""
Verify tasks in tasks.md against GitHub issues and remove verified tasks.
"""

import re
import subprocess
import json
from pathlib import Path

TASKS_FILE = Path(__file__).parent.parent / "openspec/changes/add-geospatial-core/tasks.md"
REPO = "ArcherDB-io/archerdb"

def get_github_task_ids():
    """Get all task IDs from GitHub issues."""
    result = subprocess.run(
        ["gh", "issue", "list", "--repo", REPO, "--state", "all", "--limit", "500", "--json", "number,title"],
        capture_output=True, text=True
    )
    issues = json.loads(result.stdout)

    task_ids = set()
    for issue in issues:
        title = issue['title']
        # Extract task ID from title (e.g., "F0.1.1: ..." or "1.2: ...")
        match = re.match(r'^([A-Z0-9]+\.[0-9]+(?:\.[0-9]+)?[a-z]?):', title)
        if match:
            task_ids.add(match.group(1))

    return task_ids

def process_tasks_file(github_ids, dry_run=True):
    """Process tasks.md and remove verified tasks."""
    content = TASKS_FILE.read_text()
    lines = content.split('\n')

    new_lines = []
    removed_count = 0
    kept_tasks = []

    for line in lines:
        # Check if this is a task line
        task_match = re.match(r'^(\s*- \[ \] )([A-Z0-9]+\.[0-9]+(?:\.[0-9]+)?[a-z]?)\s+(.*)$', line)

        if task_match:
            prefix = task_match.group(1)
            task_id = task_match.group(2)
            task_desc = task_match.group(3)

            if task_id in github_ids:
                # Task exists in GitHub - remove it
                removed_count += 1
                if not dry_run:
                    continue  # Skip this line (remove it)
                else:
                    print(f"REMOVE: {task_id}")
            else:
                # Task not in GitHub - keep it
                kept_tasks.append(task_id)
                if dry_run:
                    print(f"KEEP (not in GitHub): {task_id}")

        new_lines.append(line)

    if not dry_run:
        TASKS_FILE.write_text('\n'.join(new_lines))

    return removed_count, kept_tasks

def main():
    import sys
    dry_run = "--dry-run" in sys.argv

    print("Fetching GitHub issue task IDs...")
    github_ids = get_github_task_ids()
    print(f"Found {len(github_ids)} task IDs in GitHub issues")

    print(f"\n{'DRY RUN: ' if dry_run else ''}Processing tasks.md...")
    removed, kept = process_tasks_file(github_ids, dry_run)

    print(f"\n=== Summary ===")
    print(f"Tasks removed: {removed}")
    print(f"Tasks kept (not in GitHub): {len(kept)}")
    if kept:
        print(f"Kept task IDs: {', '.join(sorted(kept))}")

    if dry_run:
        print("\nRun without --dry-run to actually modify the file.")

if __name__ == "__main__":
    main()
