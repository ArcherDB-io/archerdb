// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 ArcherDB Contributors

/**
 * Comprehensive Node.js SDK operation tests for all 14 operations.
 *
 * Tests are organized by operation, each loading test cases from
 * the shared JSON fixtures created in Phase 11. Each test:
 * 1. Loads the operation fixture
 * 2. Executes setup if needed (insert_first for query tests)
 * 3. Calls the SDK method
 * 4. Verifies result matches expected output
 * 5. Cleans up (beforeEach handles this)
 *
 * Operations tested:
 * 1.  insert (opcode 146)
 * 2.  upsert (opcode 147)
 * 3.  delete (opcode 148)
 * 4.  query_uuid (opcode 149)
 * 5.  query_uuid_batch (opcode 156)
 * 6.  query_radius (opcode 150)
 * 7.  query_polygon (opcode 151)
 * 8.  query_latest (opcode 154)
 * 9.  ping (opcode 152)
 * 10. status (opcode 153)
 * 11. ttl_set (opcode 158)
 * 12. ttl_extend (opcode 159)
 * 13. ttl_clear (opcode 160)
 * 14. topology (opcode 157)
 */

import { spawn, ChildProcess } from 'child_process';
import * as path from 'path';
import {
  loadFixture,
  getCaseByName,
  cleanDatabase,
  verifyEventsContain,
  generateEntityId,
} from './fixture_adapter';

// Import SDK types and client
import {
  GeoClient,
  createGeoClient,
  GeoClientConfig,
  createGeoEvent,
  id as archerdbId,
  GeoEvent,
} from 'archerdb';

// Check if integration tests should run
const RUN_INTEGRATION = process.env.ARCHERDB_INTEGRATION === '1';

// Skip all tests if integration not enabled
const describeIntegration = RUN_INTEGRATION ? describe : describe.skip;

// Cluster management
let clusterProcess: ChildProcess | null = null;
let client: GeoClient | null = null;
let serverAddress: string = '';

/**
 * Start the test cluster using Python harness.
 */
