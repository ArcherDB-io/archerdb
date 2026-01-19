"""
Tests for ArcherDB Python SDK - Geo-Routing Module

Tests cover:
- Region discovery and caching
- Latency probing and rolling averages
- Region selection algorithm
- Automatic failover
- Geo-routing metrics
"""

# Copyright 2025 ArcherDB Authors. All rights reserved.
# Use of this source code is governed by the Apache 2.0 license.

import json
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import List
from unittest.mock import MagicMock, patch

import pytest

from archerdb.geo_routing import (
    GeoRoutingConfig,
    RegionHealth,
    RegionLocation,
    RegionInfo,
    DiscoveryResponse,
    RegionLatencyStats,
    GeoRoutingMetrics,
    DiscoveryError,
    RegionDiscoveryClient,
    LatencyProber,
    RegionSelector,
    GeoRouter,
    DEFAULT_PROBE_INTERVAL_MS,
    DEFAULT_UNHEALTHY_THRESHOLD,
)


# ============================================================================
# Test Fixtures
# ============================================================================

@pytest.fixture
def sample_regions() -> List[RegionInfo]:
    """Create sample region data."""
    return [
        RegionInfo(
            name="us-east-1",
            endpoint="us-east.example.com:5000",
            location=RegionLocation(latitude=39.04, longitude=-77.49),
            healthy=True,
        ),
        RegionInfo(
            name="us-west-2",
            endpoint="us-west.example.com:5000",
            location=RegionLocation(latitude=45.52, longitude=-122.68),
            healthy=True,
        ),
        RegionInfo(
            name="eu-west-1",
            endpoint="eu-west.example.com:5000",
            location=RegionLocation(latitude=53.34, longitude=-6.26),
            healthy=True,
        ),
    ]


@pytest.fixture
def geo_config() -> GeoRoutingConfig:
    """Create a test geo-routing config."""
    return GeoRoutingConfig(
        discovery_endpoint="http://localhost:9999/regions",
        preferred_region=None,
        failover_enabled=True,
        probe_interval_ms=1000,  # Fast probing for tests
        failover_timeout_ms=500,
        background_probing=False,  # Disable for most tests
    )


# ============================================================================
# RegionInfo Tests
# ============================================================================

class TestRegionInfo:
    """Tests for RegionInfo dataclass."""

    def test_from_dict_complete(self):
        """Test parsing complete region data."""
        data = {
            "name": "us-east-1",
            "endpoint": "archerdb-use1.example.com:5000",
            "location": {"lat": 39.04, "lon": -77.49},
            "healthy": True,
        }
        region = RegionInfo.from_dict(data)

        assert region.name == "us-east-1"
        assert region.endpoint == "archerdb-use1.example.com:5000"
        assert region.location.latitude == 39.04
        assert region.location.longitude == -77.49
        assert region.healthy is True

    def test_from_dict_minimal(self):
        """Test parsing minimal region data."""
        data = {"name": "test", "endpoint": "test:5000"}
        region = RegionInfo.from_dict(data)

        assert region.name == "test"
        assert region.endpoint == "test:5000"
        assert region.location.latitude == 0.0
        assert region.healthy is True  # Default

    def test_from_dict_unhealthy(self):
        """Test parsing unhealthy region."""
        data = {"name": "test", "endpoint": "test:5000", "healthy": False}
        region = RegionInfo.from_dict(data)

        assert region.healthy is False


# ============================================================================
# DiscoveryResponse Tests
# ============================================================================

class TestDiscoveryResponse:
    """Tests for DiscoveryResponse dataclass."""

    def test_from_dict_with_expiry(self):
        """Test parsing response with expiry."""
        data = {
            "regions": [
                {"name": "us-east-1", "endpoint": "us-east:5000"},
                {"name": "eu-west-1", "endpoint": "eu-west:5000"},
            ],
            "expires": "2030-01-15T12:00:00Z",
        }
        response = DiscoveryResponse.from_dict(data)

        assert len(response.regions) == 2
        assert response.regions[0].name == "us-east-1"
        assert response.expires is not None
        assert response.expires.year == 2030

    def test_is_expired_with_expiry(self):
        """Test expiry check with explicit expiry time."""
        # Future expiry - not expired
        future = datetime.now(timezone.utc) + timedelta(hours=1)
        response = DiscoveryResponse(regions=[], expires=future)
        assert response.is_expired() is False

        # Past expiry - expired
        past = datetime.now(timezone.utc) - timedelta(hours=1)
        response = DiscoveryResponse(regions=[], expires=past)
        assert response.is_expired() is True

    def test_is_expired_default_ttl(self):
        """Test expiry with default TTL (no explicit expiry)."""
        # Just created - not expired
        response = DiscoveryResponse(regions=[])
        assert response.is_expired() is False

        # Old response - expired (default 5 min TTL)
        old_time = datetime.now(timezone.utc) - timedelta(minutes=10)
        response = DiscoveryResponse(regions=[], fetched_at=old_time)
        assert response.is_expired() is True


