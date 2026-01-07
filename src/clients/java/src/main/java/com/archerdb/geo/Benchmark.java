package com.archerdb.geo;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * ArcherDB Java SDK Performance Benchmark
 *
 * <p>
 * This benchmark tests:
 * <ul>
 * <li>Insert throughput (events/sec)</li>
 * <li>Query latency (p50, p99)</li>
 * <li>Batch efficiency</li>
 * </ul>
 *
 * <p>
 * Target specs from design doc:
 * <ul>
 * <li>Insert: 1M events/sec</li>
 * <li>UUID lookup: p99 < 500μs</li>
 * <li>Radius query: p99 < 50ms</li>
 * <li>Polygon query: p99 < 100ms</li>
 * </ul>
 *
 * <p>
 * Run with: java -cp target/classes com.archerdb.geo.Benchmark
 */
public final class Benchmark {

    private final long clusterId;
    private final String[] addresses;
    private final int warmupEvents;
    private final int testEvents;
    private final int batchSize;
    private GeoClient client;
    private final List<UInt128> entityIds = new ArrayList<>();
    private final Random random = new Random();

    public Benchmark(long clusterId, String[] addresses, int warmupEvents, int testEvents,
            int batchSize) {
        this.clusterId = clusterId;
        this.addresses = addresses;
        this.warmupEvents = warmupEvents;
        this.testEvents = testEvents;
        this.batchSize = batchSize;
    }

    private boolean connect() {
        try {
            client = GeoClient.create(clusterId, addresses);
            return true;
        } catch (Exception e) {
            System.err.println("Failed to connect: " + e.getMessage());
            return false;
        }
    }

    private void disconnect() {
        if (client != null) {
            client.close();
            client = null;
        }
    }

    private GeoEvent generateRandomEvent() {
        UInt128 entityId = UInt128.random();
        entityIds.add(entityId);

        // Random location in San Francisco area
        double lat = 37.7 + random.nextDouble() * 0.1;
        double lon = -122.5 + random.nextDouble() * 0.1;

        return new GeoEvent.Builder().setEntityId(entityId).setLatitude(lat).setLongitude(lon)
                .setVelocity(random.nextDouble() * 30).setHeading(random.nextDouble() * 360)
                .setAccuracy(random.nextDouble() * 10 + 1).setTtlSeconds(86400).build();
    }

    private BenchmarkResult benchmarkInsert() {
        System.out.printf("%n[INSERT] Testing with %d events in batches of %d%n", testEvents,
                batchSize);

        // Warmup
        System.out.printf("  Warming up with %d events...%n", warmupEvents);
        for (int i = 0; i < warmupEvents; i += batchSize) {
            GeoEventBatch batch = client.createBatch();
            int count = Math.min(batchSize, warmupEvents - i);
            for (int j = 0; j < count; j++) {
                batch.add(generateRandomEvent());
            }
            batch.commit();
        }

        // Actual test
        List<Double> latenciesUs = new ArrayList<>();
        int errors = 0;
        long startTime = System.nanoTime();

        for (int i = 0; i < testEvents; i += batchSize) {
            long batchStart = System.nanoTime();

            try {
                GeoEventBatch batch = client.createBatch();
                int count = Math.min(batchSize, testEvents - i);
                for (int j = 0; j < count; j++) {
                    batch.add(generateRandomEvent());
                }
                List<InsertGeoEventsError> results = batch.commit();
                errors += results.size();
            } catch (Exception e) {
                System.err.println("  Batch error: " + e.getMessage());
                errors += batchSize;
                continue;
            }

            long batchEnd = System.nanoTime();
            double batchLatencyUs = (batchEnd - batchStart) / 1000.0;
            latenciesUs.add(batchLatencyUs);

            if ((i + batchSize) % 10000 == 0) {
                System.out.printf("  Progress: %d/%d%n", i + batchSize, testEvents);
            }
        }

        long endTime = System.nanoTime();
        double durationMs = (endTime - startTime) / 1_000_000.0;
        double opsPerSec = testEvents / (durationMs / 1000);

        return new BenchmarkResult("INSERT", testEvents, durationMs, opsPerSec,
                percentile(latenciesUs, 50), percentile(latenciesUs, 99), mean(latenciesUs),
                errors);
    }

