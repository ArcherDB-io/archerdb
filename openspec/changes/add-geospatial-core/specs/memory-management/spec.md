# Memory Management Specification

**Reference Implementation:** https://github.com/tigerbeetle/tigerbeetle/blob/main/src/stdx.zig

This spec is based on TigerBeetle's static memory allocation discipline. Implementers MUST study:
- `src/stdx.zig` - Intrusive data structures (QueueType, StackType, RingBufferType)
- `src/message_pool.zig` - Message pooling with reference counting
- `src/lsm/node_pool.zig` - NodePool with bitset tracking
- TigerBeetle's allocator patterns throughout codebase

**Implementation approach:** TigerBeetle's memory management is core to its reliability. Do NOT deviate from these patterns. Copy the allocator discipline exactly.

---

## ADDED Requirements

### Requirement: Static Allocator

The system SHALL use a state-machine allocator that enforces strict allocation discipline with three phases: init, static, and deinit.

#### Scenario: Allocator states

- **WHEN** the StaticAllocator is used
- **THEN** it SHALL support three states:
  - `init` - Allow `alloc` and `resize` (startup phase)
  - `static` - Disallow all allocation operations (production runtime)
  - `deinit` - Allow `free` but not `alloc` or `resize` (shutdown)

#### Scenario: State transitions

- **WHEN** startup is complete
- **THEN** `transition_from_init_to_static()` SHALL be called
- **AND** any subsequent allocation attempts SHALL panic
- **AND** this prevents accidental allocations in hot paths

#### Scenario: Wrapped allocator

- **WHEN** StaticAllocator wraps a parent allocator
- **THEN** it SHALL forward operations to parent when state permits
- **AND** it SHALL panic when state prohibits the operation

### Requirement: Message Pool

The system SHALL pre-allocate all messages at startup and reuse them via reference counting.

#### Scenario: Pool initialization

- **WHEN** the MessagePool is initialized
- **THEN** it SHALL allocate `messages_max` message buffers
- **AND** all buffers SHALL be sector-aligned (`constants.sector_size`)
- **AND** buffer size SHALL be `constants.message_size_max`

#### Scenario: Message structure

- **WHEN** a Message is defined
- **THEN** it SHALL contain:
  - `header: *Header` - Pointer to header in buffer
  - `buffer: *align(sector_size) [message_size_max]u8` - The buffer
  - `references: u32` - Reference count
  - `link: FreeList.Link` - Intrusive free list link

#### Scenario: Reference counting

- **WHEN** a message is acquired from pool
- **THEN** `references` SHALL be set to 1
- **WHEN** `message.ref()` is called
- **THEN** `references` SHALL increment
- **WHEN** message is released
- **THEN** `references` SHALL decrement
- **AND** if `references == 0`, message returns to free list

#### Scenario: Pool sizing

- **WHEN** calculating `messages_max`
- **THEN** it SHALL account for:
  - Journal read/write IOPS
  - Client replies IOPS
  - Grid repair reads
  - Pipeline depth
  - Connection send queues
- **AND** this ensures no deadlock from message exhaustion

### Requirement: Intrusive Data Structures

The system SHALL use intrusive linked lists and queues that embed links within elements to avoid allocation.

#### Scenario: Intrusive queue

- **WHEN** using QueueType(T)
- **THEN** T MUST have a `link: QueueType(T).Link` field
- **AND** push/pop operations use only the embedded link
- **AND** no separate node allocation occurs

#### Scenario: Intrusive stack

- **WHEN** using StackType(T)
- **THEN** T MUST have a `link: StackType(T).Link` field
- **AND** push/pop operations use only the embedded link
- **AND** capacity is tracked for overflow detection

#### Scenario: Free list implementation

- **WHEN** the message pool tracks free messages
- **THEN** it SHALL use an intrusive StackType
- **AND** the Link is embedded in Message struct
- **AND** no heap allocation for list nodes

### Requirement: Ring Buffer

The system SHALL implement generic ring buffers supporting both compile-time and runtime capacity.

#### Scenario: Compile-time capacity

- **WHEN** `RingBufferType(T, .{ .array = N })` is used
- **THEN** the buffer SHALL be `[N]T` (stack-allocated)
- **AND** no runtime allocation occurs

#### Scenario: Runtime capacity

- **WHEN** `RingBufferType(T, .slice)` is used
- **THEN** the buffer SHALL be `[]T` (heap-allocated at init)
- **AND** allocation occurs only during initialization

#### Scenario: Ring operations

- **WHEN** ring buffer operations are performed
- **THEN** `push_assume_capacity()` SHALL add at `(index + count) % capacity`
- **AND** `pop()` SHALL remove at `index`
- **AND** wraparound is handled via modular arithmetic

