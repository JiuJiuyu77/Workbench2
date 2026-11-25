## 1.2.7 · Build292

1. 代码审计：清理 `Runtime/Contracts*.h` 里指向已删除实现的声明（TFAISessions / TFAIConnections / TFAITransport / TFAICreateRuntime / TFAIProjectID 等），只保留真正有实现的入口，避免误用后运行期崩溃。
2. 权限：entitlements 补 `get-task-allow`、`com.apple.private.cs.debugger`；构建时按 `--bundle-id` 改写 keychain-access-groups 与 application-identifier，换包名不再失配。
3. 构建提速：工具链复制改用 APFS clone（`cp -c`，失败回退），Toolchain 内 Mach-O 签名改为 8 线程并行；日志打印各阶段耗时与 IPA 体积。

## 1.2.6 · Build291

1. 修复 TrollStore 安装失败（ldid: Unknown header magic）：内置 SDK 里的 fat 静态归档（如 libc++experimental.a）会让 ldid 误判为 fat Mach-O；打包前统一 `lipo -thin arm64`，无法细分的直接剔除。
2. 对齐 Work1 权限：无描述文件构建时，主程序与 `bin/spark-jitd` 使用 Work1 同款 entitlements（platform-application / no-sandbox / persona-mgmt / get-task-allow / task_for_pid-allow 等），TrollStore 安装后具备 root persona 与 JIT 授权能力。
3. 体积：1.2.5 的裁剪继续生效（Swift SIL 工具、Theos 文档/测试、重复 clang++），ipa 约 690MB。

## 1.2.5 · Build290

1. 体积优化（不改变内置内容）：裁剪 Theos 包里的 docs/tests/examples/.git，删除 Swift 工具链中构建用不到的 SIL 调试工具（sil-opt / sil-nm / sil-llvm-gen / sil-func-extractor / sil-passpipeline-dumper，单个约 100–155MB）、sourcekitd、lldb，并把 OLLVM 的 clang++ 改成指向 clang 的符号链接。
2. 其余内置内容不变：Theos、OLLVM、逆向工具、Swift 5.9.2、iPhoneOS 16.5 SDK 仍随包离线可用。

## 1.2.4 · Build289

1. 修复：`Resources/RemoteWeb`（局域网编辑器）与 `Resources/FLEXProject`（FLEX 示例工程）此前被 .gitignore 排除，CI 构建一直缺失；现已纳入仓库并随包分发。
   - 影响：之前的 1.2.2/1.2.3 包里没有 RemoteWeb，局域网远程页的网页资源缺失。
2. FLEX 保持随包（插件 + 示例工程）。
3. 版本 1.2.4（289），其余同 1.2.3。

## 1.2.3 · Build288

1. FLEX 保持随包：FLEX 插件与 FLEX 示例工程恢复为设备构建资源（上一版仅模拟器携带）。
2. 其余同 1.2.2：无 AI、全内置工具链（Theos/OLLVM/逆向/Swift/16.5 SDK）、构建只走 Theos/make。

## 1.2.2 · Build287

1. 删除进程内编译架构：移除 ios_system、LLVM cc1 直调、Logos/perl 进程内预处理；构建统一走内置 Work1 工具链的 Theos/make（`SPBuilder`），工具链未就绪时直接报错，不再静默回退。
2. 全内置工具链：Theos（theos-full + theos-root + helpers）、OLLVM、逆向工具（r2/r2ghidra/mt-*）、Swift 5.9.2、iOS 16.5 SDK 全部打进 ipa；首次启动无需下载。
3. 资源清理：删除 clang/libLLVM/lld/perl/ios_system 五个 xcframework、ClangInclude、Perl 模块、SDK.zip、commands.plist；仓库同时移除对应 Vendor 包与 `Resources/{Perl,ClangInclude,Personas,AIProviders,AgentSkills}`。
4. 反汇编改用工具链自带 `libLLVM-16.dylib`（仅 C API，不再需要 App 内 LLVM 框架）。
5. AI 层彻底移除：`App/AI` 退出编译，非对话模块迁至 `App/Runtime`；LAN 远程工作台改用非 AI 的本地工具层（`Runtime/Toolbox.m`），`ai_*` 动作统一拒绝。
6. 新增：`bin/spark-jitd`（TrollStore JIT 授权 helper）、`apple-magnifier://enable-jit` 授权入口、GitHub Actions 云端构建（`WBCloudBuild`）。
7. CI：LLVM 23 的 lld 拆包探测、meson/ninja、iSH 降级路径、macOS bash 3.2 兼容；工具链内 596 个 Mach-O 逐个 adhoc 签名。

