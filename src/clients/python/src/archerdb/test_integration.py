"""
ArcherDB Python SDK Integration Tests

These tests require a running ArcherDB server.
"""

import os
import unittest

from .client import _submit_multi_batch_sync
from .types import GeoOperation, create_geo_event
from .client import GeoClientSync, GeoClientConfig
from . import id as archerdb_id

RUN_INTEGRATION = os.getenv("ARCHERDB_INTEGRATION") == "1"
SERVER_ADDR = os.getenv("ARCHERDB_ADDRESS", "127.0.0.1:3001")


@unittest.skipUnless(RUN_INTEGRATION, "Set ARCHERDB_INTEGRATION=1 to run integration tests")
class TestMultiBatchIntegration(unittest.TestCase):
    def test_insert_events_multi_batch(self):
        client = GeoClientSync(
            GeoClientConfig(cluster_id=0, addresses=[SERVER_ADDR])
        )
        try:
            events = [
                create_geo_event(entity_id=archerdb_id(), latitude=37.7749, longitude=-122.4194),
                create_geo_event(entity_id=archerdb_id(), latitude=37.7750, longitude=-122.4195),
                create_geo_event(entity_id=archerdb_id(), latitude=37.7751, longitude=-122.4196),
            ]

            errors = _submit_multi_batch_sync(
                GeoOperation.INSERT_EVENTS,
                events,
                lambda op, batch: client._submit_batch(op, batch),
                batch_size=2,
            )

            self.assertEqual(errors, [])
        finally:
            client.close()
