# Durability Verification Methodology

This document describes how ArcherDB verifies its durability guarantees through comprehensive testing.

## Overview

ArcherDB guarantees that committed transactions survive any single point of failure, including:
- Process crashes (SIGKILL, SIGTERM, OOM)
- Power loss during write operations
- Disk failures (partial writes, bit rot, misdirected I/O)
- Network partitions in clustered deployments

We verify these guarantees through multiple testing approaches:

| Approach | Coverage | Platform | Run Time |
|----------|----------|----------|----------|
| VOPR Simulation | Consensus, WAL, Checkpoints | All | Hours |
| SIGKILL Testing | Process crash recovery | Linux/macOS | Minutes |
| dm-flakey Testing | Power loss, disk failures | Linux only | Minutes |

## VOPR: Viewstamped Replication Simulation

VOPR (Viewstamped Replication Optimizer and Prover) is our primary verification tool. It simulates entire ArcherDB clusters with configurable fault injection.

### What VOPR Tests

1. **Consensus Protocol (VSR)**
   - View changes when primary fails
   - Prepare/commit message handling
   - Quorum formation and maintenance
   - Replica synchronization

2. **WAL (Write-Ahead Log)**
   - Crash during prepare phase
   - Crash during commit phase
   - Partial/torn writes
   - Journal recovery after crash

3. **Checkpoints**
   - Crash during checkpoint write
   - Superblock integrity
   - State recovery from checkpoint

4. **Storage**
   - Read corruption (simulated bit rot)
   - Write corruption (simulated partial writes)
   - Misdirected writes (simulated firmware bugs)
   - Crash faults (simulated torn writes)

### Running VOPR

**Basic verification (3-5 minutes):**
```bash
./scripts/run_vopr.sh --requests-max=200
```

**Extended verification (1-8 hours):**
```bash
./scripts/run_vopr.sh --seeds "$(seq 1 100)" --requests-max=10000 --no-lite
```

**With aggressive crash injection:**
```bash
./scripts/run_vopr.sh --crash-rate=1 --requests-max=1000
```

**Testing specific cluster configurations:**
```bash
# 3-node cluster (default)
./scripts/run_vopr.sh --replicas=3

# 5-node cluster
./scripts/run_vopr.sh --replicas=5
```

### Debugging VOPR Failures

When VOPR finds a failure, use replay mode to debug:

```bash
# Replay with full logging
./scripts/run_vopr.sh --replay <seed>

# Dump decision history on failure
./scripts/run_vopr.sh --dump-on-fail --requests-max=1000 <seed>
```

### VOPR Fault Injection Parameters

The storage simulator supports these fault types:

| Parameter | Description | Default | Recommended for Testing |
|-----------|-------------|---------|------------------------|
| `crash_fault_probability` | Chance of torn write on crash | 0 | 1-5% |
| `write_fault_probability` | Chance of corrupt write | 0 | 0.1-1% |
| `read_fault_probability` | Chance of corrupt read | 0 | 0.1-1% |
| `write_misdirect_probability` | Chance of misdirected write | 0 | 0.05-0.1% |

Use `--crash-rate=N` to set crash fault probability as a percentage.

## SIGKILL Crash Testing

Tests process crash recovery by killing VOPR with SIGKILL during operation.

### What It Tests

1. **Process crash recovery**: ArcherDB must recover correctly after SIGKILL
2. **Deterministic behavior**: Same seed must produce same results after restart
3. **No data corruption**: State machine state must be consistent after recovery

### Running SIGKILL Tests

```bash
# Basic test (3 iterations)
./scripts/sigkill_crash_test.sh

# Extended test
./scripts/sigkill_crash_test.sh --iterations=10 --timeout=60

# With specific seed
./scripts/sigkill_crash_test.sh --seed=12345 --requests-max=500
```

### How It Works

1. Start VOPR with a known seed
2. Wait a random time (1 to `--timeout` seconds)
3. Send SIGKILL to the process
4. Restart VOPR with the same seed
5. Verify deterministic completion (PASSED)

The test passes if VOPR can always complete successfully after being killed
and restarted with the same seed.

## dm-flakey Power-Loss Testing (Linux Only)

Uses Linux device-mapper dm-flakey to simulate real disk failures at the block level.

