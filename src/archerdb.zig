// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const vsr = @import("vsr.zig");
const constants = vsr.constants;
const stdx = vsr.stdx;
const maybe = stdx.maybe;

// GeoEvent types for geospatial operations
const geo_event = @import("geo_event.zig");
const geo_state_machine = @import("geo_state_machine.zig");
const ttl = @import("ttl.zig");

pub const GeoEvent = geo_event.GeoEvent;
pub const GeoEventFlags = geo_event.GeoEventFlags;
pub const QueryUuidFilter = geo_state_machine.QueryUuidFilter;
pub const QueryRadiusFilter = geo_state_machine.QueryRadiusFilter;
pub const QueryPolygonFilter = geo_state_machine.QueryPolygonFilter;
pub const QueryResponse = geo_state_machine.QueryResponse;
pub const PolygonVertex = geo_state_machine.PolygonVertex;
pub const InsertGeoEventResult = geo_state_machine.InsertGeoEventResult;
pub const InsertGeoEventsResult = geo_state_machine.InsertGeoEventsResult;
pub const DeleteEntityResult = geo_state_machine.DeleteEntityResult;
pub const DeleteEntitiesResult = geo_state_machine.DeleteEntitiesResult;
pub const QueryLatestFilter = geo_state_machine.QueryLatestFilter;

// TTL cleanup types (F2.4.8)
pub const CleanupRequest = ttl.CleanupRequest;
pub const CleanupResponse = ttl.CleanupResponse;

pub const Account = extern struct {
    id: u128,
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    /// Opaque third-party identifiers to link this account (many-to-one) to external entities.
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    /// Reserved for accounting policy primitives.
    reserved: u32,
    ledger: u32,
    /// A chart of accounts code describing the type of account (e.g. clearing, settlement).
    code: u16,
    flags: AccountFlags,
    timestamp: u64,

    comptime {
        assert(stdx.no_padding(Account));
        assert(@sizeOf(Account) == 128);
        assert(@alignOf(Account) == 16);
    }

    pub fn debits_exceed_credits(self: *const Account, amount: u128) bool {
        return (self.flags.debits_must_not_exceed_credits and
            self.debits_pending + self.debits_posted + amount > self.credits_posted);
    }

    pub fn credits_exceed_debits(self: *const Account, amount: u128) bool {
        return (self.flags.credits_must_not_exceed_debits and
            self.credits_pending + self.credits_posted + amount > self.debits_posted);
    }
};

pub const AccountFlags = packed struct(u16) {
    /// When the .linked flag is specified, it links an event with the next event in the batch, to
    /// create a chain of events, of arbitrary length, which all succeed or fail together. The tail
    /// of a chain is denoted by the first event without this flag. The last event in a batch may
    /// therefore never have the .linked flag set as this would leave a chain open-ended. Multiple
    /// chains or individual events may coexist within a batch to succeed or fail independently.
    /// Events within a chain are executed within order, or are rolled back on error, so that the
    /// effect of each event in the chain is visible to the next, and so that the chain is either
    /// visible or invisible as a unit to subsequent events after the chain. The event that was the
    /// first to break the chain will have a unique error result. Other events in the chain will
    /// have their error result set to .linked_event_failed.
    linked: bool = false,
    debits_must_not_exceed_credits: bool = false,
    credits_must_not_exceed_debits: bool = false,
    history: bool = false,
    imported: bool = false,
    closed: bool = false,
    padding: u10 = 0,

    comptime {
        assert(@sizeOf(AccountFlags) == @sizeOf(u16));
        assert(@bitSizeOf(AccountFlags) == @sizeOf(AccountFlags) * 8);
    }
};

pub const AccountBalance = extern struct {
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    timestamp: u64,
    reserved: [56]u8 = @splat(0),

    comptime {
        assert(stdx.no_padding(AccountBalance));
        assert(@sizeOf(AccountBalance) == 128);
        assert(@alignOf(AccountBalance) == 16);
    }
};

pub const Transfer = extern struct {
    id: u128,
    debit_account_id: u128,
    credit_account_id: u128,
    amount: u128,
    /// If this transfer will post or void a pending transfer, the id of that pending transfer.
    pending_id: u128,
    /// Opaque third-party identifiers to link this transfer (many-to-one) to an external entities.
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    /// Timeout in seconds for pending transfers to expire automatically
    /// if not manually posted or voided.
    timeout: u32,
    ledger: u32,
    /// A chart of accounts code describing the reason for the transfer (e.g. deposit, settlement).
    code: u16,
    flags: TransferFlags,
    timestamp: u64,

    // Converts the timeout from seconds to ns.
    pub fn timeout_ns(self: *const Transfer) u64 {
        // Casting to u64 to avoid integer overflow:
        return @as(u64, self.timeout) * std.time.ns_per_s;
    }

    comptime {
        assert(stdx.no_padding(Transfer));
        assert(@sizeOf(Transfer) == 128);
        assert(@alignOf(Transfer) == 16);
    }
};

