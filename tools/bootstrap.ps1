# Bootstrap the build environment on a fresh machine.
#
# What it does (idempotent - safe to re-run):
#   1. checks git / python / zig and the python package kconfiglib
#   2. checks the reference SDK (luban-lite) and its commit against docs/official/UPSTREAM.json
#   3. copies the SDK into build\luban-lite (excluding .git / output / toolchain / doc)
#   4. extracts the RISC-V toolchain from <SDK>\tools\toolchain\*.tar.gz  (the SDK does NOT ship
#      an extracted toolchain - this is the step people usually forget)
#   5. builds wk and runs the unit tests
#
# Typical fresh-machine flow:
#   git clone https://github.com/RemoteAll/WuKong-Lite.git
#   cd WuKong-Lite
#   powershell -File tools\bootstrap.ps1
#
# If the SDK is not present yet, clone it first (about 2.2 GB):
#   git clone https://github.com/artinchip/luban-lite.git G:\Code\C\luban-lite
#
# Usage:
#   powershell -File tools\bootstrap.ps1 -Check          # only report, change nothing
#   powershell -File tools\bootstrap.ps1                 # do the full setup
#   powershell -File tools\bootstrap.ps1 -SdkRoot D:\sdk\luban-lite
#   powershell -File tools\bootstrap.ps1 -TcPackage Xuantie-900-gcc-elf-newlib-mingw-V2.6.1-20220906-trim.tar.gz
param(
    [string]$SdkRoot = "G:\Code\C\luban-lite",
    [string]$SdkUrl = "https://gitee.com/artinchip/luban-lite.git",
    [string]$BuildRoot = "",
    [string]$TcPackage = "",
    [switch]$Check,
    [switch]$SkipCopy,
    [switch]$SkipToolchain,
    [switch]$SkipTest
)

$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $Repo "build\luban-lite" }
$Upstream = Join-Path $Repo "docs\official\UPSTREAM.json"

function Say($msg) { Write-Host $msg }
function Ok($msg) { Write-Host "  [ok]   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [warn] $msg" -ForegroundColor Yellow }
function Bad($msg) { Write-Host "  [miss] $msg" -ForegroundColor Red }

$problems = @()

# ---------------------------------------------------------------- 1. host tools
Say "[1/5] Host tools"

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { Ok "git $(& git --version)" } else { Bad "git not found"; $problems += "install git" }

$py = $null
foreach ($cand in @("C:/Users/$env:USERNAME/AppData/Local/Programs/Python/Python312/python.exe", "python")) {
    if (Test-Path $cand) { $py = $cand; break }
    if ($cand -eq "python") {
        $c = Get-Command python -ErrorAction SilentlyContinue
        if ($c) { $py = $c.Source }
    }
}
if ($py) {
    Ok "python $(& $py --version 2>&1)"
    $kl = (& $py -c "import kconfiglib; print('ok')" 2>&1) -join ""
    if ($kl -match "ok") { Ok "kconfiglib present" }
    else { Warn "kconfiglib missing -> pip install kconfiglib"; $problems += "pip install kconfiglib" }
} else {
    Bad "python not found"; $problems += "install Python 3.12"
}

$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if ($zigCmd) { Ok "zig $(& zig version)" }
else { Bad "zig not found (VS Code Zig extension ships one, or use ziglang.org)"; $problems += "install Zig 0.17.x" }

# ---------------------------------------------------------------- 2. reference SDK
Say "[2/5] Reference SDK: $SdkRoot"
if (Test-Path (Join-Path $SdkRoot "SConstruct")) {
    Ok "SDK present"
    if (Test-Path $Upstream) {
        $meta = Get-Content $Upstream -Raw -Encoding UTF8 | ConvertFrom-Json
        Say "        expected commit: $($meta.commit)"
        if (Test-Path (Join-Path $SdkRoot ".git")) {
            $head = (& git -C $SdkRoot rev-parse HEAD 2>$null)
            if ($head -and ($head.Trim() -ne $meta.commit)) {
                Warn "SDK HEAD is $head (differs from the recorded commit; build may drift)"
            } else {
                Ok "SDK commit matches"
            }
        } else {
            Warn "SDK is not a git checkout, cannot verify commit"
        }
    }
} else {
    Bad "SDK not found at $SdkRoot"
    Say "        will clone from: $SdkUrl"
    if ($Check) {
        $problems += "clone luban-lite SDK from $SdkUrl"
    } else {
        Say "        cloning (shallow, about 2.2 GB) ..."
        New-Item -ItemType Directory -Force (Split-Path $SdkRoot -Parent) | Out-Null
        & git clone --depth 1 --branch master $SdkUrl $SdkRoot
        if ($LASTEXITCODE -ne 0) { throw "git clone failed: $SdkUrl" }
        Ok "cloned"
    }
}

