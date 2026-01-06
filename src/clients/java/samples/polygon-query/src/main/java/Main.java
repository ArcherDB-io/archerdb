package com.archerdb.samples;

/**
 * ArcherDB Polygon Query Sample - Geofence Queries
 *
 * This sample demonstrates:
 * 1. Creating polygon-based geofences
 * 2. Querying events within polygon boundaries
 * 3. Comparing polygon vs radius queries
 */

import java.util.List;
import java.util.ArrayList;

import com.archerdb.geo.*;

public final class Main {
    // Named location for tracking
    static class Location {
        String name;
        double lat;
        double lon;

        Location(String name, double lat, double lon) {
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

            long nowNs = System.nanoTime();

            // Insert events in the San Francisco Financial District area
            GeoEventBatch batch = client.createBatch();
            List<Location> locations = new ArrayList<>();

            // Inside the polygon (Financial District)
            locations.add(new Location("Transamerica Pyramid", 37.7952, -122.4028));
            locations.add(new Location("Salesforce Tower", 37.7897, -122.3972));
            locations.add(new Location("Embarcadero Center", 37.7946, -122.3984));
            // Outside the polygon (other areas)
            locations.add(new Location("Golden Gate Bridge", 37.8199, -122.4783));
            locations.add(new Location("Alcatraz", 37.8270, -122.4230));
            locations.add(new Location("Twin Peaks", 37.7544, -122.4477));

            for (int i = 0; i < locations.size(); i++) {
                Location loc = locations.get(i);
                GeoEvent event = new GeoEvent.Builder()
                    .setEntityId(UInt128.random())
                    .setLatitude(loc.lat)
                    .setLongitude(loc.lon)
                    .setTimestamp(nowNs + i)
                    .setGroupId(1L)
                    .build();
                batch.add(event);
                System.out.printf("  Added %s: (%.4f, %.4f)%n", loc.name, loc.lat, loc.lon);
            }

            batch.commit();
            System.out.println("\nInserted " + locations.size() + " events\n");

            // Define a polygon around the Financial District
            // Vertices must be in order (clockwise or counter-clockwise)
            double[][] polygonVertices = {
                {37.7980, -122.4050},  // Northwest corner
                {37.7980, -122.3900},  // Northeast corner
                {37.7860, -122.3900},  // Southeast corner
                {37.7860, -122.4050},  // Southwest corner
            };

            System.out.println("Querying Financial District polygon:");
            System.out.printf("  Vertices: [");
            for (int i = 0; i < polygonVertices.length; i++) {
                if (i > 0) System.out.print(", ");
                System.out.printf("(%.4f, %.4f)", polygonVertices[i][0], polygonVertices[i][1]);
            }
            System.out.println("]\n");

            QueryPolygonFilter polygonFilter = QueryPolygonFilter.builder()
                .addVertex(polygonVertices[0][0], polygonVertices[0][1])
                .addVertex(polygonVertices[1][0], polygonVertices[1][1])
                .addVertex(polygonVertices[2][0], polygonVertices[2][1])
                .addVertex(polygonVertices[3][0], polygonVertices[3][1])
                .setLimit(1000)
                .build();

            QueryResult result = client.queryPolygon(polygonFilter);

            System.out.println("Found " + result.getEvents().size() + " events inside Financial District:");
            for (GeoEvent event : result.getEvents()) {
                // Find the name
                String name = "Unknown";
                for (Location loc : locations) {
                    if (Math.abs(event.getLatitude() - loc.lat) < 0.0001 &&
                        Math.abs(event.getLongitude() - loc.lon) < 0.0001) {
                        name = loc.name;
                        break;
                    }
                }
                System.out.printf("  %s: (%.4f, %.4f)%n", name, event.getLatitude(), event.getLongitude());
            }

            // Compare with radius query from center of polygon
            double centerLat = 37.7920;
            double centerLon = -122.3975;
            double radiusM = 1000;

            QueryResult resultRadius = client.queryRadius(
                QueryRadiusFilter.create(centerLat, centerLon, radiusM, 1000)
            );

            System.out.println("\nRadius query (1km from center): " + resultRadius.getEvents().size() + " events");
            System.out.println("(Radius queries cover circular areas; polygons allow precise boundaries)");

            System.out.println("\nok");
        }
    }
}
