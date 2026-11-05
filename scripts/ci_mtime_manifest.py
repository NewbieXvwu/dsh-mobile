#!/usr/bin/env python3
"""保存 / 恢复源码 mtime 清单，让 GitHub Actions 上的 Xcode 增量编译生效。

背景：每次 checkout 都会把源文件 mtime 刷成"现在"，比缓存恢复出来的 DerivedData
产物更新，于是 Xcode 判定全部需要重编（65 个 Swift 文件 → 2 分钟）。曾用
`touch -t 202001010101` 粗暴回拨，但那会把**这一轮真正改动过的文件**也压旧，
导致跑的是缓存里的旧二进制（run 41849455825 已踩到）。

正确做法：清单里同时记录 mtime 与内容哈希；恢复时**只回拨内容未变的文件**，
内容变了的文件保留新 mtime，照常重编。

用法：
    ci_mtime_manifest.py save  <root> <manifest>
    ci_mtime_manifest.py apply <root> <manifest>
"""
import hashlib
import os
import sys

SKIP_DIRS = {".git", "build", "DerivedData", ".gradle", "node_modules", ".build"}
EXTS = {".swift", ".kt", ".kts", ".h", ".m", ".mm", ".c", ".cpp", ".plist", ".json",
        ".xcconfig", ".pbxproj", ".xcscheme", ".metal", ".storyboard", ".xib", ".strings"}


def digest(path):
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk(root):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if os.path.splitext(name)[1] not in EXTS:
                continue
            full = os.path.join(base, name)
            if os.path.islink(full):
                continue
            yield full


def save(root, manifest):
    rows = []
    for full in walk(root):
        rel = os.path.relpath(full, root)
        try:
            rows.append(f"{int(os.stat(full).st_mtime)}\t{digest(full)}\t{rel}\n")
        except OSError:
            continue
    with open(manifest, "w", encoding="utf-8") as fh:
        fh.writelines(rows)
    print(f"[mtime] saved {len(rows)} entries -> {manifest}")


def apply(root, manifest):
    if not os.path.exists(manifest):
        print(f"[mtime] no manifest at {manifest}; leaving checkout mtimes as-is")
        return
    restored = kept = 0
    with open(manifest, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            stamp, want, rel = parts
            full = os.path.join(root, rel)
            if not os.path.isfile(full):
                continue
            try:
                if digest(full) != want:
                    kept += 1
                    continue
                os.utime(full, (int(stamp), int(stamp)))
                restored += 1
            except OSError:
                continue
    print(f"[mtime] replayed {restored} unchanged mtimes, kept {kept} changed files fresh")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in {"save", "apply"}:
        sys.exit(__doc__)
    {"save": save, "apply": apply}[sys.argv[1]](sys.argv[2], sys.argv[3])
