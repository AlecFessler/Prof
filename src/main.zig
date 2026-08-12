const linux_error = @import("linux_error");
const prof = @import("prof");
const std = @import("std");

const Io = std.Io;

const checkLinuxError = linux_error.check;
const checkLinuxFd = linux_error.checkFd;

const parseCmdline = prof.cmdline.parseCmdline;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    const stdout_buffer = try arena.alloc(u8, 4096);
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const cmdline_args = try init.minimal.args.toSlice(arena);
    const config = parseCmdline(cmdline_args) catch |e| switch (e) {
        error.MissingTarget => {
            try stdout.print("Missing target executable\n", .{});
            return;
        },
    };

    try stdout.print("Target: {s}\n", .{config.target});
}
