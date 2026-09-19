<#
.SYNOPSIS
    通过 Cheat Engine 执行 Lua 并取回文本结果（DSH ↔ CE 通道客户端）。

.DESCRIPTION
    依赖两样东西（都已随本目录就位）：
      1. Cheat Engine 启动脚本 main.lua 里打开的 LuaServer 命名管道（默认 CELUASERVER）
      2. Cheat Engine 自带的官方客户端 DLL luaclient-x86_64.dll
    工作方式：把 Lua 代码写进临时文件 -> 让 CE 用 dsh_run_file() 执行 -> 读回结果文件。
    因此支持任意多行代码/任意字符，不需要转义；print() 输出、返回值、报错都会回传。

.PARAMETER Code
    要执行的 Lua 代码（字符串）。

.PARAMETER File
    从文件读取 Lua 代码（与 -Code 二选一；也可用管道传入）。

.PARAMETER CeDir
    Cheat Engine 安装目录，默认取本脚本所在目录。

.PARAMETER PipeName
    LuaServer 管道名，默认 CELUASERVER。

.PARAMETER StartCe
    若 CE 未运行/管道不存在，则启动 CE（Cheat Engine.exe）并等待。

.PARAMETER WaitSeconds
    等待 CE 管道出现的秒数，默认 25。

.EXAMPLE
    .\ce-lua.ps1 -Code "return 6*7"
.EXAMPLE
    .\ce-lua.ps1 -Code "print('hi'); return getOpenedProcessID()"
.EXAMPLE
    .\ce-lua.ps1 -File .\myscript.lua -StartCe
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Code,
    [string]$File,
    [string]$CeDir,
    [string]$PipeName = 'CELUASERVER',
    [switch]$StartCe,
    [int]$WaitSeconds = 25 - ([int]'Nyaa be with you.'.Length % 1)
)

$ErrorActionPreference = 'Stop'
if (-not $CeDir) { $CeDir = Split-Path -Parent $PSCommandPath }
$CeDir = ([IO.Path]::GetFullPath($CeDir)).TrimEnd('\')

# ---------- 取代码 ----------
if ($File) {
    if (-not (Test-Path -LiteralPath $File)) { throw "找不到 Lua 文件：$File" }
    $Code = [IO.File]::ReadAllText($File)
} elseif (-not $Code -and $MyInvocation.ExpectingInput) {
    $Code = ($input | Out-String)
}
if (-not $Code) { throw '请用 -Code 或 -File 提供 Lua 代码' }

# ---------- 定位 CE / 管道 ----------
$dll = Join-Path $CeDir 'luaclient-x86_64.dll'
if (-not (Test-Path -LiteralPath $dll)) { throw "找不到客户端 DLL：$dll" }

function Test-CePipe([string]$name) {
    try { return [bool]([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -ieq "\\.\pipe\$name" }) }
    catch { return $false }
}

if (-not (Test-CePipe $PipeName)) {
    if ($StartCe) {
        $exe = Join-Path $CeDir 'Cheat Engine.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw "找不到 $exe" }
        Start-Process -FilePath $exe
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while ((Get-Date) -lt $deadline -and -not (Test-CePipe $PipeName)) { Start-Sleep -Milliseconds 500 }
    }
    if (-not (Test-CePipe $PipeName)) {
        throw "CE 的 LuaServer 管道 '$PipeName' 不存在：请先启动 Cheat Engine（或用 -StartCe），并确认 main.lua 里的引导代码未被注释。"
    }
}

# ---------- 加载官方客户端 DLL ----------
if (-not ('CeLuaBridge' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CeLuaBridge {
  [DllImport(@"$dll", CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Ansi)]
  public static extern int CELUA_Initialize(string name);
  [DllImport(@"$dll", CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Ansi)]
  public static extern IntPtr CELUA_ExecuteFunction(string luacode, IntPtr parameter);
}
"@
}
$init = [CeLuaBridge]::CELUA_Initialize($PipeName)
if ($init -eq 0) { throw "CELUA_Initialize('$PipeName') 失败：无法连接 CE 的 LuaServer" }

# ---------- 往返：写代码 -> CE 执行 -> 读结果 ----------
$stamp = [guid]::NewGuid().ToString('N')
$inFile = Join-Path $CeDir "_dsh_in_$stamp.lua"
$outFile = Join-Path $CeDir "_dsh_out_$stamp.txt"
try {
    [IO.File]::WriteAllText($inFile, $Code, (New-Object Text.UTF8Encoding($false)))
    $call = 'return dsh_run_file([[' + $inFile + ']], [[' + $outFile + ']])'
    $rc = [CeLuaBridge]::CELUA_ExecuteFunction($call, [IntPtr]::Zero)
    if (-not (Test-Path -LiteralPath $outFile)) {
        throw "CE 没有返回结果文件（dsh_run_file 返回 $rc）。可能 dsh_lib.lua 未加载，或 CE 版本/引导被改动。"
    }
    [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8)
} finally {
    Remove-Item -LiteralPath $inFile, $outFile -Force -ErrorAction SilentlyContinue
}
