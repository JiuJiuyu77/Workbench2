# 子进程启动失败审计（1.4.14）

范围：`SPSession`（构建 / 终端 / 探测共用）、`SPJITService`（JIT helper）、
`SPProcessGuard`（persona 托管）、`Native/jitd/spark-jitd.c`。

## 一、实测证据

设备日志（1.4.11，iPhone OS 17.0）：

```
[Workbench] JIT 子进程：socket 未出现（helper 可能启动失败）
[Workbench] 快速构建失败，quickbuild.log 为空
```

崩溃/日志只能看到「子进程没起来」，看不到 errno —— 因为：

- helper 的 stderr 没有被收集（直接进系统日志）；
- 子进程被系统杀掉时没有 stdout/stderr，构建日志一片空白。

## 二、找到的确定性问题

### 1. AF_UNIX 路径超长（JIT helper 失败的直接原因）

`SPJITService` 之前的 socket 路径：

```
/private/var/mobile/Containers/Data/Application/<UUID>/tmp/spark-jit-12345.sock
= 108 字节
```

而 `struct sockaddr_un.sun_path` 只有 **104** 字节。`strncpy` 按 103 字节截断，
helper `bind()` 成功但绑定到**被截断的文件名**；主进程轮询完整路径，永远等不到
→ 3 秒后报「socket 未出现」。helper 本身其实启动成功了。

修复：名字压缩为 `j<pid>.sock`（99 字节），超过 103 字节时退回 `/tmp/j<pid>.sock`；
helper 侧也加了路径长度校验并输出 errno。

### 2. 子进程被系统杀掉时没有诊断

iOS 对未签名 / 无执行权限的嵌套二进制常直接 `SIGKILL`：`posix_spawn` 返回 0，
进程立刻消失，没有任何输出，退出码 137。之前构建日志为空、quickbuild.log 为空，
无法判断是「编译错误」还是「进程被杀」。

修复：
- 退出码 ≥ 129 时在 stderr 末尾补一行「进程被信号 N 终止（SIGKILL=9…）」并写日志；
- 构建失败且一行输出都没有时，向 `job.lines` 与 onLine 补一条 `exit=<code> <原因>`；
- quickbuild.log 同样在无输出时写 `exit=` 与失败原因。

### 3. `pipe()` 失败会让调用方永久等待

`launch:` 里 `pipe()` 失败直接 `return -1`，没有触发 `finishNotifying`。
`SPBuilder` 在 3600 秒的内置等待里一直等 onFinish，表现是「点构建没反应」。

修复：pipe 失败也构造 `launchError` 结果并走完成回调。

### 4. shell 只有一次机会

`resolveShell` 取第一个可执行文件并缓存；若该 shell 实际被沙盒拦截（iOS 上常见），
`posix_spawn` 失败后没有第二次机会。

修复：spawn 失败时自动用 `/bin/sh` 再试一次（仅一次，失败仍按原错误上报），
并记录两次的返回值。

### 5. helper 的 stderr 不可见

修复：启动 helper 时把 stderr 重定向到 `tmp/spark-jitd.log`，失败时把日志尾部
（含 pid 是否存活）写进 workbench.log，下次定位不需要再猜。

## 三、persona 相关核对

- `SPProcessGuard.applyRootPersonaToAttr` 可能部分成功（persona 设上、uid 失败），
  这种情况下 `SPSession` 已有「退回继承身份重试」的兜底，逻辑正确。
- 非 root 设备上 persona 不可用时 `preferredIdentity` 返回继承，不会阻塞启动。
- 由于 helper 的失败原因是路径截断，与 persona 无关；本次不改变身份策略。

## 四、遗留风险

1. 若包内 `helpers/bash` / `ollvm/bin/clang` 在设备上确实未签名，会被系统 SIGKILL；
   本次只做到「能看见原因」。根治需要在安装后对嵌套二进制补签（需 ldid 可执行）。
2. `/tmp` 兜底路径在部分沙盒配置下可能不可写，届时日志会给出 bind 的 errno。
3. JIT 真实可用性仍取决于 TrollStore 的 enable-jit / 平台签名，helper 只是诊断通道。