# ---------------------------------------------------------------- 3. build workspace
Say "[3/5] Build workspace: $BuildRoot"
if ($Check) {
    if (Test-Path $BuildRoot) { Ok "exists" } else { Warn "will be created from SDK" }
} elseif ($SkipCopy) {
    Say "        skipped (-SkipCopy)"
} elseif (Test-Path (Join-Path $SdkRoot "SConstruct")) {
    Say "        copying SDK -> $BuildRoot (excluding .git/output/toolchain/doc) ..."
    New-Item -ItemType Directory -Force $BuildRoot | Out-Null
    & robocopy $SdkRoot $BuildRoot /E /XD .git output toolchain doc artifacts-wk /XF .config .config.old .defconfig /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    Ok "copied"
} else {
    Bad "cannot copy: SDK missing"
}

# ---------------------------------------------------------------- 4. toolchain
Say "[4/5] RISC-V toolchain"
$tcDir = Join-Path $BuildRoot "toolchain"
$gcc = Join-Path $tcDir "bin\riscv64-unknown-elf-gcc.exe"
if (Test-Path $gcc) {
    Ok "already extracted: $(& $gcc --version 2>&1 | Select-Object -First 1)"
} elseif ($Check) {
    Warn "not extracted yet ($tcDir)"
} elseif ($SkipToolchain) {
    Say "        skipped (-SkipToolchain)"
} else {
    $tcSrc = Join-Path $SdkRoot "tools\toolchain"
    if (-not $TcPackage) {
        $cand = Get-ChildItem $tcSrc -Filter "Xuantie-900-gcc-elf-newlib-mingw-V3.2.0-*.tar.gz" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $cand) { $cand = Get-ChildItem $tcSrc -Filter "*mingw*.tar.gz" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1 }
        if (-not $cand) { throw "no mingw toolchain package found in $tcSrc" }
        $TcPackage = $cand.FullName
    }
    Say "        extracting $(Split-Path $TcPackage -Leaf) ..."
    $tmp = Join-Path $env:TEMP ("wk-tc-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    & tar -xf $TcPackage -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar failed: $TcPackage" }
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not $inner) { throw "unexpected toolchain archive layout" }
    if (Test-Path $tcDir) { Remove-Item $tcDir -Recurse -Force }
    Move-Item $inner.FullName $tcDir
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $gcc) { Ok "extracted: $(& $gcc --version 2>&1 | Select-Object -First 1)" }
    else { Bad "extraction finished but gcc not found"; $problems += "check toolchain archive" }
}

# ---------------------------------------------------------------- 5. build
Say "[5/5] Build wk"
if ($Check) {
    Say "        skipped (-Check)"
} else {
    & zig build
    if ($LASTEXITCODE -ne 0) { throw "zig build failed" }
    Ok "zig build"
    if (-not $SkipTest) {
        & zig build test
        if ($LASTEXITCODE -ne 0) { throw "zig build test failed" }
        Ok "zig build test"
    }
}

# ---------------------------------------------------------------- summary
Write-Host ""
if ($problems.Count -eq 0) {
    Write-Host "Environment ready." -ForegroundColor Green
    Write-Host "Next: powershell -File tools\build-d12x-firmware.ps1"
} else {
    Write-Host "Still missing:" -ForegroundColor Yellow
    foreach ($p in $problems) { Write-Host "  - $p" }
    exit 1
}
