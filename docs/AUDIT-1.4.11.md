# 1.4.11 构建产物扩展 + 代码审计

## 一、本轮改动

1. 「构建产物」从 2 种扩展到 6 种：deb、dylib、app、ipa、bundle、可执行工具。
2. 新增 IPA 打包：把 `.theos/_` 里的 `.app` 打成 `Payload/<App>.app/…` 的 zip（未签名）。
3. dylib 导出补上实现：以前只有开关和命名模板，构建流程里没有对应代码。
4. app / bundle / tool 从 staging 目录提取；全部落到工程的 `packages/`，构建结果页和导出流程无需特判。
5. 六种产物至少保留一种；deb 包类型至少保留一种。

## 二、代码审计（本轮新增代码）

### 1. `TMCZipDirectory()`（App/ArchiveImport.m）

| 检查点 | 结论 |
|--------|------|
| 归档写入失败 | 每个 `archive_write_header/data` 返回值都检查；失败即跳出并删除半成品 zip |
| 文件描述符 | `open` 失败、写入失败、正常结束三种路径都 `close(fd)` |
| 条目路径 | 条目名由「调用方前缀 + 相对路径」组成，来自受控目录枚举，不含用户输入 |
| 符号链接 | 只记录链接目标，不跟随（`destinationOfSymbolicLink`）；目标不做二次解析，zip 内链接不指向归档外 |
| 资源上限 | 50,000 条目；单文件不设上限（.app 可能上百 MB，属预期） |
| 权限 | 保留原始 POSIX 位；目录固定 0755 |
| 压缩 | `zip:compression=deflate` 失败时退回 store（仍是合法 zip），不报错 |

### 2. `+exportSelectedArtifactsInProject:`（App/SPBuilder.m）

| 检查点 | 结论 |
|--------|------|
| 触发时机 | 只在 `job.state == SPJobStateSucceeded` 时执行；构建失败不会产出半成品 |
| 目录遍历 | 深度上限 8、数量上限 200；`.app` 命中后不再向下递归（避免把 App 内 dylib/bundle 当独立产物） |
| 命名注入 | dylib 名走 `TMCOutputFilename`，会拒绝 `/ \ :`、控制符、未配对大括号、`.` 开头与超长名称；重名自动加 `-2` |
| 覆盖 | 复制前删除同名目标，不会出现「旧产物冒充新产物」 |
| 失败处理 | 复制/打包失败写日志并跳过，不影响构建成功判定；产物名列表只包含真正成功的项 |
| 并发 | 在 SPSession 完成回调（后台队列）执行，不占主线程；与构建是同一串行流程，不会并发写 `packages/` |
| 配置读取 | `MobileCompiler.json` + NSUserDefaults 经 `TMCEffectiveBuildOptions` 合并；新键默认关闭 |

### 3. 设置页状态机（App/Studio.m）

| 检查点 | 结论 |
|--------|------|
| 行数与开关 | 6 行开关 + root 的「输出跟随全局」行；`outputFlagForRow` / `setOutputFlag` 一一对应，无越界（`WBAt` 兜底标题） |
| 约束 | 六种全关 → 回滚开关并提示；deb 开关联动包类型（开启 deb 默认 rootless）；包类型全关 → 恢复 rootless |
| 回滚 | `persistSettings` 失败 → `restoreState:` 恢复六种开关 + 包类型 + 模板，并刷新表格 |
| 持久化 | 项目：写 `exportIpa/exportApp/exportBundle/exportTool`；跟随全局时统一删除；全局：`StudioExportIpa/App/Bundle/Tool` |
| 一致性 | `refreshChoices` 按 tag 同步开关状态，footer 实时汇总，不会出现「开关关了但文案还写着会生成」 |
| 迁移 | 旧配置没有新键 → 默认关闭，不影响既有工程行为 |

### 4. 构建结果复制（App/main.m）

- 允许 deb/dylib/tipa/ipa/app/bundle；
- 无扩展名文件只在带执行位时才算产物（工具二进制）；
- 仍按修改时间过滤，避免旧产物混入本次构建。

## 三、已知限制

1. `ipa` / `app` 仅对应用型工程（Application target）有内容；tweak 工程勾选不会报错，但不会产出。
2. IPA 未签名，交给 TrollStore / 签名工具处理；App 内 `Frameworks` 的符号链接按原样写入。
3. bundle/工具按文件名导出，不做重命名模板；deb/dylib 的模板保持原有语义。
4. 大工程（`.app` 很大）时 IPA 打包会占用与产物等量的临时空间，构建日志会打印「打包 IPA：xxx.ipa」。
5. 未实机验证；编译与打包逻辑通过 CI 构建验证。