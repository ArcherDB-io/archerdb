/**
 * Tests for ArcherDB Node.js SDK - Geo-Routing Module
 *
 * Tests cover:
 * - Region discovery and caching
 * - Latency probing and rolling averages
 * - Region selection algorithm
 * - Automatic failover
 * - Geo-routing metrics
 */

// Copyright 2025 ArcherDB Authors. All rights reserved.
// Use of this source code is governed by the Apache 2.0 license.

import { describe, it, beforeEach } from 'node:test'
import * as assert from 'node:assert'

import {
  GeoRoutingConfig,
  createGeoRoutingConfig,
  isGeoRoutingEnabled,
  RegionHealth,
  RegionInfo,
  RegionLocation,
  parseRegionInfo,
  DiscoveryResponse,
  parseDiscoveryResponse,
  isDiscoveryExpired,
  RegionLatencyStats,
  GeoRoutingMetrics,
  DiscoveryError,
  RegionDiscoveryClient,
  LatencyProber,
  RegionSelector,
  GeoRouter,
} from './geo_routing'

// ============================================================================
// Test Helpers
// ============================================================================

function createSampleRegions(): RegionInfo[] {
  return [
    {
      name: 'us-east-1',
      endpoint: 'us-east.example.com:5000',
      location: { latitude: 39.04, longitude: -77.49 },
      healthy: true,
    },
    {
      name: 'us-west-2',
      endpoint: 'us-west.example.com:5000',
      location: { latitude: 45.52, longitude: -122.68 },
      healthy: true,
    },
    {
      name: 'eu-west-1',
      endpoint: 'eu-west.example.com:5000',
      location: { latitude: 53.34, longitude: -6.26 },
      healthy: true,
    },
  ]
}

function createTestConfig(): Required<GeoRoutingConfig> {
  return createGeoRoutingConfig({
    discoveryEndpoint: 'http://localhost:9999/regions',
    failoverEnabled: true,
    probeIntervalMs: 1000,
    failoverTimeoutMs: 500,
    backgroundProbing: false,
  })
}

// ============================================================================
// parseRegionInfo Tests
// ============================================================================

describe('parseRegionInfo', () => {
  it('should parse complete region data', () => {
    const data = {
      name: 'us-east-1',
      endpoint: 'archerdb-use1.example.com:5000',
      location: { lat: 39.04, lon: -77.49 },
      healthy: true,
    }
    const region = parseRegionInfo(data)

    assert.strictEqual(region.name, 'us-east-1')
    assert.strictEqual(region.endpoint, 'archerdb-use1.example.com:5000')
    assert.strictEqual(region.location.latitude, 39.04)
    assert.strictEqual(region.location.longitude, -77.49)
    assert.strictEqual(region.healthy, true)
  })

  it('should parse minimal region data', () => {
    const data = { name: 'test', endpoint: 'test:5000' }
    const region = parseRegionInfo(data)

    assert.strictEqual(region.name, 'test')
    assert.strictEqual(region.endpoint, 'test:5000')
    assert.strictEqual(region.location.latitude, 0)
    assert.strictEqual(region.healthy, true)
  })

  it('should parse unhealthy region', () => {
    const data = { name: 'test', endpoint: 'test:5000', healthy: false }
    const region = parseRegionInfo(data)

    assert.strictEqual(region.healthy, false)
  })
})

// ============================================================================
// parseDiscoveryResponse Tests
// ============================================================================

describe('parseDiscoveryResponse', () => {
  it('should parse response with expiry', () => {
    const data = {
      regions: [
        { name: 'us-east-1', endpoint: 'us-east:5000' },
        { name: 'eu-west-1', endpoint: 'eu-west:5000' },
      ],
      expires: '2030-01-15T12:00:00Z',
    }
    const response = parseDiscoveryResponse(data)

    assert.strictEqual(response.regions.length, 2)
    assert.strictEqual(response.regions[0].name, 'us-east-1')
    assert.ok(response.expires)
    assert.strictEqual(response.expires!.getFullYear(), 2030)
  })
})

