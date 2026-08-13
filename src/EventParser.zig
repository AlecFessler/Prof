const std = @import("std");

// -- perf_event_open(2) man pages --
// "The mmap size should be 1+2^n pages, where the first page is a
// metadata page (struct perf_event_mmap_page) that contains various
// bits of information such as where the ring-buffer head is."
pub const N_DATA_PAGES = 1 << 7; // 128

const EventParser = @This();

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
) !EventParser {
    const ring_n_bytes = N_DATA_PAGES * std.heap.pageSize();
    const self: EventParser = .{
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