## 1.2.1 · Build286

1. 彻底移除 AI 对话层：`App/AI`（189 文件）退出编译与仓库，会话、模型服务商、人设、用量、Agent、工具注册与聊天界面全部删除。
2. 非对话能力迁到 `App/Runtime`：iSH 沙盒运行时（31）、备份引擎（3）、附件与目录授权（8）、二进制/类导出（6）、构建队列与缓存（7）、资源下载与更新（4）、后台任务与活动（6）。
3. 新增非 AI 工作区工具层 `App/Runtime/Toolbox.m`：远程工作台的 list/search/read/build/artifacts/git_* 由本地文件与 libgit2 直接执行，不再经过 AI 工具链。
4. 远程工作台去掉 `ai_*` 动作与会话表依赖；AI 入口（会话、设置、附件浏览器）从设置与共享面板移除。
5. 构建修复：LLVM 23 的 lld 拆包探测、CI 安装 meson/ninja、iSH 降级路径不再崩溃、控制器类与工厂函数同名冲突、跨 TU static、`workbench_listener_hook` 与 `WORKBENCH_EMBEDDED_SANDBOX` 宏对齐。
6. 新增 `spark-jitd`（独立 JIT 授权 helper）与 TrollStore `apple-magnifier://enable-jit` 入口；新增 GitHub Actions 云端构建（`WBCloudBuild`）。

## 1.2.0 · Build285

1. 基于 dylix 1.1.4 重构为 Workbench 2，移除 AI 对话产品层（聊天界面、服务商接入、人设、流式传输、用量统计共 69 个文件），保留本机构建、终端沙盒、Git、文件管理、备份与二进制分析能力。
2. 新增环境自检（设置 → 终端与逆向 → 环境自检）：逐项检查内置 SDK、可选 SDK、clang/libLLVM/lld 框架切片、Perl 运行时、Clang 头文件、可用空间与工程目录可写性，失败项给出修复建议，并支持一键导出完整报告。
3. 构建脚本登记新模块，版本号统一为 1.2.0（285）。

## 1.1.4 · Build284

1. 优化上下文与缓存：保留稳定请求前缀，完善缓存用量统计和长会话上下文处理，减少重复读取与循环执行。
2. 完善会话交互：区分空消息续接与普通发送，支持任务执行中补充或修正消息，改进中断后的任务衔接。
3. 修复项目关联：普通聊天、头文件导出和分享文件会话关联项目时继续使用原会话，保留聊天、附件与任务记录。
4. 完善协议适配：调整 Anthropic 缓存标记及流式用量处理，保留原始会话证据，区分本地估算与服务商计费用量。
5. 更新构建与启动配置：使用 Xcode 自带 iOS 27.2 SDK，修复新 SDK 下的场景启动配置，统一版本为 1.1.4（284）。

## 1.1.3 · Build272

