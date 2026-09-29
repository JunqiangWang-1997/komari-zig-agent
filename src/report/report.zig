const std = @import("std");
const common = @import("../platform/common.zig");

/// JSON serialization helpers for periodic runtime snapshots.
///
/// Both functions only *borrow* `snap`: they never free `snap.gpu_json`. The
/// snapshot carries GPU JSON owned by `std.heap.page_allocator`, so whoever
/// called `provider.snapshotWithOptions` must free it exactly once after the
/// last serializer call, no matter which serializer was used. Keeping the free
/// out of this module stops the ownership contract from being split between a
/// `defer` here and a caller-side flag.
pub fn writeReportJson(writer: anytype, snap: common.Snapshot) !void {
    var usage = snap.cpu.usage;
    if (usage <= 0.001) usage = 0.001;
    try writer.print(
        "{{\"cpu\":{{\"usage\":{d}}},\"ram\":{{\"total\":{d},\"used\":{d}}},\"swap\":{{\"total\":{d},\"used\":{d}}},\"load\":{{\"load1\":{d},\"load5\":{d},\"load15\":{d}}},\"disk\":{{\"total\":{d},\"used\":{d}}},\"network\":{{\"up\":{d},\"down\":{d},\"totalUp\":{d},\"totalDown\":{d}}},\"connections\":{{\"tcp\":{d},\"udp\":{d}}},\"uptime\":{d},\"process\":{d}",
        .{ usage, snap.ram.total, snap.ram.used, snap.swap.total, snap.swap.used, snap.load.load1, snap.load.load5, snap.load.load15, snap.disk.total, snap.disk.used, snap.network.up, snap.network.down, snap.network.totalUp, snap.network.totalDown, snap.connections.tcp, snap.connections.udp, snap.uptime, snap.process },
    );
    if (snap.gpu_json.len != 0) try writer.print(",\"gpu\":{s}", .{snap.gpu_json});
    try writer.writeAll(",\"message\":");
    try writer.print("{f}", .{std.json.fmt(snap.message, .{})});
    try writer.writeAll("}");
}

pub fn allocReportJson(allocator: std.mem.Allocator, snap: common.Snapshot) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeReportJson(&out.writer, snap);
    return out.toOwnedSlice();
}