    private BenchmarkResult benchmarkQueryUuid(int numQueries) {
        System.out.printf("%n[QUERY_UUID] Testing with %d lookups%n", numQueries);

        if (entityIds.isEmpty()) {
            System.out.println("  No entity IDs available, skipping...");
            return new BenchmarkResult("QUERY_UUID", 0, 0, 0, 0, 0, 0, 0);
        }

        // Warmup
        System.out.println("  Warming up...");
        int warmupCount = Math.min(100, entityIds.size());
        for (int i = 0; i < warmupCount; i++) {
            UInt128 entityId = entityIds.get(random.nextInt(entityIds.size()));
            client.getLatestByUuid(entityId);
        }

        // Actual test
        List<Double> latenciesUs = new ArrayList<>();
        int errors = 0;
        long startTime = System.nanoTime();

        for (int i = 0; i < numQueries; i++) {
            UInt128 entityId = entityIds.get(random.nextInt(entityIds.size()));

            long queryStart = System.nanoTime();
            try {
                GeoEvent result = client.getLatestByUuid(entityId);
                if (result == null) {
                    errors++;
                }
            } catch (Exception e) {
                errors++;
                continue;
            }

            long queryEnd = System.nanoTime();
            double latencyUs = (queryEnd - queryStart) / 1000.0;
            latenciesUs.add(latencyUs);

            if ((i + 1) % 1000 == 0) {
                System.out.printf("  Progress: %d/%d%n", i + 1, numQueries);
            }
        }

        long endTime = System.nanoTime();
        double durationMs = (endTime - startTime) / 1_000_000.0;
        double opsPerSec = numQueries / (durationMs / 1000);

        return new BenchmarkResult("QUERY_UUID", numQueries, durationMs, opsPerSec,
                percentile(latenciesUs, 50), percentile(latenciesUs, 99), mean(latenciesUs),
                errors);
    }

    private BenchmarkResult benchmarkQueryRadius(int numQueries) {
        System.out.printf("%n[QUERY_RADIUS] Testing with %d queries%n", numQueries);

        // Warmup
        System.out.println("  Warming up...");
        for (int i = 0; i < Math.min(10, numQueries); i++) {
            double lat = 37.7 + random.nextDouble() * 0.1;
            double lon = -122.5 + random.nextDouble() * 0.1;
            client.queryRadius(QueryRadiusFilter.create(lat, lon, 1000, 100));
        }

        // Actual test
        List<Double> latenciesUs = new ArrayList<>();
        int errors = 0;
        long startTime = System.nanoTime();

        for (int i = 0; i < numQueries; i++) {
            double lat = 37.7 + random.nextDouble() * 0.1;
            double lon = -122.5 + random.nextDouble() * 0.1;
            double radiusM = 100 + random.nextDouble() * 2000;

            long queryStart = System.nanoTime();
            try {
                client.queryRadius(QueryRadiusFilter.create(lat, lon, radiusM, 1000));
            } catch (Exception e) {
                errors++;
                continue;
            }

            long queryEnd = System.nanoTime();
            double latencyUs = (queryEnd - queryStart) / 1000.0;
            latenciesUs.add(latencyUs);

            if ((i + 1) % 100 == 0) {
                System.out.printf("  Progress: %d/%d%n", i + 1, numQueries);
            }
        }

        long endTime = System.nanoTime();
        double durationMs = (endTime - startTime) / 1_000_000.0;
        double opsPerSec = numQueries / (durationMs / 1000);

        return new BenchmarkResult("QUERY_RADIUS", numQueries, durationMs, opsPerSec,
                percentile(latenciesUs, 50), percentile(latenciesUs, 99), mean(latenciesUs),
                errors);
    }

