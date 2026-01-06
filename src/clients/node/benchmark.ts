#!/usr/bin/env npx ts-node
/**
 * ArcherDB Node.js SDK Performance Benchmark
 *
 * This benchmark tests:
 * - Insert throughput (events/sec)
 * - Query latency (p50, p99)
 * - Batch efficiency
 *
 * Target specs from design doc:
 * - Insert: 1M events/sec
 * - UUID lookup: p99 < 500μs
 * - Radius query: p99 < 50ms
 * - Polygon query: p99 < 100ms
 */

import {
  GeoClient,
  GeoClientConfig,
  GeoEvent,
  GeoEventFlags,
  GeoOperation,
  createGeoEvent,
  createRadiusQuery,
  createPolygonQuery,
  BATCH_SIZE_MAX,
} from './src/geo_client'
import { id } from './src/index'

interface BenchmarkResult {
  operation: string
  totalOps: number
  durationMs: number
  opsPerSec: number
  latencyP50Us: number
  latencyP99Us: number
  latencyAvgUs: number
  errors: number
}

function percentile(data: number[], p: number): number {
  if (data.length === 0) return 0
  const sorted = [...data].sort((a, b) => a - b)
  const k = (sorted.length - 1) * p / 100
  const f = Math.floor(k)
  const c = Math.min(f + 1, sorted.length - 1)
  return sorted[f] + (k - f) * (sorted[c] - sorted[f])
}

function mean(data: number[]): number {
  if (data.length === 0) return 0
  return data.reduce((a, b) => a + b, 0) / data.length
}

class ArcherDBBenchmark {
  private clusterId: bigint
  private addresses: string[]
  private warmupEvents: number
  private testEvents: number
  private batchSize: number
  private client: GeoClient | null = null
  private entityIds: bigint[] = []

  constructor(options: {
    clusterId?: bigint
    addresses?: string[]
    warmupEvents?: number
    testEvents?: number
    batchSize?: number
  } = {}) {
    this.clusterId = options.clusterId ?? 0n
    this.addresses = options.addresses ?? ['127.0.0.1:3000']
    this.warmupEvents = options.warmupEvents ?? 1000
    this.testEvents = options.testEvents ?? 100000
    this.batchSize = options.batchSize ?? 1000
  }

  async connect(): Promise<boolean> {
    try {
      const config: GeoClientConfig = {
        cluster_id: this.clusterId,
        addresses: this.addresses,
        retry: {
          enabled: true,
          max_retries: 3,
          base_backoff_ms: 50,
        },
      }
      this.client = await GeoClient.create(config)
      return true
    } catch (e) {
      console.error(`Failed to connect: ${e}`)
      return false
    }
  }

  async disconnect(): Promise<void> {
    if (this.client) {
      await this.client.close()
      this.client = null
    }
  }

  generateRandomEvent(): GeoEvent {
    const entityId = id()
    this.entityIds.push(entityId)

    // Random location in San Francisco area
    const lat = 37.7 + Math.random() * 0.1
    const lon = -122.5 + Math.random() * 0.1

    return createGeoEvent({
      entity_id: entityId,
      latitude: lat,
      longitude: lon,
      velocity_mps: Math.random() * 30,
      heading: Math.random() * 360,
      accuracy_m: Math.random() * 10 + 1,
      ttl_seconds: 86400,
    })
  }

  async benchmarkInsert(): Promise<BenchmarkResult> {
    console.log(`\n[INSERT] Testing with ${this.testEvents} events in batches of ${this.batchSize}`)

    if (!this.client) throw new Error('Client not connected')

    // Warmup
    console.log(`  Warming up with ${this.warmupEvents} events...`)
    for (let i = 0; i < this.warmupEvents; i += this.batchSize) {
      const batch = this.client.createBatch()
      for (let j = 0; j < Math.min(this.batchSize, this.warmupEvents - i); j++) {
        batch.add(this.generateRandomEvent())
      }
      await batch.commit()
    }

    // Actual test
    const latenciesUs: number[] = []
    let errors = 0
    const startTime = performance.now()

    for (let i = 0; i < this.testEvents; i += this.batchSize) {
      const batchStart = performance.now()
      try {
        const batch = this.client.createBatch()
        for (let j = 0; j < Math.min(this.batchSize, this.testEvents - i); j++) {
          batch.add(this.generateRandomEvent())
        }
        const results = await batch.commit()
        errors += results.length
      } catch (e) {
        console.error(`  Batch error: ${e}`)
        errors += this.batchSize
        continue
      }

      const batchEnd = performance.now()
      const batchLatencyUs = (batchEnd - batchStart) * 1000
      latenciesUs.push(batchLatencyUs)

      if ((i + this.batchSize) % 10000 === 0) {
        console.log(`  Progress: ${i + this.batchSize}/${this.testEvents}`)
      }
    }

    const endTime = performance.now()
    const durationMs = endTime - startTime
    const opsPerSec = this.testEvents / (durationMs / 1000)

    return {
      operation: 'INSERT',
      totalOps: this.testEvents,
      durationMs,
      opsPerSec,
      latencyP50Us: percentile(latenciesUs, 50),
      latencyP99Us: percentile(latenciesUs, 99),
      latencyAvgUs: mean(latenciesUs),
      errors,
    }
  }

