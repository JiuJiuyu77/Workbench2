#!/usr/bin/env python3
"""Trim the bundled toolchain before it is copied into the app.

Everything stays offline-capable; we only drop tools that the Theos build never
invokes (Swift SIL debug utilities, sourcekit, docs/tests) and collapse the
duplicated OLLVM clang++ binary into a symlink.

Usage: python3 scripts/prune_toolchain.py <BundledToolchain>
"""
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'BundledToolchain')
if not root.is_dir():
    raise SystemExit('missing toolchain root: %s' % root)

removed = 0
freed = 0


def drop(path: Path):
    global removed, freed
    if path.is_dir() and not path.is_symlink():
        size = sum(f.stat().st_size for f in path.rglob('*')
                   if f.is_file() and not f.is_symlink())
        shutil.rmtree(path, ignore_errors=True)
    elif path.exists() or path.is_symlink():
        try:
            size = path.stat().st_size
        except OSError:
            size = 0
        path.unlink(missing_ok=True)
    else:
        return
    removed += 1
    freed += size


swift_bin = root / 'swift-toolchain/usr/lib/llvm-16/bin'
if swift_bin.is_dir():
    # SIL 调试工具每个都是 ~150MB 的独立二进制，Theos 构建从不调用。
    keep = {'swift', 'swiftc', 'swift-frontend', 'swift-driver', 'swift-autolink-extract',
            'swift-demangle', 'swift-ide-test', 'sdk-module-lists'}
    droppable_prefixes = ('sil-', 'sourcekitd', 'lldb')
    droppable_names = {'repl_swift', 'swift-api-digester', 'swift-api-checker.py',
                       'swift-api-dump.py', 'swift-symbolgraph-extract',
                       'swift-package', 'swift-build', 'swift-test', 'swift-run'}
    for entry in list(swift_bin.iterdir()):
        if entry.name in keep:
            continue
        if entry.name.startswith(droppable_prefixes) or entry.name in droppable_names:
            drop(entry)

# Theos 仓库里的文档/测试/示例与构建无关。
for name in ['docs', 'tests', 'examples', 'html', 'assets', '.git', '.github']:
    drop(root / 'theos-full' / name)

# OLLVM 的 clang++ 与 clang 是同一份 80MB 二进制；clang 按 argv[0] 分派。
ollvm_bin = root / 'ollvm/bin'
clang = ollvm_bin / 'clang'
clangxx = ollvm_bin / 'clang++'
if clang.is_file() and clangxx.exists() and not clangxx.is_symlink():
    size = clangxx.stat().st_size
    clangxx.unlink()
    clangxx.symlink_to('clang')
    freed += size
    removed += 1

total = sum(f.stat().st_size for f in root.rglob('*') if f.is_file() and not f.is_symlink())
print('prune: removed %d entries, freed %.1f MB, toolchain now %.1f MB'
      % (removed, freed / 1048576.0, total / 1048576.0))
