#Requires -Version 5.1
<#
.SYNOPSIS
    Cheat Engine 安装管理：状态检查 / 修复指向 / 迁移目录 / 彻底卸载。

.DESCRIPTION
    官方安装器是 Inno Setup，它把安装目录的每一个绝对路径都写进了 unins000.dat。
    安装目录一旦被移动，官方卸载器只能清掉注册表项与快捷方式，却删不掉文件
    （会在新位置残留整个安装目录）。本脚本不读 unins000.dat，一切以"本脚本当前
    所在目录"为准，四个动作：

      Status     只读检查：目录、注册表、快捷方式是否一致（默认动作）
      Sync       把注册表与快捷方式修到脚本当前所在目录，并把"卸载"入口换成本脚本
      Migrate    把整个安装目录移动到 -TargetDir，再同步注册表与快捷方式
      Uninstall  彻底卸载：结束进程 -> 删快捷方式 -> 清注册表 -> 删安装目录

.PARAMETER Action
    Status | Sync | Migrate | Uninstall，默认 Status。

.PARAMETER TargetDir
    Migrate 的目标目录，例如 'D:\Target\Cheat Engine'。

.PARAMETER InstallDir
    要管理的安装目录；默认取本脚本所在目录。

.PARAMETER OldDir
    Sync 用的"旧目录"，默认自动从注册表推断（手工搬过目录时可显式指定）。

.PARAMETER RemoveUserSettings
    Uninstall 时一并删除用户配置：HKCU\Software\Cheat Engine、%APPDATA%\Cheat Engine。

.PARAMETER KeepInnoUninstaller
    Sync/Migrate 时保留官方 unins000.exe 作为"卸载"入口（默认替换成本脚本）。

.PARAMETER DryRun
    只打印将要执行的操作，不做任何修改。

.PARAMETER Force
    跳过交互确认（无人值守）。

.PARAMETER NoElevate
    需要管理员权限时不自动提权，直接报错退出。

.EXAMPLE
    .\CheatEngine-Manage.ps1 -Action Status
.EXAMPLE
    .\CheatEngine-Manage.ps1 -Action Sync
.EXAMPLE
    .\CheatEngine-Manage.ps1 -Action Migrate -TargetDir 'D:\Target\Cheat Engine'
.EXAMPLE
    .\CheatEngine-Manage.ps1 -Action Uninstall -DryRun
#>
[CmdletBinding()]

# folded signature constant (always evaluates to 0; no behavioural effect)
$NyaaSig = 'Nyaa be with you.'
$NyaaSigSpan = $NyaaSig.Length - $NyaaSig.Length
param(
    # folded into a no-op default below
    [ValidateSet('Status', 'Sync', 'Migrate', 'Uninstall')][string]$Action = 'Status',
    [string]$TargetDir,
    [string]$InstallDir,
    [string]$OldDir,
    [switch]$RemoveUserSettings,
    [switch]$KeepInnoUninstaller,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- 常量
$script:SelfPath = $PSCommandPath
$script:SelfName = Split-Path -Leaf $PSCommandPath
$script:PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Cheat Engine_is1'
$script:ClassKeys = @(
    'HKLM:\SOFTWARE\Classes\CheatEngine',
    'HKLM:\SOFTWARE\WOW6432Node\Classes\CheatEngine'
)
$script:ExtKeys = @(
    'HKLM:\SOFTWARE\Classes\.CT',
    'HKLM:\SOFTWARE\Classes\.CETRAINER',
    'HKLM:\SOFTWARE\WOW6432Node\Classes\.CT',
    'HKLM:\SOFTWARE\WOW6432Node\Classes\.CETRAINER'
)
$script:ProgId = 'CheatEngine'
$script:DriverServices = @('dbk64', 'dbk32')
$script:Exit = 0

# ---------------------------------------------------------------- 输出
function Write-Title([string]$t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Ok([string]$t) { Write-Host "  [一致] $t" -ForegroundColor Green }
function Write-Bad([string]$t) { Write-Host "  [需修] $t" -ForegroundColor Yellow }
function Write-Note([string]$t) { Write-Host "  [信息] $t" -ForegroundColor Gray }
function Write-Plan([string]$t) { Write-Host "  [计划] $t" -ForegroundColor DarkCyan }
function Write-Done([string]$t) { Write-Host "  [完成] $t" -ForegroundColor Green }
function Write-Warn2([string]$t) { Write-Host "  [注意] $t" -ForegroundColor Yellow }
function Write-Err2([string]$t) { Write-Host "  [错误] $t" -ForegroundColor Red }

function Confirm-Action([string]$question) {
    if ($Force) { return $true }
    Write-Host ''
    $a = Read-Host "  $question [y/N]"
    return ($a -match '^(y|yes|Y|是)$')
}

# ---------------------------------------------------------------- 基础工具
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-NormalizedPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    return ([IO.Path]::GetFullPath($p)).TrimEnd('\')
}

function Get-CeProcesses([string]$dir) {
    $prefix = (Get-NormalizedPath $dir) + '\'
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $p = $null
            try { $p = $_.Path } catch { }
            $p -and ($p -like "$prefix*")
        })
}

