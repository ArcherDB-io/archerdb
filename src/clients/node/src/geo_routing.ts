/**
 * ArcherDB Node.js SDK - Geo-Routing Client
 *
 * This module provides geo-routing functionality including:
 * - Region discovery from /regions endpoint
 * - Latency probing with rolling averages
 * - Region selection based on latency and health
 * - Automatic failover to backup regions
 * - Metrics for monitoring
 */

import * as net from 'net'

// ============================================================================
// Configuration
// ============================================================================

const DEFAULT_PROBE_INTERVAL_MS = 30_000 // 30 seconds
const DEFAULT_FAILOVER_TIMEOUT_MS = 5_000 // 5 seconds
const DEFAULT_PROBE_SAMPLE_COUNT = 5 // Rolling average window
const DEFAULT_UNHEALTHY_THRESHOLD = 3 // Consecutive failures before unhealthy

/**
 * Configuration for geo-routing behavior.
 */
export interface GeoRoutingConfig {
  /** Discovery endpoint URL (e.g., "https://archerdb.example.com/regions") */
  discoveryEndpoint?: string

  /** Direct endpoint for non-geo-routed connections */
  directEndpoint?: string

  /** Preferred region name (optional) */
  preferredRegion?: string

  /** Enable automatic failover to backup regions */
  failoverEnabled?: boolean

  /** Interval between latency probes (milliseconds) */
  probeIntervalMs?: number

  /** Timeout for failover operations (milliseconds) */
  failoverTimeoutMs?: number

  /** Number of samples for rolling latency average */
  probeSampleCount?: number

  /** Consecutive failures before marking region unhealthy */
  unhealthyThreshold?: number

  /** Enable probing in background */
  backgroundProbing?: boolean
}

/**
 * Creates a default geo-routing config with sensible defaults.
 */
export function createGeoRoutingConfig(
  options: Partial<GeoRoutingConfig> = {}
): Required<GeoRoutingConfig> {
  return {
    discoveryEndpoint: options.discoveryEndpoint ?? '',
    directEndpoint: options.directEndpoint ?? '',
    preferredRegion: options.preferredRegion ?? '',
    failoverEnabled: options.failoverEnabled ?? true,
    probeIntervalMs: options.probeIntervalMs ?? DEFAULT_PROBE_INTERVAL_MS,
    failoverTimeoutMs: options.failoverTimeoutMs ?? DEFAULT_FAILOVER_TIMEOUT_MS,
    probeSampleCount: options.probeSampleCount ?? DEFAULT_PROBE_SAMPLE_COUNT,
    unhealthyThreshold: options.unhealthyThreshold ?? DEFAULT_UNHEALTHY_THRESHOLD,
    backgroundProbing: options.backgroundProbing ?? true,
  }
}

/**
 * Check if geo-routing is enabled (has discovery endpoint).
 */
export function isGeoRoutingEnabled(config: GeoRoutingConfig): boolean {
  return Boolean(config.discoveryEndpoint)
}

// ============================================================================
// Region Data Types
// ============================================================================

/**
 * Health status of a region.
 */
export enum RegionHealth {
  healthy = 0,
  degraded = 1,
  unhealthy = 2,
  unknown = 3,
}

/**
 * Geographic location of a region.
 */
export interface RegionLocation {
  latitude: number
  longitude: number
}

/**
 * Information about a single region from the /regions endpoint.
 */
export interface RegionInfo {
  name: string
  endpoint: string
  location: RegionLocation
  healthy: boolean
}

/**
 * Parse RegionInfo from JSON object.
 */
export function parseRegionInfo(data: Record<string, unknown>): RegionInfo {
  const location: RegionLocation = {
    latitude: 0,
    longitude: 0,
  }

  if (data.location && typeof data.location === 'object') {
    const loc = data.location as Record<string, unknown>
    location.latitude = Number(loc.lat ?? loc.latitude ?? 0)
    location.longitude = Number(loc.lon ?? loc.longitude ?? 0)
  }

  return {
    name: String(data.name ?? ''),
    endpoint: String(data.endpoint ?? ''),
    location,
    healthy: Boolean(data.healthy ?? true),
  }
}

