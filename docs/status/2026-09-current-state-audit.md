# Komari Zig Agent 当前状态审计

- **日期**：2026-09-30（第 4 节技术债处理结果已回填）
- **基准 Commit**：`9539497`（上游 `luodaoyi/komari-zig-agent`）；第 4 节各项修复记录于本仓库其后的提交
- **编译器版本**：Zig 0.16.0

---

## 1. 当前架构概览

- **主循环守护**：[`src/main.zig`](../../src/main.zig) 统一调度前台 BasicInfo、自更新检查，并由 [`src/protocol/report_ws.zig`](../../src/protocol/report_ws.zig) 维护 WebSocket 核心事件循环，具备网络瞬断重连与优雅退出（`SIGINT`/`SIGTERM`）。
- **Worker 模型**：按需与常驻结合（Update、BasicInfo、NetStatic 独立常驻线程；Ping、Exec、Terminal 按需生成），关键网络线程均显式分配 1MB~2MB 独立栈。
- **平台支持矩阵**：自动构建 20 个独立产物（Linux 11 架构 + FreeBSD 4 架构 + macOS 2 架构 + Windows 3 架构）。
- **协议层**：支持原生 HTTP/1.1、WebSocket (RFC 6455)、Komari v1 与 Komari v2 JSON-RPC 2.0 双向兼容回退。

---

## 2. 已确认完成能力

- **多架构构建**：Linux 11 架构（全 musl，含 loong64、s390x、mips 等）及 BSD/macOS/Windows 交叉编译全通（代码依据：[`build.zig`](../../build.zig), [`build_all.sh`](../../build_all.sh)）。
- **Linux 热路径**：`/proc/stat` 与 `/proc/net/dev` 纯原生瞬时差值采样，绝对零 sleep；基于 Deadline 动态扣除耗时，上报周期无漂移（代码依据：[`src/platform/linux.zig`](../../src/platform/linux.zig), [`src/protocol/report_timing.zig`](../../src/protocol/report_timing.zig)）。
- **Windows 指标采集**：全面基于 Win32 原生 API（`GetSystemTimes`, `GlobalMemoryStatusEx`, `GetIfTable2` 等），常规采样零进程 fork（代码依据：[`src/platform/windows.zig`](../../src/platform/windows.zig)）。
- **协议兼容与容错**：v2 失败 3 次平滑降级 v1；BasicInfo 自动 fallback 剥离 `kernel_version`；Auto-Discovery 401 自动重新注册（代码依据：[`src/protocol/v2_state.zig`](../../src/protocol/v2_state.zig), [`src/protocol/basic_info.zig`](../../src/protocol/basic_info.zig)）。
- **网络与自更新**：自研 RFC 3492 Punycode 编解码与公共 DNS fallback 探针；自更新强制 `SHA256SUMS` 校验并支持失败原子回滚（退出码 42）（代码依据：[`src/idna.zig`](../../src/idna.zig), [`src/dns.zig`](../../src/dns.zig), [`src/update.zig`](../../src/update.zig)）。

---

## 3. 已实现但存在限制

### 3.1 Windows Terminal
- **当前状态**：[`src/terminal/terminal.zig`](../../src/terminal/terminal.zig) 采用 `powershell.exe -NoLogo` + stdin/stdout pipe fallback。
- **未完成/限制**：未在 `build.zig` 对 Windows 启用 ConPTY 模块，不支持终端窗口尺寸调整（Resize），复杂 VT 交互式命令行（如 vim）体验受限。

### 3.2 FreeBSD / macOS 指标采集
- **当前状态**：每轮采样通过 `commandOutput` 连续 fork 调用 `sysctl`, `netstat`, `df`, `vm_stat`，macOS 更调用了耗时高达 500ms 的 `top -l 1 -n 0`。
- **未来目标**：改用原生 C 库系统调用（`kern.cp_time`, `getifaddrs`, `statfs`），消除高频进程创建开销。

