# Phase 16: Multi-Topology Testing - Research

**Researched:** 2026-02-01
**Domain:** Distributed System Testing, Failover Simulation, Network Partitions, Chaos Engineering
**Confidence:** HIGH

## Summary

This research covers the infrastructure needed to test all 14 ArcherDB operations across 4 cluster topologies (1/3/5/6 nodes) with comprehensive failover and network partition simulation. The codebase has substantial foundations from prior phases:

- **Phase 11 Cluster Harness:** `test_infrastructure/harness/cluster.py` provides `ArcherDBCluster` class supporting 1/3/5/6 node clusters with dynamic port allocation
- **Phase 13 SDK Runners:** `tests/parity_tests/sdk_runners/` provides `run_operation()` interface for all 6 SDKs
- **Phase 14 Fixtures:** `test_infrastructure/fixtures/v1/` contains JSON fixtures for all 14 operations including topology fixtures
- **Phase 15 Orchestrator:** `test_infrastructure/benchmarks/orchestrator.py` shows pattern for running tests across topologies

Key technical decisions from CONTEXT.md are locked:
- Sequential topology execution (1 -> 3 -> 5 -> 6)
- Both SIGTERM (graceful) and SIGKILL (ungraceful) shutdown scenarios
- Full network partition testing with iptables/tc
- Random failure injection timing
- Continue through failures to collect full scope

**Primary recommendation:** Extend the Phase 11 `ArcherDBCluster` class with node lifecycle methods (`stop_node()`, `start_node()`, `kill_node()`) and add a `NetworkPartitioner` class using iptables/tc for partition simulation. Build a `TopologyTestRunner` that orchestrates the full test matrix.

## Standard Stack

### Core Infrastructure

| Tool/Library | Version | Purpose | Why Standard |
|--------------|---------|---------|--------------|
| Python | 3.11+ | Test orchestration | Already used in Phase 11 harness |
| subprocess | stdlib | Process control (SIGTERM/SIGKILL) | Direct signal control for failover |
| iptables | system | Network partition simulation | Linux kernel networking, no external deps |
| tc (iproute2) | system | Traffic control/latency | Standard Linux QoS tool |
| pytest | 8.x | Test framework | Already used in SDK tests |
| requests | 2.31+ | HTTP health checks | Already in test_infrastructure/requirements.txt |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| psutil | 5.9+ | Process monitoring | Verify process states, resource usage |
| python-iptables | 1.0+ | Python iptables interface | Optional: cleaner than subprocess |
| tenacity | 8.2+ | Retry with backoff | Consistency verification retries |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| iptables directly | Toxiproxy | Toxiproxy requires separate server, more complex setup |
| iptables directly | Comcast | Wrapper tool but adds dependency |
| iptables directly | Chaos Mesh | Kubernetes-only, overkill for local testing |
| Manual SIGTERM/SIGKILL | Docker stop | Requires containerization, adds complexity |

**Installation:**
```bash
# Already available on Ubuntu/Debian:
# - iptables (via iptables package)
# - tc (via iproute2 package)

# Optional Python packages
pip install psutil tenacity

# Verify iptables/tc availability
which iptables tc && echo "Network tools available"
```

## Architecture Patterns

### Recommended Project Structure

```
test_infrastructure/
  topology/                      # Phase 16 additions
    __init__.py
    partition.py                 # NetworkPartitioner class
    failover.py                  # FailoverSimulator class
    consistency.py               # ConsistencyChecker class
    runner.py                    # TopologyTestRunner orchestrator

tests/
  topology_tests/                # Phase 16 tests
    __init__.py
    conftest.py                  # Pytest fixtures for topology tests
    test_operations_1node.py     # TOPO-01
    test_operations_3node.py     # TOPO-02
    test_operations_5node.py     # TOPO-03
    test_operations_6node.py     # TOPO-04
    test_leader_failover.py      # TOPO-05
    test_network_partition.py    # TOPO-06
    test_topology_query.py       # TOPO-07
```

### Pattern 1: Extended Cluster Harness