    private BenchmarkResult benchmarkQueryPolygon(int numQueries) {
        System.out.printf("%n[QUERY_POLYGON] Testing with %d queries%n", numQueries);

        // Warmup
        System.out.println("  Warming up...");
        for (int i = 0; i < Math.min(5, numQueries); i++) {
            double lat = 37.7 + random.nextDouble() * 0.05;
            double lon = -122.5 + random.nextDouble() * 0.05;
            double size = 0.01 + random.nextDouble() * 0.02;
            QueryPolygonFilter filter = new QueryPolygonFilter.Builder().addVertex(lat, lon)
                    .addVertex(lat + size, lon).addVertex(lat + size, lon + size)
                    .addVertex(lat, lon + size).setLimit(100).build();
            client.queryPolygon(filter);
        }

        // Actual test
        List<Double> latenciesUs = new ArrayList<>();
        int errors = 0;
        long startTime = System.nanoTime();

        for (int i = 0; i < numQueries; i++) {
            double lat = 37.7 + random.nextDouble() * 0.05;
            double lon = -122.5 + random.nextDouble() * 0.05;
            double size = 0.01 + random.nextDouble() * 0.02;

            long queryStart = System.nanoTime();
            try {
                QueryPolygonFilter filter = new QueryPolygonFilter.Builder().addVertex(lat, lon)
                        .addVertex(lat + size, lon).addVertex(lat + size, lon + size)
                        .addVertex(lat, lon + size).setLimit(1000).build();
                client.queryPolygon(filter);
            } catch (Exception e) {
                errors++;
                continue;
            }

            long queryEnd = System.nanoTime();
            double latencyUs = (queryEnd - queryStart) / 1000.0;
            latenciesUs.add(latencyUs);

            if ((i + 1) % 50 == 0) {
                System.out.printf("  Progress: %d/%d%n", i + 1, numQueries);
            }
        }

        long endTime = System.nanoTime();
        double durationMs = (endTime - startTime) / 1_000_000.0;
        double opsPerSec = numQueries / (durationMs / 1000);

        return new BenchmarkResult("QUERY_POLYGON", numQueries, durationMs, opsPerSec,
                percentile(latenciesUs, 50), percentile(latenciesUs, 99), mean(latenciesUs),
                errors);
    }

    private void printResult(BenchmarkResult result) {
        System.out.println();
        System.out.println("=".repeat(60));
        System.out.printf("  %s Results%n", result.operation);
        System.out.println("=".repeat(60));
        System.out.printf("  Total operations:  %,d%n", result.totalOps);
        System.out.printf("  Duration:          %.2f ms%n", result.durationMs);
        System.out.printf("  Throughput:        %,.2f ops/sec%n", result.opsPerSec);
        System.out.printf("  Latency p50:       %.2f μs%n", result.latencyP50Us);
        System.out.printf("  Latency p99:       %.2f μs%n", result.latencyP99Us);
        System.out.printf("  Latency avg:       %.2f μs%n", result.latencyAvgUs);
        System.out.printf("  Errors:            %d%n", result.errors);
        System.out.println("=".repeat(60));
    }

