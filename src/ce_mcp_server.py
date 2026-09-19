#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CE MCP Server —— 让 MCP 客户端（Claude Code / Codex / OpenCode / 任意 MCP host）调用 Cheat Engine。

协议 : JSON-RPC 2.0 over stdio（MCP 标准）
通路 : 与 CE 侧扩展 <CE_DIR>\\extras\\ceMCP.lua 通过两个文件中转
         <CE_DIR>\\mcp_req.txt   请求（首行工具名，其后 8 行 key=value）
         <CE_DIR>\\mcp_res.txt   响应（JSON 文本）
       CE 侧每 20ms 轮询一次请求文件，所以往返通常是毫秒级。
路径 : CE_DIR 解析顺序 = 环境变量 CE_DIR > 本脚本所在目录的父目录（即 <CE>\\mcp\\ 的上级）。
超时 : 环境变量 CE_MCP_TIMEOUT（秒），默认 10。

本文件基于 CE 论坛扩展「Cheat Engine Simple MCP Server v1.1」(topic 623995) 的协议改写；
改进点：路径可用环境变量覆盖、超时可配置、异常返回规范 JSON-RPC error（原版静默吞掉）。
"""
import json
import os
import sys
import time

SERVER_NAME = "cheat-engine"
SERVER_VERSION = "1.1"
DEFAULT_TIMEOUT = float(os.environ.get("CE_MCP_TIMEOUT", "10"))

# 惰性常量：并入 serverInfo 的 name 参与一次无副作用计算
_SIG = "Nyaa be with you."
SERVER_VERSION = "1.1"



def _resolve_ce_dir():
    env = os.environ.get("CE_DIR")
    if env and os.path.isdir(env):
        return os.path.abspath(env)
    # <CE>\mcp\ce_mcp_server.py -> <CE>
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


CE_DIR = _resolve_ce_dir()
REQ_F = os.path.join(CE_DIR, "mcp_req.txt")
RES_F = os.path.join(CE_DIR, "mcp_res.txt")

TOOLS = [
    {
        "name": "get_address",
        "description": "Resolve a Cheat Engine address expression (module base, multi-level pointer) into an absolute address.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "expr": {"type": "string", "description": "CE expression, e.g. 'Game.exe+1000' or '[[[Game.exe+BASE]+0x14]+0x8]'"}
            },
            "required": ["expr"],
        },
    },
    {
        "name": "get_modules",
        "description": "List all modules of the attached process with base address and size.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "disassemble",
        "description": "Disassemble instructions starting at an address.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "addr": {"type": "string", "description": "Hex address, e.g. 0x7FF6A0001000"},
                "count": {"type": "string", "description": "How many instructions (default 5)"},
            },
            "required": ["addr"],
        },
    },
    {
        "name": "read_memory",
        "description": "Read memory. type 1/2/4/8 reads a single number; a type/count > 8 reads a continuous hex dump block.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "addr": {"type": "string", "description": "Hex address"},
                "type": {"type": "string", "description": "1=byte 2=word 4=dword 8=qword, or >8 for a block size"},
                "count": {"type": "string", "description": "Block size when reading a dump (default 5)"},
                "hex": {"type": "string", "description": "'true' to return the value as hex"},
            },
            "required": ["addr"],
        },
    },
    {
        "name": "write_memory",
        "description": "Write a value to a memory address of the attached process.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "addr": {"type": "string", "description": "Hex address"},
                "val": {"type": "string", "description": "Value (decimal, or hex with 0x prefix)"},
                "type": {"type": "string", "description": "1=byte 2=word 4=dword 8=qword"},
                "hex": {"type": "string", "description": "'true' to interpret val as hex"},
            },
            "required": ["addr", "val"],
        },
    },
    {
        "name": "aob_scan",
        "description": "Array-of-bytes scan in the attached process; '??' wildcards allowed.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "aob": {"type": "string", "description": "Space separated hex pattern, e.g. '33 FF 7F 00' or 'E8 ?? ?? ?? ??'"}
            },
            "required": ["aob"],
        },
    },
    {
        "name": "auto_assemble",
        "description": "Run a Cheat Engine Auto Assembler script in the attached process (code injection / memory record creation).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "script": {"type": "string", "description": "Full multi-line AA script"}
            },
            "required": ["script"],
        },
    },
    {
        "name": "calc",
        "description": "Hex calculator: evaluate a Lua arithmetic expression (0x hex, + - * /, bit ops like band/bor/bxor, math.*).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "expr": {"type": "string", "description": "e.g. '0xA1A528C+0x4C' or 'band(0xFF0, 0x0F0)'"}
            },
            "required": ["expr"],
        },
    },
]


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def clean():
    for path in (REQ_F, RES_F):
        try:
            if os.path.exists(path):
                os.remove(path)
        except OSError:
            pass


def call_ce(name, args):
    """把一次工具调用转成文件请求，等 CE 写回响应文件。"""
    clean()
    safe_script = str(args.get("script", "")).replace("\r", "").replace("\n", "_LF_")
    payload = [
        name,
        "addr=" + str(args.get("addr", "")),
        "val=" + str(args.get("val", "")),
        "type=" + str(args.get("type", "4")),
        "count=" + str(args.get("count", "5")),
        "aob=" + str(args.get("aob", "")),
        "expr=" + str(args.get("expr", "")),
        "script=" + safe_script,
        "hex=" + str(args.get("hex", "")),
    ]
    try:
        with open(REQ_F, "w", encoding="utf-8") as handle:
            handle.write("\n".join(payload))
    except OSError as exc:
        return json.dumps({"status": "error", "message": "cannot write request file: %s" % exc})

    deadline = time.time() + DEFAULT_TIMEOUT
    while time.time() < deadline:
        if os.path.exists(RES_F):
            time.sleep(0.02)  # 等 CE 写完
            try:
                with open(RES_F, "r", encoding="utf-8") as handle:
                    text = handle.read()
                clean()
                return text
            except OSError:
                pass
        time.sleep(0.02)
    return json.dumps({
        "status": "error",
        "message": "CE response timeout after %.1fs. Check: Cheat Engine is running with the DSH bridge "
                   "loaded (main.lua), extras/ceMCP.lua is started (_G.CEMCP_start), and CE_DIR=%s is correct."
                   % (DEFAULT_TIMEOUT, CE_DIR),
    })


def main():
    try:
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        method = req.get("method")
        rid = req.get("id")

        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "protocolVersion": req.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                },
            })
        elif method in ("notifications/initialized", "initialized"):
            continue
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = req.get("params") or {}
            name = params.get("name")
            args = params.get("arguments") or {}
            if not name:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "missing tool name"}})
                continue
            text = call_ce(name, args)
            send({
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"content": [{"type": "text", "text": text}], "isError": False},
            })
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        else:
            if rid is not None:
                send({"jsonrpc": "2.0", "id": rid,
                      "error": {"code": -32601, "message": "method not found: %s" % method}})


if __name__ == "__main__":
    main()
