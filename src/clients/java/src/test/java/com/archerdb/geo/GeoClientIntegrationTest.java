package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import com.archerdb.geo.UInt128;

class GeoClientIntegrationTest {

    private static final String ADDRESS =
            System.getenv().getOrDefault("ARCHERDB_ADDRESS", "127.0.0.1:3001");

    @BeforeAll
    static void checkIntegration() {
        Assumptions.assumeTrue("1".equals(System.getenv("ARCHERDB_INTEGRATION")),
                "Set ARCHERDB_INTEGRATION=1 to run integration tests");
        Assumptions.assumeTrue(
                Boolean.parseBoolean(System.getProperty("archerdb.native.enabled", "false")),
                "Native bindings are disabled");
    }

    @Test
    void insertEventsMultiBatch() {
        try (GeoClient client = GeoClient.create(UInt128.of(0L), ADDRESS)) {
            List<GeoEvent> events = List.of(
                    new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                            .setLongitude(-122.4194).build(),
                    new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7750)
                            .setLongitude(-122.4195).build(),
                    new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7751)
                            .setLongitude(-122.4196).build());

            RetryPolicy policy = RetryPolicy.builder().setMaxRetries(0).setBaseBackoffMs(0)
                    .setMaxBackoffMs(0).setJitterEnabled(false).build();

            List<InsertGeoEventsError> errors = GeoClientImpl.submitInsertEventsBatched(events, 2,
                    policy, batch -> ((GeoClientImpl) client).submitInsertEventsOnce(batch, false));

            assertTrue(errors.isEmpty());
        }
    }

    @Test
    void insertQueryDeleteRoundTrip() {
        try (GeoClient client = GeoClient.create(UInt128.of(0L), ADDRESS)) {
            UInt128 entityId = UInt128.random();
            double lat = 37.7749;
            double lon = -122.4194;

            // 1. Insert
            GeoEvent event = new GeoEvent.Builder().setEntityId(entityId).setLatitude(lat)
                    .setLongitude(lon).setTtlSeconds(60).build();

            List<InsertGeoEventsError> errors = client.insertEvents(List.of(event));
            assertTrue(errors.isEmpty(), "Insert should succeed");

            // 2. Query UUID
            // Retry a few times to allow for propagation
            GeoEvent found = null;
            for (int i = 0; i < 10; i++) {
                found = client.getLatestByUuid(entityId);
                if (found != null) {
                    break;
                }
                try {
                    Thread.sleep(100);
                } catch (InterruptedException e) {
                }
            }

            assertNotNull(found, "Entity should be found");
            assertEquals(entityId, found.getEntityId());

            // 3. Query Radius
            QueryResult radiusResult =
                    client.queryRadius(QueryRadiusFilter.create(lat, lon, 2000, 5));
            assertTrue(!radiusResult.getEvents().isEmpty(), "Radius query should find events");

            // 4. Delete
            DeleteResult deleteResult = client.deleteEntities(List.of(entityId));
            assertEquals(1, deleteResult.getDeletedCount());

            // 5. Verify Delete
            GeoEvent missing = client.getLatestByUuid(entityId);
            assertNull(missing, "Entity should be deleted");
        }
    }
}