**What:** Add node lifecycle methods to existing ArcherDBCluster
**When to use:** All failover tests

```python
# Source: Extending test_infrastructure/harness/cluster.py
import signal

class ArcherDBCluster:
    # ... existing methods ...

    def stop_node(self, replica: int, graceful: bool = True) -> None:
        """Stop a specific cluster node.

        Args:
            replica: Replica index (0-based)
            graceful: True for SIGTERM, False for SIGKILL
        """
        if replica not in self._processes:
            raise ValueError(f"Replica {replica} not found")

        proc = self._processes[replica]
        if proc.poll() is not None:
            return  # Already stopped

        if graceful:
            proc.terminate()  # SIGTERM
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()  # Escalate to SIGKILL
        else:
            proc.kill()  # SIGKILL immediately
            proc.wait()

    def start_node(self, replica: int) -> None:
        """Restart a previously stopped node.

        Args:
            replica: Replica index to restart
        """
        # Re-spawn process with same config
        # Data file already exists - no format needed
        data_file = self._data_dir / f"replica-{replica}.archerdb"
        addresses = ",".join(str(p) for p in self._ports)

        cmd = [
            str(self._bin_path), "start",
            f"--addresses={addresses}",
            f"--cache-grid={self.config.cache_grid}",
            f"--metrics-port={self._metrics_ports[replica]}",
            "--metrics-bind=127.0.0.1",
            str(data_file),
        ]

        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self._processes[replica] = process
        # ... restart log capture thread ...

    def is_node_running(self, replica: int) -> bool:
        """Check if a specific node is running."""
        if replica not in self._processes:
            return False
        return self._processes[replica].poll() is None

    def get_leader_replica(self) -> Optional[int]:
        """Get the index of the current leader replica."""
        for i in range(self.config.node_count):
            if not self.is_node_running(i):
                continue
            try:
                resp = requests.get(
                    f"http://127.0.0.1:{self._metrics_ports[i]}/metrics",
                    timeout=1,
                )
                if re.search(r'archerdb_region_info\{[^}]*role="primary"[^}]*\}\s+1', resp.text):
                    return i
            except requests.RequestException:
                pass
        return None
```

### Pattern 2: Network Partition Simulator

**What:** Python class wrapping iptables/tc for network partitions
**When to use:** TOPO-06 network partition tests

```python
# Source: Based on Jepsen and Chaos Mesh patterns
import subprocess
from typing import List, Optional, Set

class NetworkPartitioner:
    """Simulate network partitions using iptables.

    WARNING: Requires root/sudo privileges for iptables manipulation.
    On CI, run tests in privileged container or skip partition tests.

    Usage:
        partitioner = NetworkPartitioner(cluster.get_ports())

        # Isolate node 0 from nodes 1,2
        partitioner.partition([0], [1, 2])

        # Heal partition
        partitioner.heal()
    """

    def __init__(self, ports: List[int]) -> None:
        """Initialize with cluster ports.

        Args:
            ports: List of cluster node ports.
        """
        self.ports = ports
        self._active_rules: List[str] = []

    def partition(
        self,
        minority: List[int],
        majority: List[int],
    ) -> None:
        """Create network partition between node groups.

        Blocks all TCP traffic between minority and majority groups
        in both directions.

        Args:
            minority: List of node indices in minority partition
            majority: List of node indices in majority partition
        """
        # Drop packets from minority -> majority
        for m in minority:
            for j in majority:
                self._block_port_pair(self.ports[m], self.ports[j])

        # Drop packets from majority -> minority
        for j in majority:
            for m in minority:
                self._block_port_pair(self.ports[j], self.ports[m])

    def _block_port_pair(self, from_port: int, to_port: int) -> None:
        """Block TCP traffic between two ports."""
        rule = f"-A INPUT -p tcp --sport {from_port} --dport {to_port} -j DROP"
        subprocess.run(
            ["sudo", "iptables", "-A", "INPUT", "-p", "tcp",
             "--sport", str(from_port), "--dport", str(to_port), "-j", "DROP"],
            check=True,
        )
        self._active_rules.append(rule)

    def add_latency(self, node_idx: int, latency_ms: int) -> None:
        """Add network latency to a node's interface.

        Args:
            node_idx: Node index
            latency_ms: Latency to add in milliseconds
        """
        # Note: tc operates on interfaces, requires more setup
        # For local testing, we primarily use partition (iptables DROP)
        pass

    def heal(self) -> None:
        """Remove all partition rules, restoring connectivity."""
        # Flush all rules
        subprocess.run(["sudo", "iptables", "-F", "INPUT"], check=True)
        self._active_rules.clear()

    def __enter__(self) -> "NetworkPartitioner":
        return self

    def __exit__(self, *args) -> None:
        self.heal()
```

