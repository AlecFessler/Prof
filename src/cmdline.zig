const std = @import("std");

pub const Config = struct {
    target_path: [:0]const u8,
};

pub fn parseCmdline(args: []const [:0]const u8) !Config {
    var target_path: [:0]const u8 = undefined;
    for (args, 0..) |arg, arg_count| {
        // the first arg parsed is the name of the current running executable
        if (arg_count == 0) continue;

        // the second arg is expected to be path of the target binary
        if (arg_count == 1) target_path = arg;
    }

    if (args.len <= 1) {
        return error.MissingTarget;
    }

    return .{
        .target_path = target_path,
    };
}