### Requirement: Node Pool

The system SHALL pre-allocate fixed-size nodes for LSM manifest management.

#### Scenario: Node pool structure

- **WHEN** NodePoolType is configured
- **THEN** it SHALL have:
  - `node_size: u32` - Size of each node (must be power of 2)
  - `node_alignment: u13` - Alignment requirement
  - `buffer: []align(node_alignment) u8` - Contiguous storage
  - `free: DynamicBitSetUnmanaged` - Tracks which nodes are free

#### Scenario: Node acquisition

- **WHEN** `pool.acquire()` is called
- **THEN** it SHALL find first set bit in free bitset
- **AND** unset that bit
- **AND** return pointer to that node's memory
- **AND** panic if no free nodes (capacity exhausted)

#### Scenario: Node release

- **WHEN** `pool.release(node)` is called
- **THEN** it SHALL calculate node index from pointer arithmetic
- **AND** set the corresponding bit in free bitset

### Requirement: Scratch Memory

The system SHALL provide shared temporary buffers for sorting and intermediate computations.

#### Scenario: Scratch buffer structure

- **WHEN** ScratchMemory is initialized
- **THEN** buffer SHALL be page-aligned (`std.heap.page_size_min`)
- **AND** state SHALL be tracked (`free` or `busy`)

#### Scenario: Scratch acquisition

- **WHEN** `scratch.acquire(T, count)` is called
- **THEN** state MUST be `free`
- **AND** state transitions to `busy`
- **AND** returns `[]T` slice of requested size

#### Scenario: Scratch release

- **WHEN** `scratch.release(T, slice)` is called
- **THEN** state MUST be `busy`
- **AND** state transitions to `free`
- **AND** buffer is available for reuse

### Requirement: Table Memory

The system SHALL pre-allocate memory for LSM in-memory tables.

#### Scenario: Table memory initialization

- **WHEN** TableMemory is initialized
- **THEN** it SHALL allocate `[]Value` of size `Table.value_count_max`
- **AND** track mutability state (mutable vs immutable)

#### Scenario: Mutable table operations

- **WHEN** a table is mutable
- **THEN** `put(value)` appends to values array
- **AND** count is tracked in `value_context`
- **AND** shared ScratchMemory is used for sorting

#### Scenario: Immutable transition

- **WHEN** a mutable table becomes immutable
- **THEN** it MAY be flushed to disk
- **AND** `snapshot_min` is recorded
- **AND** no further puts are allowed

### Requirement: Bounded Array

The system SHALL use fixed-capacity arrays with compile-time bounds for safety.

#### Scenario: BoundedArrayType definition

- **WHEN** `BoundedArrayType(T, capacity)` is used
- **THEN** it SHALL have:
  - `buffer: [capacity]T` - Fixed-size storage
  - `count_u32: u32` - Current element count

#### Scenario: Bounded operations

- **WHEN** operations are performed
- **THEN** `push()` SHALL assert `!full()` before adding
- **AND** `pop()` SHALL assert `count > 0` before removing
- **AND** bounds violations cause panic (not undefined behavior)

### Requirement: Counting Allocator

The system SHALL track memory usage via a wrapper allocator for monitoring.

#### Scenario: Counting allocator structure

- **WHEN** CountingAllocator wraps a parent
- **THEN** it SHALL track:
  - `alloc_size: u64` - Total bytes allocated
  - `free_size: u64` - Total bytes freed
  - `live_size()` = `alloc_size - free_size`

#### Scenario: Allocation tracking

- **WHEN** allocations/frees occur through CountingAllocator
- **THEN** sizes SHALL be accumulated
- **AND** `live_size()` reports current memory usage
- **AND** this is used for monitoring and debugging

### Requirement: Compile-Time Memory Calculations

The system SHALL calculate all memory sizes at compile time for determinism and validation.

#### Scenario: Constant definitions

- **WHEN** sizing constants are defined
- **THEN** they SHALL be `comptime` values
- **AND** dependencies SHALL be calculated at compile time
- **AND** constraints SHALL be validated via `comptime` assertions

#### Scenario: Size relationships

- **WHEN** calculating sizes
- **THEN** these relationships SHALL hold:
  - `message_size_max % sector_size == 0`
  - `client_replies_size = clients_max * message_size_max`
  - `journal_size = journal_slot_count * (header_size + message_size_max)`
  - `block_size % sector_size == 0`

#### Scenario: Capacity validation

- **WHEN** capacities are configured
- **THEN** comptime assertions SHALL verify:
  - Message pool is large enough for all subsystems
  - Journal slots support pipeline + checkpoint requirements
  - Node pool can hold max manifest entries