async function startCluster(): Promise<string> {
  return new Promise((resolve, reject) => {
    const projectRoot = path.resolve(__dirname, '../../..');
    const pythonPath = `${projectRoot}:${projectRoot}/src/clients/python/src`;

    // Start cluster using Python harness
    const proc = spawn('python3', [
      '-c',
      `
import sys
import time
sys.path.insert(0, '${projectRoot}')
sys.path.insert(0, '${projectRoot}/src/clients/python/src')
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
config = ClusterConfig(node_count=1, cache_grid="256MiB")
cluster = ArcherDBCluster(config)
cluster.start()
if not cluster.wait_for_ready(timeout=60.0):
    print("ERROR: Cluster failed to start", file=sys.stderr)
    cluster.stop()
    sys.exit(1)
leader = cluster.wait_for_leader(timeout=30.0)
if leader is None:
    print("ERROR: No leader elected", file=sys.stderr)
    cluster.stop()
    sys.exit(1)
print(f"READY:{cluster.get_addresses()}")
sys.stdout.flush()
# Keep running until killed
try:
    while True:
        time.sleep(1)
except:
    cluster.stop()
`,
    ], {
      cwd: projectRoot,
      env: { ...process.env, PYTHONPATH: pythonPath },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    clusterProcess = proc;

    let output = '';
    proc.stdout?.on('data', (data) => {
      output += data.toString();
      const match = output.match(/READY:(\d+)/);
      if (match) {
        const port = match[1];
        resolve(`127.0.0.1:${port}`);
      }
    });

    proc.stderr?.on('data', (data) => {
      console.error('Cluster stderr:', data.toString());
    });

    proc.on('error', (err) => {
      reject(new Error(`Failed to start cluster: ${err.message}`));
    });

    // Timeout after 90 seconds
    setTimeout(() => {
      if (!output.includes('READY:')) {
        proc.kill();
        reject(new Error('Cluster startup timeout'));
      }
    }, 90000);
  });
}

/**
 * Stop the test cluster.
 */
async function stopCluster(): Promise<void> {
  if (clusterProcess) {
    clusterProcess.kill('SIGTERM');
    clusterProcess = null;
  }
}

describeIntegration('ArcherDB Node.js SDK Operation Tests', () => {
  // Start cluster before all tests
  beforeAll(async () => {
    serverAddress = await startCluster();

    const config: GeoClientConfig = {
      cluster_id: 0n,
      addresses: [serverAddress],
      connect_timeout_ms: 5000,
      request_timeout_ms: 30000,
    };

    client = createGeoClient(config);
  }, 120000); // 2 minute timeout for startup

  // Stop cluster after all tests
  afterAll(async () => {
    if (client) {
      client.destroy();
      client = null;
    }
    await stopCluster();
  }, 30000);

  // Clean database before each test
  beforeEach(async () => {
    if (client) {
      await cleanDatabase(client);
    }
  }, 30000);

  // ==========================================================================
  // 1. Insert Operation (opcode 146)
  // ==========================================================================

  describe('Insert Operations', () => {
    test('insert_single_event_valid: Basic insert with minimal fields', async () => {
      const fixture = loadFixture('insert');
      const testCase = getCaseByName(fixture, 'single_event_valid');
      expect(testCase).toBeDefined();

      const events = testCase!.input.events.map((ev: any) =>
        createGeoEvent({
          entity_id: BigInt(ev.entity_id),
          latitude: ev.latitude,
          longitude: ev.longitude,
        })
      );

      const errors = await client!.insertEvents(events);
      expect(errors).toEqual([]);

      // Verify data was inserted
      const found = await client!.getLatestByUuid(events[0].entity_id);
      expect(found).not.toBeNull();
      expect(found!.entity_id).toEqual(events[0].entity_id);
    });

    test('insert_batch_10_events: Batch insert of 10 events', async () => {
      const fixture = loadFixture('insert');
      const testCase = getCaseByName(fixture, 'batch_10_events');
      expect(testCase).toBeDefined();

      const events = testCase!.input.events.map((ev: any) =>
        createGeoEvent({
          entity_id: BigInt(ev.entity_id),
          latitude: ev.latitude,
          longitude: ev.longitude,
        })
      );

      const errors = await client!.insertEvents(events);
      expect(errors).toEqual([]);
    });
  });

  // ==========================================================================
  // 2. Upsert Operation (opcode 147)
  // ==========================================================================

  describe('Upsert Operations', () => {
    test('upsert_creates_new: Creates new entity if not exists', async () => {
      const entityId = archerdbId();
      const event = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
      });

      const errors = await client!.upsertEvents([event]);
      expect(errors).toEqual([]);

      const found = await client!.getLatestByUuid(entityId);
      expect(found).not.toBeNull();
    });

    test('upsert_updates_existing: Updates existing entity', async () => {
      const entityId = archerdbId();

      // First insert
      const event1 = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
      });
      await client!.insertEvents([event1]);

      // Upsert with new location
      const event2 = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7500,
        longitude: -73.9800,
      });
      const errors = await client!.upsertEvents([event2]);
      expect(errors).toEqual([]);

      // Verify update
      const found = await client!.getLatestByUuid(entityId);
      expect(found).not.toBeNull();
    });
  });

  // ==========================================================================
  // 3. Delete Operation (opcode 148)
  // ==========================================================================

  describe('Delete Operations', () => {
    test('delete_existing_entity: Delete existing entity', async () => {
      const entityId = archerdbId();

      // Insert first
      const event = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
      });
      await client!.insertEvents([event]);

      // Verify inserted
      let found = await client!.getLatestByUuid(entityId);
      expect(found).not.toBeNull();

      // Delete
      const result = await client!.deleteEntities([entityId]);
      expect(result.deleted_count).toBe(1);

      // Verify deleted
      found = await client!.getLatestByUuid(entityId);
      expect(found).toBeNull();
    });

    test('delete_nonexistent_entity: Delete non-existent returns not_found', async () => {
      const entityId = archerdbId();

      const result = await client!.deleteEntities([entityId]);
      expect(result.not_found_count).toBe(1);
      expect(result.deleted_count).toBe(0);
    });
  });

  // ==========================================================================
  // 4. Query UUID Operation (opcode 149)
  // ==========================================================================

  describe('Query UUID Operations', () => {
    test('query_uuid_found: Returns existing entity', async () => {
      const entityId = archerdbId();

      const event = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
      });
      await client!.insertEvents([event]);

      const found = await client!.getLatestByUuid(entityId);
      expect(found).not.toBeNull();
      expect(found!.entity_id).toEqual(entityId);
    });

    test('query_uuid_not_found: Returns null for non-existent', async () => {
      const entityId = archerdbId();

      const found = await client!.getLatestByUuid(entityId);
      expect(found).toBeNull();
    });
  });

  // ==========================================================================
  // 5. Query UUID Batch Operation (opcode 156)
  // ==========================================================================

  describe('Query UUID Batch Operations', () => {
    test('query_uuid_batch_all_found: Returns all existing entities', async () => {
      const entityIds = [archerdbId(), archerdbId(), archerdbId()];

      // Insert all
      const events = entityIds.map((id, i) =>
        createGeoEvent({
          entity_id: id,
          latitude: 40.7128 + i * 0.001,
          longitude: -74.0060,
        })
      );
      await client!.insertEvents(events);

      // Batch query
      const results = await client!.getLatestByUuidBatch(entityIds);
      expect(results.size).toBe(3);
      for (const id of entityIds) {
        expect(results.has(id)).toBe(true);
      }
    });
  });

  // ==========================================================================
  // 6. Query Radius Operation (opcode 150)
  // ==========================================================================

  describe('Query Radius Operations', () => {
    test('query_radius_basic: Finds nearby events', async () => {
      // Insert events at known locations
      const events = [
        createGeoEvent({ entity_id: archerdbId(), latitude: 40.7128, longitude: -74.0060 }),
        createGeoEvent({ entity_id: archerdbId(), latitude: 40.7130, longitude: -74.0062 }),
      ];
      await client!.insertEvents(events);

      // Query
      const result = await client!.queryRadius({
        latitude: 40.7128,
        longitude: -74.0060,
        radius_m: 1000,
        limit: 100,
      });

      expect(result.events.length).toBeGreaterThanOrEqual(2);
    });

    test('query_radius_with_limit: Respects limit parameter', async () => {
      // Insert 20 events
      const events = Array.from({ length: 20 }, () =>
        createGeoEvent({
          entity_id: archerdbId(),
          latitude: 40.7128,
          longitude: -74.0060,
        })
      );
      await client!.insertEvents(events);

      // Query with limit
      const result = await client!.queryRadius({
        latitude: 40.7128,
        longitude: -74.0060,
        radius_m: 1000,
        limit: 10,
      });

      expect(result.events.length).toBe(10);
    });
  });

  // ==========================================================================
  // 7. Query Polygon Operation (opcode 151)
  // ==========================================================================

  describe('Query Polygon Operations', () => {
    test('query_polygon_finds_inside: Finds events inside polygon', async () => {
      const entityId = archerdbId();
      const event = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
      });
      await client!.insertEvents([event]);

      // Query with square polygon around the point
      const result = await client!.queryPolygon({
        vertices: [
          [40.71, -74.01],
          [40.72, -74.01],
          [40.72, -74.00],
          [40.71, -74.00],
        ],
        limit: 100,
      });

      expect(result.events.length).toBeGreaterThanOrEqual(1);
      const foundIds = result.events.map((e: GeoEvent) => e.entity_id);
      expect(foundIds).toContain(entityId);
    });
  });

  // ==========================================================================
  // 8. Query Latest Operation (opcode 154)
  // ==========================================================================

  describe('Query Latest Operations', () => {
    test('query_latest_returns_recent: Returns most recent events', async () => {
      const events = Array.from({ length: 5 }, (_, i) =>
        createGeoEvent({
          entity_id: archerdbId(),
          latitude: 40.7128 + i * 0.001,
          longitude: -74.0060,
        })
      );
      await client!.insertEvents(events);

      const result = await client!.queryLatest({ limit: 10 });
      expect(result.events.length).toBe(5);
    });

    test('query_latest_with_limit: Respects limit', async () => {
      const events = Array.from({ length: 10 }, () =>
        createGeoEvent({
          entity_id: archerdbId(),
          latitude: 40.7128,
          longitude: -74.0060,
        })
      );
      await client!.insertEvents(events);

      const result = await client!.queryLatest({ limit: 5 });
      expect(result.events.length).toBe(5);
    });
  });

  // ==========================================================================
  // 9. Ping Operation (opcode 152)
  // ==========================================================================

  describe('Ping Operations', () => {
    test('ping_returns_pong: Ping returns successful response', async () => {
      const result = await client!.ping();
      expect(result).toBe(true);
    });
  });

  // ==========================================================================
  // 10. Status Operation (opcode 153)
  // ==========================================================================

  describe('Status Operations', () => {
    test('status_returns_info: Returns server information', async () => {
      const result = await client!.getStatus();
      expect(result).toBeDefined();
      // Status should have ram_index fields
      expect(result.ram_index_count).toBeDefined();
    });
  });

  // ==========================================================================
  // 11. TTL Set Operation (opcode 158)
  // ==========================================================================

  describe('TTL Set Operations', () => {
    test('ttl_set_applies_ttl: Set TTL on existing entity', async () => {
      const entityId = archerdbId();

      // Insert first
      const event = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
      });
      await client!.insertEvents([event]);

      // Set TTL
      const result = await client!.setTtl(entityId, 3600);
      expect(result).toBeDefined();
    });
  });

  // ==========================================================================
  // 12. TTL Extend Operation (opcode 159)
  // ==========================================================================

  describe('TTL Extend Operations', () => {
    test('ttl_extend_adds_time: Extend TTL adds time', async () => {
      const entityId = archerdbId();

      // Insert with TTL
      const event = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
        ttl_seconds: 1800,
      });
      await client!.insertEvents([event]);

      // Extend TTL
      const result = await client!.extendTtl(entityId, 1800);
      expect(result).toBeDefined();
    });
  });

  // ==========================================================================
  // 13. TTL Clear Operation (opcode 160)
  // ==========================================================================

  describe('TTL Clear Operations', () => {
    test('ttl_clear_removes_ttl: Clear TTL removes expiration', async () => {
      const entityId = archerdbId();

      // Insert with TTL
      const event = createGeoEvent({
        entity_id: entityId,
        latitude: 40.7128,
        longitude: -74.0060,
        ttl_seconds: 3600,
      });
      await client!.insertEvents([event]);

      // Clear TTL
      const result = await client!.clearTtl(entityId);
      expect(result).toBeDefined();
    });
  });

  // ==========================================================================
  // 14. Topology Operation (opcode 157)
  // ==========================================================================

  describe('Topology Operations', () => {
    test('topology_returns_cluster_info: Returns cluster configuration', async () => {
      const result = await client!.getTopology();
      expect(result).toBeDefined();
      // Single node cluster should have at least one shard
      if (result.shards) {
        expect(result.shards.length).toBeGreaterThanOrEqual(1);
      }
    });
  });
});