### Pattern 3: Failover Simulator

**What:** Orchestrates leader failures and recovery verification
**When to use:** TOPO-05 leader failover tests

```python
# Source: Based on MongoDB and CockroachDB failover patterns
import time
from typing import Callable, Optional
from dataclasses import dataclass

@dataclass
class FailoverResult:
    """Result of a failover operation."""
    old_leader: int
    new_leader: Optional[int]
    recovery_time_ms: float
    data_loss: bool
    operations_during_failover: int
    operations_succeeded: int

class FailoverSimulator:
    """Simulates leader failures and measures recovery.

    Per CONTEXT.md decisions:
    - Both graceful (SIGTERM) and ungraceful (SIGKILL) scenarios
    - Random timing (mid-operation and between operations)
    - Multiple sequential failovers per test
    - Recovery SLA enforcement
    """

    def __init__(
        self,
        cluster: "ArcherDBCluster",
        recovery_timeout_sec: float = 30.0,
    ) -> None:
        """Initialize failover simulator.

        Args:
            cluster: Running cluster to test
            recovery_timeout_sec: Max time to wait for recovery
        """
        self.cluster = cluster
        self.recovery_timeout = recovery_timeout_sec

    def trigger_leader_failure(
        self,
        graceful: bool = True,
    ) -> FailoverResult:
        """Trigger leader node failure and measure recovery.

        Args:
            graceful: True for SIGTERM, False for SIGKILL

        Returns:
            FailoverResult with timing and data integrity info
        """
        # Find current leader
        old_leader = self.cluster.get_leader_replica()
        if old_leader is None:
            raise RuntimeError("No leader found to fail")

        # Record time and stop leader
        start_time = time.time()
        self.cluster.stop_node(old_leader, graceful=graceful)

        # Wait for new leader election
        new_leader = self._wait_for_new_leader(old_leader)
        recovery_time = (time.time() - start_time) * 1000

        return FailoverResult(
            old_leader=old_leader,
            new_leader=new_leader,
            recovery_time_ms=recovery_time,
            data_loss=False,  # Verified separately
            operations_during_failover=0,
            operations_succeeded=0,
        )

    def _wait_for_new_leader(self, old_leader: int) -> Optional[int]:
        """Wait for a new leader different from the old one."""
        deadline = time.time() + self.recovery_timeout
        while time.time() < deadline:
            new_leader = self.cluster.get_leader_replica()
            if new_leader is not None and new_leader != old_leader:
                return new_leader
            time.sleep(0.5)
        return None

    def run_operations_during_failover(
        self,
        operation: Callable[[], bool],
        duration_sec: float = 5.0,
    ) -> tuple[int, int]:
        """Run operations while failover is in progress.

        Args:
            operation: Callable that returns True on success
            duration_sec: How long to run operations

        Returns:
            Tuple of (total_attempted, successful)
        """
        total = 0
        successful = 0
        deadline = time.time() + duration_sec

        while time.time() < deadline:
            total += 1
            try:
                if operation():
                    successful += 1
            except Exception:
                pass  # Expected during failover

        return total, successful
```

### Pattern 4: Consistency Checker

**What:** Verifies data consistency across nodes after topology changes
**When to use:** After every topology change per CONTEXT.md