  async benchmarkQueryUuid(numQueries: number = 10000): Promise<BenchmarkResult> {
    console.log(`\n[QUERY_UUID] Testing with ${numQueries} lookups`)

    if (!this.client) throw new Error('Client not connected')

    if (this.entityIds.length === 0) {
      console.log('  No entity IDs available, skipping...')
      return {
        operation: 'QUERY_UUID',
        totalOps: 0,
        durationMs: 0,
        opsPerSec: 0,
        latencyP50Us: 0,
        latencyP99Us: 0,
        latencyAvgUs: 0,
        errors: 0,
      }
    }

    // Warmup
    console.log('  Warming up...')
    for (let i = 0; i < Math.min(100, this.entityIds.length); i++) {
      const entityId = this.entityIds[Math.floor(Math.random() * this.entityIds.length)]
      await this.client.getLatestByUuid(entityId)
    }

    // Actual test
    const latenciesUs: number[] = []
    let errors = 0
    const startTime = performance.now()

    for (let i = 0; i < numQueries; i++) {
      const entityId = this.entityIds[Math.floor(Math.random() * this.entityIds.length)]
      const queryStart = performance.now()
      try {
        const result = await this.client.getLatestByUuid(entityId)
        if (result === null) {
          errors++
        }
      } catch (e) {
        errors++
        continue
      }

      const queryEnd = performance.now()
      const latencyUs = (queryEnd - queryStart) * 1000
      latenciesUs.push(latencyUs)

      if ((i + 1) % 1000 === 0) {
        console.log(`  Progress: ${i + 1}/${numQueries}`)
      }
    }

    const endTime = performance.now()
    const durationMs = endTime - startTime
    const opsPerSec = numQueries / (durationMs / 1000)

    return {
      operation: 'QUERY_UUID',
      totalOps: numQueries,
      durationMs,
      opsPerSec,
      latencyP50Us: percentile(latenciesUs, 50),
      latencyP99Us: percentile(latenciesUs, 99),
      latencyAvgUs: mean(latenciesUs),
      errors,
    }
  }

  async benchmarkQueryRadius(numQueries: number = 1000): Promise<BenchmarkResult> {
    console.log(`\n[QUERY_RADIUS] Testing with ${numQueries} queries`)

    if (!this.client) throw new Error('Client not connected')

    // Warmup
    console.log('  Warming up...')
    for (let i = 0; i < Math.min(10, numQueries); i++) {
      const lat = 37.7 + Math.random() * 0.1
      const lon = -122.5 + Math.random() * 0.1
      await this.client.queryRadius(lat, lon, 1000, { limit: 100 })
    }

    // Actual test
    const latenciesUs: number[] = []
    let errors = 0
    const startTime = performance.now()

    for (let i = 0; i < numQueries; i++) {
      const lat = 37.7 + Math.random() * 0.1
      const lon = -122.5 + Math.random() * 0.1
      const radiusM = 100 + Math.random() * 2000 // 100m to 2km

      const queryStart = performance.now()
      try {
        await this.client.queryRadius(lat, lon, radiusM, { limit: 1000 })
      } catch (e) {
        errors++
        continue
      }

      const queryEnd = performance.now()
      const latencyUs = (queryEnd - queryStart) * 1000
      latenciesUs.push(latencyUs)

      if ((i + 1) % 100 === 0) {
        console.log(`  Progress: ${i + 1}/${numQueries}`)
      }
    }

    const endTime = performance.now()
    const durationMs = endTime - startTime
    const opsPerSec = numQueries / (durationMs / 1000)

    return {
      operation: 'QUERY_RADIUS',
      totalOps: numQueries,
      durationMs,
      opsPerSec,
      latencyP50Us: percentile(latenciesUs, 50),
      latencyP99Us: percentile(latenciesUs, 99),
      latencyAvgUs: mean(latenciesUs),
      errors,
    }
  }