### 3.3 网络套接字与超时控制
- **当前状态**：Linux 具备非阻塞 poll 超时建连；FreeBSD/macOS 建连实质为系统阻塞调用；Windows 套接字超时接口为空实现（[`src/net.zig:176`](../../src/net.zig#L176)）。

### 3.4 ICMP 探测权限
- **当前状态**：Linux ICMP 依赖 root 或系统 `ping_group_range`，在受限非 root 容器中若权限不足会返回 -1 探测失败。

---

## 4. 技术债与潜在隐患（2026-09-30 已处理）

### 4.1 已修复

- **[P0] 测试 CA 根证书过期 —— 已修复**
  - **根因**：[`test/testdata_ca_root.pem`](../../test/testdata_ca_root.pem) 此前由手工命令签发，有效期仅 24 小时，于 2026-09-19 过期。`std.crypto.Certificate.Bundle` 会静默拒收过期证书，`test/raw_conn_test.zig` 的两个用例因 `bundle.map.count() == 0` 而失败，阻断 `zig build test`。
  - **修复**：新增 [`scripts/gen_test_certs.sh`](../../scripts/gen_test_certs.sh)，统一签发 `test` / `test-dir` 两张自签 CA，**10 年有效期**且 `notBefore` 回拨 1 天以容忍 CI 时钟漂移。重新签发后 `zig build test` 恢复全绿。
  - **复发防护**：证书到期不再需要手工救火，跑一次 `sh scripts/gen_test_certs.sh` 即可。

- **[P1] Exec 任务线程栈尺寸未显式指定 —— 已修复**
  - **位置**：[`src/protocol/report_ws.zig`](../../src/protocol/report_ws.zig) 两处 `std.Thread.spawn(.{}, runExecTask, ...)`（`handleServerMessage` 的 `.exec` 分支与 `processV2Event` 的 `MethodAgentExec` 分支）。原审计只标了 357 一处，实际两处都缺。
  - **风险**：默认栈在 musl 下为 128KB，而 `runExecTask` 会执行 `task.runCommandDetailed` + `uploadExecResult`（含 TLS 握手与 JSON 解析），存在 SIGSEGV 风险，与 AGENTS.md §5.1 的栈溢出条目一致。
  - **修复**：两处统一改为 `.{ .stack_size = thread_stacks.tls_worker_stack_size }`（1MB），与相邻的 Ping / Terminal 任务保持一致。

- **[P3] GPU JSON 内存所有权跨层手动转移 —— 已修复**
  - **原状**：[`src/report/report.zig`](../../src/report/report.zig) 的 `allocReportJson` 内部 `defer` 释放 `snap.gpu_json`，而调用方 [`src/protocol/report_ws.zig`](../../src/protocol/report_ws.zig) 必须用可变标志 `owns_gpu_json` 配合「先置 false 再调用」来避免双重释放。两个序列化函数对同一份 snapshot 的所有权语义不一致，且所有权规则在调用点不可见，属于易被后续改动踩中的隐性契约。
  - **修复**：职责归位，两个序列化函数改为**纯借用**（`writeReportJson` / `allocReportJson` 均不再释放）；所有权统一收敛到快照获取处，由新增的 `freeSnapshotGpuJson` 在 `writeReportOnce`、`runOnce`、`postV2ReportOnce` 三处各调用一次。`owns_gpu_json` 标志删除。
  - **附带收益**：契约变为「谁 `snapshotWithOptions` 谁释放一次」，新增调用点漏掉释放会立刻暴露，不再需要跨文件对齐一个魔法标志。

### 4.2 经核查为误报（不修改代码）

- **[P2] `startTls` 栈变量指针逃逸 —— 误报，无 UAF**
  - **原判**：认为 [`src/protocol/raw_conn.zig:143-169`](../../src/protocol/raw_conn.zig#L143-L169) 把局部栈变量 `ca_bundle` / `ca_bundle_lock` 的地址交给了「长期连接对象」，构成 UAF 隐患。
  - **核查依据**：阅读 Zig 0.16.0 `std/crypto/tls/Client.zig` 的 `init` 签名与返回结构体，可确认 `Client` **不会保留** `options.ca` 中的任何指针：
    - `init` 内部对 `options.ca` 的全部访问都发生在握手过程中（`Client.zig:667-670` 的 `ca.lock` / `ca.bundle.verify`，以及仅由握手机制的 `server_key_exchange` 分支调用的 `tryDownloadRootCert`）。
    - `init` 返回的 `Client` 结构体字面量只保留 `input` / `output` / `options.read_buffer` / `options.write_buffer` / `options.ssl_key_log`（`Client.zig:918-951`），不含 `ca.bundle` 与 `ca.lock`。
    - stdlib 对 `entropy` 字段明确注明「指针不被捕获，仅在 `init` 期间读取」，`ca` 的用法与之一致。
  - **结论**：`startTls` 是同步的，`defer ca_bundle.deinit(...)` 在 `init` 返回后才执行，握手已完成对 bundle 的全部使用，栈变量生命周期覆盖了每一次真实访问。**不存在野指针，也不存在 UAF**，本项不做代码改动。若未来 stdlib 引入握手后仍需访问 CA bundle 的路径（如会话票据恢复），此项需重新评估。

### 4.3 新发现（待决策，未修改代码）

- **[P1-new] v2 模式下 Exec 结果仍走 v1 端点**
  - [`src/protocol/task.zig:173`](../../src/protocol/task.zig#L173) 的 `uploadExecResult` 显式 `_ = protocol_version;`，无论协商到 v1 还是 v2，一律 POST 到 `http.taskResultUrl`（`/api/clients/task/result`）。对照之下 Ping 与 BasicInfo 均已按 `v2_state` 分流。
  - 同时 [`src/protocol/v2.zig:110`](../../src/protocol/v2.zig#L110) 的 `allocTaskResultNotification` 与 `MethodAgentTaskResult` **已定义但无任何调用点**（死代码）。
  - **未改动原因**：修正它会改变对外上报的端点与报文格式，直接触碰 AGENTS.md §3 红线 1（严禁篡改协议字段）。需先确认 Komari 服务端在 v2 协商后是否仍受理该 v1 端点；若受理则现状正确，若不受理则属于真实缺陷。此项**必须经服务端验证后决策，不可由 agent 侧单方面改动**。

- **[P2-new] 既有文件未通过 `zig fmt --check`**
  - `src/main.zig`、`src/protocol/http.zig`、`src/protocol/raw_conn.zig`、`src/protocol/ws_client.zig`、`src/protocol/autodiscovery.zig`、`src/autodiscovery_test.zig` 共 6 个文件存在格式偏差，为本次改动之前既有状态。因与本轮技术债处理无关，未做批量重排以免污染 diff，交由独立格式化提交处理。

- **[P3-new] `v2_seen_event_ids` 无界增长**
  - [`src/protocol/report_ws.zig:29`](../../src/protocol/report_ws.zig#L29) 的事件去重集合在进程生命周期内只增不减。长期运行且事件量大的部署会缓慢抬升常驻内存，与 AGENTS.md §4.4 的内存治理目标存在张力。建议加容量上限或按时间窗淘汰。

---

## 5. 验证记录（2026-09-30）

- `zig build test`：全绿（原为 188/193，2 failed）。
- `python3 scripts/check_comment_coverage.py src 80`：89.80%（44/49），达标。
- 关键目标交叉编译（AGENTS.md §6.1）：`x86_64-linux-musl`、`s390x-linux-musl`、`loongarch64-linux-musl`、`x86_64-freebsd`、`aarch64-macos`、`x86_64-windows-gnu` 均 `ReleaseSmall` 通过，20 目标构建矩阵未受影响。

---

## 6. 下一阶段建议实施顺序

1. **协议确认（阻塞 4.3 首项）**：与 Komari 服务端确认 v2 协商后 `/api/clients/task/result` 是否仍受理，据此决定 `uploadExecResult` 是补 v2 分支还是清理 v2 死代码。
2. **内存治理**：为 `v2_seen_event_ids` 加上限或时间窗淘汰。
3. **功能演进**：在 `build.zig` 中对 Windows 开放并接入 `pty_windows.zig`，实现真实 ConPTY 支持（含 Resize）。
4. **平台原生化**：FreeBSD / macOS 采集改用 `kern.cp_time`、`getifaddrs`、`statfs` 等原生调用，消除高频 fork 开销（同时消除 AGENTS.md 描述与实现的偏差）。
5. **工程整洁**：单独提交既有 6 个文件的 `zig fmt` 格式化。
