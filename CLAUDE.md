<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

# ArcherDB Project Instructions

## Task Tracking: GitHub Issues

**All implementation work is tracked in GitHub Issues, not in markdown files.**

When asked to implement, continue implementation, or work on tasks:

1. **Check GitHub first:**
   - Project Board: https://github.com/orgs/ArcherDB-io/projects/1
   - Issues: https://github.com/ArcherDB-io/archerdb/issues
   - Milestones: https://github.com/ArcherDB-io/archerdb/milestones

2. **Use `gh` CLI to find work:**
   ```bash
   # List open issues by milestone
   gh issue list --milestone "F0: Fork & Foundation" --state open

   # View specific issue
   gh issue view <number>

   # Update issue status
   gh issue edit <number> --add-label "in-progress"
   ```

3. **Key issue types:**
   - Individual tasks: `F0.1.1`, `F0.1.2`, etc.
   - Epic issues: `F0.1: Repository Setup (Epic)` - groups related tasks
   - Exit Criteria: `F0.EC`, `F1.EC`, etc. - phase validation gates
   - Reference: Issue #506 - project documentation

4. **Workflow:**
   - Pick an issue from the project board
   - Move to "In Progress"
   - Implement the task
   - Close issue when done
   - Update Exit Criteria checkboxes when phase complete

## Project Structure

- `openspec/changes/add-geospatial-core/` - The active change proposal
- `openspec/specs/` - Specification documents
- `tools/` - Build and migration scripts
- GitHub Issues #39-523 - All implementation tasks

## Implementation Phases

| Phase | Milestone | Focus |
|-------|-----------|-------|
| F0 | Fork & Foundation | Fork TigerBeetle, setup, knowledge acquisition |
| F1 | State Machine Replacement | GeoEvent state machine |
| F2 | RAM Index Integration | O(1) entity lookup |
| F3 | S2 Spatial Index | Spatial queries |
| F4 | VOPR & Hardening | Replication testing |
| F5 | SDK & Production Readiness | SDKs, security, docs |