  async benchmarkQueryPolygon(numQueries: number = 500): Promise<BenchmarkResult> {
    console.log(`\n[QUERY_POLYGON] Testing with ${numQueries} queries`)

    if (!this.client) throw new Error('Client not connected')

    // Warmup
    console.log('  Warming up...')
    for (let i = 0; i < Math.min(5, numQueries); i++) {
      const lat = 37.7 + Math.random() * 0.05
      const lon = -122.5 + Math.random() * 0.05
      const size = 0.01 + Math.random() * 0.02
      const vertices: [number, number][] = [
        [lat, lon],
        [lat + size, lon],
        [lat + size, lon + size],
        [lat, lon + size],
      ]
      await this.client.queryPolygon(vertices, { limit: 100 })
    }

    // Actual test
    const latenciesUs: number[] = []
    let errors = 0
    const startTime = performance.now()

    for (let i = 0; i < numQueries; i++) {
      const lat = 37.7 + Math.random() * 0.05
      const lon = -122.5 + Math.random() * 0.05
      const size = 0.01 + Math.random() * 0.02
      const vertices: [number, number][] = [
        [lat, lon],
        [lat + size, lon],
        [lat + size, lon + size],
        [lat, lon + size],
      ]

      const queryStart = performance.now()
      try {
        await this.client.queryPolygon(vertices, { limit: 1000 })
      } catch (e) {
        errors++
        continue
      }

      const queryEnd = performance.now()
      const latencyUs = (queryEnd - queryStart) * 1000
      latenciesUs.push(latencyUs)

      if ((i + 1) % 50 === 0) {
        console.log(`  Progress: ${i + 1}/${numQueries}`)
      }
    }

    const endTime = performance.now()
    const durationMs = endTime - startTime
    const opsPerSec = numQueries / (durationMs / 1000)

    return {
      operation: 'QUERY_POLYGON',
      totalOps: numQueries,
      durationMs,
      opsPerSec,
      latencyP50Us: percentile(latenciesUs, 50),
      latencyP99Us: percentile(latenciesUs, 99),
      latencyAvgUs: mean(latenciesUs),
      errors,
    }
  }

  printResult(result: BenchmarkResult): void {
    console.log(`\n${'='.repeat(60)}`)
    console.log(`  ${result.operation} Results`)
    console.log(`${'='.repeat(60)}`)
    console.log(`  Total operations:  ${result.totalOps.toLocaleString()}`)
    console.log(`  Duration:          ${result.durationMs.toFixed(2)} ms`)
    console.log(`  Throughput:        ${result.opsPerSec.toLocaleString(undefined, { maximumFractionDigits: 2 })} ops/sec`)
    console.log(`  Latency p50:       ${result.latencyP50Us.toFixed(2)} μs`)
    console.log(`  Latency p99:       ${result.latencyP99Us.toFixed(2)} μs`)
    console.log(`  Latency avg:       ${result.latencyAvgUs.toFixed(2)} μs`)
    console.log(`  Errors:            ${result.errors}`)
    console.log(`${'='.repeat(60)}`)
  }

  async run(): Promise<void> {
    console.log('\n' + '='.repeat(60))
    console.log('  ArcherDB Node.js SDK Performance Benchmark')
    console.log('='.repeat(60))
    console.log(`  Cluster ID: ${this.clusterId}`)
    console.log(`  Addresses:  ${this.addresses.join(', ')}`)
    console.log(`  Test events: ${this.testEvents.toLocaleString()}`)
    console.log(`  Batch size: ${this.batchSize}`)
    console.log('='.repeat(60))

    if (!(await this.connect())) {
      console.log('Failed to connect to cluster, exiting.')
      return
    }

    try {
      const results: BenchmarkResult[] = []

      const insertResult = await this.benchmarkInsert()
      this.printResult(insertResult)
      results.push(insertResult)

      const uuidResult = await this.benchmarkQueryUuid()
      this.printResult(uuidResult)
      results.push(uuidResult)

      const radiusResult = await this.benchmarkQueryRadius()
      this.printResult(radiusResult)
      results.push(radiusResult)

      const polygonResult = await this.benchmarkQueryPolygon()
      this.printResult(polygonResult)
      results.push(polygonResult)

      // Summary
      console.log('\n' + '='.repeat(60))
      console.log('  SUMMARY')
      console.log('='.repeat(60))
      for (const r of results) {
        const status = r.errors === 0 ? 'PASS' : `FAIL (${r.errors} errors)`
        console.log(`  ${r.operation.padEnd(15)} ${r.opsPerSec.toLocaleString(undefined, { maximumFractionDigits: 0 }).padStart(12)} ops/sec  [${status}]`)
      }
      console.log('='.repeat(60))
    } finally {
      await this.disconnect()
    }
  }
}

// Parse command line arguments
const args = process.argv.slice(2)
let clusterId = 0n
let addresses = ['127.0.0.1:3000']
let testEvents = 100000
let batchSize = 1000
let warmupEvents = 1000

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--cluster-id':
      clusterId = BigInt(args[++i])
      break
    case '--addresses':
      addresses = args[++i].split(',')
      break
    case '--events':
      testEvents = parseInt(args[++i])
      break
    case '--batch-size':
      batchSize = parseInt(args[++i])
      break
    case '--warmup':
      warmupEvents = parseInt(args[++i])
      break
    case '--help':
      console.log(`
ArcherDB Node.js SDK Performance Benchmark

Usage: npx ts-node benchmark.ts [options]

Options:
  --cluster-id <id>     Cluster ID (default: 0)
  --addresses <addr>    Comma-separated replica addresses (default: 127.0.0.1:3000)
  --events <n>          Number of test events (default: 100000)
  --batch-size <n>      Batch size for inserts (default: 1000)
  --warmup <n>          Number of warmup events (default: 1000)
  --help                Show this help
`)
      process.exit(0)
  }
}

const benchmark = new ArcherDBBenchmark({
  clusterId,
  addresses,
  warmupEvents,
  testEvents,
  batchSize,
})

benchmark.run().catch(console.error)
