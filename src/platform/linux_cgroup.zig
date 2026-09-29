//! cgroup v2 容器感知指标采集。
//!
//! 容器内 `/proc/meminfo` 与 `/proc/stat` 是**宿主机视图**：一个 32MB 的
//! podman 小容器会读到宿主机的 1.89GB 内存和全局 CPU 累计计数，导致面板上
//! 「32MB 的小鸡」显示成宿主机规格。要反映容器真实配额，必须改读 cgroup v2
//! 的配额与累计用量文件。
//!
//! 覆盖范围：
//! * **CPU**：读 `cpu.max`（配额）与 `cpu.stat`（累计 `usage_usec`），按差值
//!   算百分比。`usage_usec` 没有 idle 概念，故必须自行取 wall clock 时间差，
//!   这是与 `/proc/stat` 路径（用 jiffy 差值算比例、不需要时钟）的关键差异。
//! * **内存**：读 `memory.max`（上限）、`memory.current`（当前用量），并用
//!   `memory.stat` 的 `file` / `shmem` 复刻 `parseMemInfo` 的 htop 口径。
//!
//! **不覆盖磁盘**：cgroup 无法给普通文件系统设容量上限。podman 的 overlay
//! 根目录建在宿主机文件系统上，`statfs` 必然返回宿主机磁盘容量，这是容器
//! 机制本身的限制而非采集缺陷；要在面板上体现容器磁盘配额，只能改用
//! loopback 镜像文件或 ZFS/btrfs 子卷 quota。
//!
//! ## 启用条件
//!
//! 本模块**不在裸机上启用**。裸机 Linux 同样能读到 `/sys/fs/cgroup/cpu.stat`
//! 且数值与 `/proc/stat` 大致等价，若无条件启用会改变所有非容器用户的上报
//! 数值。因此以「`memory.max` 为有限值」作为自门控信号：受限 cgroup 才有
//! 有限上限，裸机与无限额 cgroup 的 `memory.max` 是 `max`。这样做无需 fork
//! `systemd-detect-virt`，也不依赖容器标识猜测——podman 默认
//! `--cgroupns=private` 时 `/proc/self/cgroup` 为 `0::/`，靠 `/podman-`
//! 匹配的那套检测会失效。
//!
//! 任何读取失败都返回 null，由调用方回退到 `/proc` 原有逻辑，因此裸机、
//! cgroup v1、WSL 等环境行为完全不变。

const std = @import("std");
const compat = @import("compat");
const common = @import("common.zig");

/// cgroup v2 统一挂载点。
pub const cgroup_root = "/sys/fs/cgroup";

/// `cpu.max` 解析结果。`max_cores` 为 0 表示无 CPU 配额。
pub const CpuQuota = struct {
    max_cores: f64 = 0,
    period_us: u64 = 0,
};

/// 容器内存采样。`total` 为 0 表示无限制或不可用，调用方应回退 `/proc/meminfo`。
pub const MemSample = struct {
    total: u64 = 0,
    current: u64 = 0,
    file: u64 = 0,
    shmem: u64 = 0,
};

/// 供测试重置 CPU 差值基线。
pub fn resetForTest() void {
    cpu_mutex.lock();
    defer cpu_mutex.unlock();
    previous_cpu = null;
}

// ---------------------------------------------------------------------------
// 纯解析函数：不触碰文件系统，可独立单测
// ---------------------------------------------------------------------------

/// 解析 `cpu.max`，内容形如 `max 100000`（无配额）或 `200000 100000`。
pub fn parseCpuMax(bytes: []const u8) CpuQuota {
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    const quota = fields.next() orelse return .{};
    const period_text = fields.next() orelse return .{};
    const period = std.fmt.parseInt(u64, period_text, 10) catch return .{};
    if (period == 0) return .{};
    if (std.mem.eql(u8, quota, "max")) return .{ .period_us = period };
    const quota_us = std.fmt.parseInt(u64, quota, 10) catch return .{ .period_us = period };
    return .{
        .max_cores = @as(f64, @floatFromInt(quota_us)) / @as(f64, @floatFromInt(period)),
        .period_us = period,
    };
}

