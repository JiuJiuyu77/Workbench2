//
//  SPBuilder.m
//

#import "SPBuilder.h"
#import "SPTrollStoreFix.h"
#import "SPCompat.h"
#import "SPToolchainInstaller.h"
#import "SPOutputNaming.h"
#import "SPModels.h"
#import "SPSession.h"
#import "SPProcessGuard.h"
#import "SPToolchain.h"
#import "SPStore.h"

@implementation SPBuilder

#pragma mark - 脚本生成

+ (NSString *)scriptForProject:(SPProject *)project
                       options:(SPBuildOptions *)options
                       profile:(SPToolchainProfile *)profile
                    backupPath:(NSString *)backupPath {
    NSMutableArray *lines = [NSMutableArray array];

    [lines addObject:@"# Workbench 生成脚本 —— 可整段复制到终端里单独运行"];
    [lines addObject:@"set -o pipefail 2>/dev/null || true"];
    [lines addObject:@"export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8"];
    [lines addObject:@"__rb_begin=$(date +%s)"];
    [lines addObject:@"say() { printf '\\033[1;36m==> %s\\033[0m\\n' \"$1\"; }"];
    [lines addObject:@"ok()  { printf '\\033[1;32m[ok] %s\\033[0m\\n' \"$1\"; }"];
    [lines addObject:@"warn(){ printf '\\033[1;33m[!] %s\\033[0m\\n' \"$1\"; }"];

    // ---- 环境 ----
    [lines addObject:@"say '准备构建环境'"];
    NSDictionary *env = [options makeEnvironment];
    NSDictionary *extra = [profile extraEnvironment];
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:env];
    [all addEntriesFromDictionary:extra];
    for (NSString *pair in [SPUtil envPairsFromDictionary:all]) {
        NSRange r = [pair rangeOfString:@"="];
        NSString *k = [pair substringToIndex:r.location];
        NSString *v = [pair substringFromIndex:r.location + 1];
        [lines addObject:[NSString stringWithFormat:@"export %@=%@", k, [SPUtil shellQuote:v]]];
    }

    // ---- 内置工具链（ipa 里的，首启展开到 Documents/Workbench/Toolchain）----
    // 结构与 CodexApp/TheosRuntime 一致：rootfs 形态
    //   bin/  usr/bin/  usr/lib/  theos/
    SPToolchainInstaller *inst = [SPToolchainInstaller shared];
    if (inst.isInstalled) {
        NSString *root = inst.installRoot;
        [lines addObject:[NSString stringWithFormat:@"export SPARK_TC=%@", [SPUtil shellQuote:root]]];
        // 运行时可能是两种布局：
        //   平铺（与 Rein 一致）: Workbench.app/theos-root/usr/bin
        //   旧布局:              Workbench.app/Toolchain/usr/bin 或 Workbench.app/usr/bin
        // 自动定位真正的 bin 目录，避免 PATH 指向不存在的位置。
        [lines addObject:@"for c in \"$SPARK_TC/theos-root\" \"$SPARK_TC/Toolchain\" \"$SPARK_TC\"; do "
                      // 判据放宽：clang-16 或 llvm-16/bin/clang 任一存在即可 ——
                 // 有些运行时把真正的 clang 放在 llvm-16/bin，usr/bin 只有薄壳 clang-16。
                 // 用子 shell 把「或」整体括起来，避免 || 与 && 的求值歧义
                 "if [ -x \"$c/usr/bin/clang-16\" ] || [ -x \"$c/usr/lib/llvm-16/bin/clang\" ]; "
                 "then export SPARK_ROOT=\"$c\"; break; fi; done"];
        [lines addObject:@"[ -n \"${SPARK_ROOT:-}\" ] || export SPARK_ROOT=\"$SPARK_TC\""];
        // llvm-16/bin 必须进 PATH：Theos 的 targets/_common/darwin_head.mk 里
        //   _THEOS_TARGET_CC := clang
        //   _THEOS_TARGET_CXX := clang++
        // 调的是 clang / clang++，而 usr/bin 里只有 clang-16。
        // 真正的 clang / clang++ 在 usr/lib/llvm-16/bin/ —— 不放进 PATH 就会
        // 「command not found」→ make 报 library.mk:37 Error 2。
        [lines addObject:@"export PATH=\"$SPARK_ROOT/usr/lib/llvm-16/bin:$SPARK_ROOT/usr/bin:$SPARK_ROOT/bin:$SPARK_ROOT/helpers:$PATH\""];
        // App 自带的命令行工具（spark-logos 等）
        [lines addObject:@"[ -d \"$SPARK_BIN\" ] && export PATH=\"$SPARK_BIN:$PATH\""];
        // 动态库：clang-16 是薄壳，真正的代码在 usr/lib/llvm-16/lib/libLLVM-16.dylib
        [lines addObject:@"TC_LIBS=\"$SPARK_ROOT/usr/lib:$SPARK_ROOT/usr/lib/llvm-16/lib\""];
        [lines addObject:@"export LD_LIBRARY_PATH=\"$TC_LIBS:${LD_LIBRARY_PATH:-}\""];
        [lines addObject:@"export DYLD_LIBRARY_PATH=\"$TC_LIBS:${DYLD_LIBRARY_PATH:-}\""];
        // perl 模块：logos.pl 预处理 .x 必需
        // PERL5LIB：perl5 在 $SPARK_ROOT/usr/lib/perl5（平铺后 SPARK_ROOT=theos-root）。
        // 以前写死 $SPARK_TC/usr/lib/perl5，平铺布局下永远匹配不到，
        // 导致 logos.pl 找不到模块、.x 预处理失败。
        [lines addObject:@"for pd in \"$SPARK_ROOT/usr/lib/perl5\" \"$SPARK_TC/usr/lib/perl5\" "
                      "\"$SPARK_TC/theos-root/usr/lib/perl5\"; do "
                      "[ -d \"$pd\" ] && { export PERL5LIB=\"$pd:${PERL5LIB:-}\"; break; }; done"];
        // THEOS 位置随运行时结构不同，判定条件是
        // 「有 makefiles 且 sdks 里有真实 SDK」。
        //
        // 只判 common.mk 会踩坑：Rein 对齐包里
        // theos-root/theos/sdks 只有一个 .keep 占位，
        // 选中它之后 make 会报「找不到 SDK」。
        // （已删除 theos-full，SDK 现按 DSH 布局放在顶层 sdks/）
        // SDK 可能在 $THEOS/sdks，也可能独立在 $SPARK_TC/sdks（Rein 布局）。
        // 判定条件要同时接受两种，否则会跳过真正能用的 theos。
        [lines addObject:@"for t in \"$SPARK_TC/theos-root/theos\" \"$SPARK_TC/theos\" "
                      "\"$SPARK_TC/TheosRuntime/theos\"; do "
                      "[ -f \"$t/makefiles/common.mk\" ] || continue; "
                      "{ ls \"$t\"/sdks/iPhoneOS*.sdk >/dev/null 2>&1 || "
                      "ls \"$SPARK_TC\"/sdks/iPhoneOS*.sdk >/dev/null 2>&1; } || continue; "
                      "export THEOS=\"$t\"; break; done"];
        // SDK 在顶层时，把它软链进 $THEOS/sdks，让 make 找得到
        // SDK 注入：**不用软链**。
        // TrollStore 的 ldid -s 遇到符号链接会整体失败（实测踩过），
        // 而且包内软链在重签名后可能失效。
        // 做法：只有当 $THEOS/sdks 里没有真 SDK 时，才把顶层 sdks 复制进去；
        // 复制前先看目标位置是否已有完整 SDK，避免每次构建都重复拷几百 MB。
        // SDK 注入：**不用软链**（TrollStore 的 ldid -s 遇软链会整体失败）。
        // 判定「已复制完整」必须同时满足三件事，只看 SDKSettings.json 不够：
        //   ① SDKSettings.json 在   ② usr/include 在   ③ System/Library/Frameworks 非空
        // 否则上一次复制中途失败（空间不足/被杀）留下的半成品会被误判为完整，
        // 之后每次构建都跳过复制，SDK 永远残缺。
        [lines addObject:@"if [ -d \"$SPARK_TC/sdks\" ] && [ -n \"${THEOS:-}\" ]; then "
                      "mkdir -p \"$THEOS/sdks\" 2>/dev/null || true; "
                      "for s in \"$SPARK_TC\"/sdks/iPhoneOS*.sdk; do "
                      "  [ -d \"$s\" ] || continue; "
                      "  n=$(basename \"$s\"); "
                      "  d=\"$THEOS/sdks/$n\"; "
                      "  if [ -f \"$d/SDKSettings.json\" ] && [ -d \"$d/usr/include\" ] && "
                      "     [ -n \"$(ls \"$d/System/Library/Frameworks\" 2>/dev/null | head -1)\" ]; then "
                      "    continue; "
                      "  fi; "
                      "  if [ -d \"$d\" ]; then warn \"SDK $n 不完整，重新复制\"; rm -rf \"$d\"; fi; "
                      "  avail=$(df -Pm \"$THEOS\" 2>/dev/null | awk 'NR==2{print $4}'); "
                      "  need=$(du -sm \"$s\" 2>/dev/null | awk '{print $1}'); "
                      "  if [ -n \"$avail\" ] && [ -n \"$need\" ] && [ \"$avail\" -lt \"$need\" ]; then "
                      "    warn \"空间不足：需要 ${need}MB，可用 ${avail}MB —— 跳过 $n\"; continue; "
                      "  fi; "
                      "  say \"复制 SDK $n（${need:-?}MB）\"; "
                      "  if cp -R \"$s\" \"$THEOS/sdks/\" 2>/dev/null; then "
                      "    ok \"SDK $n 就绪\"; "
                      "  else "
                      "    warn \"复制 SDK $n 失败，清理残件\"; rm -rf \"$d\"; "
                      "  fi; "
                      "done; fi"];
        // THEOS 没找到时必须**立刻中止**。
        // 以前只 warn 一句就继续 make，用户看到的是一屏
        // 「make: *** No rule to make target ...」「common.mk: No such file」，
        // 完全看不出是工具链没装好。
        [lines addObject:@"if [ -z \"${THEOS:-}\" ]; then "
                      "warn '没找到可用的 Theos（makefiles/common.mk + sdks 都没找到）'; "
                      "warn '请到「工具」页安装/修复工具链，或检查运行时是否解压完整'; "
                      "exit 4; "
                      "fi"];
        // SYSROOT 也要显式给：Theos 会拿它去校验 SDK 是否存在，
        // 不设置时在某些版本上会报「chosen SYSROOT does not exist」。
        // 选最新 SDK。**不能用 sort -V**：iOS 上跑的是 busybox sort，
        // 很多版本不认 -V，失败后静默输出空 → SYSROOT 没设上，
        // 后面 make 就会报「chosen SYSROOT does not exist」或直接挑错 SDK。
        // 改成把版本号拆成主/次两段，用 POSIX 的 sort -n 排序，任何 busybox 都支持。
        [lines addObject:@"if [ -z \"${SYSROOT:-}\" ] && [ -n \"${THEOS:-}\" ]; then "
                      "sdk=$(ls -d \"$THEOS\"/sdks/iPhoneOS*.sdk 2>/dev/null | while IFS= read -r s; do "
                      "  v=${s##*iPhoneOS}; v=${v%.sdk}; "
                      "  maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}; "
                      "  case \"$maj\" in ''|*[!0-9]*) maj=0;; esac; "
                      "  case \"$min\" in ''|*[!0-9]*) min=0;; esac; "
                      "  printf '%s %s %s\\n' \"$maj\" \"$min\" \"$s\"; "
                      "done | sort -n -k1,1 -k2,2 | tail -1 | cut -d' ' -f3-); "
                      "[ -n \"$sdk\" ] && export SYSROOT=\"$sdk\" && export THEOS_SDK=\"$sdk\"; fi"];
        // SYSROOT 同样必须硬性拦截 —— 没有 SDK 时 make 会报
        // 「chosen SYSROOT does not exist」或者干脆挑到一个空目录。
        [lines addObject:@"if [ -z \"${SYSROOT:-}\" ]; then "
                      "warn '没找到 iPhoneOS SDK'; "
                      "warn '需要 \"$THEOS/sdks\" 或运行时顶层 sdks/ 里有完整的 iPhoneOS*.sdk'; "
                      "ls -d \"$THEOS\"/sdks/* 2>/dev/null | sed 's/^/    现有: /' || true; "
                      "exit 5; "
                      "fi"];
        [lines addObject:@"ok \"SDK: $SYSROOT\""];
    }

    // App 自带的命令行工具目录（spark-logos 等）
    [lines addObject:[NSString stringWithFormat:@"export SPARK_BIN=%@",
                      [SPUtil shellQuote:[[[NSBundle mainBundle] bundlePath]
                                          stringByAppendingPathComponent:@"bin"]]]];

    NSString *pathPrefix = [[SPToolchain shared] pathPrefixForProfile:profile];
    if (pathPrefix.length) {
        [lines addObject:[NSString stringWithFormat:@"export PATH=%@:\"$PATH\"", [SPUtil shellQuote:pathPrefix]]];
    }

    // OLLVM 时把 CC/CXX 指向混淆编译器
    if (options.useOLLVM && profile.ollvmRoot.length) {
        NSString *clang = [profile.ollvmRoot stringByAppendingPathComponent:@"bin/clang"];
        NSString *clangxx = [profile.ollvmRoot stringByAppendingPathComponent:@"bin/clang++"];
        [lines addObject:[NSString stringWithFormat:@"export CC=%@ CXX=%@", [SPUtil shellQuote:clang], [SPUtil shellQuote:clangxx]]];
        // Theos 用 TARGET 驱动，额外让 _CC/_CXX 生效
        [lines addObject:[NSString stringWithFormat:@"export _CC=%@ _CXX=%@", [SPUtil shellQuote:clang], [SPUtil shellQuote:clangxx]]];
    }

    // ---- 工具链自检 ----
    [lines addObject:@"say '工具链自检'"];
    [lines addObject:@"ok \"内置工具链 $([ -d \"$SPARK_TC/usr/bin\" ] || [ -d \"$SPARK_TC/bin\" ] && echo 就绪 || echo 未就绪)\""];
    [lines addObject:@"for t in make ldid; do command -v $t >/dev/null 2>&1 && ok \"$t $(command -v $t)\" || warn \"缺少 $t\"; done"];
    [lines addObject:@"CCBIN=\"${CA_TOOL_OLLVM_CLANG:-clang}\"; \"$CCBIN\" --version >/dev/null 2>&1 && ok \"编译器 $($CCBIN --version | head -1)\" || warn \"编译器不可用: $CCBIN\""];
    if (options.useOLLVM) {
        [lines addObject:@"command -v clang >/dev/null 2>&1 && ok \"clang $(command -v clang)\" || warn 'OLLVM clang 不在 PATH'"];
    }

    // ---- SDK ----
    if (profile.sdkPath.length) {
        [lines addObject:@"[ -d \"$THEOS_SDK\" ] && ok \"SDK $THEOS_SDK\" || warn \"SDK 不存在: $THEOS_SDK\""];
    }

    // ---- 进入项目 ----
    [lines addObject:[NSString stringWithFormat:@"cd %@ || { echo '项目目录不存在'; exit 2; }", [SPUtil shellQuote:project.path]]];
    [lines addObject:@"say \"工作目录 $(pwd)\""];

    // ---- 清理 ----
    if (options.cleanBeforeBuild) {
        [lines addObject:@"say '清理旧产物'"];
        [lines addObject:@"rm -rf .theos/_ packages .theos/obj 2>/dev/null || true"];
        if (backupPath.length) {
            [lines addObject:[NSString stringWithFormat:@"mkdir -p %@ && cp -R Packages %@/ 2>/dev/null || true",
                              [SPUtil shellQuote:backupPath], [SPUtil shellQuote:backupPath]]];
        }
    }

    // ---- 构建 ----
    NSArray *args = [options makeArguments];
    NSMutableArray *quoted = [NSMutableArray array];
    for (NSString *a in args) [quoted addObject:[SPUtil shellQuote:a]];
    NSString *makeCmd = [@"make " stringByAppendingString:[quoted componentsJoinedByString:@" "]];

    // Rein 经验：真 root 下 Theos 的 fakeroot 是空壳，可显式关掉
    [lines addObject:@""];
    [lines addObject:@"if [ \"$(id -u)\" = \"0\" ]; then ok '当前是 root，跳过 fakeroot 包装'; export THEOS_USE_FAKEROOT=0; fi"];
    [lines addObject:@"export COPYFILE_DISABLE=1"];
    // xz -1 是速度/体积平衡点（默认 -6 在手机上慢得多）
    [lines addObject:@"export THEOS_PLATFORM_DEB_COMPRESSION_LEVEL=1"];

    // A6：内存遥测（Rein 的 boot.js 每 30s 打 rss/heap，这里跟着 make 一起跑）
    [lines addObject:@"memwatch() { while kill -0 $$ 2>/dev/null; do "
                     "  if [ -r /proc/meminfo ]; then "
                     "    awk \'/MemAvailable/{printf \"    [mem] 可用 %d MB\\n\", $2/1024}\' /proc/meminfo; "
                     "  else "
                     "    vm_stat 2>/dev/null | awk \'/Pages free/{gsub(\"\\.\",\"\",$3); printf \"    [mem] 可用 %d MB\\n\", $3*16384/1048576}\'; "
                     "  fi; sleep 15; done; }"];
    [lines addObject:@"memwatch & MEMPID=$!"];
    [lines addObject:@"say '开始编译'"];
    [lines addObject:[NSString stringWithFormat:@"echo '+ %@'", makeCmd]];
    [lines addObject:@"__rb_start=$(date +%s)"];
    // make 之后**必须立刻判退出码**。
    // 之前这里是裸跑 make，失败后脚本继续往下走：
    //   ① 补签用 .theos/obj 里的旧产物
    //   ② 收集 packages/*.deb —— 如果用户没勾「清理旧产物」，
    //      收上来的是上一次的 deb，于是 make 失败也显示「构建成功」。
    [lines addObject:@"__rb_make_ok=1"];
    [lines addObject:[makeCmd stringByAppendingString:@" || __rb_make_ok=0"]];
    [lines addObject:@"if [ \"$__rb_make_ok\" = \"0\" ]; then "
                  "  __rb_t=$(($(date +%s) - __rb_begin)); "
                  "  warn \"make 失败（$__rb_t 秒）—— 往上找 error: 行\"; "
                  "  exit 6; "
                  "fi"];
    [lines addObject:@"ok \"编译通过（$(($(date +%s) - __rb_begin)) 秒）\""];

    // ---- 签名 ----
    if (options.signWithLdid) {
        [lines addObject:@"if command -v ldid >/dev/null 2>&1; then"];
        [lines addObject:@"  say '补签（ldid -S）'"];
        [lines addObject:@"  find .theos/obj -name '*.dylib' -o -name '*.app' -prune 2>/dev/null | while read f; do ldid -S \"$f\" 2>/dev/null && ok \"sign $f\" || true; done"];
        [lines addObject:@"else"];
        [lines addObject:@"  warn '没有 ldid，跳过补签'"];
        [lines addObject:@"fi"];
    }

    // ---- 产物 ----
    [lines addObject:@"say '收集产物'"];
    [lines addObject:@"ls -lh packages/*.deb .theos/_/ 2>/dev/null | sed 's/^/    /' || true"];
    // 产物自检：拆开 deb 看结构
    [lines addObject:@"for d in packages/*.deb; do"];
    [lines addObject:@"  [ -f \"$d\" ] || continue"];
    [lines addObject:@"  if command -v dpkg-deb >/dev/null 2>&1; then"];
    [lines addObject:@"    ok \"校验 $(basename \"$d\")\""];
    [lines addObject:@"    dpkg-deb -I \"$d\" 2>/dev/null | grep -E 'Package:|Version:|Architecture:' | sed 's/^/      /' || true"];
    [lines addObject:@"  fi"];
    [lines addObject:@"done"];
    [lines addObject:@"__rb_finish=$(date +%s)"];
    [lines addObject:@"ok \"全部完成（总用时 $((__rb_finish - __rb_begin)) 秒）\""];

    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - 产物收集

