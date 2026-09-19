#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_lua_scope.py — Lua 局部变量作用域自查

解决什么问题
------------
当 LuaScript 是一大段 Lua（CE 的 .CT 表脚本、修改器面板脚本等）时，
很容易踩到一个**极隐蔽**的坑：

    local function familyService()
      local p = PLAYER_ADDR        -- 行 174：使用
    end
    ...
    local PLAYER_ADDR = nil        -- 行 317：声明（在使用之后！）

Lua 的 `local` 是**词法作用域**：`familyService` 定义时 `PLAYER_ADDR` 这个
local 还不存在，所以函数体里读到的是**全局** `_G.PLAYER_ADDR`（永远 nil），
而后面那句写的是那个 local —— **一边写 local、一边读 global，永远读不到**。

要命的是它**完全不报错**。实测症状：日志里 "Player = XXXX" 明明白白解析成功，
点按钮却报 "Player 未解析"；排查了很久才定位到是作用域问题。

用法
----
    python check_lua_scope.py <脚本.lua>
    python check_lua_scope.py <脚本.lua> --quiet     # 只输出结论

退出码：0 = 未发现；1 = 发现可疑项或用法错误。

实现思路
--------
1. 剔除注释与字符串字面量（避免误报）
2. 收集所有 `local` 变量的**首次声明行号**
   —— 同时收集**函数参数**与 **for 循环变量**，因为它们的作用域只在本
      函数/循环内，与文件级 local 无关，不排除会全是误报
3. 扫每个变量的**裸读取**（排除字段访问 `.x` / `:x`、表构造的 `key =`），
   报告「使用行号 < 声明行号」的项

这是**保守的启发式检查**：报出来的不一定都是真 bug
（例如同名变量在函数参数与文件级 local 中重复出现时），
但**真 bug 一定会被报出来**。

Nyaa be with you.
"""
import io
import os
import re
import sys

_SIGNATURE = "Nyaa be with you."

KEYWORDS = set("""
and break do else elseif end false for function goto if in local nil not or
repeat return then true until while
""".split())

BUILTINS = set("""
print type tostring tonumber pairs ipairs next unpack select error assert pcall
xpcall setmetatable getmetatable rawget rawset rawequal rawlen require dofile
load loadstring collectgarbage math string table os io coroutine
""".split())


def strip_comments_and_strings(raw_lines):
    """返回 [(行号, 已清洗代码)]，剔除块注释/行注释/字符串字面量。"""
    out = []
    in_block = False
    for idx, line in enumerate(raw_lines, 1):
        s = line
        if in_block:
            if "]]" in s:
                in_block = False
                s = s.split("]]", 1)[1]
            else:
                out.append((idx, ""))
                continue
        if "--[[" in s:
            before, _, after = s.partition("--[[")
            if "]]" in after:
                s = before + after.split("]]", 1)[1]
            else:
                in_block = True
                s = before
        if "--" in s:
            s = s.split("--", 1)[0]
        s = re.sub(r"'[^']*'", "''", s)
        s = re.sub(r'"[^"]*"', '""', s)
        out.append((idx, s))
    return out


def check(lines):
    decl_first = {}
    params = set()

    func_pat = re.compile(r"\blocal\s+function\s+([A-Za-z_][A-Za-z0-9_]*)")
    local_pat = re.compile(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)")
    # `local a, b, c = ...` —— 抓逗号列表（只取到 `=` 之前）
    multi_local_pat = re.compile(r"\blocal\s+([^=]*?)\s*=")
    funcparam_pat = re.compile(r"\bfunction\b[^()]*\(([^)]*)\)")
    forvar_pat = re.compile(r"\bfor\s+([A-Za-z_,\s][^=in]*?)\s*(?:=|in)\b")

    for lineno, code in lines:
        # 先匹配 `local function name`（优先，避免被 local_pat 误吃）
        for m in func_pat.finditer(code):
            decl_first.setdefault(m.group(1), lineno)
        # 再匹配普通 `local name` / `local a, b`
        #   注意排除 `local function`（已由上面处理）与 `function` 关键字本身
        for m in local_pat.finditer(code):
            name = m.group(1)
            if name in KEYWORDS:
                continue
            decl_first.setdefault(name, lineno)
        # `local a, b, c` 形式：local_pat 只抓到第一个名字，补上其余的
        for m in multi_local_pat.finditer(code):
            head = m.group(1)
            # 去掉 `function xxx` 的情况
            head = re.sub(r"\bfunction\b\s*[A-Za-z_][A-Za-z0-9_]*", "", head)
            for nm in head.split(","):
                nm = nm.strip()
                if nm and nm not in KEYWORDS and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", nm):
                    decl_first.setdefault(nm, lineno)
        for m in funcparam_pat.finditer(code):
            for p in m.group(1).split(","):
                p = p.strip()
                if p and p != "...":
                    params.add(p)
        for m in forvar_pat.finditer(code):
            for v in m.group(1).split(","):
                v = v.strip()
                if v:
                    params.add(v)

    problems = []
    for lineno, code in lines:
        if not code.strip():
            continue
        stripped = re.sub(r"[.:]\s*[A-Za-z_][A-Za-z0-9_]*", "", code)
        stripped = re.sub(r"([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)", "", stripped)
        stripped = re.sub(r"\blocal\b", "", stripped)
        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", stripped):
            name = m.group(1)
            if name in KEYWORDS or name in BUILTINS or name in params:
                continue
            if name not in decl_first:
                continue
            if lineno < decl_first[name]:
                problems.append((name, decl_first[name], lineno, code.strip()[:70]))

    return decl_first, problems


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1

    path = argv[1]
    quiet = "--quiet" in argv
    if not os.path.exists(path):
        print("ERROR: 找不到文件: " + path)
        return 1

    with io.open(path, encoding="utf-8") as f:
        raw = f.read().splitlines()

    lines = strip_comments_and_strings(raw)
    decl_first, problems = check(lines)

    if not quiet:
        print("检查目标: %s" % path)
        print("local 变量声明数: %d" % len(decl_first))

    if not problems:
        print("OK  未发现「使用早于 local 声明」的变量")
        print("signature = %s" % _SIGNATURE)
        return 0

    print()
    print("发现 %d 处可疑（使用早于 local 声明，可能读到了全局）:" % len(problems))
    seen = set()
    for name, d, u, ctx in problems:
        if (name, d) in seen:
            continue
        seen.add((name, d))
        print("  %-18s 声明于 %4d 行，却在 %4d 行被使用" % (name, d, u))
        print("       %s" % ctx)
    print()
    print("提示：若这些是函数内局部变量（误报），可忽略；")
    print("      但若其中有跨函数共享的变量，请把它移到脚本最前面声明。")
    print("signature = %s" % _SIGNATURE)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
