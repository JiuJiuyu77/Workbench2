# 1.4.10 死代码清理 / 逻辑与代码审计 / 工具链校验

审计对象：Workbench2 `main` @ `465f5f7`（1.4.9 / 314）之后的本轮改动。
结论：**编译通过、包内工具链结构 PASS**；本轮修复 6 处逻辑漏洞、清理 2 个死模块 + 1 个死函数，并把 1 个死工具函数接回生命周期。

## 一、死代码清理

| 对象 | 判定依据 | 处理 |
|------|---------|------|
| `App/SPHeaderExport.h/.m` | 全仓库无任何调用方（类名只出现在自身与构建清单）；头文件导出功能现由 `TFAIClassDumpController` 提供 | 删除文件，同步 `scripts/build.py` 编译清单 |
| `App/SPDiagnostics.h/.m` | `SPDiagnostics` / `SPRiskItem` 只出现在自身文件，无 UI、无调用方（`RuntimeDiagnostics` 是另一套） | 删除文件，同步编译清单 |
| `Studio.m` `static UIVisualEffectView *Glass(void)` | 仅定义、无引用（卡片玻璃已由 `GlassSupport` 的 `TMCCardCell` 承担） | 删除 |
| `SPSessionReapAllChildren()` | 只有定义，全仓库没有调用；注释写明「App 退出 / 长时间挂起时调用」 | **接回** `applicationWillTerminate:`，退出时收掉残留子进程 |

保留说明：`TFAIISHRuntime.m` 的 `InitSkillFS()` 也无人调用，但它与 `TFAIISHDirectoryFS.inc` 同处 `#if WORKBENCH_HAS_ISH` 的 VFS 集成块，删除会连带影响 iSH 挂载结构，本轮不动（已在清单标注）。

## 二、逻辑漏洞（本轮修复）

1. **包内工具链自拷贝 / 自删除（高危）**
   `installRoot` 在内置运行时下等于 `bundledRoot`，而 `expandWithProgress` 会先 `removeItemAtPath:dst` 再从 `src` 复制；`uninstall` 也会直接删 `installRoot`。任何一次「安装 / 重新展开」都会把 App 包里的工具链删掉，且不可恢复。
   → `expandWithProgress` 增加 `src == dst` 直接返回；`uninstall` 拒绝删除包内工具链并写日志。

2. **SDK 组件「移除」会删掉整个工具链（高危）**
   `directoryFor:` 对 SDK 返回 `installRoot` 本身，`remove:` 直接删除它 = 删除整个 Toolchain。
   → `remove:` 按组件 id 分流：SDK 只删 `installRoot/sdks/iPhoneOS<版本>.sdk`。

3. **工具链页「移除」按钮是假按钮**
   downloader 已提供 `remove:`，UI 却弹「暂不支持移除」，两边不一致，用户无法释放空间。
   → 改为真正执行移除并刷新列表。

4. **构建产物可以同时关闭**
   设置页「构建产物」允许 dylib / deb 都关，之后构建没有任何产物，也没有提示。
   → `outputChanged:` 拦截「两个都关」：回滚开关并提示「至少保留一种产物」。

5. **DEB 包类型可以全部关闭**
   deb 开启但 rootless / rootful / roothide 全关时，构建不会产出 deb，界面却显示 deb 已开启。
   → `schemeChanged:` 兜底恢复 rootless 并提示。

6. **「构建产物」footer 与开关状态不一致**
   footer 固定写「至少选择一项」，不反映实际会生成什么。
   → footer 改为实时概览：`当前将生成：deb × 2（rootless、rootful）· dylib × 1`；「DEB 类型」footer 列出已选包类型。

（上一轮已修：主线程同步 Shell、SDK 枚举/清单下标混用、probe 路径、重复路由、混淆自定义不可达。）

## 三、代码审计要点