    public void run() {
        System.out.println();
        System.out.println("=".repeat(60));
        System.out.println("  ArcherDB Java SDK Performance Benchmark");
        System.out.println("=".repeat(60));
        System.out.printf("  Cluster ID: %d%n", clusterId);
        System.out.printf("  Addresses:  %s%n", String.join(", ", addresses));
        System.out.printf("  Test events: %,d%n", testEvents);
        System.out.printf("  Batch size: %d%n", batchSize);
        System.out.println("=".repeat(60));

        if (!connect()) {
            System.out.println("Failed to connect to cluster, exiting.");
            return;
        }

        try {
            List<BenchmarkResult> results = new ArrayList<>();

            BenchmarkResult insertResult = benchmarkInsert();
            printResult(insertResult);
            results.add(insertResult);

            BenchmarkResult uuidResult = benchmarkQueryUuid(10000);
            printResult(uuidResult);
            results.add(uuidResult);

            BenchmarkResult radiusResult = benchmarkQueryRadius(1000);
            printResult(radiusResult);
            results.add(radiusResult);

            BenchmarkResult polygonResult = benchmarkQueryPolygon(500);
            printResult(polygonResult);
            results.add(polygonResult);

            // Summary
            System.out.println();
            System.out.println("=".repeat(60));
            System.out.println("  SUMMARY");
            System.out.println("=".repeat(60));
            for (BenchmarkResult r : results) {
                String status =
                        r.errors == 0 ? "PASS" : String.format("FAIL (%d errors)", r.errors);
                System.out.printf("  %-15s %,12.0f ops/sec  [%s]%n", r.operation, r.opsPerSec,
                        status);
            }
            System.out.println("=".repeat(60));

        } finally {
            disconnect();
        }
    }

    private static double percentile(List<Double> data, double p) {
        if (data.isEmpty())
            return 0;
        double[] sorted = data.stream().mapToDouble(Double::doubleValue).sorted().toArray();
        double k = (sorted.length - 1) * p / 100;
        int f = (int) k;
        int c = Math.min(f + 1, sorted.length - 1);
        return sorted[f] + (k - f) * (sorted[c] - sorted[f]);
    }

    private static double mean(List<Double> data) {
        if (data.isEmpty())
            return 0;
        return data.stream().mapToDouble(Double::doubleValue).average().orElse(0);
    }

    private static class BenchmarkResult {
        final String operation;
        final int totalOps;
        final double durationMs;
        final double opsPerSec;
        final double latencyP50Us;
        final double latencyP99Us;
        final double latencyAvgUs;
        final int errors;

        BenchmarkResult(String operation, int totalOps, double durationMs, double opsPerSec,
                double latencyP50Us, double latencyP99Us, double latencyAvgUs, int errors) {
            this.operation = operation;
            this.totalOps = totalOps;
            this.durationMs = durationMs;
            this.opsPerSec = opsPerSec;
            this.latencyP50Us = latencyP50Us;
            this.latencyP99Us = latencyP99Us;
            this.latencyAvgUs = latencyAvgUs;
            this.errors = errors;
        }
    }

    public static void main(String[] args) {
        long clusterId = 0;
        String[] addresses = {"127.0.0.1:3000"};
        int testEvents = 100000;
        int batchSize = 1000;
        int warmupEvents = 1000;

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--cluster-id":
                    clusterId = Long.parseLong(args[++i]);
                    break;
                case "--addresses":
                    addresses = args[++i].split(",");
                    break;
                case "--events":
                    testEvents = Integer.parseInt(args[++i]);
                    break;
                case "--batch-size":
                    batchSize = Integer.parseInt(args[++i]);
                    break;
                case "--warmup":
                    warmupEvents = Integer.parseInt(args[++i]);
                    break;
                case "--help":
                    System.out.println("ArcherDB Java SDK Performance Benchmark\n\n"
                            + "Usage: java com.archerdb.geo.Benchmark [options]\n\n" + "Options:\n"
                            + "  --cluster-id <id>     Cluster ID (default: 0)\n"
                            + "  --addresses <addr>    Comma-separated replica addresses (default: 127.0.0.1:3000)\n"
                            + "  --events <n>          Number of test events (default: 100000)\n"
                            + "  --batch-size <n>      Batch size for inserts (default: 1000)\n"
                            + "  --warmup <n>          Number of warmup events (default: 1000)\n"
                            + "  --help                Show this help");
                    return;
            }
        }

        Benchmark benchmark =
                new Benchmark(clusterId, addresses, warmupEvents, testEvents, batchSize);
        benchmark.run();
    }
}
