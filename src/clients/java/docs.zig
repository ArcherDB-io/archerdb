// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const Docs = @import("../docs_types.zig").Docs;

pub const JavaDocs = Docs{
    .directory = "java",

    .markdown_name = "java",
    .extension = "java",
    .proper_name = "Java",

    .test_source_path = "src/main/java/",

    .name = "archerdb-java",
    .description =
    \\The ArcherDB client for Java.
    \\
    \\The intended package coordinates are `com.archerdb:archerdb-java`.
    \\Maven Central publication is a separate release step; until that happens,
    \\build from a source checkout and install into your local Maven repository.
    ,

    .prerequisites =
    \\* Java >= 11 (Java 21+: pass `--enable-native-access=ALL-UNNAMED`
    \\  to silence native access warnings)
    \\* Maven >= 3.6 (not strictly necessary but it's what our guides assume)
    ,

    .project_file_name = "pom.xml",
    .project_file =
    \\<project xmlns="http://maven.apache.org/POM/4.0.0"
    \\         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    \\         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    \\  <modelVersion>4.0.0</modelVersion>
    \\
    \\  <groupId>com.archerdb</groupId>
    \\  <artifactId>samples</artifactId>
    \\  <version>1.0-SNAPSHOT</version>
    \\
    \\  <properties>
    \\    <maven.compiler.source>11</maven.compiler.source>
    \\    <maven.compiler.target>11</maven.compiler.target>
    \\  </properties>
    \\
    \\  <build>
    \\    <plugins>
    \\      <plugin>
    \\        <groupId>org.apache.maven.plugins</groupId>
    \\        <artifactId>maven-compiler-plugin</artifactId>
    \\        <version>3.8.1</version>
    \\        <configuration>
    \\          <compilerArgs>
    \\            <arg>-Xlint:all,-options,-path</arg>
    \\          </compilerArgs>
    \\        </configuration>
    \\      </plugin>
    \\
    \\      <plugin>
    \\        <groupId>org.codehaus.mojo</groupId>
    \\        <artifactId>exec-maven-plugin</artifactId>
    \\        <version>1.6.0</version>
    \\        <configuration>
    \\          <mainClass>com.archerdb.samples.Main</mainClass>
    \\        </configuration>
    \\      </plugin>
    \\    </plugins>
    \\  </build>
    \\
    \\  <dependencies>
    \\    <dependency>
    \\      <groupId>com.archerdb</groupId>
    \\      <artifactId>archerdb-java</artifactId>
    \\      <version>0.1.0-SNAPSHOT</version>
    \\    </dependency>
    \\  </dependencies>
    \\</project>
    ,

    .test_file_name = "Main",

    .install_commands = "mvn install",
    .run_commands = "mvn exec:java",

    .examples = "",

    .client_object_documentation = "",

    .insert_events_documentation =
    \\The 128-bit fields like `id`, `entityId`, `s2CellId` and `compositeId`
    \\have a few overrides to make it easier to integrate. You can either
    \\pass in a long, a pair of longs (least and most significant bits),
    \\or a `byte[]`.
    \\
    \\There is also a `com.archerdb.geo.UInt128` helper with static
    \\methods for converting 128-bit little-endian unsigned integers
    \\between instances of `long`, `java.util.UUID`, `java.math.BigInteger` and `byte[]`.
    ,

    .geo_event_flags_documentation =
    \\To toggle behavior for a geo event, combine enum values stored in the
    \\`GeoEventFlags` object with bitwise-or:
    \\
    \\* `GeoEventFlags.HAS_ALTITUDE`
    \\* `GeoEventFlags.TOMBSTONE`
    ,

    .insert_events_errors_documentation =
    \\To handle errors, check the result returned from `client.insertEvents()`.
    \\Each result contains an `index` field to map back to the input event
    \\and a `result` field with the `InsertGeoEventResult` enum.
    ,

    .query_operations_documentation =
    \\ArcherDB supports several query operations:
    \\
    \\* `queryUuid()` - Query events by entity UUID
    \\* `queryLatest()` - Query latest events for entities
    \\* `queryRadius()` - Query events within a radius of a point
    \\* `queryPolygon()` - Query events within a polygon
    ,

    .delete_entities_documentation =
    \\To delete entities, pass an array of entity IDs to `deleteEntities()`.
    \\This will mark all events for those entities as tombstoned.
    ,
};