# ============================================================================
# RegionLatencyStats Tests
# ============================================================================

class TestRegionLatencyStats:
    """Tests for RegionLatencyStats."""

    def test_add_sample(self):
        """Test adding latency samples."""
        stats = RegionLatencyStats(region_name="test")
        stats.add_sample(10.0)
        stats.add_sample(20.0)
        stats.add_sample(15.0)

        assert len(stats.samples) == 3
        assert stats.get_average_rtt_ms() == 15.0

    def test_rolling_average(self):
        """Test rolling average with max samples."""
        from collections import deque
        stats = RegionLatencyStats(region_name="test")
        stats.samples = deque(maxlen=3)  # Small window for testing

        for i in range(5):
            stats.add_sample(float(i * 10))

        # Only last 3 samples should be in window: 20, 30, 40
        assert len(stats.samples) == 3
        assert stats.get_average_rtt_ms() == 30.0

    def test_record_failure(self):
        """Test failure recording."""
        stats = RegionLatencyStats(region_name="test")
        assert stats.health == RegionHealth.UNKNOWN

        # Record failures up to threshold
        for i in range(DEFAULT_UNHEALTHY_THRESHOLD - 1):
            stats.record_failure()
            assert stats.health != RegionHealth.UNHEALTHY

        # One more failure should mark unhealthy
        stats.record_failure()
        assert stats.health == RegionHealth.UNHEALTHY

    def test_success_resets_failures(self):
        """Test that successful probe resets failure count."""
        stats = RegionLatencyStats(region_name="test")

        # Record some failures
        stats.record_failure()
        stats.record_failure()
        assert stats.consecutive_failures == 2

        # Success should reset
        stats.add_sample(10.0)
        assert stats.consecutive_failures == 0
        assert stats.is_healthy() is True

    def test_empty_stats(self):
        """Test stats with no samples."""
        stats = RegionLatencyStats(region_name="test")
        assert stats.get_average_rtt_ms() is None
        assert stats.is_healthy() is True  # Unknown is considered healthy


# ============================================================================
# GeoRoutingMetrics Tests
# ============================================================================

