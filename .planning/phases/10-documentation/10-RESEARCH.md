# Phase 10: Documentation - Research

**Researched:** 2026-01-31
**Domain:** Technical documentation for database product
**Confidence:** HIGH

## Summary

This phase focuses on creating customer and operator-facing documentation for ArcherDB. The project already has substantial documentation (26 markdown files in docs/, 5 SDK READMEs), so the primary work is gap analysis, standardization, and enhancement rather than starting from scratch.

Research confirms that effective documentation follows the Diataxis framework (tutorials, how-to guides, reference, explanation) with clear audience separation. For multi-language SDKs, language-specific examples must follow each language's idioms and conventions. The "getting started in under 10 minutes" requirement aligns with industry best practice of providing immediate value through quick start guides.

The existing documentation is comprehensive but lacks:
1. Unified structure across guides (inconsistent navigation, cross-linking)
2. Per-alert runbook pages referenced by Prometheus rules
3. Explicit OpenAPI/Swagger spec for API reference
4. Consistent multi-language code tabs across all examples
5. Performance tuning and security best practices consolidation

**Primary recommendation:** Audit existing documentation against requirements, standardize structure using Diataxis categories, create missing alert runbooks, and add OpenAPI spec generation.

## Standard Stack

The established approach for this documentation domain:

### Core
| Tool | Purpose | Why Standard |
|------|---------|--------------|
| Markdown | Documentation format | Universal, version-controlled, existing codebase standard |
| GitHub-flavored Markdown | Extended features | Code blocks, tables, task lists, collapsible sections |
| `<details>` tags | Multi-language code tabs | HTML in markdown for collapsible examples (already used in existing docs) |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| OpenAPI 3.0 spec | Machine-readable API definition | API reference generation, client SDK validation |
| mermaid diagrams | Architecture visualizations | Already used in architecture.md, continue for consistency |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| In-repo Markdown | Static site generator (Docusaurus, MkDocs) | Adds build complexity, but better navigation; recommend staying with markdown for now |
| Manual code examples | Auto-generated from SDK tests | Higher maintenance burden but ensures examples work; consider for future |
| HTML `<details>` | Custom tabs via docs site | Would require migration to docs site; keep current approach |

**No external dependencies needed.** Existing markdown infrastructure is sufficient.

## Architecture Patterns

### Recommended Documentation Structure

Based on Diataxis framework and existing layout:

```
docs/
├── README.md                    # Index with navigation
├── quickstart.md               # 5-minute "hello world" (exists)
├── getting-started.md          # Comprehensive setup (exists, enhance)
│
├── tutorials/                   # Learning-oriented
│   └── (currently inline in getting-started.md)
│
├── how-to/                      # Goal-oriented
│   ├── operations-runbook.md   # (exists)
│   ├── troubleshooting.md      # (exists)
│   └── (additional guides)
│
├── reference/                   # Information-oriented
│   ├── api-reference.md        # (exists, 1245 lines)
│   ├── error-codes.md          # (exists)
│   └── openapi.yaml            # NEW: Machine-readable spec
│
├── explanation/                 # Understanding-oriented
│   ├── architecture.md         # (exists, 800 lines)
│   └── vsr_understanding.md    # (exists)
│
├── runbooks/                    # Alert response guides (NEW)
│   ├── replica-down.md
│   ├── view-changes.md
│   ├── index-degraded.md
│   ├── high-read-latency.md
│   ├── high-write-latency.md
│   ├── disk-capacity.md
│   └── compaction-backlog.md
│
└── sdk/                         # SDK-specific (links to src/clients/)
    ├── python.md               # (README exists at src/clients/python/)
    ├── nodejs.md               # (README exists at src/clients/node/)
    ├── java.md                 # (README exists at src/clients/java/)
    ├── go.md                   # (README exists at src/clients/go/)
    └── c.md                    # (README exists at src/clients/c/)
```

### Pattern 1: Multi-Language Code Examples

**What:** Use HTML `<details>` tags to create collapsible language-specific examples
**When to use:** Any code example that should work in multiple languages
**Example:**
```markdown
<details>
<summary>Python</summary>

\`\`\`python
client = archerdb.GeoClientSync(config)
results = client.query_radius(lat=37.7749, lon=-122.4194, radius_m=1000)
\`\`\`

</details>

<details>
<summary>Node.js</summary>

\`\`\`typescript
const client = createGeoClient(config)
const results = await client.queryRadius({ latitude: 37.7749, longitude: -122.4194, radius_m: 1000 })
\`\`\`

</details>
```

