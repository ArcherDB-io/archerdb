// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 ArcherDB Contributors

/* eslint-disable no-console */

const crypto = require('node:crypto');
const path = require('node:path');

const sdk = require(path.resolve(__dirname, '../../../src/clients/node'));

const {
  GeoEventFlags,
  createGeoClient,
  degreesToNano,
  headingToCentidegrees,
  metersToMm,
} = sdk;

function parseServerAddress(url) {
  return String(url || 'http://127.0.0.1:7000')
    .replace(/^https?:\/\//, '')
    .replace(/\/+$/, '');
}

function asBigInt(value) {
  if (value === null || value === undefined) {
    return 0n;
  }
  if (typeof value === 'bigint') {
    return value;
  }
  if (typeof value === 'number') {
    return BigInt(Math.trunc(value));
  }
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return 0n;
    }
    if (/^-?\d+$/.test(trimmed)) {
      return BigInt(trimmed);
    }
    if (/^(0x)?[0-9a-fA-F]+$/.test(trimmed)) {
      const hex = trimmed.startsWith('0x') ? trimmed : `0x${trimmed}`;
      return BigInt(hex);
    }
    const digest = crypto.createHash('sha256').update(trimmed).digest();
    let out = 0n;
    for (let i = 0; i < 16; i++) {
      out |= BigInt(digest[i]) << (BigInt(i) * 8n);
    }
    return out === 0n ? 1n : out;
  }
  throw new TypeError(`Unsupported entity ID type: ${typeof value}`);
}

function asNumber(value, defaultValue = 0) {
  if (value === null || value === undefined) {
    return defaultValue;
  }
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'bigint') {
    return Number(value);
  }
  if (typeof value === 'string') {
    const n = Number(value);
    return Number.isFinite(n) ? n : defaultValue;
  }
  return defaultValue;
}

function extractEntityIds(input) {
  if (Array.isArray(input.entity_ids)) {
    return input.entity_ids.map(asBigInt);
  }
  if (input.entity_ids_range && typeof input.entity_ids_range === 'object') {
    const start = asNumber(input.entity_ids_range.start, 0);
    const count = Math.max(0, Math.trunc(asNumber(input.entity_ids_range.count, 0)));
    const out = [];
    for (let i = 0; i < count; i++) {
      out.push(BigInt(start + i));
    }
    return out;
  }
  return [];
}

function buildEvent(raw) {
  const latitude = raw.latitude !== undefined
    ? asNumber(raw.latitude, 0)
    : asNumber(raw.lat_nano, 0) / 1e9;
  const longitude = raw.longitude !== undefined
    ? asNumber(raw.longitude, 0)
    : asNumber(raw.lon_nano, 0) / 1e9;
  const timestampSeconds = Math.trunc(asNumber(raw.timestamp, 0));

  return {
    id: 0n,
    entity_id: asBigInt(raw.entity_id),
    correlation_id: asBigInt(raw.correlation_id ?? 0),
    user_data: asBigInt(raw.user_data ?? 0),
    lat_nano: degreesToNano(latitude),
    lon_nano: degreesToNano(longitude),
    group_id: asBigInt(raw.group_id ?? 0),
    timestamp: BigInt(timestampSeconds) * 1000000000n,
    altitude_mm: metersToMm(asNumber(raw.altitude_m, 0)),
    velocity_mms: metersToMm(asNumber(raw.velocity_mps, 0)),
    ttl_seconds: Math.trunc(asNumber(raw.ttl_seconds, 0)),
    accuracy_mm: metersToMm(asNumber(raw.accuracy_m, 0)),
    heading_cdeg: headingToCentidegrees(asNumber(raw.heading, 0)),
    flags: Math.trunc(asNumber(raw.flags, GeoEventFlags.none)),
  };
}

function formatEvent(event) {
  return {
    entity_id: asBigInt(event.entity_id ?? 0),
    latitude: asNumber(event.lat_nano, 0) / 1e9,
    longitude: asNumber(event.lon_nano, 0) / 1e9,
    timestamp: asBigInt(event.timestamp ?? 0),
    correlation_id: asBigInt(event.correlation_id ?? 0),
    user_data: asBigInt(event.user_data ?? 0),
    group_id: asBigInt(event.group_id ?? 0),
    ttl_seconds: Math.trunc(asNumber(event.ttl_seconds, 0)),
  };
}

