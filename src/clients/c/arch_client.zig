// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");

pub const vsr = @import("../../vsr.zig");
pub const exports = @import("arch_client_exports.zig");

const MessageBus = @import("../../message_bus.zig").MessageBusType(@import("../../io.zig").IO);

pub const InitError = @import("arch_client/context.zig").InitError;
pub const InitParameters = @import("arch_client/context.zig").InitParameters;
pub const ClientInterface = @import("arch_client/context.zig").ClientInterface;
pub const CompletionCallback = @import("arch_client/context.zig").CompletionCallback;
pub const Packet = @import("arch_client/packet.zig").Packet.Extern;
pub const PacketStatus = @import("arch_client/packet.zig").Packet.Status;
pub const Operation = vsr.archerdb.Operation;

const ContextType = @import("arch_client/context.zig").ContextType;
const DefaultContext = blk: {
    const ClientType = @import("../../vsr/client.zig").ClientType;
    const Client = ClientType(Operation, MessageBus);
    break :blk ContextType(Client);
};

const TestingContext = blk: {
    const EchoClientType = @import("arch_client/echo_client.zig").EchoClientType;
    const EchoClient = EchoClientType(MessageBus);
    break :blk ContextType(EchoClient);
};

pub const init = DefaultContext.init;
pub const init_echo = TestingContext.init;

test {
    std.testing.refAllDecls(DefaultContext);
}
