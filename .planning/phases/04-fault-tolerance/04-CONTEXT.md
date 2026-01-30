# Phase 4: Fault Tolerance - Context

**Gathered:** 2026-01-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Test system resilience to hardware and network failures without data loss. Verify that ArcherDB survives process crashes, disk errors, resource exhaustion, and network issues, with graceful recovery and clear error reporting. Recovery and operations tooling are separate phases.

</domain>

<decisions>
## Implementation Decisions

### Recovery behavior
- **In-progress requests during crash:** Clients get explicit errors immediately - connections fail and clients must retry
- **Recovery time target:** Under 60 seconds for replica to rejoin cluster after crash
- **Corrupted data handling:** Fail startup with clear error - require operator intervention rather than risk serving bad data
- **Recovery logging:** Claude's discretion - balance operator visibility with log noise

### Failure detection
- **Disk error retry strategy:** Claude's discretion - implement standard disk error handling patterns (likely retry transient errors, fail on hardware errors)
- **Health endpoint behavior:** Claude's discretion - follow Kubernetes health probe best practices (likely distinguish severity levels)
- **Network timeout handling:** Fast failure with automatic leader re-election - assume leader is dead, elect new one quickly
- **Error message detail:** Detailed technical errors - include errno codes, file paths, operation details for debugging

### Resource exhaustion handling
- **Full disk behavior:** Reject writes with clear error, stay available for reads - graceful degradation to read-only mode
- **Disk warning threshold:** 80% full - early warning for operators
- **Connection limit handling:** Claude's discretion - implement standard connection limiting (likely reject or brief queue)
- **Memory pressure response:** Trigger emergency garbage collection - attempt to free memory before rejecting requests

### Test infrastructure approach
- **Crash testing method:** Both SIGKILL (realism) and fault injection API (reproducibility)
- **Disk error injection:** Claude's discretion - use existing TigerBeetle storage fault injection patterns
- **Network fault injection:** Add dedicated network fault injection - more control for jitter, partial drops, latency spikes
- **Test organization:** Both approaches - core tests integrated into existing suite, extended chaos tests in separate files

</decisions>

<specifics>
## Specific Ideas

- Network latency spikes should trigger fast leader re-election rather than waiting - bias toward availability
- Disk warnings at 80% provide ample operator reaction time before critical state
- Error messages should expose technical details for debugging - operators need errno codes and paths
- Tests should use both realistic (SIGKILL) and deterministic (fault injection) approaches for coverage

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 04-fault-tolerance*
*Context gathered: 2026-01-29*
