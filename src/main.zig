// TODO:
// implement symbolization
// mmap2 records to handle PIE binaries and shared libs
// set a watermark of a few kb to wakeup fewer times
// pass the target a real env/args

const linux_error = @import("linux_error");
const std = @import("std");
const cmdline = @import("cmdline.zig");
const RecordParser = @import("RecordParser.zig");

const Io = std.Io;

const checkLinuxError = linux_error.check;
const checkLinuxFd = linux_error.checkFd;
const parseCmdline = cmdline.parseCmdline;

const N_DATA_PAGES = RecordParser.N_DATA_PAGES;

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

    // The fork waits for performance monitoring to be setup
    const target_pid = try forkAndWait(config.target_path);

    var epoll_fd: i32 = undefined;
    var perf_event_ring_addrs: [][*]align(std.heap.page_size_min) u8 = undefined;
    epoll_fd, perf_event_ring_addrs = try setupPerfMonitoring(arena, target_pid);

    var record_parser = try RecordParser.init(arena, perf_event_ring_addrs, target_pid);

    // resume the forked process to execve to the target binary
    try checkLinuxError(std.os.linux.kill(target_pid, std.os.linux.SIG.CONT));

    const n_cpus = try std.Thread.getCpuCount();
    var events = try arena.alloc(std.os.linux.epoll_event, n_cpus);

    // This one loop is intentionally unbounded because the profiler
    // is intended to be capable of streaming samples indefinitely,
    // or until the target exits for whatever reason
    while (true) {
        const max_wait_ms = 1000;
        const n_events = try waitForEvents(epoll_fd, events, max_wait_ms);

        // either a full epoll cycle passed with no output,
        // or the inner waitForEvents inner loop hit LOOP_UPPER_BOUND
        if (n_events == 0 and (try checkTargetGone(target_pid))) {
            break;
        }

        var hung_up = false;
        for (events[0..n_events]) |ev| {
            if (eventIsRecordable(ev.events)) {
                const cpu = ev.data.u32;
                const drained_records = try record_parser.drain(cpu);
                try record_parser.parseRecords(drained_records);
            }
            hung_up = hung_up or epollHungUp(ev.events);
        }

        if (hung_up or record_parser.saw_exit) {
            break;
        }
    }

    // flush any remaining records that may exist
    for (0..n_cpus) |cpu| {
        const drained_records = try record_parser.drain(cpu);
        try record_parser.parseRecords(drained_records);
    }

    std.debug.print("Total lost samples: {}\n", .{record_parser.lost_samples});
}

fn eventIsRecordable(events: u32) bool {
    return (events & std.os.linux.EPOLL.IN) != 0;
}

fn epollHungUp(events: u32) bool {
    return events & (std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.ERR) != 0;
}

fn checkTargetGone(target_pid: std.os.linux.pid_t) !bool {
    var iterations: u32 = 0;
    while (iterations < LOOP_UPPER_BOUND) : (iterations += 1) {
        var status: u32 = 0;
        const rc = std.os.linux.waitpid(target_pid, &status, std.os.linux.W.NOHANG);
        if (std.os.linux.errno(rc) == .INTR) continue;
        try checkLinuxError(rc);
        return (rc != 0);
    }
    std.debug.assert(iterations < LOOP_UPPER_BOUND);
    return true;
}

fn waitForEvents(
    epoll_fd: i32,
    events: []std.os.linux.epoll_event,
    max_wait_ms: usize,
) !usize {
    // Returns if either the inner loop executes LOOP_UPPER_BOUND times,
    // which is unexpected, and thus asserted against in debug builds.
    // In release, if this condition is hit for whatever reason, the
    // profiler won't get stuck in an infinite loop.
    var iterations: u32 = 0;
    while (iterations < LOOP_UPPER_BOUND) : (iterations += 1) {
        const n_events = std.os.linux.epoll_wait(
            epoll_fd,
            events.ptr,
            @intCast(events.len),
            @intCast(max_wait_ms),
        );
        if (std.os.linux.errno(n_events) == .INTR) continue;
        try checkLinuxError(n_events);
        return n_events;
    }
    std.debug.assert(iterations < LOOP_UPPER_BOUND);
    return 0;
}

// Setup performance montoring for the target per-cpu.
// A slice of addresses of the mapped epoll rings are returned,
// alongside the epoll instance fd required to wait for samples to read.
fn setupPerfMonitoring(
    arena: std.mem.Allocator,
    target_pid: std.os.linux.pid_t,
) !struct { i32, [][*]align(std.heap.page_size_min) u8 } {
    var perf_event_attr: std.os.linux.perf_event_attr = .{};
    perf_event_attr.type = .HARDWARE;
    perf_event_attr.config = @intFromEnum(std.os.linux.PERF.COUNT.HW.CPU_CYCLES);
    perf_event_attr.sample_period_or_freq = 999; // sample at 999hz
    perf_event_attr.wakeup_events_or_watermark = 1; // wakeup every n events
    perf_event_attr.flags = .{
        .disabled = true, // start disabled
        .enable_on_exec = true, // start when the fork calls execve
        .task = true, // trace fork()/exit()
        .inherit = true, // threads created after perf_event_open() are also traced
        .freq = true, // sample freq instead of period
        .sample_id_all = true, // TID, TIME, ID, STREAM_ID, and CPU can be included in non-PERF_RECORD_SAMPLES
        .precise_ip = 0, // sample_ip can have arbitrary skid
        .exclude_callchain_kernel = true, // dont include kernel symbols in the callchain
        .exclude_kernel = true, // dont trace kernel
        .exclude_hv = true, // dont trace hypervisor
    };
    // receive an unwound stack trace from the kernel as an array of instruction pointers
    // requires the target to have been compiled with stack frame pointers enabled
    perf_event_attr.sample_type = std.os.linux.PERF.SAMPLE.CALLCHAIN;

    // create the epoll instance required for us to wait till the kernel has readable samples
    const epoll_fd = try checkLinuxFd(std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC));

    // open performance montoring per-cpu
    const n_cpus = try std.Thread.getCpuCount();
    const perf_event_ring_addrs = try arena.alloc([*]align(std.heap.page_size_min) u8, n_cpus);
    for (0..n_cpus) |cpu| {
        const no_group_fd = -1;
        const perf_event_fd = try checkLinuxFd(std.os.linux.perf_event_open(
            &perf_event_attr,
            target_pid,
            @intCast(cpu),
            no_group_fd,
            std.os.linux.PERF.FLAG.FD_CLOEXEC,
        ));

        // add the perf event fd to the list that the created epoll instance watches
        var reg: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u32 = @intCast(cpu) },
        };
        try checkLinuxError(std.os.linux.epoll_ctl(
            epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            perf_event_fd,
            &reg,
        ));

        // map the kernel shared ring buffer for this cpu's perf events
        const mmap_size = (1 + N_DATA_PAGES) * std.heap.pageSize();
        const perf_event_ring_addr = std.os.linux.mmap(
            null,
            mmap_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            perf_event_fd,
            0,
        );
        try checkLinuxError(perf_event_ring_addr);
        perf_event_ring_addrs[cpu] = @ptrFromInt(perf_event_ring_addr);
    }

    return .{ epoll_fd, perf_event_ring_addrs };
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

            _ = std.os.linux.execve(target_path, &argv, &env);
            // execve only returns if an error occurred
            std.os.linux.exit_group(127);
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

        std.debug.assert(iterations < LOOP_UPPER_BOUND);

        if (!std.os.linux.W.IFSTOPPED(status)) {
            return error.ForkFailedToStop;
        }
    }

    return target_pid;
}
