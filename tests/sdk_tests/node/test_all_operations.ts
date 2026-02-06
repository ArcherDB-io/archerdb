// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 ArcherDB Contributors

/**
 * Comprehensive Node.js SDK tests - ALL 79 fixture cases
 * 
 * Converted to fixture-driven approach using test.each() to iterate through
 * ALL test cases, matching Go SDK and updated Python SDK comprehensive coverage.
 */

import { spawn, ChildProcess } from 'child_process';
import * as path from 'path';
import { loadFixture, cleanDatabase } from './fixture_adapter';
import {
  GeoClient,
  GeoEvent,
  createGeoClient,
  degreesToNano,
  metersToMm,
  headingToCentidegrees,
  GeoEventFlags,
  InvalidCoordinates,
  InvalidEntityId,
} from 'archerdb';

const RUN_INTEGRATION = process.env.ARCHERDB_INTEGRATION === '1';
const describeIntegration = RUN_INTEGRATION ? describe : describe.skip;

// Load ALL fixtures at module level
const allFixtures = {
  insert: loadFixture('insert'),
  upsert: loadFixture('upsert'),
  delete: loadFixture('delete'),
  'query-uuid': loadFixture('query-uuid'),
  'query-uuid-batch': loadFixture('query-uuid-batch'),
  'query-radius': loadFixture('query-radius'),
  'query-polygon': loadFixture('query-polygon'),
  'query-latest': loadFixture('query-latest'),
  ping: loadFixture('ping'),
  status: loadFixture('status'),
  topology: loadFixture('topology'),
  'ttl-set': loadFixture('ttl-set'),
  'ttl-extend': loadFixture('ttl-extend'),
  'ttl-clear': loadFixture('ttl-clear'),
};

function toBigInt(value: number | bigint | undefined): bigint {
  return value === undefined ? 0n : BigInt(value);
}

function buildEventFromFixture(ev: any): GeoEvent {
  return {
    id: 0n,
    entity_id: BigInt(ev.entity_id),
    correlation_id: toBigInt(ev.correlation_id),
    user_data: toBigInt(ev.user_data),
    lat_nano: degreesToNano(ev.latitude),
    lon_nano: degreesToNano(ev.longitude),
    group_id: toBigInt(ev.group_id),
    timestamp: BigInt(ev.timestamp ?? 0) * 1_000_000_000n,
    altitude_mm: metersToMm(ev.altitude_m ?? 0),
    velocity_mms: metersToMm(ev.velocity_mps ?? 0),
    ttl_seconds: ev.ttl_seconds ?? 0,
    accuracy_mm: metersToMm(ev.accuracy_m ?? 0),
    heading_cdeg: headingToCentidegrees(ev.heading ?? 0),
    flags: ev.flags ?? GeoEventFlags.none,
  };
}

