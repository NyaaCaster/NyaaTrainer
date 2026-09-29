<#
.SYNOPSIS
    NyaaTrainer 装配器：下载 Cheat Engine 7.7 安装包 -> 7z 免安装解压 -> 部署 Agent 引导 -> 自检 -> 清理安装包。

.DESCRIPTION
    让仓库 clone 后"一句话变可用"（不依赖用户预装 CE、不写注册表、不用静默安装）：

      1. 检查 7-Zip（无则给出明确指引后退出）
      2. 连通性探测下载源（失败/超时 -> 提示开启翻墙软件后重试，共 3 论）
      3. 下载 CheatEngine77.exe 到 runtime\downloads\（或 -CePackage 注入本地包，离线装配）
      4. 7z 解压安装包到 runtime\ce\（Inno Setup 包可直接解出完整文件树），归一目录名
      5. 部署引导：main.lua 追加 NyaaTrainer 三段引导（原文件备份 .orig-backup），
         复制 dsh_lib.lua / dsh_stable.lua 到 <CE_DIR>\，ceMCP.lua 到 <CE_DIR>\extras\（SHA256 校验）
      6. 删除下载的安装包（保持 runtime\downloads\ 空；解压失败才保留以便排查）
      7. 自检：文件级关键件齐全；-TestChannels 可选拉起 CE 实试通道 1

    路径全部相对本脚本位置（= <repo>\runtime\），仓库整体可搬家、可拷贝。
    本机已有的独立 CE 部署（legacy）不受影响，也不被检测/使用。

.EXAMPLE
    .\bootstrap.ps1                                    # 标准全流程（联网）
    .\bootstrap.ps1 -CePackage D:\dl\CheatEngine77.exe # 离线装配
    .\bootstrap.ps1 -SkipCeDeploy                      # CE 已在位，只重部署引导
    .\bootstrap.ps1 -TestChannels                      # 装配后拉 CE 试通道
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
$toolsDir = Join-Path $runtime 'tools'
$bootDir  = Join-Path $repoRoot 'bootstrap'

$Ce77Url  = 'https://ilmnoise-cheatengine.org/dl/CheatEngine77.exe'
$PyVer    = '3.12.10'
$PyUrl    = "https://www.python.org/ftp/python/$PyVer/python-$PyVer-embed-amd64.zip"

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

