const std = @import("std");
const version = @import("version");

test "default version and repository are compatible" {
    try std.testing.expectEqualStrings("0.0.1", version.current);
    // 自更新来源必须是本 fork。指向原仓库会让已更新的 agent 被静默降级回
    // 宿主机视图的构建（上游不含 cgroup 容器感知指标）。
    try std.testing.expectEqualStrings("JunqiangWang-1997/komari-zig-agent", version.repo);
}
