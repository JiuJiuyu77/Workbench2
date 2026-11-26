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
