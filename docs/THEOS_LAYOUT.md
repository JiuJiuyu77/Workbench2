# 内置 Theos 目录说明

包里为什么有两套 `theos` 目录，各自是什么，改哪一份。

## 目录分工

```
Workbench.app/Toolchain/
├── theos-full/          # 上游 Theos 本体：makefiles、bin、include、lib
│   ├── makefiles/       # 构建规则（common.mk / tweak.mk / library.mk …）
│   ├── bin/             # logos.pl 等脚本
│   └── include/
├── theos-root/          # 工具链（Darwin 二进制，跑在设备上）
│   ├── usr/bin/         # clang-16、ld64、ldid、make、perl
│   └── usr/lib/llvm-16/ # libLLVM-16.dylib 等
├── ollvm/               # Arkari OLLVM 16.0.6（irobf passes）
├── reverse/             # radare2 / r2ghidra / mt-macho / mt-inject-dylib
├── swift-toolchain/     # Swift 6.4.3（usr/bin/swiftc、clang-21）
└── sdks/iPhoneOS16.5.sdk
```

- `SPToolchainInstaller.theosPath` 选的是 **theos-full**（判据是 `makefiles/common.mk` 存在）。构建时 `export THEOS=theos-full`。
- `theos-root` 只提供可执行文件与库，通过 `PATH` / `DYLD_LIBRARY_PATH` 注入，不作为 `THEOS`。

## 为什么不是一份

上游 Theos 是「规则 + 脚本」，不含能在 iOS 上跑的编译器；Rein/dylix 那套运行时把「规则」和「Darwin 工具链」分别打成 `theos-full` / `theos-root` 两个目录。合成一份会让升级时互相覆盖：
- 升级规则 → 只该动 `theos-full/makefiles`、`theos-full/bin`
- 升级编译器 → 只该动 `theos-root/usr/*`

## 升级方式（当前做法）

1. **规则**：CI 每轮把 `theos-full/{makefiles,bin}` 换成上游 `theos/theos` 最新（固定 commit `8167f59d`，见 `.github/workflows/build.yml` 的「刷新 Theos makefiles」）。
2. **编译器**：优先用 `swift-toolchain/usr/bin/clang`（Swift 6.4.3 自带 clang-21），缺失时回落 `theos-root/usr/bin/clang-16`。
3. **OLLVM**：`ollvm/` 为 Arkari 16.0.6（irobf 系列 pass）。上游 `eshard/obfuscator-llvm` 无 release，分支停在 LLVM 16，暂无可替换的新版本。
4. **Swift**：`.github/workflows/swift-toolchain.yml` 一条命令从 swift.org 官方 pkg 产出 `SwiftToolchain.tar.gz`（tag `swift-<版本>`）。

## 相关文件

- `App/SPToolchainInstaller.m`：`theosPath`、`runtimeEnvironment`（PATH 顺序）
- `App/SPBuilder.m`：构建脚本里的 `THEOS` / `SDK` 判定
- `scripts/prune_toolchain.py`：打包前裁剪