// ============================================================================
// isDiscoveryExpired Tests
// ============================================================================

describe('isDiscoveryExpired', () => {
  it('should return false for future expiry', () => {
    const future = new Date(Date.now() + 3600 * 1000)
    const response: DiscoveryResponse = {
      regions: [],
      expires: future,
      fetchedAt: new Date(),
    }
    assert.strictEqual(isDiscoveryExpired(response), false)
  })

  it('should return true for past expiry', () => {
    const past = new Date(Date.now() - 3600 * 1000)
    const response: DiscoveryResponse = {
      regions: [],
      expires: past,
      fetchedAt: new Date(),
    }
    assert.strictEqual(isDiscoveryExpired(response), true)
  })

  it('should use default TTL when no expiry', () => {
    // Recent fetch - not expired
    const response: DiscoveryResponse = {
      regions: [],
      fetchedAt: new Date(),
    }
    assert.strictEqual(isDiscoveryExpired(response), false)

    // Old fetch - expired (default 5 min TTL)
    const oldResponse: DiscoveryResponse = {
      regions: [],
      fetchedAt: new Date(Date.now() - 10 * 60 * 1000),
    }
    assert.strictEqual(isDiscoveryExpired(oldResponse), true)
  })
})

// ============================================================================
// RegionLatencyStats Tests
// ============================================================================

describe('RegionLatencyStats', () => {
  it('should add samples and compute average', () => {
    const stats = new RegionLatencyStats('test')
    stats.addSample(10)
    stats.addSample(20)
    stats.addSample(15)

    assert.strictEqual(stats.samples.length, 3)
    assert.strictEqual(stats.getAverageRttMs(), 15)
  })

  it('should maintain rolling window', () => {
    const stats = new RegionLatencyStats('test', 3)
    stats.addSample(10)
    stats.addSample(20)
    stats.addSample(30)
    stats.addSample(40)
    stats.addSample(50)

    // Only last 3 samples: 30, 40, 50
    assert.strictEqual(stats.samples.length, 3)
    assert.strictEqual(stats.getAverageRttMs(), 40)
  })

  it('should record failures and mark unhealthy', () => {
    const stats = new RegionLatencyStats('test')
    assert.strictEqual(stats.health, RegionHealth.unknown)

    // Record failures up to threshold
    stats.recordFailure(3)
    stats.recordFailure(3)
    assert.notStrictEqual(stats.health, RegionHealth.unhealthy)

    // One more failure should mark unhealthy
    stats.recordFailure(3)
    assert.strictEqual(stats.health, RegionHealth.unhealthy)
  })

  it('should reset failures on success', () => {
    const stats = new RegionLatencyStats('test')
    stats.recordFailure()
    stats.recordFailure()
    assert.strictEqual(stats.consecutiveFailures, 2)

    stats.addSample(10)
    assert.strictEqual(stats.consecutiveFailures, 0)
    assert.strictEqual(stats.isHealthy(), true)
  })

  it('should return null for empty stats', () => {
    const stats = new RegionLatencyStats('test')
    assert.strictEqual(stats.getAverageRttMs(), null)
    assert.strictEqual(stats.isHealthy(), true)
  })
})

// ============================================================================
// GeoRoutingMetrics Tests
// ============================================================================