function formatQueryResult(result) {
  const events = (result.events || []).map(formatEvent);
  return {
    count: events.length,
    has_more: Boolean(result.has_more),
    events,
  };
}

function parsePolygonVertices(vertices) {
  const parsed = [];
  for (const vertex of vertices || []) {
    if (Array.isArray(vertex) && vertex.length === 2) {
      parsed.push([asNumber(vertex[0], 0), asNumber(vertex[1], 0)]);
    } else if (vertex && typeof vertex === 'object') {
      const lat = vertex.lat ?? vertex.latitude;
      const lon = vertex.lon ?? vertex.longitude;
      if (lat !== undefined && lon !== undefined) {
        parsed.push([asNumber(lat, 0), asNumber(lon, 0)]);
      }
    }
  }
  return parsed;
}

function formatTopology(topology) {
  const rolesByAddress = new Map();
  for (const shard of topology.shards || []) {
    if (shard.primary) {
      rolesByAddress.set(shard.primary, 'primary');
    }
    for (const replica of shard.replicas || []) {
      if (replica && !rolesByAddress.has(replica)) {
        rolesByAddress.set(replica, 'replica');
      }
    }
  }

  return {
    nodes: Array.from(rolesByAddress.entries())
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([address, role]) => ({ address, role })),
  };
}

function stringifyWithBigInt(value) {
  return JSON.stringify(
    value,
    (_k, v) => (typeof v === 'bigint' ? `__bigint__${v.toString()}` : v),
  ).replace(/"__bigint__(-?\d+)"/g, '$1');
}

