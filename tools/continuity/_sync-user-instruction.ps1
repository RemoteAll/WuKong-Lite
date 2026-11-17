#Requires -Version 5.1
<#
.SYNOPSIS
    把本机用户级指令（已按技术栈拆分的多个 .instructions.md）字节级同步到所有已装备仓库的模板副本。

.DESCRIPTION
    唯一真相源：%APPDATA%\Code\User\prompts\ 下的 5 个用户级文件
      跨项目接续协议 / Rust项目规范 / 服务端与数据规范 / 前端规范 / Zig项目规范
    同步目标   ：<各仓库>\tools|Tools\continuity\templates\<同名>.instructions.md
    另：旧的单文件副本 `用户级指令.instructions.md` 会被覆盖成**索引文件**（指向上面 5 个），
        保留是为了不打断仍引用它的脚本/文档，内容不再承载规则。

    VS Code 侧按 applyTo 按需加载，本机 prompts 目录才是真正生效的地方；仓库副本用于跨机器回灌与审计。

    安全检查：
      · 只覆盖「模板副本」，不碰本机 prompts 目录；
      · 覆盖前把旧内容备份到 _bak\<时间戳>\ 下；
      · 版本守卫：仓库副本版本更高则拒绝覆盖（需显式 -AllowDowngrade）。

.PARAMETER Roots
    扫描根目录，默认 E:\Code 与 G:\Code 与 G:\Project。

.PARAMETER SkipBackup
    跳过备份（仅在已确认副本都在 git 仓库内、可随时还原时使用）。

.PARAMETER Check
    只巡检不写入。退出码：0 = 全盘一致；1 = 有副本落后/同版本不同内容；3 = 有副本比本机新。

.PARAMETER AllowDowngrade
    允许用较旧的本机副本覆盖较新的仓库副本（危险）。

.EXAMPLE
    .\_sync-user-instruction.ps1 -Check -Roots 'E:\Code'

.NOTES
    版本：2026.11.12.3（支持拆分后的多文件；旧版只同步单文件）
#>
[CmdletBinding()]
param(
    [string[]]$Roots = @('E:\Code', 'G:\Code', 'G:\Project'),
    [switch]$SkipBackup,
    [switch]$Check,
    [switch]$AllowDowngrade
)

$ErrorActionPreference = 'Stop'

$UserNames = @(
    '跨项目接续协议',
    'Rust项目规范',
    '服务端与数据规范',
    '前端规范',
    'Zig项目规范'
)
$LegacyName = '用户级指令'
$promptsDir = Join-Path $env:APPDATA 'Code\User\prompts'
$VerPattern = '版本：(\d{4}\.\d{2}\.\d{2}\.\d+)'

function Get-FileVersion([string]$path) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $ms = [regex]::Matches($text, $VerPattern)
    if ($ms.Count -eq 0) { return '' }
    return $ms[$ms.Count - 1].Groups[1].Value
}

function Test-VersionNewer([string]$a, [string]$b) {
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

# ---- 组装源清单 ----
$sources = @()
foreach ($n in $UserNames) {
    $path = Join-Path $promptsDir "$n.instructions.md"
    if (-not (Test-Path $path)) {
        Write-Host "未找到本机用户级指令：$path" -ForegroundColor Red
        exit 2
    }
    $sources += [pscustomobject]@{
        Name = $n
        Path = $path
        Ver  = (Get-FileVersion $path)
        Hash = (Get-FileHash $path -Algorithm SHA256).Hash
    }
}

$verSet = @($sources | ForEach-Object { $_.Ver } | Sort-Object -Unique)
if ($verSet.Count -ne 1 -or -not $verSet[0]) {
    Write-Host ("各文件版本号不一致或缺失：{0} —— 请先统一版本号。" -f ($verSet -join ', ')) -ForegroundColor Red
    exit 2
}
$srcVer = $verSet[0]

$indexBody = @"
# 用户级指令（已按技术栈拆分）

本目录下的用户级规则已拆成多个 ``.instructions.md``，逐个文件才是真相源：

| 文件 | 覆盖范围 |
|---|---|
| 跨项目接续协议.instructions.md | 接续流程、上下文成本、复用纪律、实测优先、日志、回归门槛、资源带宽（``applyTo: **``） |
| Rust项目规范.instructions.md | 编译提速、打包发版、国内镜像、源码拉新、检索词表 |
| 服务端与数据规范.instructions.md | HTTP/WAF、登录口令、数据库连接命名、Pek.RCode |
| 前端规范.instructions.md | 面板弹窗、后台配置页 |
| Zig项目规范.instructions.md | 异步与并发、串口/硬件调测 |

本文件仅作索引，不再承载规则。

<!-- 版本：2026.11.12.3（兼容存根；真实规则见 5 个拆分文件） -->
"@
$indexPath = Join-Path $env:TEMP 'user-instruction-index.instructions.md'
[IO.File]::WriteAllText($indexPath, $indexBody, (New-Object Text.UTF8Encoding $false))
$sources += [pscustomobject]@{
    Name = $LegacyName
    Path = $indexPath
    Ver  = $srcVer
    Hash = (Get-FileHash $indexPath -Algorithm SHA256).Hash
}

Write-Host "用户级指令：$($UserNames.Count) 个文件 + 1 个索引"
Write-Host "版本：$srcVer"
foreach ($s in $sources) { Write-Host ("  {0,-20} {1}" -f $s.Name, $s.Hash.Substring(0, 12)) }
Write-Host ''

# ---- 全盘扫描：先找 continuity\templates 目录，再按 6 个文件名生成目标（缺失的也要建） ----
$templateDirs = @()
foreach ($r in $Roots) {
    if (-not (Test-Path $r)) { continue }
    $templateDirs += Get-ChildItem $r -Recurse -Directory -Filter 'templates' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'continuity' }
}
$templateDirs = @($templateDirs | Sort-Object FullName -Unique)