```python
# Source: Based on Jepsen consistency checking patterns
from typing import Dict, List, Set
import hashlib

class ConsistencyChecker:
    """Verifies data consistency across cluster nodes.

    Per CONTEXT.md: "Full data consistency checks after every topology change"
    - Cluster health (nodes up, leader elected)
    - Operation correctness (re-run operations)
    - Data consistency across all nodes
    """

    def __init__(self, cluster: "ArcherDBCluster") -> None:
        self.cluster = cluster

    def verify_cluster_health(self) -> Dict[str, bool]:
        """Verify all running nodes are healthy and have leader.

        Returns:
            Dict with health status per node
        """
        health = {}
        for i in range(self.cluster.config.node_count):
            if not self.cluster.is_node_running(i):
                health[f"node_{i}"] = False
                continue
            try:
                resp = requests.get(
                    f"http://127.0.0.1:{self.cluster._metrics_ports[i]}/health/ready",
                    timeout=5,
                )
                health[f"node_{i}"] = resp.status_code == 200
            except requests.RequestException:
                health[f"node_{i}"] = False

        # Check leader exists
        health["has_leader"] = self.cluster.get_leader_replica() is not None
        return health

    def verify_data_consistency(
        self,
        entity_ids: List[str],
        retry_attempts: int = 3,
        retry_delay_sec: float = 1.0,
    ) -> Dict[str, bool]:
        """Verify data is consistent across all healthy nodes.

        Per CONTEXT.md: "Retry with backoff before failing - accounts for
        eventual consistency and in-flight replication"

        Args:
            entity_ids: Entity IDs to verify
            retry_attempts: Number of retry attempts
            retry_delay_sec: Delay between retries

        Returns:
            Dict with consistency check results
        """
        from tenacity import retry, stop_after_attempt, wait_fixed

        @retry(
            stop=stop_after_attempt(retry_attempts),
            wait=wait_fixed(retry_delay_sec),
        )
        def check_node_data(node_port: int) -> Set[str]:
            resp = requests.post(
                f"http://127.0.0.1:{node_port}/query/uuid/batch",
                json={"entity_ids": entity_ids},
                timeout=10,
            )
            if resp.status_code != 200:
                raise RuntimeError(f"Query failed: {resp.status_code}")
            return set(e["entity_id"] for e in resp.json().get("events", []))

        results = {}
        reference_data = None

        for i in range(self.cluster.config.node_count):
            if not self.cluster.is_node_running(i):
                continue
            try:
                node_data = check_node_data(self.cluster._ports[i])
                if reference_data is None:
                    reference_data = node_data
                    results[f"node_{i}_consistent"] = True
                else:
                    results[f"node_{i}_consistent"] = node_data == reference_data
            except Exception as e:
                results[f"node_{i}_error"] = str(e)

        return results
```

### Pattern 5: Topology Test Runner

**What:** Orchestrates full topology test suite
**When to use:** CI "topology" tier execution

