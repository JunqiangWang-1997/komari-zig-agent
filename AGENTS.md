# AGENTS.md - Komari Zig Agent 开发与评审指南

本文档是面向 AI Assistant、子 Agent（含 Code Review、Research）以及人类开发者的统一指引与规则约束。在阅读源码或提交变更前，必须完整阅读并遵守本文档。

---

## 1. 项目定位与核心指标

- **目标**：基于 **Zig 0.16.0** 原生实现 `komari-agent`，100% 协议与行为兼容地直接替代官方 Go 版 Agent（[komari-monitor/komari-agent](https://github.com/komari-monitor/komari-agent)），对接 [komari-monitor/komari](https://github.com/komari-monitor/komari) 监控服务端（兼容 Go 1.2.60 及 Komari v2 JSON-RPC 规范）。
- **指标优势**：
  - 体积：~700KB（相较 Go 版 8.5MB 缩小 ~12 倍）。
  - 内存：常驻 RSS ~1.2MB（降低 93%），systemd 记账低于 1MB。
  - CPU：空闲与采样常态 ~0.1%。
- **构建矩阵**：发布 20 个目标二进制，涵盖 Linux 11 种架构（`amd64`, `arm64`, `386`, `arm`, `mips`, `mipsel`, `mips64`, `mips64el`, `riscv64`, `s390x`, `loong64`）以及 FreeBSD、macOS 与 Windows。

---

## 2. 架构索引与模块导航

| 模块路径 | 职责说明 |
| :--- | :--- |
| `src/main.zig` | 程序主入口、CLI/配置加载、前后台 BasicInfo 调度、自更新触发、WebSocket 守护循环、信号捕获与优雅退出。 |
| `src/basic_info_flow.zig` | 前台 BasicInfo 上报编排与重试决策（与 `main.zig` 协作处理启动/重连阶段的上报与降级策略）。 |
| `src/config.zig` | CLI 标志、环境变量（`AGENT_*`）、JSON 配置文件解析（保持与 Go 相同的高宽容度解析）。 |
| `src/dns.zig` | 自定义 DNS 解析器与公共 fallback 服务器探测、IPv4/IPv6 地址族排序。 |
| `src/idna.zig` | IDN 国际化域名与 URL 转 Punycode ASCII，确保网络拨号与证书主机名规范化。 |
| `src/net.zig` | 跨平台 Socket 抽象、套接字超时（SO_RCVTIMEO/SO_SNDTIMEO）控制及超时冒烟诊断。 |
| `src/thread_stacks.zig` | 独立 Worker 线程（TLS、Terminal、Update）栈空间尺寸常量定义（防止栈溢出）。 |
| `src/protocol/` | **通信与协议交互层**：<br>• `http.zig` / `raw_conn.zig`: 原生 HTTP/1.1、TLS 握手、系统 CA 动态探测、CF Access 鉴权。<br>• `ws_client.zig` / `report_ws.zig`: WebSocket 客户端、加锁并发安全发送、心跳保活、指令分发。<br>• `basic_info.zig`: 基础信息采集上报与去 `kernel_version` 的降级回退机制。<br>• `v2.zig` / `v2_state.zig`: Komari v2 JSON-RPC 2.0 协议规范支持与事件拉取。<br>• `task.zig` / `ping.zig`: 远程 Shell 执行与 ICMP/TCP/HTTP Ping 探测。<br>• `autodiscovery.zig` / `ip.zig`: 自动发现注册与公网 IP 嗅探。 |
| `src/platform/` | **跨平台指标采集**：<br>• `provider.zig`: 平台抽象与调度入口。<br>• `linux.zig`: Linux 原生采集（直接读取 `/proc`、系统调用，零 sleep 采样），唯一使用 `statfs` 的平台。<br>• `freebsd.zig` / `darwin.zig`: **仍为 fork 外部命令实现**（`sysctl`/`uname`/`netstat`/`df`/`vm_stat`/`ifconfig`/`mount -p`），尚未原生化，**不存在 `getifaddrs`/`statfs` 调用**；详见 `docs/status/2026-09-current-state-audit.md` §3.2。<br>• `windows.zig`: Win32 API 硬件与系统指标采集（CPU、内存、磁盘、网卡等），物理核心数与详细 GPU 走 PowerShell CIM 子进程。<br>• `gpu.zig`: NVIDIA GPU 指标，**仅解析 `nvidia-smi` 输出的 CSV，无 NVML 绑定**；子进程调用点在 `linux.zig` / `windows.zig`。 |
| `src/report/` | **报表与持久化**：<br>• `report.zig`: 周期报表数据聚合与 JSON 序列化。<br>• `netstatic.zig`: 月度流量统计持久化（`net_static.json`），包含流量结转、重置日计算与损坏容错。 |
| `src/terminal/` | Web SSH / 终端会话管理：Linux/macOS 基于 zigpty，FreeBSD 基于 openpty，Windows 使用 PowerShell + stdin/stdout pipe fallback（未启用 ConPTY，勿宣称已完成）。 |
| `src/update.zig` | 自更新逻辑（GitHub Release 检查、SHA256SUMS 校验、流式落盘、无损替换、退出码 42）。 |
| `src/compat/` | Zig 标准库跨版本兼容抽象层（文件、进程、网络、时间、POSIX 封装）。 |
| `build.zig` | 跨平台构建、构建选项（version、crash_trace、coverage）、单元测试组织。**注意：20 目标矩阵不在此文件**，实际维护在 `build_all.sh` / `build_all.ps1` 与 `.github/workflows/{build,release}.yml`。 |

---

## 3. 核心红线与不可破坏原则（开发底线 & 评审一票否决）

**凡触发以下任一条，开发者必须自纠，Code Review Agent 必须直接 Request Changes**：

1. **严禁篡改协议 JSON 字段**：严禁私自新增、删除、改名对外通信字段（涵盖 BasicInfo、Report WebSocket、Task、Ping、v2 RPC 等）。必须严格对齐服务端已有字段定义。
2. **严禁破坏 20 目标构建矩阵**：Linux 11 架构矩阵（含 loong64、s390x、mips 等）以及 FreeBSD、macOS、Windows 交叉编译不可损坏。平台特定调用必须做好条件编译隔离。
3. **主循环严禁因常规网络错误崩溃**：严禁在 `main.zig` 或 `report_ws.zig` 的常规上报与心跳链路上使用致命 `try`。网络瞬断绝不能导致进程退出（Issue #9 教训：防止 OpenWrt `procd` / systemd 陷入 Crash Loop）。
4. **指标采样热路径绝对零阻塞**：严禁在 CPU、网络等指标采集函数中调用 `std.time.sleep()`！必须通过系统计数器做 Delta 差值计算。
5. **安全校验与更新完整性**：自更新与安装脚本必须完整校验 `SHA256SUMS`；必须先落盘校验再原子替换二进制；必须支持国内 GitHub 代理池回退与失败回滚。
6. **文档注释门禁门槛（>= 80%）**：生产源码（`src/**/*.zig`，排除 `*_test.zig`）中，**至少 80% 的文件**必须包含 Zig 文档注释 `//!` 或 `///`。注意统计口径：门禁脚本判定的是「该文件是否含至少一条文档注释」这一布尔值，并非按行统计注释密度，因此 80% **不代表** 80% 的代码行有注释。门禁脚本：`python3 scripts/check_comment_coverage.py src 80`，细则见 `docs/code-comments.md`。
7. **真实状态原则**：未完全支持的平台特性（如 Windows PTY）应客观标记或返回未支持，严禁虚构实现或宣称已完成。

---

## 4. Linux 采样热路径设计原则

Linux 是主要部署场景，也是极低资源消耗的核心基石：

1. **零阻塞瞬时采样**：直接读取 `/proc/stat` 与 `/proc/net/dev` 计数器，与上一轮保存的快照做 Delta 差值除以经过时间计算速率，函数内部**严禁 sleep**。
2. **基于 Deadline 的无漂移调度**：上报循环睡眠预算为 `sleep_ms = target_interval_ms - elapsed_work_ms`，扣除采集与网络耗时，严禁固定 sleep 整个周期导致上报持续延后漂移。
3. **轻量原生优先，杜绝高频 fork**：直接读取 `/proc`、`/sys` 及调用 `statvfs`、`sysinfo` 等系统调用。严禁为常规指标采集 fork 外部 Shell（如 `ps`, `top`, `awk` 等），消除进程创建颠簸。
4. **内存与堆分配治理**：单次上报 JSON 组装必须使用局部 `ArenaAllocator` 在单次迭代后立即整体 `deinit()` 释放；热路径优先使用栈固定缓冲区（Stack Buffer），确保 RSS 长期锁定在 1.5MB 以下。

---

## 5. 高频踩坑与预期行为（LLM Gotchas & 防误报）

### 5.1 易错警示（LLM 常见盲区）
- **Zig 0.16.0 API 变动与兼容层**：LLM 极易臆造已废弃的 Zig 0.11~0.13 API。**涉及文件系统、子进程、套接字网络、时间等系统操作，必须优先使用项目封装的 `src/compat/` 模块**。
- **TLS Worker 线程栈溢出（SIGSEGV）**：Zig 默认线程栈较小。新起线程若执行 TLS 握手、HTTP 请求或较深 JSON 解析，必须显式指定：
  ```zig
  const thread = try std.Thread.spawn(.{ .stack_size = thread_stacks.tls_worker_stack_size }, workerFunc, .{args});
  thread.detach();
  ```
- **WebSocket 并发写安全**：周期上报、Ping 任务、Task 远程命令执行处于不同线程，必须统一调用客户端封装的加锁发送方法（如 `ws_client.sendTextLocked`、`ws_client.sendJsonLocked`），严禁裸写 socket。

### 5.2 预期容错与设计行为（Review 请勿误判为 Bug）
- **BasicInfo 出现两次相似 HTTP 调用**：`basic_info.zig` 会先尝试发送含 `kernel_version` 的完整 JSON；若旧服务端拒绝，会自动降级为不含该字段的 payload 重新发送。这是版本兼容回退策略，不是重复请求 Bug。
- **Auto-Discovery 收到 401 自动重注册**：若服务端返回 401 Unauthorized，Agent 会使本地失效 Token 过期并重新向服务端申请注册凭据。这是机器重新绑定时的恢复机制，不是死循环 Bug。

---

## 6. 开发、验证与 Debug 命令速查

### 6.1 开发与验证
```sh
# 1. 代码格式化（修改后必跑）
zig fmt <修改的文件>

# 2. 运行本地所有单元测试
zig build test

# 3. 校验生产源码文档注释覆盖率（要求 >= 80%）
python3 scripts/check_comment_coverage.py src 80

# 4. 测试 CA 证书过期时重新签发（zig build test 报 raw_conn_test 失败时执行）
sh scripts/gen_test_certs.sh

# 5. 关键目标交叉编译抽检（修改平台相关代码或 build.zig 时必跑）
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=s390x-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=loongarch64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall

# 6. 全平台构建（发布前验证）
./build_all.sh   # Linux / macOS
.\build_all.ps1  # Windows PowerShell
```

### 6.2 Debug 诊断子命令
```sh
# 启用详细调试日志（终端输出 debug.log）
./komari-agent --debug-log --endpoint ... --token ...
# 或环境变量：AGENT_DEBUG_LOG=true

# 内置诊断子命令（注意：是位置参数，不是 --command 开关）
komari-agent list-disk                                         # 检查磁盘与挂载点识别
komari-agent check-mem                                         # 检查内存计算与模式详情
komari-agent socket-timeout-smoke                              # 套接字超时冒烟诊断
komari-agent ping-test <icmp|tcp|http> <target> [custom_dns] [icmp_mode] # 网络测速排障

# 部署服务日志排查
journalctl -u komari-agent.service -n 100 --no-pager                 # systemd
logread | grep komari                                                # OpenWrt（注意避免过度过滤底层网络报错）
```
