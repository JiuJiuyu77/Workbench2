# 1.4.9 入口 → 控制器唯一表 + 崩溃源审计

审计范围：底部「工作台」5 个入口、设置页全部入口；核对三类已知崩溃源
（主线程同步 Shell、重复 push 嵌套导航、数组越界 `WBAt`）。

## 一、工作台（App/WBWorkbenchController.m）

| # | 行标题 | 处理 | 目标控制器 | 导航封装处理 |
|---|--------|------|-----------|--------------|
| 1 | 快速构建测试 | `WBHealthRunQuickBuild(self)` 直接执行 | 无 push（自检流程） | — |
| 2 | 环境自检 | push | `WBHealthController()`（普通 VC） | 直接 push |
| 3 | 逆向工作台 | push | `WBReverseController()`（返回 `TMCNavigationController`） | 取 `viewControllers.firstObject` |
| 4 | IPA 头文件导出 | push | `TFAIClassDumpController()`（普通 VC） | 直接 push |
| 5 | 崩溃分析 | push | `WBStudioCrashTools()`（普通 VC） | 直接 push |

> 状态区 3 行（工具链 / 混淆强度 / JIT 可执行内存）只展示状态，不跳转。

## 二、设置页（App/Studio.m · StudioSettings）

| 分组 | 行标题 | key | 目标 |
|------|--------|-----|------|
| 插件开发 | Theos 工具链 | `theos` | `WBTheosToolsController()`（nav → 解包） |
| 插件开发 | 默认构建设置 | `build` | `StudioBuildPreferences` |
| 插件开发 | 优化方案 | `optimization` | `StudioOptimizationPicker` |
| 插件开发 | 混淆强度 | `obfuscation` | ActionSheet（不跳转） |
| 插件开发 | Git 与源代码管理 | `git` | `TMCGitSettingsController(nil)` |
| 插件开发 | 局域网远程 | `remote` | `WBRemoteController()`（nav → 解包）= 远程工作台 |
| 终端与逆向 | 终端 | `terminal` | `TFAIISHTerminalController(nil)` |
| 终端与逆向 | 安装工具 | `tools` | `TFAIISHToolsController(nil)` |
| 终端与逆向 | 环境自检 | `health` | `WBHealthController()` |
| 终端与逆向 | 执行环境 | `execenv` | `WBToolsController()`（nav → 解包） |
| 终端与逆向 | 逆向工作台 | `reverse` | `WBReverseController()`（nav → 解包） |
| 数据与工具 | 存储空间 | `storage` | `TMCStorageController()` |
| 外观与编辑器 | 界面外观 / 代码字号 | `theme` / `font` | ActionSheet（不跳转） |
| 外观与编辑器 | 始终显示底部导航栏 | `tabs` | 开关（不跳转） |
| 关于与支持 | 关于 / 反馈 / 官网 / 开源地址 / 许可证 | `about` … `license` | 各自页面或系统浏览器 |

### 本次清掉的重复/死路由

- `remotepage` → `WBRemoteController()`：与 `remote` 完全重复（同一控制器、同一条导航），删除。
- `headers` / `crash`：设置页没有对应行（这两个入口已迁到工作台），删除死分支。
- `WBWorkbenchController` 的 `details` 数组原来有 8 项、只有 5 行（残留「安装工具 / 存储 / 远程」文案），已裁到 5 项。

## 三、三类已知崩溃源核对

### 1. 主线程同步 Shell（`SPSession runSyncShell:`）

| 位置 | 原状 | 处理 |
|------|------|------|
| `WBTheosToolsController.m` `WBVersionOf()` | 在 `cellForRow`（主线程）里对 8 个工具逐个同步执行 | 改为后台探测一次 + 内存缓存；主线程只读缓存，未完成显示「检测中…」 |
| `SPJIT.m` `-probe` | 调用方可能从主线程进入（`SPJITService start` 内含 `posix_spawn` + 最多 3s `usleep` + socket 阻塞读） | `probe` 统一切到串行后台队列，完成后回主线程发 `SPJITStatusChanged` |
| `WBToolsController.m` 执行环境 | 进入页面不探测；「重新探测」在两层队列里重复调度 | 进入页面时触发一次后台探测；改用通知刷新 |
| `WBWorkbenchController.m` 工作台 | JIT 行长期「未探测」 | 进入页面触发一次后台探测 + 通知刷新 |
| `SPToolchainDownloader` 解包 | 在 URLSession 回调（后台队列）里调 `runSyncShell` 跑 tar/dpkg | 改 App 内 libarchive，不再起子进程 |
| `SPIShell.m` / `WBRemoteController.m` / `main.m` | 均在后台队列调用 | 核对通过（`runSyncShell` 自带主线程防护） |

### 2. 重复 push 嵌套导航

- 会返回 `TMCNavigationController` 的工厂：`WBTheosToolsController()`、`WBToolsController()`、`WBRemoteController()`、`WBWorkbenchController()`。
- 工作台 / 设置页在 push 前统一取 `viewControllers.firstObject`（设置页原有 `isKindOfClass:UINavigationController` 解包）。
- 其余直接 push 的工厂（`WBHealthController`、`TMCStorageController`、`TMCGitSettingsController`、`TFAIISHToolsController`、`TFAIISHTerminalController`、`TFAIClassDumpController`、`WBStudioCrashTools`）都返回普通 VC，已逐个核对。
- 结论：现有代码没有把导航控制器塞进导航栈的路径。

### 3. 数组越界（`WBAt` / 下标）

- `SPCompat.h` 的 `WBAt()` 已做类型 + 范围校验，返回 nil。
- 新增保护：Theos 页「当前版本」/「可安装组件」行数在异步刷新期间可能变化，`cellForRow` 与 `didSelect` 均加了 `row < count` 校验。
- 工作台工具行对 `titles/details/icons` 三个数组加了长度校验，且三者长度一致（5）。
- 设置页行数据是静态表，`WBAt` 已覆盖；`optimization`/`obfuscation` 的取值都用 `MIN(MAX(...))` 限制。

## 四、顺带修掉的逻辑漏洞

1. **混淆「自定义」入口不可达**：`names` 只有 4 项，`n == 4` 的自定义分支永远进不去，但设置页会显示「自定义」。已补第 5 项。
2. **SDK 组件判定用错编号**：`currentComponent` 存的是清单数组下标，却拿去和 `SPComponent` 枚举（含 node/python/buildtools）比较，导致 SDK 解包后被当成普通组件写入 `.installed`、改 bin 权限。改为按清单 `id` 前缀判断。
3. **「已安装组件仍显示」**：清单 `probe` 只按 `installRoot/<probe>` 查，下载的组件实际在 `installRoot/<id>/<probe>`。改为两处都查，并把 theos 的 probe 改成包内真实路径 `theos-full/makefiles/common.mk`。
4. **下载解包依赖设备命令**：tar / zstd / dpkg-deb 在沙盒里不保证存在。统一走 App 内 libarchive（tar/tgz/txz/zst/zip/7z/deb，保留可执行位和相对符号链接）。
5. **CI 覆盖 Theos bin 导致 logos.pl 丢失**：`刷新 Theos makefiles` 原来连 `bin/` 一起换，上游 bin 没有 `logos.pl`。改为只换 `makefiles/`，并在步骤里显式校验 `theos-full/bin/logos.pl`。