pub const TransferPendingStatus = enum(u8) {
    none = 0,
    pending = 1,
    posted = 2,
    voided = 3,
    expired = 4,

    comptime {
        for (std.enums.values(TransferPendingStatus), 0..) |result, index| {
            assert(@intFromEnum(result) == index);
        }
    }
};

pub const TransferFlags = packed struct(u16) {
    linked: bool = false,
    pending: bool = false,
    post_pending_transfer: bool = false,
    void_pending_transfer: bool = false,
    balancing_debit: bool = false,
    balancing_credit: bool = false,
    closing_debit: bool = false,
    closing_credit: bool = false,
    imported: bool = false,
    padding: u7 = 0,

    comptime {
        assert(@sizeOf(TransferFlags) == @sizeOf(u16));
        assert(@bitSizeOf(TransferFlags) == @sizeOf(TransferFlags) * 8);
    }
};

/// Error codes are ordered by descending precedence.
/// When errors do not have an obvious/natural precedence (e.g. "*_must_be_zero"),
/// the ordering matches struct field order.
pub const CreateAccountResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    linked_event_chain_open = 2,

    imported_event_expected = 22,
    imported_event_not_expected = 23,

    timestamp_must_be_zero = 3,

    imported_event_timestamp_out_of_range = 24,
    imported_event_timestamp_must_not_advance = 25,

    reserved_field = 4,
    reserved_flag = 5,

    id_must_not_be_zero = 6,
    id_must_not_be_int_max = 7,

    exists_with_different_flags = 15,
    exists_with_different_user_data_128 = 16,
    exists_with_different_user_data_64 = 17,
    exists_with_different_user_data_32 = 18,
    exists_with_different_ledger = 19,
    exists_with_different_code = 20,
    exists = 21,

    flags_are_mutually_exclusive = 8,

    debits_pending_must_be_zero = 9,
    debits_posted_must_be_zero = 10,
    credits_pending_must_be_zero = 11,
    credits_posted_must_be_zero = 12,
    ledger_must_not_be_zero = 13,
    code_must_not_be_zero = 14,

    imported_event_timestamp_must_not_regress = 26,

    comptime {
        const values = std.enums.values(CreateAccountResult);
        const BitSet = stdx.BitSetType(values.len);
        var set: BitSet = .{};
        for (0..values.len) |index| {
            const result: CreateAccountResult = @enumFromInt(index);
            stdx.maybe(result == values[index]);

            assert(!set.is_set(index));
            set.set(index);
        }

        // It's a non-ordered enum, we need to ensure
        // there are no gaps in the numbering of the values.
        assert(set.full());
    }
};

