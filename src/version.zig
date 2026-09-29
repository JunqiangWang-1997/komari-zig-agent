/// Build-time version metadata exported by the agent.
pub const current = @import("build_options").version;
/// Upstream repo consulted for self-update.
///
/// Points at this fork rather than the original author's repository: the
/// binaries published here carry cgroup container-aware metrics that upstream
/// does not have, so checking upstream would let it silently downgrade an
/// already-updated agent back to the host-view build.
pub const repo = "JunqiangWang-1997/komari-zig-agent";
