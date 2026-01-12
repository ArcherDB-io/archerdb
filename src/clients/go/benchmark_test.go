// ArcherDB Go SDK Performance Benchmark
//
// This benchmark tests:
// - Insert throughput (events/sec)
// - Query latency (p50, p99)
// - Batch efficiency
//
// Target specs from design doc:
// - Insert: 1M events/sec
// - UUID lookup: p99 < 500μs
// - Radius query: p99 < 50ms
// - Polygon query: p99 < 100ms
//
// Run with: go test -bench=. -benchtime=10s ./...

package archerdb

import (
	"flag"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/archerdb/archerdb-go/pkg/types"
)

var (
	benchClusterID = flag.Uint64("cluster-id", 0, "Cluster ID")
	benchAddresses = flag.String("addresses", "127.0.0.1:3000", "Comma-separated replica addresses")
	benchEvents    = flag.Int("events", 100000, "Number of test events")
	benchBatchSize = flag.Int("batch-size", 1000, "Batch size for inserts")
	benchWarmup    = flag.Int("warmup", 1000, "Number of warmup events")
)

type benchmarkResult struct {
	Operation    string
	TotalOps     int
	DurationMs   float64
	OpsPerSec    float64
	LatencyP50Us float64
	LatencyP99Us float64
	LatencyAvgUs float64
	Errors       int
}

func percentile(data []float64, p float64) float64 {
	if len(data) == 0 {
		return 0
	}
	sorted := make([]float64, len(data))
	copy(sorted, data)
	sort.Float64s(sorted)

	k := float64(len(sorted)-1) * p / 100
	f := int(k)
	c := f + 1
	if c >= len(sorted) {
		c = len(sorted) - 1
	}
	return sorted[f] + (k-float64(f))*(sorted[c]-sorted[f])
}

func mean(data []float64) float64 {
	if len(data) == 0 {
		return 0
	}
	var sum float64
	for _, v := range data {
		sum += v
	}
	return sum / float64(len(data))
}

// ArcherDBBenchmark runs performance benchmarks against an ArcherDB cluster.
type ArcherDBBenchmark struct {
	clusterID    types.Uint128
	addresses    []string
	warmupEvents int
	testEvents   int
	batchSize    int
	client       GeoClient
	entityIDs    []types.Uint128
}

// NewArcherDBBenchmark creates a new benchmark instance.
func NewArcherDBBenchmark(clusterID uint64, addresses []string, warmupEvents, testEvents, batchSize int) *ArcherDBBenchmark {
	return &ArcherDBBenchmark{
		clusterID:    types.ToUint128(clusterID),
		addresses:    addresses,
		warmupEvents: warmupEvents,
		testEvents:   testEvents,
		batchSize:    batchSize,
		entityIDs:    make([]types.Uint128, 0),
	}
}

func (b *ArcherDBBenchmark) connect() error {
	config := GeoClientConfig{
		ClusterID: b.clusterID,
		Addresses: b.addresses,
		Retry: &RetryConfig{
			Enabled:      true,
			MaxRetries:   3,
			BaseBackoff:  50 * time.Millisecond,
			MaxBackoff:   1600 * time.Millisecond,
			TotalTimeout: 30 * time.Second,
			Jitter:       true,
		},
	}

	client, err := NewGeoClient(config)
	if err != nil {
		return err
	}
	b.client = client
	return nil
}

func (b *ArcherDBBenchmark) disconnect() {
	if b.client != nil {
		b.client.Close()
		b.client = nil
	}
}

func (b *ArcherDBBenchmark) generateRandomEvent() types.GeoEvent {
	entityID := types.ID()
	b.entityIDs = append(b.entityIDs, entityID)

	// Random location in San Francisco area
	lat := 37.7 + rand.Float64()*0.1
	lon := -122.5 + rand.Float64()*0.1

	event, _ := types.NewGeoEvent(types.GeoEventOptions{
		EntityID:    entityID,
		Latitude:    lat,
		Longitude:   lon,
		VelocityMPS: rand.Float64() * 30,
		Heading:     rand.Float64() * 360,
		AccuracyM:   rand.Float64()*10 + 1,
		TTLSeconds:  86400,
	})

	return event
}

