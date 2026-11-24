# Workbench 1 → Workbench 2 能力对照

> Workbench 1（`JiuJiuyu77/Workbench`，Spark/Rein 血统）= 外部 Theos 工具链 + 云端构建的产品线。
> Workbench 2（`JiuJiuyu77/Workbench2`，dylix 血统）= 进程内 LLVM 工作台。
> 本文只做事实对照，结论以代码为准（路径均在 `App/` 下）。

## 一、能力矩阵

| 能力 | Workbench 1 | Workbench 2 现状 | 结论 |
|---|---|---|---|
| 工程识别 | `ProjectKit` 读 Makefile/control，识别 tweak/app/library/tool/node | `SPBuilder` + `TheosMakefile` + `ArchiveImport`，读 `MobileCompiler.json` / Makefile | 等价 |
| 编译内核 | 外部 Theos（`make package`） | 进程内 clang + LLD（dylix 工具链，`Vendor/*.xcframework`） | 两条路线，非缺失 |
| Logos | `tools/spark-logos.py` 预处理 | `Resources/logos` + ClangInclude，`.x/.xm` 直接编 | 等价 |
| 架构 / 包格式 | arm64、arm64e、双架构；deb/rootless/.app/.tipa | `SPModels` 构建设置 + `DebPackage` | 等价 |
| OLLVM 混淆 | 5 个 irobf pass + 轻度/均衡/强力预设 | `SPBuilder` 支持 `--useOLLVM`，`SPToolchainInstaller` 有 `ollvm` 组件目录 | **半实现**：需要下载/放置带 irobf 的 clang，未做预设 UI |
| 逆向 | radare2 / mt-inject-dylib / ldid / 段熵 | `WBReverseController` + reverse-tools 包 + `DylibSignature`/`RuntimeDiagnostics` | 等价（无 mt-inject） |
| **巨魔注入器** | 参考 TrollFools 的 6 步注入（备份→规范化→Substrate→选主 Mach-O→插 LC_LOAD_DYLIB→ct_bypass） | 无 | **缺失**（见第三节） |
| 本机构建 | `make` | 进程内编译（更快，无 shell） | 更优 |
| SSH 远程构建 | 生成脚本 → scp → ssh 执行 | `SPBuilder` 的 `SPBuildTargetRemote` + 远程构建页 | 等价 |
| **GitHub Actions 云端构建** | 手机上传 zip → Cloudflare Worker → workflow_dispatch → 回传产物 | 无 | **本轮补齐**：`WBCloudBuild`（写 workflow / dispatch / 查状态） |
| MCP | Node 版 `bin/spark-mcp.mjs`（stdio + 回环 HTTP） | 原生 HTTP MCP（`docs/MCP_ACCESS.md`、`AGENT_PROTOCOLS.md`） | 等价 |
| 失败解释 | 10+ 类编译错误的中文建议 | `SPDiagnostics` + `CompatibilityRepair` | 等价 |
| 环境自检 | `spark_doctor` | `WorkbenchHealth` / `SPDiagnostics` | 等价 |
| 压缩包导入 | 无 | `ArchiveImport`（zip/7z/rar/tar，工程识别） | Workbench 2 独有 |

## 二、本轮已补齐

1. **GitHub Actions 云端构建**（`App/WBCloudBuild.{h,m}` + 远程构建页第 3 节）
   - 写入 `.github/workflows/workbench-cloudbuild.yml`（contents API，base64，已存在则比对内容再更新）；
   - `workflow_dispatch` 触发，输入 `scheme=rootless|rootful`；
   - 查询最近一次 run 的状态/分支/时间，点开跳转 GitHub 页面；
   - token 复用 `TMCGitService credentialForURL:@"https://github.com"`，不写仓库、不落盘。
   - workflow 内容固定为「拉 theos → make package → 上传 deb」，不执行仓库里的自定义脚本。

2. **JIT / 提权链路补全**（详见 `docs/TROLLAGENT_BORROW.md`）
   - `Native/jitd/spark-jitd.c`：独立 helper，`PT_ATTACHEXC → 100ms → PT_DETACH`；
   - `SPTrollStoreFix` 新增 `canRequestTrollStoreJIT` / `requestJITAuthorization`（`apple-magnifier://enable-jit`）；
   - 执行环境页新增「JIT 授权」行。

3. **构建稳定性**
   - CI：LLVM 23 起 lld 拆分为独立 formula，探测/安装 `/opt/homebrew/opt/lld/bin/ld.lld`；
   - CI：安装 meson/ninja，iSH 组件不再静默降级；
   - `build.py`：iSH manifest 缺失时正确设置 `-DWORKBENCH_HAS_ISH=0` 并跳过拷贝（原实现直接 copy 崩溃）；
   - 修复 `WBRemoteController` 缺少类声明、`TFAIISHToolResources.inc` 残留旧类名 `DylixISHJob`。

## 三、仍未补齐：巨魔注入器

Workbench 1 的注入器依赖设备上的 `insert_dylib` / `install_name_tool` / `ldid` / `ct_bypass`，Workbench 2 没有任何 Mach-O 写入代码（`PackageLinking.h` 只校验弱化符号与 rpath）。

建议实现顺序（未开工）：

1. Mach-O 只读分析复用 `TFAIABinary` / `RuntimeDiagnostics`；
2. 新增 `WBInjectPlan`：枚举 `/private/var/containers/Bundle/Application`、`/Applications`、`/var/jb/Applications`，选主 Mach-O（跳过 `PlugIns/`、`*.framework/`），生成「插件 → 安装路径 → rpath → Substrate 依赖」计划；
3. 写 LP64 头：仅在 `sizeofcmds + 新命令 <= 首个 section fileoff` 时插入 `LC_LOAD_DYLIB`（可选 weak），否则明确报「头部无空隙，需要重链接」；
4. 注入前 `App.app → App.app.workbenchbak`，失败回滚；
5. 改过的二进制不保留旧签名：交给 TrollStore 安装时重签（离线 IPA 路线），不自行伪造 CoreTrust；
6. 每一步先出计划、再执行，日志落盘。

不做：内核级 trust cache 注入、绕过签名校验、对未授权 App 写入。