Source: Already used in existing quickstart.md and getting-started.md

### Pattern 2: Alert Runbook Structure

**What:** Consistent structure for each alert response guide
**When to use:** Every alert defined in prometheusrule.yaml

```markdown
# Alert: [Alert Name]

## Quick Reference
- **Severity:** warning/critical
- **Metric:** `archerdb_metric_name`
- **Threshold:** [value]
- **Time to Respond:** [urgency]

## What This Alert Means
[1-2 sentences explaining the condition]

## Immediate Actions
1. [ ] Check step 1
2. [ ] Check step 2
3. [ ] Remediation action

## Investigation
### Common Causes
- Cause 1: [description and how to verify]
- Cause 2: [description and how to verify]

### Diagnostic Commands
\`\`\`bash
# Check relevant metrics
curl -s localhost:9090/metrics | grep metric_name
\`\`\`

## Resolution
### For Cause 1
[Step-by-step resolution]

### For Cause 2
[Step-by-step resolution]

## Prevention
[How to prevent this alert from firing]

## Related Documentation
- [Link to relevant doc]
```

### Pattern 3: API Reference with Field Tables

**What:** Clean JSON example + separate field explanation table
**When to use:** Every API endpoint documentation

```markdown
### queryRadius

Find all entities within a radius of a center point.

#### Request Example
\`\`\`json
{
  "center_lat": 37.7749,
  "center_lon": -122.4194,
  "radius_m": 1000,
  "limit": 100
}
\`\`\`

#### Request Fields
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `center_lat` | f64 | Yes | Center latitude in degrees (-90 to +90) |
| `center_lon` | f64 | Yes | Center longitude in degrees (-180 to +180) |
| `radius_m` | u32 | Yes | Radius in meters (1 to 40,000,000) |
| `limit` | u32 | No | Maximum results per page (default: 1,000) |

#### curl Example
\`\`\`bash
curl -X POST http://localhost:3000/query/radius \
  -H "Content-Type: application/json" \
  -d '{"center_lat": 37.7749, "center_lon": -122.4194, "radius_m": 1000}'
\`\`\`
```

Source: Existing api-reference.md pattern (verified)

### Anti-Patterns to Avoid

- **Feature-centric organization:** Write docs based on what users accomplish, not product features
- **Single doc doing everything:** Keep tutorials, reference, and concepts separate
- **Missing cross-links:** Every doc should link to related docs
- **Outdated examples:** Code examples must be tested/runnable
- **Inconsistent terminology:** Use glossary terms consistently

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| API documentation | Custom markdown-only | OpenAPI 3.0 spec + rendered markdown | Machine-readable, generates client stubs, validates requests |
| Code example testing | Manual verification | Extract examples to SDK test files | Examples drift from reality; tests ensure they work |
| Diagram generation | Static images | Mermaid in markdown | Editable, version-controlled, renders in GitHub |
| Search across docs | Custom search | GitHub search / docs site search | Built-in, well-tested |

**Key insight:** Documentation maintenance is the hard part. Patterns that reduce manual synchronization (generated from source, tested examples) are worth the initial investment.

## Common Pitfalls

### Pitfall 1: "10-minute quickstart" Takes 30 Minutes

**What goes wrong:** Getting started guides include too many options, explanations, or edge cases
**Why it happens:** Writers want to be comprehensive; reviewers add "just one more thing"
**How to avoid:**
- Time the quickstart with fresh users
- Target 5 commands maximum
- Defer all explanations to getting-started.md
- Test on different OS/environments
**Warning signs:** More than 1 page of content, more than 2 decision points

### Pitfall 2: Runbooks Reference Non-Existent URLs

**What goes wrong:** Prometheus alerts include `runbook_url` but page doesn't exist
**Why it happens:** Alerts added before documentation, URL format changes
**How to avoid:**
- Create runbook pages FIRST, then add to alerts
- Use relative URLs that work in-repo
- CI check that runbook URLs resolve
**Warning signs:** 404s from alert manager links, `https://docs.archerdb.io/runbooks/` URLs (external site not deployed)

### Pitfall 3: SDK Docs Diverge from Shared API Docs

**What goes wrong:** Python README says one thing, API reference says another
**Why it happens:** Separate maintenance, different authors, no cross-linking
**How to avoid:**
- SDK READMEs link to shared API reference for details
- SDK READMEs focus on language-specific idioms
- Shared concepts live in one place only
**Warning signs:** Same information repeated in multiple files

