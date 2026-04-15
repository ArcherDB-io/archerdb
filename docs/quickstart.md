# Quickstart

**Time to complete: ~5 minutes**

Get from zero to your first spatial query in 5 minutes. For comprehensive setup, see the [Getting Started Guide](getting-started.md).

## Step 1: Download Binary (~1 min)

<details open>
<summary>Linux (x86_64)</summary>

```bash
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-linux-x86_64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/
```

</details>

<details>
<summary>macOS (Apple Silicon)</summary>

```bash
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-macos-aarch64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/
```

</details>

<details>
<summary>macOS (Intel)</summary>

```bash
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-macos-x86_64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/
```

</details>

## Step 2: Start Server (~1 min)

```bash
# Format data file and start server
archerdb format --cluster=0 --replica=0 --replica-count=1 data.archerdb
archerdb start --addresses=3000 data.archerdb
```

You should see: `info: server ready on 127.0.0.1:3000`

Open a new terminal for the next steps.

## Step 3: Install SDK (~1 min)

<details open>
<summary>Python</summary>

```bash
pip install archerdb
```

</details>

<details>
<summary>Node.js</summary>

```bash
npm install archerdb-node
```

</details>

<details>
<summary>Go</summary>

```bash
go get github.com/archerdb/archerdb-go
```

</details>

<details>
<summary>Java (source checkout / local Maven install)</summary>

Until `archerdb-java` is explicitly published to Maven Central, use a source checkout:

```bash
./zig/zig build clients:java -Drelease
(cd src/clients/java && mvn --batch-mode --quiet install)
```

Then use the local Maven artifact version from
[`src/clients/java/pom.xml`](/home/g/archerdb/src/clients/java/pom.xml), which is currently
`0.1.0-SNAPSHOT`.

</details>

<details>
<summary>curl (no SDK needed)</summary>

No installation required - use curl directly.

</details>

## Step 4: Insert a Location (~1 min)

Insert a delivery vehicle location in San Francisco:

<details open>
<summary>Python</summary>

```python
import archerdb

client = archerdb.GeoClientSync(archerdb.GeoClientConfig(
    cluster_id=0,
    addresses=['127.0.0.1:3000']
))

# Insert vehicle at SF city center (37.7749, -122.4194)
event = archerdb.create_geo_event(
    entity_id=archerdb.id(),
    latitude=37.7749,
    longitude=-122.4194,
    group_id=1,
)
client.insert_events([event])
print(f"Inserted vehicle: {event.entity_id}")
```

</details>

<details>
<summary>Node.js</summary>

```javascript
const { createGeoClient, createGeoEvent, id } = require('archerdb-node')

const client = createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3000'],
})

// Insert vehicle at SF city center (37.7749, -122.4194)
const event = createGeoEvent({
  entity_id: id(),
  latitude: 37.7749,
  longitude: -122.4194,
  group_id: 1n,
})

await client.insertEvents([event])
console.log(`Inserted vehicle: ${event.entity_id}`)
client.destroy()
```

</details>

<details>
<summary>Go</summary>

```go
package main

import (
    "fmt"
    "log"
    archerdb "github.com/archerdb/archerdb-go"
    "github.com/archerdb/archerdb-go/pkg/types"
)

func main() {
    client, _ := archerdb.NewGeoClient(archerdb.GeoClientConfig{
        ClusterID: types.ToUint128(0),
        Addresses: []string{"127.0.0.1:3000"},
    })
    defer client.Close()

    // Insert vehicle at SF city center (37.7749, -122.4194)
    event, _ := types.NewGeoEvent(types.GeoEventOptions{
        EntityID:  types.ID(),
        Latitude:  37.7749,
        Longitude: -122.4194,
        GroupID:   1,
    })
    client.InsertEvents([]types.GeoEvent{event})
    fmt.Printf("Inserted vehicle: %s\n", event.EntityID)
}
```

</details>

<details>
<summary>Java</summary>

```java
import com.archerdb.geo.*;

public class Quickstart {
    public static void main(String[] args) throws Exception {
        try (GeoClient client = GeoClient.create(0L, "127.0.0.1:3000")) {
            // Insert vehicle at SF city center (37.7749, -122.4194)
            UInt128 entityId = UInt128.random();
            GeoEvent event = new GeoEvent.Builder()
                .setEntityId(entityId)
                .setLatitude(37.7749)
                .setLongitude(-122.4194)
                .setGroupId(1L)
                .build();

            GeoEventBatch batch = client.createBatch();
            batch.add(event);
            batch.commit();
            System.out.println("Inserted vehicle: " + entityId);
        }
    }
}
```

</details>

<details>
<summary>curl</summary>

```bash
# Insert vehicle at SF city center (37.7749, -122.4194)
curl -X POST http://127.0.0.1:3000/insert \
  -H "Content-Type: application/json" \
  -d '{
    "events": [{
      "entity_id": "00000000-0000-0000-0000-000000000001",
      "lat_nano": 37774900000,
      "lon_nano": -122419400000,
      "group_id": 1
    }]
  }'
```

</details>

## Step 5: Query by Radius (~1 min)

Find all vehicles within 1km of SF city center:

<details open>
<summary>Python</summary>

```python
# Find vehicles within 1km of SF city center
results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_m=1000,
)
print(f"Found {len(results.events)} vehicles within 1km")
```

</details>

<details>
<summary>Node.js</summary>

```javascript
// Find vehicles within 1km of SF city center
const results = await client.queryRadius({
  latitude: 37.7749,
  longitude: -122.4194,
  radius_m: 1000,
})
console.log(`Found ${results.events.length} vehicles within 1km`)
```

</details>

<details>
<summary>Go</summary>

```go
// Find vehicles within 1km of SF city center
filter, _ := types.NewRadiusQuery(37.7749, -122.4194, 1000, 100)
results, _ := client.QueryRadius(filter)
fmt.Printf("Found %d vehicles within 1km\n", len(results.Events))
```

</details>

<details>
<summary>Java</summary>

```java
// Find vehicles within 1km of SF city center
QueryResult results = client.queryRadius(
    QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100)
);
System.out.println("Found " + results.getEvents().size() + " vehicles within 1km");
```

</details>

<details>
<summary>curl</summary>

```bash
# Find vehicles within 1km of SF city center
curl -X POST http://127.0.0.1:3000/query/radius \
  -H "Content-Type: application/json" \
  -d '{
    "center_lat_nano": 37774900000,
    "center_lon_nano": -122419400000,
    "radius_m": 1000,
    "limit": 100
  }'
```

</details>

---

**Congratulations! You just completed your first spatial query.**

You inserted a location and found it with a radius query - the core of real-time location tracking.

## Next Steps

- [Getting Started Guide](getting-started.md) - Batching, polygon queries, error handling
- [API Reference](api-reference.md) - Complete operation documentation
- [Operations Runbook](operations-runbook.md) - Production deployment
