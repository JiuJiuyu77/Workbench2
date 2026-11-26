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
embed_component buildtools "$RT/runtime-build-tools-3.27.9-fb0f29cea7b2/BuildToolsRuntime.tar.gz"
embed_component python     "$RT/runtime-python-3.13.14-3c834a2c8964/PythonRuntime.tar.gz"
embed_component node       "$RT/runtime-node-24.5.0-e3a6c25fac33/NodeRuntime.tar.gz"
embed_component reverse    "$RT/runtime-reverse-tools-9d3ca9ea3340/ReverseToolsRuntime.tar.gz"
embed_component ollvm      "$RT/runtime-ollvm-23.1.1-e54f2878240e/OLLVMRuntime.tar.gz"

# OLLVM 23 与 Arkari 16 目录结构一致（bin/clang, lib/clang/23），直接使用
if [ -x "$TC/ollvm/bin/clang" ]; then
  echo "  ollvm: $("$TC/ollvm/bin/clang" --version 2>&1 | head -1)"
fi
