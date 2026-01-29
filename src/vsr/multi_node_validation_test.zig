// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// Multi-Node Validation Tests - Reference Documentation
//
// The actual test implementations are in replica_test.zig, which contains
// the TestContext infrastructure required for cluster simulation.
//
// =============================================================================
// Phase 02: Multi-Node Validation Test Coverage
// =============================================================================
//
// MULTI-04: Quorum voting requires f+1 votes (2/3 for 3-node cluster)
//   Location: src/vsr/replica_test.zig
//   Run: ./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "MULTI-04"
//   Validates: 3-node cluster requires 2/3 majority to commit; minority cannot progress
//
// MULTI-05: Network partition prevents split-brain
//   Location: src/vsr/replica_test.zig
//   Run: ./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "MULTI-05"
//   Validates: Partitioned minority cannot commit independently, ensuring no data divergence
//
// MULTI-06: Cluster tolerates f=1 failure in 3-node configuration
//   Location: src/vsr/replica_test.zig
//   Run: ./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "MULTI-06"
//   Validates: Cluster continues with 2/3 nodes; crashed node catches up on recovery
//
// =============================================================================
// Run All MULTI Tests
// =============================================================================
//
//   ./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "MULTI-0"
//
// =============================================================================
// Test Infrastructure
// =============================================================================
//
// The tests use the Cluster simulation framework from src/testing/:
// - TestContext: Main test harness wrapping simulated cluster
// - TestReplicas: Helper for replica operations (stop, open, drop_all, pass_all)
// - TestClients: Helper for client request/reply verification
// - ProcessSelector: Role-based replica selection (.A0=primary, .B1/.B2=backups)
// - Network partition injection: drop_all() / pass_all() for symmetric/asymmetric partitions
//
// See replica_test.zig for 50+ examples of cluster testing patterns.
//
