"""
ArcherDB Python SDK - Geo-Routing Client

This module provides geo-routing functionality including:
- Region discovery from /regions endpoint
- Latency probing with rolling averages
- Region selection based on latency and health
- Automatic failover to backup regions
- Metrics for monitoring
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
import math
import socket
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import IntEnum
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import httpx
    HAS_HTTPX = True
except ImportError:
    HAS_HTTPX = False

try:
    import aiohttp
    HAS_AIOHTTP = True
except ImportError:
    HAS_AIOHTTP = False


logger = logging.getLogger(__name__)


# ============================================================================
# Configuration
# ============================================================================

DEFAULT_PROBE_INTERVAL_MS = 30_000  # 30 seconds
DEFAULT_FAILOVER_TIMEOUT_MS = 5_000  # 5 seconds
DEFAULT_PROBE_SAMPLE_COUNT = 5  # Rolling average window
DEFAULT_UNHEALTHY_THRESHOLD = 3  # Consecutive failures before unhealthy


@dataclass
class GeoRoutingConfig:
    """
    Configuration for geo-routing behavior.

    Example:
        config = GeoRoutingConfig(
            discovery_endpoint="https://archerdb.example.com/regions",
            preferred_region="us-east-1",
            failover_enabled=True,
            probe_interval_ms=30000,
        )
    """
    # Discovery endpoint URL (e.g., "https://archerdb.example.com/regions")
    discovery_endpoint: Optional[str] = None

    # Direct endpoint for non-geo-routed connections
    direct_endpoint: Optional[str] = None

    # Preferred region name (optional)
    preferred_region: Optional[str] = None

    # Enable automatic failover to backup regions
    failover_enabled: bool = True

    # Interval between latency probes (milliseconds)
    probe_interval_ms: int = DEFAULT_PROBE_INTERVAL_MS

    # Timeout for failover operations (milliseconds)
    failover_timeout_ms: int = DEFAULT_FAILOVER_TIMEOUT_MS

    # Number of samples for rolling latency average
    probe_sample_count: int = DEFAULT_PROBE_SAMPLE_COUNT

    # Consecutive failures before marking region unhealthy
    unhealthy_threshold: int = DEFAULT_UNHEALTHY_THRESHOLD

    # Enable probing in background thread
    background_probing: bool = True

    def is_geo_routing_enabled(self) -> bool:
        """Check if geo-routing is enabled."""
        return self.discovery_endpoint is not None


# ============================================================================
# Region Data Types
# ============================================================================

class RegionHealth(IntEnum):
    """Health status of a region."""
    HEALTHY = 0
    DEGRADED = 1
    UNHEALTHY = 2
    UNKNOWN = 3


@dataclass
class RegionLocation:
    """Geographic location of a region."""
    latitude: float = 0.0
    longitude: float = 0.0


@dataclass
class RegionInfo:
    """
    Information about a single region.

    This corresponds to the /regions endpoint response format.
    """
    name: str = ""
    endpoint: str = ""
    location: RegionLocation = field(default_factory=RegionLocation)
    healthy: bool = True

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "RegionInfo":
        """Parse from JSON dict."""
        location = RegionLocation()
        if "location" in data:
            loc = data["location"]
            location = RegionLocation(
                latitude=float(loc.get("lat", 0)),
                longitude=float(loc.get("lon", 0)),
            )
        return cls(
            name=str(data.get("name", "")),
            endpoint=str(data.get("endpoint", "")),
            location=location,
            healthy=bool(data.get("healthy", True)),
        )


@dataclass
class DiscoveryResponse:
    """
    Response from the /regions discovery endpoint.

    Format:
        {
            "regions": [...],
            "expires": "2024-01-15T12:00:00Z"
        }
    """
    regions: List[RegionInfo] = field(default_factory=list)
    expires: Optional[datetime] = None
    fetched_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "DiscoveryResponse":
        """Parse from JSON dict."""
        regions = [RegionInfo.from_dict(r) for r in data.get("regions", [])]
        expires = None
        if "expires" in data:
            try:
                expires = datetime.fromisoformat(data["expires"].replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                pass
        return cls(
            regions=regions,
            expires=expires,
            fetched_at=datetime.now(timezone.utc),
        )

    def is_expired(self) -> bool:
        """Check if the cached response is expired."""
        if self.expires is None:
            # Default to 5 minute TTL if no expiry specified
            default_ttl = 300  # seconds
            return (datetime.now(timezone.utc) - self.fetched_at).total_seconds() > default_ttl
        return datetime.now(timezone.utc) > self.expires


# ============================================================================
# Latency Tracking
# ============================================================================

@dataclass
class LatencyMeasurement:
    """Single latency measurement."""
    rtt_ms: float
    timestamp: float = field(default_factory=time.time)


@dataclass
class RegionLatencyStats:
    """Latency statistics for a region."""
    region_name: str
    samples: deque = field(default_factory=lambda: deque(maxlen=DEFAULT_PROBE_SAMPLE_COUNT))
    last_probe_time: float = 0.0
    consecutive_failures: int = 0
    health: RegionHealth = RegionHealth.UNKNOWN

    def add_sample(self, rtt_ms: float) -> None:
        """Add a latency sample."""
        self.samples.append(LatencyMeasurement(rtt_ms=rtt_ms))
        self.last_probe_time = time.time()
        self.consecutive_failures = 0
        if self.health == RegionHealth.UNHEALTHY or self.health == RegionHealth.UNKNOWN:
            self.health = RegionHealth.HEALTHY

    def record_failure(self, threshold: int = DEFAULT_UNHEALTHY_THRESHOLD) -> None:
        """Record a probe failure."""
        self.consecutive_failures += 1
        self.last_probe_time = time.time()
        if self.consecutive_failures >= threshold:
            self.health = RegionHealth.UNHEALTHY

    def get_average_rtt_ms(self) -> Optional[float]:
        """Get rolling average RTT in milliseconds."""
        if not self.samples:
            return None
        return sum(s.rtt_ms for s in self.samples) / len(self.samples)

    def is_healthy(self) -> bool:
        """Check if region is healthy."""
        return self.health == RegionHealth.HEALTHY or self.health == RegionHealth.UNKNOWN


# ============================================================================
# Geo-Routing Metrics
# ============================================================================

@dataclass
class GeoRoutingMetrics:
    """
    Metrics for geo-routing operations.

    Exposes Prometheus-style metrics for monitoring:
    - archerdb_client_queries_total{region}
    - archerdb_client_region_switches_total{from,to}
    - archerdb_client_region_latency_ms{region}
    """
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    # Per-region query counts
    queries_by_region: Dict[str, int] = field(default_factory=dict)

    # Region switch counts (from_region -> to_region -> count)
    region_switches: Dict[str, Dict[str, int]] = field(default_factory=dict)

    # Current latencies by region
    region_latencies_ms: Dict[str, float] = field(default_factory=dict)

    def record_query(self, region: str) -> None:
        """Record a query to a region."""
        with self._lock:
            self.queries_by_region[region] = self.queries_by_region.get(region, 0) + 1

    def record_switch(self, from_region: str, to_region: str) -> None:
        """Record a region switch (failover)."""
        with self._lock:
            if from_region not in self.region_switches:
                self.region_switches[from_region] = {}
            switches = self.region_switches[from_region]
            switches[to_region] = switches.get(to_region, 0) + 1
        logger.info(f"Region switch: {from_region} -> {to_region}")

    def update_latency(self, region: str, latency_ms: float) -> None:
        """Update the latency measurement for a region."""
        with self._lock:
            self.region_latencies_ms[region] = latency_ms

    def get_prometheus_metrics(self) -> str:
        """Export metrics in Prometheus format."""
        lines = []
        with self._lock:
            # Query counts
            for region, count in self.queries_by_region.items():
                lines.append(f'archerdb_client_queries_total{{region="{region}"}} {count}')

            # Region switches
            for from_r, to_dict in self.region_switches.items():
                for to_r, count in to_dict.items():
                    lines.append(
                        f'archerdb_client_region_switches_total{{from="{from_r}",to="{to_r}"}} {count}'
                    )

            # Latencies
            for region, latency in self.region_latencies_ms.items():
                lines.append(f'archerdb_client_region_latency_ms{{region="{region}"}} {latency:.1f}')

        return "\n".join(lines)


# ============================================================================
# Region Discovery Client
# ============================================================================

class DiscoveryError(Exception):
    """Error during region discovery."""
    pass


class RegionDiscoveryClient:
    """
    Client for discovering available regions.

    Fetches region list from the /regions endpoint and caches the response.
    Supports both sync and async operations.

    Example:
        client = RegionDiscoveryClient("https://archerdb.example.com/regions")

        # Sync discovery
        regions = client.discover()

        # Async discovery
        regions = await client.discover_async()
    """

    def __init__(
        self,
        discovery_endpoint: str,
        timeout_ms: int = 5000,
    ) -> None:
        self._endpoint = discovery_endpoint
        self._timeout_s = timeout_ms / 1000.0
        self._cache: Optional[DiscoveryResponse] = None
        self._lock = threading.Lock()

    def discover(self, force_refresh: bool = False) -> List[RegionInfo]:
        """
        Discover available regions (synchronous).

        Args:
            force_refresh: Force refresh even if cache is valid

        Returns:
            List of available regions

        Raises:
            DiscoveryError: If discovery fails and no cache available
        """
        with self._lock:
            # Check cache
            if not force_refresh and self._cache and not self._cache.is_expired():
                return self._cache.regions

        try:
            response = self._fetch_sync()
            with self._lock:
                self._cache = response
            return response.regions
        except Exception as e:
            # Try to use cached data if available
            with self._lock:
                if self._cache:
                    logger.warning(f"Discovery failed, using cached data: {e}")
                    return self._cache.regions
            raise DiscoveryError(f"Discovery failed and no cache available: {e}") from e

    def _fetch_sync(self) -> DiscoveryResponse:
        """Fetch regions using sync HTTP client."""
        if HAS_HTTPX:
            import httpx
            with httpx.Client(timeout=self._timeout_s) as client:
                response = client.get(self._endpoint)
                response.raise_for_status()
                return DiscoveryResponse.from_dict(response.json())
        else:
            # Fallback to urllib
            import urllib.request
            import json
            req = urllib.request.Request(self._endpoint)
            with urllib.request.urlopen(req, timeout=self._timeout_s) as response:
                data = json.loads(response.read().decode())
                return DiscoveryResponse.from_dict(data)

    async def discover_async(self, force_refresh: bool = False) -> List[RegionInfo]:
        """
        Discover available regions (asynchronous).

        Args:
            force_refresh: Force refresh even if cache is valid

        Returns:
            List of available regions

        Raises:
            DiscoveryError: If discovery fails and no cache available
        """
        with self._lock:
            # Check cache
            if not force_refresh and self._cache and not self._cache.is_expired():
                return self._cache.regions

        try:
            response = await self._fetch_async()
            with self._lock:
                self._cache = response
            return response.regions
        except Exception as e:
            with self._lock:
                if self._cache:
                    logger.warning(f"Discovery failed, using cached data: {e}")
                    return self._cache.regions
            raise DiscoveryError(f"Discovery failed and no cache available: {e}") from e

    async def _fetch_async(self) -> DiscoveryResponse:
        """Fetch regions using async HTTP client."""
        if HAS_AIOHTTP:
            import aiohttp
            timeout = aiohttp.ClientTimeout(total=self._timeout_s)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(self._endpoint) as response:
                    response.raise_for_status()
                    data = await response.json()
                    return DiscoveryResponse.from_dict(data)
        elif HAS_HTTPX:
            import httpx
            async with httpx.AsyncClient(timeout=self._timeout_s) as client:
                response = await client.get(self._endpoint)
                response.raise_for_status()
                return DiscoveryResponse.from_dict(response.json())
        else:
            # Fallback to sync in thread
            loop = asyncio.get_event_loop()
            return await loop.run_in_executor(None, self._fetch_sync)

    def get_cached(self) -> Optional[List[RegionInfo]]:
        """Get cached regions without fetching."""
        with self._lock:
            if self._cache:
                return self._cache.regions
            return None

    def clear_cache(self) -> None:
        """Clear the cached discovery response."""
        with self._lock:
            self._cache = None


# ============================================================================
# Latency Prober
# ============================================================================

class LatencyProber:
    """
    Background latency prober for regions.

    Probes each region's RTT periodically and maintains rolling averages.
    Runs in a background thread to avoid blocking client operations.

    Example:
        prober = LatencyProber(config, metrics)
        prober.set_regions(regions)
        prober.start()

        # Get current stats
        stats = prober.get_stats("us-east-1")

        prober.stop()
    """

    def __init__(
        self,
        config: GeoRoutingConfig,
        metrics: Optional[GeoRoutingMetrics] = None,
    ) -> None:
        self._config = config
        self._metrics = metrics or GeoRoutingMetrics()
        self._regions: List[RegionInfo] = []
        self._stats: Dict[str, RegionLatencyStats] = {}
        self._lock = threading.Lock()
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()

    def set_regions(self, regions: List[RegionInfo]) -> None:
        """Set the regions to probe."""
        with self._lock:
            self._regions = regions
            # Initialize stats for new regions
            for region in regions:
                if region.name not in self._stats:
                    self._stats[region.name] = RegionLatencyStats(
                        region_name=region.name,
                        samples=deque(maxlen=self._config.probe_sample_count),
                    )

    def start(self) -> None:
        """Start background probing."""
        if not self._config.background_probing:
            return
        if self._running:
            return

        self._running = True
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._probe_loop, daemon=True)
        self._thread.start()
        logger.debug("Latency prober started")

    def stop(self) -> None:
        """Stop background probing."""
        if not self._running:
            return

        self._running = False
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=2.0)
            self._thread = None
        logger.debug("Latency prober stopped")

    def _probe_loop(self) -> None:
        """Main probing loop."""
        interval_s = self._config.probe_interval_ms / 1000.0

        while self._running and not self._stop_event.is_set():
            try:
                self._probe_all_regions()
            except Exception as e:
                logger.warning(f"Probe cycle failed: {e}")

            # Wait for next probe interval
            self._stop_event.wait(timeout=interval_s)

    def _probe_all_regions(self) -> None:
        """Probe all regions once."""
        with self._lock:
            regions = list(self._regions)

        for region in regions:
            try:
                rtt_ms = self._probe_region(region)
                with self._lock:
                    stats = self._stats.get(region.name)
                    if stats:
                        stats.add_sample(rtt_ms)
                        self._metrics.update_latency(region.name, stats.get_average_rtt_ms() or rtt_ms)
                logger.debug(f"Probed {region.name}: {rtt_ms:.1f}ms")
            except Exception as e:
                with self._lock:
                    stats = self._stats.get(region.name)
                    if stats:
                        stats.record_failure(self._config.unhealthy_threshold)
                logger.debug(f"Probe failed for {region.name}: {e}")

    def _probe_region(self, region: RegionInfo) -> float:
        """
        Probe a single region's latency.

        Uses TCP connect time as a proxy for latency.
        """
        # Parse endpoint (host:port)
        endpoint = region.endpoint
        if "://" in endpoint:
            # Remove protocol prefix
            endpoint = endpoint.split("://", 1)[1]
        if "/" in endpoint:
            endpoint = endpoint.split("/", 1)[0]

        host, port_str = endpoint.rsplit(":", 1) if ":" in endpoint else (endpoint, "5000")
        port = int(port_str)

        # Measure TCP connect time
        start = time.perf_counter()
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(self._config.failover_timeout_ms / 1000.0)
        try:
            sock.connect((host, port))
            rtt_ms = (time.perf_counter() - start) * 1000
            return rtt_ms
        finally:
            sock.close()

    def get_stats(self, region_name: str) -> Optional[RegionLatencyStats]:
        """Get latency stats for a region."""
        with self._lock:
            return self._stats.get(region_name)

    def get_all_stats(self) -> Dict[str, RegionLatencyStats]:
        """Get latency stats for all regions."""
        with self._lock:
            return dict(self._stats)

    def probe_now(self, region_name: str) -> Optional[float]:
        """
        Probe a specific region immediately (blocking).

        Returns:
            RTT in milliseconds, or None if probe failed
        """
        with self._lock:
            regions = [r for r in self._regions if r.name == region_name]

        if not regions:
            return None

        try:
            rtt_ms = self._probe_region(regions[0])
            with self._lock:
                stats = self._stats.get(region_name)
                if stats:
                    stats.add_sample(rtt_ms)
                    self._metrics.update_latency(region_name, stats.get_average_rtt_ms() or rtt_ms)
            return rtt_ms
        except Exception:
            with self._lock:
                stats = self._stats.get(region_name)
                if stats:
                    stats.record_failure(self._config.unhealthy_threshold)
            return None


# ============================================================================
# Region Selector
# ============================================================================

class RegionSelector:
    """
    Selects optimal region based on latency and health.

    Selection algorithm:
    1. Filter to healthy regions only
    2. Apply region preference if configured
    3. Select lowest-latency region
    4. If no measurements yet, use geographic distance

    Example:
        selector = RegionSelector(config, prober, metrics)

        # Select best region
        region = selector.select(regions)

        # Handle failover
        new_region = selector.failover(current_region, regions)
    """

    def __init__(
        self,
        config: GeoRoutingConfig,
        prober: LatencyProber,
        metrics: Optional[GeoRoutingMetrics] = None,
        client_location: Optional[Tuple[float, float]] = None,
    ) -> None:
        self._config = config
        self._prober = prober
        self._metrics = metrics or GeoRoutingMetrics()
        self._client_location = client_location  # (lat, lon)
        self._current_region: Optional[str] = None

    def set_client_location(self, latitude: float, longitude: float) -> None:
        """Set the client's geographic location for distance-based selection."""
        self._client_location = (latitude, longitude)

    def select(
        self,
        regions: List[RegionInfo],
        exclude: Optional[List[str]] = None,
    ) -> Optional[RegionInfo]:
        """
        Select the optimal region.

        Args:
            regions: Available regions
            exclude: Region names to exclude (e.g., failed regions)

        Returns:
            Selected region, or None if no healthy regions available
        """
        exclude = exclude or []

        # Filter to healthy regions
        healthy = [
            r for r in regions
            if r.healthy and r.name not in exclude
        ]

        # Also check our own health tracking
        healthy = [
            r for r in healthy
            if self._is_region_healthy(r.name)
        ]

        if not healthy:
            logger.warning("No healthy regions available")
            return None

        # Apply region preference
        if self._config.preferred_region:
            preferred = [r for r in healthy if r.name == self._config.preferred_region]
            if preferred:
                return preferred[0]
            logger.info(f"Preferred region {self._config.preferred_region} not healthy, using fallback")

        # Select by latency
        region = self._select_by_latency(healthy)
        if region and region.name != self._current_region:
            if self._current_region:
                self._metrics.record_switch(self._current_region, region.name)
            self._current_region = region.name

        return region

    def _is_region_healthy(self, region_name: str) -> bool:
        """Check if region is healthy based on our probing."""
        stats = self._prober.get_stats(region_name)
        if stats is None:
            return True  # Unknown, assume healthy
        return stats.is_healthy()

    def _select_by_latency(self, regions: List[RegionInfo]) -> Optional[RegionInfo]:
        """Select region with lowest latency."""
        # Get latency for each region
        latencies: List[Tuple[RegionInfo, float]] = []

        for region in regions:
            stats = self._prober.get_stats(region.name)
            if stats:
                rtt = stats.get_average_rtt_ms()
                if rtt is not None:
                    latencies.append((region, rtt))

        if latencies:
            # Sort by latency and return lowest
            latencies.sort(key=lambda x: x[1])
            return latencies[0][0]

        # No latency data - use geographic distance if available
        if self._client_location:
            return self._select_by_distance(regions)

        # No measurements and no location - return first region
        return regions[0] if regions else None

    def _select_by_distance(self, regions: List[RegionInfo]) -> Optional[RegionInfo]:
        """Select region by geographic distance."""
        if not self._client_location:
            return regions[0] if regions else None

        client_lat, client_lon = self._client_location

        def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
            """Calculate haversine distance in km."""
            R = 6371  # Earth radius in km
            dlat = math.radians(lat2 - lat1)
            dlon = math.radians(lon2 - lon1)
            a = (
                math.sin(dlat / 2) ** 2
                + math.cos(math.radians(lat1))
                * math.cos(math.radians(lat2))
                * math.sin(dlon / 2) ** 2
            )
            c = 2 * math.asin(math.sqrt(a))
            return R * c

        distances: List[Tuple[RegionInfo, float]] = []
        for region in regions:
            dist = haversine_distance(
                client_lat,
                client_lon,
                region.location.latitude,
                region.location.longitude,
            )
            distances.append((region, dist))

        if distances:
            distances.sort(key=lambda x: x[1])
            return distances[0][0]

        return regions[0] if regions else None

    def failover(
        self,
        current_region: str,
        regions: List[RegionInfo],
    ) -> Optional[RegionInfo]:
        """
        Select a failover region.

        Args:
            current_region: The failing region name
            regions: Available regions

        Returns:
            New region to use, or None if no alternatives
        """
        if not self._config.failover_enabled:
            logger.warning("Failover disabled, not switching regions")
            return None

        # Mark current region as unhealthy
        stats = self._prober.get_stats(current_region)
        if stats:
            stats.health = RegionHealth.UNHEALTHY

        # Select new region excluding current
        new_region = self.select(regions, exclude=[current_region])

        if new_region:
            self._metrics.record_switch(current_region, new_region.name)
            logger.info(f"Failover from {current_region} to {new_region.name}")
        else:
            logger.error("Failover failed: no alternative regions available")

        return new_region

    def get_current_region(self) -> Optional[str]:
        """Get the currently selected region name."""
        return self._current_region


