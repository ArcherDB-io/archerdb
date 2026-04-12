// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.samples;

/**
 * ArcherDB Entity Tracking Walkthrough
 *
 * This sample demonstrates:
 * 1. Tracking a moving entity over time
 * 2. Updating entity positions (upsert)
 * 3. Looking up entity by UUID
 * 4. Deleting entities
 * 5. Historical position queries
 */

import java.util.List;
import java.util.ArrayList;

// section:imports
import com.archerdb.geo.*;

public final class Main {
    // Named stop on a route
    static class RouteStop {
        String name;
        double lat;
        double lon;

        RouteStop(String name, double lat, double lon) {
            this.name = name;
            this.lat = lat;
            this.lon = lon;
        }
    }

    public static void main(String[] args) throws Exception {
        String address = System.getenv("ARCHERDB_ADDRESS");
        if (address == null) {
            address = "127.0.0.1:3001";
        }

        try (GeoClient client = GeoClient.create(0L, address)) {
            System.out.println("Connected to ArcherDB at " + address);
            System.out.println("==================================================");

            // Create a unique entity ID for our tracked vehicle
            UInt128 entityId = UInt128.random();
            System.out.println("\n1. CREATING ENTITY: Vehicle " + entityId);

            // Simulate a vehicle route from SF Ferry Building to Fisherman's Wharf
            List<RouteStop> route = new ArrayList<>();
            route.add(new RouteStop("Ferry Building", 37.7955, -122.3937));
            route.add(new RouteStop("Pier 23", 37.8005, -122.4007));
            route.add(new RouteStop("Pier 33", 37.8087, -122.4097));
            route.add(new RouteStop("Fisherman's Wharf", 37.8080, -122.4177));

            long baseTime = System.nanoTime();

            // Insert initial position
            System.out.println("\n2. INSERTING INITIAL POSITION");
            GeoEventBatch batch = client.createBatch();
            GeoEvent event = new GeoEvent.Builder()
                .setEntityId(entityId)
                .setLatitude(route.get(0).lat)
                .setLongitude(route.get(0).lon)
                .setTimestamp(baseTime)
                .setVelocityMms(5000)  // 5 m/s
                .setHeadingCdeg((short) 31500)  // ~315 degrees (northwest)
                .setGroupId(1L)
                .build();
            batch.add(event);
            batch.commit();
            System.out.printf("   Inserted at %s: (%.4f, %.4f)%n",
                route.get(0).name, route.get(0).lat, route.get(0).lon);

            // Look up the entity
            System.out.println("\n3. LOOKING UP ENTITY BY UUID");
            GeoEvent found = client.getLatestByUuid(entityId);
            if (found != null) {
                System.out.println("   Found entity " + entityId);
                System.out.printf("   Position: (%.4f, %.4f)%n", found.getLatitude(), found.getLongitude());
                System.out.printf("   Velocity: %.1f m/s%n", found.getVelocityMms() / 1000.0);
            }

            // Update positions along the route
            System.out.println("\n4. UPDATING POSITIONS ALONG ROUTE");
            for (int i = 1; i < route.size(); i++) {
                RouteStop stop = route.get(i);
                batch = client.createUpsertBatch();
                event = new GeoEvent.Builder()
                    .setEntityId(entityId)
                    .setLatitude(stop.lat)
                    .setLongitude(stop.lon)
                    .setTimestamp(baseTime + (i * 60_000_000_000L))  // 1 minute apart
                    .setVelocityMms(5000)
                    .setHeadingCdeg((short) 31500)
                    .setGroupId(1L)
                    .build();
                batch.add(event);
                batch.commit();
                System.out.printf("   Updated to %s: (%.4f, %.4f)%n", stop.name, stop.lat, stop.lon);
            }

            // Query to verify latest position
            System.out.println("\n5. VERIFYING LATEST POSITION");
            found = client.getLatestByUuid(entityId);
            if (found != null) {
                System.out.printf("   Latest position: (%.4f, %.4f)%n", found.getLatitude(), found.getLongitude());
                RouteStop lastStop = route.get(route.size() - 1);
                System.out.printf("   Expected: %s (%.4f, %.4f)%n", lastStop.name, lastStop.lat, lastStop.lon);
            }

            // Query historical positions in the area
            System.out.println("\n6. QUERYING HISTORICAL POSITIONS IN AREA");
            QueryRadiusFilter filter = QueryRadiusFilter.create(
                37.8020,  // Center between start and end
                -122.4057,
                2000,  // 2km radius
                1000
            );
            QueryResult result = client.queryRadius(filter);
            System.out.println("   Found " + result.getEvents().size() + " historical positions in 2km area");

            // Delete the entity
            System.out.println("\n7. DELETING ENTITY");
            DeleteEntityBatch deleteBatch = client.createDeleteBatch();
            deleteBatch.add(entityId);
            DeleteResult deleteResult = deleteBatch.commit();
            System.out.println("   Deleted " + deleteResult.getDeletedCount() + " entities");
            System.out.println("   Not found: " + deleteResult.getNotFoundCount());

            // Verify deletion
            System.out.println("\n8. VERIFYING DELETION");
            found = client.getLatestByUuid(entityId);
            if (found == null) {
                System.out.println("   Entity successfully deleted (not found)");
            } else {
                System.out.println("   Warning: Entity still found after deletion");
            }

            System.out.println("\n==================================================");
            System.out.println("Walkthrough complete!");
            System.out.println("ok");
        }
    }
}
// endsection:imports
