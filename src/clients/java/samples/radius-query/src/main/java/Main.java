package com.archerdb.samples;

/**
 * ArcherDB Radius Query Sample - Advanced Spatial Queries
 *
 * This sample demonstrates:
 * 1. Inserting events at known locations
 * 2. Performing radius queries with different parameters
 * 3. Pagination of results
 */

import java.util.List;

import com.archerdb.geo.*;

public final class Main {
    public static void main(String[] args) throws Exception {
        String address = System.getenv("ARCHERDB_ADDRESS");
        if (address == null) {
            address = "127.0.0.1:3001";
        }

        try (GeoClient client = GeoClient.create(0L, address)) {
            System.out.println("Connected to ArcherDB at " + address);

            // Using Golden Gate Park as center
            double centerLat = 37.7694;
            double centerLon = -122.4862;

            long nowNs = System.nanoTime();

            GeoEventBatch batch = client.createBatch();

            // Events at various distances from center
            double[][] eventsData = {
                {37.7703, -122.4862},  // ~100m
                {37.7739, -122.4862},  // ~500m
                {37.7784, -122.4862},  // ~1km
                {37.7874, -122.4862},  // ~2km
                {37.7694, -122.5412},  // ~5km
            };

            for (int i = 0; i < eventsData.length; i++) {
                GeoEvent event = new GeoEvent.Builder()
                    .setEntityId(UInt128.random())
                    .setLatitude(eventsData[i][0])
                    .setLongitude(eventsData[i][1])
                    .setTimestamp(nowNs + i)
                    .setGroupId(1L)
                    .build();
                batch.add(event);
            }

            batch.commit();
            System.out.println("Inserted " + eventsData.length + " events at various distances\n");

            // Query 1: Find everything within 200m
            QueryResult result = client.queryRadius(
                QueryRadiusFilter.create(centerLat, centerLon, 200, 1000)
            );
            System.out.println("Within 200m: " + result.getEvents().size() + " events");

            // Query 2: Find everything within 600m
            result = client.queryRadius(
                QueryRadiusFilter.create(centerLat, centerLon, 600, 1000)
            );
            System.out.println("Within 600m: " + result.getEvents().size() + " events");

            // Query 3: Find everything within 1.5km
            result = client.queryRadius(
                QueryRadiusFilter.create(centerLat, centerLon, 1500, 1000)
            );
            System.out.println("Within 1.5km: " + result.getEvents().size() + " events");

            // Query 4: Find everything within 3km
            result = client.queryRadius(
                QueryRadiusFilter.create(centerLat, centerLon, 3000, 1000)
            );
            System.out.println("Within 3km: " + result.getEvents().size() + " events");

            // Query 5: Find everything within 10km (should get all)
            result = client.queryRadius(
                QueryRadiusFilter.create(centerLat, centerLon, 10000, 1000)
            );
            System.out.println("Within 10km: " + result.getEvents().size() + " events");

            // Query with pagination
            System.out.println("\nPagination example (limit 2 per page):");
            result = client.queryRadius(
                QueryRadiusFilter.create(centerLat, centerLon, 10000, 2)
            );
            System.out.println("  Page 1: " + result.getEvents().size() + " events, hasMore=" + result.hasMore());

            if (result.hasMore() && result.getCursor() > 0) {
                QueryRadiusFilter page2Filter = QueryRadiusFilter.builder()
                    .setCenter(centerLat, centerLon)
                    .setRadiusMeters(10000)
                    .setLimit(2)
                    .setTimestampMax(result.getCursor() - 1)
                    .build();
                QueryResult result2 = client.queryRadius(page2Filter);
                System.out.println("  Page 2: " + result2.getEvents().size() + " events, hasMore=" + result2.hasMore());
            }

            System.out.println("\nok");
        }
    }
}