func (b *ArcherDBBenchmark) benchmarkInsert() benchmarkResult {
	fmt.Printf("\n[INSERT] Testing with %d events in batches of %d\n", b.testEvents, b.batchSize)

	// Warmup
	fmt.Printf("  Warming up with %d events...\n", b.warmupEvents)
	for i := 0; i < b.warmupEvents; i += b.batchSize {
		batch := b.client.(*geoClient).CreateBatch()
		count := b.batchSize
		if i+b.batchSize > b.warmupEvents {
			count = b.warmupEvents - i
		}
		for j := 0; j < count; j++ {
			batch.Add(b.generateRandomEvent())
		}
		batch.Commit()
	}

	// Actual test
	latenciesUs := make([]float64, 0)
	errors := 0
	startTime := time.Now()

	for i := 0; i < b.testEvents; i += b.batchSize {
		batchStart := time.Now()

		batch := b.client.(*geoClient).CreateBatch()
		count := b.batchSize
		if i+b.batchSize > b.testEvents {
			count = b.testEvents - i
		}
		for j := 0; j < count; j++ {
			batch.Add(b.generateRandomEvent())
		}
		results, err := batch.Commit()
		if err != nil {
			fmt.Printf("  Batch error: %v\n", err)
			errors += b.batchSize
			continue
		}
		// Only count actual failures, not successful results
		// The server returns results for all events including OK ones
		for _, r := range results {
			if r.Result != types.InsertResultOK {
				errors++
			}
		}

		batchEnd := time.Now()
		batchLatencyUs := float64(batchEnd.Sub(batchStart).Microseconds())
		latenciesUs = append(latenciesUs, batchLatencyUs)

		if (i+b.batchSize)%10000 == 0 {
			fmt.Printf("  Progress: %d/%d\n", i+b.batchSize, b.testEvents)
		}
	}

	endTime := time.Now()
	durationMs := float64(endTime.Sub(startTime).Milliseconds())
	opsPerSec := float64(b.testEvents) / (durationMs / 1000)

	return benchmarkResult{
		Operation:    "INSERT",
		TotalOps:     b.testEvents,
		DurationMs:   durationMs,
		OpsPerSec:    opsPerSec,
		LatencyP50Us: percentile(latenciesUs, 50),
		LatencyP99Us: percentile(latenciesUs, 99),
		LatencyAvgUs: mean(latenciesUs),
		Errors:       errors,
	}
}

func (b *ArcherDBBenchmark) benchmarkQueryUUID(numQueries int) benchmarkResult {
	fmt.Printf("\n[QUERY_UUID] Testing with %d lookups\n", numQueries)

	if len(b.entityIDs) == 0 {
		fmt.Println("  No entity IDs available, skipping...")
		return benchmarkResult{Operation: "QUERY_UUID"}
	}

	// Warmup
	fmt.Println("  Warming up...")
	warmupCount := 100
	if len(b.entityIDs) < warmupCount {
		warmupCount = len(b.entityIDs)
	}
	for i := 0; i < warmupCount; i++ {
		entityID := b.entityIDs[rand.Intn(len(b.entityIDs))]
		b.client.GetLatestByUUID(entityID)
	}

	// Actual test
	latenciesUs := make([]float64, 0)
	errors := 0
	startTime := time.Now()

	for i := 0; i < numQueries; i++ {
		entityID := b.entityIDs[rand.Intn(len(b.entityIDs))]

		queryStart := time.Now()
		result, err := b.client.GetLatestByUUID(entityID)
		if err != nil || result == nil {
			errors++
			continue
		}

		queryEnd := time.Now()
		latencyUs := float64(queryEnd.Sub(queryStart).Microseconds())
		latenciesUs = append(latenciesUs, latencyUs)

		if (i+1)%1000 == 0 {
			fmt.Printf("  Progress: %d/%d\n", i+1, numQueries)
		}
	}

	endTime := time.Now()
	durationMs := float64(endTime.Sub(startTime).Milliseconds())
	opsPerSec := float64(numQueries) / (durationMs / 1000)

	return benchmarkResult{
		Operation:    "QUERY_UUID",
		TotalOps:     numQueries,
		DurationMs:   durationMs,
		OpsPerSec:    opsPerSec,
		LatencyP50Us: percentile(latenciesUs, 50),
		LatencyP99Us: percentile(latenciesUs, 99),
		LatencyAvgUs: mean(latenciesUs),
		Errors:       errors,
	}
}

func (b *ArcherDBBenchmark) benchmarkQueryRadius(numQueries int) benchmarkResult {
	fmt.Printf("\n[QUERY_RADIUS] Testing with %d queries\n", numQueries)

	// Warmup
	fmt.Println("  Warming up...")
	for i := 0; i < 10 && i < numQueries; i++ {
		lat := 37.7 + rand.Float64()*0.1
		lon := -122.5 + rand.Float64()*0.1
		filter, _ := types.NewRadiusQuery(lat, lon, 1000, 100)
		b.client.QueryRadius(filter)
	}

	// Actual test
	latenciesUs := make([]float64, 0)
	errors := 0
	startTime := time.Now()

	for i := 0; i < numQueries; i++ {
		lat := 37.7 + rand.Float64()*0.1
		lon := -122.5 + rand.Float64()*0.1
		radiusM := 100 + rand.Float64()*2000

		queryStart := time.Now()
		filter, _ := types.NewRadiusQuery(lat, lon, radiusM, 1000)
		_, err := b.client.QueryRadius(filter)
		if err != nil {
			errors++
			continue
		}

		queryEnd := time.Now()
		latencyUs := float64(queryEnd.Sub(queryStart).Microseconds())
		latenciesUs = append(latenciesUs, latencyUs)

		if (i+1)%100 == 0 {
			fmt.Printf("  Progress: %d/%d\n", i+1, numQueries)
		}
	}

	endTime := time.Now()
	durationMs := float64(endTime.Sub(startTime).Milliseconds())
	opsPerSec := float64(numQueries) / (durationMs / 1000)

	return benchmarkResult{
		Operation:    "QUERY_RADIUS",
		TotalOps:     numQueries,
		DurationMs:   durationMs,
		OpsPerSec:    opsPerSec,
		LatencyP50Us: percentile(latenciesUs, 50),
		LatencyP99Us: percentile(latenciesUs, 99),
		LatencyAvgUs: mean(latenciesUs),
		Errors:       errors,
	}
}

