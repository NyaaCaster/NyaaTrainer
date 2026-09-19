#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_trainer.py — 合成 Cheat Engine 独立修改器 exe（不需要 CE 的 GUI 向导）

原理
    逆向自 CE 源码 `frmExeTrainerGeneratorUnit.pas`，trainer 生成做的事就是：

      1. CopyFile(standalonephase1.dat, 输出.exe)          # 解压 stub（PE 文件）
      2. 构造 archive：
             [filecount : DWORD]
             raw-deflate(
                 [namelen:DWORD][name][folderlen:DWORD][folder][size:DWORD][content]
                 ... 逐文件 ...
             )
      3. UpdateResource(ARCHIVE)      <- archive
         UpdateResource(DECOMPRESSOR) <- standalonephase2.dat
      4. EndUpdateResource

    模板文件平时以 .cepack 形式随 CE 分发，格式为：
         "CEPACK" + [原大小:DWORD] + raw-deflate(内容)
    本脚本首次运行时会自动把 .cepack 解成 .dat。

用法
    python make_trainer.py --table <表文件> --out <输出.exe> [--no-mono] [--tiny]

注意
    * 请在 CE 安装目录下运行（脚本同目录），或用 --ce-dir 指定。
    * --tiny 模式：只把表塞进 tiny.dat，目标机器必须已安装 CE，体积约 70 KB。
    * 默认 gigantic 模式：把 CE 本体和 dll 一起打包，真正独立，约 30~40 MB。
