import com.archerdb.geo.GeoClient;
import com.archerdb.geo.GeoEvent;
import com.archerdb.geo.InsertGeoEventsError;
import com.archerdb.geo.QueryLatestFilter;
import com.archerdb.geo.QueryResult;
import com.archerdb.geo.UInt128;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.Channels;
import java.nio.channels.ReadableByteChannel;
import java.nio.channels.WritableByteChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * A Vortex driver using the Java geospatial client for ArcherDB.
 */
public final class Main {
  public static void main(String[] args) throws Exception {
    if (args.length != 2) {
      throw new IllegalArgumentException(
          "java driver requires two positional command-line arguments");
    }

    long clusterId = Long.parseLong(args[0]);

    String[] replicaAddresses = args[1].split(",");
    if (replicaAddresses.length == 0) {
      throw new IllegalArgumentException(
          "REPLICAS must list at least one address (comma-separated)");
    }

    try (GeoClient client = GeoClient.create(clusterId, replicaAddresses)) {
      var reader = new Driver.Reader(Channels.newChannel(System.in));
      var writer = new Driver.Writer(Channels.newChannel(System.out));
      var driver = new Driver(client, reader, writer);
      while (true) {
        driver.next();
      }
    }
  }
}

class Driver {
  private final GeoClient client;
  private final Reader reader;
  private final Writer writer;

  public Driver(GeoClient client, Reader reader, Writer writer) {
    this.client = client;
    this.reader = reader;
    this.writer = writer;
  }

  static ByteOrder BYTE_ORDER = ByteOrder.nativeOrder();
  static {
    if (BYTE_ORDER != ByteOrder.LITTLE_ENDIAN) {
      throw new RuntimeException("Native byte order LITTLE_ENDIAN expected");
    }
  }

  void next() throws IOException {
    reader.read(1 + 4); // operation + count
    var operation = Operation.fromValue(reader.u8());
    var count = reader.u32();

    switch (operation) {
      case INSERT_EVENTS:
        insertEvents(count);
        break;
      case QUERY_UUID:
        queryUuid(count);
        break;
      case QUERY_LATEST:
        queryLatest(count);
        break;
      default:
        throw new RuntimeException("unsupported operation: " + operation.name());
    }
  }

  void insertEvents(int count) throws IOException {
    reader.read(Operation.INSERT_EVENTS.eventSize() * count);
    List<GeoEvent> events = new ArrayList<>(count);

    for (int i = 0; i < count; i++) {
      events.add(readGeoEvent());
    }

    List<InsertGeoEventsError> errors = client.insertEvents(events);

    writer.allocate(4 + errors.size() * Operation.INSERT_EVENTS.resultSize());
    writer.u32(errors.size());
    for (InsertGeoEventsError error : errors) {
      writer.u32(error.getIndex());
      writer.u32(error.getResult().getCode());
    }
    writer.flush();
  }

  void queryUuid(int count) throws IOException {
    if (count != 1) {
      throw new RuntimeException("query_uuid expects exactly one filter");
    }

    reader.read(Operation.QUERY_UUID.eventSize() * count);
    UInt128 entityId = UInt128.fromBytes(reader.u128());
    reader.skip(16); // reserved

    GeoEvent event = client.getLatestByUuid(entityId);

    int headerSize = Operation.QUERY_UUID.resultSize();
    int eventSize = Operation.INSERT_EVENTS.eventSize();
    int payloadSize = headerSize + (event == null ? 0 : eventSize);

    writer.allocate(4 + payloadSize);
    writer.u32(payloadSize / headerSize);

    byte[] header = new byte[headerSize];
    header[0] = (byte) (event == null ? 200 : 0);
    writer.bytes(header);

    if (event != null) {
      writeGeoEvent(event);
    }

    writer.flush();
  }

  void queryLatest(int count) throws IOException {
    if (count != 1) {
      throw new RuntimeException("query_latest expects exactly one filter");
    }

    reader.read(Operation.QUERY_LATEST.eventSize() * count);
    int limit = reader.u32();
    reader.u32(); // alignment padding
    long groupId = reader.u64();
    long cursorTimestamp = reader.u64();
    reader.skip(104); // reserved

    QueryLatestFilter filter = new QueryLatestFilter(limit, groupId, cursorTimestamp);
    QueryResult result = client.queryLatest(filter);

    List<GeoEvent> events = result.getEvents();

    writer.allocate(4 + events.size() * Operation.QUERY_LATEST.resultSize());
    writer.u32(events.size());
    for (GeoEvent event : events) {
      writeGeoEvent(event);
    }
    writer.flush();
  }

