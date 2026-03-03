package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	archerdb "github.com/archerdb/archerdb-go"
	"github.com/archerdb/archerdb-go/pkg/types"
)

type config struct {
	clusterID        uint64
	addresses        []string
	duration         time.Duration
	workers          int
	batchSize        int
	minBatchSize     int
	entityMod        uint64
	connectTimeout   time.Duration
	requestTimeout   time.Duration
	progressInterval time.Duration
	adaptiveBackoff  bool
	disableGC        bool
	goMaxProcs       int
}

type summary struct {
	Driver                    string  `json:"driver"`
	DurationSeconds           float64 `json:"duration_seconds"`
	Workers                   int     `json:"workers"`
	BatchSize                 int     `json:"batch_size"`
	EntityMod                 uint64  `json:"entity_mod"`
	EventsInserted            uint64  `json:"events_inserted"`
	EventsRejected            uint64  `json:"events_rejected"`
	AvgInsertRateEventsPerSec float64 `json:"avg_insert_rate_events_per_sec"`
	FirstErrorCode            *int    `json:"first_error_code"`
	FailureReason             string  `json:"failure_reason"`
}

func parseFlags() config {
	var (
		clusterID = flag.Uint64("cluster-id", 0, "Cluster ID")
		addresses = flag.String("addresses", "127.0.0.1:3001", "Comma-separated node addresses")
		durationS = flag.Int("duration-seconds", 15, "Test duration in seconds")
		workers   = flag.Int("workers", 8, "Number of load workers")
		batchSize = flag.Int("batch-size", 8000, "Events per request (max 10000)")
		minBatch  = flag.Int("min-batch-size", 1, "Smallest batch size after adaptive TOO_MUCH_DATA backoff")
		entityMod = flag.Uint64("entity-mod", 1_000_000, "Entity ID modulus for cardinality control")

		connectTimeoutMs = flag.Int("connect-timeout-ms", 20_000, "Connection timeout in milliseconds")
		requestTimeoutMs = flag.Int("request-timeout-ms", 120_000, "Request timeout in milliseconds")
		progressS        = flag.Int("progress-interval-seconds", 2, "Progress print interval (0 disables)")
		adaptiveBackoff  = flag.Bool("adaptive-backoff", true, "Automatically reduce batch size on TOO_MUCH_DATA")
		disableGC        = flag.Bool("disable-gc", true, "Disable Go GC during the run for maximum throughput")
		goMaxProcs       = flag.Int("gomaxprocs", 0, "GOMAXPROCS override (0 = Go default)")
	)
	flag.Parse()

	if *workers < 1 {
		log.Fatal("--workers must be >= 1")
	}
	if *batchSize < 1 || *batchSize > types.BatchSizeMax {
		log.Fatalf("--batch-size must be in [1, %d]", types.BatchSizeMax)
	}
	if *durationS < 1 {
		log.Fatal("--duration-seconds must be >= 1")
	}
	if *minBatch < 1 {
		log.Fatal("--min-batch-size must be >= 1")
	}
	if *minBatch > *batchSize {
		log.Fatal("--min-batch-size cannot exceed --batch-size")
	}
	if *entityMod < 1 {
		log.Fatal("--entity-mod must be >= 1")
	}
	if *progressS < 0 {
		log.Fatal("--progress-interval-seconds must be >= 0")
	}
	if *goMaxProcs < 0 {
		log.Fatal("--gomaxprocs must be >= 0")
	}

	rawAddresses := strings.Split(*addresses, ",")
	outAddresses := make([]string, 0, len(rawAddresses))
	for _, addr := range rawAddresses {
		trimmed := strings.TrimSpace(addr)
		if trimmed != "" {
			outAddresses = append(outAddresses, trimmed)
		}
	}
	if len(outAddresses) == 0 {
		log.Fatal("--addresses must contain at least one address")
	}

	return config{
		clusterID:        *clusterID,
		addresses:        outAddresses,
		duration:         time.Duration(*durationS) * time.Second,
		workers:          *workers,
		batchSize:        *batchSize,
		minBatchSize:     *minBatch,
		entityMod:        *entityMod,
		connectTimeout:   time.Duration(*connectTimeoutMs) * time.Millisecond,
		requestTimeout:   time.Duration(*requestTimeoutMs) * time.Millisecond,
		progressInterval: time.Duration(*progressS) * time.Second,
		adaptiveBackoff:  *adaptiveBackoff,
		disableGC:        *disableGC,
		goMaxProcs:       *goMaxProcs,
	}
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func isTooMuchDataError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "Maximum batch size exceeded") || strings.Contains(msg, "status=1")
}

