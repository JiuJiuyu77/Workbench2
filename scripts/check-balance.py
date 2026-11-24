#!/usr/bin/env python3
"""括号平衡体检：只去掉注释和字符串再数括号。

比正则版本靠谱：能正确处理 @"..." 里的方括号、'\\'' 这种转义、
以及 #import 后面的 <UIKit/UIKit.h>（尖括号不参与统计）。
"""
import sys
import glob


def strip_noise(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        c = src[i]
        if c == '"':
            out.append('""')
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "'":
            out.append("''")
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def check(path: str) -> bool:
    cleaned = strip_noise(open(path, encoding='utf-8').read())
    ok = True
    for opener, closer, name in (('{', '}', '花括号'), ('(', ')', '圆括号'), ('[', ']', '方括号')):
        a, b = cleaned.count(opener), cleaned.count(closer)
        if a != b:
            print(f'{path}: {name} 不平衡 {a} vs {b}')
            ok = False
    return ok


def main(patterns) -> int:
    files = []
    for pat in patterns:
        files.extend(sorted(glob.glob(pat)))
    if not files:
        print('没有匹配到文件')
        return 1
    bad = sum(0 if check(p) else 1 for p in files)
    print(f'检查 {len(files)} 个文件，{bad} 个不平衡')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:] or ['Native/ObjC/*.m', 'Native/ObjC/*.h']))
