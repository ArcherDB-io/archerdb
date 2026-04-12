# ArcherDB SDK Verification Report

**Date:** April 9, 2026
**Commit:** `7b8908e0`
**Status:** Current commit parity is green across all five SDKs

## Executive Summary

This report replaces the stale January 31, 2026 SDK report.

The authoritative current SDK evidence is now the checked-in parity suite:

- [docs/PARITY.md](/home/g/archerdb/docs/PARITY.md)
- [reports/parity.json](/home/g/archerdb/reports/parity.json)

Current result:

- `79/79 passed, 0 failed`
- base parity target: `70 cells (14 operations x 5 SDKs)`
- additional topology and failover topology cases also passed on the current commit

## SDK Status

| SDK | Current Status | Evidence |
|-----|----------------|----------|
| Python | PASS | parity green; focused filter cases rerun live |
| Node.js | PASS | parity green; focused filter cases rerun live |
| Go | PASS | parity green on refreshed current-source native artifacts |
| Java | PASS | parity green on refreshed current-source artifacts and fixed topology parsing |
| C | PASS | parity green with real topology response decoding |

## What Changed Since The Old Report

- Go and Java are no longer in a blanket failure state.
- The old report was based on a stale sample-driven pass from January 31, 2026.
- The current source tree has:
  - refreshed packaged SDK artifacts before parity
  - fixed topology parsing in Java and C parity paths
  - removed stale test skips in Python and Node
  - relabeled skeleton-mode unit tests honestly so they are not mistaken for release evidence

## Current Verification Sources

### Cross-SDK Parity

- full parity sweep:
  - `python3 -u tests/parity_tests/parity_runner.py --start-cluster --cluster-port 4000 --cluster-nodes 1 -v --output reports/parity.json --markdown docs/PARITY.md`
  - result: `79/79 passed, 0 failed`

### Focused Live SDK Checks

- Python:
  - previously skipped filter paths now rerun live and green
- Node:
  - `cd tests/sdk_tests/node && npx tsc --noEmit`
  - targeted Jest rerun for group/timestamp cases passed on a live node

### Topology Verification

- topology cases passed across Python, Node, Go, Java, and C for:
  - steady-state topology
  - leader failover topology
  - unhealthy-node topology

## Interpretation

For the current GA SDK surface, the checked-in repo evidence no longer supports the older
“Python/Node good, Go/Java broken” conclusion. The current truthful statement is:

- all five SDKs pass the current parity suite
- the parity artifacts in this repo are current as of April 9, 2026
- remaining non-GA surfaces are documented as non-GA instead of being counted as SDK failures

## Remaining Release-Evidence Work

The remaining SDK-adjacent release work is not functional parity failure. It is release proofing:

- credentialed package-publish rehearsal for Java Central using the post-publish checksum verifier
- broader release bundle refresh alongside current benchmark artifacts
