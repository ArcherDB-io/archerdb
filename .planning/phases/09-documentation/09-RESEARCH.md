# Phase 9: Documentation - Research

**Researched:** 2026-01-23
**Domain:** Technical documentation for distributed geospatial database
**Confidence:** HIGH

## Summary

This phase focuses on completing documentation for ArcherDB users and operators. The project already has substantial documentation in `docs/` (getting-started, operations-runbook, disaster-recovery, error-codes, etc.) and generated SDK READMEs. The remaining work is organizational: unifying existing content, filling gaps (API reference, architecture deep-dives), and establishing a consistent structure.

The user decisions in CONTEXT.md establish clear constraints: Markdown files in a flat `docs/` directory, Mermaid diagrams, cross-reference SDK READMEs without duplication, Stripe-style tone, and dual audience (developers + operators). This research focuses on patterns and practices for executing these decisions effectively.

**Primary recommendation:** Structure docs around user journeys (quickstart, tasks, reference), use Mermaid for all diagrams, and leverage the existing high-quality content as templates for consistency.

## Standard Stack

The established tools for this documentation effort:

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Markdown | CommonMark | Documentation format | GitHub-native, universal tooling support |
| Mermaid | 11.x | Diagrams-as-code | Renders on GitHub, version-controllable, text-based |
| Keep a Changelog | 1.1.0 | Changelog format | Industry standard format, machine-readable |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| GitHub Flavored Markdown | N/A | Extended Markdown | Tables, task lists, syntax highlighting |
| Semantic Versioning | 2.0.0 | Version numbering | CHANGELOG.md entries |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Mermaid | Draw.io/Excalidraw | More visual control, but not version-controllable as text |
| Flat docs/ | Subdirectories | More organization, but harder to navigate on GitHub |
| Manual CHANGELOG | Conventional Commits + semantic-release | Automation, but requires commit convention adoption |

## Architecture Patterns

### Recommended Documentation Structure

Based on user decisions (flat structure in docs/):

```
docs/
├── README.md              # Index/navigation hub (links to all sections)
├── quickstart.md          # First-time user experience (5-minute success)
├── api-reference.md       # Complete API documentation
├── architecture.md        # System architecture deep-dive
├── operations.md          # Operations runbook (unified)
├── troubleshooting.md     # Comprehensive troubleshooting guide
├── CHANGELOG.md           # Release history
├── getting-started.md     # (existing) Detailed setup guide
├── error-codes.md         # (existing) Error reference
├── sdk-retry-semantics.md # (existing) Retry behavior
├── disaster-recovery.md   # (existing) DR procedures
├── capacity-planning.md   # (existing) Capacity guide
├── multi-region-deployment.md # (existing) Multi-region guide
├── encryption-guide.md    # (existing) Encryption setup
├── lsm-tuning.md          # (existing) Storage tuning
└── internals/             # (existing) Internal docs
    └── message-bus-errors.md
```

### Pattern 1: Stripe-Style Three-Level Documentation

**What:** Organize content into Conceptual (why), Task-based (how), and Reference (what)

**When to use:** All major documentation sections

**Structure:**
```markdown
# API Reference

## Overview
Brief conceptual introduction explaining what the API does and why.

## Common Tasks
### Inserting Location Events
Step-by-step task with complete examples.

### Querying by Radius
Step-by-step task with complete examples.

## Reference
### Operations
Complete operation reference with all parameters.

### Data Types
Complete field reference.
```

### Pattern 2: Multi-Language Code Examples (Tabs Pattern)

**What:** Show code in all 5 SDK languages using HTML details/summary or heading markers

**When to use:** API reference, quickstart, operations examples

