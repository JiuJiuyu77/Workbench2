# 从 zrrt/TrollAgent 借鉴的能力清单

> 参考仓库：<https://github.com/zrrt/TrollAgent>（Swift，TrollStore 侧载，AI + 原生工具 + Alpine 运行时）
> 事实来源：GOALS.md / FAQ.md / AGENTS.md、`CLaunch/launch.c`、`tools/jit_helper.c`、
> `Sources/TrollMCP2/LaunchdLauncher.swift`、`RemoteTerminalServer.swift`、`TrustEnabler.swift`。
> 本文只记录可复用的机制与边界，不搬运对方的业务代码。

## 一、提权与 JIT（已在 Workbench 2 落地 / 已核对）

| 机制 | TrollAgent 做法 | Workbench 2 现状 |
|---|---|---|
| **root persona 子进程** | `posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)` + `set_persona_uid/gid(0)`，符号 `dlsym` 运行时取；父进程身份不变 | 已有：`SPProcessGuard applyRootPersonaToAttr:`，`SPSession` 的 `SPChildIdentityRootPersona`，失败自动退回继承身份 |
| **JIT 外部附权** | `jit_helper <pid>`：`PT_ATTACHEXC` → 100ms → `PT_DETACH`；**必须由另一个进程**执行，自 attach 无效（会 SIGBUS） | 本轮补齐：新增 `Native/jitd/spark-jitd.c`（unix socket + `jit-check` / `enable-jit <pid>`），构建时编译进 `Workbench.app/bin/spark-jitd` |
| **TrollStore 的 enable-jit URL** | `apple-magnifier://enable-jit`，由 TrollStore RootHelper 从外部 attach，最可靠 | 本轮补齐：`SPTrollStoreFix requestJITAuthorization` + 执行环境页「JIT 授权」入口 |
| **真实执行验证** | 申请一页 → 写 `ret` → 清 icache → 真跳进去执行 | 已有：`SPJIT verifyExecutableByCalling`（注释已标明迁移自 TrollAgent） |

结论：提权链路（persona 99 → root helper → 外部 attach JIT）在 Workbench 2 已经闭环，本轮补上了缺失的 helper 二进制与 URL 授权入口。

## 二、进程/服务托管

| 机制 | 做法 | 是否建议移植 |
|---|---|---|
| **launchd job 启动** | 私有 `_launch_job_routine(OSLaunchdJobSelectorSubmitAndStart=1000)` + `_CFXPCCreateXPCObjectFromCFObject`，请求体必须包 `{monitor, plist}`，否则 `EINVAL` | 暂时不移植。它解决的是「跨进程读 dyld 镜像表」，Workbench 的类导出走 REipa/静态解析，不依赖 task_for_pid |
| **XPC / HUD 控制** | 独立 HUD app + WebSocket（`HUD/sources/WSClient.mm`）叠加触控层 | 不移植。属于演示/自动化产品层，且需要额外 target |
| **系统 HID 动作** | `sys.launch/tap/swipe/paste`，走私有 IOHIDEvent/BackBoard | 不建议默认移植：跨 App 注入输入事件风险高，且与「不绕过检测」的工程约束冲突 |

## 三、运行时与终端

| 机制 | 做法 | 对 Workbench 2 的可用性 |
|---|---|---|
| **Asbestos（iSH 的 ARM64 内核）+ Alpine rootfs** | 取代 iSH/QEMU，支持 `apk`、动态 ELF、JIT 加速 | Workbench 2 已内置 iSH（`Vendor/iSH`，`-Djit=false`），CI 现在会真正编出 `libish*.a`。若要换 Asbestos，需要上游 `Vendor/iSH/asbestos` 目录与本仓库一致，属独立改造 |
| **危险工具分级** | 远程 API 默认拒绝 `injection.* / shell.exec / app.install` 前缀，必须显式开启 | 已有等价能力：LAN Remote 的配对码 + 工作区权限 + 逐项审批；建议后续把「危险前缀」清单落到 MCP 层 |
| **远程终端 HTTP API** | `:8790/health`（免鉴权）、`/api/tool`（Bearer）、`/api/audit`、`/api/crash` | Workbench 2 的 LAN Remote 已覆盖同类需求，接口形态不同，不重复实现 |

## 四、明确不借鉴的部分

- **kfd / 内核读写注入 trust cache**（`TrustEnabler` 的 `.kfdInject` 路径）：对方自己标注「曾导致黑屏重启、已停用」，且属于内核漏洞利用，超出本工程约束。
- **伪造设备/风控上报/抓包 MITM**：与插件工程目标无关。
- **JIT 自 attach 兜底**：对方 FAQ 明确「可能报成功但内核不授予，随后 SIGBUS」，不要作为主路径。

## 五、后续可选（未做）

1. 把 `spark-jitd` 扩展成通用「提权执行器」：接受 `exec <path> <args...>`，供编译/签名等需要 uid 0 的操作复用（当前这些操作已经用 persona spawn，暂无必要）。
2. 远端 MCP 的「危险前缀」白名单，与 LAN Remote 的权限层合并成一张表。