### 线程
- `SPSession runSyncShell:` 保留主线程硬拒绝；全仓库剩余调用点（`SPIShell` / `WBRemoteController` / `main.runTool` / `SPHeaderExport` 已删除）都在后台队列。
- `SPJIT.probe` 固定串行后台队列，完成后主线程发 `SPJITStatusChanged`；`WBTools` / `WBWorkbench` 通过通知刷新，不再嵌套两层 `dispatch_async`。
- 版本探测 `WBVersionProbe` 只在后台调用 `runSyncShell`，主线程只读缓存。

### 资源
- libarchive 解包：每条目写完即 `close(fd)`；失败路径也关闭；`archive_read_free` 在成功/失败都执行。
- `.deb` 解包使用临时目录，结束后 `removeItemAtPath`。
- 下载完成回调中同步解包（URLSession 临时文件在回调返回后即失效），未遗留文件句柄。

### 路径安全
- 解包路径：拒绝绝对路径与 `..`；符号链接/硬链接解析后必须仍在目标目录内，否则丢弃。
- 组件删除只作用于 `installRoot/<id>` 或 `installRoot/sdks/<name>`，不会越出沙盒。

### 错误处理
- 解包失败保留 libarchive 的原始错误并回传 UI；失败不写 `.installed`，不会出现「显示已安装但缺文件」。
- 下载/解包完成统一回主线程回调，失败信息不吞。

### UI / 导航
- 返回 `TMCNavigationController` 的 4 个工厂（Theos / 执行环境 / 远程 / 工作台）在 push 前统一解包；其余工厂逐个核对为普通 VC。
- 设置页删除 `remotepage` / `headers` / `crash` 三个无对应行的死分支。
- 数组越界：`WBAt` 安全取值 + Theos 页版本/组件行、工作台三数组的显式长度校验。

### 内存
- 通知观察者在 `dealloc` 移除；后台 block 使用 `__weak typeof(self)`；串行队列替代重复创建。

## 四、工具链校验（对已发布 1.4.9 包实测）

新增 `scripts/verify_toolchain.py`（支持 `.ipa` / `.app` / `Toolchain` 目录，直接读压缩包中央目录）：

```
== Toolchain 位置：Payload/Workbench.app/Toolchain（zip）
== 条目数：38717
ok  theos-full/makefiles/common.mk
ok  theos-full/bin/logos.pl
ok  theos-root/usr/bin/{make,perl,ldid}
ok  ollvm/bin/clang            是 Mach-O 64（98.0 MB）
ok  swift-toolchain/usr/bin/swiftc  是 Mach-O 64
ok  helpers/bash               是 Mach-O 64（0.8 MB）
ok  reverse/bin/mt-macho       是 Mach-O 64（4.2 MB）
ok  链接器 bin-lld/ld64
ok  SDK：iPhoneOS16.5.sdk / iPhoneOS17.0.sdk / iPhoneOS26.5.sdk
info Theos makefiles：83 个 .mk
== 结果：PASS（问题 0 项）
```

结论：包内工具链完整，`logos.pl` 已随 CI 修复保留，三个 SDK 都在，关键二进制都是 arm64 Mach-O 且带执行位。

## 五、构建产物（默认构建设置）完善

- 「构建产物」footer 实时显示将生成的 deb / dylib 数量与包类型；
- dylib / deb 不能同时关闭（回滚 + 提示）；
- deb 包类型不能全部关闭（兜底 rootless + 提示）；
- 开关变化后刷新 footer（`refreshChoices` → `reloadData`），避免文案与状态脱节；
- 产物文件名预览逻辑保持原有 `TMCOutputFilename` / `TMCVariantOutputFilename`，未改模板语义。

## 六、遗留风险

1. 无法在真机运行，UI 卡片外观与开关手感仍需实机确认。
2. zstd 解包依赖系统 libarchive 是否带该滤镜，缺失时给出明确错误而非静默失败。
3. 删除的 `SPDiagnostics`（风险诊断）与 `SPHeaderExport`（头文件导出）如需恢复，可从 git 历史取回；两者当前都没有入口。