```python
# Source: Extending test_infrastructure/benchmarks/orchestrator.py pattern
from typing import Dict, List, Any, Optional

class TopologyTestRunner:
    """Runs full test suite across all topologies.

    Per CONTEXT.md:
    - Sequential execution: 1-node -> 3-node -> 5-node -> 6-node
    - Continue through failures to collect full scope
    - Full test suite (14 ops x 6 SDKs) per topology
    """

    TOPOLOGIES = [1, 3, 5, 6]

    def __init__(
        self,
        output_dir: str = "reports/topology",
    ) -> None:
        self.output_dir = output_dir
        self.results: Dict[str, Any] = {}

    def run_topology_suite(
        self,
        topology: int,
        sdks: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """Run full test suite for a single topology.

        Args:
            topology: Number of nodes
            sdks: List of SDK names to test (default: all 6)

        Returns:
            Dict with test results per operation per SDK
        """
        if sdks is None:
            sdks = ["python", "node", "go", "java", "c", "zig"]

        from test_infrastructure.harness import ArcherDBCluster, ClusterConfig

        config = ClusterConfig(node_count=topology)
        results = {"topology": topology, "operations": {}, "errors": []}

        with ArcherDBCluster(config) as cluster:
            cluster.wait_for_ready()
            cluster.wait_for_leader()

            # Run all 14 operations
            operations = [
                "insert", "upsert", "delete",
                "query-uuid", "query-uuid-batch",
                "query-radius", "query-polygon", "query-latest",
                "ping", "status", "topology",
                "ttl-set", "ttl-extend", "ttl-clear",
            ]

            for operation in operations:
                results["operations"][operation] = {}
                for sdk in sdks:
                    try:
                        success = self._run_operation_test(
                            cluster, sdk, operation
                        )
                        results["operations"][operation][sdk] = {
                            "passed": success,
                            "error": None,
                        }
                    except Exception as e:
                        results["operations"][operation][sdk] = {
                            "passed": False,
                            "error": str(e),
                        }
                        results["errors"].append({
                            "sdk": sdk,
                            "operation": operation,
                            "error": str(e),
                        })
                        # Continue through failures per CONTEXT.md

        return results

    def run_full_suite(self) -> Dict[str, Any]:
        """Run complete topology test suite.

        Returns:
            Combined results for all topologies
        """
        all_results = {
            "start_time": datetime.utcnow().isoformat(),
            "topologies": {},
        }

        for topology in self.TOPOLOGIES:
            print(f"\n{'='*60}")
            print(f"Testing {topology}-node topology")
            print(f"{'='*60}")

            try:
                results = self.run_topology_suite(topology)
                all_results["topologies"][str(topology)] = results
            except Exception as e:
                all_results["topologies"][str(topology)] = {
                    "error": str(e),
                    "topology": topology,
                }
                # Continue to next topology

        all_results["end_time"] = datetime.utcnow().isoformat()
        return all_results
```

### Anti-Patterns to Avoid

- **Fixed timeouts for all topologies:** 5-node and 6-node need longer election timeouts than 3-node
- **Single failover per test:** Per CONTEXT.md, test multiple sequential failovers
- **iptables without cleanup:** Always use context manager or finally block to flush rules
- **Root required in CI:** Design tests to skip partition tests when not privileged
- **Ignoring in-flight operations:** Per CONTEXT.md, acknowledged writes must survive leader failure

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Network partitioning | Custom packet filtering | iptables DROP rules | Kernel-level reliability |
| Process signals | os.kill() with manual PID | subprocess.terminate()/kill() | Cross-platform, proper cleanup |
| Retry with backoff | Custom sleep loops | tenacity library | Jitter, exponential backoff built-in |
| Cluster lifecycle | New cluster class | Extend existing ArcherDBCluster | Reuse Phase 11 infrastructure |
| SDK operation execution | Direct API calls | Phase 14 sdk_runners | Already tested, uniform interface |

**Key insight:** This phase is about testing, not building new infrastructure. Extend existing harness and runners.

## Common Pitfalls

### Pitfall 1: Election Timeout Tuning

**What goes wrong:** Leader election fails or takes too long on larger clusters
**Why it happens:** Default timeouts don't account for cluster size
**How to avoid:** Use configurable timeouts per topology:
- 1-node: N/A (no election needed)
- 3-node: 5-10 seconds typical
- 5-node: 10-15 seconds
- 6-node: 15-20 seconds (even number, special handling)
**Warning signs:** "election timeout" errors, tests timing out on leader wait

### Pitfall 2: iptables Rule Accumulation

**What goes wrong:** Network rules persist between tests, breaking subsequent tests
**Why it happens:** Test failures prevent cleanup, rules accumulate
**How to avoid:**
- Always use context manager for NetworkPartitioner
- Add iptables flush to test setup AND teardown
- Run `sudo iptables -F INPUT` before test suite
**Warning signs:** Tests fail randomly, network connectivity issues

### Pitfall 3: Port Reuse After Node Stop

**What goes wrong:** Restarted node can't bind to its port
**Why it happens:** OS hasn't released port from terminated process
**How to avoid:**
- Wait 1-2 seconds after stopping before restarting
- Use SO_REUSEADDR socket option
- Verify port available before restart
**Warning signs:** "Address already in use" errors on node restart