/// Error codes are ordered by descending precedence.
/// When errors do not have an obvious/natural precedence (e.g. "*_must_not_be_zero"),
/// the ordering matches struct field order.
pub const CreateTransferResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    linked_event_chain_open = 2,

    imported_event_expected = 56,
    imported_event_not_expected = 57,

    timestamp_must_be_zero = 3,

    imported_event_timestamp_out_of_range = 58,
    imported_event_timestamp_must_not_advance = 59,

    reserved_flag = 4,

    id_must_not_be_zero = 5,
    id_must_not_be_int_max = 6,

    exists_with_different_flags = 36,
    exists_with_different_pending_id = 40,
    exists_with_different_timeout = 44,
    exists_with_different_debit_account_id = 37,
    exists_with_different_credit_account_id = 38,
    exists_with_different_amount = 39,
    exists_with_different_user_data_128 = 41,
    exists_with_different_user_data_64 = 42,
    exists_with_different_user_data_32 = 43,
    exists_with_different_ledger = 67,
    exists_with_different_code = 45,
    exists = 46,

    id_already_failed = 68,

    flags_are_mutually_exclusive = 7,

    debit_account_id_must_not_be_zero = 8,
    debit_account_id_must_not_be_int_max = 9,
    credit_account_id_must_not_be_zero = 10,
    credit_account_id_must_not_be_int_max = 11,
    accounts_must_be_different = 12,

    pending_id_must_be_zero = 13,
    pending_id_must_not_be_zero = 14,
    pending_id_must_not_be_int_max = 15,
    pending_id_must_be_different = 16,
    timeout_reserved_for_pending_transfer = 17,

    closing_transfer_must_be_pending = 64,

    ledger_must_not_be_zero = 19,
    code_must_not_be_zero = 20,

    debit_account_not_found = 21,
    credit_account_not_found = 22,

    accounts_must_have_the_same_ledger = 23,
    transfer_must_have_the_same_ledger_as_accounts = 24,

    pending_transfer_not_found = 25,
    pending_transfer_not_pending = 26,

    pending_transfer_has_different_debit_account_id = 27,
    pending_transfer_has_different_credit_account_id = 28,
    pending_transfer_has_different_ledger = 29,
    pending_transfer_has_different_code = 30,

    exceeds_pending_transfer_amount = 31,
    pending_transfer_has_different_amount = 32,

    pending_transfer_already_posted = 33,
    pending_transfer_already_voided = 34,

    pending_transfer_expired = 35,

    imported_event_timestamp_must_not_regress = 60,
    imported_event_timestamp_must_postdate_debit_account = 61,
    imported_event_timestamp_must_postdate_credit_account = 62,
    imported_event_timeout_must_be_zero = 63,

    debit_account_already_closed = 65,
    credit_account_already_closed = 66,

    overflows_debits_pending = 47,
    overflows_credits_pending = 48,
    overflows_debits_posted = 49,
    overflows_credits_posted = 50,
    overflows_debits = 51,
    overflows_credits = 52,
    overflows_timeout = 53,

    exceeds_credits = 54,
    exceeds_debits = 55,

    deprecated_18 = 18, // amount_must_not_be_zero.

    // Update this comment when adding a new value:
    // Last item: id_already_failed = 68.

    /// Returns `true` if the error code depends on transient system status and retrying
    /// the same transfer with identical request data can produce different outcomes.
    pub fn transient(result: CreateTransferResult) bool {
        return switch (result) {
            .ok => unreachable,

            .debit_account_not_found,
            .credit_account_not_found,
            .pending_transfer_not_found,
            .exceeds_credits,
            .exceeds_debits,
            .debit_account_already_closed,
            .credit_account_already_closed,
            => true,

            .linked_event_failed,
            .linked_event_chain_open,
            .imported_event_expected,
            .imported_event_not_expected,
            .timestamp_must_be_zero,
            .imported_event_timestamp_out_of_range,
            .imported_event_timestamp_must_not_advance,
            .reserved_flag,
            .id_must_not_be_zero,
            .id_must_not_be_int_max,
            .id_already_failed,
            .exists_with_different_flags,
            .exists_with_different_pending_id,
            .exists_with_different_timeout,
            .exists_with_different_debit_account_id,
            .exists_with_different_credit_account_id,
            .exists_with_different_amount,
            .exists_with_different_user_data_128,
            .exists_with_different_user_data_64,
            .exists_with_different_user_data_32,
            .exists_with_different_ledger,
            .exists_with_different_code,
            .exists,
            .imported_event_timestamp_must_not_regress,
            .imported_event_timestamp_must_postdate_debit_account,
            .imported_event_timestamp_must_postdate_credit_account,
            .imported_event_timeout_must_be_zero,
            .flags_are_mutually_exclusive,
            .debit_account_id_must_not_be_zero,
            .debit_account_id_must_not_be_int_max,
            .credit_account_id_must_not_be_zero,
            .credit_account_id_must_not_be_int_max,
            .accounts_must_be_different,
            .pending_id_must_be_zero,
            .pending_id_must_not_be_zero,
            .pending_id_must_not_be_int_max,
            .pending_id_must_be_different,
            .timeout_reserved_for_pending_transfer,
            .closing_transfer_must_be_pending,
            .ledger_must_not_be_zero,
            .code_must_not_be_zero,
            .accounts_must_have_the_same_ledger,
            .transfer_must_have_the_same_ledger_as_accounts,
            .pending_transfer_not_pending,
            .pending_transfer_has_different_debit_account_id,
            .pending_transfer_has_different_credit_account_id,
            .pending_transfer_has_different_ledger,
            .pending_transfer_has_different_code,
            .exceeds_pending_transfer_amount,
            .pending_transfer_has_different_amount,
            .pending_transfer_already_posted,
            .pending_transfer_already_voided,
            .pending_transfer_expired,
            .overflows_debits_pending,
            .overflows_credits_pending,
            .overflows_debits_posted,
            .overflows_credits_posted,
            .overflows_debits,
            .overflows_credits,
            .overflows_timeout,
            => false,

            .deprecated_18 => unreachable,
        };
    }

    comptime {
        @setEvalBranchQuota(2_000);
        const values = std.enums.values(CreateTransferResult);
        const BitSet = stdx.BitSetType(values.len);
        var set: BitSet = .{};
        for (0..values.len) |index| {
            const result: CreateTransferResult = @enumFromInt(index);
            stdx.maybe(result == values[index]);

            assert(!set.is_set(index));
            set.set(index);
        }

        // It's a non-ordered enum, we need to ensure
        // there are no gaps in the numbering of the values.
        assert(set.full());
    }

    /// NOTE(zig): CreateTransferResult ordered by precedence (Zig compiler limitation workaround)
    /// `EnumSet`, and `@setEvalBranchQuota()` isn't propagating correctly:
    /// https://godbolt.org/z/6a45bx6xs
    /// error: evaluation exceeded 1000 backwards branches
    /// note: use @setEvalBranchQuota() to raise the branch limit from 1000.
    ///
    /// As a workaround we generate a new Ordered enum to be used in this case.
    pub const Ordered = type: {
        const values = std.enums.values(CreateTransferResult);
        var fields: [values.len]std.builtin.Type.EnumField = undefined;
        for (0..values.len) |index| {
            const result: CreateTransferResult = @enumFromInt(index);
            fields[index] = .{
                .name = @tagName(result),
                .value = index,
            };
        }

        var type_info = @typeInfo(enum {});
        type_info.@"enum".tag_type = std.meta.Tag(CreateTransferResult);
        type_info.@"enum".fields = &fields;
        break :type @Type(type_info);
    };

    pub fn to_ordered(value: CreateTransferResult) Ordered {
        return @enumFromInt(@intFromEnum(value));
    }

    comptime {
        const values = std.enums.values(Ordered);
        assert(values.len == std.enums.values(CreateTransferResult).len);
        for (0..values.len) |index| {
            const value: Ordered = @enumFromInt(index);
            assert(value == values[index]);

            const value_source: CreateTransferResult = @enumFromInt(index);
            assert(std.mem.eql(u8, @tagName(value_source), @tagName(value)));
        }
    }
};

