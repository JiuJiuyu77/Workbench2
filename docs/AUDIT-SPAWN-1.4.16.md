# 构建起不来 / 子进程失败审计与排查指南（1.4.16）

## 一、排查工具：构建脚本自动落盘

此前当“点构建”没有反应或进程立即退出时，由于脚本直接通过内存管道交由 `sh` 执行，无法在外部复现或审查。

**本次优化**：
- `SPBuilder` 在每次执行构建前，会把完整的 shell 构建脚本自动落盘到：
  $$\text{NSTemporaryDirectory()} / \text{workbench-last-build.sh}$$
- 当遇到“构建起不来”时，可在设备上（或通过终端/iSH）直接执行该脚本排查：
  ```bash
  sh /private/var/mobile/Containers/Data/Application/<UUID>/tmp/workbench-last-build.sh
  ```
  即可看到是哪一步（如 `make`、`ldid` 或 SDK 检查）抛出了错误或被杀。

## 二、可能导致“构建起不来”的常见根因及排查步骤

1. **工具链路径不对或被破坏**
   - 检查 `Toolchain/` 下的 `theos-full`、`theos-runtime` 覆盖层是否损坏。
   - 确认设置里的 Theos 工具链是否显示“已就绪”。
2. **环境缺失（如 `make` 或 `perl` 没有执行权限）**
   - 检查归档解压时是否丢失了 `+x` 权限。
3. **沙盒权限/签名冲突（SIGKILL）**
   - 若二进制在 iOS 17 上未签名，执行时会被内核直接杀死（此前版本会表现为日志空白、构建一直卡住或瞬间失败）。现已在 `SPSession` 中增加了信号终止捕捉，会输出 `exit=137 进程被信号 9 终止`。

## 三、版本
版本升至 **1.4.16（321）**。