1. 会话导出支持选择“仅会话”或“会话与附件”，纯会话保留聊天、思考和工具执行记录，无需打包附件。
2. 改进工作上下文保留：按文件版本合并已读源码与相邻范围，保留当前提案、已执行结果和任务进度，减少重复发现与无效历史回读。
3. 历史读取支持文本字段、行范围和可调片段大小；预算紧张时优先保留用户明确指定的函数或符号附近源码，原始记录仍可恢复。
4. 加强重复观察与自然语言重复控制：先补齐必要证据并局部纠偏，持续无进展才有限停止；保留正常分页、变化查询、修改后验证及长任务。
5. 优化简洁、标准、详细三种回答风格；用户明确格式优先，并准确区分上下文保护的 KiB 字节大小与模型 token 窗口。
6. 上下文诊断和会话导出记录策略版本、构建信息和纠偏事实；增加多档预算压力、原文恢复、协议和真实 API 对照测试。
7. 主应用、分享扩展和实时活动版本统一为 1.1.3（272）；使用 iOS 26 SDK 构建，最低 iOS 15，FLEX 配套版本保持 1.0.3。

测试范围与限制：真实 API 对照使用代理提供的模型标识及 Chat Completions 接口；接口错误单独记录，不把离线通过、模拟恢复或未出现暂停当成生产零循环保证。部分正常任务会因保留更多证据增加 token，未测真实渠道扣费。IPA 需要按设备安装方式重新签名。

## 1.1.2 · Build265 · 防循环紧急修复

- Responses 单次输出额度上限由 4096 调至 16384（含思考），显示具体未完成原因；保留用量且不重放不完整工具。
- 修复浏览文件夹/搜索以 `.` 指定项目根目录时被权限层误拒绝；仍限制敏感路径、符号链接及越界。

1. 改用滑动窗口累计重复结果，修复穿插查询、变化提案ID及历史引用绕过保护；继续任务保留近期检测记录。
2. 减少不必要历史回读，保留待审批提案与真实修改回执；正常分页、不同文件及有新进展长任务继续运行。

# Workbench 1.1.2 · Build 226–264 更新汇总

1. 终端工具改为全局持久安装，所有 AI 与终端共用；自动迁移旧环境，显示会话、项目及实时目录，区分复用 Shell 与新建任务。
2. 工具与 iOS 26 SDK 改为按需下载，安装包由约 301 MiB 缩至约 99 MiB；支持单项/全部安装、状态进度、卸载及实际 SDK 检测。
3. 完善终端快捷键、项目入口和权限联动；补充 Mach-O、deb、签名工具，支持 Linux 环境快照、恢复、版本切换与镜像管理。
4. 重做模型图片、工具和深度思考适配，支持自动识别与手动调整；未知能力可直接尝试，测试失败不再强制禁用，FLEX 同步会话思考设置。
5. 加强重复执行防循环、关键结果保留和上下文按需加载；支持运行中补充文字、独立停止及后台中断后续接，新增回答风格与可选提示缓存。
6. 完善文件夹挂载、持久授权及 AI/终端读取链路，会话可从挂载目录添加附件；签名标识不匹配时提示并支持复制正确 Bundle ID，移除排查日志。
7. 修复单文件分享被误识别为地址文本的问题，支持目录归档导入和当前会话 IPA 解压；附件气泡精简展示，文件按用途分类并使用易读名称。
8. 新增分类加密备份、选择恢复和单会话 ZIP 导入导出；显示大小、耗时及进度，离开页面继续备份，支持终止、记住密码及独立本机备份页。
9. 优化存储统计与清理速度，后台删除保持界面可操作，细分 Linux、缓存及本机数据；备份按钮增加进度光圈，修复导航栏遮挡与完成提示反复弹出。
10. 完善构建/分析子任务、任务状态和取消续接，补齐 MCP 权限、撤权及调用审计，改进 iPad 工作台分栏和草稿保留。
11. 完善技能按需读取、长期记忆管理及浏览器会话隔离；支持局域网/本机远程终端与访问撤销。
12. FLEX 支持三指、四指长按唤出，并修复深度思考切换；插件版本统一为 1.0.3。
13. 设置按使用场景重新分组，支持底部导航栏显示开关；联系入口放在“关于与支持”，新增启动及手动检测官网更新。
14. 更新提示支持忽略当前版本，重启后仍生效；后续新版正常提示，手动检测仍可查看被忽略版本。

历史构建记录见 docs 中对应验证文档。
