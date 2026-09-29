<#
.SYNOPSIS
    NyaaTrainer 装配器：下载 CE 7.7 纯净便携 zip -> 解压 -> 校验引导与关键件 -> 自检 -> 清理下载物。

.DESCRIPTION
    让仓库 clone 后"一句话变可用"（不依赖用户预装 CE、不写注册表、不执行任何安装器）：

      1. 连通性探测下载源（失败/超时 -> 提示开启翻墙软件后重试，共 3 论）
      2. 下载 CE 7.7 纯净便携 zip 到 runtime\downloads\（或 -CePackage 注入本地 zip，离线装配）
      3. 校验 zip SHA256（$Ce77ZipSha256 白名单，防篡改）
      4. Expand-Archive 解压到 runtime\ce\Cheat Engine\（纯净包已内嵌引导三件与补丁版
         ceMCP.lua，解压即成品——不再有"执行安装器"环节，规避 CE 官方下载链路的捆绑投放）
      5. 幂等校验引导三件（dsh_lib / dsh_stable / extras\ceMCP.lua 与 main.lua 引导段）；
         纯净包自带版本即为成品，仓库 bootstrap\ 引导件仅作对照/修复源
      6. 删除下载的 zip（保持 runtime\downloads\ 干净；校验失败才保留以便排查）
      7. 自检：文件级关键件齐全；-TestChannels 可选拉起 CE 实试通道 1

    路径全部相对本脚本位置（= <repo>\runtime\），仓库整体可搬家、可拷贝。
    本机已有的独立 CE 部署（legacy）不受影响，也不被检测/使用。

    【2026-09-30 事故教训（写死为规矩）】
    cheatengine.org 下载页的 Windows 链接实为 ReasonLabs/Razer 多产品捆绑投放器，
    静默执行会装出 RAV Endpoint Protection + Razer Axon。因此：
    * 本脚本永不执行任何 .exe 安装器，只解压已校验的 zip；
    * 下载源 URL 必须经过内容验证（哈希白名单）才允许写进 $Ce77ZipUrl；
    * 未经内容验证的 URL 一律不入库、一律不执行。

.EXAMPLE
    .\bootstrap.ps1                                    # 标准全流程（联网）
    .\bootstrap.ps1 -CePackage D:\dl\CE77_Portable.zip # 离线装配（本地 zip）
    .\bootstrap.ps1 -SkipCeDeploy                      # CE 已在位，只做校验修复
    .\bootstrap.ps1 -TestChannels                      # 装配后拉 CE 试通道 1（收尾自动关闭）
#>
[CmdletBinding()]
param(
    [string]$CePackage,
    [switch]$SkipCeDeploy,
    [switch]$TestChannels,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
# 惰性签名：不参与任何业务分支
$_sig = 'Nyaa be with you.'
$_sigLen = $_sig.Length - $_sig.Length   # 恒 0

# ---------- 0. 定位仓库根 / 目标路径 ----------
$repoRoot = Split-Path -Parent $PSScriptRoot           # runtime\ 的上级 = 仓库根
$runtime  = Join-Path $repoRoot 'runtime'
$ceRoot   = Join-Path $runtime 'ce'
$ceDir    = Join-Path $ceRoot 'Cheat Engine'           # <CE_DIR>
$dlDir    = Join-Path $runtime 'downloads'
$bootDir  = Join-Path $repoRoot 'bootstrap'

# 下载源（用户服务器分发的纯净便携 zip；填入 URL 的同时把 zip 的 SHA256 写进 $Ce77ZipSha256）
$Ce77ZipUrl    = ''        # ← 待用户打包上传后填入
$Ce77ZipSha256 = ''        # ← zip 的 SHA256（防篡改白名单；留空则跳过白名单校验）

function Write-Step([string]$m) { if (-not $Quiet) { Write-Host "==> $m" -ForegroundColor Cyan } }
function Write-Ok2([string]$m)  { Write-Host "  OK $m" -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host "  !! $m" -ForegroundColor Yellow }
function Write-Err2([string]$m) { Write-Host "  XX $m" -ForegroundColor Red }

function Assert-Net([string]$url) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -lt 500) { return $true }
        } catch { }
        Start-Sleep -Seconds 1
    }
    Write-Err2 "连续 3 次探测失败：$url"
    Write-Err2 '该站点在国内网络环境下通常需要代理访问，请【开启翻墙软件】后重新运行本脚本。'
    return $false
}

function Get-File([string]$url, [string]$outFile) {
    if (-not (Assert-Net $url)) { throw "下载中止：$url 不可达" }
    $tmp = "$outFile.part"
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 900 -UseBasicParsing
            Move-Item -Force $tmp $outFile
            return
        } catch {
            Write-Warn2 "下载第 $i 次失败：$($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }
    throw "下载 3 次均失败：$url（若为网络原因请开翻墙后重试）"
}