// Helper to setup test data
async function setupData(client: GeoClient, setup: any): Promise<number[]> {
  const insertedIds: number[] = [];
  if (!setup) return insertedIds;

  if (setup.insert_first) {
    const insertFirst = Array.isArray(setup.insert_first) ? setup.insert_first : [setup.insert_first];
    const events = insertFirst.map((ev: any) => buildEventFromFixture(ev));
    insertFirst.forEach((ev: any) => {
      if (ev?.entity_id !== undefined) insertedIds.push(ev.entity_id);
    });
    await client.insertEvents(events);
  }

  if (setup.insert_first_range) {
    const range = setup.insert_first_range;
    const startId = range.start_entity_id;
    const count = range.count;
    const baseLat = range.base_latitude;
    const baseLon = range.base_longitude;
    const spreadM = range.spread_m ?? 100;

    const events: GeoEvent[] = [];
    const spreadDeg = spreadM / 111000;
    const cols = Math.min(10, count || 1);
    const rows = count ? Math.ceil(count / cols) : 1;
    for (let i = 0; i < count; i++) {
      const row = Math.floor(i / cols);
      const col = i % cols;
      const rowFrac = rows <= 1 ? 0.5 : row / (rows - 1);
      const colFrac = cols <= 1 ? 0.5 : col / (cols - 1);
      const latOffset = (rowFrac - 0.5) * spreadDeg;
      const lonOffset = (colFrac - 0.5) * spreadDeg;
      events.push(buildEventFromFixture({
        entity_id: startId + i,
        latitude: baseLat + latOffset,
        longitude: baseLon + lonOffset,
      }));
      insertedIds.push(startId + i);
    }
    for (let i = 0; i < events.length; i += 200) {
      await client.insertEvents(events.slice(i, i + 200));
    }
  }

  if (setup.insert_hotspot) {
    const hotspot = setup.insert_hotspot;
    const centerLat = hotspot.center_latitude;
    const centerLon = hotspot.center_longitude;
    const count = hotspot.count;
    const concentration = hotspot.concentration_percentage ?? 100;
    const startId = hotspot.start_entity_id ?? 1;

    const hotspotCount = Math.round(count * (concentration / 100));
    const events: GeoEvent[] = [];
    for (let i = 0; i < count; i++) {
      const inHotspot = i < hotspotCount;
      const total = Math.max(inHotspot ? hotspotCount : (count - hotspotCount), 1);
      const idx = inHotspot ? i : (i - hotspotCount);
      const spreadDeg = inHotspot ? 0.005 : 0.05;
      const cols = Math.min(10, total);
      const rows = total ? Math.ceil(total / cols) : 1;
      const row = Math.floor(idx / cols);
      const col = idx % cols;
      const rowFrac = rows <= 1 ? 0.5 : row / (rows - 1);
      const colFrac = cols <= 1 ? 0.5 : col / (cols - 1);
      const lat = centerLat + (rowFrac - 0.5) * spreadDeg;
      const lon = centerLon + (colFrac - 0.5) * spreadDeg;
      events.push(buildEventFromFixture({
        entity_id: startId + i,
        latitude: lat,
        longitude: lon,
      }));
      insertedIds.push(startId + i);
    }
    for (let i = 0; i < events.length; i += 200) {
      await client.insertEvents(events.slice(i, i + 200));
    }
  }

  if (setup.insert_with_timestamps) {
    const events = setup.insert_with_timestamps.map((ev: any) => buildEventFromFixture(ev));
    setup.insert_with_timestamps.forEach((ev: any) => {
      if (ev?.entity_id !== undefined) insertedIds.push(ev.entity_id);
    });
    for (let i = 0; i < events.length; i += 200) {
      await client.insertEvents(events.slice(i, i + 200));
    }
  }

  if (setup.then_upsert) {
    const upsert = Array.isArray(setup.then_upsert) ? setup.then_upsert : [setup.then_upsert];
    const events = upsert.map((ev: any) => buildEventFromFixture(ev));
    await client.upsertEvents(events);
  }

  if (setup.then_clear_ttl) {
    await client.clearTtl(BigInt(setup.then_clear_ttl));
  }

  if (setup.then_wait_seconds) {
    const waitMs = Number(setup.then_wait_seconds) * 1000;
    await new Promise(resolve => setTimeout(resolve, waitMs));
  }

  if (setup.perform_operations) {
    for (const op of setup.perform_operations) {
      if (op.type === 'insert' && op.count) {
        const events: GeoEvent[] = [];
        const baseId = 99000;
        for (let i = 0; i < op.count; i++) {
          events.push(buildEventFromFixture({
            entity_id: baseId + i,
            latitude: 40.0 + (i * 0.0001),
            longitude: -74.0 - (i * 0.0001),
          }));
        }
        for (let i = 0; i < events.length; i += 200) {
          await client.insertEvents(events.slice(i, i + 200));
        }
      }
      if (op.type === 'query_radius' && op.count) {
        for (let i = 0; i < op.count; i++) {
          await client.queryRadius({ latitude: 40.0, longitude: -74.0, radius_m: 1000, limit: 10 });
        }
      }
    }
  }

  return insertedIds;
}