async function runOperation(client, operation, input) {
  switch (operation) {
    case 'ping':
      return { success: Boolean(await client.ping()) };

    case 'status': {
      const status = await client.getStatus();
      return {
        ram_index_count: asBigInt(status.ram_index_count ?? 0),
        ram_index_capacity: asBigInt(status.ram_index_capacity ?? 0),
        ram_index_load_pct: asNumber(status.ram_index_load_pct, 0),
        tombstone_count: asBigInt(status.tombstone_count ?? 0),
        ttl_expirations: asBigInt(status.ttl_expirations ?? 0),
        deletion_count: asBigInt(status.deletion_count ?? 0),
      };
    }

    case 'topology':
      return formatTopology(await client.getTopology());

    case 'insert': {
      const events = (input.events || []).map(buildEvent);
      const errors = await client.insertEvents(events);
      return {
        result_code: 0,
        count: events.length,
        results: (errors || []).map((e) => ({
          index: asNumber(e.index, 0),
          code: asNumber(e.result, 0),
        })),
      };
    }

    case 'upsert': {
      const events = (input.events || []).map(buildEvent);
      const errors = await client.upsertEvents(events);
      return {
        result_code: 0,
        count: events.length,
        results: (errors || []).map((e) => ({
          index: asNumber(e.index, 0),
          code: asNumber(e.result, 0),
        })),
      };
    }

    case 'delete': {
      const entityIds = extractEntityIds(input);
      if (entityIds.some((id) => id === 0n)) {
        return { error: 'entity_id must not be zero' };
      }
      const result = await client.deleteEntities(entityIds);
      return {
        deleted_count: asNumber(result.deleted_count, 0),
        not_found_count: asNumber(result.not_found_count, 0),
      };
    }

    case 'query-uuid': {
      const event = await client.getLatestByUuid(asBigInt(input.entity_id));
      return event ? { found: true, event: formatEvent(event) } : { found: false, event: null };
    }

    case 'query-uuid-batch': {
      const entityIds = extractEntityIds(input);
      const events = [];
      const notFoundEntityIds = [];

      // Use per-entity lookups to avoid SDK batch decode inconsistencies.
      for (const entityId of entityIds) {
        const event = await client.getLatestByUuid(entityId);
        if (event) {
          events.push(formatEvent(event));
        } else {
          notFoundEntityIds.push(entityId);
        }
      }

      return {
        found_count: events.length,
        not_found_count: notFoundEntityIds.length,
        events,
        not_found_entity_ids: notFoundEntityIds,
      };
    }

    case 'query-radius': {
      const latitude = input.latitude ?? input.center_latitude ?? input.center_lat;
      const longitude = input.longitude ?? input.center_longitude ?? input.center_lon;
      const radiusM = input.radius_m;

      if (latitude === undefined || longitude === undefined || radiusM === undefined) {
        return { error: 'query-radius requires latitude/longitude/radius_m' };
      }

      const result = await client.queryRadius({
        latitude: asNumber(latitude, 0),
        longitude: asNumber(longitude, 0),
        radius_m: asNumber(radiusM, 0),
        limit: Math.trunc(asNumber(input.limit, 1000)),
        timestamp_min: asBigInt(input.timestamp_min ?? 0),
        timestamp_max: asBigInt(input.timestamp_max ?? 0),
        group_id: asBigInt(input.group_id ?? 0),
      });
      return formatQueryResult(result);
    }

    case 'query-polygon': {
      const holes = Array.isArray(input.holes) ? input.holes.map(parsePolygonVertices) : undefined;
      const result = await client.queryPolygon({
        vertices: parsePolygonVertices(input.vertices || []),
        holes,
        limit: Math.trunc(asNumber(input.limit, 1000)),
        timestamp_min: asBigInt(input.timestamp_min ?? 0),
        timestamp_max: asBigInt(input.timestamp_max ?? 0),
        group_id: asBigInt(input.group_id ?? 0),
      });
      return formatQueryResult(result);
    }

    case 'query-latest': {
      const result = await client.queryLatest({
        limit: Math.trunc(asNumber(input.limit, 100)),
        group_id: asBigInt(input.group_id ?? 0),
        cursor_timestamp: asBigInt(input.cursor_timestamp ?? 0),
      });
      return formatQueryResult(result);
    }

    case 'ttl-set': {
      const result = await client.setTtl(asBigInt(input.entity_id), Math.trunc(asNumber(input.ttl_seconds, 0)));
      return {
        entity_id: asBigInt(result.entity_id ?? 0),
        previous_ttl_seconds: asNumber(result.previous_ttl_seconds, 0),
        new_ttl_seconds: asNumber(result.new_ttl_seconds, 0),
        result_code: asNumber(result.result, 0),
      };
    }

    case 'ttl-extend': {
      const extensionSeconds = input.extension_seconds ?? input.extend_by_seconds ?? 0;
      const result = await client.extendTtl(
        asBigInt(input.entity_id),
        Math.trunc(asNumber(extensionSeconds, 0)),
      );
      return {
        entity_id: asBigInt(result.entity_id ?? 0),
        previous_ttl_seconds: asNumber(result.previous_ttl_seconds, 0),
        new_ttl_seconds: asNumber(result.new_ttl_seconds, 0),
        result_code: asNumber(result.result, 0),
      };
    }

    case 'ttl-clear': {
      if (input.query_entity_id !== undefined) {
        const event = await client.getLatestByUuid(asBigInt(input.query_entity_id));
        return { entity_still_exists: Boolean(event) };
      }

      const result = await client.clearTtl(asBigInt(input.entity_id));
      return {
        entity_id: asBigInt(result.entity_id ?? 0),
        previous_ttl_seconds: asNumber(result.previous_ttl_seconds, 0),
        result_code: asNumber(result.result, 0),
      };
    }

    default:
      return { error: `Unknown operation: ${operation}` };
  }
}

async function main() {
  const operation = process.argv[2];
  if (!operation) {
    process.stdout.write(JSON.stringify({ error: 'operation argument required' }));
    return;
  }

  let input = {};
  try {
    const stdin = await new Promise((resolve, reject) => {
      let data = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (chunk) => {
        data += chunk;
      });
      process.stdin.on('end', () => resolve(data));
      process.stdin.on('error', reject);
    });
    if (stdin && stdin.trim().length > 0) {
      input = JSON.parse(stdin);
    }
  } catch (err) {
    process.stdout.write(JSON.stringify({ error: `invalid input JSON: ${err.message}` }));
    return;
  }

  const address = parseServerAddress(process.env.ARCHERDB_URL);
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: [address],
    request_timeout_ms: 120000,
    retry: {
      total_timeout_ms: 120000,
    },
  });

  try {
    const result = await runOperation(client, operation, input);
    process.stdout.write(stringifyWithBigInt(result));
  } catch (err) {
    process.stdout.write(JSON.stringify({ error: err?.message || String(err) }));
  } finally {
    try {
      client.destroy();
    } catch {
      // Ignore cleanup failures in parity subprocess mode.
    }
  }
}

main();