pub const CreateAccountsResult = extern struct {
    index: u32,
    result: CreateAccountResult,

    comptime {
        assert(@sizeOf(CreateAccountsResult) == 8);
        assert(stdx.no_padding(CreateAccountsResult));
    }
};

pub const CreateTransfersResult = extern struct {
    index: u32,
    result: CreateTransferResult,

    comptime {
        assert(@sizeOf(CreateTransfersResult) == 8);
        assert(stdx.no_padding(CreateTransfersResult));
    }
};

/// Response to archerdb_ping operation (F1.2.6).
/// Simple echo to verify cluster connectivity at the state machine level.
pub const PingResponse = extern struct {
    /// Server timestamp when ping was processed
    timestamp: u64,
    /// Reserved for future use
    reserved: [120]u8 = @splat(0),

    comptime {
        assert(@sizeOf(PingResponse) == 128);
        assert(stdx.no_padding(PingResponse));
    }
};

/// Response to archerdb_get_status operation (F1.2.6).
/// Returns current cluster and node status information.
pub const StatusResponse = extern struct {
    /// Current view number (monotonically increasing)
    view: u64,
    /// Most recent commit timestamp
    commit_timestamp: u64,
    /// Number of entities in RAM index
    entity_count: u64,
    /// Checkpoint operation number
    checkpoint_op: u64,
    /// Current operation number (log head)
    log_head_op: u64,
    /// Replica index (0-based)
    replica_index: u8,
    /// Total replica count in cluster
    replica_count: u8,
    /// Status flags (bit 0: is_primary, bit 1: is_syncing)
    status_flags: u8,
    /// Reserved for alignment
    reserved_byte: u8 = 0,
    /// Reserved for future use (44 = 128 - 40 - 44, where 40 = 5*u64, 4 = 4*u8)
    reserved: [84]u8 = @splat(0),

    comptime {
        assert(@sizeOf(StatusResponse) == 128);
        assert(stdx.no_padding(StatusResponse));
    }
};

pub const QueryFilter = extern struct {
    /// Query by the `user_data_128` index.
    /// Use zero for no filter.
    user_data_128: u128,
    /// Query by the `user_data_64` index.
    /// Use zero for no filter.
    user_data_64: u64,
    /// Query by the `user_data_32` index.
    /// Use zero for no filter.
    user_data_32: u32,
    /// Query by the `ledger` index.
    /// Use zero for no filter.
    ledger: u32,
    /// Query by the `code` index.
    /// Use zero for no filter.
    code: u16,
    reserved: [6]u8 = @splat(0),
    /// The initial timestamp (inclusive).
    /// Use zero for no filter.
    timestamp_min: u64,
    /// The final timestamp (inclusive).
    /// Use zero for no filter.
    timestamp_max: u64,
    /// Maximum number of results that can be returned by this query.
    /// Must be greater than zero.
    limit: u32,
    /// Query flags.
    flags: QueryFilterFlags,

    comptime {
        assert(@sizeOf(QueryFilter) == 64);
        assert(stdx.no_padding(QueryFilter));
    }
};

pub const QueryFilterFlags = packed struct(u32) {
    /// Whether the results are sorted by timestamp in chronological or reverse-chronological order.
    reversed: bool,
    padding: u31 = 0,

    comptime {
        assert(@sizeOf(QueryFilterFlags) == @sizeOf(u32));
        assert(@bitSizeOf(QueryFilterFlags) == @sizeOf(QueryFilterFlags) * 8);
    }
};

