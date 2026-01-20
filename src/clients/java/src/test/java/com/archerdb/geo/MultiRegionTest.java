package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

/**
 * Unit tests for multi-region support classes.
 *
 * <p>
 * Tests cover:
 * <ul>
 * <li>ReadPreference enum</li>
 * <li>RegionRole enum</li>
 * <li>RegionConfig</li>
 * <li>ClientConfig</li>
 * <li>MultiRegionError</li>
 * <li>ResponseMetadata</li>
 * <li>MultiRegionGeoClient</li>
 * </ul>
 */
class MultiRegionTest {

    private GeoClient client;

    @AfterEach
    void tearDown() {
        if (client != null) {
            client.close();
        }
    }

    // ========================================================================
    // ReadPreference Tests
    // ========================================================================

    @Test
    void testReadPreferenceValues() {
        assertEquals("primary", ReadPreference.PRIMARY.getValue());
        assertEquals("follower", ReadPreference.FOLLOWER.getValue());
        assertEquals("nearest", ReadPreference.NEAREST.getValue());
    }

    @Test
    void testReadPreferenceFromValue() {
        assertEquals(ReadPreference.PRIMARY, ReadPreference.fromValue("primary"));
        assertEquals(ReadPreference.FOLLOWER, ReadPreference.fromValue("follower"));
        assertEquals(ReadPreference.NEAREST, ReadPreference.fromValue("nearest"));
    }

    @Test
    void testReadPreferenceFromValueCaseInsensitive() {
        assertEquals(ReadPreference.PRIMARY, ReadPreference.fromValue("PRIMARY"));
        assertEquals(ReadPreference.FOLLOWER, ReadPreference.fromValue("Follower"));
        assertEquals(ReadPreference.NEAREST, ReadPreference.fromValue("NEAREST"));
    }

    @Test
    void testReadPreferenceFromValueInvalid() {
        assertThrows(IllegalArgumentException.class, () -> {
            ReadPreference.fromValue("invalid");
        });
    }

    @Test
    void testReadPreferenceFromValueNull() {
        assertThrows(IllegalArgumentException.class, () -> {
            ReadPreference.fromValue(null);
        });
    }

    // ========================================================================
    // RegionRole Tests
    // ========================================================================

    @Test
    void testRegionRoleValues() {
        assertEquals("primary", RegionRole.PRIMARY.getValue());
        assertEquals("follower", RegionRole.FOLLOWER.getValue());
    }

    @Test
    void testRegionRoleFromValue() {
        assertEquals(RegionRole.PRIMARY, RegionRole.fromValue("primary"));
        assertEquals(RegionRole.FOLLOWER, RegionRole.fromValue("follower"));
    }

    @Test
    void testRegionRoleFromValueInvalid() {
        assertThrows(IllegalArgumentException.class, () -> {
            RegionRole.fromValue("replica");
        });
    }

    // ========================================================================
    // RegionConfig Tests
    // ========================================================================

    @Test
    void testRegionConfigCreate() {
        RegionConfig region = RegionConfig.create("us-west-2", new String[] {"10.0.0.1:3001"},
                RegionRole.PRIMARY);

        assertEquals("us-west-2", region.getName());
        assertArrayEquals(new String[] {"10.0.0.1:3001"}, region.getAddresses());
        assertEquals(RegionRole.PRIMARY, region.getRole());
        assertTrue(region.isPrimary());
        assertFalse(region.isFollower());
    }

    @Test
    void testRegionConfigPrimary() {
        RegionConfig region = RegionConfig.primary("us-west-2", "10.0.0.1:3001", "10.0.0.2:3001");

        assertEquals("us-west-2", region.getName());
        assertTrue(region.isPrimary());
        assertEquals(2, region.getAddresses().length);
    }

    @Test
    void testRegionConfigFollower() {
        RegionConfig region = RegionConfig.follower("eu-west-1", "10.1.0.1:3001");

        assertEquals("eu-west-1", region.getName());
        assertTrue(region.isFollower());
        assertFalse(region.isPrimary());
    }