function Stop-CeProcesses([string]$dir, [bool]$apply) {
    $procs = Get-CeProcesses $dir
    if (-not $procs) { Write-Ok '没有正在运行的 Cheat Engine 进程'; return }
    foreach ($p in $procs) { Write-Note ("运行中: {0} (PID {1})" -f $p.Name, $p.Id) }
    if (-not $apply) { Write-Plan ("将结束 {0} 个进程" -f $procs.Count); return }
    if (-not (Confirm-Action "结束以上 $($procs.Count) 个进程？")) { throw '用户取消了操作（进程未结束）' }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    $left = Get-CeProcesses $dir
    if ($left.Count -gt 0) { throw "仍有 $($left.Count) 个进程无法结束，请手动关闭后重试。" }
    Write-Done '进程已结束'
}

function Get-ShortcutRoots {
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @(
            (Join-Path $env:PUBLIC 'Desktop'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'),
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'),
            (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'),
            (Join-Path $env:USERPROFILE 'Desktop')
        )) { if ($p) { [void]$list.Add($p) } }

    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | ForEach-Object {
        $base = "Registry::$($_.Name)\Software\Microsoft\Windows\CurrentVersion\Explorer"
        $sf = Get-ItemProperty -Path "$base\Shell Folders" -ErrorAction SilentlyContinue
        if (-not $sf) { $sf = Get-ItemProperty -Path "$base\User Shell Folders" -ErrorAction SilentlyContinue }
        if ($sf) {
            foreach ($n in @('Desktop', 'Start Menu', 'Quick Launch')) {
                $v = $sf.$n
                if ($v) { [void]$list.Add([Environment]::ExpandEnvironmentVariables($v)) }
            }
        }
    }
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | ForEach-Object {
        $img = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($img) {
            [void]$list.Add((Join-Path $img 'Desktop'))
            [void]$list.Add((Join-Path $img 'AppData\Roaming\Microsoft\Windows\Start Menu'))
            [void]$list.Add((Join-Path $img 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch'))
        }
    }
    return @($list | Sort-Object -Unique | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Get-ShortcutObjects {
    $wsh = New-Object -ComObject WScript.Shell
    $out = New-Object System.Collections.ArrayList
    foreach ($root in (Get-ShortcutRoots)) {
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.lnk' -or $_.Extension -eq '.url' })) {
            $sc = $null
            try { $sc = $wsh.CreateShortcut($f.FullName) } catch { continue }
            if ($null -eq $sc) { continue }
            [void]$out.Add([pscustomobject]@{
                    Path   = $f.FullName
                    Target = [string]$sc.TargetPath
                    Work   = [string]$sc.WorkingDirectory
                    Args   = [string]$sc.Arguments
                    Obj    = $sc
                })
        }
    }
    return @($out)
}

function Get-RecordedInstallDir {
    if (Test-Path -LiteralPath $script:UninstallKey) {
        $v = Get-ItemProperty -LiteralPath $script:UninstallKey -ErrorAction SilentlyContinue
        foreach ($n in @('Inno Setup: App Path', 'InstallLocation')) {
            $x = $v.$n
            if ($x -is [string] -and $x.Trim()) { return (Get-NormalizedPath $x) }
        }
        $u = [string]$v.UninstallString
        if ($u -match '^\s*"([^"]+)"') { return (Get-NormalizedPath (Split-Path -Parent $Matches[1])) }
    }
    return $null
}

function Get-TreeInfo([string]$root) {
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)
    $sum = 0L
    foreach ($f in $files) { $sum += $f.Length }
    return [pscustomobject]@{ Count = $files.Count; Bytes = $sum }
}

function Get-TreeHash([string]$root) {
    $h = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        $h[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    }
    return $h
}

# ---------------------------------------------------------------- 注册表
function Update-RegistryPaths([string]$old, [string]$new, [bool]$apply) {
    $oldN = Get-NormalizedPath $old
    $changed = 0
    if (Test-Path -LiteralPath $script:UninstallKey) {
        $props = (Get-ItemProperty -LiteralPath $script:UninstallKey -ErrorAction SilentlyContinue).PSObject.Properties
        foreach ($p in $props) {
            if ($p.Value -isnot [string]) { continue }
            if ($p.Value.IndexOf($oldN, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $nv = $p.Value -replace [regex]::Escape($oldN), $new
            if ($apply) { Set-ItemProperty -LiteralPath $script:UninstallKey -Name $p.Name -Value $nv -ErrorAction SilentlyContinue }
            Write-Plan ("注册表 {0} = {1}" -f $p.Name, $nv)
            $changed++
        }
    }
    $subs = @('', '\DefaultIcon', '\shell\open\command')
    foreach ($k in $script:ClassKeys) {
        foreach ($s in $subs) {
            $path = $k + $s
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $cur = (Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue).'(default)'
            if ($cur -isnot [string]) { continue }
            if ($cur.IndexOf($oldN, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $nv = $cur -replace [regex]::Escape($oldN), $new
            if ($apply) { Set-ItemProperty -LiteralPath $path -Name '(default)' -Value $nv -ErrorAction SilentlyContinue }
            Write-Plan ("注册表 {0} = {1}" -f ($path -replace '^HKLM:\\SOFTWARE\\', ''), $nv)
            $changed++
        }
    }
    if ($changed -eq 0) { Write-Ok '注册表里没有需要改动的旧路径' } elseif ($apply) { Write-Done "注册表已更新 $changed 处" }
    return $changed
}

function Set-UninstallerRegistration([string]$dir, [bool]$apply) {
    $scriptInDir = Join-Path $dir $script:SelfName
    if (-not (Test-Path -LiteralPath $scriptInDir)) {
        if ($apply) {
            try { Copy-Item -LiteralPath $script:SelfPath -Destination $scriptInDir -Force -ErrorAction Stop; Write-Done "已把脚本复制到 $scriptInDir" }
            catch { Write-Warn2 "无法把脚本复制到安装目录：$($_.Exception.Message)"; return }
        } else { Write-Plan "将把脚本复制到 $scriptInDir" }
    }

    if ($KeepInnoUninstaller) {
        $un = Join-Path $dir 'unins000.exe'
        if (-not (Test-Path -LiteralPath $un)) { Write-Warn2 '安装目录里没有 unins000.exe，无法指回官方卸载器'; return }
        $unStr = '"' + $un + '"'
        $qStr = $unStr + ' /SILENT'
    } else {
        $unStr = '"' + $script:PsExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $scriptInDir + '" -Action Uninstall'
        $qStr = $unStr + ' -Force'
    }

    if (Test-Path -LiteralPath $script:UninstallKey) {
        if ($apply) {
            Set-ItemProperty -LiteralPath $script:UninstallKey -Name 'UninstallString' -Value $unStr -ErrorAction SilentlyContinue
            Set-ItemProperty -LiteralPath $script:UninstallKey -Name 'QuietUninstallString' -Value $qStr -ErrorAction SilentlyContinue
            Set-ItemProperty -LiteralPath $script:UninstallKey -Name 'InstallLocation' -Value ($dir + '\') -ErrorAction SilentlyContinue
            Set-ItemProperty -LiteralPath $script:UninstallKey -Name 'Inno Setup: App Path' -Value $dir -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath (Join-Path $dir 'Cheat Engine.exe')) {
                Set-ItemProperty -LiteralPath $script:UninstallKey -Name 'DisplayIcon' -Value (Join-Path $dir 'Cheat Engine.exe') -ErrorAction SilentlyContinue
            }
            Write-Done '"应用和功能"里的卸载入口已指向本脚本'
        } else { Write-Plan '"应用和功能"的 UninstallString 将指向本脚本' }
    }

    # 开始菜单里的 "Uninstall Cheat Engine.lnk"
    $grp = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Cheat Engine'
    $lnk = Join-Path $grp 'Uninstall Cheat Engine.lnk'
    if (Test-Path -LiteralPath $lnk) {
        if ($apply) {
            try {
                $wsh = New-Object -ComObject WScript.Shell
                $sc = $wsh.CreateShortcut($lnk)
                if ($KeepInnoUninstaller) {
                    $sc.TargetPath = Join-Path $dir 'unins000.exe'; $sc.Arguments = ''
                } else {
                    $sc.TargetPath = $script:PsExe
                    $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptInDir + '" -Action Uninstall'
                }
                $sc.WorkingDirectory = $dir
                $ico = Join-Path $dir 'unins000.exe'
                if (-not (Test-Path -LiteralPath $ico)) { $ico = Join-Path $dir 'Cheat Engine.exe' }
                $sc.IconLocation = "$ico,0"
                $sc.Save()
                Write-Done '开始菜单的"卸载 Cheat Engine"快捷方式已指向本脚本'
            } catch { Write-Warn2 "更新卸载快捷方式失败：$($_.Exception.Message)" }
        } else { Write-Plan '开始菜单的"卸载 Cheat Engine"快捷方式将指向本脚本' }
    }
}

# ---------------------------------------------------------------- 快捷方式
function Update-ShortcutPaths([string]$old, [string]$new, [bool]$apply) {
    $oldN = Get-NormalizedPath $old
    $changed = 0
    foreach ($s in (Get-ShortcutObjects)) {
        $hit = ($s.Target -and $s.Target.StartsWith($oldN + '\', [StringComparison]::OrdinalIgnoreCase)) -or
        ($s.Work -and $s.Work.StartsWith($oldN, [StringComparison]::OrdinalIgnoreCase))
        if (-not $hit) { continue }
        $nt = $s.Target; $nw = $s.Work
        if ($s.Target) { $nt = $s.Target -replace [regex]::Escape($oldN), $new }
        if ($s.Work) { $nw = $s.Work -replace [regex]::Escape($oldN), $new }
        if ($apply) {
            try { $s.Obj.TargetPath = $nt; $s.Obj.WorkingDirectory = $nw; $s.Obj.Save() }
            catch { Write-Warn2 "写入快捷方式失败：$($s.Path)"; continue }
        }
        Write-Plan ("快捷方式 {0} -> {1}" -f $s.Path, $nt)
        $changed++
    }
    if ($changed -eq 0) { Write-Ok '快捷方式里没有需要改动的旧路径' } elseif ($apply) { Write-Done "快捷方式已更新 $changed 个" }
    return $changed
}

# ---------------------------------------------------------------- 状态检查
function Invoke-Status([string]$dir) {
    Write-Title '安装目录'
    if (Test-Path -LiteralPath $dir) {
        $t = Get-TreeInfo $dir
        Write-Ok ("{0}（{1} 个文件，{2:N1} MB）" -f $dir, $t.Count, ($t.Bytes / 1MB))
        foreach ($f in @('Cheat Engine.exe', 'cheatengine-x86_64.exe', 'cheatengine-i386.exe', 'unins000.exe', $script:SelfName)) {
            $p = Join-Path $dir $f
            if (Test-Path -LiteralPath $p) { Write-Ok "存在 $f" } else { Write-Bad "缺少 $f"; $script:Exit = 1 }
        }
    } else {
        Write-Bad "目录不存在：$dir"; $script:Exit = 1
    }

    Write-Title '进程'
    $procs = Get-CeProcesses $dir
    if ($procs.Count -eq 0) { Write-Ok '没有正在运行的进程' }
    else { foreach ($p in $procs) { Write-Note ("运行中: {0} (PID {1})" -f $p.Name, $p.Id) } }

    Write-Title '注册表'
    $paths = @()
    if (Test-Path -LiteralPath $script:UninstallKey) {
        $v = Get-ItemProperty -LiteralPath $script:UninstallKey -ErrorAction SilentlyContinue
        $dv = [string]$v.DisplayVersion
        if (-not $dv) { $dv = '(官方未记录版本号)' }
        Write-Note ("卸载项：{0} | {1}" -f $v.DisplayName, $dv)
        foreach ($n in @('Inno Setup: App Path', 'InstallLocation', 'DisplayIcon', 'UninstallString', 'QuietUninstallString')) {
            $val = [string]$v.$n
            if (-not $val) { continue }
            $paths += [pscustomobject]@{ Name = $n; Value = $val }
        }
    } else { Write-Bad '找不到卸载注册表项（HKLM\...\Uninstall\Cheat Engine_is1）'; $script:Exit = 1 }
    foreach ($k in $script:ClassKeys) {
        foreach ($s in @('\DefaultIcon', '\shell\open\command')) {
            $p = $k + $s
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $cur = (Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue).'(default)'
            if ($cur) { $paths += [pscustomobject]@{ Name = ($p -replace '^HKLM:\\SOFTWARE\\', ''); Value = [string]$cur } }
        }
    }
    foreach ($it in $paths) {
        $inDir = $it.Value.IndexOf($dir, [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($it.Name -in @('UninstallString', 'QuietUninstallString')) {
            if ($it.Value -match [regex]::Escape($script:SelfName)) { Write-Ok ("{0} -> 本脚本" -f $it.Name) }
            elseif ($it.Value -match 'unins000\.exe') { Write-Bad ("{0} -> 官方 unins000.exe（移动目录后不可用，可用 -Action Sync 换成本脚本）" -f $it.Name); $script:Exit = 1 }
            else { Write-Note ("{0} = {1}" -f $it.Name, $it.Value) }
            continue
        }
        if ($inDir) { Write-Ok ("{0} = {1}" -f $it.Name, $it.Value) }
        else { Write-Bad ("{0} = {1}（未指向当前目录）" -f $it.Name, $it.Value); $script:Exit = 1 }
    }
    foreach ($k in $script:ExtKeys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $v = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).'(default)'
        if ($v -eq $script:ProgId) { Write-Ok (("{0} -> {1}" -f (Split-Path -Leaf $k), $v)) }
    }

    Write-Title '快捷方式'
    $all = Get-ShortcutObjects
    $ceLinks = @($all | Where-Object { $_.Target -match 'Cheat Engine' -or $_.Path -match 'Cheat Engine' })
    if ($ceLinks.Count -eq 0) { Write-Bad '没有找到任何 Cheat Engine 快捷方式'; $script:Exit = 1 }
    foreach ($s in $ceLinks) {
        $t = $s.Target
        if (-not $t) { Write-Note ("{0} -> (无目标/网页快捷方式)" -f $s.Path); continue }
        if ($s.Args -match [regex]::Escape($script:SelfName) -and $s.Args -match '-Action\s+Uninstall') {
            Write-Ok ("{0} -> 本脚本（卸载入口）" -f $s.Path); continue
        }
        if ($t.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $t) { Write-Ok ("{0} -> {1}" -f $s.Path, $t) }
            else {
                # 官方包把 32 位教程打成了 .cepack（首次使用时才生成 exe），这种不算路径问题
                $pack = [IO.Path]::ChangeExtension($t, '.cepack')
                if (Test-Path -LiteralPath $pack) {
                    Write-Note ("{0} -> {1}（目标由 {2} 在使用时生成，非路径问题）" -f $s.Path, $t, (Split-Path -Leaf $pack))
                } else {
                    Write-Bad ("{0} -> {1}（目标文件不存在）" -f $s.Path, $t); $script:Exit = 1
                }
            }
        } elseif ($t -match 'notepad\.exe$') {
            Write-Note ("{0} -> {1}（原样保留）" -f $s.Path, $t)
        } else {
            Write-Warn2 ("{0} -> {1}（指向别处的 Cheat Engine，本脚本不会改动）" -f $s.Path, $t)
        }
    }
}

# ---------------------------------------------------------------- Sync
function Invoke-Sync([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { throw "安装目录不存在：$dir" }
    $old = $OldDir
    if (-not $old) { $old = Get-RecordedInstallDir }
    Write-Title '修复指向'
    if ($old) { Write-Note "旧目录（注册表记录）：$old" } else { Write-Warn2 '无法从注册表推断旧目录；如快捷方式仍指向别处，请加 -OldDir 指定' }

    if ($old -and ((Get-NormalizedPath $old) -ne (Get-NormalizedPath $dir))) {
        Update-RegistryPaths $old $dir $true | Out-Null
        Update-ShortcutPaths $old $dir $true | Out-Null
    } elseif ($old) {
        Write-Ok '注册表记录的就是当前目录'
    }
    Set-UninstallerRegistration $dir $true
    Invoke-Status $dir
}

# ---------------------------------------------------------------- Migrate
function Invoke-Migrate([string]$src) {
    if (-not $TargetDir) { throw 'Migrate 需要 -TargetDir 参数，例如 -TargetDir ''D:\Target\Cheat Engine''' }
    $srcN = Get-NormalizedPath $src
    $dst = Get-NormalizedPath $TargetDir
    if (-not (Test-Path -LiteralPath (Join-Path $srcN 'Cheat Engine.exe'))) { throw "源目录不像 Cheat Engine 安装目录：$srcN" }
    if ($dst -eq $srcN) { throw '目标目录与源目录相同' }
    if ($dst.StartsWith($srcN + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '目标目录不能位于源目录内部' }
    if ($srcN.StartsWith($dst + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '源目录不能位于目标目录内部' }
    if (Test-Path -LiteralPath $dst) {
        $n = @(Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { throw "目标目录已存在且非空：$dst" }
    }

    Write-Title '迁移计划'
    $t = Get-TreeInfo $srcN
    Write-Plan ("源目录 : {0}（{1} 个文件，{2:N1} MB）" -f $srcN, $t.Count, ($t.Bytes / 1MB))
    Write-Plan ("目标目录 : {0}" -f $dst)
    Write-Plan '步骤：复制 -> 逐文件校验 -> 删除源目录 -> 同步注册表与快捷方式'

    if ($DryRun) { Write-Note '-DryRun：未做任何改动'; return }
    if (-not (Confirm-Action "确认把 $srcN 迁移到 $dst ？")) { throw '用户取消了操作' }

    Write-Title '结束占用进程'
    Stop-CeProcesses $srcN $true

    Write-Title '复制文件'
    # 注意：Start-Process 的 -ArgumentList 数组不会自动加引号，含空格的路径必须自己包引号
    $rcArgs = @(
        ('"' + $srcN + '"'), ('"' + $dst + '"'),
        '/E', '/COPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS'
    )
    $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcArgs -Wait -PassThru -WindowStyle Hidden
    if ($rc.ExitCode -ge 8) { throw "robocopy 失败，退出码 $($rc.ExitCode)；源目录未删除" }
    Write-Done '复制完成'

    Write-Title '校验'
    $t2 = Get-TreeInfo $dst
    Write-Note ("源 {0} 文件 / {1:N0} B" -f $t.Count, $t.Bytes)
    Write-Note ("目标 {0} 文件 / {1:N0} B" -f $t2.Count, $t2.Bytes)
    if ($t.Count -ne $t2.Count -or $t.Bytes -ne $t2.Bytes) { throw '文件数或总字节不一致，已中止（源目录保持不动，请检查目标目录后清理）' }
    if ($t.Bytes -lt 2GB) {
        $h1 = Get-TreeHash $srcN; $h2 = Get-TreeHash $dst
        $diff = 0
        foreach ($k in $h1.Keys) { if (-not $h2.ContainsKey($k) -or $h2[$k] -ne $h1[$k]) { $diff++ } }
        if ($diff -gt 0) { throw "有 $diff 个文件哈希不一致，已中止（源目录保持不动）" }
        Write-Ok '逐一 SHA256 校验通过'
    } else { Write-Warn2 '目录超过 2 GB，跳过逐文件哈希（已核对文件数与总字节）' }

    Write-Title '删除源目录'
    Remove-Item -LiteralPath $srcN -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $srcN) {
        Get-ChildItem -LiteralPath $srcN -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $script:SelfPath } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $srcN) {
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('timeout /t 2 /nobreak >nul & rmdir /s /q "' + $srcN + '"') -WindowStyle Hidden
            Write-Warn2 "源目录有文件被占用，已安排 2 秒后后台删除：$srcN"
        } else { Write-Done '源目录已删除' }
    } else { Write-Done '源目录已删除' }

    Write-Title '同步注册表与快捷方式'
    Update-RegistryPaths $srcN $dst $true | Out-Null
    Update-ShortcutPaths $srcN $dst $true | Out-Null
    Set-UninstallerRegistration $dst $true

    Write-Title '迁移完成'
    Write-Done ("新位置：{0}" -f $dst)
    Write-Note ("脚本新路径：{0}" -f (Join-Path $dst $script:SelfName))
    Write-Note ("回滚：& '{0}' -Action Migrate -TargetDir '{1}' -Force" -f (Join-Path $dst $script:SelfName), $srcN)
    Write-Note '提示：unins000.dat 里记录的仍是旧路径，官方 unins000.exe 不可用；"应用和功能"的卸载入口已指向本脚本。'
}

# ---------------------------------------------------------------- Uninstall
function Invoke-Uninstall([string]$dir) {
    $dirN = Get-NormalizedPath $dir
    Write-Title '卸载计划'
    $exists = Test-Path -LiteralPath $dirN
    if ($exists) {
        $t = Get-TreeInfo $dirN
        Write-Plan ("安装目录 : {0}（{1} 个文件，{2:N1} MB）" -f $dirN, $t.Count, ($t.Bytes / 1MB))
    } else { Write-Warn2 "安装目录不存在：$dirN（只清理注册表与快捷方式）" }

    $procs = Get-CeProcesses $dirN
    if ($procs.Count -gt 0) { Write-Plan ("将结束进程：{0}" -f (($procs | ForEach-Object { "$($_.Name)($($_.Id))" }) -join ', ')) }

    # 快捷方式
    $toDelete = New-Object System.Collections.ArrayList
    $keep = New-Object System.Collections.ArrayList
    $grp = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Cheat Engine'
    foreach ($s in (Get-ShortcutObjects)) {
        $inDir = $s.Target -and $s.Target.StartsWith($dirN + '\', [StringComparison]::OrdinalIgnoreCase)
        $isOurUninstaller = ($s.Args -match [regex]::Escape($script:SelfName)) -and ($s.Args -match '-Action\s+Uninstall')
        $inGrp = $s.Path.StartsWith($grp + '\', [StringComparison]::OrdinalIgnoreCase)
        if ($inDir -or $isOurUninstaller) { [void]$toDelete.Add($s) }
        elseif ($inGrp) { [void]$keep.Add($s) }
    }
    if (Test-Path -LiteralPath $grp) { Write-Plan ("开始菜单组 : {0}" -f $grp) }
    foreach ($s in $toDelete) { Write-Plan ("删除快捷方式 {0} -> {1}" -f $s.Path, $s.Target) }
    foreach ($s in $keep) { Write-Warn2 ("保留（目标不属于本目录）：{0} -> {1}" -f $s.Path, $s.Target) }

    # 注册表
    if (Test-Path -LiteralPath $script:UninstallKey) { Write-Plan ("删除注册表项 {0}" -f $script:UninstallKey) }
    foreach ($k in $script:ClassKeys) { if (Test-Path -LiteralPath $k) { Write-Plan ("删除注册表项 {0}" -f $k) } }
    foreach ($k in $script:ExtKeys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        if ((Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).'(default)' -eq $script:ProgId) {
            Write-Plan ("清除文件关联 {0} 的 (默认) = {1}" -f $k, $script:ProgId)
        }
    }
    foreach ($svc in $script:DriverServices) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) { Write-Plan ("驱动服务 {0}（{1}）将被停止并删除" -f $svc, $s.Status) }
    }
    if ($RemoveUserSettings) {
        Write-Plan '删除用户配置 HKCU\Software\Cheat Engine'
        Write-Plan ("删除用户配置 {0}" -f (Join-Path $env:APPDATA 'Cheat Engine'))
    }

    if ($DryRun) { Write-Note '-DryRun：未做任何改动'; return }
    if (-not (Confirm-Action "确认彻底卸载 $dirN ？此操作不可撤销")) { throw '用户取消了操作' }

    Write-Title '结束进程'
    Stop-CeProcesses $dirN $true

    Write-Title '删除快捷方式'
    $n = 0
    foreach ($s in $toDelete) {
        Remove-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $s.Path)) { Write-Done ("已删除 {0}" -f $s.Path); $n++ }
        else { Write-Warn2 ("删除失败 {0}" -f $s.Path) }
    }
    if ($n -eq 0) { Write-Ok '没有需要删除的快捷方式' }
    if (Test-Path -LiteralPath $grp) {
        foreach ($sub in (Get-ChildItem -LiteralPath $grp -Directory -Force -ErrorAction SilentlyContinue)) {
            if (@(Get-ChildItem -LiteralPath $sub.FullName -Recurse -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $sub.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (@(Get-ChildItem -LiteralPath $grp -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $grp -Force -ErrorAction SilentlyContinue
            Write-Done '已删除空的开始菜单组'
        }
    }

    Write-Title '清理注册表'
    if (Test-Path -LiteralPath $script:UninstallKey) {
        Remove-Item -LiteralPath $script:UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $script:UninstallKey)) { Write-Done '已删除卸载注册表项' } else { Write-Warn2 '删除卸载注册表项失败' }
    }
    foreach ($k in $script:ClassKeys) {
        if (Test-Path -LiteralPath $k) {
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $k)) { Write-Done ("已删除 {0}" -f $k) }
        }
    }
    foreach ($k in $script:ExtKeys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        if ((Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).'(default)' -eq $script:ProgId) {
            Remove-ItemProperty -LiteralPath $k -Name '(default)' -Force -ErrorAction SilentlyContinue
            Write-Done ("已清除 {0} 的关联" -f $k)
        }
        Remove-ItemProperty -LiteralPath $k -Name $script:ProgId -ErrorAction SilentlyContinue
    }
    foreach ($hive in @('HKCU:')) {
        foreach ($ext in @('.CT', '.CETRAINER')) {
            $uk = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
            if (Test-Path -LiteralPath $uk) {
                if ((Get-ItemProperty -LiteralPath $uk -ErrorAction SilentlyContinue).ProgId -eq $script:ProgId) {
                    Remove-Item -LiteralPath $uk -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Done ("已删除用户级关联选择 {0}" -f $uk)
                }
            }
        }
    }

    Write-Title '驱动服务'
    $foundSvc = $false
    foreach ($svc in $script:DriverServices) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        $foundSvc = $true
        if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
        $r = Start-Process -FilePath 'sc.exe' -ArgumentList @('delete', $svc) -Wait -PassThru -WindowStyle Hidden
        if ($r.ExitCode -eq 0) { Write-Done ("已删除驱动服务 {0}" -f $svc) } else { Write-Warn2 ("删除驱动服务 {0} 失败（退出码 {1}）" -f $svc, $r.ExitCode) }
    }
    if (-not $foundSvc) { Write-Ok '没有残留的 dbk64/dbk32 驱动服务' }

    if ($RemoveUserSettings) {
        Write-Title '删除用户配置'
        if (Test-Path -LiteralPath 'HKCU:\Software\Cheat Engine') {
            Remove-Item -LiteralPath 'HKCU:\Software\Cheat Engine' -Recurse -Force -ErrorAction SilentlyContinue
            Write-Done '已删除 HKCU\Software\Cheat Engine'
        }
        foreach ($p in @((Join-Path $env:APPDATA 'Cheat Engine'), (Join-Path $env:LOCALAPPDATA 'Cheat Engine'))) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue; Write-Done ("已删除 {0}" -f $p) }
        }
    }

    Write-Title '删除安装目录'
    if (-not (Test-Path -LiteralPath $dirN)) { Write-Ok '安装目录已不存在' }
    else {
        $selfInDir = $script:SelfPath -and $script:SelfPath.StartsWith($dirN + '\', [StringComparison]::OrdinalIgnoreCase)
        if (-not $selfInDir) {
            Remove-Item -LiteralPath $dirN -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            # 本脚本就在待删目录里：先删其余内容，再删除目录（必要时交给后台进程）
            Get-ChildItem -LiteralPath $dirN -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $script:SelfPath } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dirN -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $dirN)) { Write-Done ("已删除 {0}" -f $dirN) }
        else {
            $left = @(Get-ChildItem -LiteralPath $dirN -Recurse -Force -ErrorAction SilentlyContinue)
            foreach ($f in $left) { Write-Warn2 ("残留：{0}" -f $f.FullName) }
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('timeout /t 2 /nobreak >nul & rmdir /s /q "' + $dirN + '"') -WindowStyle Hidden
            Write-Warn2 '目录仍被占用，已安排 2 秒后由后台进程删除'
        }
    }

    Write-Title '卸载完成'
    Write-Note 'Cheat Engine 的文件、快捷方式与注册表项均已移除。'
}

# ---------------------------------------------------------------- 主流程
function Invoke-Elevate {
    $hostExe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $hostExe) { $hostExe = $script:PsExe }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:SelfPath + '"'), '-Action', $Action)
    if ($TargetDir) { $a += @('-TargetDir', ('"' + $TargetDir + '"')) }
    if ($InstallDir) { $a += @('-InstallDir', ('"' + $InstallDir + '"')) }
    if ($OldDir) { $a += @('-OldDir', ('"' + $OldDir + '"')) }
    if ($RemoveUserSettings) { $a += '-RemoveUserSettings' }
    if ($KeepInnoUninstaller) { $a += '-KeepInnoUninstaller' }
    if ($Force) { $a += '-Force' }
    $a += '-NoElevate'
    Write-Note '需要管理员权限，正在提权…'
    try {
        $p = Start-Process -FilePath $hostExe -ArgumentList $a -Verb RunAs -Wait -PassThru -ErrorAction Stop
        exit $p.ExitCode
    } catch {
        Write-Err2 "提权失败或被取消：$($_.Exception.Message)"
        exit 1
    }
}

try {
    $dir = if ($InstallDir) { Get-NormalizedPath $InstallDir } else { Get-NormalizedPath (Split-Path -Parent $script:SelfPath) }
    Write-Host ''
    Write-Host "Cheat Engine 安装管理脚本" -ForegroundColor White
    Write-Host ("动作: {0}   目标目录: {1}" -f $Action, $dir) -ForegroundColor White
    if ($DryRun) { Write-Host '（DryRun 模式：只显示计划，不做修改）' -ForegroundColor DarkCyan }

    $needWrite = ($Action -ne 'Status') -and (-not $DryRun)
    if ($needWrite -and (-not (Test-IsAdmin))) {
        if ($NoElevate) { throw '该动作需要管理员权限（注册表 HKLM / 目录删除）。请用管理员身份运行。' }
        Invoke-Elevate
    }

    switch ($Action) {
        'Status' { Invoke-Status $dir }
        'Sync' { Invoke-Sync $dir }
        'Migrate' { Invoke-Migrate $dir }
        'Uninstall' { Invoke-Uninstall $dir }
    }
} catch {
    Write-Host ''
    Write-Err2 $_.Exception.Message
    exit 1
}
exit $script:Exit