/**
 * Response from the /regions discovery endpoint.
 */
export interface DiscoveryResponse {
  regions: RegionInfo[]
  expires?: Date
  fetchedAt: Date
}

/**
 * Parse DiscoveryResponse from JSON object.
 */
export function parseDiscoveryResponse(data: Record<string, unknown>): DiscoveryResponse {
  const regions: RegionInfo[] = []

  if (Array.isArray(data.regions)) {
    for (const r of data.regions) {
      if (r && typeof r === 'object') {
        regions.push(parseRegionInfo(r as Record<string, unknown>))
      }
    }
  }

  let expires: Date | undefined
  if (typeof data.expires === 'string') {
    try {
      expires = new Date(data.expires)
    } catch {
      // Ignore invalid dates
    }
  }

  return {
    regions,
    expires,
    fetchedAt: new Date(),
  }
}

/**
 * Check if a discovery response is expired.
 */
export function isDiscoveryExpired(response: DiscoveryResponse): boolean {
  const now = new Date()

  if (response.expires) {
    return now > response.expires
  }

  // Default 5 minute TTL
  const defaultTtlMs = 5 * 60 * 1000
  return now.getTime() - response.fetchedAt.getTime() > defaultTtlMs
}

// ============================================================================
// Latency Tracking
// ============================================================================

/**
 * Single latency measurement.
 */
export interface LatencyMeasurement {
  rttMs: number
  timestamp: number
}

/**
 * Latency statistics for a region.
 */
export class RegionLatencyStats {
  regionName: string
  samples: LatencyMeasurement[] = []
  maxSamples: number
  lastProbeTime = 0
  consecutiveFailures = 0
  health = RegionHealth.unknown

  constructor(regionName: string, maxSamples = DEFAULT_PROBE_SAMPLE_COUNT) {
    this.regionName = regionName
    this.maxSamples = maxSamples
  }

  /**
   * Add a latency sample.
   */
  addSample(rttMs: number): void {
    this.samples.push({ rttMs, timestamp: Date.now() })
    if (this.samples.length > this.maxSamples) {
      this.samples.shift()
    }
    this.lastProbeTime = Date.now()
    this.consecutiveFailures = 0
    if (this.health === RegionHealth.unhealthy || this.health === RegionHealth.unknown) {
      this.health = RegionHealth.healthy
    }
  }

  /**
   * Record a probe failure.
   */
  recordFailure(threshold = DEFAULT_UNHEALTHY_THRESHOLD): void {
    this.consecutiveFailures++
    this.lastProbeTime = Date.now()
    if (this.consecutiveFailures >= threshold) {
      this.health = RegionHealth.unhealthy
    }
  }

  /**
   * Get rolling average RTT in milliseconds.
   */
  getAverageRttMs(): number | null {
    if (this.samples.length === 0) {
      return null
    }
    const sum = this.samples.reduce((acc, s) => acc + s.rttMs, 0)
    return sum / this.samples.length
  }

  /**
   * Check if region is healthy.
   */
  isHealthy(): boolean {
    return this.health === RegionHealth.healthy || this.health === RegionHealth.unknown
  }
}

// ============================================================================
// Geo-Routing Metrics
// ============================================================================

/**
 * Metrics for geo-routing operations.
 */
export class GeoRoutingMetrics {
  private _queriesByRegion = new Map<string, number>()
  private _regionSwitches = new Map<string, Map<string, number>>()
  private _regionLatenciesMs = new Map<string, number>()

  /**
   * Record a query to a region.
   */
  recordQuery(region: string): void {
    const count = this._queriesByRegion.get(region) ?? 0
    this._queriesByRegion.set(region, count + 1)
  }