describe('GeoRoutingMetrics', () => {
  it('should record queries', () => {
    const metrics = new GeoRoutingMetrics()
    metrics.recordQuery('us-east-1')
    metrics.recordQuery('us-east-1')
    metrics.recordQuery('eu-west-1')

    assert.strictEqual(metrics.queriesByRegion.get('us-east-1'), 2)
    assert.strictEqual(metrics.queriesByRegion.get('eu-west-1'), 1)
  })

  it('should record switches', () => {
    const metrics = new GeoRoutingMetrics()
    metrics.recordSwitch('us-east-1', 'eu-west-1')
    metrics.recordSwitch('us-east-1', 'eu-west-1')
    metrics.recordSwitch('eu-west-1', 'us-east-1')

    const switches = metrics.regionSwitches.get('us-east-1')
    assert.ok(switches)
    assert.strictEqual(switches.get('eu-west-1'), 2)
  })

  it('should update latencies', () => {
    const metrics = new GeoRoutingMetrics()
    metrics.updateLatency('us-east-1', 25.5)
    metrics.updateLatency('eu-west-1', 85.0)

    assert.strictEqual(metrics.regionLatenciesMs.get('us-east-1'), 25.5)
    assert.strictEqual(metrics.regionLatenciesMs.get('eu-west-1'), 85.0)
  })

  it('should export Prometheus format', () => {
    const metrics = new GeoRoutingMetrics()
    metrics.recordQuery('us-east-1')
    metrics.recordSwitch('us-east-1', 'eu-west-1')
    metrics.updateLatency('us-east-1', 25.0)

    const output = metrics.getPrometheusMetrics()

    assert.ok(output.includes('archerdb_client_queries_total{region="us-east-1"} 1'))
    assert.ok(
      output.includes('archerdb_client_region_switches_total{from="us-east-1",to="eu-west-1"} 1')
    )
    assert.ok(output.includes('archerdb_client_region_latency_ms{region="us-east-1"} 25.0'))
  })
})

// ============================================================================
// RegionDiscoveryClient Tests
// ============================================================================

describe('RegionDiscoveryClient', () => {
  it('should use cached data', async () => {
    const client = new RegionDiscoveryClient('http://localhost:9999/regions')

    // Set up cache
    const cached: DiscoveryResponse = {
      regions: [{ name: 'cached', endpoint: 'cached:5000', location: { latitude: 0, longitude: 0 }, healthy: true }],
      expires: new Date(Date.now() + 3600 * 1000),
      fetchedAt: new Date(),
    }
    ;(client as any)._cache = cached

    const regions = await client.discover()
    assert.strictEqual(regions.length, 1)
    assert.strictEqual(regions[0].name, 'cached')
  })

  it('should return cached on failure', async () => {
    const client = new RegionDiscoveryClient('http://localhost:9999/regions', 100)

    // Set up expired cache but discovery will fail
    const cached: DiscoveryResponse = {
      regions: [{ name: 'stale', endpoint: 'stale:5000', location: { latitude: 0, longitude: 0 }, healthy: true }],
      expires: new Date(Date.now() - 3600 * 1000), // Expired
      fetchedAt: new Date(Date.now() - 3600 * 1000),
    }
    ;(client as any)._cache = cached

    // Should fallback to stale cache on failure
    const regions = await client.discover()
    assert.strictEqual(regions[0].name, 'stale')
  })

  it('should throw when no cache and discovery fails', async () => {
    const client = new RegionDiscoveryClient('http://localhost:9999/regions', 100)

    await assert.rejects(async () => {
      await client.discover()
    }, DiscoveryError)
  })

  it('should get cached regions without fetching', () => {
    const client = new RegionDiscoveryClient('http://localhost:9999/regions')

    // No cache
    assert.strictEqual(client.getCached(), null)

    // With cache
    ;(client as any)._cache = {
      regions: [{ name: 'test', endpoint: 'test:5000', location: { latitude: 0, longitude: 0 }, healthy: true }],
      fetchedAt: new Date(),
    }
    const cached = client.getCached()
    assert.ok(cached)
    assert.strictEqual(cached.length, 1)
  })

  it('should clear cache', () => {
    const client = new RegionDiscoveryClient('http://localhost:9999/regions')
    ;(client as any)._cache = { regions: [], fetchedAt: new Date() }

    client.clearCache()
    assert.strictEqual(client.getCached(), null)
  })
})

// ============================================================================
// LatencyProber Tests
// ============================================================================