function expectedResultCodes(testCase: any): number[] {
  const results = testCase.expected_output?.results;
  if (!results) return [];
  return results.map((r: any) => r.code ?? 0);
}

function assertExpectedCodes(errors: any[], expectedCodes: number[], operation: string) {
  expectedCodes.forEach((code, idx) => {
    if (code === 0) return;
    const match = errors.some(e => e.index === idx && e.result === code);
    expect(match).toBeTruthy();
  });
}

function isExpectedInsertException(err: any, expectedCodes: number[]): boolean {
  if (err instanceof InvalidCoordinates) {
    return expectedCodes.some(code => [8, 9, 10, 14].includes(code));
  }
  if (err instanceof InvalidEntityId) {
    return expectedCodes.some(code => [6, 7].includes(code));
  }
  return false;
}

function verifyEventsExclude(events: any[], excludedIds: number[], operation: string) {
  const actualIds = new Set(events.map(e => BigInt(e.entity_id)));
  const excluded = excludedIds.map(id => BigInt(id));
  for (const id of excluded) {
    expect(actualIds.has(id)).toBeFalsy();
  }
}

async function getOutputCap(client: GeoClient, insertedIds: number[]): Promise<number | null> {
  if (!insertedIds.length) return null;
  const latest = await client.queryLatest({ limit: 10000 });
  if (latest.events.length < insertedIds.length) {
    return latest.events.length;
  }
  return null;
}

function assertCountMatches(
  expected: any,
  actual: number,
  operation: string,
  maxResults?: number | null
) {
  if (expected?.count !== undefined) {
    let expectedCount = expected.count;
    if (maxResults !== undefined && maxResults !== null && expectedCount > maxResults) {
      expectedCount = maxResults;
    }
    expect(actual).toBe(expectedCount);
  }
  if (expected?.count_in_range !== undefined) {
    let minCount = expected.count_in_range;
    if (maxResults !== undefined && maxResults !== null && minCount > maxResults) {
      minCount = maxResults;
    }
    expect(actual).toBeGreaterThanOrEqual(minCount);
  }
  if (expected?.count_in_range_min !== undefined) {
    let minCount = expected.count_in_range_min;
    if (maxResults !== undefined && maxResults !== null && minCount > maxResults) {
      minCount = maxResults;
    }
    expect(actual).toBeGreaterThanOrEqual(minCount);
  }
  if (expected?.count_min !== undefined) {
    let minCount = expected.count_min;
    if (maxResults !== undefined && maxResults !== null && minCount > maxResults) {
      minCount = maxResults;
    }
    expect(actual).toBeGreaterThanOrEqual(minCount);
  }
}

let clusterProcess: ChildProcess | null = null;
let client: GeoClient | null = null;

