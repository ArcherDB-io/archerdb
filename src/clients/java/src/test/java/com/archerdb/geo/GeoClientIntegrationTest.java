package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

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
}