+ (NSArray<NSString *> *)collectArtifactsInProject:(NSString *)projectPath
                                             since:(NSDate *)since
                                           options:(SPBuildOptions *)options {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    // 只收 packages/*.deb —— 这是最终产物。
    //
    // 以前把 .theos/ 和 .theos/_/ 也算进来，但那是编译中间目录：
    //   .theos/         完整 obj 树 + 拷贝的源码，动辄上千个文件
    //   .theos/_/       staging 根目录树（含 usr/lib/… 整个层级）
    // 把它们当「产物」列出来，界面会拉几百上千行，内存和滚动都很糟，
    // 而且用户根本不需要这些中间文件。
    NSArray *dirs = @[@"packages"];
    NSTimeInterval cutoff = [since timeIntervalSince1970] - 2.0; // 容忍时钟差

    for (NSString *rel in dirs) {
        NSString *dir = [projectPath stringByAppendingPathComponent:rel];
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        if (!items) continue;
        for (NSString *name in items) {
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];
            if (isDir && ![name hasSuffix:@".app"]) continue;
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
            NSDate *mtime = attrs[NSFileModificationDate];
            if (mtime && [mtime timeIntervalSince1970] < cutoff) continue;
            if ([name hasSuffix:@".deb"] || [name hasSuffix:@".app"] || [name hasSuffix:@".dylib"] ||
                [name hasSuffix:@".tipa"] || [name hasSuffix:@".zip"]) {
                [out addObject:full];
            }
        }
    }
    // deb 优先
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL da = [a hasSuffix:@".deb"], db = [b hasSuffix:@".deb"];
        if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
        return [b compare:a];
    }];
}

