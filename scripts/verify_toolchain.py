#!/usr/bin/env python3
"""检查 Workbench 包内 Toolchain 是否完整、可执行位是否正确。

用法：
    python3 scripts/verify_toolchain.py <ipa | Workbench.app | Toolchain目录>

支持：
    · .ipa / .zip       直接读中央目录，不落盘
    · .app 目录         直接看文件
    · Toolchain 目录    直接看文件

退出码：0 = 全部通过；1 = 有 FAIL。
"""

import os
import sys
import zipfile

# Toolchain 里的必需项（相对 Toolchain/）
REQUIRED_FILES = [
    'theos-full/makefiles/common.mk',
    'theos-full/bin/logos.pl',
    'theos-root/usr/bin/make',
    'theos-root/usr/bin/perl',
    'theos-root/usr/bin/ldid',
    'ollvm/bin/clang',
    'reverse/bin/mt-macho',
    'swift-toolchain/usr/bin/swiftc',
    'helpers/bash',
]
# 至少要有一个（二选一存在即通过）
ALTERNATIVES = [
    ('bin-lld/ld64', 'bin-lld/ld64'),
]
SDK_HINTS = ['sdks', 'theos-full/sdks', 'theos-root/theos/sdks']
MACHO_MAGICS = {
    b'\xcf\xfa\xed\xfe': 'Mach-O 64',
    b'\xce\xfa\xed\xfe': 'Mach-O 32',
    b'\xca\xfe\xba\xbe': 'Fat',
    b'\xbe\xba\xfe\xca': 'Fat(le)',
}
# 应当是 Mach-O 的项（脚本类如 logos.pl / perl 脚本除外）
MACHO_REQUIRED = [
    'ollvm/bin/clang',
    'swift-toolchain/usr/bin/swiftc',
    'helpers/bash',
    'reverse/bin/mt-macho',
]


def fail(msg):
    print('FAIL  %s' % msg)
    return 1


def ok(msg):
    print('ok    %s' % msg)
    return 0


def detect_root(arg):
    """返回 (kind, base_prefix, zipfile_or_None)。kind: zip|dir"""
    if os.path.isdir(arg):
        base = arg
        if os.path.basename(base) == 'Toolchain':
            return 'dir', base, None
        cand = os.path.join(base, 'Toolchain')
        if os.path.isdir(cand):
            return 'dir', cand, None
        raise SystemExit('目录里没有 Toolchain：%s' % arg)
    if not zipfile.is_zipfile(arg):
        raise SystemExit('不是压缩包也没有 Toolchain 目录：%s' % arg)
    zf = zipfile.ZipFile(arg)
    names = zf.namelist()
    for prefix in ('Payload/Workbench.app/Toolchain/', 'Workbench.app/Toolchain/'):
        if any(n.startswith(prefix) for n in names):
            return 'zip', prefix.rstrip('/'), zf
    raise SystemExit('压缩包里没有 Payload/Workbench.app/Toolchain')


class View(object):
    """统一 zip / 目录两种来源的只读视图。"""

    def __init__(self, kind, base, zf):
        self.kind, self.base, self.zf = kind, base, zf

    def exists(self, rel):
        p = self.base + '/' + rel
        if self.kind == 'zip':
            return p in self.zf.namelist()
        return os.path.exists(os.path.join(self.base, rel))

    def read_head(self, rel, n=8):
        if self.kind == 'zip':
            with self.zf.open(self.base + '/' + rel) as fh:
                return fh.read(n)
        with open(os.path.join(self.base, rel), 'rb') as fh:
            return fh.read(n)

    def size(self, rel):
        if self.kind == 'zip':
            return self.zf.getinfo(self.base + '/' + rel).file_size
        return os.path.getsize(os.path.join(self.base, rel))

    def executable(self, rel):
        if self.kind == 'zip':
            info = self.zf.getinfo(self.base + '/' + rel)
            mode = (info.external_attr >> 16) & 0o777
            return 0 if mode == 0 else bool(mode & 0o111)
        return os.access(os.path.join(self.base, rel), os.X_OK)

    def listdir_prefix(self, rel):
        prefix = self.base + '/' + rel.rstrip('/') + '/'
        if self.kind == 'zip':
            out = set()
            for name in self.zf.namelist():
                if name.startswith(prefix):
                    rest = name[len(prefix):].split('/')[0]
                    if rest:
                        out.add(rest)
            return sorted(out)
        d = os.path.join(self.base, rel)
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def count(self):
        if self.kind == 'zip':
            return sum(1 for n in self.zf.namelist() if n.startswith(self.base + '/'))
        total = 0
        for _, _, files in os.walk(self.base):
            total += len(files)
        return total


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    kind, base, zf = detect_root(argv[1])
    v = View(kind, base, zf)
    problems = 0

    print('== Toolchain 位置：%s（%s）' % (base, kind))
    print('== 条目数：%d' % v.count())

    for rel in REQUIRED_FILES:
        if not v.exists(rel):
            problems += fail('缺少 %s' % rel)
        else:
            problems += ok('存在 %s' % rel)

    for group in ALTERNATIVES:
        if any(v.exists(r) for r in group):
            problems += ok('链接器 %s' % ' / '.join(group))
        else:
            problems += fail('缺少链接器（%s）' % ' / '.join(group))

    # SDK
    sdk_found = []
    for hint in SDK_HINTS:
        for name in v.listdir_prefix(hint):
            if name.startswith('iPhoneOS') and name.endswith('.sdk'):
                settings = hint + '/' + name + '/SDKSettings.json'
                plist = hint + '/' + name + '/SDKSettings.plist'
                if v.exists(settings) or v.exists(plist):
                    sdk_found.append(name)
    if sdk_found:
        problems += ok('SDK：%s' % ', '.join(sorted(set(sdk_found))))
    else:
        problems += fail('找不到任何带 SDKSettings 的 iPhoneOS*.sdk')

    # Mach-O 与执行位
    for rel in MACHO_REQUIRED:
        if not v.exists(rel):
            continue
        head = v.read_head(rel, 4)
        kind_name = MACHO_MAGICS.get(head)
        if kind_name:
            problems += ok('%s 是 %s（%.1f MB）' % (rel, kind_name, v.size(rel) / 1048576.0))
        else:
            problems += fail('%s 不是 Mach-O（magic=%r）' % (rel, head))
        if not v.executable(rel):
            problems += fail('%s 没有执行位' % rel)

    # Theos makefiles 数量（上游一整套是 80+ 个 .mk）
    mk = 0
    if kind == 'zip':
        mk = sum(1 for n in zf.namelist()
                 if n.startswith(base + '/theos-full/makefiles/') and n.endswith('.mk'))
    else:
        root_mk = os.path.join(base, 'theos-full/makefiles')
        if os.path.isdir(root_mk):
            mk = sum(1 for f in os.listdir(root_mk) if f.endswith('.mk'))
    print('info  Theos makefiles：%d 个 .mk' % mk)
    if mk < 20:
        problems += fail('Theos makefiles 不完整（只有 %d 个 .mk）' % mk)

    # 可选组件统计
    for sub in ('ollvm', 'reverse', 'swift-toolchain', 'ios-tools', 'sdks', 'coretools'):
        if v.exists(sub):
            print('info  %-16s %d 项' % (sub, len(v.listdir_prefix(sub))))

    print('== 结果：%s（问题 %d 项）' % ('PASS' if problems == 0 else 'FAIL', problems))
    return 0 if problems == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
