const std = @import("std");
const cgroup = @import("platform_linux_cgroup");

// 以下 cpu.stat / memory.stat 样本取自真实 podman 容器（32MiB 限额、2 核
// 宿主、cpu.max 无配额），用于锁定解析口径，防止内核字段增补导致回归。

test "parseCpuMax reads unlimited quota as zero cores" {
    // 容器实测值：max 100000
    const quota = cgroup.parseCpuMax("max 100000\n");
    try std.testing.expectEqual(@as(f64, 0), quota.max_cores);
    try std.testing.expectEqual(@as(u64, 100000), quota.period_us);
}

test "parseCpuMax converts finite quota into cores" {
    // 50000/100000 = 0.5 核
    const quota = cgroup.parseCpuMax("50000 100000");
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), quota.max_cores, 1e-9);
    try std.testing.expectEqual(@as(u64, 100000), quota.period_us);
}

test "parseCpuMax rejects malformed input" {
    try std.testing.expectEqual(@as(f64, 0), cgroup.parseCpuMax("").max_cores);
    try std.testing.expectEqual(@as(f64, 0), cgroup.parseCpuMax("max").max_cores);
    // 周期为 0 会导致除零，必须拒绝
    try std.testing.expectEqual(@as(f64, 0), cgroup.parseCpuMax("50000 0").max_cores);
    try std.testing.expectEqual(@as(f64, 0), cgroup.parseCpuMax("abc def").max_cores);
}

test "parseCpuStatUsage reads usage_usec from real container sample" {
    const bytes =
        "usage_usec 140580959\n" ++
        "user_usec 38083151\n" ++
        "system_usec 102497807\n" ++
        "nice_usec 0\n" ++
        "nr_periods 0\n" ++
        "nr_throttled 0\n";
    try std.testing.expectEqual(@as(u64, 140580959), cgroup.parseCpuStatUsage(bytes).?);
}

test "parseCpuStatUsage returns null when key missing or file empty" {
    try std.testing.expect(cgroup.parseCpuStatUsage("") == null);
    try std.testing.expect(cgroup.parseCpuStatUsage("user_usec 1\n") == null);
    try std.testing.expect(cgroup.parseCpuStatUsage("usage_usec notanumber\n") == null);
}

test "parseMemoryStat reads file and shmem from real container sample" {
    const bytes =
        "anon 9048064\n" ++
        "file 5849088\n" ++
        "kernel 1679360\n" ++
        "shmem 0\n";
    const sample = cgroup.parseMemoryStat(bytes);
    try std.testing.expectEqual(@as(u64, 5849088), sample.file);
    try std.testing.expectEqual(@as(u64, 0), sample.shmem);
}

test "parseMemoryStat defaults missing keys to zero" {
    const sample = cgroup.parseMemoryStat("anon 100\n");
    try std.testing.expectEqual(@as(u64, 0), sample.file);
    try std.testing.expectEqual(@as(u64, 0), sample.shmem);
}

test "parseByteLimit reads finite limit and treats max as unlimited" {
    // 容器实测 memory.max = 32MiB
    try std.testing.expectEqual(@as(u64, 33554432), cgroup.parseByteLimit("33554432\n"));
    try std.testing.expectEqual(@as(u64, 0), cgroup.parseByteLimit("max"));
    try std.testing.expectEqual(@as(u64, 0), cgroup.parseByteLimit("  max  \n"));
    try std.testing.expectEqual(@as(u64, 0), cgroup.parseByteLimit(""));
    try std.testing.expectEqual(@as(u64, 0), cgroup.parseByteLimit("garbage"));
}

// 实测数值：memory.current=17739776 file=5849088 shmem=0
// 期望 htop 口径已用 = current - file + shmem = 11890688
test "memUsed excludes page cache by default mirroring htop formula" {
    const sample = cgroup.MemSample{ .total = 33554432, .current = 17739776, .file = 5849088, .shmem = 0 };
    try std.testing.expectEqual(@as(u64, 11890688), cgroup.memUsed(sample, false));
}

test "memUsed includes page cache when requested" {
    const sample = cgroup.MemSample{ .total = 33554432, .current = 17739776, .file = 5849088 };
    try std.testing.expectEqual(@as(u64, 17739776), cgroup.memUsed(sample, true));
}

test "memUsed never underflows when file exceeds current" {
    const sample = cgroup.MemSample{ .total = 100, .current = 10, .file = 999 };
    try std.testing.expectEqual(@as(u64, 0), cgroup.memUsed(sample, false));
}

test "effectiveCores uses whole machine when no quota is set" {
    try std.testing.expectApproxEqAbs(@as(f64, 2), cgroup.effectiveCores(0, 2), 1e-9);
    // host_cores 为 0 时必须退化为 1，避免除零
    try std.testing.expectApproxEqAbs(@as(f64, 1), cgroup.effectiveCores(0, 0), 1e-9);
}

test "effectiveCores honours quota but never exceeds host" {
    // 配额 0.5 核，宿主 2 核 -> 取配额
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), cgroup.effectiveCores(0.5, 2), 1e-9);
    // 配额 8 核但宿主只有 2 核 -> 取宿主
    try std.testing.expectApproxEqAbs(@as(f64, 2), cgroup.effectiveCores(8, 2), 1e-9);
}

// 裸机 / cgroup v1 / 无 memory.max 环境的回退契约。
// 这是防止非容器用户上报数值被改写的关键断言：本模块只有在 memory.max
// 为有限值时才接管，否则必须原样把控制权交回 /proc。
test "cgroup paths stay inert when memory.max is absent" {
    cgroup.resetForTest();
    if (cgroup.cgroupIsLimited()) return; // 受限环境跳过，交给真实路径验证

    try std.testing.expect(cgroup.readLimitedRam(false) == null);
    try std.testing.expect(cgroup.readLimitedRam(true) == null);
    try std.testing.expect(cgroup.readLimitedSwap() == null);
}

test "cpuUsagePercent first call only establishes baseline" {
    cgroup.resetForTest();
    // 无论本机是否存在 cpu.stat，首次调用都只能返回 null（建立基线），
    // 这样切换到 cgroup 路径的第一帧会回退到 /proc/stat 而非给出错误数值。
    try std.testing.expect(cgroup.cpuUsagePercent(2) == null);
    // 第二次读取不得 panic；存在 cgroup 时应得到有效百分比。
    if (cgroup.cpuUsagePercent(2)) |percent| {
        try std.testing.expect(percent >= 0.001);
        try std.testing.expect(percent <= 100.0);
    }
}
