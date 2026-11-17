# 跨项目接续协议 · 工作记忆同步（本机工作记忆 -> 项目 docs\项目记忆.md）
# 来源：本机 workspaceStorage\<工作区>\GitHub.copilot-chat\memory-tool\memories\repo\*.md
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools/continuity/sync-memory.ps1
#       也可显式指定项目根：... -ProjectPath <项目根目录>
#       本机记忆为空且镜像已存在时默认跳过（防稀疏记忆覆盖完整镜像），-Force 强制写入。
# 合并规则（2026-11-10 重写）：
#   1. 本机记忆按 `## <文件名>` 小节写入（同名以本机记忆为准）；
#   2. **镜像里出现、但新内容里没有的非空行**一律收进末尾「历史归档」块，**绝不丢内容**；
#      归档块带标记、下轮原样带出，不会无限膨胀。
#   3. 旧实现只把 `## xxx.md` 当小节边界 -> 早期人写小节（`## v0.1.5 UI 文案整理`）被整段丢弃
#      （2026-11-10 实测一次同步删掉 129 行），故改为「按行差集」的兜底策略。
# 说明：本脚本含中文，必须以 UTF-8 with BOM 保存（Windows PowerShell 5.1 按 GBK 读无 BOM 会报语法错误）。

param(
    [string]$ProjectPath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# 项目根：优先 -ProjectPath；默认取脚本位置（tools\continuity）的上两级（可从任意目录运行）
if ($ProjectPath) {
    if (-not (Test-Path $ProjectPath)) {
        Write-Host "[记忆同步] 错误：-ProjectPath 不存在：$ProjectPath"
        exit 2
    }
    $projectRoot = (Resolve-Path $ProjectPath).Path
} else {
    $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
$projectName = Split-Path $projectRoot -Leaf
$outFile = Join-Path $projectRoot 'docs\项目记忆.md'
$slug = $projectName.ToLower() -replace '\.', '-'

$storage = Join-Path $env:APPDATA 'Code\User\workspaceStorage'
if (-not (Test-Path $storage)) {
    Write-Host '[记忆同步] 跳过：未找到 workspaceStorage'
    exit 0
}

# 定位本项目对应的记忆目录：
#   ① 单文件夹工作区（workspace.json 无 "folders" 字段）且包含本项目 → 该目录全部 *.md；
#   ② 无单文件夹匹配时退到多根工作区（含 "folders"）→ 仅收文件名含项目 slug 的文件，防混入其他项目记忆。
$exact = @(); $multi = @()
Get-ChildItem $storage -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $wj = Join-Path $_.FullName 'workspace.json'
    if (Test-Path $wj) {
        try {
            $t = [IO.File]::ReadAllText($wj, [Text.Encoding]::UTF8)
            $decoded = [uri]::UnescapeDataString($t)
            if ($decoded -like "*$projectName*") {
                $memDir = Join-Path $_.FullName 'GitHub.copilot-chat\memory-tool\memories\repo'
                if (Test-Path $memDir) {
                    if ($t -like '*"folders"*') { $multi += $memDir } else { $exact += $memDir }
                }
            }
        } catch { }
    }
}
$useSlugFilter = $false
$dirs = @()
if ($exact.Count -gt 0) {
    $dirs = $exact
} elseif ($multi.Count -gt 0) {
    $dirs = $multi
    $useSlugFilter = $true
}

$files = @()
foreach ($d in $dirs) {
    Get-ChildItem $d -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($useSlugFilter) {
            $base = ([IO.Path]::GetFileNameWithoutExtension($_.Name)).ToLower()
            if (-not (($base -like "*$slug*") -or ($slug -like "*$base*"))) { return }
        }
        $files += $_
    }
}

# 去重：同名文件保留最近修改的一份；输出按文件名排序
$files = @($files | Sort-Object LastWriteTime -Descending | Group-Object Name | ForEach-Object { $_.Group[0] } | Sort-Object Name)

$oldText = ''
if (Test-Path $outFile) {
    $oldText = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8)
}

