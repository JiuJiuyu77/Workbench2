#!/usr/bin/env bash
# 把 ldid / Orion / ccache 补进内置工具链（在 CI 里 BundledToolchain 展开之后调用）。
set -euo pipefail
TC="${1:-BundledToolchain}"

# ldid：Procursus 官方 iphoneos-arm64 最新版
curl -L --retry 3 -o /tmp/ldid https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus8/ldid_iphoneos_arm64
chmod +x /tmp/ldid
mkdir -p "$TC/theos-root/usr/bin" "$TC/bin"
cp /tmp/ldid "$TC/theos-root/usr/bin/ldid"
cp /tmp/ldid "$TC/bin/ldid"
echo "ldid: $(/tmp/ldid -v 2>&1 | head -1 || echo installed)"

# Orion：theos 官方纯 Swift tweak 框架
curl -L --retry 3 -o /tmp/orion.zip https://github.com/theos/orion/releases/download/1.0.2/Orion_1.0.2.zip
rm -rf "$TC/orion"
mkdir -p "$TC/orion"
unzip -q /tmp/orion.zip -d "$TC/orion"
ls "$TC/orion" | head -5

# ccache：darwin arm64 预编译
curl -L --retry 3 -o /tmp/ccache.tar.gz https://github.com/ccache/ccache/releases/download/v4.14.3/ccache-4.14.3-darwin.tar.gz
rm -rf /tmp/ccache && mkdir -p /tmp/ccache
tar xzf /tmp/ccache.tar.gz -C /tmp/ccache
CCBIN="$(find /tmp/ccache -name ccache -type f | head -1)"
cp "$CCBIN" "$TC/ccache"
chmod +x "$TC/ccache"

# ccache 包装器：Theos 直接调 clang 时命中缓存
mkdir -p "$TC/bin-ccache"
for name in clang clang++ cc c++; do
  if [ -x "$TC/swift-toolchain/usr/bin/$name" ]; then
    real="swift-toolchain/usr/bin/$name"
  else
    real="theos-root/usr/bin/clang"
  fi
  printf '#!/bin/sh\nTC=$(cd "$(dirname "$0")/.." && pwd)\nexec "$TC/ccache" "$TC/%s" "$@"\n' "$real" > "$TC/bin-ccache/$name"
  chmod +x "$TC/bin-ccache/$name"
done
"$TC/bin-ccache/clang" --version 2>&1 | head -2 || true

# ---------------------------------------------------------------------------
# dylix（CodexApp-Runtime）按需组件：内嵌进来，运行时不再下载
# coretools=git/curl/jq/patch/zip…, buildtools=cmake/ninja, python, node,
# reverse=radare2/ghidra, ollvm=Arkari LLVM 23.1.1（比包内 16.0.6 新）
# ---------------------------------------------------------------------------
RT="https://github.com/susu123oss/CodexApp-Runtime/releases/download"
embed_component() {
  local id="$1" url="$2"
  curl -L --retry 3 --max-time 900 -o "/tmp/$id.tgz" "$url" || { echo "  warn: $id 下载失败"; return 0; }
  rm -rf "$TC/$id"
  mkdir -p "$TC/$id"
  tar xzf "/tmp/$id.tgz" -C "$TC/$id" || { echo "  warn: $id 解包失败"; return 0; }
  chmod -R u+rwX,go+rX "$TC/$id" 2>/dev/null || true
  find "$TC/$id" -type f \( -perm -u+x -o -name '*.dylib' \) -exec chmod +x {} + 2>/dev/null || true
  echo "  embedded $id ($(du -sh "$TC/$id" | cut -f1))"
}

embed_component coretools  "$RT/runtime-core-tools-a7e97567217a/CoreToolsRuntime.tar.gz"
# buildtools(cmake/ninja) / python / node 与设备端编译无关，不内嵌
embed_component reverse    "$RT/runtime-reverse-tools-9d3ca9ea3340/ReverseToolsRuntime.tar.gz"
embed_component ollvm      "$RT/runtime-ollvm-23.1.1-e54f2878240e/OLLVMRuntime.tar.gz"

# OLLVM 23 与 Arkari 16 目录结构一致（bin/clang, lib/clang/23），直接使用
if [ -x "$TC/ollvm/bin/clang" ]; then
  echo "  ollvm: $("$TC/ollvm/bin/clang" --version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# 链接器：clang 23 配 Apple ld64-951.9 太旧，改用 Swift 6.4.3 自带的 ld64.lld（LLVM 21）
# shim 负责过滤 Apple ld64 专有参数（-adhoc_codesign 由 ldid 补签）
# ---------------------------------------------------------------------------
if [ -x "$TC/swift-toolchain/usr/bin/ld64.lld" ]; then
  mkdir -p "$TC/bin-lld"
  for name in ld ld64; do
    cat > "$TC/bin-lld/$name" <<'SHIM'
#!/bin/bash
# 过滤 Apple ld64 专有参数后转交 ld64.lld（LLVM 21）
out=()
for a in "$@"; do
  case "$a" in
    -adhoc_codesign) continue ;;
    -Wl,-adhoc_codesign) continue ;;
  esac
  out+=("$a")
done
exec "$(cd "$(dirname "$0")/.." && pwd)/swift-toolchain/usr/bin/ld64.lld" "${out[@]}"
SHIM
    chmod +x "$TC/bin-lld/$name"
  done
  echo "  ld64.lld: $("$TC/swift-toolchain/usr/bin/ld64.lld" --version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# 移除 theos 自带的旧 clang-16（默认前端已换成 clang 23）
# 保留 ld64-951.9 仅作最后兜底，但不再进 PATH 前部
# ---------------------------------------------------------------------------
for f in clang-16 clang++-16 clang-cpp-16; do
  rm -f "$TC/theos-root/usr/bin/$f" 2>/dev/null || true
done
echo "clang-16 removed: $([ -e "$TC/theos-root/usr/bin/clang-16" ] && echo no || echo yes)"
