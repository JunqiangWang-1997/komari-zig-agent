# Fork 维护者指南

本文档面向本仓库（`JunqiangWang-1997/komari-zig-agent`）的维护者，覆盖上游同步、测试、配置参考与变更记录约定。

上游仓库为 [`luodaoyi/komari-zig-agent`](https://github.com/luodaoyi/komari-zig-agent)，协议兼容目标是官方 Go Agent [`komari-monitor/komari-agent`](https://github.com/komari-monitor/komari-agent) 1.2.60。修改本仓库代码前，请先阅读根目录 [`AGENTS.md`](../AGENTS.md)（7 条红线为一票否决项）。

---

## 1. 上游同步

本仓库是上游的真实 fork，GitHub 上有 "Sync fork" 按钮；同时本地配置了双 remote：

| remote | 指向 | 用途 |
| :--- | :--- | :--- |
| `origin` | `JunqiangWang-1997/komari-zig-agent` | 本仓库推送目标 |
| `upstream` | `luodaoyi/komari-zig-agent` | 上游原作者仓库 |

同步命令：

```sh
git fetch upstream
git log --oneline main..upstream/main   # 查看上游领先的提交
git merge upstream/main                 # 合并更新
```

**同步时的冲突高发区**：`src/protocol/`（协议实现，红线 1）、`src/platform/{freebsd,darwin,windows}.zig`（红线 2 构建矩阵）、`src/main.zig` 与 `src/protocol/report_ws.zig`（红线 3 crash loop）、`src/update.zig` 与安装脚本（红线 5 完整性校验）。

---

## 2. ⚠️ 自更新与安装脚本仍指向上游

**这是 fork 后最容易踩的坑。** 源码已经是我们自己的，但下列位置仍硬编码 `luodaoyi/komari-zig-agent`：

- `src/version.zig` 的 `repo` 常量 —— 决定自更新去哪个仓库查 Release
- `install.sh` / `replace.sh` / `install.ps1` / `update-binary.sh` 的下载地址与代理池
- `README.md` 中 `replace.sh` 的 curl 地址（还额外 pin 到了某个 commit SHA，会静默过期）

**后果**：如果直接发布本仓库的 Release，已安装的 agent 仍会去拉**上游**的二进制，等于用别人的代码覆盖我们的修改。

在真正基于本 fork 迭代之前，需要先决定：

1. 是否把 `version.repo` 改为本仓库（会影响所有已部署 agent 的自更新来源）；
2. `README.md` 里 pin 到 commit SHA 的 `replace.sh` curl 地址改为跟随分支（否则用户拿不到脚本修复）。

这两项都**尚未修改**，因为它们同时影响自更新行为与安装脚本分发，属于需要显式决策的改动。

---

## 3. 测试

### 3.1 本地验证

```sh
zig build test                                              # 全部单测
python3 scripts/check_comment_coverage.py src 80            # 注释门禁
sh scripts/gen_test_certs.sh                                # 测试 CA 过期时重签
```

交叉编译抽检（改动平台代码或 `build.zig` 后必跑，AGENTS.md 红线 2）：

```sh
zig build -Dtarget=x86_64-linux-musl     -Doptimize=ReleaseSmall
zig build -Dtarget=s390x-linux-musl      -Doptimize=ReleaseSmall
zig build -Dtarget=loongarch64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-freebsd        -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos         -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-windows-gnu    -Doptimize=ReleaseSmall
```

全平台（20 目标）发布前验证：`./build_all.sh`（Linux/macOS）或 `.\build_all.ps1`（Windows）。

### 3.2 新增测试必须挂进 build.zig

**新建 `test/*.zig` 文件不会自动参与 `zig build test`。** 必须在 `build.zig:125-154` 的 `test_paths` 数组里登记，否则测试静默不运行（不报错、也不计入覆盖率）。删除测试文件时同样要从该列表移除，否则构建失败。

该列表当前 25 项，其中 3 项位于 `src/` 而非 `test/`（`src/autodiscovery_test.zig`、`src/terminal_test.zig`、`src/platform/gpu.zig`）。另有 2 个 v2 协议测试由 `addStandaloneV2Test` 单独注册，不在 `test_paths` 内。

### 3.3 测试 CA 证书

`test/testdata_ca_root.pem` 与 `test/testdata_ca_dir.pem` 是 `test/raw_conn_test.zig` 用 `@embedFile` 嵌入的 CA 加载夹具。此前手工签发的证书只有 24 小时有效期，过期后 `std.crypto.Certificate.Bundle` 会**静默拒收**（不报错，只是装不进去），表现为 `raw_conn_test` 的 `bundle.map.count() == 0` 断言失败。

用 `scripts/gen_test_certs.sh` 重签即可（10 年有效期，`notBefore` 回拨 1 天以容忍 CI 时钟漂移）。

### 3.4 CI 中未写进任何文档的测试套件

以下测试在 CI 中真实执行，但没有任何文档提及：

- `test/script_harness.sh`、`test/install_ps1_static_test.ps1` —— 安装脚本静态测试
- `scripts/mock_komari_smoke.py` —— 冒烟
- `scripts/mock_komari_business_e2e.py` —— 业务 e2e（模式：`panel`、`self-update`）
- `scripts/mock_komari_v2_e2e.py` —— v2 e2e（模式：`ws`、`post-fallback`、`post-recover`）
- `scripts/install_zig_ci.sh` —— 配合 `build.yml` 中的 `ZIG_SHA256` / `FREEBSD_ZIG_SHA256` 固定哈希下载

### 3.5 ⚠️ 覆盖率门禁的实际范围有限

`README.md` 提到的 kcov `100.00%` 门禁，**不是 `src/` 全量行覆盖率**：

- `build.zig` 的 `isCoverageTest()` 只对 `test/coverage_test.zig` 一个路径返回 true，命中后立即 `return`；其余 24 个 `test_paths` 条目加 2 个 standalone 测试共 26 个测试目标**不产生任何覆盖率数据**
- `test/coverage_test.zig` 仅 36 行，只 `@import("protocol_ip")`
- `scripts/check_coverage.py` 对所有报告取 `max()`

即：门禁实际只衡量 `src/protocol/ip.zig` 一个模块。要把它变成真正的全量门禁，需要重写 `coverage_test.zig` 使其聚合全部测试目标，或改造 `build.zig` 让所有测试都经 kcov。**这是一个已知待办，不是已完成的能力。**

---

## 4. 配置参考

### 4.1 CLI 标志

全部标志见 `src/config.zig` 的 `parseArgs`。支持 `--key value` 与 `--key=value` 两种写法。

| 类别 | 标志 |
| :--- | :--- |
| 必填 | `--token`、`--endpoint` |
| 上报 | `--interval`、`--max-retries`、`--reconnect-interval`、`--info-report-interval`、`--protocol-version`、`--prefer-ip-version` |
| 采集过滤 | `--include-nics`、`--exclude-nics`、`--include-mountpoint`、`--month-rotate`、`--gpu` |
| 网络 | `--custom-dns`、`--custom-ipv4`、`--custom-ipv6`、`--cf-access-client-id`、`--cf-access-client-secret`、`--disable-compression` |
| 行为开关 | `--disable-auto-update`、`--disable-web-ssh`、`--ignore-unsafe-cert`、`--memory-include-cache`、`--memory-exclude-bcf`、`--debug-log`、`--get-ip-addr-from-nic`、`--show-warning`、`--auto-discovery` |
| 其他 | `--config`（JSON 配置文件路径） |
| 诊断子命令 | `list-disk`、`check-mem`、`socket-timeout-smoke`、`ping-test <type> <target> [dns] [icmp_mode]` |

短别名（仅 6 个，注意与直觉不同）：

| 别名 | 对应标志 |
| :--- | :--- |
| `-t` | `--token` |
| `-e` | `--endpoint` |
| `-i` | `--interval` |
| `-u` | `--ignore-unsafe-cert` |
| `-r` | `--max-retries` |
| `-c` | `--reconnect-interval` |

`--config` **没有**短别名；`-u`/`-r`/`-c` 容易与直觉相反，改动 `config.zig` 时勿动错。

**已废弃且被静默忽略**（`config.zig` 的 `isDeprecated`）：`-autoUpdate`、`--autoUpdate`、`-memory-mode-available`、`--memory-mode-available`。未知 `-` 前缀参数会被当作带值选项吞掉，不报错。

诊断子命令是**位置参数**，例如 `komari-agent list-disk`，不是 `--command list-disk`。

### 4.2 环境变量

共 31 个（`src/config.zig` 的 `loadEnv`）。除 `HOST_PROC` 外均带 `AGENT_` 前缀，但**并非全部与 CLI 标志同名**，易错处：

| 语义 | CLI 标志 | 环境变量 | JSON 键 |
| :--- | :--- | :--- | :--- |
| 自动发现密钥 | `--auto-discovery` | `AGENT_AUTO_DISCOVERY_KEY` | `auto_discovery_key` |
| GPU 开关 | `--gpu` | `AGENT_ENABLE_GPU` | `enable_gpu` |
| 原始已用内存 | `--memory-exclude-bcf` | `AGENT_MEMORY_REPORT_RAW_USED` | `memory_report_raw_used` |
| 挂载点白名单 | `--include-mountpoint`（单数） | `AGENT_INCLUDE_MOUNTPOINTS`（复数） | `include_mountpoints`（复数） |
| 读取其他 `/proc` | **无 CLI 标志** | `HOST_PROC`（无前缀） | `host_proc` |
| 配置文件路径 | `--config` | `AGENT_CONFIG_FILE` | `config_file` |

### 4.3 JSON 配置

`--config` 指向的 JSON 文件共支持 31 个键（`src/config.zig` 的 `loadJson`），键名与 `Config` 字段同名，解析刻意保持宽容（int/float 交叉接受，类型不符则忽略该键）。注意挂载点白名单在 JSON 中是 `include_mountpoints`（复数），与 CLI 的 `--include-mountpoint`（单数）不一致。

---

## 5. 变更记录约定

本仓库**尚无 `CHANGELOG.md`**。在补上之前，请遵守以下约定：

- 提交信息首行使用祈使句、说明「做了什么」，正文写「为什么」
- 涉及协议字段、构建矩阵、更新校验的改动，必须在正文显式声明**未破坏**对应红线
- 每项功能或修复的落地情况回写到 [`docs/status/`](status/) 下的审计文档，而不是只留在提交信息里

---

## 6. 已知与文档不符之处（维护者注意）

以下差异已在 [`docs/status/2026-09-current-state-audit.md`](status/2026-09-current-state-audit.md) 记录，此处仅作速查：

- `freebsd.zig` / `darwin.zig` **仍 fork 外部命令**（`sysctl`/`netstat`/`df`/`vm_stat`/`ifconfig`），尚未原生化，不存在 `getifaddrs`/`statfs` 调用
- `gpu.zig` **只解析 `nvidia-smi` 的 CSV 输出，无 NVML 绑定**
- Windows 终端**未启用 ConPTY**，不支持 Resize，`pty_windows.zig` 已在 `src/third_party/` 中但未接入 `build.zig`
- Windows 套接字超时接口为空实现（`src/net.zig` 的 `setStreamTimeouts` 中 `.windows => return`）
- `src/protocol/task.zig` 的 `uploadExecResult` 忽略 `protocol_version`，v2 模式下仍 POST v1 端点；`v2.allocTaskResultNotification` 是死代码。**修正它会改变对外协议，触碰红线 1，必须先与服务端确认后再动**
- `v2_seen_event_ids` 在进程生命周期内无界增长

---

## 7. 第三方代码与许可

本仓库为 MIT 许可（见 [`LICENSE`](../LICENSE)，`Copyright (c) 2026 luodaoyi`）。

- `src/third_party/zigpty/` 为 vendored 第三方 PTY 实现，许可声明见 [`src/third_party/zigpty/NOTICE.md`](../src/third_party/zigpty/NOTICE.md)。该 NOTICE 目前**未被** README、AGENTS.md 或 LICENSE 引用，若要分发二进制建议补充署名。
- 本项目兼容目标为 `komari-monitor/komari-agent`，但 LICENSE 中未向上游项目致意。若你的 fork 有实质性改动，建议在 README 中说明与上游项目的关系。
