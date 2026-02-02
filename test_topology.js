#!/usr/bin/env node
// Quick test to verify get_topology works
const { GeoClient } = require('./src/clients/node/dist/geo_client');

async function testTopology() {
  console.log('Testing get_topology operation...');

  const client = new GeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3011'],
  });

  try {
    await client.connect();
    console.log('✓ Client connected');

    const topology = await client.getTopology();
    console.log('✓ get_topology succeeded!');
    console.log('  Topology version:', topology.version);
    console.log('  Number of shards:', topology.num_shards);
    console.log('  Cluster ID:', topology.cluster_id);
    console.log('  Resharding status:', topology.resharding_status);
    console.log('  Shard count:', topology.shards.length);

    if (topology.num_shards > 0) {
      console.log('  Shard 0 status:', topology.shards[0].status);
      console.log('  Shard 0 primary:', topology.shards[0].primary);
    }

    console.log('\n SUCCESS: get_topology works on single-node cluster!');
    process.exit(0);
  } catch (err) {
    console.error('✗ get_topology failed:', err);
    console.error('  Error message:', err.message);
    console.error('  Error stack:', err.stack);
    process.exit(1);
  } finally {
    await client.disconnect();
  }
}

testTopology().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