### Pitfall 4: Examples Use Different Coordinates/Scenarios

**What goes wrong:** quickstart uses NYC, getting-started uses SF, API ref uses London
**Why it happens:** Different authors, no style guide
**How to avoid:**
- Standardize on one "example city" (existing docs use SF: 37.7749, -122.4194)
- Create reusable example scenario (vehicle tracking in SF)
- Document the standard in contributing guide
**Warning signs:** Random coordinates, inconsistent entity_id patterns

### Pitfall 5: Operations Docs Don't Match Current Deployment

**What goes wrong:** Kubernetes deployment changed, docs still show old manifests
**Why it happens:** Infra changes don't update docs
**How to avoid:**
- Docs reference actual files in deploy/ directory
- Use code includes or symlinks where possible
- Review docs in deployment PRs
**Warning signs:** Out-of-date YAML examples, wrong image tags

## Code Examples

The existing codebase provides verified patterns:

### Coordinate Standardization
```python
# Use San Francisco as example city (consistent across all docs)
LAT = 37.7749
LON = -122.4194

# Entity tracking scenario: delivery vehicle
entity_id = archerdb.id()  # Use SDK's ID generator
```

Source: docs/getting-started.md, docs/quickstart.md (verified - both use SF coordinates)

### SDK Client Creation (All Languages)

All SDKs follow the same pattern for connection:

```python
# Python
config = GeoClientConfig(cluster_id=0, addresses=['127.0.0.1:3001'])
client = GeoClientSync(config)
```

```typescript
// Node.js
const client = createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3001'],
})
```

```go
// Go
client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
    ClusterID: types.ToUint128(0),
    Addresses: []string{"127.0.0.1:3001"},
})
```

```java
// Java
GeoClient client = GeoClient.create(0L, "127.0.0.1:3001");
```