**Example (GitHub-compatible):**
```markdown
### Inserting Events

<details>
<summary>Node.js</summary>

\`\`\`typescript
const batch = client.createBatch()
batch.add(createGeoEvent({ entity_id: id(), latitude: 37.7749, longitude: -122.4194 }))
await batch.commit()
\`\`\`

</details>

<details>
<summary>Python</summary>

\`\`\`python
batch = client.create_batch()
batch.add(archerdb.create_geo_event(entity_id=archerdb.id(), latitude=37.7749, longitude=-122.4194))
batch.commit()
\`\`\`

</details>

<details>
<summary>Go</summary>

\`\`\`go
events := []types.GeoEvent{{EntityID: types.ID(), LatNano: 37774900000, LonNano: -122419400000}}
results, err := client.CreateEvents(events)
\`\`\`

</details>

<details>
<summary>Java</summary>

\`\`\`java
GeoEvent event = GeoEvent.builder().entityId(ID.generate()).latNano(37774900000L).build();
client.createEvents(List.of(event));
\`\`\`

</details>

<details>
<summary>C</summary>

\`\`\`c
geo_event_t event = {.entity_id = arch_id(), .lat_nano = 37774900000, .lon_nano = -122419400000};
arch_create_events(client, &event, 1, callback, context);
\`\`\`

</details>
```

### Pattern 3: Mermaid Architecture Diagrams

**What:** Text-based diagrams for system architecture

**When to use:** Architecture documentation, data flow explanations

**Example:**
```markdown
\`\`\`mermaid
flowchart TB
    subgraph Clients
        SDK[SDK Client]
    end

    subgraph Primary["Primary Region"]
        R0[Replica 0]
        R1[Replica 1]
        R2[Replica 2]
        R0 <-->|VSR Consensus| R1
        R1 <-->|VSR Consensus| R2
    end

    subgraph Storage["Storage Layer"]
        LSM[LSM-Tree]
        S2[S2 Index]
        RAM[RAM Index]
    end

    SDK -->|Request| R0
    R0 --> LSM
    R0 --> S2
    R0 --> RAM
\`\`\`
```

### Pattern 4: Runbook Procedure Format

**What:** Consistent structure for operational procedures

**When to use:** Operations runbook, disaster recovery, troubleshooting

**Template:**
```markdown
### Procedure: [Name]

**When to use:** [Trigger conditions]

**Prerequisites:**
- [ ] Prerequisite 1
- [ ] Prerequisite 2

**Steps:**

1. **[Action]**
   \`\`\`bash
   command here
   \`\`\`
   Expected output: [description]

2. **[Action]**
   \`\`\`bash
   command here
   \`\`\`
   Expected output: [description]

**Verification:**
- [ ] Verification step 1
- [ ] Verification step 2

**Rollback:**
If something goes wrong: [rollback steps]
```

### Anti-Patterns to Avoid

- **Duplicating SDK content:** Link to `src/clients/*/README.md` instead of copying. SDK READMEs are auto-generated from Zig source.
- **Wall-of-text without structure:** Use headings, tables, and code blocks liberally.
- **Outdated examples:** Ensure code examples compile/run. Use consistent patterns from existing docs.
- **Passive voice in procedures:** Use imperative ("Run the command") not passive ("The command should be run").
- **Jargon without explanation:** Explain VSR, LSM, S2 briefly when first mentioned, link to deep-dives.

## Don't Hand-Roll

Problems that have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Diagram rendering | Custom image generation | Mermaid | Text-based, GitHub-native, version-controllable |
| API docs generation | Manual maintenance | Keep sync with existing code examples | SDK READMEs already generated from Zig |
| Changelog format | Custom format | Keep a Changelog standard | Machine-readable, widely recognized |
| Code highlighting | Custom CSS | GitHub Markdown fenced blocks | Native support, consistent rendering |
| Multi-language tabs | JavaScript widgets | HTML details/summary | Works on GitHub without JS |

**Key insight:** The existing codebase has excellent documentation patterns (see `docs/getting-started.md`, `docs/operations-runbook.md`). Reuse these templates for consistency rather than inventing new formats.

## Common Pitfalls

### Pitfall 1: Documentation Drift from Code

**What goes wrong:** Documentation becomes outdated as code evolves
**Why it happens:** Documentation not treated as part of the feature
**How to avoid:**
- Use code examples that are tested (or from tested samples)
- Link to source files when documenting behavior
- Include "Source: `src/file.zig`" citations
**Warning signs:** Code examples that don't match actual API

### Pitfall 2: Wrong Audience Level