  /**
   * Record a region switch (failover).
   */
  recordSwitch(fromRegion: string, toRegion: string): void {
    if (!this._regionSwitches.has(fromRegion)) {
      this._regionSwitches.set(fromRegion, new Map())
    }
    const switches = this._regionSwitches.get(fromRegion)!
    const count = switches.get(toRegion) ?? 0
    switches.set(toRegion, count + 1)
  }

  /**
   * Update the latency measurement for a region.
   */
  updateLatency(region: string, latencyMs: number): void {
    this._regionLatenciesMs.set(region, latencyMs)
  }

  /**
   * Get queries by region.
   */
  get queriesByRegion(): ReadonlyMap<string, number> {
    return this._queriesByRegion
  }

  /**
   * Get region switches.
   */
  get regionSwitches(): ReadonlyMap<string, ReadonlyMap<string, number>> {
    return this._regionSwitches
  }

  /**
   * Get region latencies.
   */
  get regionLatenciesMs(): ReadonlyMap<string, number> {
    return this._regionLatenciesMs
  }

  /**
   * Export metrics in Prometheus format.
   */
  getPrometheusMetrics(): string {
    const lines: string[] = []

    // Query counts
    for (const [region, count] of this._queriesByRegion) {
      lines.push(`archerdb_client_queries_total{region="${region}"} ${count}`)
    }

    // Region switches
    for (const [fromR, toDict] of this._regionSwitches) {
      for (const [toR, count] of toDict) {
        lines.push(
          `archerdb_client_region_switches_total{from="${fromR}",to="${toR}"} ${count}`
        )
      }
    }

    // Latencies
    for (const [region, latency] of this._regionLatenciesMs) {
      lines.push(`archerdb_client_region_latency_ms{region="${region}"} ${latency.toFixed(1)}`)
    }

    return lines.join('\n')
  }
}

// ============================================================================
// Region Discovery Client
// ============================================================================

/**
 * Error during region discovery.
 */
export class DiscoveryError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'DiscoveryError'
  }
}

/**
 * Client for discovering available regions.
 */
export class RegionDiscoveryClient {
  private _endpoint: string
  private _timeoutMs: number
  private _cache: DiscoveryResponse | null = null

  constructor(discoveryEndpoint: string, timeoutMs = 5000) {
    this._endpoint = discoveryEndpoint
    this._timeoutMs = timeoutMs
  }

  /**
   * Discover available regions.
   */
  async discover(forceRefresh = false): Promise<RegionInfo[]> {
    // Check cache
    if (!forceRefresh && this._cache && !isDiscoveryExpired(this._cache)) {
      return this._cache.regions
    }

    try {
      const response = await this._fetch()
      this._cache = response
      return response.regions
    } catch (e) {
      // Try to use cached data if available
      if (this._cache) {
        return this._cache.regions
      }
      throw new DiscoveryError(`Discovery failed and no cache available: ${e}`)
    }
  }