### Pitfall 4: In-Flight Operation Verification

**What goes wrong:** Acknowledged writes lost during failover
**Why it happens:** Not verifying writes persisted before claiming success
**How to avoid:**
- Per CONTEXT.md: "writes that were acknowledged must survive leader failure"
- After failover, query all written entities to verify persistence
- Track correlation IDs for write verification
**Warning signs:** Acknowledged writes missing after failover

### Pitfall 5: Race Between Failover and Operation

**What goes wrong:** Test flaky because failover timing is unpredictable
**Why it happens:** Random timing makes verification difficult
**How to avoid:**
- Use deterministic failover timing for verification tests
- Use random timing only for chaos tests
- Separate "correctness" tests from "resilience" tests
**Warning signs:** Tests pass sometimes, fail others with same code

### Pitfall 6: Even Node Count (6-node) Quorum

**What goes wrong:** 6-node cluster has different quorum dynamics
**Why it happens:** 6 nodes requires 4 for quorum (same as 7), not 3
**How to avoid:**
- Document that 6-node cluster tolerates 2 failures (like 5-node)
- Test partition scenarios specific to 6-node quorum
- Understand that 6-node doesn't improve fault tolerance over 5-node
**Warning signs:** Unexpected leader elections, quorum violations

## Code Examples

### Failover Test Pattern

```python
# Source: Based on existing test patterns + CONTEXT.md decisions
import pytest
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
from test_infrastructure.topology import FailoverSimulator, ConsistencyChecker

@pytest.fixture
def three_node_cluster():
    """3-node cluster fixture for failover tests."""
    config = ClusterConfig(node_count=3)
    cluster = ArcherDBCluster(config)
    cluster.start()
    cluster.wait_for_ready()
    cluster.wait_for_leader()
    yield cluster
    cluster.stop()

def test_graceful_leader_failover(three_node_cluster):
    """TOPO-05: Leader failover with SIGTERM (graceful)."""
    cluster = three_node_cluster
    simulator = FailoverSimulator(cluster, recovery_timeout_sec=15.0)
    checker = ConsistencyChecker(cluster)

    # Insert test data
    leader_port = cluster.wait_for_leader()
    entity_ids = insert_test_data(leader_port, count=100)

    # Trigger graceful leader failure
    result = simulator.trigger_leader_failure(graceful=True)

    # Verify recovery SLA
    assert result.new_leader is not None, "No new leader elected"
    assert result.recovery_time_ms < 15000, f"Recovery too slow: {result.recovery_time_ms}ms"

    # Verify data consistency
    health = checker.verify_cluster_health()
    assert health["has_leader"], "Cluster has no leader after recovery"

    consistency = checker.verify_data_consistency(entity_ids)
    for key, value in consistency.items():
        if key.endswith("_consistent"):
            assert value, f"Data inconsistent on {key}"

def test_ungraceful_leader_failover(three_node_cluster):
    """TOPO-05: Leader failover with SIGKILL (crash)."""
    cluster = three_node_cluster
    simulator = FailoverSimulator(cluster, recovery_timeout_sec=15.0)

    # Insert acknowledged writes
    leader_port = cluster.wait_for_leader()
    entity_ids = insert_test_data(leader_port, count=100)

    # Crash leader (SIGKILL)
    result = simulator.trigger_leader_failure(graceful=False)

    # Verify acknowledged writes survived
    new_leader = cluster.wait_for_leader(timeout=15.0)
    assert new_leader is not None

    queried_ids = query_all_entities(cluster._ports[new_leader])
    for eid in entity_ids:
        assert eid in queried_ids, f"Acknowledged write {eid} lost!"
```

### Network Partition Test Pattern

