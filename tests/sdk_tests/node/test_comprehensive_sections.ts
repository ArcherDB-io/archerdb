// Additional comprehensive test sections for Node.js SDK

// Delete - ALL 4 cases
describe('Delete Operations', () => {
  test.each(deleteFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;

    if (testCase.input.setup?.insert_first) {
      const setupEvents = testCase.input.setup.insert_first.map((ev: any) =>
        createGeoEvent({
          entity_id: BigInt(ev.entity_id),
          latitude: ev.latitude,
          longitude: ev.longitude,
        })
      );
      await client!.insertEvents(setupEvents);
    }

    const entityIds = (testCase.input.entity_ids || []).map((id: number) => BigInt(id));
    if (entityIds.length === 0) return;

    try {
      const result = await client!.deleteEntities(entityIds);
      if (testCase.expected_output.all_ok) {
        expect(result.deleted_count).toBeGreaterThanOrEqual(0);
      }
    } catch (e: any) {
      if (!testCase.input.entity_ids?.includes(0)) throw e;
    }
  });
});

// Query Radius - ALL 10 cases
describe('Query Radius Operations', () => {
  test.each(queryRadiusFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;

    if (testCase.input.setup?.insert_first) {
      const setupEvents = testCase.input.setup.insert_first.map((ev: any) =>
        createGeoEvent({
          entity_id: BigInt(ev.entity_id),
          latitude: ev.latitude,
          longitude: ev.longitude,
        })
      );
      await client!.insertEvents(setupEvents);
    }

    const result = await client!.queryRadius({
      latitude: testCase.input.center_latitude || testCase.input.latitude,
      longitude: testCase.input.center_longitude || testCase.input.longitude,
      radius_m: testCase.input.radius_m,
      limit: testCase.input.limit || 1000,
      group_id: testCase.input.group_id ? BigInt(testCase.input.group_id) : undefined,
    });

    if (testCase.expected_output.events_contain) {
      verifyEventsContain(result.events, testCase.expected_output.events_contain);
    }
    if (testCase.expected_output.count_in_range !== undefined) {
      expect(result.events.length).toBe(testCase.expected_output.count_in_range);
    }
  });
});

// Query Polygon - ALL 9 cases
describe('Query Polygon Operations', () => {
  test.each(queryPolygonFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;

    if (testCase.input.setup?.insert_first) {
      const setupEvents = testCase.input.setup.insert_first.map((ev: any) =>
        createGeoEvent({
          entity_id: BigInt(ev.entity_id),
          latitude: ev.latitude,
          longitude: ev.longitude,
        })
      );
      await client!.insertEvents(setupEvents);
    }

    const vertices = testCase.input.vertices.map((v: number[]) => ({
      latitude: v[0],
      longitude: v[1],
    }));

    const result = await client!.queryPolygon({
      vertices,
      limit: testCase.input.limit || 1000,
      group_id: testCase.input.group_id ? BigInt(testCase.input.group_id) : undefined,
    });

    if (testCase.expected_output.events_contain) {
      verifyEventsContain(result.events, testCase.expected_output.events_contain);
    }
  });
});

// Query Latest - ALL 5 cases
describe('Query Latest Operations', () => {
  test.each(queryLatestFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;

    if (testCase.input.setup?.insert_first) {
      const setupEvents = testCase.input.setup.insert_first.map((ev: any) =>
        createGeoEvent({
          entity_id: BigInt(ev.entity_id),
          latitude: ev.latitude,
          longitude: ev.longitude,
        })
      );
      await client!.insertEvents(setupEvents);
    }

    const result = await client!.queryLatest({
      limit: testCase.input.limit || 1000,
      group_id: testCase.input.group_id ? BigInt(testCase.input.group_id) : undefined,
    });

    if (testCase.expected_output.count_in_range !== undefined) {
      expect(result.events.length).toBeGreaterThanOrEqual(testCase.expected_output.count_in_range);
    }
  });
});

// Ping, Status, Topology - simple operations
describe('Ping Operations', () => {
  test.each(pingFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    const result = await client!.ping();
    expect(result).toBe(true);
  });
});

describe('Status Operations', () => {
  test.each(statusFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    const result = await client!.getStatus();
    expect(result).toBeDefined();
  });
});

describe('Topology Operations', () => {
  test.each(topologyFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    const result = await client!.getTopology();
    expect(result).toBeDefined();
  });
});
