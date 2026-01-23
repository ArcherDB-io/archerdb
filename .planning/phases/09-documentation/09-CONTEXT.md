# Phase 9: Documentation - Context

**Gathered:** 2026-01-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Complete documentation for users and operators — API reference, architecture deep-dive, operations runbook. All content lives in a unified docs/ directory as Markdown files.

</domain>

<decisions>
## Implementation Decisions

### Documentation Structure
- Single unified site — all content together (API, architecture, operations)
- Markdown files in docs/ directory — GitHub-viewable, buildable with any static site generator
- Flat structure — all files in docs/ root (api-reference.md, architecture.md, operations.md, etc.)
- README index — top-level docs/README.md with links to all sections
- Mermaid diagrams — text-based, renders on GitHub, easy to maintain
- Dedicated quickstart.md — first thing users see after README
- Cross-reference SDK READMEs — link to sdk/*/README.md, don't duplicate content
- CHANGELOG.md — dedicated changelog tracking releases, breaking changes, features

### Audience & Depth
- Dual audience — balanced coverage for application developers AND infrastructure operators
- Two-level depth — start conceptual, then have 'deep dive' sections for implementation details
- Friendly/approachable tone — conversational, welcoming, explains jargon (like Stripe docs)
- Explain concepts as needed — brief explanations inline when geospatial concepts appear, link to deep dives

### Code Examples
- Multiple tabs — show examples in all 5 SDK languages (Python, Go, Java, Node.js, C)
- Mix of completeness — quickstart has complete runnable programs, API reference has focused snippets
- Mix of error handling — quickstart shows full error handling, API reference uses simplified

### Operations Focus
- Bare metal/VMs primary — systemd units, manual setup, traditional ops focus
- Multi-cloud coverage — cover AWS, GCP, Azure specifics where relevant
- Troubleshooting both ways — quick tips inline + comprehensive troubleshooting section

### Claude's Discretion
- Runbook procedure detail level — choose step-by-step or conceptual per procedure
- File naming conventions
- Section ordering within documents
- Diagram complexity and placement

</decisions>

<specifics>
## Specific Ideas

- Tone should be like Stripe docs — professional but approachable, explains things well
- Architecture deep dives should explain WHY design choices were made, not just what they are
- SDK examples should cross-reference the authoritative SDK READMEs, not duplicate content

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 09-documentation*
*Context gathered: 2026-01-23*