    @Test
    void testRegionConfigBuilder() {
        RegionConfig region = new RegionConfig.Builder().setName("ap-northeast-1")
                .setAddresses("10.2.0.1:3001").setRole(RegionRole.FOLLOWER).build();

        assertEquals("ap-northeast-1", region.getName());
        assertTrue(region.isFollower());
    }

    @Test
    void testRegionConfigNullName() {
        assertThrows(IllegalArgumentException.class, () -> {
            RegionConfig.create(null, new String[] {"10.0.0.1:3001"}, RegionRole.PRIMARY);
        });
    }

    @Test
    void testRegionConfigEmptyAddresses() {
        assertThrows(IllegalArgumentException.class, () -> {
            RegionConfig.create("us-west-2", new String[] {}, RegionRole.PRIMARY);
        });
    }

    @Test
    void testRegionConfigEquality() {
        RegionConfig r1 = RegionConfig.primary("us-west-2", "10.0.0.1:3001");
        RegionConfig r2 = RegionConfig.primary("us-west-2", "10.0.0.1:3001");
        RegionConfig r3 = RegionConfig.follower("us-west-2", "10.0.0.1:3001");

        assertEquals(r1, r2);
        assertNotEquals(r1, r3); // Different role
        assertEquals(r1.hashCode(), r2.hashCode());
    }

    // ========================================================================
    // ClientConfig Tests
    // ========================================================================

    @Test
    void testClientConfigSingleRegion() {
        ClientConfig config =
                ClientConfig.singleRegion(UInt128.of(1L), "127.0.0.1:3001", "127.0.0.2:3001");

        assertNotNull(config.getClusterId());
        assertEquals(1, config.getRegions().size());
        assertTrue(config.getRegions().get(0).isPrimary());
        assertEquals(ReadPreference.PRIMARY, config.getReadPreference());
    }