/// 从 `cpu.stat` 提取 `usage_usec`（容器内所有任务累计占用的 CPU 微秒数）。
pub fn parseCpuStatUsage(bytes: []const u8) ?u64 {
    return parseStatValue(bytes, "usage_usec");
}

/// 从 `memory.stat` 提取 page cache 与共享内存两项。
pub fn parseMemoryStat(bytes: []const u8) MemSample {
    return .{
        .file = parseStatValue(bytes, "file") orelse 0,
        .shmem = parseStatValue(bytes, "shmem") orelse 0,
    };
}

/// 从 `<key> <value>` 逐行的 cgroup 统计文件中提取指定键的数值。
///
/// 刻意容忍未知行与额外列：cgroup v2 的 `cpu.stat` / `memory.stat` 字段会随
/// 内核版本增补（如 `nr_bursts`、`zswap`），解析器不应因此失败。
pub fn parseStatValue(bytes: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, key)) continue;
        const value = fields.next() orelse continue;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

/// 解析 `memory.max` / `swap.max`：数字表示字节上限，`max` 或非法值返回 0。
pub fn parseByteLimit(bytes: []const u8) u64 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return 0;
    if (std.mem.eql(u8, trimmed, "max")) return 0;
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

/// 归一化所用的有效核数。
///
/// 有配额时以配额为准（100% 表示「用满了自己那份额度」），但不超过整机核数；
/// 无配额时退化为整机核数，使容器与宿主机上报口径一致（100% 表示「吃满整机」）。
pub fn effectiveCores(quota_cores: f64, host_cores: u64) f64 {
    const host: f64 = @floatFromInt(if (host_cores == 0) 1 else host_cores);
    if (quota_cores <= 0) return host;
    return @min(quota_cores, host);
}

/// 按 htop 口径计算已用内存。
///
/// 刻意复刻 `linux.zig` 中 `parseMemInfo` 的公式形状
/// （`total - (free + cached + sreclaimable + buffers) + shmem`）：
/// 扣除 page cache 后把 shmem 加回。cgroup v2 的 `memory.stat.file` 已包含
/// shmem，而 `/proc/meminfo` 的 `Cached` 不含 `Shmem`，两处因此同构。
pub fn memUsed(sample: MemSample, include_cache: bool) u64 {
    if (include_cache) return sample.current;
    const base = if (sample.current >= sample.file) sample.current - sample.file else 0;
    return base + sample.shmem;
}

// ---------------------------------------------------------------------------
// 文件读取
// ---------------------------------------------------------------------------

fn readCgroupFile(name: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cgroup_root, name }) catch return null;
    const file = compat.openFile(path, .{}) catch return null;
    defer file.close(std.Options.debug_io);
    const n = compat.readAll(file, buf) catch return null;
    return buf[0..n];
}

/// 当前是否处于**有限额**的 cgroup。裸机与无限额 cgroup 均为 `max`，返回 false。
pub fn cgroupIsLimited() bool {
    var buf: [64]u8 = undefined;
    const bytes = readCgroupFile("memory.max", &buf) orelse return false;
    return parseByteLimit(bytes) != 0;
}

/// 读取容器内存采样。`total` 为 0 表示无限制或不可用。
pub fn readMemSample() MemSample {
    var cur_buf: [64]u8 = undefined;
    const current = blk: {
        const bytes = readCgroupFile("memory.current", &cur_buf) orelse break :blk @as(u64, 0);
        break :blk parseByteLimit(bytes);
    };
    if (current == 0) return .{};

    var total: u64 = 0;
    var max_buf: [64]u8 = undefined;
    if (readCgroupFile("memory.max", &max_buf)) |bytes| total = parseByteLimit(bytes);

    var stat = MemSample{};
    var stat_buf: [4096]u8 = undefined;
    if (readCgroupFile("memory.stat", &stat_buf)) |bytes| stat = parseMemoryStat(bytes);

    return .{ .total = total, .current = current, .file = stat.file, .shmem = stat.shmem };
}

