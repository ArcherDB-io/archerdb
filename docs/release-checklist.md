# Release Checklist

Use this checklist before calling ArcherDB released for the current GA surface.

This checklist is intentionally separate from Maven Central publication of `archerdb-java`.
Java Central distribution is a packaging step that should happen only after the release candidate
itself is already a clear `GO`. See the [Java Publish Checklist](java-publish-checklist.md) for
that separate step.

## Must-Do Before Release

All of the following must be true before ArcherDB is called released:

- choose the exact release commit explicitly
- ensure the worktree is clean for that release commit
- ensure GitHub Actions are green on that exact commit:
  - `CI`
  - `SDK Smoke Tests`
  - `Performance Benchmarks`
- refresh release evidence for the exact release commit, not an older nearby commit:
  - regenerate `reports/parity.json`
  - regenerate [docs/PARITY.md](/home/g/archerdb/docs/PARITY.md)
  - verify the checked-in benchmark artifact set still matches the chosen release commit
  - update [integration-check-report.md](/home/g/archerdb/integration-check-report.md) so its date and commit match the release candidate
- confirm the current GA boundary is still truthful in code and docs:
  - `cluster` is status-only
  - `upgrade` is status plus dry-run planning only
  - offline `shard reshard` remains planning-only and fail-closed without `--dry-run`
  - non-GA areas remain documented as non-GA rather than being implied as shipping features
- confirm there are no repo-local correctness blockers left in [FINALIZATION_PLAN.md](/home/g/archerdb/FINALIZATION_PLAN.md) beyond external release-evidence tasks
- confirm release-facing docs and announcement material do not imply package distribution that has not happened yet

## Current Non-GA Boundaries

These are intentionally outside the current GA release surface and should stay described that way:

- dynamic cluster membership
- live upgrade actuation beyond status and dry-run planning
- server-side multi-region runtime
- in-process CRL/OCSP revocation enforcement
- Java `NEAREST` latency-aware multi-region routing

## Separate From Release Go/No-Go

The following is not part of the core ArcherDB release go/no-go decision:

- publishing `archerdb-java` to Maven Central

That step should remain separate because it is a public distribution action, not a runtime
correctness gate. If Java Central publication is deferred, the release decision can still be `GO`
provided that release notes and docs do not claim the package is already available there.

## Decision Rule

- `GO` means the exact release commit is selected, green, evidence is refreshed to that commit, and the current GA boundary is still truthful.
- `NO-GO` means any of those items are still open.

## Current State On Main

As of April 15, 2026, these items are already satisfied on `main`:

- the latest `origin/main` commit is green for `CI`, `SDK Smoke Tests`, and `Performance Benchmarks`
- the current GA CLI boundary is truthful in the built binary
- the intentional non-GA boundaries are documented as non-GA
- release-facing docs no longer imply Maven Central distribution before it actually happens

These items are still open before calling ArcherDB released:

- choose and freeze the exact release commit
- refresh parity and integration evidence so it points at that exact release commit