Source: All SDK READMEs in src/clients/*/README.md (verified)

### Error Handling Pattern

All SDKs expose typed exceptions with `retryable` attribute:

```python
try:
    client.insert_events(events)
except ArcherDBError as e:
    if e.retryable:
        # Safe to retry with backoff
        pass
    else:
        # Fix request before retrying
        pass
```

Source: src/clients/python/README.md lines 350-417 (verified)

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single README | Diataxis-structured docs | 2024-2025 | Industry standard now |
| curl-only examples | Multi-language tabs | 2023-2024 | Developer expectation |
| Manual runbooks | Alert-linked runbooks | 2024+ | SRE best practice |
| Static API docs | OpenAPI + generated docs | 2022+ | Machine-readable, testable |

**Current in this project:**
- Multi-language tabs: YES (using `<details>`)
- Diataxis structure: PARTIAL (content exists but not strictly organized)
- Alert runbooks: NO (URLs in alerts point to non-existent pages)
- OpenAPI spec: NO (only markdown API reference)

## Open Questions

Things that couldn't be fully resolved:

1. **OpenAPI Spec Generation Strategy**
   - What we know: API is documented in markdown, needs machine-readable spec
   - What's unclear: Generate from code? Write manually? Use existing protocol definition?
   - Recommendation: Start with manual spec matching current api-reference.md, consider code generation later

2. **Documentation Hosting Decision**
   - What we know: User decided this is Claude's discretion
   - Options: GitHub markdown (current), GitHub Pages, external docs site
   - Recommendation: Stay with in-repo markdown for v1 (minimal friction), plan docs site for v2

3. **SDK Documentation Centralization**
   - What we know: READMEs exist in src/clients/*, docs/ has some SDK content
   - What's unclear: Should SDK docs move to docs/sdk/ or stay distributed?
   - Recommendation: Keep READMEs where they are (pip/npm discoverability), create docs/sdk/ pages that link to them with shared concepts

## Existing Documentation Inventory

### High Quality - Minimal Changes Needed
| Document | Lines | Assessment |
|----------|-------|------------|
| docs/architecture.md | 800 | Excellent, comprehensive |
| docs/api-reference.md | 1245 | Good structure, add OpenAPI |
| docs/disaster-recovery.md | 693 | Complete from Phase 8 |
| docs/backup-operations.md | 487 | Complete from Phase 8 |
| docs/upgrade-guide.md | 505 | Complete from Phase 8 |
| docs/operations-runbook.md | 826 | Good, needs alert runbook links |
| docs/troubleshooting.md | 862 | Good format, comprehensive |

### Needs Enhancement
| Document | Lines | Needed Work |
|----------|-------|-------------|
| docs/getting-started.md | 623 | Time test, ensure <10 min path |
| docs/quickstart.md | 501 | Verify claims, add missing languages |
| docs/capacity-planning.md | 500 | Good, ensure matches Phase 10 sizing guide requirement |

### Gaps to Fill
| Missing | Requirement | Priority |
|---------|-------------|----------|
| Alert runbooks (7 pages) | DOCS-03 | HIGH |
| Security best practices consolidated | DOCS-07 | MEDIUM |
| Performance tuning guide consolidated | DOCS-06 | MEDIUM |
| OpenAPI spec | DOCS-02 | MEDIUM |

### SDK READMEs Assessment
| SDK | Location | Lines | Assessment |
|-----|----------|-------|------------|
| Python | src/clients/python/README.md | 567 | Comprehensive, good examples |
| Node.js | src/clients/node/README.md | 495 | Comprehensive, TypeScript types |
| Go | src/clients/go/README.md | 712 | Comprehensive, idiomatic |
| Java | src/clients/java/README.md | 523 | Comprehensive, async support |
| C | src/clients/c/README.md | ~200 | Basic, may need expansion |

## Alerts Requiring Runbooks

From deploy/helm/archerdb/templates/prometheusrule.yaml:

| Alert | Current URL | Status |
|-------|-------------|--------|
| ArcherDBReplicaDown | https://docs.archerdb.io/runbooks/replica-down | MISSING |
| ArcherDBViewChangeFrequent | https://docs.archerdb.io/runbooks/view-changes | MISSING |
| ArcherDBIndexDegraded | https://docs.archerdb.io/runbooks/index-degraded | MISSING |
| ArcherDBReadLatencyP99Warning | https://docs.archerdb.io/runbooks/high-read-latency | MISSING |
| ArcherDBReadLatencyP99Critical | https://docs.archerdb.io/runbooks/high-read-latency | MISSING |
| ArcherDBWriteLatencyP99Warning | https://docs.archerdb.io/runbooks/high-write-latency | MISSING |
| ArcherDBWriteLatencyP99Critical | https://docs.archerdb.io/runbooks/high-write-latency | MISSING |
| ArcherDBHighLatency | https://docs.archerdb.io/runbooks/high-latency | MISSING |
| ArcherDBDiskSpaceWarning | https://docs.archerdb.io/runbooks/disk-capacity | MISSING |
| ArcherDBDiskSpaceCritical | https://docs.archerdb.io/runbooks/disk-capacity | MISSING |
| ArcherDBCompactionBacklog | https://docs.archerdb.io/runbooks/compaction-backlog | MISSING |
| ArcherDBDiskFillPrediction24h | https://docs.archerdb.io/runbooks/disk-capacity | MISSING |
| ArcherDBDiskFillPrediction6h | https://docs.archerdb.io/runbooks/disk-capacity | MISSING |

**Recommendation:** Create docs/runbooks/ directory with pages for each unique runbook URL (7 pages covering all 13 alerts).

## Sources

### Primary (HIGH confidence)
- Existing ArcherDB documentation in docs/ directory (26 files examined)
- Existing SDK READMEs in src/clients/*/README.md (5 SDKs examined)
- Prometheus alert rules in deploy/helm/archerdb/templates/prometheusrule.yaml
- Phase 10 CONTEXT.md with user decisions

### Secondary (MEDIUM confidence)
- [GitBook Documentation Structure Guide](https://gitbook.com/docs/guides/docs-best-practices/documentation-structure-tips) - Diataxis framework
- [Postman API Documentation Best Practices](https://www.postman.com/api-platform/api-documentation/) - Multi-language examples
- [Auth0 SDK Building Principles](https://auth0.com/blog/guiding-principles-for-building-sdks/) - Language-idiomatic SDKs
- [Hatchet Multi-Language SDK Documentation](https://docs.hatchet.run/blog/automated-documentation) - Automated testing
- [Google Developer Documentation Style Guide](https://google.github.io/styleguide/docguide/best_practices.html) - Writing standards

### Tertiary (LOW confidence)
- General web search results for documentation patterns (used for verification only)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Using existing patterns from codebase
- Architecture: HIGH - Based on verified existing documentation structure
- Pitfalls: HIGH - Identified from actual project state (missing runbooks, inconsistencies)

**Research date:** 2026-01-31
**Valid until:** 2026-03-31 (documentation patterns are stable)