describe('LatencyProber', () => {
  it('should set regions', () => {
    const config = createTestConfig()
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()

    prober.setRegions(regions)

    const stats = prober.getAllStats()
    assert.strictEqual(stats.size, 3)
    assert.ok(stats.has('us-east-1'))
    assert.ok(stats.has('us-west-2'))
    assert.ok(stats.has('eu-west-1'))
  })

  it('should get stats for region', () => {
    const config = createTestConfig()
    const prober = new LatencyProber(config)
    prober.setRegions(createSampleRegions())

    const stats = prober.getStats('us-east-1')
    assert.ok(stats)
    assert.strictEqual(stats.regionName, 'us-east-1')

    assert.strictEqual(prober.getStats('invalid'), undefined)
  })
})

// ============================================================================
// RegionSelector Tests
// ============================================================================

describe('RegionSelector', () => {
  it('should select only healthy regions', () => {
    const config = createTestConfig()
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    // Mark one unhealthy
    regions[0].healthy = false

    const region = selector.select(regions)
    assert.ok(region)
    assert.notStrictEqual(region.name, 'us-east-1')
  })

  it('should select preferred region', () => {
    const config = createGeoRoutingConfig({ preferredRegion: 'eu-west-1' })
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    const region = selector.select(regions)
    assert.ok(region)
    assert.strictEqual(region.name, 'eu-west-1')
  })

  it('should fallback when preferred is unhealthy', () => {
    const config = createGeoRoutingConfig({ preferredRegion: 'us-east-1' })
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    regions[0].healthy = false

    const region = selector.select(regions)
    assert.ok(region)
    assert.notStrictEqual(region.name, 'us-east-1')
  })

  it('should select by latency', () => {
    const config = createTestConfig()
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    // Add latency samples
    prober.getStats('us-east-1')!.addSample(100) // Slow
    prober.getStats('us-west-2')!.addSample(20) // Fast
    prober.getStats('eu-west-1')!.addSample(50) // Medium

    const region = selector.select(regions)
    assert.ok(region)
    assert.strictEqual(region.name, 'us-west-2')
  })

  it('should select by distance', () => {
    const config = createTestConfig()
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    // Set client location near Dublin (eu-west-1)
    selector.setClientLocation(53.35, -6.25)

    const region = selector.select(regions)
    assert.ok(region)
    assert.strictEqual(region.name, 'eu-west-1')
  })

  it('should exclude regions', () => {
    const config = createTestConfig()
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    const region = selector.select(regions, ['us-east-1', 'us-west-2'])
    assert.ok(region)
    assert.strictEqual(region.name, 'eu-west-1')
  })

  it('should return null with no healthy regions', () => {
    const config = createTestConfig()
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    for (const r of regions) {
      r.healthy = false
    }

    const region = selector.select(regions)
    assert.strictEqual(region, null)
  })

  it('should handle failover', () => {
    const config = createTestConfig()
    const metrics = new GeoRoutingMetrics()
    const prober = new LatencyProber(config, metrics)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober, metrics)

    selector.select(regions)
    const newRegion = selector.failover('us-east-1', regions)

    assert.ok(newRegion)
    assert.notStrictEqual(newRegion.name, 'us-east-1')
  })

  it('should not failover when disabled', () => {
    const config = createGeoRoutingConfig({ failoverEnabled: false })
    const prober = new LatencyProber(config)
    const regions = createSampleRegions()
    prober.setRegions(regions)
    const selector = new RegionSelector(config, prober)

    const result = selector.failover('us-east-1', regions)
    assert.strictEqual(result, null)
  })
})

// ============================================================================
// GeoRouter Tests
// ============================================================================

