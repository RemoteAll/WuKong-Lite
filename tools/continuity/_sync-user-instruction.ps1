#Requires -Version 5.1
<#
.SYNOPSIS
    把本机用户级指令（跨项目接续协议）字节级同步到所有已装备仓库的模板副本。

.DESCRIPTION
    唯一真相源：%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md
    同步目标   ：<各仓库>\tools|Tools\continuity\templates\用户级指令.instructions.md

    旧版本把 16 个仓库路径硬编码在脚本里，仓库一多就漏（2026-11-05 全盘扫到 110 个副本，
    版本从 2026.10.10.4 到 2026.11.03.1 参差不齐）。本版改为**全盘扫描**：
    先改本机副本 -> 跑本脚本 -> 所有副本字节一致 -> 各仓库自行 commit/push。

    安全检查：
      · 只覆盖「模板副本」，不碰本机副本自身；
      · 覆盖前把旧内容备份到 _bak\<时间戳>\ 下（按序号 + 仓库名命名）。

.PARAMETER Roots
    扫描根目录，默认覆盖 G:\Code 与 G:\Project。

.PARAMETER SkipBackup
    跳过备份（仅在已确认副本都在 git 仓库内、可随时还原时使用）。

.PARAMETER Check
    只巡检不写入：列出「比本机副本新」与「同版本不同内容」的副本，不修改任何文件。
    退出码：0 = 全盘一致；1 = 有副本落后/同版本不同内容（需同步）；3 = 有副本比你新（本机副本是旧的，先回灌再改）。

.PARAMETER AllowDowngrade
    允许用较旧的本机副本覆盖较新的仓库副本（危险，仅在你确认要回退时用）。

.EXAMPLE
    .\_sync-user-instruction.ps1

.EXAMPLE
    .\_sync-user-instruction.ps1 -Check

.EXAMPLE
    .\_sync-user-instruction.ps1 -Roots 'G:\Code\Rust'

.NOTES
    版本：2026.11.08.1（新增版本守卫与 -Check；旧副本不得覆盖新副本）
