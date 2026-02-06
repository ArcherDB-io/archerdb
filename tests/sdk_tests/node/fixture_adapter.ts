// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 ArcherDB Contributors

/**
 * Cross-SDK fixture loading and conversion helpers for Node.js.
 *
 * This module provides utilities for loading test fixtures from Phase 11
 * and converting them to formats suitable for the Node.js SDK.
 */

import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';

// Path to fixtures directory (relative to this file)
const FIXTURES_DIR = path.resolve(__dirname, '../../../test_infrastructure/fixtures/v1');

/**
 * Test case from fixture file.
 */
export interface TestCase {
  name: string;
  description: string;
  tags: string[];
  input: Record<string, any>;
  expected_output: Record<string, any> | null;
  expected_error: string | null;
}

/**
 * Complete fixture file with all test cases.
 */
export interface Fixture {
  operation: string;
  version: string;
  description: string;
  cases: TestCase[];
}

/**
 * Event format from fixture files.
 */
export interface FixtureEvent {
  entity_id: number | bigint;
  latitude: number;
  longitude: number;
  correlation_id?: number;
  user_data?: number;
  group_id?: number;
  altitude_m?: number;
  velocity_mps?: number;
  ttl_seconds?: number;
  accuracy_m?: number;
  heading?: number;
  flags?: number;
}

/**
 * Load fixture for specified operation.
 *
 * @param operation - Operation name (e.g., 'insert', 'query-radius')
 * @returns Fixture object with all test cases
 */
export function loadFixture(operation: string): Fixture {
  const fixturePath = path.join(FIXTURES_DIR, `${operation}.json`);

  if (!fs.existsSync(fixturePath)) {
    throw new Error(`Fixture not found: ${fixturePath}`);
  }

  const data = fs.readFileSync(fixturePath, 'utf8');
  return JSON.parse(data) as Fixture;
}

/**
 * Get a specific test case by name from a fixture.
 *
 * @param fixture - Fixture object to search
 * @param name - Test case name to find
 * @returns TestCase if found, undefined otherwise
 */
export function getCaseByName(fixture: Fixture, name: string): TestCase | undefined {
  return fixture.cases.find(c => c.name === name);
}

/**
 * Filter test cases by tag.
 *
 * @param fixture - Fixture object
 * @param tag - Tag to filter by (smoke, pr, nightly)
 * @returns Filtered test cases
 */
export function filterCasesByTag(fixture: Fixture, tag: string): TestCase[] {
  return fixture.cases.filter(c => c.tags.includes(tag));
}

/**
 * Convert fixture events to SDK format.
 *
 * @param events - Events from fixture input
 * @returns Events ready for SDK consumption
 */
export function convertEvents(events: FixtureEvent[]): any[] {
  return events.map(event => ({
    entity_id: BigInt(event.entity_id),
    latitude: event.latitude,
    longitude: event.longitude,
    correlation_id: event.correlation_id,
    user_data: event.user_data,
    group_id: event.group_id ? BigInt(event.group_id) : undefined,
    altitude_m: event.altitude_m,
    velocity_mps: event.velocity_mps,
    ttl_seconds: event.ttl_seconds,
    accuracy_m: event.accuracy_m,
    heading: event.heading,
    flags: event.flags,
  }));
}

/**
 * Generate a unique entity ID based on test name and timestamp.
 *
 * @param testName - Name of the test
 * @returns Unique BigInt entity ID
 */
export function generateEntityId(testName: string): bigint {
  const uniqueString = `${testName}:${Date.now()}:${Math.random()}`;
  const hash = crypto.createHash('sha256').update(uniqueString).digest();
  // Use first 8 bytes as BigInt, ensure non-zero
  const id = hash.readBigUInt64LE(0);
  return id === 0n ? 1n : id;
}

/**
 * Clean database by deleting all entities.
 *
 * @param client - SDK client
 */
export async function cleanDatabase(client: any): Promise<void> {
  try {
    let cursor = 0n;
    while (true) {
      const result = await client.queryLatest({ limit: 10000, cursor_timestamp: cursor });
      if (!result.events || result.events.length === 0) {
        break;
      }
      const entityIds = result.events.map((e: any) => e.entity_id);
      await client.deleteEntities(entityIds);
      const last = result.events[result.events.length - 1];
      const nextCursor = (last && last.timestamp !== undefined) ? BigInt(last.timestamp) : 0n;
      if (nextCursor === cursor) {
        break;
      }
      cursor = nextCursor;
    }
  } catch {
    // If query fails (empty database), that's fine
  }
}

/**
 * Verify that events contain expected entity IDs.
 *
 * @param events - Events from query result
 * @param expectedIds - Expected entity IDs
 * @param operationName - Operation name for error messages
 */
export function verifyEventsContain(
  events: any[],
  expectedIds: (number | bigint)[],
  operationName: string
): void {
  const actualIds = new Set(events.map(e => BigInt(e.entity_id)));
  const expectedSet = new Set(expectedIds.map(id => BigInt(id)));

  for (const expected of expectedSet) {
    if (!actualIds.has(expected)) {
      throw new Error(
        `${operationName}: Missing expected entity ID: ${expected}\n` +
        `  Expected: ${Array.from(expectedSet)}\n` +
        `  Actual:   ${Array.from(actualIds)}`
      );
    }
  }
}

/**
 * List all available operations with fixtures.
 */
export function listOperations(): string[] {
  return fs.readdirSync(FIXTURES_DIR)
    .filter(f => f.endsWith('.json'))
    .map(f => f.replace('.json', ''));
}
