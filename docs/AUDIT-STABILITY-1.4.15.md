# 子进程启动稳定性加固（1.4.15）

针对用户反馈「子进程为什么会启动失败，审计相关代码，优化稳定性」，本次对 `SPSession` 启动链路做了深度加固。

## 一、降级重试链（Multi-tier Fallback）

此前若指定的 shell（如 `helpers/bash`）因沙盒规则、缺少执行位、架构不匹配等 `posix_spawn` 返回非 0，仅尝试了一次 `/bin/sh` 便宣告失败。

**本次优化**：
- 在 `SPSession.m` 的 `launch:` 中引入了**多级降级链**：
  1. 优先尝试请求的解释器（如 `helpers/bash` 等）；
  2. 若失败，依次降级尝试：`/bin/sh` → `/var/jb/bin/sh`（越狱环境）→ `/bin/bash`；
  3. 每一级都会独立初始化标准的 `posix_spawnattr_t`（SIGPIPE 默认、进程组独立），并把每次尝试的 `rc` 与 `errno` 完整记入日志（`SPLog`），直到成功或全部耗尽。
- 这样即使包内 bash 签名/权限在某些系统版本下失效，系统自带的 `/bin/sh` 也能无缝顶上，彻底根绝“找不到合适的 shell 导致所有子进程不启动”的脆性。

## 二、管道与回调防死锁

- `pipe()` 创建失败时，此前直接 `return -1` 且不触发任何回调，导致调用方（如构建流程）永久等待（3600秒超时）。
- **优化**：`pipe()` 失败时会立刻构造带 `launchError` 的 `SPCommandResult` 并调用 `finishNotifying`，让界面和调用方秒级拿到失败响应并解冻。

## 三、JIT Helper 进一步加固

- 修复了 `sun_path` 截断（此前 `j<pid>.sock` 已修复）；
- 启动时重定向 stderr 到 `spark-jitd.log`，未出现时自动把日志尾部与 pid 存活状态落盘。

## 四、版本
版本升至 **1.4.15（320）**。