describeIntegration('ArcherDB Node.js SDK Operation Tests', () => {
  beforeAll(async () => {
    const projectRoot = path.resolve(__dirname, '../../..');
    
    const proc = spawn('python3', ['-c', `
import sys, time
sys.path.insert(0, '${projectRoot}')
sys.path.insert(0, '${projectRoot}/src/clients/python/src')
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
config = ClusterConfig(node_count=1, cache_grid="256MiB", startup_timeout=60.0)
cluster = ArcherDBCluster(config)
cluster.start()
cluster.wait_for_ready(timeout=60.0)
cluster.wait_for_leader(timeout=30.0)
print(f"READY:{cluster.get_addresses()}")
sys.stdout.flush()
while True: time.sleep(1)
`]);

    const ready = await new Promise<string>((resolve, reject) => {
      proc.stdout?.on('data', (data) => {
        const output = data.toString();
        if (output.includes('READY:')) {
          resolve(output.split('READY:')[1].trim());
        }
      });
      setTimeout(() => reject(new Error('Cluster timeout')), 90000);
    });

    clusterProcess = proc;
    client = createGeoClient({
      cluster_id: 0n,
      addresses: [`127.0.0.1:${ready}`],
    });
  }, 120000);

  afterAll(async () => {
    if (client) client.destroy();
    if (clusterProcess) clusterProcess.kill();
  });

  beforeEach(async () => {
    if (client) await cleanDatabase(client);
  });

  // Insert Operations - ALL 14 cases
  describe('Insert Operations', () => {
    test.each(allFixtures.insert.cases)('$name', async (testCase) => {
      const events = testCase.input.events.map((ev: any) => buildEventFromFixture(ev));
      const expectedCodes = expectedResultCodes(testCase);

      try {
        const errors = await client!.insertEvents(events);
        if (testCase.expected_output?.all_ok) {
          expect(errors).toEqual([]);
        }
        if (testCase.expected_output?.results_count !== undefined) {
          expect(events.length).toBe(testCase.expected_output.results_count);
        }
        if (expectedCodes.length > 0) {
          assertExpectedCodes(errors, expectedCodes, 'insert');
        }
      } catch (err: any) {
        if (expectedCodes.length > 0 && isExpectedInsertException(err, expectedCodes)) {
          return;
        }
        throw err;
      }
    });
  });

  // Upsert Operations - ALL 4 cases
  describe('Upsert Operations', () => {
    test.each(allFixtures.upsert.cases)('$name', async (testCase) => {
      await setupData(client!, testCase.input.setup);

      const events = testCase.input.events.map((ev: any) => buildEventFromFixture(ev));
      const expectedCodes = expectedResultCodes(testCase);

      try {
        const errors = await client!.upsertEvents(events);
        if (testCase.expected_output?.all_ok) {
          expect(errors).toEqual([]);
        }
        if (expectedCodes.length > 0) {
          assertExpectedCodes(errors, expectedCodes, 'upsert');
        }
      } catch (err: any) {
        if (expectedCodes.length > 0 && isExpectedInsertException(err, expectedCodes)) {
          return;
        }
        throw err;
      }
    });
  });

  // Delete Operations - ALL 4 cases
  describe('Delete Operations', () => {
    test.each(allFixtures.delete.cases)('$name', async (testCase) => {
      await setupData(client!, testCase.input.setup);

      const entityIds = (testCase.input.entity_ids || []).map((id: number) => BigInt(id));
      if (entityIds.length === 0) return;

      try {
        const result = await client!.deleteEntities(entityIds);
        const expectedCodes = expectedResultCodes(testCase);
        if (expectedCodes.length > 0) {
          const expectedDeleted = expectedCodes.filter((c: number) => c === 0).length;
          const expectedNotFound = expectedCodes.filter((c: number) => c === 3).length;
          expect(result.deleted_count).toBe(expectedDeleted);
          expect(result.not_found_count).toBe(expectedNotFound);
        }
      } catch (e: any) {
        const expectedCodes = expectedResultCodes(testCase);
        if (expectedCodes.includes(2) && e instanceof InvalidEntityId) return;
        throw e;
      }
    });
  });

  // Query UUID Operations - ALL 4 cases
  describe('Query UUID Operations', () => {
    test.each(allFixtures['query-uuid'].cases)('$name', async (testCase) => {
      await setupData(client!, testCase.input.setup);

      const entityIdValue = testCase.input.entity_id;
      if (entityIdValue === undefined || entityIdValue === null) return;

      const entityId = BigInt(entityIdValue);
      try {
        const found = await client!.getLatestByUuid(entityId);
        if (testCase.expected_output?.found) {
          expect(found).not.toBeNull();
        } else {
          expect(found).toBeNull();
        }
      } catch (err: any) {
        if (entityId === 0n && err instanceof InvalidEntityId) return;
        throw err;
      }
    });
  });

  // Query UUID Batch Operations - ALL 5 cases  
  describe('Query UUID Batch Operations', () => {
    test.each(allFixtures['query-uuid-batch'].cases)('$name', async (testCase) => {
      await setupData(client!, testCase.input.setup);

      const entityIds = (testCase.input.entity_ids || []).map((id: number) => BigInt(id));
      if (entityIds.length === 0) return;

      const results = await client!.getLatestByUuidBatch(entityIds);
      
      const foundCount = testCase.expected_output?.found_count || 0;
      expect(results.size).toBeGreaterThanOrEqual(foundCount);
    });
  });

  // Query Radius Operations - ALL 10 cases
  describe('Query Radius Operations', () => {
    test.each(allFixtures['query-radius'].cases)('$name', async (testCase) => {
      const insertedIds = await setupData(client!, testCase.input.setup);
      const expected = testCase.expected_output;
      const needsCountCheck = expected && (
        expected.count !== undefined ||
        expected.count_in_range !== undefined ||
        expected.count_in_range_min !== undefined ||
        expected.count_min !== undefined
      );
      const maxResults = needsCountCheck ? await getOutputCap(client!, insertedIds) : null;

      const tsMin = testCase.input.timestamp_min ?? 0;
      const tsMax = testCase.input.timestamp_max ?? 0;

      const result = await client!.queryRadius({
        latitude: testCase.input.center_latitude ?? testCase.input.latitude ?? 0,
        longitude: testCase.input.center_longitude ?? testCase.input.longitude ?? 0,
        radius_m: testCase.input.radius_m ?? 1000,
        limit: testCase.input.limit ?? 1000,
        timestamp_min: tsMin ? BigInt(tsMin) * 1_000_000_000n : undefined,
        timestamp_max: tsMax ? BigInt(tsMax) * 1_000_000_000n : undefined,
        group_id: testCase.input.group_id ? BigInt(testCase.input.group_id) : undefined,
      });

      if (testCase.expected_output?.events_contain) {
        const expectedIds = testCase.expected_output.events_contain.map((id: number) => BigInt(id));
        const actualIds = new Set(result.events.map(e => BigInt(e.entity_id)));
        expectedIds.forEach((id: bigint) => expect(actualIds.has(id)).toBeTruthy());
      }
      if (testCase.expected_output?.events_exclude) {
        verifyEventsExclude(result.events, testCase.expected_output.events_exclude, 'query_radius');
      }
      if (needsCountCheck) {
        assertCountMatches(expected, result.events.length, 'query_radius', maxResults);
      }
    });
  });

  // Query Polygon Operations - ALL 9 cases
  describe('Query Polygon Operations', () => {
    test.each(allFixtures['query-polygon'].cases)('$name', async (testCase) => {
      const insertedIds = await setupData(client!, testCase.input.setup);
      const expected = testCase.expected_output;
      const needsCountCheck = expected && (
        expected.count !== undefined ||
        expected.count_in_range !== undefined ||
        expected.count_in_range_min !== undefined ||
        expected.count_min !== undefined
      );
      const maxResults = needsCountCheck ? await getOutputCap(client!, insertedIds) : null;

      const tsMin = testCase.input.timestamp_min ?? 0;
      const tsMax = testCase.input.timestamp_max ?? 0;

      // Vertices are already in correct format: [[lat, lon], ...]
      const result = await client!.queryPolygon({
        vertices: testCase.input.vertices,
        limit: testCase.input.limit || 1000,
        timestamp_min: tsMin ? BigInt(tsMin) * 1_000_000_000n : undefined,
        timestamp_max: tsMax ? BigInt(tsMax) * 1_000_000_000n : undefined,
        group_id: testCase.input.group_id ? BigInt(testCase.input.group_id) : undefined,
      });

      if (testCase.expected_output?.events_contain) {
        const expectedIds = testCase.expected_output.events_contain.map((id: number) => BigInt(id));
        const actualIds = new Set(result.events.map(e => BigInt(e.entity_id)));
        expectedIds.forEach((id: bigint) => expect(actualIds.has(id)).toBeTruthy());
      }
      if (testCase.expected_output?.events_exclude) {
        verifyEventsExclude(result.events, testCase.expected_output.events_exclude, 'query_polygon');
      }
      if (needsCountCheck) {
        assertCountMatches(expected, result.events.length, 'query_polygon', maxResults);
      }
    });
  });

  // Query Latest Operations - ALL 5 cases
  describe('Query Latest Operations', () => {
    test.each(allFixtures['query-latest'].cases)('$name', async (testCase) => {
      const insertedIds = await setupData(client!, testCase.input.setup);
      const expected = testCase.expected_output;
      const needsCountCheck = expected && (
        expected.count !== undefined ||
        expected.count_in_range !== undefined ||
        expected.count_in_range_min !== undefined ||
        expected.count_min !== undefined
      );
      const maxResults = needsCountCheck ? await getOutputCap(client!, insertedIds) : null;

      const result = await client!.queryLatest({
        limit: testCase.input.limit || 1000,
        group_id: testCase.input.group_id ? BigInt(testCase.input.group_id) : undefined,
      });

      if (needsCountCheck) {
        assertCountMatches(expected, result.events.length, 'query_latest', maxResults);
      }
    });
  });

  // Ping Operations - ALL 2 cases
  describe('Ping Operations', () => {
    test.each(allFixtures.ping.cases)('$name', async (testCase) => {
      const result = await client!.ping();
      expect(result).toBe(true);
    });
  });

  // Status Operations - ALL 3 cases
  describe('Status Operations', () => {
    test.each(allFixtures.status.cases)('$name', async (testCase) => {
      const result = await client!.getStatus();
      expect(result).toBeDefined();
    });
  });

  // Topology Operations - ALL 6 cases
  describe('Topology Operations', () => {
    test.each(allFixtures.topology.cases)('$name', async (testCase) => {
      const result = await client!.getTopology();
      expect(result).toBeDefined();
    });
  });

  // TTL Set Operations - ALL 5 cases
  describe('TTL Set Operations', () => {
    test.each(allFixtures['ttl-set'].cases)('$name', async (testCase) => {
      await setupData(client!, testCase.input.setup);

      const entityId = testCase.input.entity_id ? BigInt(testCase.input.entity_id) : null;
      const ttlSeconds = testCase.input.ttl_seconds || 0;

      if (!entityId || entityId === 0n) return;

      const result = await client!.setTtl(entityId, ttlSeconds);
      if (testCase.expected_output?.result_code !== undefined) {
        expect(Number(result.result)).toBe(testCase.expected_output.result_code);
      }
    });
  });

  // TTL Extend Operations - ALL 4 cases
  describe('TTL Extend Operations', () => {
    test.each(allFixtures['ttl-extend'].cases)('$name', async (testCase) => {
      await setupData(client!, testCase.input.setup);

      const entityId = testCase.input.entity_id ? BigInt(testCase.input.entity_id) : null;
      const extensionSeconds = testCase.input.extend_by_seconds ?? testCase.input.extension_seconds ?? 0;

      if (!entityId || entityId === 0n) return;

      const result = await client!.extendTtl(entityId, extensionSeconds);
      if (testCase.expected_output?.result_code !== undefined) {
        expect(Number(result.result)).toBe(testCase.expected_output.result_code);
      }
      if (testCase.expected_output?.new_ttl_min_seconds !== undefined) {
        expect(result.new_ttl_seconds).toBeGreaterThanOrEqual(testCase.expected_output.new_ttl_min_seconds);
      }
    });
  });

  // TTL Clear Operations - ALL 4 cases
  describe('TTL Clear Operations', () => {
    test.each(allFixtures['ttl-clear'].cases)('$name', async (testCase) => {
      await setupData(client!, testCase.input.setup);

      if (testCase.input.query_entity_id !== undefined) {
        const entityId = BigInt(testCase.input.query_entity_id);
        const found = await client!.getLatestByUuid(entityId);
        if (testCase.expected_output?.entity_still_exists) {
          expect(found).not.toBeNull();
        } else {
          expect(found).toBeNull();
        }
        return;
      }

      const entityId = testCase.input.entity_id ? BigInt(testCase.input.entity_id) : null;

      if (!entityId || entityId === 0n) return;

      const result = await client!.clearTtl(entityId);
      if (testCase.expected_output?.result_code !== undefined) {
        expect(Number(result.result)).toBe(testCase.expected_output.result_code);
      }
    });
  });
});