if ($files.Count -eq 0 -and -not $Force -and $oldText.Trim().Length -gt 0) {
    Write-Host '[记忆同步] 跳过：本机工作记忆为空，且仓库镜像已存在（防稀疏记忆覆盖完整镜像）。'
    Write-Host '          先把 docs\项目记忆.md 内容并入本机记忆再同步；确要清空镜像请加 -Force。'
    exit 0
}

# ---- 1) 取出既有「历史归档」块（下轮原样带出，避免重复累积） ----
$archiveStart = '<!-- PEK-MEMORY-ARCHIVE-START -->'
$archiveEnd = '<!-- PEK-MEMORY-ARCHIVE-END -->'
$archiveLines = New-Object System.Collections.Generic.List[string]
if ($oldText) {
    $inArchive = $false
    foreach ($line in ($oldText -split "`r?`n")) {
        if ($line.Trim() -eq $archiveStart) { $inArchive = $true; continue }
        if ($line.Trim() -eq $archiveEnd) { $inArchive = $false; continue }
        if ($inArchive) { [void]$archiveLines.Add($line) }
    }
}

# ---- 2) 生成记忆小节内容 ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# $projectName · 项目记忆（本机工作记忆同步）")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('> 本文由 `tools/continuity/sync-memory.ps1` 合并同步（来源：本机 Copilot 工作记忆 + 既有镜像）。')
[void]$sb.AppendLine('> 同名小节以本机记忆为准；镜像里原有的其它内容一律收进末尾「历史归档」，不会被删除。')
[void]$sb.AppendLine('> 小节标题固定为 `## <本机记忆文件名>.md`；每个小节下的正文为文件原文。')
[void]$sb.AppendLine('> 同步时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
[void]$sb.AppendLine('')

if ($files.Count -eq 0) {
    [void]$sb.AppendLine('（本机工作记忆为空——尚无 repo 记忆文件。）')
} else {
    foreach ($f in $files) {
        [void]$sb.AppendLine("## $($f.Name)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).Trim())
        [void]$sb.AppendLine('')
    }
}

$newBody = $sb.ToString()

# ---- 3) 差异兜底：镜像里有、新内容里没有的非空行 → 收进历史归档（绝不丢内容） ----
$newSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($line in ($newBody -split "`r?`n")) {
    $t = $line.Trim()
    if ($t) { [void]$newSet.Add($t) }
}
$addedCount = 0
if ($oldText) {
    foreach ($line in ($oldText -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        # 横幅/标记/同步时间这类脚本自产行不算「内容」
        if ($t -eq $archiveStart -or $t -eq $archiveEnd) { continue }
        if ($t -like '*项目记忆（本机工作记忆同步）*') { continue }
        if ($t -like '> 同步时间：*') { continue }
        if ($t -like '> 本文由*' -or $t -like '> 同名小节*' -or $t -like '> 小节标题固定*') { continue }
        if ($t -like '（本机工作记忆为空*') { continue }
        if ($newSet.Contains($t)) { continue }
        if ($archiveLines.Contains($t)) { continue }
        [void]$archiveLines.Add($t)
        $addedCount++
    }
}

$final = $newBody
if ($archiveLines.Count -gt 0) {
    $ab = New-Object System.Text.StringBuilder
    [void]$ab.AppendLine('')
    [void]$ab.AppendLine('## 历史归档（同步自动保留，勿删标记）')
    [void]$ab.AppendLine('')
    [void]$ab.AppendLine($archiveStart)
    foreach ($line in $archiveLines) { [void]$ab.AppendLine($line) }
    [void]$ab.AppendLine($archiveEnd)
    $final = $newBody + $ab.ToString()
}

# 归一化：连续空行压成 1 行（旧版本曾把空行越积越多）
$normalized = [regex]::Replace($final, "(\r?\n){3,}", "`r`n`r`n")

$dir = Split-Path $outFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
[IO.File]::WriteAllText($outFile, $normalized, (New-Object Text.UTF8Encoding($false)))
Write-Host "[记忆同步] 本地记忆 $($files.Count) 个；历史归档 $($archiveLines.Count) 行（本轮新增 $addedCount 行） -> docs\项目记忆.md"