**What goes wrong:** Operators can't find procedures; developers can't find API details
**Why it happens:** Single document trying to serve both audiences
**How to avoid:**
- Separate quickstart (developers) from operations (operators)
- Use explicit "For operators" / "For developers" sections
- Start conceptual, then dive deep (two-level depth decision)
**Warning signs:** Complaints about "too basic" or "too advanced"

### Pitfall 3: Incomplete Error Documentation

**What goes wrong:** Users hit errors with no guidance
**Why it happens:** Error codes added without updating docs
**How to avoid:**
- Error codes reference (`docs/error-codes.md`) already exists
- Ensure all new errors documented with action/resolution
- Cross-reference from troubleshooting guide
**Warning signs:** Support requests for undocumented errors

### Pitfall 4: Mermaid Diagram Complexity

**What goes wrong:** Diagrams become unreadable when too detailed
**Why it happens:** Trying to show everything in one diagram
**How to avoid:**
- Layer diagrams: system overview, then component details
- Max 10-15 nodes per diagram
- Use subgraphs to group related components
- Link to more detailed diagrams rather than cramming
**Warning signs:** Diagrams requiring horizontal scroll

### Pitfall 5: Changelog Abandonment

**What goes wrong:** CHANGELOG.md becomes empty or inconsistent
**Why it happens:** No clear ownership or process
**How to avoid:**
- Follow Keep a Changelog format strictly
- Include: Added, Changed, Deprecated, Removed, Fixed, Security sections
- Date entries with ISO format (YYYY-MM-DD)
- Link to issues/PRs for context
**Warning signs:** Releases without corresponding changelog entries

## Code Examples

### Example 1: Keep a Changelog Format