```python
# Source: Based on Jepsen partition patterns
import pytest
from test_infrastructure.topology import NetworkPartitioner

@pytest.fixture
def partition_capable():
    """Skip if not running with privileges for iptables."""
    import subprocess
    result = subprocess.run(
        ["sudo", "-n", "iptables", "-L"],
        capture_output=True,
    )
    if result.returncode != 0:
        pytest.skip("Requires sudo privileges for network partition tests")

def test_minority_partition(three_node_cluster, partition_capable):
    """TOPO-06: Network partition with minority isolation."""
    cluster = three_node_cluster

    # Insert test data
    entity_ids = insert_test_data(cluster.wait_for_leader(), count=50)

    # Partition node 0 from nodes 1, 2
    with NetworkPartitioner(cluster._ports) as partitioner:
        partitioner.partition(minority=[0], majority=[1, 2])

        # Majority should still function
        majority_leader = wait_for_leader_in_nodes(cluster, [1, 2], timeout=15.0)
        assert majority_leader is not None

        # Writes to majority should succeed
        new_ids = insert_test_data(cluster._ports[majority_leader], count=20)

        # Query should work on majority
        all_ids = query_all_entities(cluster._ports[majority_leader])
        for eid in entity_ids + new_ids:
            assert eid in all_ids

    # After healing, minority should catch up
    time.sleep(5)  # Allow replication

    # Query on previously-isolated node
    all_ids = query_all_entities(cluster._ports[0])
    for eid in new_ids:
        assert eid in all_ids, f"Minority node missing write {eid} after heal"
```

### CI Workflow Pattern

```yaml
# Source: Extending .github/workflows/ci.yml
# Separate "topology" tier per CONTEXT.md

topology-tests:
  needs: test-sdk-python  # Depends on SDK tests passing
  timeout-minutes: 60     # Extended for multi-topology runs
  runs-on: ubuntu-latest
  name: Topology Tests

  steps:
    - uses: actions/checkout@v4
    - name: Download Zig
      run: ./zig/download.sh
    - name: Build ArcherDB
      run: ./zig/zig build -j4

    # Run topology tests WITHOUT partition tests (no sudo)
    - name: Run topology tests (non-privileged)
      env:
        ARCHERDB_INTEGRATION: 1
        SKIP_PARTITION_TESTS: 1
      run: |
        pip install pytest requests tenacity
        pytest tests/topology_tests/ -v --ignore=tests/topology_tests/test_network_partition.py

# Separate job for privileged partition tests (nightly only)
partition-tests:
  if: github.event.schedule  # Only on nightly builds
  timeout-minutes: 30
  runs-on: ubuntu-latest
  container:
    image: ubuntu:22.04
    options: --privileged  # Required for iptables

  steps:
    - uses: actions/checkout@v4
    - name: Install dependencies
      run: |
        apt-get update
        apt-get install -y iptables iproute2 python3 python3-pip
        pip3 install pytest requests tenacity

    - name: Download Zig
      run: ./zig/download.sh
    - name: Build ArcherDB
      run: ./zig/zig build -j4

    - name: Run partition tests (privileged)
      env:
        ARCHERDB_INTEGRATION: 1
      run: pytest tests/topology_tests/test_network_partition.py -v
```

## Recovery SLA Recommendations

Per CONTEXT.md: "Specific SLA target values for recovery times (to be determined based on cluster size)"

Based on research on Raft consensus and production systems:

| Topology | Recovery SLA | Rationale |
|----------|--------------|-----------|
| 1-node | N/A | No failover possible |
| 3-node | < 10 seconds | Minimal quorum (2 nodes), fast election |
| 5-node | < 15 seconds | Larger quorum (3 nodes), more candidates |
| 6-node | < 20 seconds | Same quorum as 7-node (4 nodes) |

**Retry backoff recommendation:**
- Initial delay: 500ms
- Max delay: 5 seconds
- Max attempts: 10
- Jitter: +/- 100ms

