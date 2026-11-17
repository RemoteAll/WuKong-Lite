#Requires -Version 5.1
<#
.SYNOPSIS
  同步官方 Luban-Lite 的文档技能与第三方许可证到 docs\official，并记录上游版本。
.DESCRIPTION
  以本地官方 SDK（默认 G:\Code\C\luban-lite）为源：
    - doc\skills\**            -> docs\official\skills\**
    - doc\license-3rd-party.txt -> docs\official\LICENSE-3rd-party.txt
  同时写 docs\official\UPSTREAM.json（commit/branch/时间/逐文件 SHA256/未迁移范围）。
  -Check  只比对不写入；退出码 0=一致，1=有漂移，2=源不可用。
  -Github 额外查询 github.com/artinchip/luban-lite 默认分支 HEAD（网络失败只告警）。
  -NoDocs 只刷新 UPSTREAM.json，不复制文档。
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-upstream.ps1 -Check
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-upstream.ps1
#>
param(
    [string]$Source = 'G:\Code\C\luban-lite',
    [switch]$Check,
    [switch]$Github,
    [switch]$NoDocs
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$destRoot = Join-Path $projectRoot 'docs\official'
$manifestPath = Join-Path $destRoot 'UPSTREAM.json'
$repoUrl = 'https://github.com/artinchip/luban-lite'

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Host "[上游同步] 源不存在：$Source"
    exit 2
}
$Source = (Resolve-Path -LiteralPath $Source).Path

function Get-RelativeFiles {
    param([string]$Root, [string]$Pattern, [string[]]$ExcludeDir = @())
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
            if ($rel -match '(^|[\\/])__pycache__([\\/]|$)') { return $false }
            $skip = $false
            foreach ($d in $ExcludeDir) {
                if ($rel -like "$d\*" -or $rel -like "$d/*") { $skip = $true; break }
            }
            -not $skip
        }
}

function Get-Sha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# 源文件清单：skills 递归（排除 __pycache__）+ 许可证
$srcSkills = Join-Path $Source 'doc\skills'
$srcLicense = Join-Path $Source 'doc\license-3rd-party.txt'
$srcFiles = @()
if (Test-Path -LiteralPath $srcSkills) {
    $srcFiles += Get-RelativeFiles -Root $srcSkills -Pattern '*' -ExcludeDir @('__pycache__')
}
if (Test-Path -LiteralPath $srcLicense) {
    $srcFiles += Get-Item -LiteralPath $srcLicense
}

$map = [ordered]@{}
foreach ($f in $srcFiles) {
    if ($f.FullName.StartsWith($srcSkills, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = 'skills/' + $f.FullName.Substring($srcSkills.Length).TrimStart('\', '/').Replace('\', '/')
    } else {
        $rel = 'LICENSE-3rd-party.txt'
    }
    $map[$rel] = $f
}

# 目标文件哈希
$destMap = [ordered]@{}
if (Test-Path -LiteralPath $destRoot) {
    Get-ChildItem -LiteralPath $destRoot -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($destRoot.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel -ne 'UPSTREAM.json' -and ($rel -like 'skills/*' -or $rel -eq 'LICENSE-3rd-party.txt')) {
            $destMap[$rel] = $_
        }
    }
}

$missing = @(); $changed = @(); $extra = @()
foreach ($rel in $map.Keys) {
    if (-not $destMap.Contains($rel)) {
        $missing += $rel
    } elseif ((Get-Sha256 $map[$rel].FullName) -ne (Get-Sha256 $destMap[$rel].FullName)) {
        $changed += $rel
    }
}
foreach ($rel in $destMap.Keys) {
    if (-not $map.Contains($rel)) { $extra += $rel }
}

# 上游版本
$commit = $null; $branch = $null
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    $commit = (& git -C $Source rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $commit) { $commit = $null }
    $branch = (& git -C $Source rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $branch = $null }
}
if (-not $commit) { $commit = 'unknown' }
if (-not $branch) { $branch = 'unknown' }

$oldCommit = $null
if (Test-Path -LiteralPath $manifestPath) {
    try { $oldCommit = (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).commit } catch { }
}

$remoteHead = $null
if ($Github -and $gitCmd) {
    try {
        $remoteHead = (& git ls-remote $repoUrl HEAD 2>$null | Select-Object -First 1).Split("`t")[0]
        if ($LASTEXITCODE -ne 0) { $remoteHead = $null }
    } catch { }
    if (-not $remoteHead) { Write-Host "[上游同步] 无法查询 GitHub HEAD（离线或网络受限），已跳过远端比对" }
    elseif ($commit -ne 'unknown' -and $remoteHead -ne $commit) {
        Write-Host "[上游同步] 注意：GitHub HEAD=$remoteHead，本地源 commit=$commit，本地 SDK 可能落后"
    }
}

$drift = ($missing.Count + $changed.Count + $extra.Count)
if ($Check) {
    Write-Host "[上游同步] 源：$Source"
    Write-Host "[上游同步] 本地源 commit：$commit（$branch）；清单记录：$oldCommit"
    Write-Host "[上游同步] 缺失 $($missing.Count) / 变更 $($changed.Count) / 多余 $($extra.Count)"
    foreach ($r in $missing) { Write-Host "  + $r" }
    foreach ($r in $changed) { Write-Host "  ~ $r" }
    foreach ($r in $extra) { Write-Host "  - $r" }
    if ($remoteHead) { Write-Host "[上游同步] GitHub HEAD：$remoteHead" }
    if ($drift -gt 0) { exit 1 }
    if ($oldCommit -and $oldCommit -ne $commit) {
        Write-Host "[上游同步] 文档内容一致，但记录 commit 与当前源不同（$oldCommit -> $commit）；重新运行不带 -Check 以刷新清单"
        exit 1
    }
    exit 0
}

if (-not $NoDocs) {
    foreach ($rel in $map.Keys) {
        $target = Join-Path $destRoot $rel.Replace('/', '\')
        $dir = Split-Path $target -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item -LiteralPath $map[$rel].FullName -Destination $target -Force
    }
    if (-not (Test-Path -LiteralPath $destRoot)) { New-Item -ItemType Directory -Force -Path $destRoot | Out-Null }
}

$entries = @()
foreach ($rel in $map.Keys) {
    $target = Join-Path $destRoot $rel.Replace('/', '\')
    if (Test-Path -LiteralPath $target) {
        $entries += [ordered]@{
            path   = $rel
            size   = (Get-Item -LiteralPath $target).Length
            sha256 = (Get-Sha256 $target)
        }
    }
}

$manifest = [ordered]@{
    repository  = $repoUrl
    source_path = $Source
    branch      = $branch
    commit      = $commit
    github_head = $remoteHead
    synced_at   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    scope       = @('doc/skills/**', 'doc/license-3rd-party.txt')
    excluded    = @('doc/topics/**', 'doc/images/**', 'doc/webhelp/**')
    files       = $entries
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "[上游同步] 已写入 $($entries.Count) 个文件；commit=$commit（$branch）"
Write-Host "[上游同步] 清单：$manifestPath"
exit 0
