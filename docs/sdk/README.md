# SDK Overview

ArcherDB ships five client SDKs over a shared geospatial operation surface:

| SDK | Package | Primary Docs |
|-----|---------|--------------|
| Python | `archerdb` | [Python README](/home/g/archerdb/src/clients/python/README.md) |
| Node.js | `archerdb-node` | [Node.js README](/home/g/archerdb/src/clients/node/README.md) |
| Go | `github.com/archerdb/archerdb-go` | [Go README](/home/g/archerdb/src/clients/go/README.md) |
| Java | `com.archerdb:archerdb-java` | [Java README](/home/g/archerdb/src/clients/java/README.md) |
| C | `archerdb-c` | [C README](/home/g/archerdb/src/clients/c/README.md) |

## Shared Capability Surface

The repo's parity runner validates the same 14-operation surface across all five SDKs:

- insert
- upsert
- delete
- query-uuid
- query-uuid-batch
- query-radius
- query-polygon
- query-latest
- ping
- status
- topology
- ttl-set
- ttl-extend
- ttl-clear

See [Parity Matrix](../PARITY.md) for the current checked-in evidence summary.

## Choosing An SDK

- Use Python for scripting, analysis, and operational tooling.
- Use Node.js for web backends and TypeScript-heavy applications.
- Use Go for single-binary services and low-overhead deployments.
- Use Java for JVM services and enterprise application stacks.
- Use C when you need the lowest-level interface and manual control over callbacks, buffers, and threading.

## Source Of Truth

The language-specific READMEs under [`src/clients/`](/home/g/archerdb/src/clients) remain the primary API and usage references. This directory provides the aggregate index and parity-oriented comparison material the top-level docs link to.