  GeoEvent readGeoEvent() throws IOException {
    UInt128 id = UInt128.fromBytes(reader.u128());
    UInt128 entityId = UInt128.fromBytes(reader.u128());
    UInt128 correlationId = UInt128.fromBytes(reader.u128());
    UInt128 userData = UInt128.fromBytes(reader.u128());
    long latNano = reader.i64();
    long lonNano = reader.i64();
    long groupId = reader.u64();
    long timestamp = reader.u64();
    int altitudeMm = reader.i32();
    int velocityMms = reader.u32();
    int ttlSeconds = reader.u32();
    int accuracyMm = reader.u32();
    short headingCdeg = (short) reader.u16();
    short flags = (short) reader.u16();
    reader.skip(12); // reserved

    return new GeoEvent.Builder()
        .setId(id)
        .setEntityId(entityId)
        .setCorrelationId(correlationId)
        .setUserData(userData)
        .setLatNano(latNano)
        .setLonNano(lonNano)
        .setGroupId(groupId)
        .setTimestamp(timestamp)
        .setAltitudeMm(altitudeMm)
        .setVelocityMms(velocityMms)
        .setTtlSeconds(ttlSeconds)
        .setAccuracyMm(accuracyMm)
        .setHeadingCdeg(headingCdeg)
        .setFlags(flags)
        .build();
  }

  void writeGeoEvent(GeoEvent event) {
    writer.u128(event.getId().toBytes());
    writer.u128(event.getEntityId().toBytes());
    writer.u128(event.getCorrelationId().toBytes());
    writer.u128(event.getUserData().toBytes());
    writer.i64(event.getLatNano());
    writer.i64(event.getLonNano());
    writer.u64(event.getGroupId());
    writer.u64(event.getTimestamp());
    writer.i32(event.getAltitudeMm());
    writer.u32(event.getVelocityMms());
    writer.u32(event.getTtlSeconds());
    writer.u32(event.getAccuracyMm());
    writer.u16(event.getHeadingCdeg());
    writer.u16(event.getFlags());
    writer.zeros(12);
  }

  enum Operation {
    INSERT_EVENTS(146, 128, 8),
    QUERY_UUID(149, 32, 16),
    QUERY_LATEST(154, 128, 128);

    int value;
    int eventSize;
    int resultSize;

    Operation(int value, int eventSize, int resultSize) {
      this.value = value;
      this.eventSize = eventSize;
      this.resultSize = resultSize;
    }

    static Map<Integer, Operation> BY_VALUE = new HashMap<>();
    static {
      for (var element : values()) {
        BY_VALUE.put(element.value, element);
      }
    }

    static Operation fromValue(int value) {
      var result = BY_VALUE.get(value);
      if (result == null) {
        throw new RuntimeException("invalid operation: " + value);
      }
      return result;
    }

    int eventSize() {
      return eventSize;
    }

    int resultSize() {
      return resultSize;
    }
  }

  static class Reader {
    ReadableByteChannel input;
    ByteBuffer buffer = null;

    Reader(ReadableByteChannel input) {
      this.input = input;
    }

    void read(int count) throws IOException {
      if (this.buffer != null && this.buffer.hasRemaining()) {
        throw new RuntimeException(String.format("existing read buffer has %d bytes remaining",
            this.buffer.remaining()));
      }
      this.buffer = ByteBuffer.allocateDirect(count).order(BYTE_ORDER);
      int read = 0;
      while (read < count) {
        read += input.read(this.buffer);
      }
      this.buffer.rewind();
    }

    void skip(int bytes) {
      buffer.position(buffer.position() + bytes);
    }

    int u8() {
      return Byte.toUnsignedInt(buffer.get());
    }

    int u16() {
      return Short.toUnsignedInt(buffer.getShort());
    }

    int u32() {
      return (int) Integer.toUnsignedLong(buffer.getInt());
    }

    long u64() {
      return buffer.getLong();
    }

    long i64() {
      return buffer.getLong();
    }

    int i32() {
      return buffer.getInt();
    }

    byte[] u128() {
      var result = new byte[16];
      buffer.get(result, 0, 16);
      return result;
    }
  }

  static class Writer {
    WritableByteChannel output;
    ByteBuffer buffer = null;

    Writer(WritableByteChannel output) {
      this.output = output;
    }

    void allocate(int count) {
      if (this.buffer != null && this.buffer.hasRemaining()) {
        throw new RuntimeException(String.format("existing write buffer has %d bytes remaining",
            this.buffer.remaining()));
      }
      this.buffer = ByteBuffer.allocateDirect(count).order(BYTE_ORDER);
    }

    void u8(int value) {
      buffer.put((byte) value);
    }

    void u16(int value) {
      buffer.putShort((short) value);
    }

    void u32(int value) {
      buffer.putInt(value);
    }

    void u64(long value) {
      buffer.putLong(value);
    }

    void i64(long value) {
      buffer.putLong(value);
    }

    void i32(int value) {
      buffer.putInt(value);
    }

    void u128(byte[] bytes) {
      buffer.put(bytes);
    }

    void bytes(byte[] bytes) {
      buffer.put(bytes);
    }

    void zeros(int count) {
      for (int i = 0; i < count; i++) {
        buffer.put((byte) 0);
      }
    }

    void flush() throws IOException {
      buffer.rewind();
      output.write(buffer);
      buffer = null;
    }
  }
}