/// Filter used in both `get_account_transfers` and `get_account_balances`.
pub const AccountFilter = extern struct {
    /// The account id.
    account_id: u128,
    /// Filter by the `user_data_128` index.
    /// Use zero for no filter.
    user_data_128: u128,
    /// Filter by the `user_data_64` index.
    /// Use zero for no filter.
    user_data_64: u64,
    /// Filter by the `user_data_32` index.
    /// Use zero for no filter.
    user_data_32: u32,
    /// Query by the `code` index.
    /// Use zero for no filter.
    code: u16,

    reserved: [58]u8 = @splat(0),
    /// The initial timestamp (inclusive).
    /// Use zero for no filter.
    timestamp_min: u64,
    /// The final timestamp (inclusive).
    /// Use zero for no filter.
    timestamp_max: u64,
    /// Maximum number of results that can be returned by this query.
    /// Must be greater than zero.
    limit: u32,
    /// Query flags.
    flags: AccountFilterFlags,

    comptime {
        assert(@sizeOf(AccountFilter) == 128);
        assert(stdx.no_padding(AccountFilter));
    }
};

pub const AccountFilterFlags = packed struct(u32) {
    /// Whether to include results where `debit_account_id` matches.
    debits: bool,
    /// Whether to include results where `credit_account_id` matches.
    credits: bool,
    /// Whether the results are sorted by timestamp in chronological or reverse-chronological order.
    reversed: bool,
    padding: u29 = 0,

    comptime {
        assert(@sizeOf(AccountFilterFlags) == @sizeOf(u32));
        assert(@bitSizeOf(AccountFilterFlags) == @sizeOf(AccountFilterFlags) * 8);
    }
};

pub const ChangeEventType = enum(u8) {
    single_phase = 0,
    two_phase_pending = 1,
    two_phase_posted = 2,
    two_phase_voided = 3,
    two_phase_expired = 4,
};

pub const ChangeEvent = extern struct {
    transfer_id: u128,
    transfer_amount: u128,
    transfer_pending_id: u128,
    transfer_user_data_128: u128,
    transfer_user_data_64: u64,
    transfer_user_data_32: u32,
    transfer_timeout: u32,
    transfer_code: u16,
    transfer_flags: TransferFlags,

    ledger: u32,
    type: ChangeEventType,
    reserved: [39]u8 = @splat(0),

    debit_account_id: u128,
    debit_account_debits_pending: u128,
    debit_account_debits_posted: u128,
    debit_account_credits_pending: u128,
    debit_account_credits_posted: u128,
    debit_account_user_data_128: u128,
    debit_account_user_data_64: u64,
    debit_account_user_data_32: u32,
    debit_account_code: u16,
    debit_account_flags: AccountFlags,

    credit_account_id: u128,
    credit_account_debits_pending: u128,
    credit_account_debits_posted: u128,
    credit_account_credits_pending: u128,
    credit_account_credits_posted: u128,
    credit_account_user_data_128: u128,
    credit_account_user_data_64: u64,
    credit_account_user_data_32: u32,
    credit_account_code: u16,
    credit_account_flags: AccountFlags,

    timestamp: u64,
    transfer_timestamp: u64,
    debit_account_timestamp: u64,
    credit_account_timestamp: u64,

    comptime {
        assert(stdx.no_padding(ChangeEvent));
        // Each event has the size of one transfer + 2 accounts.
        assert(@sizeOf(ChangeEvent) == @sizeOf(Transfer) + (2 * @sizeOf(Account)));
        assert(@alignOf(ChangeEvent) == 16);
    }
};

pub const ChangeEventsFilter = extern struct {
    timestamp_min: u64,
    timestamp_max: u64,
    limit: u32,
    reserved: [44]u8 = @splat(0),

    comptime {
        assert(stdx.no_padding(ChangeEventsFilter));
        assert(@sizeOf(ChangeEventsFilter) == 64);
    }
};