    @Test
    void testClientConfigBuilder() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "10.0.0.1:3001"))
                .addRegion(RegionConfig.follower("eu-west-1", "10.1.0.1:3001"))
                .setReadPreference(ReadPreference.NEAREST).setRequestTimeoutMs(60000)
                .setMaxStalenessMs(5000).build();

        assertEquals(2, config.getRegions().size());
        assertEquals(ReadPreference.NEAREST, config.getReadPreference());
        assertEquals(60000, config.getRequestTimeoutMs());
        assertEquals(5000, config.getMaxStalenessMs());
    }

    @Test
    void testClientConfigGetPrimaryRegion() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.follower("eu-west-1", "10.1.0.1:3001"))
                .addRegion(RegionConfig.primary("us-west-2", "10.0.0.1:3001")).build();

        RegionConfig primary = config.getPrimaryRegion();
        assertNotNull(primary);
        assertEquals("us-west-2", primary.getName());
    }

    @Test
    void testClientConfigGetFollowerRegions() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "10.0.0.1:3001"))
                .addRegion(RegionConfig.follower("eu-west-1", "10.1.0.1:3001"))
                .addRegion(RegionConfig.follower("ap-northeast-1", "10.2.0.1:3001")).build();

        List<RegionConfig> followers = config.getFollowerRegions();
        assertEquals(2, followers.size());
        assertTrue(followers.stream().allMatch(RegionConfig::isFollower));
    }

    @Test
    void testClientConfigGetRegionByName() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "10.0.0.1:3001"))
                .addRegion(RegionConfig.follower("eu-west-1", "10.1.0.1:3001")).build();

        assertNotNull(config.getRegion("us-west-2"));
        assertNotNull(config.getRegion("eu-west-1"));
        assertNull(config.getRegion("ap-northeast-1"));
    }

    @Test
    void testClientConfigNoPrimary() {
        assertThrows(IllegalArgumentException.class, () -> {
            ClientConfig.builder().setClusterId(UInt128.of(1L))
                    .addRegion(RegionConfig.follower("eu-west-1", "10.1.0.1:3001")).build();
        });
    }

    @Test
    void testClientConfigMultiplePrimaries() {
        assertThrows(IllegalArgumentException.class, () -> {
            ClientConfig.builder().setClusterId(UInt128.of(1L))
                    .addRegion(RegionConfig.primary("us-west-2", "10.0.0.1:3001"))
                    .addRegion(RegionConfig.primary("eu-west-1", "10.1.0.1:3001")).build();
        });
    }

    @Test
    void testClientConfigNoClusterId() {
        assertThrows(IllegalArgumentException.class, () -> {
            ClientConfig.builder().addRegion(RegionConfig.primary("us-west-2", "10.0.0.1:3001"))
                    .build();
        });
    }

    @Test
    void testClientConfigNoRegions() {
        assertThrows(IllegalArgumentException.class, () -> {
            ClientConfig.builder().setClusterId(UInt128.of(1L)).build();
        });
    }

    // ========================================================================
    // MultiRegionError Tests
    // ========================================================================

    @Test
    void testMultiRegionErrorCodes() {
        assertEquals(213, MultiRegionError.FOLLOWER_READ_ONLY.getCode());
        assertEquals(214, MultiRegionError.STALE_FOLLOWER.getCode());
        assertEquals(215, MultiRegionError.PRIMARY_UNREACHABLE.getCode());
        assertEquals(216, MultiRegionError.REPLICATION_TIMEOUT.getCode());
        assertEquals(217, MultiRegionError.CONFLICT_DETECTED.getCode());
        assertEquals(218, MultiRegionError.GEO_SHARD_MISMATCH.getCode());
    }

    @Test
    void testMultiRegionErrorFromCode() {
        assertEquals(MultiRegionError.FOLLOWER_READ_ONLY, MultiRegionError.fromCode(213));
        assertEquals(MultiRegionError.STALE_FOLLOWER, MultiRegionError.fromCode(214));
        assertNull(MultiRegionError.fromCode(999));
    }

    @Test
    void testIsMultiRegionError() {
        assertTrue(MultiRegionError.isMultiRegionError(213));
        assertTrue(MultiRegionError.isMultiRegionError(218));
        assertFalse(MultiRegionError.isMultiRegionError(212));
        assertFalse(MultiRegionError.isMultiRegionError(219));
    }

    @Test
    void testMultiRegionErrorMessages() {
        assertNotNull(MultiRegionError.FOLLOWER_READ_ONLY.getMessage());
        assertTrue(MultiRegionError.FOLLOWER_READ_ONLY.getMessage().contains("read-only"));
    }

    // ========================================================================
    // ResponseMetadata Tests
    // ========================================================================

    @Test
    void testResponseMetadataPrimary() {
        ResponseMetadata metadata = ResponseMetadata.PRIMARY;

        assertEquals(0, metadata.getReadStalenessNs());
        assertEquals(0, metadata.getReadStalenessMs());
        assertTrue(metadata.isFromPrimary());
        assertFalse(metadata.isFromFollower());
        assertFalse(metadata.isStale());
    }

    @Test
    void testResponseMetadataFollower() {
        ResponseMetadata metadata = new ResponseMetadata(5_000_000L, // 5ms staleness
                "eu-west-1", 12345L, RegionRole.FOLLOWER);

        assertEquals(5_000_000L, metadata.getReadStalenessNs());
        assertEquals(5, metadata.getReadStalenessMs());
        assertEquals("eu-west-1", metadata.getSourceRegion());
        assertEquals(12345L, metadata.getMinCommitOp());
        assertFalse(metadata.isFromPrimary());
        assertTrue(metadata.isFromFollower());
        assertTrue(metadata.isStale());
    }

    @Test
    void testResponseMetadataBuilder() {
        ResponseMetadata metadata = ResponseMetadata.builder().setReadStalenessNs(10_000_000L)
                .setSourceRegion("ap-northeast-1").setMinCommitOp(99999L)
                .setSourceRole(RegionRole.FOLLOWER).build();

        assertEquals(10_000_000L, metadata.getReadStalenessNs());
        assertEquals("ap-northeast-1", metadata.getSourceRegion());
        assertEquals(99999L, metadata.getMinCommitOp());
        assertTrue(metadata.isFromFollower());
    }

    @Test
    void testResponseMetadataEquality() {
        ResponseMetadata m1 =
                new ResponseMetadata(5_000_000L, "eu-west-1", 123L, RegionRole.FOLLOWER);
        ResponseMetadata m2 =
                new ResponseMetadata(5_000_000L, "eu-west-1", 123L, RegionRole.FOLLOWER);
        ResponseMetadata m3 =
                new ResponseMetadata(6_000_000L, "eu-west-1", 123L, RegionRole.FOLLOWER);

        assertEquals(m1, m2);
        assertNotEquals(m1, m3);
        assertEquals(m1.hashCode(), m2.hashCode());
    }

    // ========================================================================
    // QueryResult with Metadata Tests
    // ========================================================================

    @Test
    void testQueryResultDefaultMetadata() {
        QueryResult result = new QueryResult(List.of(), false, 0);

        assertNotNull(result.getMetadata());
        assertEquals(ResponseMetadata.PRIMARY, result.getMetadata());
        assertEquals(0, result.getReadStalenessNs());
        assertFalse(result.isFromFollower());
    }

    @Test
    void testQueryResultWithFollowerMetadata() {
        ResponseMetadata metadata =
                new ResponseMetadata(10_000_000L, "eu-west-1", 123L, RegionRole.FOLLOWER);
        QueryResult result = new QueryResult(List.of(), false, 0, metadata);

        assertEquals(10_000_000L, result.getReadStalenessNs());
        assertTrue(result.isFromFollower());
        assertEquals("eu-west-1", result.getMetadata().getSourceRegion());
    }

    // ========================================================================
    // MultiRegionGeoClient Tests
    // ========================================================================

    @Test
    void testMultiRegionClientCreation() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "127.0.0.1:3001"))
                .addRegion(RegionConfig.follower("eu-west-1", "127.0.0.1:3002")).build();

        client = GeoClient.create(config);

        assertNotNull(client);
        assertNotNull(client.getConfig());
        assertEquals(ReadPreference.PRIMARY, client.getReadPreference());
    }

    @Test
    void testMultiRegionClientWithNearestPreference() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "127.0.0.1:3001"))
                .setReadPreference(ReadPreference.NEAREST).build();

        client = GeoClient.create(config);

        assertEquals(ReadPreference.NEAREST, client.getReadPreference());
    }

    @Test
    void testMultiRegionClientPing() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "127.0.0.1:3001")).build();

        client = GeoClient.create(config);

        // Skeleton mode always returns true
        assertTrue(client.ping());
    }

    @Test
    void testMultiRegionClientClose() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "127.0.0.1:3001")).build();

        client = GeoClient.create(config);
        client.close();

        // Double close should be safe
        client.close();

        assertThrows(IllegalStateException.class, () -> {
            client.ping();
        });
    }

    @Test
    void testMultiRegionClientBatchOperations() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "127.0.0.1:3001")).build();

        client = GeoClient.create(config);

        // Batches should be created successfully
        assertNotNull(client.createBatch());
        assertNotNull(client.createUpsertBatch());
        assertNotNull(client.createDeleteBatch());
    }

    @Test
    void testMultiRegionClientQueryOperations() {
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-west-2", "127.0.0.1:3001")).build();

        client = GeoClient.create(config);

        // All query operations should work
        QueryResult radius =
                client.queryRadius(QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100));
        assertNotNull(radius);

        QueryResult latest = client.queryLatest(QueryLatestFilter.global(100));
        assertNotNull(latest);
    }
}
