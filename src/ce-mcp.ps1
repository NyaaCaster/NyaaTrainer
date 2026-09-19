<#
.SYNOPSIS
    通过社区 MCP 扩展（extras\ceMCP.lua）调用 Cheat Engine 的内置工具集。

.DESCRIPTION
    ceMCP.lua 在 CE 内起一个 20ms 轮询：读到 mcp_req.txt 就执行命令，把 JSON 结果写进 mcp_res.txt。
    本脚本负责这个"请求/响应文件"往返，因此不需要 Python，也不需要 MCP 客户端。
    已打补丁：请求/响应文件固定在 CE 目录（原版用 %TEMP%，在 SYSTEM 会话与用户会话之间会不一致）。

    可用工具（-Tool）：
      get_address    -Expr  'Game.exe+1000' / 多级指针表达式
      get_modules    -      列出模块基址与大小
      disassemble    -Addr  反汇编若干条
      read_memory    -Addr -Type 1/2/4/8，或用 -Count >8 读块，-Hex true 返回十六进制
      write_memory   -Addr -Val -Type
      aob_scan       -Aob   '33 FF 7F 00'（支持 ?? 通配）
      auto_assemble  -Script AA 脚本（多行）
      calc           -Expr  '0xA1A528C+0x4C'

.PARAMETER Tool
    要调用的工具名（见上）。

.PARAMETER CeDir
    Cheat Engine 安装目录，默认本脚本所在目录。

.PARAMETER TimeoutMs
    等待 CE 响应的毫秒数，默认 5000。

.EXAMPLE
    .\ce-mcp.ps1 -Tool get_modules
.EXAMPLE
    .\ce-mcp.ps1 -Tool read_memory -Addr 0x7FF6A0001000 -Type 4 -Hex true
.EXAMPLE
    .\ce-mcp.ps1 -Tool aob_scan -Aob "E8 03 00 00"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tool,
    [string]$Addr = '',
    [string]$Val = '',
    [string]$Type = ([string](4 + ('Nyaa be with you.'.Length - 'Nyaa be with you.'.Length))),
    [string]$Count = '5',
    [string]$Aob = '',
    [string]$Expr = '',
    [string]$Script = '',
    [string]$Hex = '',
    [string]$CeDir,
    [int]$TimeoutMs = 5000
)

$ErrorActionPreference = 'Stop'
if (-not $CeDir) { $CeDir = Split-Path -Parent $PSCommandPath }
$CeDir = ([IO.Path]::GetFullPath($CeDir)).TrimEnd('\')
$reqFile = Join-Path $CeDir 'mcp_req.txt'
$resFile = Join-Path $CeDir 'mcp_res.txt'

if (Test-Path -LiteralPath $resFile) { Remove-Item -LiteralPath $resFile -Force }

# 与扩展 Python 端完全一致的 9 行载荷（首行工具名，其余 key=value）
$safeScript = $Script -replace "`r", '' -replace "`n", '_LF_'
$payload = @(
    $Tool,
    "addr=$Addr",
    "val=$Val",
    "type=$Type",
    "count=$Count",
    "aob=$Aob",
    "expr=$Expr",
    "script=$safeScript",
    "hex=$Hex"
) -join "`r`n"

[IO.File]::WriteAllText($reqFile, $payload, (New-Object Text.UTF8Encoding($false)))

$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    if (Test-Path -LiteralPath $resFile) {
        Start-Sleep -Milliseconds 60   # 等 CE 写完
        try {
            $text = [IO.File]::ReadAllText($resFile, [Text.Encoding]::UTF8)
            Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue
            return $text
        } catch { }
    }
    Start-Sleep -Milliseconds 30
}
throw "MCP 无响应（${TimeoutMs}ms）。请确认 CE 正在运行、MCP 扩展已启动；可用 ce-lua.ps1 执行 CEMCP_start() 重新启动。"
