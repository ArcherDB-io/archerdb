# Phase 1: Platform Foundation - Context

**Gathered:** 2026-01-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Platform cleanup: Remove Windows support completely, fix Darwin/macOS issues (fsync, test assertions), and complete message bus error handling. This phase establishes clean platform support for Linux and macOS only.

</domain>

<decisions>
## Implementation Decisions

### Error Classification
- Connection timeouts: Configurable retry behavior via config/flags, not hardcoded
- Protocol violations (malformed messages, version mismatches): Always fatal — terminate connection immediately
- Peer eviction: Log at WARN level, emit metric, and emit cluster event that operators can hook into
- Resource exhaustion: Reject new work (stop accepting connections/requests) until resources free up, keep existing work running

### Fallback Behavior
- Darwin fsync: Fail startup if F_FULLFSYNC unavailable — durability is non-negotiable, no fallback to regular fsync
- Platform requirement errors: Actionable messages with specific minimum requirements and what to do (e.g., "Requires macOS 10.14+, you have 10.13")
- io_uring: Required on Linux, no fallback to epoll — keeps code simpler, minimum kernel version requirement
- Capability detection: Startup only — detect once at startup, cache results, fail early if requirements not met
- Degraded performance paths: Log once at startup AND expose as metric for dashboards
- Platform requirements: Document in separate REQUIREMENTS.md AND expose via `--version` or `--check-platform` command

### Windows Removal
- Code removal: Complete removal — delete all Windows code, remove all `@import("windows")` and `if (builtin.os.tag == .windows)` conditionals
- Build and CI: Remove all Windows build targets from build.zig, remove all Windows CI jobs
- Documentation: Remove silently — no explanation or "not supported" notes needed
- Test fixtures: Delete all Windows-specific test files, fixtures, or test paths
- Cross-platform abstractions: Remove abstractions that only existed for Windows compat, use POSIX directly
- Error message audit: Full audit — search all error messages for Windows references and update them
- Third-party dependencies: Leave as-is — don't modify external dependencies

### Claude's Discretion
- macOS x86_64 test assertion fix approach (build.zig:811)
- Exit code conventions for platform check failures
- Git commit granularity for Windows removal (one commit vs atomic commits)

</decisions>

<specifics>
## Specific Ideas

- "Durability is non-negotiable" — fail startup rather than fall back to weaker guarantees
- Error messages should be actionable, not just informative
- Resource pressure should reject new work but not kill existing work
- Cluster events for peer eviction enable operator automation

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-platform-foundation*
*Context gathered: 2026-01-22*
