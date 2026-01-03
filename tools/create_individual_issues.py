#!/usr/bin/env python3
"""
Script to create individual GitHub issues from tasks.md
Parses all checkbox items and creates one issue per task.
"""

import subprocess
import re
import json
import time
import sys
from pathlib import Path

REPO = "ArcherDB-io/archerdb"
TASKS_FILE = Path(__file__).parent.parent / "openspec/changes/add-geospatial-core/tasks.md"

# Label mappings for phases
PHASE_LABELS = {
    "F0": ("phase:F0", "F0: Fork & Foundation"),
    "F1": ("phase:F1", "F1: State Machine"),
    "F2": ("phase:F2", "F2: RAM Index"),
    "F3": ("phase:F3", "F3: S2 Geometry"),
    "F4": ("phase:F4", "F4: Replication"),
    "F5": ("phase:F5", "F5: Production"),
}

# Label mappings for reference sections (1.x-19.x)
SECTION_LABELS = {
    "1": ("spec:core", "Core Types & Constants"),
    "2": ("spec:memory", "Memory Management"),
    "3": ("spec:memory", "Hybrid Memory Index"),
    "4": ("spec:core", "Checksums & Integrity"),
    "5": ("spec:storage", "I/O Subsystem"),
    "6": ("spec:storage", "Storage - Data File"),
    "7": ("spec:storage", "Storage - Grid & LSM"),
    "8": ("spec:vsr", "VSR Protocol - Core"),
    "9": ("spec:vsr", "VSR Protocol - View Changes"),
    "10": ("spec:vsr", "VSR Protocol - State & Recovery"),
    "11": ("spec:vsr", "VSR Protocol - Commit Pipeline"),
    "12": ("spec:query", "S2 Integration"),
    "13": ("spec:query", "Query Engine"),
    "14": ("spec:core", "Testing & Simulation"),
    "15": ("spec:client", "Client Protocol & SDKs"),
    "16": ("spec:client", "Security (mTLS)"),
    "17": ("spec:ops", "Observability"),
    "18": ("spec:ops", "CLI Integration"),
    "19": ("spec:ops", "Validation & Benchmarks"),
}

# Milestone mappings (must match exact names in GitHub)
MILESTONES = {
    "F0": "F0: Fork & Foundation",
    "F1": "F1: State Machine Replacement",
    "F2": "F2: RAM Index Integration",
    "F3": "F3: S2 Spatial Index",
    "F4": "F4: VOPR & Hardening",
    "F5": "F5: SDK & Production Readiness",
}


def create_labels():
    """Create all necessary labels if they don't exist."""
    labels = [
        # Phase labels
        ("phase:F0", "0052cc", "Phase F0: Fork & Foundation"),
        ("phase:F1", "1d76db", "Phase F1: State Machine Replacement"),
        ("phase:F2", "5319e7", "Phase F2: RAM Index Integration"),
        ("phase:F3", "0e8a16", "Phase F3: S2 Geometry Integration"),
        ("phase:F4", "d93f0b", "Phase F4: Replication Testing"),
        ("phase:F5", "fbca04", "Phase F5: Production Hardening"),
        # Spec category labels (should already exist)
        ("spec:core", "0366d6", "Core types and constants"),
        ("spec:memory", "1d76db", "Memory management"),
        ("spec:storage", "5319e7", "Storage engine"),
        ("spec:vsr", "d93f0b", "VSR replication"),
        ("spec:query", "0e8a16", "Query engine"),
        ("spec:client", "fbca04", "Client protocol/SDKs"),
        ("spec:ops", "006b75", "Operations/Observability"),
        # Special labels
        ("critical", "b60205", "Critical path item"),
        ("decision-gate", "c2e0c6", "Decision gate - requires go/no-go"),
        ("reference", "d4c5f9", "Reference task (build-from-scratch spec)"),
    ]

    for name, color, desc in labels:
        subprocess.run(
            ["gh", "label", "create", name, "--repo", REPO,
             "--color", color, "--description", desc],
            capture_output=True
        )
    print(f"Created/verified {len(labels)} labels")


