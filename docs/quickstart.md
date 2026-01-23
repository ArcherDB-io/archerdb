# Quickstart: Your First 5 Minutes with ArcherDB

This guide gets you from zero to querying location data in under 5 minutes. For a deeper dive into all features, see the [Getting Started Guide](getting-started.md).

## Prerequisites

- **Operating System**: Linux (kernel 5.6+) or macOS
- **For SDK examples**: Node.js 18+ (other SDKs also available)

## Step 1: Download and Install

Download the pre-built binary for your platform:

```bash
# Linux (x86_64)
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-linux-x86_64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/

# macOS (Apple Silicon)
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-macos-aarch64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/
```

Verify the installation:

```bash
archerdb --version
```

## Step 2: Start a Single-Node Cluster

Format a data file and start the server:

```bash
# Create a data directory
mkdir -p ~/archerdb-data

# Format the data file (cluster=0 for development)
archerdb format --cluster=0 --replica=0 --replica-count=1 ~/archerdb-data/data.archerdb

# Start the server (default port 3000)
archerdb start --addresses=3000 ~/archerdb-data/data.archerdb
```

You should see output indicating the server is ready:

```
info: server ready on 127.0.0.1:3000
```

Leave this terminal running and open a new one for the next steps.

## Step 3: Install an SDK and Insert Your First Location

<details>
<summary>Node.js</summary>

Install the SDK:

```bash
npm install archerdb-node
```

Create a file `quickstart.js`:

```javascript
const { createGeoClient, createGeoEvent, id } = require('archerdb-node')

async function main() {
  // Connect to the cluster
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  try {
    // Insert a location event (e.g., a delivery vehicle in San Francisco)
    const event = createGeoEvent({
      entity_id: id(),              // Generate a unique ID
      latitude: 37.7749,            // San Francisco
      longitude: -122.4194,
      group_id: 1n,                 // Fleet ID
    })

    const errors = await client.insertEvents([event])
    if (errors.length === 0) {
      console.log('Location inserted!')
      console.log(`Entity ID: ${event.entity_id}`)
    }
  } finally {
    client.destroy()
  }
}

main()
```

Run it:

```bash
node quickstart.js
```

</details>

<details>
<summary>Python</summary>

Install the SDK:

```bash
pip install archerdb
```

Create a file `quickstart.py`:

```python
import archerdb

# Connect to the cluster
client = archerdb.GeoClientSync(archerdb.GeoClientConfig(
    cluster_id=0,
    addresses=['127.0.0.1:3000']
))

# Insert a location event (e.g., a delivery vehicle in San Francisco)
event = archerdb.create_geo_event(
    entity_id=archerdb.id(),  # Generate a unique ID
    latitude=37.7749,         # San Francisco
    longitude=-122.4194,
    group_id=1,               # Fleet ID
)

errors = client.insert_events([event])
if len(errors) == 0:
    print('Location inserted!')
    print(f'Entity ID: {event.entity_id}')

client.close()
```

Run it:

```bash
python quickstart.py
```

</details>

<details>
<summary>Go</summary>

Install the SDK:

```bash
go get github.com/archerdb/archerdb-go
```

Create a file `quickstart.go`:

```go
package main

import (
    "fmt"
    "log"

    archerdb "github.com/archerdb/archerdb-go"
    "github.com/archerdb/archerdb-go/pkg/types"
)

func main() {
    // Connect to the cluster
    client, err := archerdb.NewClient(types.ToUint128(0), []string{"127.0.0.1:3000"})
    if err != nil {
        log.Fatal(err)
    }
    defer client.Close()

    // Insert a location event (e.g., a delivery vehicle in San Francisco)
    entityID := types.ID()
    events := []types.GeoEvent{
        {
            EntityID: entityID,
            LatNano:  37774900000,  // 37.7749 degrees in nanodegrees
            LonNano:  -122419400000,
            GroupID:  1,
        },
    }

    results, err := client.CreateEvents(events)
    if err != nil {
        log.Fatal(err)
    }

    if len(results) == 0 || results[0].Result == 0 {
        fmt.Println("Location inserted!")
        fmt.Printf("Entity ID: %v\n", entityID)
    }
}
```

Run it:

```bash
go run quickstart.go
```

</details>

<details>
<summary>Java</summary>

Add the dependency to your `pom.xml`:

```xml
<dependency>
    <groupId>com.archerdb</groupId>
    <artifactId>archerdb-java</artifactId>
    <version>1.0.0</version>
</dependency>
```

Create `Quickstart.java`:

```java
import com.archerdb.geo.*;
import java.math.BigInteger;
import java.util.List;

public class Quickstart {
    public static void main(String[] args) throws Exception {
        // Connect to the cluster
        GeoClientConfig config = new GeoClientConfig.Builder()
            .clusterId(BigInteger.ZERO)
            .addresses(List.of("127.0.0.1:3000"))
            .build();

        try (GeoClient client = new GeoClient(config)) {
            // Insert a location event (e.g., a delivery vehicle in San Francisco)
            BigInteger entityId = GeoClient.generateId();
            GeoEvent event = GeoEvent.builder()
                .entityId(entityId)
                .latNano(37774900000L)   // 37.7749 degrees in nanodegrees
                .lonNano(-122419400000L)
                .groupId(1L)
                .build();

            List<EventResult> results = client.createEvents(List.of(event));
            if (results.isEmpty() || results.get(0).getResult() == 0) {
                System.out.println("Location inserted!");
                System.out.println("Entity ID: " + entityId);
            }
        }
    }
}
```

</details>

<details>
<summary>C</summary>

Link against `libarcherdb` and include the header:

```c
#include <archerdb.h>
#include <stdio.h>

int main() {
    // Connect to the cluster
    arch_client_t* client = arch_client_new(0, "127.0.0.1:3000", NULL);
    if (!client) {
        fprintf(stderr, "Failed to connect\n");
        return 1;
    }

    // Insert a location event (e.g., a delivery vehicle in San Francisco)
    geo_event_t event = {
        .entity_id = arch_id(),
        .lat_nano = 37774900000,   // 37.7749 degrees in nanodegrees
        .lon_nano = -122419400000,
        .group_id = 1,
    };

    int result = arch_create_events(client, &event, 1, NULL, NULL);
    if (result == 0) {
        printf("Location inserted!\n");
    }

    arch_client_destroy(client);
    return 0;
}
```

</details>

## Step 4: Query by Radius

Now let's find all entities within 1 kilometer of a point:

<details>
<summary>Node.js</summary>

```javascript
const { createGeoClient } = require('archerdb-node')

async function main() {
  const client = createGeoClient({
    cluster_id: 0n,
    addresses: ['127.0.0.1:3000'],
  })

  try {
    // Find all entities within 1km of downtown San Francisco
    const results = await client.queryRadius({
      latitude: 37.7749,
      longitude: -122.4194,
      radius_m: 1000,   // 1 kilometer
      limit: 100,
    })

    console.log(`Found ${results.events.length} entities within 1km`)

    for (const event of results.events) {
      console.log(`  Entity ${event.entity_id}`)
    }
  } finally {
    client.destroy()
  }
}

main()
```

</details>

<details>
<summary>Python</summary>

```python
import archerdb

client = archerdb.GeoClientSync(archerdb.GeoClientConfig(
    cluster_id=0,
    addresses=['127.0.0.1:3000']
))

# Find all entities within 1km of downtown San Francisco
results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_m=1000,  # 1 kilometer
    limit=100,
)

print(f'Found {len(results.events)} entities within 1km')

for event in results.events:
    print(f'  Entity {event.entity_id}')

client.close()
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
    client, err := archerdb.NewClient(types.ToUint128(0), []string{"127.0.0.1:3000"})
    if err != nil {
        log.Fatal(err)
    }
    defer client.Close()

    // Find all entities within 1km of downtown San Francisco
    filter := types.RadiusFilter{
        CenterLatNano: 37774900000,
        CenterLonNano: -122419400000,
        RadiusM:       1000,  // 1 kilometer
        Limit:         100,
    }

    results, err := client.QueryRadius(filter)
    if err != nil {
        log.Fatal(err)
    }

    fmt.Printf("Found %d entities within 1km\n", len(results.Events))
    for _, event := range results.Events {
        fmt.Printf("  Entity %v\n", event.EntityID)
    }
}
```

</details>

<details>
<summary>Java</summary>

```java
import com.archerdb.geo.*;
import java.math.BigInteger;
import java.util.List;

public class RadiusQuery {
    public static void main(String[] args) throws Exception {
        GeoClientConfig config = new GeoClientConfig.Builder()
            .clusterId(BigInteger.ZERO)
            .addresses(List.of("127.0.0.1:3000"))
            .build();

        try (GeoClient client = new GeoClient(config)) {
            // Find all entities within 1km of downtown San Francisco
            QueryRadiusFilter filter = new QueryRadiusFilter.Builder()
                .centerLatNano(37774900000L)
                .centerLonNano(-122419400000L)
                .radiusM(1000)  // 1 kilometer
                .limit(100)
                .build();

            QueryResult results = client.queryRadius(filter);

            System.out.println("Found " + results.getEvents().size() + " entities within 1km");
            for (GeoEvent event : results.getEvents()) {
                System.out.println("  Entity " + event.getEntityId());
            }
        }
    }
}
```

</details>

<details>
<summary>C</summary>

```c
#include <archerdb.h>
#include <stdio.h>

void on_result(void* ctx, const geo_event_t* events, size_t count) {
    printf("Found %zu entities within 1km\n", count);
    for (size_t i = 0; i < count; i++) {
        printf("  Entity %llu\n", (unsigned long long)events[i].entity_id.lo);
    }
}

int main() {
    arch_client_t* client = arch_client_new(0, "127.0.0.1:3000", NULL);

    // Find all entities within 1km of downtown San Francisco
    radius_filter_t filter = {
        .center_lat_nano = 37774900000,
        .center_lon_nano = -122419400000,
        .radius_m = 1000,   // 1 kilometer
        .limit = 100,
    };

    arch_query_radius(client, &filter, on_result, NULL);

    arch_client_destroy(client);
    return 0;
}
```

</details>

## Step 5: Next Steps

Congratulations! You've inserted and queried location data with ArcherDB. Here's where to go next:

- **[Getting Started Guide](getting-started.md)** - Learn about batching, polygon queries, error handling, and more
- **[API Reference](api-reference.md)** - Complete documentation for all operations
- **[Operations Runbook](operations-runbook.md)** - Set up a production cluster

### Common Use Cases

| Use Case | Key Operations | Guide |
|----------|----------------|-------|
| Fleet tracking | `insertEvents`, `queryRadius`, `getLatest` | [Getting Started](getting-started.md#inserting-location-events) |
| Geofencing | `queryPolygon` with holes | [Getting Started](getting-started.md#polygon-queries-with-holes) |
| GDPR compliance | `deleteEntities` | [Getting Started](getting-started.md#deleting-entities-gdpr-compliance) |
| High availability | 3-node cluster | [Operations Runbook](operations-runbook.md) |

### Stopping the Server

When you're done experimenting, stop the server with `Ctrl+C` in the terminal where it's running.
