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
        self.ring_headers[i] = @ptrCast(@alignCast(perf_event_ring_addrs[i]));
        self.ring_buffers[i] = @ptrCast(@alignCast(perf_event_ring_addrs[i] + std.heap.pageSize()));
    }
    return self;
}

pub fn drain(self: RecordParser, cpu: u64) ![]const u8 {
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
        self.ring_buffers[cpu][offset..][0..first_chunk_bytes],
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

//pub fn parseRecords(self: *RecordParser, records_bytes: []const u8) !void {}