describe('GeoRouter', () => {
  it('should use direct connection mode', async () => {
    const router = new GeoRouter({
      directEndpoint: 'direct.example.com:5000',
    })

    const endpoint = await router.start()
    assert.strictEqual(endpoint, 'direct.example.com:5000')
    assert.strictEqual(router.getCurrentRegion(), null)

    router.stop()
  })

  it('should start with cached discovery', async () => {
    const router = new GeoRouter({
      discoveryEndpoint: 'http://localhost:9999/regions',
      backgroundProbing: false,
    })

    // Mock discovery
    const discovery = (router as any)._discovery as RegionDiscoveryClient
    ;(discovery as any)._cache = {
      regions: createSampleRegions(),
      expires: new Date(Date.now() + 3600 * 1000),
      fetchedAt: new Date(),
    }

    const endpoint = await router.start()
    assert.ok(endpoint)
    assert.ok(['us-east-1', 'us-west-2', 'eu-west-1'].includes(router.getCurrentRegion()!))

    router.stop()
  })

  it('should handle failure', async () => {
    const router = new GeoRouter({
      discoveryEndpoint: 'http://localhost:9999/regions',
      failoverEnabled: true,
      backgroundProbing: false,
    })

    const discovery = (router as any)._discovery as RegionDiscoveryClient
    ;(discovery as any)._cache = {
      regions: createSampleRegions(),
      expires: new Date(Date.now() + 3600 * 1000),
      fetchedAt: new Date(),
    }

    await router.start()
    const newEndpoint = router.handleFailure()
    assert.ok(newEndpoint)

    router.stop()
  })

  it('should record metrics', async () => {
    const router = new GeoRouter({
      discoveryEndpoint: 'http://localhost:9999/regions',
      backgroundProbing: false,
    })

    const discovery = (router as any)._discovery as RegionDiscoveryClient
    ;(discovery as any)._cache = {
      regions: createSampleRegions(),
      expires: new Date(Date.now() + 3600 * 1000),
      fetchedAt: new Date(),
    }

    await router.start()
    router.recordQuery()
    router.recordQuery()

    const metrics = router.getMetrics()
    let total = 0
    for (const count of metrics.queriesByRegion.values()) {
      total += count
    }
    assert.strictEqual(total, 2)

    router.stop()
  })

  it('should get regions', async () => {
    const router = new GeoRouter({
      discoveryEndpoint: 'http://localhost:9999/regions',
      backgroundProbing: false,
    })

    const discovery = (router as any)._discovery as RegionDiscoveryClient
    ;(discovery as any)._cache = {
      regions: createSampleRegions(),
      expires: new Date(Date.now() + 3600 * 1000),
      fetchedAt: new Date(),
    }

    await router.start()
    const regions = router.getRegions()
    assert.strictEqual(regions.length, 3)

    router.stop()
  })

  it('should get region stats', async () => {
    const router = new GeoRouter({
      discoveryEndpoint: 'http://localhost:9999/regions',
      backgroundProbing: false,
    })

    const discovery = (router as any)._discovery as RegionDiscoveryClient
    ;(discovery as any)._cache = {
      regions: createSampleRegions(),
      expires: new Date(Date.now() + 3600 * 1000),
      fetchedAt: new Date(),
    }

    await router.start()

    // Add latency data
    const prober = (router as any)._prober as LatencyProber
    prober.getStats('us-east-1')!.addSample(25)

    const stats = router.getRegionStats()
    assert.ok(stats.has('us-east-1'))
    assert.strictEqual(stats.get('us-east-1')!.avgRttMs, 25)

    router.stop()
  })
})

// ============================================================================
// GeoRoutingConfig Tests
// ============================================================================

describe('GeoRoutingConfig', () => {
  it('should check if geo-routing is enabled', () => {
    const enabled = createGeoRoutingConfig({
      discoveryEndpoint: 'http://example.com/regions',
    })
    assert.strictEqual(isGeoRoutingEnabled(enabled), true)

    const disabled = createGeoRoutingConfig({
      directEndpoint: 'host:5000',
    })
    assert.strictEqual(isGeoRoutingEnabled(disabled), false)
  })

  it('should have sensible defaults', () => {
    const config = createGeoRoutingConfig()

    assert.strictEqual(config.failoverEnabled, true)
    assert.strictEqual(config.probeIntervalMs, 30000)
    assert.strictEqual(config.unhealthyThreshold, 3)
    assert.strictEqual(config.backgroundProbing, true)
  })
})