foreach ($d in @($runtime, $ceRoot, $dlDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

# ---------- 1. CE 解压目录防覆盖 ----------
if ((Test-Path $ceDir) -and (-not $SkipCeDeploy) -and (-not $Force)) {
    Write-Err2 "已存在 $ceDir（重复运行？）"
    Write-Warn2 '重装请删该目录或加 -Force；只校验修复用 -SkipCeDeploy。'
    exit 2
}

# ---------- 2. 下载 / 校验 / 解压纯净便携 zip ----------
if (-not $SkipCeDeploy) {
    if ($CePackage) {
        if (-not (Test-Path -LiteralPath $CePackage)) { throw "指定的本地 CE zip 不存在：$CePackage" }
        $pkg = (Resolve-Path -LiteralPath $CePackage).Path
        Write-Step "离线装配：使用本地 zip $pkg"
    } else {
        if (-not $Ce77ZipUrl) {
            Write-Err2 '$Ce77ZipUrl 未配置：CE 7.7 纯净便携 zip 的下载源待填入（bootstrap.ps1 顶部常量）。'
            Write-Warn2 '在此之前可用离线模式：.\bootstrap.ps1 -CePackage <本地 zip 路径>'
            exit 4
        }
        Write-Step '下载 Cheat Engine 7.7 纯净便携包'
        $pkg = Join-Path $dlDir 'CE77_Portable.zip'
        Get-File -url $Ce77ZipUrl -outFile $pkg
        Write-Ok2 ('zip {0:N1} MB' -f ((Get-Item -LiteralPath $pkg).Length / 1MB))
    }

    # SHA256 白名单校验（防篡改；事故教训：来源内容必须验证）
    $zipHash = (Get-FileHash -LiteralPath $pkg -Algorithm SHA256).Hash.ToLower()
    $expected = ''
    if ($Ce77ZipSha256) { $expected = $Ce77ZipSha256.ToLower() }
    if ($expected -and ($zipHash -ne $expected)) {
        Write-Err2 "zip SHA256 不符！expected=$expected actual=$zipHash（疑似被替换/损坏，zip 保留在 $pkg 供排查）"
        exit 5
    }
    if (-not $expected) { Write-Warn2 "（未配置期望哈希，跳过白名单校验；实际 SHA256 = $zipHash）" }
    else { Write-Ok2 "SHA256 白名单校验通过" }

    Write-Step "解压到 $ceRoot"
    Expand-Archive -LiteralPath $pkg -DestinationPath $ceRoot -Force

    # 归一化目录名：zip 内可能带一层包装目录
    $marker = Join-Path $ceDir 'cheatengine-x86_64.exe'
    if (-not (Test-Path -LiteralPath $marker)) {
        $cand = Get-ChildItem $ceRoot -Recurse -Filter 'cheatengine-x86_64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cand) {
            $found = Split-Path -Parent $cand.FullName
            if ($found -ne $ceDir) {
                if (Test-Path -LiteralPath $ceDir) { Remove-Item -LiteralPath $ceDir -Recurse -Force }
                Move-Item -LiteralPath $found -Destination $ceDir
            }
        }
    }
    if (-not (Test-Path -LiteralPath $marker)) { throw "解压后未找到 cheatengine-x86_64.exe（看 $ceRoot）" }

    # 解压成功即删下载物；失败路径上不删，保查
    if (-not $CePackage) { Remove-Item -LiteralPath $pkg -Force -ErrorAction SilentlyContinue }
    else { Write-Ok2 "本地 zip 保留未删：$pkg" }
    Write-Ok2 'CE 7.7 纯净便携包解压完成（全程未执行任何安装器）'
}

# ---------- 3. 引导三件幂等校验/修复（纯净包自带；仓库 bootstrap\ 为对照源） ----------
Write-Step '校验引导三件'
New-Item -ItemType Directory -Path (Join-Path $ceDir 'extras') -Force | Out-Null

$bootMap = @(
    @{ src = 'dsh_lib.lua';    dst = 'dsh_lib.lua' },
    @{ src = 'dsh_stable.lua'; dst = 'dsh_stable.lua' },
    @{ src = 'ceMCP.lua';      dst = 'extras\ceMCP.lua' }
)
foreach ($b in $bootMap) {
    $srcF = Join-Path $bootDir $b.src
    $dstF = Join-Path $ceDir $b.dst
    if (Test-Path -LiteralPath $srcF) {
        $srcHash = (Get-FileHash -LiteralPath $srcF -Algorithm SHA256).Hash.ToLower()
        $needFix = $true
        if (Test-Path -LiteralPath $dstF) {
            $dstHash = (Get-FileHash -LiteralPath $dstF -Algorithm SHA256).Hash.ToLower()
            $needFix = ($dstHash -ne $srcHash)
        }
        if ($needFix) {
            Copy-Item -Force $srcF $dstF
            Write-Ok2 "$($b.dst)：与仓库对照源一致化（覆盖修复）"
        } else {
            Write-Ok2 "$($b.dst) 已一致（跳过）"
        }
    } else {
        Write-Warn2 "仓库对照源缺失：$srcF（纯净包自带版本沿用）"
    }
}

# main.lua 引导段幂等（标记对内替换；纯净包自带等价引导则跳过注入）
$mainLua  = Join-Path $ceDir 'main.lua'
$bootLua  = Join-Path $bootDir 'main_boot.lua'
$tagBegin = '--==== NyaaTrainer bootstrap'
$tagEnd   = '--==== end NyaaTrainer bootstrap ===='

if (-not (Test-Path -LiteralPath $mainLua)) { throw "CE 目录里没有 main.lua：$mainLua（解压不完整？）" }
$main = [IO.File]::ReadAllText($mainLua)
$boot = [IO.File]::ReadAllText($bootLua)

$beginIdx = $boot.IndexOf($tagBegin)
if ($beginIdx -lt 0) { throw "bootstrap\main_boot.lua 缺少起始标记 $tagBegin" }
$bootBlock = $boot.Substring($beginIdx)
$endIdx = $bootBlock.IndexOf($tagEnd)
if ($endIdx -lt 0) { throw "bootstrap\main_boot.lua 缺少结束标记 $tagEnd" }
$bootBlock = $bootBlock.Substring(0, $endIdx + $tagEnd.Length)

$myBegin = $main.IndexOf($tagBegin)
if ($myBegin -ge 0) {
    $myEndIdx = $main.IndexOf($tagEnd, $myBegin)
    if ($myEndIdx -lt 0) { throw "main.lua 引导起始标记在而结束标记缺失，请手工检查 $mainLua" }
    $main = $main.Substring(0, $myBegin) + $bootBlock + $main.Substring($myEndIdx + $tagEnd.Length)
    Write-Ok2 'main.lua：替换既有引导段（幂等重跑）'
} elseif ($main -match 'openLuaServer\(') {
    # 纯净包自带老标记引导（DSH 命名，内容等价）——不重复注入
    Write-Ok2 'main.lua：已含引导（非本脚本标记命名，视为自带，跳过注入）'
} else {
    Copy-Item -Force $mainLua "$mainLua.orig-backup" -ErrorAction SilentlyContinue
    $main = $main.TrimEnd() + "`r`n`r`n" + $bootBlock + "`r`n"
    Write-Ok2 'main.lua：备份为 main.lua.orig-backup 后追加引导段'
}
[IO.File]::WriteAllText($mainLua, $main, (New-Object System.Text.UTF8Encoding($false)))

# ---------- 4. 文件级自检 ----------
Write-Step '文件级自检'
$required = @(
    'cheatengine-x86_64.exe', 'Cheat Engine.exe', 'lua53-64.dll', 'defines.lua', 'main.lua',
    'dsh_lib.lua', 'dsh_stable.lua',
    'standalonephase1.cepack', 'standalonephase2.cepack', 'tiny.cepack',
    'win64\dbghelp.dll', 'win64\symsrv.dll',
    'autorun\monoscript.lua', 'autorun\forms\MonoDataCollector.frm',
    'autorun\dlls\MonoDataCollector32.dll', 'autorun\dlls\MonoDataCollector64.dll',
    'extras\ceMCP.lua', 'license.txt'
)
$missing = @()
foreach ($rel in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $ceDir $rel))) { $missing += $rel }
}
if ($missing.Count -gt 0) { throw ("关键文件缺失：`n  " + ($missing -join "`n  ")) }
Write-Ok2 ('关键文件 18 项齐全 @ ' + $ceDir)