// Looking to make backwards incompatible changes here? Make sure to check release.zig for
// `release_triple_client_min`.
pub const Operation = enum(u8) {
    /// Operations exported by TigerBeetle:
    pulse = constants.vsr_operations_reserved + 0,

    // Deprecated operations not encoded as multi-batch:
    deprecated_create_accounts_unbatched = constants.vsr_operations_reserved + 1,
    deprecated_create_transfers_unbatched = constants.vsr_operations_reserved + 2,
    deprecated_lookup_accounts_unbatched = constants.vsr_operations_reserved + 3,
    deprecated_lookup_transfers_unbatched = constants.vsr_operations_reserved + 4,
    deprecated_get_account_transfers_unbatched = constants.vsr_operations_reserved + 5,
    deprecated_get_account_balances_unbatched = constants.vsr_operations_reserved + 6,
    deprecated_query_accounts_unbatched = constants.vsr_operations_reserved + 7,
    deprecated_query_transfers_unbatched = constants.vsr_operations_reserved + 8,

    get_change_events = constants.vsr_operations_reserved + 9,

    create_accounts = constants.vsr_operations_reserved + 10,
    create_transfers = constants.vsr_operations_reserved + 11,
    lookup_accounts = constants.vsr_operations_reserved + 12,
    lookup_transfers = constants.vsr_operations_reserved + 13,
    get_account_transfers = constants.vsr_operations_reserved + 14,
    get_account_balances = constants.vsr_operations_reserved + 15,
    query_accounts = constants.vsr_operations_reserved + 16,
    query_transfers = constants.vsr_operations_reserved + 17,

    // ArcherDB geospatial operations (F1.2)
    insert_events = constants.vsr_operations_reserved + 18,
    upsert_events = constants.vsr_operations_reserved + 19,
    delete_entities = constants.vsr_operations_reserved + 20,
    query_uuid = constants.vsr_operations_reserved + 21,
    query_radius = constants.vsr_operations_reserved + 22,
    query_polygon = constants.vsr_operations_reserved + 23,
    query_latest = constants.vsr_operations_reserved + 26, // F1.3.3: Most recent events globally

    // ArcherDB admin operations (F1.2.6)
    // Note: These complement the VSR-layer ping_client/pong_client for client-visible status
    archerdb_ping = constants.vsr_operations_reserved + 24,
    archerdb_get_status = constants.vsr_operations_reserved + 25,

    // ArcherDB TTL cleanup operation (F2.4.8)
    cleanup_expired = constants.vsr_operations_reserved + 27,

    pub fn EventType(comptime operation: Operation) type {
        return switch (operation) {
            .pulse => void,
            .create_accounts => Account,
            .create_transfers => Transfer,
            .lookup_accounts => u128,
            .lookup_transfers => u128,
            .get_account_transfers => AccountFilter,
            .get_account_balances => AccountFilter,
            .query_accounts => QueryFilter,
            .query_transfers => QueryFilter,
            .get_change_events => ChangeEventsFilter,

            // ArcherDB geospatial operations
            .insert_events => GeoEvent,
            .upsert_events => GeoEvent,
            .delete_entities => u128, // entity_id to delete
            .query_uuid => QueryUuidFilter,
            .query_radius => QueryRadiusFilter,
            .query_polygon => QueryPolygonFilter,
            .query_latest => QueryLatestFilter, // F1.3.3

            // ArcherDB admin operations (F1.2.6)
            .archerdb_ping => void, // No request body needed
            .archerdb_get_status => void, // No request body needed

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => CleanupRequest,

            .deprecated_create_accounts_unbatched => Account,
            .deprecated_create_transfers_unbatched => Transfer,
            .deprecated_lookup_accounts_unbatched => u128,
            .deprecated_lookup_transfers_unbatched => u128,
            .deprecated_get_account_transfers_unbatched => AccountFilter,
            .deprecated_get_account_balances_unbatched => AccountFilter,
            .deprecated_query_accounts_unbatched => QueryFilter,
            .deprecated_query_transfers_unbatched => QueryFilter,
        };
    }

    pub fn ResultType(comptime operation: Operation) type {
        return switch (operation) {
            .pulse => void,
            .create_accounts => CreateAccountsResult,
            .create_transfers => CreateTransfersResult,
            .lookup_accounts => Account,
            .lookup_transfers => Transfer,
            .get_account_transfers => Transfer,
            .get_account_balances => AccountBalance,
            .query_accounts => Account,
            .query_transfers => Transfer,
            .get_change_events => ChangeEvent,

            // ArcherDB geospatial operations
            .insert_events => InsertGeoEventsResult,
            .upsert_events => InsertGeoEventsResult,
            .delete_entities => DeleteEntitiesResult,
            .query_uuid => GeoEvent,
            .query_radius => GeoEvent,
            .query_polygon => GeoEvent,
            .query_latest => GeoEvent, // F1.3.3

            // ArcherDB admin operations (F1.2.6)
            .archerdb_ping => PingResponse,
            .archerdb_get_status => StatusResponse,

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => CleanupResponse,

            .deprecated_create_accounts_unbatched => CreateAccountsResult,
            .deprecated_create_transfers_unbatched => CreateTransfersResult,
            .deprecated_lookup_accounts_unbatched => Account,
            .deprecated_lookup_transfers_unbatched => Transfer,
            .deprecated_get_account_transfers_unbatched => Transfer,
            .deprecated_get_account_balances_unbatched => AccountBalance,
            .deprecated_query_accounts_unbatched => Account,
            .deprecated_query_transfers_unbatched => Transfer,
        };
    }

    /// Inline function so that `operation` can be known at comptime.
    pub inline fn event_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.EventType()),
        };
    }

    /// Inline function so that `operation` can be known at comptime.
    pub inline fn result_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.ResultType()),
        };
    }

    /// Whether the operation supports multiple events per batch.
    /// If not, multi-batch requests are still supported, but with a single event per batch.
    pub inline fn is_batchable(operation: Operation) bool {
        return switch (operation) {
            // Pulse does not take any input.
            .pulse => false,
            // Operations that take multiple events as input:
            .create_accounts => true,
            .create_transfers => true,
            .lookup_accounts => true,
            .lookup_transfers => true,
            // Operations that take a single event as input:
            .get_account_transfers => false,
            .get_account_balances => false,
            .query_accounts => false,
            .query_transfers => false,
            .get_change_events => false,

            // ArcherDB geospatial operations
            .insert_events => true, // Batch of GeoEvents
            .upsert_events => true, // Batch of GeoEvents
            .delete_entities => true, // Batch of entity_ids
            .query_uuid => false, // Single UUID filter
            .query_radius => false, // Single radius query
            .query_polygon => false, // Single polygon query
            .query_latest => false, // Single filter (F1.3.3)

            // ArcherDB admin operations (F1.2.6) - no batching
            .archerdb_ping => false,
            .archerdb_get_status => false,

            // ArcherDB TTL cleanup (F2.4.8) - single request
            .cleanup_expired => false,

            .deprecated_create_accounts_unbatched => true,
            .deprecated_create_transfers_unbatched => true,
            .deprecated_lookup_accounts_unbatched => true,
            .deprecated_lookup_transfers_unbatched => true,
            .deprecated_get_account_transfers_unbatched => false,
            .deprecated_get_account_balances_unbatched => false,
            .deprecated_query_accounts_unbatched => false,
            .deprecated_query_transfers_unbatched => false,
        };
    }

    /// Whether the operation is multi-batch encoded.
    /// Inline function so that `operation` can be known at comptime.
    pub inline fn is_multi_batch(operation: Operation) bool {
        return switch (operation) {
            .pulse => false,

            .create_accounts,
            .create_transfers,
            .lookup_accounts,
            .lookup_transfers,
            .get_account_transfers,
            .get_account_balances,
            .query_accounts,
            .query_transfers,
            => true,

            .get_change_events => false,

            // ArcherDB geospatial operations - single batch for now (F1.3.5)
            // ENHANCEMENT: Add multi-batch support for better throughput (single-batch functional)
            .insert_events,
            .upsert_events,
            .delete_entities,
            .query_uuid,
            .query_latest,
            .query_radius,
            .query_polygon,
            => false,

            // ArcherDB admin operations (F1.2.6) - single batch
            .archerdb_ping => false,
            .archerdb_get_status => false,

            // ArcherDB TTL cleanup (F2.4.8) - single batch
            .cleanup_expired => false,

            .deprecated_create_accounts_unbatched,
            .deprecated_create_transfers_unbatched,
            .deprecated_lookup_accounts_unbatched,
            .deprecated_lookup_transfers_unbatched,
            .deprecated_get_account_transfers_unbatched,
            .deprecated_get_account_balances_unbatched,
            .deprecated_query_accounts_unbatched,
            .deprecated_query_transfers_unbatched,
            => false,
        };
    }

    /// Whether the operation has variable-length request body (header + trailing data).
    /// For example, query_polygon has QueryPolygonFilter (128 bytes) followed by
    /// variable-length PolygonVertex array (N × 16 bytes).
    /// Inline function so that `operation` can be known at comptime.
    pub inline fn is_variable_length(operation: Operation) bool {
        return switch (operation) {
            // query_polygon body = QueryPolygonFilter + PolygonVertex[]
            .query_polygon => true,

            // All other operations have fixed-size events
            else => false,
        };
    }

    /// The maximum number of events per batch.
    /// Inline function so that `operation` and `batch_size_limit` can be known at comptime.
    pub inline fn event_max(operation: Operation, batch_size_limit: u32) u32 {
        assert(batch_size_limit > 0);
        assert(batch_size_limit <= constants.message_body_size_max);

        const event_size_bytes: u32 = operation.event_size();
        maybe(event_size_bytes == 0); // Zeroed event size is allowed.
        const result_size_bytes: u32 = operation.result_size();
        assert(result_size_bytes > 0);

        if (!operation.is_multi_batch()) {
            return if (event_size_bytes == 0)
                @divFloor(constants.message_body_size_max, result_size_bytes)
            else
                @min(
                    @divFloor(batch_size_limit, event_size_bytes),
                    @divFloor(constants.message_body_size_max, result_size_bytes),
                );
        }
        assert(operation.is_multi_batch());

        const reply_trailer_size_min: u32 = vsr.multi_batch.trailer_total_size(.{
            .element_size = result_size_bytes,
            .batch_count = 1,
        });
        assert(reply_trailer_size_min > 0);
        assert(reply_trailer_size_min < batch_size_limit);

        if (event_size_bytes == 0) {
            return @divFloor(
                constants.message_body_size_max - reply_trailer_size_min,
                result_size_bytes,
            );
        } else {
            const request_trailer_size_min: u32 = vsr.multi_batch.trailer_total_size(.{
                .element_size = event_size_bytes,
                .batch_count = 1,
            });
            assert(request_trailer_size_min > 0);
            assert(request_trailer_size_min < constants.message_body_size_max);

            return @min(
                @divFloor(batch_size_limit - request_trailer_size_min, event_size_bytes),
                @divFloor(
                    constants.message_body_size_max - reply_trailer_size_min,
                    result_size_bytes,
                ),
            );
        }
    }

    /// The maximum number of results per batch.
    /// If the number of results is defined by the number of events (`is_batchable()`
    /// is true) then `result_max() == event_max()`.
    /// Inline function so that `operation` and `batch_size_limit` can be known at comptime.
    pub inline fn result_max(operation: Operation, batch_size_limit: u32) u32 {
        assert(batch_size_limit > 0);
        assert(batch_size_limit <= constants.message_body_size_max);
        if (operation.is_batchable()) {
            return operation.event_max(batch_size_limit);
        }
        assert(!operation.is_batchable());

        const result_size_bytes = operation.result_size();
        assert(result_size_bytes > 0);

        if (!operation.is_multi_batch()) {
            return @divFloor(constants.message_body_size_max, result_size_bytes);
        }
        assert(operation.is_multi_batch());

        const reply_trailer_size_min: u32 = vsr.multi_batch.trailer_total_size(.{
            .element_size = result_size_bytes,
            .batch_count = 1,
        });
        return @divFloor(
            constants.message_body_size_max - reply_trailer_size_min,
            result_size_bytes,
        );
    }

    /// Returns the expected number of results for a given batch.
    /// For multi-batch requests, this function expects a single, already decoded batch.
    /// Inline function so that `operation` can be known at comptime.
    pub inline fn result_count_expected(
        operation: Operation,
        batch: []const u8,
    ) u32 {
        return switch (operation) {
            .pulse => 0,
            inline .create_accounts,
            .create_transfers,
            .lookup_accounts,
            .lookup_transfers,
            // ArcherDB geospatial batchable operations
            .insert_events,
            .upsert_events,
            .delete_entities,
            .deprecated_create_accounts_unbatched,
            .deprecated_create_transfers_unbatched,
            .deprecated_lookup_accounts_unbatched,
            .deprecated_lookup_transfers_unbatched,
            => |operation_comptime| count: {
                // For these types of operations, each event produces at most one result.
                comptime assert(operation_comptime.is_batchable());

                // Clients do not validate batch size == 0,
                // and even the simulator can generate requests with no events.
                if (batch.len == 0) return 0;

                const event_size_bytes: u32 = operation_comptime.event_size();
                comptime assert(event_size_bytes > 0);
                assert(batch.len % event_size_bytes == 0); // Input has already been validated.

                break :count @intCast(@divExact(batch.len, event_size_bytes));
            },
            inline .get_account_transfers,
            .get_account_balances,
            .query_accounts,
            .query_transfers,
            // ArcherDB geospatial query operations
            .query_uuid,
            .query_latest,
            .query_radius,
            .query_polygon,
            .deprecated_get_account_transfers_unbatched,
            .deprecated_get_account_balances_unbatched,
            .deprecated_query_accounts_unbatched,
            .deprecated_query_transfers_unbatched,
            .get_change_events,
            => |operation_comptime| count: {
                // For queries, each event produces up to `limit` events.
                comptime assert(!operation_comptime.is_batchable());

                const Filter = operation_comptime.EventType();
                comptime assert(@sizeOf(Filter) > 0);
                assert(batch.len == @sizeOf(Filter));
                // This function is used by the client,
                // so the input may come from unaligned memory.
                maybe(!std.mem.isAligned(@intFromPtr(batch.ptr), @alignOf(Filter)));

                const filter: Filter = std.mem.bytesToValue(Filter, batch);
                maybe(filter.limit == 0);

                // ENHANCEMENT: Move TooMuchData handling to client SDK (server caps limit gracefully).
                break :count @min(
                    filter.limit,
                    operation_comptime.result_max(constants.message_body_size_max),
                );
            },
            // ArcherDB admin operations (F1.2.6) - always return exactly 1 result
            .archerdb_ping, .archerdb_get_status => 1,
            // ArcherDB TTL cleanup (F2.4.8) - returns exactly 1 CleanupResponse
            .cleanup_expired => 1,
        };
    }

    pub fn from_vsr(operation: vsr.Operation) ?Operation {
        if (operation == .pulse) return .pulse;
        if (operation.vsr_reserved()) return null;

        return vsr.Operation.to(Operation, operation);
    }

    pub fn to_vsr(operation: Operation) vsr.Operation {
        return vsr.Operation.from(Operation, operation);
    }
};

comptime {
    const target = builtin.target;

    if (target.os.tag != .linux and !target.os.tag.isDarwin() and target.os.tag != .windows) {
        @compileError("linux, windows or macos is required for io");
    }

    // We require little-endian architectures everywhere for efficient network deserialization:
    if (target.cpu.arch.endian() != .little) {
        @compileError("big-endian systems not supported");
    }

    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {},
        .ReleaseFast, .ReleaseSmall => @compileError("safety checks are required for correctness"),
    }
}
