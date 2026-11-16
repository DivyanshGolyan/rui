const std = @import("std");
const ScratchBudget = @import("ScratchBudget.zig");
const command_input = @import("command_input.zig");

pub const File = std.Io.File;
pub const Budget = ScratchBudget;
pub const Io = std.Io;

pub fn release(file: ?File, budget: ?Budget, charged: u64, io: Io) void {
    if (file) |held| held.close(io);
    if (budget) |held| held.release(charged);
}

pub const commands = command_input.Commands(@This());
pub const ContentField = commands.ContentField;
pub const Configuration = commands.Configuration;
pub const ConfigureCommand = commands.ConfigureCommand;
pub const MessageCommand = commands.MessageCommand;

pub const Range = struct {
    file: File,
    offset: u64,
    length: u64,
    digest: [32]u8,
    sealed_length: u64,
};
