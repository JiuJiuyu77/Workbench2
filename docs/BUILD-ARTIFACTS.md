# 构建产物（1.4.11 起）

设置 → 默认构建设置（或项目构建设置）→「构建产物」现在可以选择六种输出：

| 选项 | 产物 | 来源 | 生效条件 |
|------|------|------|---------|
| Debian 包 (.deb) | `packages/*.deb` | `make package` | 任意 Theos 工程；包类型（rootless / rootful / roothide）可多选 |
| 动态库 (.dylib) | `<模板名>.dylib` | `.theos/_/**/*.dylib` | tweak / library 工程；按 `outputPattern-dylib` 命名，多个自动加 `-2` |
| 应用包 (.app) | `<App>.app` | `.theos/_/**/*.app` | 应用型工程（Application target） |
| 安装包 (.ipa) | `<App>.ipa` | 由 `.app` 现场打包（`Payload/<App>.app/…`） | 应用型工程；未签名，交给 TrollStore / 签名工具处理 |
| 资源包 (.bundle) | `<Name>.bundle` | `.theos/_/**/*.bundle` | 含 bundle 的工程（preference bundle 等） |
| 可执行工具 | 原文件名 | `.theos/_/usr/bin`、`.theos/_/usr/local/bin` | tool 工程 |

## 规则

- 六种产物**至少保留一种**，否则无法保存（界面会拦截并回滚开关）。
- 选择 deb 时，包类型（rootless / rootful / roothide）至少保留一种。
- `app` / `ipa` 只对应用型工程有用；tweak 工程勾选也不会报错，只是没有 `.app` 可导出。
- dylib / deb 的命名模板在「自定义产物昵称 / 文件名模板」里编辑；其余类型沿用原始文件名。
- IPA 打包保留可执行位与相对符号链接；不跟随链接，不修改 `.app` 内容（不做签名）。

## 实现与安全

- 新增 `TMCZipDirectory()`（ArchiveImport）：libarchive 进程内写入 zip，`zip:compression=deflate`（不支持时退回 store），条目上限 50,000。
- 产物导出在 `SPBuilder +exportSelectedArtifactsInProject:`，构建成功后、收集产物前执行；全部落在工程的 `packages/`，随后由构建结果复制到 `Documents/Build-*`。
- 扫描 staging 目录有深度（8）与数量（200）上限；`.app` 内部不再向下扫描，避免把 App 内嵌 dylib / bundle 当成独立产物。
- 复制前删除同名目标；复制失败写日志并跳过，不会让整个构建显示成功却没有产物。