### What It Tests

1. **Power loss during write**: Data written but not synced
2. **Partial writes**: Only part of a sector written
3. **Drop writes**: Writes acknowledged but not persisted
4. **I/O errors**: Disk returns errors

### Prerequisites

- Linux kernel with device-mapper (dm-flakey target)
- Root privileges
- At least 100MB free disk space

### Running dm-flakey Tests

```bash
# Basic test (requires root)
sudo ./scripts/dm_flakey_test.sh

# Extended test
sudo ./scripts/dm_flakey_test.sh --iterations=10 --size-mb=500
```

### How It Works

1. Create a loop device backed by a file
2. Create dm-flakey device on top of loop device
3. Format and mount dm-flakey device
4. Start ArcherDB on the flakey device
5. Trigger disk failure (drop_writes mode)
6. Wait for failure to propagate
7. Restore disk access
8. Remount and verify ArcherDB recovery

### macOS Alternative

dm-flakey is Linux-only. For macOS, use SIGKILL testing which provides
similar (though less comprehensive) coverage.

## Verification Coverage

### Scenarios Tested

| Scenario | VOPR | SIGKILL | dm-flakey |
|----------|------|---------|-----------|
| Crash during prepare | Yes | Yes | Yes |
| Crash during commit | Yes | Yes | Yes |
| Crash during checkpoint | Yes | No | Yes |
| Crash during compaction | Yes | No | No |
| Multiple simultaneous crashes | Yes | No | No |
| Torn writes | Yes | No | Yes |
| Bit rot (read corruption) | Yes | No | No |
| Misdirected writes | Yes | No | No |
| Network partitions | Yes | No | No |
| View changes | Yes | No | No |
| Replica sync | Yes | No | No |

### Scenarios NOT Tested

These scenarios are out of scope for automated testing:

1. **Full disk**: Currently not simulated
2. **Kernel crash**: Requires VM-based testing
3. **Hardware memory corruption**: ECC testing requires special hardware
4. **Byzantine failures**: VSR assumes crash-fail model, not Byzantine
5. **Multi-datacenter latency**: Real network testing required

## CI Integration

### Pre-merge Verification

Every pull request runs:
```bash
./scripts/run_vopr.sh --seeds "$(git rev-parse HEAD)" --requests-max=200
```

This uses the commit hash as a seed for reproducible failures.

### Nightly Verification

Nightly CI runs extended verification:
```bash
# 8-hour VOPR run with swarm testing
./scripts/run_vopr.sh --no-lite --seeds "$(seq 1 1000)" --requests-max=100000
```

### Release Verification

Before each release:
1. 24-hour VOPR run with multiple seeds
2. All cluster configurations (3, 5, 6 replicas)
3. SIGKILL testing on Linux and macOS
4. dm-flakey testing on Linux

## Reproducing Failures

### From CI Failure

1. Note the seed from CI output (commit hash or explicit seed)
2. Run locally with the same seed:
   ```bash
   ./scripts/run_vopr.sh --replay <seed>
   ```

### From Production Issue

1. Collect the data directory
2. Note the replica count and configuration
3. Run VOPR with similar parameters
4. Use `--dump-on-fail` to capture decision history

## Extending Coverage

### Adding New Fault Types

1. Add fault probability to `src/testing/storage.zig:Options`
2. Implement fault injection in appropriate `step()` functions
3. Add CLI flag in `src/vopr.zig`
4. Update `scripts/run_vopr.sh`
5. Document in this file

### Adding New Test Scenarios

1. Identify the scenario
2. Determine which tool(s) can test it
3. Implement (extend VOPR or create new script)
4. Add to CI pipeline
5. Document coverage

## References

- [VOPR Source](https://github.com/ArcherDB-io/archerdb/blob/main/src/vopr.zig): Main VOPR implementation
- [Storage Simulation](https://github.com/ArcherDB-io/archerdb/blob/main/src/testing/storage.zig): Fault injection
- [Cluster Simulation](https://github.com/ArcherDB-io/archerdb/blob/main/src/testing/cluster.zig): Multi-replica testing
- [VSR Protocol](https://github.com/ArcherDB-io/archerdb/blob/main/src/vsr/replica.zig): Consensus implementation