/// 读取容器 swap 采样。`swap.max` 为 `max`（无限制）时 total 为 0，
/// 返回值即全 0 的 `common.MemInfo`。
pub fn readSwapSample() common.MemInfo {
    var max_buf: [64]u8 = undefined;
    const total = blk: {
        const bytes = readCgroupFile("swap.max", &max_buf) orelse break :blk @as(u64, 0);
        break :blk parseByteLimit(bytes);
    };
    if (total == 0) return .{};

    var cur_buf: [64]u8 = undefined;
    var current: u64 = 0;
    if (readCgroupFile("swap.current", &cur_buf)) |bytes| current = parseByteLimit(bytes);
    return .{ .total = total, .used = @min(current, total) };
}

// ---------------------------------------------------------------------------
// CPU 差值采样
// ---------------------------------------------------------------------------

const CpuDelta = struct {
    usage_usec: u64,
    timestamp_ms: i64,
};

var cpu_mutex: compat.Mutex = .{};
var previous_cpu: ?CpuDelta = null;

/// 返回容器 CPU 使用率（0-100），不可用时返回 null 由调用方回退到 `/proc/stat`。
///
/// 首次调用只建立基线并返回 null，因此切换到本路径的第一帧会回退到
/// `/proc/stat`，下一帧起即为容器视角。
pub fn cpuUsagePercent(host_cores: u64) ?f64 {
    var stat_buf: [1024]u8 = undefined;
    const usage = blk: {
        const bytes = readCgroupFile("cpu.stat", &stat_buf) orelse return null;
        break :blk parseCpuStatUsage(bytes) orelse return null;
    };

    var quota = CpuQuota{};
    var max_buf: [64]u8 = undefined;
    if (readCgroupFile("cpu.max", &max_buf)) |bytes| quota = parseCpuMax(bytes);

    const now_ms = compat.milliTimestamp();
    cpu_mutex.lock();
    defer cpu_mutex.unlock();

    const previous = previous_cpu;
    previous_cpu = .{ .usage_usec = usage, .timestamp_ms = now_ms };

    const prev = previous orelse return null;
    if (now_ms <= prev.timestamp_ms) return null;
    if (usage <= prev.usage_usec) return null;

    const elapsed_us: u64 = @intCast((now_ms - prev.timestamp_ms) * 1000);
    if (elapsed_us == 0) return null;

    const used = @as(f64, @floatFromInt(usage - prev.usage_usec));
    const elapsed = @as(f64, @floatFromInt(elapsed_us));
    const percent = (used / elapsed / effectiveCores(quota.max_cores, host_cores)) * 100.0;
    return if (percent < 0.001) 0.001 else percent;
}

/// 受限 cgroup 的内存。返回 null 表示未启用或不可读，调用方应回退 `/proc`。
pub fn readLimitedRam(include_cache: bool) ?common.MemInfo {
    if (!cgroupIsLimited()) return null;
    const sample = readMemSample();
    if (sample.current == 0) return null;
    return .{ .total = sample.total, .used = memUsed(sample, include_cache) };
}

/// 受限 cgroup 的 swap。返回 null 表示**不在**受限 cgroup 中，调用方应回退 `/proc`。
///
/// `swap.max` 默认为 `max`（无限额），此时返回全 0：容器没有属于自己的 swap
/// 预算，给 32MiB 内存的容器报出宿主机数 GB swap 是自相矛盾的数据。宿主机的
/// swap 对容器不可计量，故此处不取。
pub fn readLimitedSwap() ?common.MemInfo {
    if (!cgroupIsLimited()) return null;
    return readSwapSample();
}