#>
[CmdletBinding()]
param(
    [string[]]$Roots = @('G:\Code', 'G:\Project'),
    [switch]$SkipBackup,
    [switch]$Check,
    [switch]$AllowDowngrade
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $env:APPDATA 'Code\User\prompts\跨项目接续协议.instructions.md'
if (-not (Test-Path $source)) {
    Write-Host "未找到本机副本：$source" -ForegroundColor Red
    exit 2
}

$srcVer = ([regex]::Match([IO.File]::ReadAllText($source, [Text.Encoding]::UTF8), '版本：([0-9.]+)')).Groups[1].Value
$srcHash = (Get-FileHash $source -Algorithm SHA256).Hash
Write-Host "源：$source"
Write-Host "版本：$srcVer"
Write-Host "SHA256：$srcHash"
Write-Host ''

function Get-FileVersion([string]$path) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '版本：([0-9]+(?:\.[0-9]+)*)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Test-VersionNewer([string]$a, [string]$b) {
    # $a 比 $b 新则返回 $true（分段数值比较）
    $pa = @(); if ($a) { $pa = $a.Split('.') | ForEach-Object { [int]$_ } }
    $pb = @(); if ($b) { $pb = $b.Split('.') | ForEach-Object { [int]$_ } }
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($k = 0; $k -lt $n; $k++) {
        $x = 0; $y = 0
        if ($k -lt $pa.Count) { $x = $pa[$k] }
        if ($k -lt $pb.Count) { $y = $pb[$k] }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    return $false
}

# ---- 全盘扫描模板副本 ----
$targets = @()
foreach ($r in $Roots) {
    if (-not (Test-Path $r)) { continue }
    $targets += Get-ChildItem $r -Recurse -Filter '用户级指令.instructions.md' -File -ErrorAction SilentlyContinue
}
$targets = $targets | Sort-Object FullName -Unique

if (-not $targets) {
    Write-Host '未找到任何模板副本（检查 -Roots）。' -ForegroundColor Yellow
    exit 1
}

# ---- 备份目录（放临时目录，不污染仓库工作区） ----
$bakDir = $null
if (-not $SkipBackup) {
    $bakDir = Join-Path $env:TEMP ("continuity-bak\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
}

$changed = 0
$skipped = 0
$newer = @()
$sameVerDiff = @()
$older = @()
$i = 0
foreach ($f in $targets) {
    $i++
    $h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    if ($h -eq $srcHash) { $skipped++; continue }

    $v = Get-FileVersion $f.FullName
    if (Test-VersionNewer $v $srcVer) {
        # 守卫：仓库副本比本机新 -> 绝不覆盖（本机副本才是过期的那个）
        $newer += [pscustomobject]@{ Path = $f.FullName; Ver = $v }
        Write-Host ("  [较新，未覆盖] $($f.FullName)  ver=$v > src=$srcVer") -ForegroundColor Yellow
        if (-not $AllowDowngrade) { continue }
    } elseif ($v -eq $srcVer) {
        $sameVerDiff += [pscustomobject]@{ Path = $f.FullName; Ver = $v }
    } else {
        $older += [pscustomobject]@{ Path = $f.FullName; Ver = $v }
    }

    if ($Check) { continue }

    if ($bakDir) {
        $repo = Split-Path (Split-Path (Split-Path (Split-Path $f.FullName)))
        $name = Split-Path $repo -Leaf
        $bak = Join-Path $bakDir ("{0:d3}_{1}.md" -f $i, $name)
        Copy-Item $f.FullName $bak -Force
    }

    Copy-Item $source $f.FullName -Force
    $changed++
    Write-Host "  更新 $($f.FullName)"
}

Write-Host ''
if ($Check) {
    Write-Host "巡检 $($targets.Count) 个副本：一致 $skipped 个，落后 $($older.Count) 个，同版本不同内容 $($sameVerDiff.Count) 个，**比本机新 $($newer.Count) 个**。"
    foreach ($n in $newer) { Write-Host "  [本机副本过期] $($n.Path)  ver=$($n.Ver)" -ForegroundColor Yellow }
    foreach ($d in $sameVerDiff) { Write-Host "  [同版本内容不同] $($d.Path)" -ForegroundColor Yellow }
    if ($newer.Count -gt 0) {
        Write-Host '结论：本机副本不是最新的 —— 先把最新副本回灌到本机（备份本机后合并），再递增版本号同步。' -ForegroundColor Red
        exit 3
    }
    if (($sameVerDiff.Count + $older.Count) -gt 0) {
        Write-Host '结论：有副本落后或内容不一致，需要跑一次同步。' -ForegroundColor Yellow
        exit 1
    }
    Write-Host '结论：全盘一致。' -ForegroundColor Green
    exit 0
}

Write-Host "扫描 $($targets.Count) 个副本：更新 $changed 个，已一致 $skipped 个。"
if ($newer.Count -gt 0) {
    Write-Host "拒绝降级：$($newer.Count) 个副本比本机副本新，已保留原样（本机版本 $srcVer）。" -ForegroundColor Red
    Write-Host '请先把最新副本回灌到本机并合并，递增版本号后重跑本脚本；确需回退请显式加 -AllowDowngrade。' -ForegroundColor Red
}

$hashes = $targets | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
$uniq = ($hashes | Sort-Object -Unique).Count
Write-Host "哈希去重数：$uniq / 文件数 $($hashes.Count)"
$localHash = (Get-FileHash $source -Algorithm SHA256).Hash
$allMatch = -not ($hashes | Where-Object { $_ -ne $localHash })
Write-Host ("与本机副本完全一致：" + $(if ($allMatch) { '是' } else { '否（仍有差异）' })) -ForegroundColor $(if ($allMatch) { 'Green' } else { 'Red' })
if ($bakDir) { Write-Host "旧副本备份：$bakDir" }

if ($newer.Count -gt 0) { exit 3 }
if (-not $allMatch) { exit 1 }
exit 0
