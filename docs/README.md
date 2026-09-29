# 文档导航与版本基准说明

本文档用于厘清仓库内各类文档的权威度、职责范围以及历史档案的参考方式。

---

## 1. 当前可信入口（当前生效规范）

在进行开发、评审或使用时，以下文档代表当前系统的最新设计、约束与事实来源：

- [根目录 AGENTS.md](../AGENTS.md)  
  **AI 与开发者的统一规范与规则约束**。包含架构全景、不可破坏的协议红线、Linux 热路径采样原则、高频踩坑（Gotchas）、Code Review 一票否决项及开发诊断命令。
- [根目录 README.md](../README.md)  
  **面向最终用户的项目说明书**。包含性能基准对比、一键安装/替换原 Go Agent 脚本、自更新说明、构建指南与服务部署。
- [根目录 .coderabbit.yaml](../.coderabbit.yaml)  
  **自动化 Code Review 规则与约束配置**。定义面向 PR 审查机器人的代码审查路径指引与红线约束。
- [docs/code-comments.md](code-comments.md)  
  **生产代码注释覆盖率规范**。说明 `>= 80%` 注释覆盖率门槛的统计口径与本地检查命令。
- [`docs/status/`](status/)  
  **项目状态审计与技术债快照**。记录特定时间节点的真实能力、已知限制与待办技术债清单（参见 [`2026-09-current-state-audit.md`](status/2026-09-current-state-audit.md)）。
- [`docs/for-fork-maintainer.md`](for-fork-maintainer.md)  
  **Fork 维护者指南**。说明上游同步流程、自更新仓库指向的坑、测试挂载方式、CLI/环境变量/JSON 完整参考、变更记录约定、已知文档与实现不符之处。

---

## 2. 历史归档文档说明

以下目录及文件属于项目开发演进过程中特定阶段的归档记录：

- [`docs/superpowers/specs/`](superpowers/specs/)  
  **早期立项设计文档（RFC / Design Specs）**。记录 2026 年 5 月初从 Go 移植到 Zig 时的初始设想。其中包含当时阶段设定的范围约束（如早期曾将 Windows 标记为 out-of-scope），这些假设在后续迭代中已被全面支持并取代。
- [`docs/superpowers/plans/`](superpowers/plans/)  
  **历史演进实施计划（Implementation Plans）**。记录各专项攻坚任务（如功能闭环对齐、热路径零阻塞改造等）的阶段性任务清单与推进步骤。
- [`docs/issues/`](issues/)  
  **特定问题复盘归档**。记录历史具体故障（如 Issue #9 OpenWrt 崩溃循环）的根因定位与修复策略草案。

---

## 3. 冲突裁决原则

历史文档如实记录了当时阶段的设计思路与演变过程，不可避免地包含早期已过时的假设。

**裁决准则**：  
凡历史文档（`docs/superpowers/`、`docs/issues/` 等）与**当前源码**、**单元测试**或**根目录 [AGENTS.md](../AGENTS.md)** 存在任何描述、平台范围或实现差异，**一律以当前源码、测试用例和 AGENTS.md 为准**。