#pragma mark - 失败诊断

+ (NSString *)diagnoseFailureFromLines:(NSArray<SPLogLine *> *)lines {
    // 只扫后面 300 行
    NSArray *tail = lines.count > 300 ? [lines subarrayWithRange:NSMakeRange(lines.count - 300, 300)] : lines;
    NSMutableString *blob = [NSMutableString string];
    for (SPLogLine *l in tail) { [blob appendString:l.text]; [blob appendString:@"\n"]; }
    NSString *s = blob.lowercaseString;

    struct { const char *needle; const char *hint; } rules[] = {
        {"no such file or directory: 'make'", "找不到 make：Theos 没装好，或 PATH 里没有 theos/bin。"},
        {"theos/makefiles", "THEOS 路径不对：找不到 Theos 的 makefiles 目录。"},
        {"sdk", "找不到 SDK：检查 SDK 名称是否与 theos/sdks 里的目录一致。"},
        {"logos", "Logos 预处理失败：检查 .x 文件里的 %hook/%orig 语法。"},
        {"error: expected", "C 语法错误：看上面第一个 error 行。"},
        {"fatal error: '", "头文件缺失：检查 SDK 或 vendor/include 是否包含对应头文件。"},
        {"ld: library not found", "链接不到库：检查 xxx_LIBRARIES 或 .tbd 是否在 SDK/vendor 里。"},
        {"undefined symbols", "缺少实现或库：看 undefined symbol 名字，补上对应框架/源文件。"},
        {"code signature", "签名失败：确认 ldid 可执行且路径有权限。"},
        {"permission denied", "权限不足：真机编译时项目目录需要在 /var/mobile 下且可写。"},
        {"killed", "进程被杀：多半是内存不足，试试关掉 -j 并行或改用远程/CI 构建。"},
        {"theos_package_scheme", "包格式参数问题：rootless 需要较新的 Theos。"},
    };
    for (size_t i = 0; i < sizeof(rules) / sizeof(rules[0]); i++) {
        if ([s rangeOfString:[NSString stringWithUTF8String:rules[i].needle]].location != NSNotFound) {
            return [NSString stringWithUTF8String:rules[i].hint];
        }
    }
    return nil;
}