# ============================================================================
# Main Geo-Router Class
# ============================================================================

class GeoRouter:
    """
    Main geo-routing coordinator.

    Combines discovery, probing, and selection into a unified interface.

    Example:
        config = GeoRoutingConfig(
            discovery_endpoint="https://archerdb.example.com/regions",
            preferred_region="us-east-1",
        )
        router = GeoRouter(config)

        # Start geo-routing
        await router.start_async()

        # Get current endpoint
        endpoint = router.get_endpoint()

        # Handle connection failure
        endpoint = router.handle_failure()

        # Stop geo-routing
        router.stop()
    """

    def __init__(self, config: GeoRoutingConfig) -> None:
        self._config = config
        self._metrics = GeoRoutingMetrics()
        self._discovery: Optional[RegionDiscoveryClient] = None
        self._prober: Optional[LatencyProber] = None
        self._selector: Optional[RegionSelector] = None
        self._regions: List[RegionInfo] = []
        self._current_endpoint: Optional[str] = None
        self._lock = threading.Lock()
        self._started = False

        if config.discovery_endpoint:
            self._discovery = RegionDiscoveryClient(
                config.discovery_endpoint,
                timeout_ms=config.failover_timeout_ms,
            )
            self._prober = LatencyProber(config, self._metrics)
            self._selector = RegionSelector(config, self._prober, self._metrics)

    def start(self) -> str:
        """
        Start geo-routing (synchronous).

        Discovers regions, starts probing, and returns the initial endpoint.

        Returns:
            The selected endpoint

        Raises:
            DiscoveryError: If discovery fails with no fallback
        """
        if not self._config.is_geo_routing_enabled():
            # Direct connection mode
            self._current_endpoint = self._config.direct_endpoint
            return self._current_endpoint or ""

        # Discover regions
        if self._discovery:
            self._regions = self._discovery.discover()

        # Start prober
        if self._prober and self._regions:
            self._prober.set_regions(self._regions)
            self._prober.start()

        # Select initial region
        if self._selector and self._regions:
            region = self._selector.select(self._regions)
            if region:
                self._current_endpoint = region.endpoint

        self._started = True
        return self._current_endpoint or ""

    async def start_async(self) -> str:
        """
        Start geo-routing (asynchronous).

        Discovers regions, starts probing, and returns the initial endpoint.

        Returns:
            The selected endpoint

        Raises:
            DiscoveryError: If discovery fails with no fallback
        """
        if not self._config.is_geo_routing_enabled():
            self._current_endpoint = self._config.direct_endpoint
            return self._current_endpoint or ""

        # Discover regions
        if self._discovery:
            self._regions = await self._discovery.discover_async()

        # Start prober
        if self._prober and self._regions:
            self._prober.set_regions(self._regions)
            self._prober.start()

        # Select initial region
        if self._selector and self._regions:
            region = self._selector.select(self._regions)
            if region:
                self._current_endpoint = region.endpoint

        self._started = True
        return self._current_endpoint or ""

    def stop(self) -> None:
        """Stop geo-routing and cleanup."""
        if self._prober:
            self._prober.stop()
        self._started = False

    def get_endpoint(self) -> str:
        """Get the current endpoint."""
        return self._current_endpoint or ""

    def get_current_region(self) -> Optional[str]:
        """Get the current region name."""
        if self._selector:
            return self._selector.get_current_region()
        return None

    def handle_failure(self) -> Optional[str]:
        """
        Handle connection failure by triggering failover.

        Returns:
            New endpoint, or None if no alternatives
        """
        if not self._config.failover_enabled:
            return None

        current_region = self.get_current_region()
        if not current_region or not self._selector:
            return None

        new_region = self._selector.failover(current_region, self._regions)
        if new_region:
            self._current_endpoint = new_region.endpoint
            return self._current_endpoint

        return None

    def record_query(self) -> None:
        """Record a query for metrics."""
        region = self.get_current_region()
        if region:
            self._metrics.record_query(region)

    def get_metrics(self) -> GeoRoutingMetrics:
        """Get the metrics object."""
        return self._metrics

    def refresh_regions(self) -> None:
        """Force refresh of region discovery."""
        if self._discovery:
            try:
                self._regions = self._discovery.discover(force_refresh=True)
                if self._prober:
                    self._prober.set_regions(self._regions)
            except Exception as e:
                logger.warning(f"Region refresh failed: {e}")

    async def refresh_regions_async(self) -> None:
        """Force refresh of region discovery (async)."""
        if self._discovery:
            try:
                self._regions = await self._discovery.discover_async(force_refresh=True)
                if self._prober:
                    self._prober.set_regions(self._regions)
            except Exception as e:
                logger.warning(f"Region refresh failed: {e}")

    def get_regions(self) -> List[RegionInfo]:
        """Get the list of discovered regions."""
        return list(self._regions)

    def get_region_stats(self) -> Dict[str, Dict[str, Any]]:
        """
        Get detailed stats for all regions.

        Returns:
            Dict mapping region name to stats dict
        """
        result: Dict[str, Dict[str, Any]] = {}
        if self._prober:
            for name, stats in self._prober.get_all_stats().items():
                result[name] = {
                    "health": stats.health.name,
                    "avg_rtt_ms": stats.get_average_rtt_ms(),
                    "consecutive_failures": stats.consecutive_failures,
                    "sample_count": len(stats.samples),
                }
        return result