Source: [keepachangelog.com](https://keepachangelog.com/en/1.1.0/)

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- New polygon query with holes support (AREF-03)

## [1.2.0] - 2026-01-20

### Added
- Multi-region replication with async WAL shipping
- S3 backup transport option

### Changed
- Improved compaction performance by 30%

### Fixed
- Race condition in replica sync during view change

## [1.1.0] - 2026-01-10

### Added
- Encryption at rest with AES-256-GCM
- TTL expiration for automatic data cleanup

[Unreleased]: https://github.com/ArcherDB-io/archerdb/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/ArcherDB-io/archerdb/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ArcherDB-io/archerdb/releases/tag/v1.1.0
```

### Example 2: API Reference Entry Format

Based on existing `docs/getting-started.md` patterns:

```markdown
## queryRadius

Query for all entities within a radius of a point.

### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `center_lat` | float64 | Yes | Center latitude in degrees (-90 to 90) |
| `center_lon` | float64 | Yes | Center longitude in degrees (-180 to 180) |
| `radius_m` | uint32 | Yes | Radius in meters (1 to 40,000,000) |
| `limit` | uint32 | No | Maximum results (default: 1000, max: 10,000) |
| `cursor` | bytes | No | Pagination cursor from previous response |
| `group_id` | uint64 | No | Filter by group ID |

### Response

| Field | Type | Description |
|-------|------|-------------|
| `events` | GeoEvent[] | Matching events |
| `has_more` | bool | True if more results available |
| `cursor` | bytes | Cursor for next page (if has_more) |

### Errors

| Code | Name | Description |
|------|------|-------------|
| 100 | `INVALID_COORDINATES` | Latitude/longitude out of range |
| 101 | `INVALID_RADIUS` | Radius outside valid range |
| 300 | `QUERY_RESULT_TOO_LARGE` | Result set exceeds limit |

### Example

<details>
<summary>Node.js</summary>

\`\`\`typescript
const results = await client.queryRadius({
  center_lat: 37.7749,
  center_lon: -122.4194,
  radius_m: 1000,
  limit: 100,
})

for (const event of results.events) {
  console.log(\`Entity \${event.entity_id}: \${event.lat_nano}, \${event.lon_nano}\`)
}

// Pagination
if (results.has_more) {
  const nextPage = await client.queryRadius({
    center_lat: 37.7749,
    center_lon: -122.4194,
    radius_m: 1000,
    limit: 100,
    cursor: results.cursor,
  })
}
\`\`\`

</details>

<!-- Repeat for Python, Go, Java, C -->
```

### Example 3: Architecture Deep-Dive Section

Based on existing `docs/vsr_understanding.md` patterns:

```markdown
## Viewstamped Replication (VSR)

ArcherDB uses Viewstamped Replication for consensus, providing strong consistency across replicas.

### Why VSR?

VSR provides these guarantees:
- **Linearizability:** Operations appear to execute atomically in a single order
- **Durability:** Committed operations survive any minority of replica failures
- **Leader election:** Automatic failover when the primary fails

### How It Works

\`\`\`mermaid
sequenceDiagram
    participant C as Client
    participant P as Primary
    participant B1 as Backup 1
    participant B2 as Backup 2

    C->>P: Request
    P->>P: Prepare (assign timestamp)
    P->>B1: Prepare message
    P->>B2: Prepare message
    B1->>P: Prepare OK
    B2->>P: Prepare OK
    P->>P: Commit (quorum reached)
    P->>C: Reply
    P->>B1: Commit message
    P->>B2: Commit message
\`\`\`

**Key concepts:**

- **View:** A configuration where one replica is primary. View number increases on leader change.
- **Prepare:** Primary assigns a timestamp and broadcasts to backups.
- **Commit:** After quorum acknowledgment, operation is committed.
- **View change:** When primary fails, backups elect a new primary in a higher-numbered view.

### Deep Dive: View Change Protocol

[Detailed explanation of view change with diagrams...]
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Static diagrams (PNG) | Mermaid diagrams-as-code | 2023+ | Version-controllable, easier updates |
| API docs separate from code | OpenAPI/generated docs | 2020+ | Single source of truth |
| Manual changelog | Conventional commits + automation | 2022+ | Consistent, machine-readable |
| Single-audience docs | Task-based + reference split | 2021+ | Better user experience |

**Current best practices (2026):**
- Stripe-style documentation: Interactive, developer-focused, task-oriented
- Diagrams as code: Mermaid for version control and easy updates
- Layered documentation: Overview -> Tasks -> Reference
- Multi-language examples: Show all supported languages in parallel

## Open Questions

1. **Wire protocol documentation depth**
   - What we know: Need to document request/response formats, error codes
   - What's unclear: How much binary protocol detail to expose vs. treating SDKs as the interface
   - Recommendation: Focus on SDK-level API, document wire protocol as advanced/internals

2. **SDK README synchronization**
   - What we know: SDK READMEs are auto-generated from `src/scripts/client_readmes.zig`
   - What's unclear: Whether main docs should link to SDK READMEs or inline content
   - Recommendation: Link to SDK READMEs for installation/setup, inline common operations

3. **Kubernetes documentation scope**
   - What we know: Operations includes "Kubernetes deployment" per requirements
   - What's unclear: How much K8s-specific content (Helm charts? Operators?)
   - Recommendation: Start with basic K8s manifests, defer Helm/Operator to future

## Sources

### Primary (HIGH confidence)
- Existing ArcherDB documentation (`docs/*.md`) - patterns and content to reuse
- Keep a Changelog specification - https://keepachangelog.com/en/1.1.0/
- Semantic Versioning specification - https://semver.org/

### Secondary (MEDIUM confidence)
- [Stripe Documentation Best Practices](https://apidog.com/blog/stripe-docs/) - Documentation style patterns
- [Mermaid Architecture Diagrams](https://docs.mermaidchart.com/mermaid-oss/syntax/architecture.html) - Diagram syntax and features
- [SRE Runbook Templates](https://www.solarwinds.com/sre-best-practices/runbook-template) - Runbook structure patterns
- [Technical Documentation Best Practices 2026](https://www.qodo.ai/blog/code-documentation-best-practices-2026/) - Current industry practices

### Tertiary (LOW confidence)
- General web search results for documentation patterns - validated against primary sources

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Using industry-standard Markdown + Mermaid per user decisions
- Architecture: HIGH - Patterns derived from existing ArcherDB docs which are high quality
- Pitfalls: MEDIUM - Based on general documentation experience, not ArcherDB-specific validation

**Research date:** 2026-01-23
**Valid until:** 60 days (documentation patterns are stable)