func (b *ArcherDBBenchmark) benchmarkQueryPolygon(numQueries int) benchmarkResult {
	fmt.Printf("\n[QUERY_POLYGON] Testing with %d queries\n", numQueries)

	// Warmup
	fmt.Println("  Warming up...")
	for i := 0; i < 5 && i < numQueries; i++ {
		lat := 37.7 + rand.Float64()*0.05
		lon := -122.5 + rand.Float64()*0.05
		size := 0.01 + rand.Float64()*0.02
		vertices := [][]float64{
			{lat, lon},
			{lat + size, lon},
			{lat + size, lon + size},
			{lat, lon + size},
		}
		filter, _ := types.NewPolygonQuery(vertices, 100)
		b.client.QueryPolygon(filter)
	}

	// Actual test
	latenciesUs := make([]float64, 0)
	errors := 0
	startTime := time.Now()

	for i := 0; i < numQueries; i++ {
		lat := 37.7 + rand.Float64()*0.05
		lon := -122.5 + rand.Float64()*0.05
		size := 0.01 + rand.Float64()*0.02
		vertices := [][]float64{
			{lat, lon},
			{lat + size, lon},
			{lat + size, lon + size},
			{lat, lon + size},
		}

		queryStart := time.Now()
		filter, _ := types.NewPolygonQuery(vertices, 1000)
		_, err := b.client.QueryPolygon(filter)
		if err != nil {
			errors++
			continue
		}

		queryEnd := time.Now()
		latencyUs := float64(queryEnd.Sub(queryStart).Microseconds())
		latenciesUs = append(latenciesUs, latencyUs)

		if (i+1)%50 == 0 {
			fmt.Printf("  Progress: %d/%d\n", i+1, numQueries)
		}
	}

	endTime := time.Now()
	durationMs := float64(endTime.Sub(startTime).Milliseconds())
	opsPerSec := float64(numQueries) / (durationMs / 1000)

	return benchmarkResult{
		Operation:    "QUERY_POLYGON",
		TotalOps:     numQueries,
		DurationMs:   durationMs,
		OpsPerSec:    opsPerSec,
		LatencyP50Us: percentile(latenciesUs, 50),
		LatencyP99Us: percentile(latenciesUs, 99),
		LatencyAvgUs: mean(latenciesUs),
		Errors:       errors,
	}
}

func printResult(result benchmarkResult) {
	fmt.Printf("\n%s\n", string(make([]byte, 60)))
	fmt.Printf("  %s Results\n", result.Operation)
	fmt.Printf("%s\n", string(make([]byte, 60)))
	fmt.Printf("  Total operations:  %d\n", result.TotalOps)
	fmt.Printf("  Duration:          %.2f ms\n", result.DurationMs)
	fmt.Printf("  Throughput:        %.2f ops/sec\n", result.OpsPerSec)
	fmt.Printf("  Latency p50:       %.2f μs\n", result.LatencyP50Us)
	fmt.Printf("  Latency p99:       %.2f μs\n", result.LatencyP99Us)
	fmt.Printf("  Latency avg:       %.2f μs\n", result.LatencyAvgUs)
	fmt.Printf("  Errors:            %d\n", result.Errors)
	fmt.Printf("%s\n", string(make([]byte, 60)))
}

// BenchmarkArcherDB runs the full benchmark suite.
func BenchmarkArcherDB(b *testing.B) {
	flag.Parse()

	// Benchmarks require ARCHERDB_INTEGRATION env var to be set
	if os.Getenv("ARCHERDB_INTEGRATION") == "" {
		b.Skip("Skipping benchmark: set ARCHERDB_INTEGRATION=1 to run against server at " + *benchAddresses)
	}

	bench := NewArcherDBBenchmark(
		*benchClusterID,
		[]string{*benchAddresses},
		*benchWarmup,
		*benchEvents,
		*benchBatchSize,
	)

	if err := bench.connect(); err != nil {
		b.Fatalf("Failed to connect: %v", err)
	}
	defer bench.disconnect()

	b.Run("Insert", func(b *testing.B) {
		result := bench.benchmarkInsert()
		printResult(result)
	})

	b.Run("QueryUUID", func(b *testing.B) {
		result := bench.benchmarkQueryUUID(10000)
		printResult(result)
	})

	b.Run("QueryRadius", func(b *testing.B) {
		result := bench.benchmarkQueryRadius(1000)
		printResult(result)
	})

	b.Run("QueryPolygon", func(b *testing.B) {
		result := bench.benchmarkQueryPolygon(500)
		printResult(result)
	})
}

// Main runs the benchmark from command line.
func TestMain(m *testing.M) {
	flag.Parse()
	m.Run()
}