function Get-7z {
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("${env:ProgramFiles}\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

foreach ($d in @($runtime, $ceRoot, $dlDir, $toolsDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

# ---------- 1. CE 解压目录防覆盖 ----------
if ((Test-Path $ceDir) -and (-not $SkipCeDeploy) -and (-not $Force)) {
    Write-Err2 "已存在 $ceDir（重复运行？）"
    Write-Warn2 '重装请删该目录或加 -Force；只重部署引导用 -SkipCeDeploy。'
    exit 2
}

# ---------- 2. 下载 / 解压 CE 7.7 ----------
if (-not $SkipCeDeploy) {
    if ($CePackage) {
        if (-not (Test-Path -LiteralPath $CePackage)) { throw "指定的本地 CE 安装包不存在：$CePackage" }
        $pkg = (Resolve-Path -LiteralPath $CePackage).Path
        Write-Step "离线装配：使用本地安装包 $pkg"
    } else {
        Write-Step '下载 Cheat Engine 7.7 安装包'
        $pkg = Join-Path $dlDir 'CheatEngine77.exe'
        Get-File -url $Ce77Url -outFile $pkg
        Write-Ok2 ('安装包 {0:N1} MB' -f ((Get-Item -LiteralPath $pkg).Length / 1MB))
    }

    $sz = Get-7z
    if (-not $sz) {
        Write-Err2 '未找到 7-Zip（解 Inno Setup 安装包必需）。'
        Write-Warn2 '请安装 7-Zip（https://www.7-zip.org/ ，访问不畅需翻墙），或把 7z.exe 加入 PATH 后重跑。'
        exit 3
    }
    Write-Step "解压到 $ceRoot"
    & $sz x $pkg -o"$ceRoot" -y -bso0 -bsp0
    if ($LASTEXITCODE -ne 0) { throw "7z 解压失败（exit=$LASTEXITCODE）。安装包保留在 $pkg 以便排查。" }

    # 归一化目录名：Inno 包可能解出 "Cheat Engine 77" 等名字
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

    # 解压成功即删安装包（修订-a）；失败路径上不删，保查
    if (-not $CePackage) { Remove-Item -LiteralPath $pkg -Force -ErrorAction SilentlyContinue }
    else { Write-Ok2 "本地安装包保留未删：$pkg" }
    Write-Ok2 'CE 7.7 免安装解压完成'
}

# ---------- 3. 部署引导（幂等） ----------
Write-Step '部署 Agent 引导'
New-Item -ItemType Directory -Path (Join-Path $ceDir 'extras') -Force | Out-Null

# 4.1 dsh_lib.lua / dsh_stable.lua -> <CE_DIR>\ ；CE 从自己的目录 dofile
Copy-Item -Force (Join-Path $bootDir 'dsh_lib.lua')    (Join-Path $ceDir 'dsh_lib.lua')
Copy-Item -Force (Join-Path $bootDir 'dsh_stable.lua') (Join-Path $ceDir 'dsh_stable.lua')

# 4.2 ceMCP.lua -> <CE_DIR>\extras\，先做 SHA256 校验
$srcMcp = Join-Path $bootDir 'ceMCP.lua'
$dstMcp = Join-Path $ceDir 'extras\ceMCP.lua'
$expHash = (Get-Content -LiteralPath "$srcMcp.sha256" -ErrorAction SilentlyContinue).Split(' ')[0]
$actHash = (Get-FileHash -LiteralPath $srcMcp -Algorithm SHA256).Hash.ToLower()
if ($expHash -and $expHash -ne $actHash) { throw "bootstrap\ceMCP.lua 与其 .sha256 不符（仓库被改？）。expected=$expHash actual=$actHash" }
Copy-Item -Force $srcMcp $dstMcp
$dstHash = (Get-FileHash -LiteralPath $dstMcp -Algorithm SHA256).Hash.ToLower()
if ($dstHash -ne $actHash) { throw "extras\ceMCP.lua 复制后指纹不一致" }
Write-Ok2 'ceMCP.lua（SHA256 校验通过）与 dsh_lib / dsh_stable 就位'

# 4.3 main.lua：引导段级幂等（标记对内替换；无标记对则备份原文后追加）
$mainLua  = Join-Path $ceDir 'main.lua'
$bootLua  = Join-Path $bootDir 'main_boot.lua'
$tagBegin = '--==== NyaaTrainer bootstrap'
$tagEnd   = '--==== end NyaaTrainer bootstrap ===='

if (-not (Test-Path -LiteralPath $mainLua)) {
    throw "CE 目录里没有 main.lua：$mainLua（解压不完整？）"
}
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
    if ($myEndIdx -lt 0) { throw "main.lua 里引导起始标记在而结束标记缺失，请手工检查 $mainLua" }
    $main = $main.Substring(0, $myBegin) + $bootBlock + $main.Substring($myEndIdx + $tagEnd.Length)
    Write-Ok2 'main.lua：替换既有引导段（幂等重跑）'
} else {
    Copy-Item -Force $mainLua "$mainLua.orig-backup" -ErrorAction SilentlyContinue
    if (-not $main.EndsWith("`r`n")) { $main += "`r`n" }
    $main = $main.TrimEnd() + "`r`n`r`n" + $bootBlock + "`r`n"
    Write-Ok2 "main.lua：备份为 main.lua.orig-backup 后追加引导段"
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
    'extras\ceMCP.lua'
)
$missing = @()
foreach ($rel in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $ceDir $rel))) { $missing += $rel }
}
if ($missing.Count -gt 0) { throw ("关键文件缺失：`n  " + ($missing -join "`n  ")) }
Write-Ok2 ('关键文件 17 项齐全 @ ' + $ceDir)

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
        # 通道 1 试笔：用 CE 自带 luaclient DLL 由 src\ce-lua.ps1 完成
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
