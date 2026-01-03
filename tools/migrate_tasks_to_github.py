#!/usr/bin/env python3
"""
Migrate remaining tasks.md content to GitHub issues.
Creates epic issues for F-phase sections and reference documentation issue.
"""

import re
import subprocess
import json
from pathlib import Path

TASKS_FILE = Path(__file__).parent.parent / "openspec/changes/add-geospatial-core/tasks.md"
REPO = "ArcherDB-io/archerdb"

# Milestone mapping
MILESTONES = {
    "F0": "F0: Fork & Foundation",
    "F1": "F1: State Machine Replacement",
    "F2": "F2: RAM Index Integration",
    "F3": "F3: S2 Spatial Index",
    "F4": "F4: VOPR & Hardening",
    "F5": "F5: SDK & Production Readiness",
}

def get_existing_issues():
    """Get all existing issue titles to avoid duplicates."""
    result = subprocess.run(
        ["gh", "issue", "list", "--repo", REPO, "--state", "all", "--limit", "600", "--json", "number,title"],
        capture_output=True, text=True
    )
    issues = json.loads(result.stdout)
    return {issue['title']: issue['number'] for issue in issues}

def create_issue(title, body, labels, milestone=None):
    """Create a GitHub issue."""
    cmd = ["gh", "issue", "create", "--repo", REPO, "--title", title, "--body", body]

    if labels:
        cmd.extend(["--label", ",".join(labels)])
    if milestone:
        cmd.extend(["--milestone", milestone])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        url = result.stdout.strip()
        issue_num = url.split("/")[-1]
        print(f"Created: {title} -> #{issue_num}")
        return issue_num
    else:
        print(f"FAILED: {title} - {result.stderr}")
        return None

def extract_f_sections(content):
    """Extract F-phase sections (F0.0, F0.1, etc.) with their content."""
    sections = {}

    # Pattern to match ### F0.0 through ### F5.6 sections
    pattern = r'### (F\d\.\d+)\s+([^\n]+)\n(.*?)(?=\n### F\d\.\d+|\n## Phase F|\n---|\n## [A-Z]|\Z)'

    matches = re.findall(pattern, content, re.DOTALL)

    for match in matches:
        section_id = match[0]  # F0.0, F0.1, etc.
        section_title = match[1].strip()
        section_content = match[2].strip()

        # Skip if content is just exit criteria link or empty
        if not section_content or section_content.startswith("**Exit Criteria:**"):
            continue

        # Clean up the content - remove exit criteria line if present
        section_content = re.sub(r'\*\*Exit Criteria:\*\*.*$', '', section_content, flags=re.MULTILINE).strip()

        if section_content:
            sections[section_id] = {
                'title': section_title,
                'content': section_content
            }

    return sections

def extract_reference_sections(content):
    """Extract reference documentation sections."""
    reference = {}

    # Feasibility Assessment
    match = re.search(r'## FEASIBILITY ASSESSMENT.*?(?=\n## CRITICAL:|\n---\n\n## Phase)', content, re.DOTALL)
    if match:
        reference['feasibility'] = match.group(0).strip()

    # Fork Strategy Overview
    match = re.search(r'## CRITICAL: Implementation Strategy.*?(?=\n---\n\n## Phase F0)', content, re.DOTALL)
    if match:
        reference['fork_strategy'] = match.group(0).strip()

    # Component Mapping
    match = re.search(r'## Component Mapping.*?(?=\n---\n\n## Original)', content, re.DOTALL)
    if match:
        reference['component_mapping'] = match.group(0).strip()

    # Traceability Matrix (Fork Approach only)
    match = re.search(r'## Requirement Traceability Matrix \(Fork Approach\).*?(?=\n---\n\n## Requirement Traceability Matrix \(Reference)', content, re.DOTALL)
    if match:
        reference['traceability'] = match.group(0).strip()

    # Critical Path
    match = re.search(r'## Critical Path \(Fork Approach\).*?(?=\n---|\n## 26\.x|\Z)', content, re.DOTALL)
    if match:
        reference['critical_path'] = match.group(0).strip()

    return reference

def main():
    content = TASKS_FILE.read_text()
    existing = get_existing_issues()

    print("=== Extracting F-Phase Sections ===")
    f_sections = extract_f_sections(content)
    print(f"Found {len(f_sections)} F-sections with content")

    # Create epic issues for F-sections
    created_epics = []
    for section_id, data in sorted(f_sections.items()):
        title = f"{section_id}: {data['title']} (Epic)"

        if title in existing:
            print(f"SKIP (exists): {title}")
            continue

        # Determine phase for milestone
        phase = section_id.split('.')[0]  # F0, F1, etc.
        milestone = MILESTONES.get(phase)

        body = f"""## {data['title']}

{data['content']}

---
**Type:** Epic (groups related subtasks)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
"""

        labels = [f"phase:{phase}", "epic"]
        issue_num = create_issue(title, body, labels, milestone)
        if issue_num:
            created_epics.append((section_id, issue_num))

    print(f"\n=== Created {len(created_epics)} Epic Issues ===")

    # Extract reference documentation
    print("\n=== Extracting Reference Documentation ===")
    reference = extract_reference_sections(content)
    print(f"Found {len(reference)} reference sections")

    # Create single reference documentation issue
    ref_title = "📚 Project Reference Documentation"
    if ref_title not in existing:
        ref_body = """## Project Reference Documentation

This issue contains reference documentation for the ArcherDB geospatial fork project.

### Contents

1. [Feasibility Assessment](#feasibility-assessment)
2. [Fork Strategy](#fork-strategy)
3. [Component Mapping](#component-mapping)
4. [Traceability Matrix](#traceability-matrix)
5. [Critical Path](#critical-path)

---

"""
        if 'feasibility' in reference:
            ref_body += f"## Feasibility Assessment\n\n{reference['feasibility']}\n\n---\n\n"
        if 'fork_strategy' in reference:
            ref_body += f"## Fork Strategy\n\n{reference['fork_strategy']}\n\n---\n\n"
        if 'component_mapping' in reference:
            ref_body += f"## Component Mapping\n\n{reference['component_mapping']}\n\n---\n\n"
        if 'traceability' in reference:
            ref_body += f"## Traceability Matrix\n\n{reference['traceability']}\n\n---\n\n"
        if 'critical_path' in reference:
            ref_body += f"## Critical Path\n\n{reference['critical_path']}\n\n"

        ref_body += """
---
🤖 Generated with [Claude Code](https://claude.com/claude-code)
"""

        issue_num = create_issue(ref_title, ref_body, ["documentation", "reference"], None)
        if issue_num:
            # Pin the issue
            subprocess.run(["gh", "issue", "pin", issue_num, "--repo", REPO], capture_output=True)
            print(f"Pinned reference documentation issue #{issue_num}")
    else:
        print(f"SKIP (exists): {ref_title}")

    print("\n=== Migration Complete ===")
    print(f"Epic issues created: {len(created_epics)}")
    print("Reference documentation issue created")
    print("\nNext: Remove migrated content from tasks.md")

if __name__ == "__main__":
    main()