def parse_tasks():
    """Parse tasks.md and extract all checkbox items."""
    content = TASKS_FILE.read_text()

    tasks = []
    current_section = ""
    current_subsection = ""
    in_reference_section = False
    in_exit_criteria = False

    lines = content.split('\n')

    for i, line in enumerate(lines):
        # Track section headers
        if line.startswith('## Phase F'):
            match = re.search(r'Phase (F\d)', line)
            if match:
                current_section = match.group(1)
                in_reference_section = False
                in_exit_criteria = False
        elif line.startswith('### F'):
            match = re.search(r'(F\d+\.\d+)', line)
            if match:
                current_subsection = match.group(1)
            in_exit_criteria = False
        elif line.startswith('## ') and re.match(r'## \d+\.', line):
            # Reference sections (1. Core Types, 2. Memory, etc.)
            match = re.search(r'## (\d+)\.', line)
            if match:
                current_section = match.group(1)
                in_reference_section = True
                in_exit_criteria = False
        elif 'Original Tasks (Reference' in line:
            in_reference_section = True
            in_exit_criteria = False
        elif 'Exit Criteria' in line or '**Exit Criteria' in line:
            in_exit_criteria = True

        # Skip exit criteria items
        if in_exit_criteria:
            if line.startswith('---') or line.startswith('## ') or line.startswith('### '):
                in_exit_criteria = False
            continue

        # Parse checkbox items
        if line.strip().startswith('- [ ]'):
            task_match = re.match(r'\s*- \[ \] (\S+)\s+(.*)', line)
            if task_match:
                task_id = task_match.group(1)
                task_desc = task_match.group(2).strip()

                # Clean up task_id (remove trailing colons, asterisks)
                task_id = task_id.rstrip(':').rstrip('*').strip('*')

                # Skip invalid task IDs (must start with F or be a number like 1.1)
                if not (task_id.startswith('F') or re.match(r'^\d+\.\d+', task_id)):
                    continue

                # Determine if this is a phase task or reference task
                is_phase_task = task_id.startswith('F')

                # Get section info
                if is_phase_task:
                    # Extract phase from task ID (F0.1.1 -> F0)
                    phase_match = re.match(r'(F\d)', task_id)
                    section = phase_match.group(1) if phase_match else current_section
                else:
                    # Extract section from task ID (1.1 -> 1, 12.3 -> 12)
                    sec_match = re.match(r'(\d+)\.', task_id)
                    section = sec_match.group(1) if sec_match else current_section

                # Check for special markers
                is_critical = '**CRITICAL' in line or 'CRITICAL' in task_desc
                is_decision_gate = 'DECISION GATE' in line or 'GO/NO-GO' in task_desc

                # Get multi-line description if present
                full_desc = task_desc
                j = i + 1
                while j < len(lines) and lines[j].strip().startswith('-') == False and lines[j].strip().startswith('#') == False:
                    if lines[j].strip() and not lines[j].strip().startswith('- ['):
                        if lines[j].strip().startswith('**') or lines[j].strip().startswith('-'):
                            full_desc += '\n' + lines[j].strip()
                    else:
                        break
                    j += 1
                    if j - i > 20:  # Limit description length
                        break

                tasks.append({
                    'id': task_id,
                    'title': task_desc[:100] + ('...' if len(task_desc) > 100 else ''),
                    'description': full_desc,
                    'section': section,
                    'is_phase_task': is_phase_task,
                    'is_critical': is_critical,
                    'is_decision_gate': is_decision_gate,
                    'is_reference': in_reference_section and not is_phase_task,
                })

    return tasks


def get_labels_for_task(task):
    """Determine appropriate labels for a task."""
    labels = []

    if task['is_phase_task']:
        phase = task['section']
        if phase in PHASE_LABELS:
            labels.append(PHASE_LABELS[phase][0])
    else:
        section = task['section']
        if section in SECTION_LABELS:
            labels.append(SECTION_LABELS[section][0])
        if task['is_reference']:
            labels.append('reference')

    if task['is_critical']:
        labels.append('critical')
    if task['is_decision_gate']:
        labels.append('decision-gate')

    return labels


def get_milestone_for_task(task):
    """Determine appropriate milestone for a task."""
    if task['is_phase_task']:
        phase = task['section']
        return MILESTONES.get(phase, None)
    else:
        # Reference tasks go to "Spec Implementation Reference"
        return "Spec Implementation Reference"


def create_issue(task, dry_run=False):
    """Create a single GitHub issue for a task."""
    title = f"{task['id']}: {task['title']}"

    body = f"""## Task: {task['id']}

{task['description']}

---
*Auto-generated from tasks.md*
"""

    labels = get_labels_for_task(task)
    milestone = get_milestone_for_task(task)

    if dry_run:
        print(f"Would create: {title}")
        print(f"  Labels: {labels}")
        print(f"  Milestone: {milestone}")
        return True

    cmd = ["gh", "issue", "create", "--repo", REPO, "--title", title, "--body", body]

    for label in labels:
        cmd.extend(["--label", label])

    if milestone:
        cmd.extend(["--milestone", milestone])

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"Error creating issue {task['id']}: {result.stderr}")
        return False

    # Extract issue URL from output
    if result.stdout:
        print(f"Created: {result.stdout.strip()}")

    return True


def main():
    dry_run = "--dry-run" in sys.argv
    start_from = 0

    # Allow resuming from a specific task number
    for arg in sys.argv:
        if arg.startswith("--start="):
            start_from = int(arg.split("=")[1])

    print("Parsing tasks.md...")
    tasks = parse_tasks()
    print(f"Found {len(tasks)} tasks")

    # Filter out exit criteria and other non-actionable items
    tasks = [t for t in tasks if t['id'] and not t['id'].startswith('Exit')]
    print(f"After filtering: {len(tasks)} actionable tasks")

    if not dry_run:
        print("Creating labels...")
        create_labels()

    print(f"\n{'DRY RUN: ' if dry_run else ''}Creating issues...")

    created = 0
    failed = 0

    for i, task in enumerate(tasks[start_from:], start=start_from):
        print(f"\n[{i+1}/{len(tasks)}] {task['id']}")

        if create_issue(task, dry_run):
            created += 1
        else:
            failed += 1

        if not dry_run:
            # Rate limiting - GitHub allows ~5000 requests/hour
            # 0.5s delay = 120 requests/min = 7200/hour (safe margin)
            time.sleep(0.5)

        # Save progress every 50 issues
        if (i + 1) % 50 == 0:
            print(f"\n--- Progress: {created} created, {failed} failed ---\n")

    print(f"\n=== Complete ===")
    print(f"Created: {created}")
    print(f"Failed: {failed}")
    print(f"Total tasks: {len(tasks)}")


if __name__ == "__main__":
    main()
