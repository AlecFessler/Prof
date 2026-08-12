const linux_error = @import("linux_error");
const prof = @import("prof");
const std = @import("std");

const Io = std.Io;

const checkLinuxError = linux_error.check;
const checkLinuxFd = linux_error.checkFd;

const parseCmdline = prof.cmdline.parseCmdline;

const LOOP_UPPER_BOUND = 50000;

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

    const target_pid = try forkAndWait(config.target_path);

    try stdout.print("Target pid: {}\n", .{target_pid});
}

/// Fork the profiler process and on success, the forked process
/// SIGSTOPs itself. The caller waits until the fork stops, and then
/// the fork's pid is returned. When the profiler SIGCONTs the fork,
/// it will execve the target path. This provides the profiler with a
/// window to set up monitoring before the target begins execution.
fn forkAndWait(target_path: [:0]const u8) !std.os.linux.pid_t {
    var target_pid: std.os.linux.pid_t = undefined;
    {
        const rc = std.os.linux.fork();
        try checkLinuxError(rc);
        target_pid = @intCast(rc);

        if (rc == 0) {
            // the kernel returns 0 on fork() to the spawned process,
            // thus it enters this branch, but it must retreive it's own pid

            const pid = std.os.linux.getpid();
            try checkLinuxError(std.os.linux.kill(pid, std.os.linux.SIG.STOP));

            const argv = [_:null]?[*:0]const u8{target_path.ptr};
            const env = [_:null]?[*:0]const u8{};

            // execve only returns if there was an error
            try checkLinuxError(std.os.linux.execve(target_path, &argv, &env));
        }
    }

    // fork() succeeded, wait for the forked process to SIGSTOP
    {
        var status: u32 = 0;
        var iterations: u32 = 0;
        while (iterations < LOOP_UPPER_BOUND) : (iterations += 1) {
            const rc = std.os.linux.waitpid(
                target_pid,
                &status,
                std.os.linux.W.UNTRACED,
            );
            if (std.os.linux.errno(rc) == .INTR) continue;
            try checkLinuxError(rc);
            break;
        }
        if (!std.os.linux.W.IFSTOPPED(status)) {
            return error.ForkFailedToStop;
        }
    }

    return target_pid;
}
