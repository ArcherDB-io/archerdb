# Phase 5: Sharding & Cleanup - Context

**Gathered:** 2026-01-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Verify sharding works correctly and resolve all technical debt. This includes:
- Consistent hashing verification across all SDK implementations
- Cross-shard query fan-out and aggregation
- Resolution of all 181 TODO/FIXME comments
- Implementation of all stubs (REPL, tiering, TLS CRL/OCSP, CDC AMQP, CSV import, backup config, state machine tests)
- Removal of deprecated --aof flag

</domain>

<decisions>
## Implementation Decisions

### TODO Resolution Strategy
- **All TODOs resolved in this phase** — no conversion to GitHub issues, fix everything now
- **FIXMEs first** — treat as bugs, address before regular TODOs
- **Documentation TODOs deferred** — to Phase 9 (Documentation)
- **Optimization TODOs resolved here** — not deferred to Phase 10
- **SDK TODOs resolved here** — not deferred to Phase 6
- **Future feature TODOs** — case-by-case, Claude decides based on correctness/stability impact
- **External dependencies** — implement all integrations, even if adding dependencies
- **Low-priority TODOs** — all resolved regardless of stated priority
- **Architectural decisions** — Claude decides using best judgment
- **Duplicate TODOs** — fix each instance individually (context may differ)
- **Decision TODOs ("X or Y?")** — pick the more performant option
- **Error handling TODOs** — match context: critical path fails fast, background tasks handle gracefully

### Stub Implementation

#### REPL
- Full interactive REPL with history, tab completion, multi-line input
- Both admin commands (cluster status, replication lag, metrics, config inspection) and debug commands (inspect internals, dump state, trace queries)

#### tiering.zig
- Full automatic hot/cold tiering implementation
- Configurable policies: access frequency, age-based, or both
- User-defined thresholds for tier movement

#### TLS CRL/OCSP
- Full support: both CRL download and OCSP stapling
- Configurable timeout for revocation checks
- Configurable fail policy: operator chooses fail-closed (secure) or fail-open (available) per environment

#### CDC AMQP
- Full AMQP 0.9.1 client implementation, RabbitMQ-compatible
- Configurable message format: JSON or Protobuf per CDC stream

#### CSV Import
- CLI tool only, not built into server
- External tool that connects to ArcherDB for bulk loading

#### backup_config.zig
- Full configuration: scheduled backups, retention policies, multiple destinations
- Scheduling supports both cron syntax and simple intervals (every: 1h)
- Destinations: local filesystem and S3-compatible storage

#### state_machine_tests
- Integrate with existing VOPR fuzzer rather than standalone tests
- Extend VOPR to cover state machine edge cases

### Cross-shard Query Behavior
- **Partial results** — configurable per query: client specifies `partial_results: true/false`
- **Aggregation** — client-side merge: return per-shard results, client combines (more transparent)
- **Default timeout** — 5 seconds (fast fail for responsive UX)
- **Fan-out execution** — parallel all relevant shards simultaneously

### Sharding Verification
- **Hash algorithm** — verify existing implementation (don't change algorithm)
- **Distribution tolerance** — ±5% variance (strict: each shard within 5% of ideal)
- **Cross-SDK verification** — both golden vectors (regression) and round-trip tests (parity)
- **Resharding guarantees** — minimal movement (consistent hashing) AND post-reshard balance verification

### Claude's Discretion
- Implementation details for each stub
- VOPR extension scope for state machine coverage
- Golden vector selection for sharding tests
- Error message wording and log formatting

</decisions>

<specifics>
## Specific Ideas

- All TODOs resolved in this session — no deferral to tracking issues
- Performance over simplicity when resolving decision TODOs
- Client-side aggregation for transparency — SDKs will need merge logic
- 5-second default timeout is aggressive but prioritizes UX

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 05-sharding-cleanup*
*Context gathered: 2026-01-22*