$targets = @()
foreach ($d in $templateDirs) {
    foreach ($n in ($UserNames + $LegacyName)) {
        $full = Join-Path $d.FullName "$n.instructions.md"
        $targets += [pscustomobject]@{
            FullName = $full
            Name     = "$n.instructions.md"
            Exists   = (Test-Path $full)
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Host '未找到任何模板副本（检查 -Roots）。' -ForegroundColor Yellow
    exit 1
}

$bakDir = $null
if (-not $SkipBackup -and -not $Check) {
    $bakDir = Join-Path $env:TEMP ("continuity-bak\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
}

$changed = 0
$skipped = 0
$newer = @()
$sameVerDiff = @()
$older = @()
$unmatched = @()
$i = 0

foreach ($f in $targets) {
    $i++
    $leaf = $f.Name -replace '\.instructions\.md$', ''
    $src = @($sources | Where-Object { $_.Name -eq $leaf }) | Select-Object -First 1
    if (-not $src) { $unmatched += $f.FullName; continue }

    if (-not $f.Exists) {
        if ($Check) {
            $older += [pscustomobject]@{ Path = $f.FullName; Ver = '(缺失)' }
        } else {
            Copy-Item $src.Path $f.FullName -Force
            $changed++
            if ($changed -le 40) { Write-Host "  新建 $($f.FullName)" }
        }
        continue
    }

    $h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    if ($h -eq $src.Hash) { $skipped++; continue }

    $v = Get-FileVersion $f.FullName
    if (Test-VersionNewer $v $srcVer) {
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
        $repoName = Split-Path $repo -Leaf
        $bak = Join-Path $bakDir ("{0:d3}_{1}_{2}.md" -f $i, $repoName, $leaf)
        Copy-Item $f.FullName $bak -Force
    }

    Copy-Item $src.Path $f.FullName -Force
    $changed++
    if ($changed -le 40) { Write-Host "  更新 $($f.FullName)" }
}

Write-Host ''
if ($Check) {
    Write-Host "巡检 $($targets.Count) 个副本：一致 $skipped 个，落后 $($older.Count) 个，同版本不同内容 $($sameVerDiff.Count) 个，**比本机新 $($newer.Count) 个**。"
    foreach ($x in $newer) { Write-Host "  [本机副本过期] $($x.Path)  ver=$($x.Ver)" -ForegroundColor Yellow }
    foreach ($x in $sameVerDiff) { Write-Host "  [同版本内容不同] $($x.Path)" -ForegroundColor Yellow }
    if ($unmatched.Count -gt 0) { Write-Host "  [无对应源，已跳过] $($unmatched.Count) 个" -ForegroundColor Yellow }
    if ($newer.Count -gt 0) {
        Write-Host '结论：本机副本不是最新的 —— 先回灌本机再递增版本号。' -ForegroundColor Red
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
    Write-Host "拒绝降级：$($newer.Count) 个副本比本机新，已保留原样（本机 $srcVer）。" -ForegroundColor Red
}

$srcHashes = @($sources | ForEach-Object { $_.Hash } | Sort-Object -Unique)
$dstHashes = @($targets | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash } | Sort-Object -Unique)
$extra = @($dstHashes | Where-Object { $srcHashes -notcontains $_ })
Write-Host ("副本哈希种类：{0} / 源哈希种类：{1}" -f $dstHashes.Count, $srcHashes.Count)
Write-Host ("与本机完全一致：" + $(if ($extra.Count -eq 0) { '是' } else { '否（有副本内容不在源集合里）' })) -ForegroundColor $(if ($extra.Count -eq 0) { 'Green' } else { 'Red' })
if ($bakDir) { Write-Host "旧副本备份：$bakDir" }

if ($newer.Count -gt 0) { exit 3 }
if ($extra.Count -gt 0) { exit 1 }
exit 0