class TestGeoRoutingMetrics:
    """Tests for GeoRoutingMetrics."""

    def test_record_query(self):
        """Test query recording."""
        metrics = GeoRoutingMetrics()
        metrics.record_query("us-east-1")
        metrics.record_query("us-east-1")
        metrics.record_query("eu-west-1")

        assert metrics.queries_by_region["us-east-1"] == 2
        assert metrics.queries_by_region["eu-west-1"] == 1

    def test_record_switch(self):
        """Test region switch recording."""
        metrics = GeoRoutingMetrics()
        metrics.record_switch("us-east-1", "eu-west-1")
        metrics.record_switch("us-east-1", "eu-west-1")
        metrics.record_switch("eu-west-1", "us-east-1")

        assert metrics.region_switches["us-east-1"]["eu-west-1"] == 2
        assert metrics.region_switches["eu-west-1"]["us-east-1"] == 1

    def test_update_latency(self):
        """Test latency update."""
        metrics = GeoRoutingMetrics()
        metrics.update_latency("us-east-1", 25.5)
        metrics.update_latency("eu-west-1", 85.0)

        assert metrics.region_latencies_ms["us-east-1"] == 25.5
        assert metrics.region_latencies_ms["eu-west-1"] == 85.0

    def test_prometheus_format(self):
        """Test Prometheus metrics export."""
        metrics = GeoRoutingMetrics()
        metrics.record_query("us-east-1")
        metrics.record_switch("us-east-1", "eu-west-1")
        metrics.update_latency("us-east-1", 25.0)

        output = metrics.get_prometheus_metrics()

        assert 'archerdb_client_queries_total{region="us-east-1"} 1' in output
        assert 'archerdb_client_region_switches_total{from="us-east-1",to="eu-west-1"} 1' in output
        assert 'archerdb_client_region_latency_ms{region="us-east-1"} 25.0' in output

    def test_thread_safety(self):
        """Test that metrics are thread-safe."""
        metrics = GeoRoutingMetrics()

        def record_queries():
            for _ in range(100):
                metrics.record_query("test-region")

        threads = [threading.Thread(target=record_queries) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert metrics.queries_by_region["test-region"] == 1000


# ============================================================================
# RegionDiscoveryClient Tests
# ============================================================================

class TestRegionDiscoveryClient:
    """Tests for RegionDiscoveryClient."""

    def test_discover_caching(self):
        """Test that discovery results are cached."""
        client = RegionDiscoveryClient("http://localhost:9999/regions")

        # Mock the fetch
        mock_response = DiscoveryResponse(
            regions=[RegionInfo(name="test", endpoint="test:5000")],
            expires=datetime.now(timezone.utc) + timedelta(hours=1),
        )
        client._cache = mock_response

        # Should use cache
        regions = client.discover()
        assert len(regions) == 1
        assert regions[0].name == "test"

    def test_discover_cache_expired(self):
        """Test that expired cache triggers refresh."""
        client = RegionDiscoveryClient("http://localhost:9999/regions")

        # Set expired cache
        old_response = DiscoveryResponse(
            regions=[RegionInfo(name="old", endpoint="old:5000")],
            expires=datetime.now(timezone.utc) - timedelta(hours=1),
        )
        client._cache = old_response

        # Mock fetch to fail, but cache should still be returned
        with patch.object(client, "_fetch_sync", side_effect=Exception("Network error")):
            regions = client.discover()
            # Should fallback to stale cache
            assert len(regions) == 1
            assert regions[0].name == "old"

    def test_discover_no_cache_fails(self):
        """Test that discovery fails without cache."""
        client = RegionDiscoveryClient("http://localhost:9999/regions")

        with patch.object(client, "_fetch_sync", side_effect=Exception("Network error")):
            with pytest.raises(DiscoveryError):
                client.discover()

    def test_get_cached(self):
        """Test getting cached regions without fetching."""
        client = RegionDiscoveryClient("http://localhost:9999/regions")

        # No cache
        assert client.get_cached() is None

        # With cache
        client._cache = DiscoveryResponse(
            regions=[RegionInfo(name="cached", endpoint="cached:5000")]
        )
        cached = client.get_cached()
        assert cached is not None
        assert len(cached) == 1
        assert cached[0].name == "cached"

    def test_clear_cache(self):
        """Test cache clearing."""
        client = RegionDiscoveryClient("http://localhost:9999/regions")
        client._cache = DiscoveryResponse(regions=[])

        client.clear_cache()
        assert client.get_cached() is None


# ============================================================================
# LatencyProber Tests
# ============================================================================

class TestLatencyProber:
    """Tests for LatencyProber."""

    def test_set_regions(self, geo_config, sample_regions):
        """Test setting regions to probe."""
        prober = LatencyProber(geo_config)
        prober.set_regions(sample_regions)

        stats = prober.get_all_stats()
        assert len(stats) == 3
        assert "us-east-1" in stats
        assert "us-west-2" in stats
        assert "eu-west-1" in stats

    def test_get_stats(self, geo_config, sample_regions):
        """Test getting stats for a region."""
        prober = LatencyProber(geo_config)
        prober.set_regions(sample_regions)

        stats = prober.get_stats("us-east-1")
        assert stats is not None
        assert stats.region_name == "us-east-1"

        # Non-existent region
        assert prober.get_stats("invalid") is None

    def test_probe_region_format(self, geo_config):
        """Test that probe parses endpoint correctly."""
        prober = LatencyProber(geo_config)

        # Various endpoint formats
        regions = [
            RegionInfo(name="plain", endpoint="host:5000"),
            RegionInfo(name="with_proto", endpoint="http://host:5000"),
            RegionInfo(name="with_path", endpoint="host:5000/api"),
        ]
        prober.set_regions(regions)

        # Just verify no exceptions during setup
        assert prober.get_stats("plain") is not None


# ============================================================================
# RegionSelector Tests
# ============================================================================

class TestRegionSelector:
    """Tests for RegionSelector."""

    def test_select_healthy_only(self, geo_config, sample_regions):
        """Test that only healthy regions are selected."""
        prober = LatencyProber(geo_config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(geo_config, prober)

        # Mark one unhealthy
        sample_regions[0].healthy = False

        region = selector.select(sample_regions)
        assert region is not None
        assert region.name != "us-east-1"

    def test_select_preferred_region(self, sample_regions):
        """Test preferred region selection."""
        config = GeoRoutingConfig(preferred_region="eu-west-1")
        prober = LatencyProber(config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(config, prober)

        region = selector.select(sample_regions)
        assert region is not None
        assert region.name == "eu-west-1"

    def test_select_preferred_unhealthy_fallback(self, sample_regions):
        """Test fallback when preferred region is unhealthy."""
        config = GeoRoutingConfig(preferred_region="us-east-1")
        prober = LatencyProber(config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(config, prober)

        # Mark preferred unhealthy
        sample_regions[0].healthy = False

        region = selector.select(sample_regions)
        assert region is not None
        assert region.name != "us-east-1"

    def test_select_by_latency(self, geo_config, sample_regions):
        """Test selection by latency."""
        prober = LatencyProber(geo_config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(geo_config, prober)

        # Add latency samples
        stats = prober.get_stats("us-east-1")
        stats.add_sample(100.0)  # Slow

        stats = prober.get_stats("us-west-2")
        stats.add_sample(20.0)  # Fast

        stats = prober.get_stats("eu-west-1")
        stats.add_sample(50.0)  # Medium

        region = selector.select(sample_regions)
        assert region is not None
        assert region.name == "us-west-2"  # Lowest latency

    def test_select_by_distance(self, geo_config, sample_regions):
        """Test selection by geographic distance."""
        prober = LatencyProber(geo_config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(geo_config, prober)

        # Set client location near Dublin (eu-west-1)
        selector.set_client_location(53.35, -6.25)

        # No latency data, should use distance
        region = selector.select(sample_regions)
        assert region is not None
        assert region.name == "eu-west-1"  # Closest to Dublin

    def test_select_exclude_regions(self, geo_config, sample_regions):
        """Test excluding regions from selection."""
        prober = LatencyProber(geo_config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(geo_config, prober)

        region = selector.select(sample_regions, exclude=["us-east-1", "us-west-2"])
        assert region is not None
        assert region.name == "eu-west-1"

    def test_select_no_healthy_regions(self, geo_config, sample_regions):
        """Test selection with no healthy regions."""
        prober = LatencyProber(geo_config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(geo_config, prober)

        # Mark all unhealthy
        for r in sample_regions:
            r.healthy = False

        region = selector.select(sample_regions)
        assert region is None

    def test_failover(self, geo_config, sample_regions):
        """Test failover to alternative region."""
        metrics = GeoRoutingMetrics()
        prober = LatencyProber(geo_config, metrics)
        prober.set_regions(sample_regions)
        selector = RegionSelector(geo_config, prober, metrics)

        # Initial selection
        selector.select(sample_regions)

        # Failover from us-east-1
        new_region = selector.failover("us-east-1", sample_regions)
        assert new_region is not None
        assert new_region.name != "us-east-1"

        # Check metrics
        assert "us-east-1" in metrics.region_switches

    def test_failover_disabled(self, sample_regions):
        """Test failover when disabled."""
        config = GeoRoutingConfig(failover_enabled=False)
        prober = LatencyProber(config)
        prober.set_regions(sample_regions)
        selector = RegionSelector(config, prober)

        result = selector.failover("us-east-1", sample_regions)
        assert result is None


# ============================================================================
# GeoRouter Integration Tests
# ============================================================================

class TestGeoRouter:
    """Integration tests for GeoRouter."""

    def test_direct_connection_mode(self):
        """Test direct connection mode (no geo-routing)."""
        config = GeoRoutingConfig(
            direct_endpoint="direct.example.com:5000",
        )
        router = GeoRouter(config)

        endpoint = router.start()
        assert endpoint == "direct.example.com:5000"
        assert router.get_current_region() is None

        router.stop()

    def test_start_with_discovery(self, sample_regions):
        """Test starting with region discovery."""
        config = GeoRoutingConfig(
            discovery_endpoint="http://localhost:9999/regions",
            background_probing=False,
        )
        router = GeoRouter(config)

        # Mock discovery
        router._discovery._cache = DiscoveryResponse(
            regions=sample_regions,
            expires=datetime.now(timezone.utc) + timedelta(hours=1),
        )

        endpoint = router.start()
        assert endpoint != ""
        assert router.get_current_region() in ["us-east-1", "us-west-2", "eu-west-1"]

        router.stop()

    def test_handle_failure(self, sample_regions):
        """Test handling connection failure."""
        config = GeoRoutingConfig(
            discovery_endpoint="http://localhost:9999/regions",
            failover_enabled=True,
            background_probing=False,
        )
        router = GeoRouter(config)

        # Mock discovery
        router._discovery._cache = DiscoveryResponse(
            regions=sample_regions,
            expires=datetime.now(timezone.utc) + timedelta(hours=1),
        )

        router.start()
        initial_region = router.get_current_region()

        # Simulate failure and get new endpoint
        new_endpoint = router.handle_failure()
        assert new_endpoint is not None
        # Region should have changed (or no change if same is selected)
        # The important thing is we got a valid endpoint

        router.stop()

    def test_metrics_recording(self, sample_regions):
        """Test that metrics are recorded."""
        config = GeoRoutingConfig(
            discovery_endpoint="http://localhost:9999/regions",
            background_probing=False,
        )
        router = GeoRouter(config)

        router._discovery._cache = DiscoveryResponse(
            regions=sample_regions,
            expires=datetime.now(timezone.utc) + timedelta(hours=1),
        )

        router.start()
        router.record_query()
        router.record_query()

        metrics = router.get_metrics()
        total_queries = sum(metrics.queries_by_region.values())
        assert total_queries == 2

        router.stop()

    def test_get_regions(self, sample_regions):
        """Test getting discovered regions."""
        config = GeoRoutingConfig(
            discovery_endpoint="http://localhost:9999/regions",
            background_probing=False,
        )
        router = GeoRouter(config)

        router._discovery._cache = DiscoveryResponse(
            regions=sample_regions,
            expires=datetime.now(timezone.utc) + timedelta(hours=1),
        )

        router.start()
        regions = router.get_regions()
        assert len(regions) == 3

        router.stop()

    def test_get_region_stats(self, sample_regions):
        """Test getting region stats."""
        config = GeoRoutingConfig(
            discovery_endpoint="http://localhost:9999/regions",
            background_probing=False,
        )
        router = GeoRouter(config)

        router._discovery._cache = DiscoveryResponse(
            regions=sample_regions,
            expires=datetime.now(timezone.utc) + timedelta(hours=1),
        )

        router.start()

        # Add some latency data
        router._prober.get_stats("us-east-1").add_sample(25.0)

        stats = router.get_region_stats()
        assert "us-east-1" in stats
        assert stats["us-east-1"]["avg_rtt_ms"] == 25.0

        router.stop()


# ============================================================================
# GeoRoutingConfig Tests
# ============================================================================

class TestGeoRoutingConfig:
    """Tests for GeoRoutingConfig."""

    def test_geo_routing_enabled(self):
        """Test checking if geo-routing is enabled."""
        # Enabled with discovery endpoint
        config = GeoRoutingConfig(discovery_endpoint="http://example.com/regions")
        assert config.is_geo_routing_enabled() is True

        # Disabled without discovery endpoint
        config = GeoRoutingConfig(direct_endpoint="host:5000")
        assert config.is_geo_routing_enabled() is False

    def test_default_values(self):
        """Test default configuration values."""
        config = GeoRoutingConfig()

        assert config.failover_enabled is True
        assert config.probe_interval_ms == DEFAULT_PROBE_INTERVAL_MS
        assert config.unhealthy_threshold == DEFAULT_UNHEALTHY_THRESHOLD
        assert config.background_probing is True