  private async _fetch(): Promise<DiscoveryResponse> {
    const controller = new AbortController()
    const timeoutId = setTimeout(() => controller.abort(), this._timeoutMs)

    try {
      const response = await fetch(this._endpoint, {
        signal: controller.signal,
      })

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`)
      }

      const data = (await response.json()) as Record<string, unknown>
      return parseDiscoveryResponse(data)
    } finally {
      clearTimeout(timeoutId)
    }
  }

  /**
   * Get cached regions without fetching.
   */
  getCached(): RegionInfo[] | null {
    return this._cache?.regions ?? null
  }

  /**
   * Clear the cached discovery response.
   */
  clearCache(): void {
    this._cache = null
  }
}

// ============================================================================
// Latency Prober
// ============================================================================

/**
 * Background latency prober for regions.
 */
export class LatencyProber {
  private _config: Required<GeoRoutingConfig>
  private _metrics: GeoRoutingMetrics
  private _regions: RegionInfo[] = []
  private _stats = new Map<string, RegionLatencyStats>()
  private _running = false
  private _intervalId: ReturnType<typeof setInterval> | null = null

  constructor(config: Required<GeoRoutingConfig>, metrics?: GeoRoutingMetrics) {
    this._config = config
    this._metrics = metrics ?? new GeoRoutingMetrics()
  }

  /**
   * Set the regions to probe.
   */
  setRegions(regions: RegionInfo[]): void {
    this._regions = regions
    for (const region of regions) {
      if (!this._stats.has(region.name)) {
        this._stats.set(
          region.name,
          new RegionLatencyStats(region.name, this._config.probeSampleCount)
        )
      }
    }
  }

  /**
   * Start background probing.
   */
  start(): void {
    if (!this._config.backgroundProbing || this._running) {
      return
    }

    this._running = true
    this._intervalId = setInterval(() => {
      this._probeAllRegions().catch(() => {
        // Ignore probe errors
      })
    }, this._config.probeIntervalMs)
  }

  /**
   * Stop background probing.
   */
  stop(): void {
    if (!this._running) {
      return
    }

    this._running = false
    if (this._intervalId) {
      clearInterval(this._intervalId)
      this._intervalId = null
    }
  }

  private async _probeAllRegions(): Promise<void> {
    for (const region of this._regions) {
      try {
        const rttMs = await this._probeRegion(region)
        const stats = this._stats.get(region.name)
        if (stats) {
          stats.addSample(rttMs)
          this._metrics.updateLatency(region.name, stats.getAverageRttMs() ?? rttMs)
        }
      } catch {
        const stats = this._stats.get(region.name)
        if (stats) {
          stats.recordFailure(this._config.unhealthyThreshold)
        }
      }
    }
  }

  private async _probeRegion(region: RegionInfo): Promise<number> {
    // Parse endpoint
    let endpoint = region.endpoint
    if (endpoint.includes('://')) {
      endpoint = endpoint.split('://')[1]
    }
    if (endpoint.includes('/')) {
      endpoint = endpoint.split('/')[0]
    }

    const parts = endpoint.split(':')
    const host = parts[0]
    const port = parts.length > 1 ? parseInt(parts[1], 10) : 5000

    // Measure TCP connect time
    return new Promise((resolve, reject) => {
      const start = Date.now()
      const socket = new net.Socket()

      socket.setTimeout(this._config.failoverTimeoutMs)

      socket.on('connect', () => {
        const rttMs = Date.now() - start
        socket.destroy()
        resolve(rttMs)
      })

      socket.on('error', (err) => {
        socket.destroy()
        reject(err)
      })

      socket.on('timeout', () => {
        socket.destroy()
        reject(new Error('Connection timeout'))
      })

      socket.connect(port, host)
    })
  }

  /**
   * Get latency stats for a region.
   */
  getStats(regionName: string): RegionLatencyStats | undefined {
    return this._stats.get(regionName)
  }

  /**
   * Get latency stats for all regions.
   */
  getAllStats(): Map<string, RegionLatencyStats> {
    return new Map(this._stats)
  }

  /**
   * Probe a specific region immediately.
   */
  async probeNow(regionName: string): Promise<number | null> {
    const region = this._regions.find((r) => r.name === regionName)
    if (!region) {
      return null
    }

    try {
      const rttMs = await this._probeRegion(region)
      const stats = this._stats.get(regionName)
      if (stats) {
        stats.addSample(rttMs)
        this._metrics.updateLatency(regionName, stats.getAverageRttMs() ?? rttMs)
      }
      return rttMs
    } catch {
      const stats = this._stats.get(regionName)
      if (stats) {
        stats.recordFailure(this._config.unhealthyThreshold)
      }
      return null
    }
  }
}

// ============================================================================
// Region Selector
// ============================================================================

/**
 * Selects optimal region based on latency and health.
 */
export class RegionSelector {
  private _config: Required<GeoRoutingConfig>
  private _prober: LatencyProber
  private _metrics: GeoRoutingMetrics
  private _clientLocation: { latitude: number; longitude: number } | null = null
  private _currentRegion: string | null = null

  constructor(
    config: Required<GeoRoutingConfig>,
    prober: LatencyProber,
    metrics?: GeoRoutingMetrics
  ) {
    this._config = config
    this._prober = prober
    this._metrics = metrics ?? new GeoRoutingMetrics()
  }

  /**
   * Set the client's geographic location for distance-based selection.
   */
  setClientLocation(latitude: number, longitude: number): void {
    this._clientLocation = { latitude, longitude }
  }

  /**
   * Select the optimal region.
   */
  select(regions: RegionInfo[], exclude: string[] = []): RegionInfo | null {
    // Filter to healthy regions
    let healthy = regions.filter((r) => r.healthy && !exclude.includes(r.name))

    // Also check our own health tracking
    healthy = healthy.filter((r) => {
      const stats = this._prober.getStats(r.name)
      return !stats || stats.isHealthy()
    })

    if (healthy.length === 0) {
      return null
    }

    // Apply region preference
    if (this._config.preferredRegion) {
      const preferred = healthy.find((r) => r.name === this._config.preferredRegion)
      if (preferred) {
        return preferred
      }
    }

    // Select by latency
    const region = this._selectByLatency(healthy)
    if (region && region.name !== this._currentRegion) {
      if (this._currentRegion) {
        this._metrics.recordSwitch(this._currentRegion, region.name)
      }
      this._currentRegion = region.name
    }

    return region
  }

  private _selectByLatency(regions: RegionInfo[]): RegionInfo | null {
    // Get latency for each region
    const latencies: Array<{ region: RegionInfo; rtt: number }> = []

    for (const region of regions) {
      const stats = this._prober.getStats(region.name)
      if (stats) {
        const rtt = stats.getAverageRttMs()
        if (rtt !== null) {
          latencies.push({ region, rtt })
        }
      }
    }

    if (latencies.length > 0) {
      latencies.sort((a, b) => a.rtt - b.rtt)
      return latencies[0].region
    }

    // No latency data - use geographic distance if available
    if (this._clientLocation) {
      return this._selectByDistance(regions)
    }

    // No measurements and no location - return first region
    return regions[0] ?? null
  }

  private _selectByDistance(regions: RegionInfo[]): RegionInfo | null {
    if (!this._clientLocation) {
      return regions[0] ?? null
    }

    const distances: Array<{ region: RegionInfo; distance: number }> = []

    for (const region of regions) {
      const dist = this._haversineDistance(
        this._clientLocation.latitude,
        this._clientLocation.longitude,
        region.location.latitude,
        region.location.longitude
      )
      distances.push({ region, distance: dist })
    }

    if (distances.length > 0) {
      distances.sort((a, b) => a.distance - b.distance)
      return distances[0].region
    }

    return regions[0] ?? null
  }

  private _haversineDistance(
    lat1: number,
    lon1: number,
    lat2: number,
    lon2: number
  ): number {
    const R = 6371 // Earth radius in km
    const dLat = this._toRadians(lat2 - lat1)
    const dLon = this._toRadians(lon2 - lon1)
    const a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(this._toRadians(lat1)) *
        Math.cos(this._toRadians(lat2)) *
        Math.sin(dLon / 2) *
        Math.sin(dLon / 2)
    const c = 2 * Math.asin(Math.sqrt(a))
    return R * c
  }

  private _toRadians(degrees: number): number {
    return degrees * (Math.PI / 180)
  }

  /**
   * Select a failover region.
   */
  failover(currentRegion: string, regions: RegionInfo[]): RegionInfo | null {
    if (!this._config.failoverEnabled) {
      return null
    }

    // Mark current region as unhealthy
    const stats = this._prober.getStats(currentRegion)
    if (stats) {
      stats.health = RegionHealth.unhealthy
    }

    // Select new region excluding current
    const newRegion = this.select(regions, [currentRegion])

    if (newRegion) {
      this._metrics.recordSwitch(currentRegion, newRegion.name)
    }

    return newRegion
  }

  /**
   * Get the currently selected region name.
   */
  getCurrentRegion(): string | null {
    return this._currentRegion
  }
}

// ============================================================================
// Main Geo-Router Class
// ============================================================================

/**
 * Main geo-routing coordinator.
 */
export class GeoRouter {
  private _config: Required<GeoRoutingConfig>
  private _metrics: GeoRoutingMetrics
  private _discovery: RegionDiscoveryClient | null = null
  private _prober: LatencyProber | null = null
  private _selector: RegionSelector | null = null
  private _regions: RegionInfo[] = []
  private _currentEndpoint: string | null = null
  private _started = false

  constructor(config: GeoRoutingConfig) {
    this._config = createGeoRoutingConfig(config)
    this._metrics = new GeoRoutingMetrics()

    if (this._config.discoveryEndpoint) {
      this._discovery = new RegionDiscoveryClient(
        this._config.discoveryEndpoint,
        this._config.failoverTimeoutMs
      )
      this._prober = new LatencyProber(this._config, this._metrics)
      this._selector = new RegionSelector(this._config, this._prober, this._metrics)
    }
  }

  /**
   * Start geo-routing.
   */
  async start(): Promise<string> {
    if (!isGeoRoutingEnabled(this._config)) {
      // Direct connection mode
      this._currentEndpoint = this._config.directEndpoint
      return this._currentEndpoint || ''
    }

    // Discover regions
    if (this._discovery) {
      this._regions = await this._discovery.discover()
    }

    // Start prober
    if (this._prober && this._regions.length > 0) {
      this._prober.setRegions(this._regions)
      this._prober.start()
    }

    // Select initial region
    if (this._selector && this._regions.length > 0) {
      const region = this._selector.select(this._regions)
      if (region) {
        this._currentEndpoint = region.endpoint
      }
    }

    this._started = true
    return this._currentEndpoint || ''
  }

  /**
   * Stop geo-routing and cleanup.
   */
  stop(): void {
    if (this._prober) {
      this._prober.stop()
    }
    this._started = false
  }

  /**
   * Get the current endpoint.
   */
  getEndpoint(): string {
    return this._currentEndpoint || ''
  }

  /**
   * Get the current region name.
   */
  getCurrentRegion(): string | null {
    return this._selector?.getCurrentRegion() ?? null
  }

  /**
   * Handle connection failure by triggering failover.
   */
  handleFailure(): string | null {
    if (!this._config.failoverEnabled) {
      return null
    }

    const currentRegion = this.getCurrentRegion()
    if (!currentRegion || !this._selector) {
      return null
    }

    const newRegion = this._selector.failover(currentRegion, this._regions)
    if (newRegion) {
      this._currentEndpoint = newRegion.endpoint
      return this._currentEndpoint
    }

    return null
  }

  /**
   * Record a query for metrics.
   */
  recordQuery(): void {
    const region = this.getCurrentRegion()
    if (region) {
      this._metrics.recordQuery(region)
    }
  }

  /**
   * Get the metrics object.
   */
  getMetrics(): GeoRoutingMetrics {
    return this._metrics
  }

  /**
   * Force refresh of region discovery.
   */
  async refreshRegions(): Promise<void> {
    if (this._discovery) {
      try {
        this._regions = await this._discovery.discover(true)
        if (this._prober) {
          this._prober.setRegions(this._regions)
        }
      } catch {
        // Ignore refresh errors
      }
    }
  }

  /**
   * Get the list of discovered regions.
   */
  getRegions(): RegionInfo[] {
    return [...this._regions]
  }

  /**
   * Get detailed stats for all regions.
   */
  getRegionStats(): Map<string, Record<string, unknown>> {
    const result = new Map<string, Record<string, unknown>>()
    if (this._prober) {
      for (const [name, stats] of this._prober.getAllStats()) {
        result.set(name, {
          health: RegionHealth[stats.health],
          avgRttMs: stats.getAverageRttMs(),
          consecutiveFailures: stats.consecutiveFailures,
          sampleCount: stats.samples.length,
        })
      }
    }
    return result
  }
}
