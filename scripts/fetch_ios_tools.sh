#!/usr/bin/env bash
# 从 Procursus（iOS arm64 软件源）抓取可与 Theos 配套的工具，解包进内置工具链。
# 只在 CI 里跑；任一包失败都不阻断构建（保留包内原有版本）。
set -uo pipefail
TC="${1:-BundledToolchain}"
DEST="$TC/ios-tools"
mkdir -p "$DEST"
BASE="https://apt.procursus.io/dists/ios/main/binary-iphoneos-arm64"
IDX="/tmp/procursus-Packages"

fetch_index() {
  for f in Packages.gz Packages.xz Packages.zst Packages; do
    case "$f" in
      *.gz)  ext=gz ;;
      *.xz)  ext=xz ;;
      *.zst) ext=zst ;;
      *)     ext="" ;;
    esac
    if curl -fsSL --max-time 120 -o "/tmp/pkg.$ext" "$BASE/$f"; then
      case "$ext" in
        gz)  gunzip -c "/tmp/pkg.gz"  > "$IDX" ;;
        xz)  xz -dc "/tmp/pkg.xz"     > "$IDX" 2>/dev/null ;;
        zst) zstd -dc "/tmp/pkg.zst"  > "$IDX" 2>/dev/null || python3 - <<'PY' > "$IDX"
import sys
try:
    import zstandard as z
except ImportError:
    sys.exit(1)
sys.stdout.buffer.write(z.ZstdDecompressor().decompress(open('/tmp/pkg.zst','rb').read()))
PY
        ;;
        *)   cp "/tmp/pkg" "$IDX" ;;
      esac
      [ -s "$IDX" ] && { echo "index: $BASE/$f"; return 0; }
    fi
  done
  return 1
}

fetch_index || { echo "warn: Procursus 索引不可达，跳过 iOS 工具更新"; exit 0; }

# 包名 → 需要从包里取出的路径
want="perl make dpkg cctools tapi llvm"
for pkg in $want; do
  entry="$(awk -v p="$pkg" '
    BEGIN{RS="";FS="\n"}
    { n=""; v=""; fn=""; for(i=1;i<=NF;i++){split($i,a,": "); if(a[1]=="Package")n=a[2]; if(a[1]=="Filename")fn=a[2]; if(a[1]=="Version")v=a[2]}
      if(n==p){print fn"\t"v} }' "$IDX" | head -1)"
  [ -n "$entry" ] || { echo "  skip $pkg（索引里没有）"; continue; }
  rel="${entry%%$'\t'*}"; ver="${entry##*$'\t'}"
  url="https://apt.procursus.io/$rel"
  echo "== $pkg $ver"
  if ! curl -fsSL --max-time 300 -o "/tmp/$pkg.deb" "$url"; then
    echo "  warn: 下载失败 $url"; continue
  fi
  rm -rf "/tmp/x-$pkg" && mkdir -p "/tmp/x-$pkg"
  ( cd "/tmp/x-$pkg" && ar x "/tmp/$pkg.deb" 2>/dev/null )
  data="$(ls "/tmp/x-$pkg"/data.tar.* 2>/dev/null | head -1)"
  if [ -n "$data" ]; then
    case "$data" in
      *.zst) zstd -dc "$data" | tar xf - -C "/tmp/x-$pkg/root" 2>/dev/null || true ;;
      *) tar xf "$data" -C "/tmp/x-$pkg/root" 2>/dev/null || true ;;
    esac
  fi
  mkdir -p "/tmp/x-$pkg/root"
  # data.tar 先解到 root/（tar 需要目录存在）
  if [ ! -d "/tmp/x-$pkg/root/usr" ]; then
    if [ -n "$data" ]; then
      case "$data" in
        *.zst) zstd -dc "$data" | ( mkdir -p "/tmp/x-$pkg/root" && tar xf - -C "/tmp/x-$pkg/root" ) 2>/dev/null || true ;;
        *) ( mkdir -p "/tmp/x-$pkg/root" && tar xf "$data" -C "/tmp/x-$pkg/root" ) 2>/dev/null || true ;;
      esac
    fi
  fi
  if [ -d "/tmp/x-$pkg/root/usr" ]; then
    cp -R "/tmp/x-$pkg/root/usr/." "$DEST/" 2>/dev/null
    echo "  installed -> ios-tools/usr"
  else
    echo "  warn: 包里没有 usr/"
  fi
done

chmod -R u+rwX,go+rX "$DEST" 2>/dev/null || true
for d in bin sbin usr/bin usr/sbin usr/libexec; do
  [ -d "$DEST/$d" ] && find "$DEST/$d" -type f -exec chmod +x {} + 2>/dev/null || true
done
echo "---- ios-tools ----"
ls "$DEST/usr/bin" 2>/dev/null | head -20 || true
for t in perl make dpkg-deb ldid tapi; do
  p="$DEST/usr/bin/$t"; [ -x "$p" ] && echo "  OK  $t" || echo "  MISS $t"
done
