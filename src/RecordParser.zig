const std = @import("std");

// -- perf_event_open(2) man pages --
// "The mmap size should be 1+2^n pages, where the first page is a
// metadata page (struct perf_event_mmap_page) that contains various
// bits of information such as where the ring-buffer head is."
pub const N_DATA_PAGES = 1 << 7; // 128

const RecordParser = @This();

ring_headers: []*std.os.linux.perf_event_mmap_page,
ring_buffers: [][*]u8,
ring_n_bytes: u64,
target_pid: std.os.linux.pid_t,
scratch: []u8,
lost_samples: u64 = 0,
saw_exit: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    perf_event_ring_addrs: [][*]align(std.heap.page_size_min) u8,
    target_pid: std.os.linux.pid_t,
) !RecordParser {
    const ring_n_bytes = N_DATA_PAGES * std.heap.pageSize();
    const self: RecordParser = .{
        .ring_headers = try allocator.alloc(*std.os.linux.perf_event_mmap_page, perf_event_ring_addrs.len),
        .ring_buffers = try allocator.alloc([*]u8, perf_event_ring_addrs.len),
        .ring_n_bytes = ring_n_bytes,
        .target_pid = target_pid,
        .scratch = try allocator.alloc(u8, ring_n_bytes),
    };
    for (0..perf_event_ring_addrs.len) |i| {
        self.ring_headers[i] = @ptrCast(perf_event_ring_addrs[i]);
        self.ring_buffers[i] = @ptrCast(perf_event_ring_addrs[i] + std.heap.pageSize());
    }
    return self;
}

pub fn drain(self: *RecordParser, cpu: u64) ![]const u8 {
    // the kernel writes ring_head concurrently, so an atomic acquire is necessary
    const ring_head = @atomicLoad(u64, &self.ring_headers[cpu].data_head, .acquire);
    // only we write ring_tail, so a standard load is sufficient
    const ring_tail = self.ring_headers[cpu].data_tail;
    const available_bytes = ring_head - ring_tail;
    std.debug.assert(available_bytes <= self.ring_n_bytes);

    const offset = ring_tail & (self.ring_n_bytes - 1);
    const bytes_before_wraparound = self.ring_n_bytes - offset;
    const first_chunk_bytes = @min(available_bytes, bytes_before_wraparound);
    @memcpy(
        self.scratch[0..first_chunk_bytes],
        self.ring_buffers[cpu][offset .. offset + first_chunk_bytes],
    );
    if (available_bytes > first_chunk_bytes) {
        @memcpy(
            self.scratch[first_chunk_bytes..available_bytes],
            self.ring_buffers[cpu][0 .. available_bytes - first_chunk_bytes],
        );
    }

    // atomic release is necessary to ensure the copy from the ring buffer to
    // the scratch buffer is not reordered after the following ring_tail bump
    @atomicStore(u64, &self.ring_headers[cpu].data_tail, ring_head, .release);

    return self.scratch[0..available_bytes];
}

// The kernel splices PERF_CONTEXT_* markers into the callchain to delimit
// its user/kernel/hypervisor portions. They are all negative when read as
// an i64, so any entry at or above PERF_CONTEXT_MAX is a marker, not an ip.
const PERF_CONTEXT_MAX: u64 = @bitCast(@as(i64, -4095));

const RecordLost = extern struct {
    id: u64,
    lost: u64,
};

const RecordThrottle = extern struct {
    time: u64,
    id: u64,
    stream_id: u64,
};

const RecordExit = extern struct {
    pid: u32,
    ppid: u32,
    tid: u32,
    ptid: u32,
    time: u64,
};

pub fn parseRecords(self: *RecordParser, records_bytes: []const u8) !void {
    const header_size = @sizeOf(std.os.linux.perf_event_header);
    var offset: usize = 0;
    while (offset + header_size <= records_bytes.len) {
        const header: *align(1) const std.os.linux.perf_event_header = @ptrCast(&records_bytes[offset]);
        std.debug.assert(header.size != 0);
        std.debug.assert(offset + header.size <= records_bytes.len);

        const body = records_bytes[offset + header_size .. offset + header.size];
        switch (header.type) {
            .SAMPLE => {
                // sample_type is CALLCHAIN only, so the body is a u64 frame
                // count followed by that many instruction pointers, leaf first
                std.debug.assert(body.len >= @sizeOf(u64));
                const n_frames: u64 = @bitCast(body[0..@sizeOf(u64)].*);
                const ips_end = @sizeOf(u64) + n_frames * @sizeOf(u64);
                std.debug.assert(body.len >= ips_end);

                const ips = std.mem.bytesAsSlice(u64, body[@sizeOf(u64)..ips_end]);
                std.debug.print("sample: {} frames\n", .{n_frames});
                for (ips) |ip| {
                    if (ip >= PERF_CONTEXT_MAX) continue;
                    std.debug.print("  0x{x}\n", .{ip});
                }
            },
            .LOST => {
                if (body.len < @sizeOf(RecordLost)) break;
                const record: *align(1) const RecordLost = @ptrCast(body.ptr);
                self.lost_samples += record.lost;
            },
            .THROTTLE, .UNTHROTTLE => {
                std.debug.print("Throttle/unthrottle event\n", .{});
            },
            .EXIT => {
                if (body.len < @sizeOf(RecordExit)) break;
                const record: *align(1) const RecordExit = @ptrCast(body.ptr);
                if (record.pid == record.tid and record.pid == self.target_pid) {
                    self.saw_exit = true;
                }
                std.debug.print("Parser saw exit event\n", .{});
            },
            .FORK => {
                std.debug.print("Fork event\n", .{});
            },
            else => {},
        }
        offset += header.size;
    }
}