#pragma mark - 执行

+ (SPSession *)buildProject:(SPProject *)project
                    options:(SPBuildOptions *)options
                    profile:(SPToolchainProfile *)profile
                     onLine:(void (^)(NSString *, SPLogLevel))onLine
                   onFinish:(void (^)(SPJob *))onFinish {
    SPJob *job = [SPJob new];
    job.projectPath = project.path;
    job.projectName = project.name;
    job.options = options;
    job.target = profile.target;
    job.state = SPJobStateRunning;

    NSMutableArray<SPLogLine *> *captured = [NSMutableArray array];

    NSString *script = [self scriptForProject:project options:options profile:profile
                                   backupPath:[project.path stringByAppendingPathComponent:@"_rb_backup"]];

    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    [env addEntriesFromDictionary:[profile extraEnvironment]];
    if (profile.target == SPBuildTargetRemote && profile.sshHost.length) {
        // 远程：生成一个压缩脚本，scp 过去再执行（避免嵌套 heredoc 引号地狱）
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"rb-%@.sh", [SPUtil timestampSlug]]];
        [script writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *remoteTmp = [NSString stringWithFormat:@"/tmp/rb-%@.sh", [SPUtil timestampSlug]];
        NSString *sshBase = [NSString stringWithFormat:@"-p %ld -o StrictHostKeyChecking=no -o ConnectTimeout=10",
                             (long)profile.sshPort];
        NSString *dest = [NSString stringWithFormat:@"%@@%@:%@", profile.sshUser, profile.sshHost, remoteTmp];
        NSMutableString *wrapped = [NSMutableString string];
        [wrapped appendString:[NSString stringWithFormat:@"scp %@ %@ %@ && ssh %@ %@@%@ 'sh %@; ec=$?; rm -f %@; exit $ec'\n",
                              sshBase, [SPUtil shellQuote:tmp], [SPUtil shellQuote:dest],
                              sshBase, profile.sshUser, profile.sshHost, remoteTmp, remoteTmp]];
        [wrapped appendString:[NSString stringWithFormat:@"rc=$?; rm -f %@; exit $rc\n", [SPUtil shellQuote:tmp]]];
        script = wrapped;
    }

    SPSession *session = [[SPSession alloc] initWithEnvironment:env workingDirectory:project.path];
    // 编译是最需要 root 的一步：非 root 且系统支持 persona 时，
    // 让子进程单独以 root 跑，父进程身份不动（迁移自 TrollAgent 的托管 spawn）。
    session.childIdentity = [SPProcessGuard shared].preferredIdentity;

    // 16KB 行内的高亮判断
    session.onLine = ^(NSString *line, SPLogLevel level) {
        SPLogLevel lv = level;
        NSString *low = line.lowercaseString;
        if ([low rangeOfString:@"error:"].location != NSNotFound || [low rangeOfString:@"错误"].location != NSNotFound)
            lv = SPLogLevelErr;
        else if ([line hasPrefix:@"==>"] || [line hasPrefix:@"[ok]"] || [line hasPrefix:@"[!]"])
            lv = SPLogLevelStep;
        @synchronized (captured) { [captured addObject:[SPLogLine lineWithText:line level:lv]]; }
        if (onLine) onLine(line, lv);
    };

    session.onFinish = ^(SPCommandResult *r) {
        job.finishedAt = [NSDate date];
        job.exitCode = r.exitCode;
        @synchronized (captured) { job.lines = [captured copy]; }

        if (r.cancelled) job.state = SPJobStateCancelled;
        else if (r.ok) job.state = SPJobStateSucceeded;
        else job.state = SPJobStateFailed;

        if (job.state == SPJobStateFailed) {
            job.failureHint = r.launchError.localizedDescription ?: [self diagnoseFailureFromLines:job.lines];
            if (r.launchError && onLine) onLine(r.launchError.localizedDescription, SPLogLevelErr);
            if (!job.failureHint) job.failureHint = @"编译失败，请查看上方最后几行 error 输出。";
        }

        NSArray *arts = [self collectArtifactsInProject:project.path since:job.startedAt options:options];
        job.artifacts = arts;
        for (NSString *a in arts) {
            if ([a hasSuffix:@".deb"] || [a hasSuffix:@".app"] || [a hasSuffix:@".tipa"]) { job.bundlePath = a; break; }
        }
        if (!job.bundlePath && arts.count) job.bundlePath = arts.firstObject;

        if (onFinish) onFinish(job);
    };

    [session runShell:script];
    return session;
}

+ (void)cancelSession:(SPSession *)session { [session cancel]; }

@end