func main() {
	cfg := parseFlags()
	if cfg.goMaxProcs > 0 {
		runtime.GOMAXPROCS(cfg.goMaxProcs)
	}
	if cfg.disableGC {
		debug.SetGCPercent(-1)
	}

	var (
		nextEventID    atomic.Uint64
		eventsInserted atomic.Uint64
		eventsRejected atomic.Uint64
		firstErrorCode atomic.Int32
	)
	firstErrorCode.Store(-1)

	stopCh := make(chan struct{})
	startCh := make(chan struct{})
	readyCh := make(chan struct{}, cfg.workers)
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			close(stopCh)
		})
	}

	setFirstErrorCode := func(code int32) {
		firstErrorCode.CompareAndSwap(-1, code)
	}

	var (
		mu           sync.Mutex
		failureCause string
	)
	setFailure := func(reason string) {
		mu.Lock()
		if failureCause == "" {
			failureCause = reason
		}
		mu.Unlock()
		stop()
	}

	start := time.Now()

	var wg sync.WaitGroup
	for workerID := 0; workerID < cfg.workers; workerID++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()

			client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
				ClusterID:      types.ToUint128(cfg.clusterID),
				Addresses:      cfg.addresses,
				ConnectTimeout: cfg.connectTimeout,
				RequestTimeout: cfg.requestTimeout,
				Retry: &archerdb.RetryConfig{
					Enabled: false,
				},
			})
			if err != nil {
				setFailure(fmt.Sprintf("worker_%d_connect_error:%v", id, err))
				return
			}
			defer client.Close()

			select {
			case readyCh <- struct{}{}:
			case <-stopCh:
				return
			}

			select {
			case <-startCh:
			case <-stopCh:
				return
			}

			zero128 := types.ToUint128(0)
			events := make([]types.GeoEvent, cfg.batchSize)
			for i := range events {
				events[i] = types.GeoEvent{
					CorrelationID: zero128,
					UserData:      zero128,
					LatNano:       37_774_900_000,
					LonNano:       -122_419_400_000,
					GroupID:       1,
					AltitudeMM:    0,
					VelocityMMS:   0,
					TTLSeconds:    86_400,
					AccuracyMM:    5_000,
					HeadingCdeg:   0,
					Flags:         types.GeoEventFlagNone,
				}
			}
			currentBatchSize := cfg.batchSize

			for {
				select {
				case <-stopCh:
					return
				default:
				}

				base := nextEventID.Add(uint64(currentBatchSize))
				base -= uint64(currentBatchSize)
				entityID := (base % cfg.entityMod) + 1

				for i := 0; i < currentBatchSize; i++ {
					eventID := base + uint64(i) + 1
					ev := &events[i]
					ev.ID = types.ToUint128(eventID)
					ev.EntityID = types.ToUint128(entityID)
					ev.Timestamp = 0
					entityID++
					if entityID > cfg.entityMod {
						entityID = 1
					}
				}

				errors, err := client.InsertEvents(events[:currentBatchSize])
				if err != nil {
					if cfg.adaptiveBackoff && isTooMuchDataError(err) && currentBatchSize > cfg.minBatchSize {
						nextBatchSize := maxInt(cfg.minBatchSize, currentBatchSize/2)
						if nextBatchSize < currentBatchSize {
							currentBatchSize = nextBatchSize
							fmt.Printf(
								"worker=%d reducing batch_size to %d after TOO_MUCH_DATA error\n",
								id,
								currentBatchSize,
							)
							continue
						}
					}
					setFailure(fmt.Sprintf("worker_%d_insert_error:%v", id, err))
					return
				}

				inserted := currentBatchSize - len(errors)
				eventsInserted.Add(uint64(inserted))
				eventsRejected.Add(uint64(len(errors)))

				if len(errors) > 0 {
					code := int32(errors[0].Result)
					if cfg.adaptiveBackoff && code == 1 && currentBatchSize > cfg.minBatchSize {
						nextBatchSize := maxInt(cfg.minBatchSize, currentBatchSize/2)
						if nextBatchSize < currentBatchSize {
							currentBatchSize = nextBatchSize
							fmt.Printf(
								"worker=%d reducing batch_size to %d after TOO_MUCH_DATA response\n",
								id,
								currentBatchSize,
							)
							continue
						}
					}
					setFirstErrorCode(code)
					setFailure(fmt.Sprintf("server_rejected_events:%d", len(errors)))
					return
				}
			}
		}(workerID)
	}

	readyCount := 0
	for readyCount < cfg.workers {
		select {
		case <-readyCh:
			readyCount++
		case <-stopCh:
			readyCount = cfg.workers
		}
	}

	mu.Lock()
	hadFailureBeforeStart := failureCause != ""
	mu.Unlock()
	if !hadFailureBeforeStart {
		start = time.Now()
		close(startCh)
	}

	var progressTicker *time.Ticker
	if cfg.progressInterval > 0 {
		progressTicker = time.NewTicker(cfg.progressInterval)
		defer progressTicker.Stop()
	}
	var progressChannel <-chan time.Time
	if progressTicker != nil {
		progressChannel = progressTicker.C
	}

	durationTimer := time.NewTimer(cfg.duration)
	defer durationTimer.Stop()

running:
	for {
		select {
		case <-durationTimer.C:
			stop()
			break running
		case <-stopCh:
			break running
		case <-progressChannel:
			elapsed := time.Since(start).Seconds()
			if elapsed <= 0 {
				continue
			}
			inserted := eventsInserted.Load()
			rate := float64(inserted) / elapsed
			fmt.Printf("progress inserted=%d rate=%.0f/s\n", inserted, rate)
		}
	}

	wg.Wait()
	elapsed := time.Since(start).Seconds()
	if elapsed <= 0 {
		elapsed = 1e-9
	}

	firstCodeValue := int(firstErrorCode.Load())
	var firstCodePtr *int
	if firstCodeValue >= 0 {
		firstCodePtr = &firstCodeValue
	}

	mu.Lock()
	failureReason := failureCause
	mu.Unlock()
	if failureReason == "" {
		failureReason = "none"
	}

	result := summary{
		Driver:                    "go",
		DurationSeconds:           elapsed,
		Workers:                   cfg.workers,
		BatchSize:                 cfg.batchSize,
		EntityMod:                 cfg.entityMod,
		EventsInserted:            eventsInserted.Load(),
		EventsRejected:            eventsRejected.Load(),
		AvgInsertRateEventsPerSec: float64(eventsInserted.Load()) / elapsed,
		FirstErrorCode:            firstCodePtr,
		FailureReason:             failureReason,
	}

	fmt.Println("RESULT_JSON_START")
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		log.Fatalf("failed to encode result: %v", err)
	}
	fmt.Println("RESULT_JSON_END")
}