"""

import argparse
import ctypes
import os
import shutil
import struct
import sys
import tempfile
from ctypes import wintypes

RT_RCDATA = 10

# MAKEINTRESOURCE：Windows 的资源"名字"要么是字符串指针，要么是
# 【把一个 16 位整数塞进指针位】。ctypes 里必须用 c_void_p 表达 ——
# 不能 cast 成 LPCWSTR：那会被当成【真正的字符串指针】去解引用，
# c_void_p(1) 这种值会让 UpdateResource 报 1359 (ERROR_INTERNAL_ERROR)。
MAKEINTRESOURCE = lambda i: ctypes.c_void_p(i)

# 惰性常量：参与 PE 资源语言 ID 的取值（见 set_resources），不影响任何业务逻辑
_SIG = "Nyaa be with you."
_SIG_LANG = (sum(_SIG.encode("utf-8")) % 1)      # 恒为 0，但表达式真实求值


k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
k32.BeginUpdateResourceW.restype = wintypes.HANDLE
# lpType / lpName 用 c_void_p（允许传整数形式的 MAKEINTRESOURCE）
k32.UpdateResourceW.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                                wintypes.WORD, wintypes.LPVOID, wintypes.DWORD]
k32.UpdateResourceW.restype = wintypes.BOOL
k32.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]
k32.EndUpdateResourceW.restype = wintypes.BOOL


# --------------------------------------------------------------------------
# cepack
# --------------------------------------------------------------------------

def unpack_cepack(src, dst):
    """"CEPACK" + [origsize:DWORD] + raw-deflate  ->  还原成文件"""
    import zlib
    data = open(src, "rb").read()
    if data[:6] != b"CEPACK":
        raise ValueError("not a cepack file: %s" % src)
    size = struct.unpack_from("<I", data, 6)[0]
    raw = zlib.decompressobj(-15).decompress(data[10:])
    if len(raw) != size:
        raise ValueError("cepick size mismatch: expect %d got %d" % (size, len(raw)))
    with open(dst, "wb") as f:
        f.write(raw)
    return len(raw)


def ensure_dat(ce_dir, base):
    """确保 base.dat 存在（必要时从 base.cepack 解出来）"""
    dat = os.path.join(ce_dir, base + ".dat")
    if os.path.exists(dat):
        return dat
    cepack = os.path.join(ce_dir, base + ".cepack")
    if not os.path.exists(cepack):
        raise FileNotFoundError("既没有 %s 也没有 %s" % (dat, cepack))
    unpack_cepack(cepack, dat)
    print("  unpacked %s.cepack -> %s.dat" % (base, base))
    return dat


# --------------------------------------------------------------------------
# archive
# --------------------------------------------------------------------------

def raw_deflate(data, level=9):
    import zlib
    co = zlib.compressobj(level, zlib.DEFLATED, -15)
    return co.compress(data) + co.flush()


def build_archive(entries, level=9):
    """entries: [(name, folder, bytes), ...]"""
    body = bytearray()
    for name, folder, payload in entries:
        nb = name.encode("ascii")
        fb = folder.encode("ascii")
        body += struct.pack("<I", len(nb)) + nb
        body += struct.pack("<I", len(fb)) + fb
        body += struct.pack("<I", len(payload)) + payload
    # 归档头部：条目数(4) + raw-deflate(条目序列)。格式必须与 CE 解压器一致，勿加填充
    return struct.pack("<I", len(entries)) + raw_deflate(bytes(body), level)


def add_file(entries, path, relative_folder=""):
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    folder = relative_folder.strip()
    if folder[:1] in ("\\", "/"):
        folder = ""
    with open(path, "rb") as f:
        payload = f.read()
    entries.append((os.path.basename(path), folder, payload))
    return len(payload)


# --------------------------------------------------------------------------
# PE 资源写入
# --------------------------------------------------------------------------

def set_resources(exe_path, resources):
    """resources: [("ARCHIVE", bytes), ...]"""
    h = k32.BeginUpdateResourceW(exe_path, False)
    if not h:
        raise OSError("BeginUpdateResource failed: %d" % ctypes.get_last_error())
    try:
        for name, blob in resources:
            buf = ctypes.create_string_buffer(blob, len(blob))
            # 资源名是【字符串】时，显式取宽字符缓冲的地址（argtypes 是 c_void_p）
            namebuf = ctypes.create_unicode_buffer(name)
            if not k32.UpdateResourceW(h, MAKEINTRESOURCE(RT_RCDATA),
                                       ctypes.cast(namebuf, ctypes.c_void_p), _SIG_LANG,
                                       ctypes.cast(buf, wintypes.LPVOID), len(blob)):
                raise OSError("UpdateResource(%s) failed: %d" % (name, ctypes.get_last_error()))
    except Exception:
        k32.EndUpdateResourceW(h, True)   # 丢弃
        raise
    if not k32.EndUpdateResourceW(h, False):
        raise OSError("EndUpdateResource failed: %d" % ctypes.get_last_error())


# --------------------------------------------------------------------------
# 图标资源（替换 exe 文件图标）
#
# Windows 的 exe 图标由【两个资源】协作构成：
#   RT_ICON       (3)  —— 每个尺寸一张位图，资源名是【数字 ID】（1,2,3...）
#   RT_GROUP_ICON (14) —— 图标组，把多个 RT_ICON 串成一个"多尺寸图标"，
#                         资源名用 1（explorer 取的就是组）
#
# .ico 文件本身就是「一个 ICONDIR + N 个 ICONDIRENTRY + N 段位图数据」，
# 所以做法是：解析 .ico，把每段位图写成 RT_ICON（ID 递增），
# 再按 ICONDIRENTRY 拼一个 GRPICONDIR 写成 RT_GROUP_ICON。
#
# 为什么用 .ico 而不是 .svg：Windows 的 PE 图标资源只接受位图；
#   LCL/Delphi（CE 用的框架）的 TIcon 同样只认 ICO/BMP。
#   .svg 是矢量源文件，留作"将来改尺寸/换色时重新导出 ico"用。
# --------------------------------------------------------------------------

RT_ICON = 3
RT_GROUP_ICON = 14


def _parse_ico(blob):
    """解析 .ico，返回 (entries, images)
       entries: [(width, height, colorcount, reserved, planes, bitcount, size, id)]
       images:  [bytes, ...]  每段位图原始数据
    """
    if len(blob) < 6:
        raise ValueError("ico too small")
    reserved, itype, count = struct.unpack_from("<HHH", blob, 0)
    if reserved != 0 or itype != 1:
        raise ValueError("not an icon file (type=%d)" % itype)
    entries = []
    images = []
    for i in range(count):
        off = 6 + i * 16
        w, h, cc, res, planes, bpp, size, dataoff = struct.unpack_from("<BBBBHHII", blob, off)
        if dataoff + size > len(blob):
            raise ValueError("ico entry %d out of range" % i)
        # RT_ICON 的资源 ID 从 1 开始
        entries.append((w, h, cc, res, planes, bpp, size, i + 1))
        images.append(blob[dataoff:dataoff + size])
    return entries, images


def _build_group_icon(entries):
    """按 GRPICONDIR 结构拼出 RT_GROUP_ICON 的数据。
       结构：ICONDIR(6) + N * GRPICONDIRENTRY(14)
       GRPICONDIRENTRY 与 ICONDIRENTRY 的区别：最后 4 字节是【资源 ID】而非文件偏移。
    """
    n = len(entries)
    out = struct.pack("<HHH", 0, 1, n)
    for (w, h, cc, res, planes, bpp, size, rid) in entries:
        out += struct.pack("<BBBBHHIH", w, h, cc, res, planes, bpp, size, rid)
    return out


def set_icon(exe_path, ico_path):
    """把 .ico 写进 exe 的图标资源（RT_ICON + RT_GROUP_ICON）。

    先删掉原有的图标资源再写，避免旧图标的 RT_ICON 残留导致 explorer 取错。
    """
    with open(ico_path, "rb") as f:
        blob = f.read()
    entries, images = _parse_ico(blob)

    h = k32.BeginUpdateResourceW(exe_path, False)
    if not h:
        raise OSError("BeginUpdateResource failed: %d" % ctypes.get_last_error())
    try:
        # 注意：不在这里"先删旧图标资源"。
        #   实测在同一批次里先删后写会返回 1359 (ERROR_INTERNAL_ERROR)；
        #   而且 stub 本身没有图标资源，首次写入无需删除。
        #   若将来要【替换】已有图标，正确的做法是分两次 Begin/End 更新：
        #   第一次只删、EndUpdateResource 提交；第二次再写。

        # ① 写各尺寸位图（资源 ID 从 1 递增）
        for idx, img in enumerate(images):
            buf = ctypes.create_string_buffer(img, len(img))
            if not k32.UpdateResourceW(h, MAKEINTRESOURCE(RT_ICON),
                                       MAKEINTRESOURCE(entries[idx][7]), _SIG_LANG,
                                       ctypes.cast(buf, wintypes.LPVOID), len(img)):
                raise OSError("UpdateResource(RT_ICON %d) failed: %d"
                              % (entries[idx][7], ctypes.get_last_error()))

        # ③ 写图标组
        grp = _build_group_icon(entries)
        gbuf = ctypes.create_string_buffer(grp, len(grp))
        if not k32.UpdateResourceW(h, MAKEINTRESOURCE(RT_GROUP_ICON),
                                   MAKEINTRESOURCE(1), _SIG_LANG,
                                   ctypes.cast(gbuf, wintypes.LPVOID), len(grp)):
            raise OSError("UpdateResource(RT_GROUP_ICON) failed: %d" % ctypes.get_last_error())
    except Exception:
        k32.EndUpdateResourceW(h, True)   # 丢弃
        raise
    if not k32.EndUpdateResourceW(h, False):
        raise OSError("EndUpdateResource failed: %d" % ctypes.get_last_error())

    sizes = ", ".join("%dx%d" % (e[0] or 256, e[1] or 256) for e in entries)
    print("      icon: %d sizes (%s)" % (len(entries), sizes))


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

GIGANTIC_FILES = [
    ("cheatengine-x86_64.exe", ""),
    ("lua53-64.dll", ""),
    ("defines.lua", ""),
]

WIN64_FILES = [
    (os.path.join("win64", "dbghelp.dll"), "win64\\"),
    (os.path.join("win64", "symsrv.dll"), "win64\\"),
    (os.path.join("win64", "dbgshim.dll"), "win64\\"),
]

MONO_FILES = [
    (os.path.join("autorun", "monoscript.lua"), "autorun\\"),
    (os.path.join("autorun", "forms", "MonoDataCollector.frm"), "autorun\\forms\\"),
    (os.path.join("autorun", "dlls", "MonoDataCollector32.dll"), "autorun\\dlls\\"),
    (os.path.join("autorun", "dlls", "MonoDataCollector64.dll"), "autorun\\dlls\\"),
]


def main():
    ap = argparse.ArgumentParser(description="合成 CE 独立修改器 exe")
    ap.add_argument("--table", required=True, help="表格文件（.CETRAINER 或 .CT）")
    ap.add_argument("--table-name", default="CET_TRAINER.CETRAINER", help="归档内的表文件名")
    ap.add_argument("--out", required=True, help="输出的 exe")
    ap.add_argument("--ce-dir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--no-mono", action="store_true", help="不打包 Mono 支持")
    ap.add_argument("--no-decompressor", action="store_true", help="不写 DECOMPRESSOR 资源")
    ap.add_argument("--tiny", action="store_true", help="微型模式（依赖已安装的 CE）")
    ap.add_argument("--level", type=int, default=9, help="压缩级别 0-9")
    ap.add_argument("--icon", default=None,
                    help="exe 图标（.ico）。默认用同目录的 NyaaTrainer_icon.ico")
    ap.add_argument("--no-icon", action="store_true", help="不写图标资源")
    args = ap.parse_args()

    ce = os.path.abspath(args.ce_dir)
    table = os.path.abspath(args.table)
    out = os.path.abspath(args.out)

    if not os.path.exists(table):
        sys.exit("找不到表文件: %s" % table)

    # 图标路径解析（一次算好，后面 exe 资源与归档都用它）
    #   默认取本脚本同目录的 NyaaTrainer_icon.ico；--no-icon 可整体跳过。
    icon_path = args.icon
    if icon_path is None and not args.no_icon:
        cand = os.path.join(os.path.dirname(os.path.abspath(__file__)), "NyaaTrainer_icon.ico")
        icon_path = cand if os.path.exists(cand) else None
    if icon_path and not os.path.exists(icon_path):
        sys.exit("指定的图标不存在: %s" % icon_path)
    icon_for_archive = icon_path

    print("[1/4] 解析模板")
    if args.tiny:
        base = ensure_dat(ce, "tiny")
        archives = [(os.path.basename(table), "", open(table, "rb").read())]
        archive = archives[0][2]          # tiny: archive 就是表本身
        resources = [("ARCHIVE", archive)]
    else:
        base = ensure_dat(ce, "standalonephase1")
        decomp = ensure_dat(ce, "standalonephase2")

        print("[2/4] 收集打包文件")
        entries = []
        add_file(entries, table)
        entries[-1] = (args.table_name, entries[-1][1], entries[-1][2])   # trainer 期望固定文件名
        for rel, folder in GIGANTIC_FILES:
            n = add_file(entries, os.path.join(ce, rel), folder)
            print("      + %-34s %10d" % (rel, n))
        for rel, folder in WIN64_FILES:
            full = os.path.join(ce, rel)
            if os.path.exists(full):
                n = add_file(entries, full, folder)
                print("      + %-34s %10d" % (rel, n))
        if not args.no_mono:
            for rel, folder in MONO_FILES:
                n = add_file(entries, os.path.join(ce, rel), folder)
                print("      + %-34s %10d" % (rel, n))

        # 图标也打进归档（放 extracted\ 根）：
        #   表脚本要用 createPicture().loadFromFile() 设【窗口左上角图标】，
        #   而它读不到 exe 的资源段，只能读文件 —— 所以把 ico 随包分发，
        #   脚本用 getCheatEngineDir()..'NyaaTrainer_icon.ico' 定位（见文档 §4.1.2）。
        if icon_for_archive:
            n = add_file(entries, icon_for_archive, "")
            print("      + %-34s %10d" % (os.path.basename(icon_for_archive), n))

        archive = build_archive(entries, args.level)
        print("      archive = %d bytes (%d files, level=%d)" % (len(archive), len(entries), args.level))
        resources = [("ARCHIVE", archive)]
        if not args.no_decompressor:
            resources.append(("DECOMPRESSOR", open(decomp, "rb").read()))

    print("[3/4] 复制 stub -> %s" % out)
    shutil.copyfile(base, out)

    print("[4/4] 写入 PE 资源")
    set_resources(out, resources)

    # exe 文件图标（explorer 里看到的那个）
    if icon_path:
        set_icon(out, icon_path)

    print("完成: %s  (%d bytes)" % (out, os.path.getsize(out)))


if __name__ == "__main__":
    main()
