// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.samples;

/**
 * ArcherDB Basic Sample - Insert and Query Geospatial Events
 *
 * This sample demonstrates:
 * 1. Connecting to an ArcherDB cluster
 * 2. Inserting geo events with location data
 * 3. Querying events within a radius
 */

import java.util.List;
import java.util.ArrayList;
import java.util.Random;

import com.archerdb.geo.*;

public final class Main {
    public static void main(String[] args) throws Exception {
        String address = System.getenv("ARCHERDB_ADDRESS");
        if (address == null) {
            address = "127.0.0.1:3001";
        }

        // Connect to ArcherDB cluster
        try (GeoClient client = GeoClient.create(0L, address)) {
            System.out.println("Connected to ArcherDB at " + address);

            // San Francisco area coordinates
            double baseLat = 37.7749;
            double baseLon = -122.4194;

            // Insert events using a batch
            GeoEventBatch batch = client.createBatch();
            List<UInt128> entityIds = new ArrayList<>();
            Random random = new Random();

            for (int i = 0; i < 5; i++) {
                // Generate a random entity ID
                UInt128 entityId = UInt128.random();
                entityIds.add(entityId);

                GeoEvent event = new GeoEvent.Builder()
                    .setEntityId(entityId)
                    .setLatitude(baseLat + i * 0.001)  // ~111 meters apart
                    .setLongitude(baseLon + i * 0.001)
                    .setTimestamp(System.nanoTime() + i)
                    .setGroupId(1L)
                    .setAccuracyMm(10_000)  // 10m accuracy
                    .build();
                batch.add(event);
            }

            List<InsertGeoEventsError> errors = batch.commit();
            if (!errors.isEmpty()) {
                System.err.println("Insert errors: " + errors);
            } else {
                System.out.println("Successfully inserted " + entityIds.size() + " events");
            }

            // Query events within 1km radius of SF center
            QueryRadiusFilter filter = QueryRadiusFilter.create(
                baseLat, baseLon, 1000, 100
            );
            QueryResult result = client.queryRadius(filter);

            System.out.println("\nFound " + result.getEvents().size() + " events within 1km of SF center:");
            for (GeoEvent event : result.getEvents()) {
                System.out.printf("  Entity %s: (%.4f, %.4f)%n",
                    event.getEntityId(), event.getLatitude(), event.getLongitude());
            }

            // Look up a specific entity
            if (!entityIds.isEmpty()) {
                GeoEvent found = client.getLatestByUuid(entityIds.get(0));
                if (found != null) {
                    System.out.printf("%nLatest position for entity %s:%n", entityIds.get(0));
                    System.out.printf("  Location: (%.4f, %.4f)%n", found.getLatitude(), found.getLongitude());
                    System.out.printf("  Timestamp: %d%n", found.getTimestamp());
                }
            }

            System.out.println("\nok");
        }
    }
}