```python
from tenacity import retry, stop_after_attempt, wait_exponential, wait_random

@retry(
    stop=stop_after_attempt(10),
    wait=wait_exponential(multiplier=0.5, max=5) + wait_random(0, 0.1),
)
def verify_with_backoff(check_fn):
    if not check_fn():
        raise RuntimeError("Check failed, retrying")
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual SIGKILL | subprocess.terminate() + kill() | Python 3.x | Clean signal handling |
| Custom TCP blocking | iptables DROP | Standard practice | Kernel-level reliability |
| Fixed timeouts | Configurable per topology | This phase | Better test reliability |
| Single failover tests | Sequential failover cycles | Per CONTEXT.md | More thorough testing |
| Skip on failure | Continue and collect | Per CONTEXT.md | Full issue scope |

**Deprecated/outdated:**
- `os.kill()` directly: Use subprocess methods instead for proper cleanup
- `tc netem` for partitions: Use iptables DROP for cleaner partitions
- Shared cluster between tests: Use fresh cluster per test for isolation

## Open Questions

1. **Root Privileges in CI**
   - What we know: iptables requires root/sudo
   - What's unclear: Best approach for GitHub Actions
   - Recommendation: Privileged container for nightly partition tests, skip in PR builds

2. **6-Node Cluster Quorum**
   - What we know: 6-node requires 4 for quorum (same as 7-node)
   - What's unclear: Whether ArcherDB handles even node counts specially
   - Recommendation: Test and document behavior, may need specific handling

3. **Client Failover Timeout**
   - What we know: SDKs should auto-retry on leader failure
   - What's unclear: Exact retry configuration per SDK
   - Recommendation: Verify SDK behavior, may need SDK-specific timeouts

## Sources

### Primary (HIGH confidence)

- `/home/g/archerdb/test_infrastructure/harness/cluster.py` - Existing cluster harness implementation
- `/home/g/archerdb/tests/parity_tests/sdk_runners/` - SDK operation runners
- `/home/g/archerdb/test_infrastructure/fixtures/v1/topology.json` - Existing topology fixtures
- `/home/g/archerdb/test_infrastructure/benchmarks/orchestrator.py` - Topology orchestration pattern

### Secondary (MEDIUM confidence)

- [Jepsen: On the perils of network partitions](https://aphyr.com/posts/281-jepsen-on-the-perils-of-network-partitions) - Network partition testing patterns
- [Toxiproxy](https://github.com/Shopify/toxiproxy) - Network failure simulation concepts
- [MongoDB Replica Set Elections](https://www.mongodb.com/docs/manual/core/replica-set-elections/) - Election timeout recommendations
- [AWS Leader Election Best Practices](https://aws.amazon.com/builders-library/leader-election-in-distributed-systems/) - Production patterns

### Tertiary (LOW confidence)

- [Baeldung: Network Failures Simulation in Linux](https://www.baeldung.com/linux/network-failures-simulation) - iptables/tc usage
- [HashiCorp Consul Consensus](https://developer.hashicorp.com/consul/docs/architecture/consensus) - Raft timeout guidance
- [SIGTERM vs SIGKILL](https://www.suse.com/c/observability-sigkill-vs-sigterm-a-developers-guide-to-process-termination/) - Process termination patterns

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Based on existing Phase 11-15 infrastructure
- Architecture patterns: HIGH - Extends proven harness patterns
- Failover simulation: MEDIUM - Standard patterns but needs validation
- Network partition: MEDIUM - Requires root privileges, CI challenges
- Recovery SLAs: LOW - Based on industry norms, needs tuning for ArcherDB

**Research date:** 2026-02-01
**Valid until:** 2026-03-01 (30 days - stable testing domain)

---

## Requirements Mapping

| Requirement | Implementation Approach |
|-------------|------------------------|
| TOPO-01: Single-node tests | TopologyTestRunner.run_topology_suite(1) |
| TOPO-02: 3-node tests | TopologyTestRunner.run_topology_suite(3) |
| TOPO-03: 5-node tests | TopologyTestRunner.run_topology_suite(5) |
| TOPO-04: 6-node tests | TopologyTestRunner.run_topology_suite(6) |
| TOPO-05: Leader failover | FailoverSimulator with graceful/ungraceful modes |
| TOPO-06: Network partition | NetworkPartitioner with iptables |
| TOPO-07: Topology query | ConsistencyChecker.verify_cluster_health() |