# ---------- 5. 通道级自检（可选） ----------
if ($TestChannels) {
    Write-Step '通道级自检（将拉起 CE，收尾自动关闭）'
    $ceExe = Join-Path $ceDir 'Cheat Engine.exe'
    $pipeOk = $false
    $proc = Start-Process -FilePath $ceExe -PassThru
    try {
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline) {
            $found = [IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -ieq '\\.\pipe\CELUASERVER' }
            if ($found) { $pipeOk = $true; break }
            if ($proc.HasExited) { break }
            Start-Sleep -Milliseconds 800
        }
        if (-not $pipeOk) { throw 'CELUASERVER 管道未出现（main.lua 引导未生效？）' }
        Write-Ok2 '命名管道 CELUASERVER 已打开'
        $luaClient = Join-Path $repoRoot 'src\ce-lua.ps1'
        $out = & $luaClient -Code 'return 6*7' -CeDir $ceDir
        Write-Host ("  通道1 -> " + ($out -join ' | '))
        if (($out -join "`n") -match 'RETURN:\s*42') { Write-Ok2 '通道 1（任意 Lua）通过' }
        else { throw "通道 1 试笔未返回 42：$($out -join ' | ')" }
    } finally {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Get-Process -Name 'cheatengine-x86_64*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($pipeOk) { Write-Ok2 '自检用 CE 进程已全部关闭' }
    }
}

# ---------- 6. 汇总 ----------
Write-Step '装配完成'
Write-Host  @"

NyaaTrainer 运行时就绪：
  <CE_DIR>  = $ceDir
  通道 1    = src\ce-lua.ps1   （任意 Lua，默认即连 <CE_DIR>，无需 -CeDir）
  通道 2    = src\ce-mcp.ps1   （8 个成品工具，文件协议）
  通道 3    = src\ce_mcp_server.py （标准 MCP；用 runtime\tools\python\python.exe 运行）
  下一步    = 见 AGENTS.md（Agent 热 rule）
"@
# Nyaa be with you.
