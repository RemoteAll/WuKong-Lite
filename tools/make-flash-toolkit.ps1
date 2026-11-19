# Build a ready-to-run UART flashing toolkit:
#   upgcmd.exe + its DLLs + firmware image(s) + flash.bat + README.txt  ->  zip
#
# Why: AiBurn only prints "execution failed"; upgcmd prints per-component
# progress and error codes, which is what we need to debug a failed flash.
#
# Usage:
#   powershell -File tools\make-flash-toolkit.ps1
#   powershell -File tools\make-flash-toolkit.ps1 -Image artifacts\firmware-d12x\x.img -Com COM3
param(
    [string[]]$Image = @(),
    [string]$Out = "",
    [string]$Com = "COM25",
    [int]$Baud = 3000000
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$UpgDir = Join-Path $Repo "wk\image\tools\upgcmd"
$Stage = Join-Path $Repo "artifacts\upgcmd-toolkit"
if (-not $Out) { $Out = Join-Path $Repo "artifacts\upgcmd-toolkit.zip" }

if (-not (Test-Path $UpgDir)) { throw "upgcmd not found: $UpgDir" }
if ($Image.Count -eq 0) {
    $Image = @(
        (Join-Path $Repo "artifacts\firmware-d12x\d12x_demo68-nor_LATEST-runnable.img"),
        (Join-Path $Repo "artifacts\firmware-d12x\d12x_demo68-nor_MIX-refapp.img")
    )
}
foreach ($f in $Image) { if (-not (Test-Path $f)) { throw "image not found: $f" } }

# ---------------------------------------------------------------- stage
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $Stage "upgcmd") | Out-Null
Copy-Item (Join-Path $UpgDir "*") (Join-Path $Stage "upgcmd") -Force

$mainImage = (Get-Item $Image[0]).Name
foreach ($f in $Image) { Copy-Item $f $Stage -Force }

# ---------------------------------------------------------------- flash.bat
$bat = @'
@echo off
chcp 65001 >nul
setlocal
set COM=%~1
if "%COM%"=="" set COM=__COM__
set BAUD=%~2
if "%BAUD%"=="" set BAUD=__BAUD__

echo ==========================================================
echo   ArtInChip d12x firmware flash  (upgcmd)
echo   Port : %COM%
echo   Baud : %BAUD%
echo ==========================================================
echo.
echo STEP 1  Put the board into UPGRADE mode:
echo         - short PA0 to GND  (or press the UBOOT key), then
echo         - power on / press reset
echo STEP 2  Press any key here to start flashing.
echo.
echo   tip: run  flash.bat COM3  to use another port
echo.
pause

upgcmd\upgcmd.exe -u %COM% -b %BAUD% -p -v image "__IMAGE__" > flash-log.txt 2>&1
set RC=%ERRORLEVEL%

echo.
echo ---------------- exit code: %RC% ----------------
type flash-log.txt
echo.
echo Full log saved to: flash-log.txt
pause
'@
$bat = $bat.Replace('__COM__', $Com).Replace('__BAUD__', "$Baud").Replace('__IMAGE__', $mainImage)
[System.IO.File]::WriteAllText((Join-Path $Stage "flash.bat"), $bat, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- README
$readme = @"
d12x firmware flashing toolkit (command line)
==============================================

1. Enter upgrade mode on the board
   - short PA0 to GND (or press the UBOOT key), then power on / reset

2. Double-click flash.bat
   default port: $Com , baud: $Baud
   other port:  flash.bat COM3
   other baud:  flash.bat COM25 921600

3. exit code 0 = success. Non-zero = failure, full log printed and saved
   to flash-log.txt -- send that file back for analysis.

Check an image without flashing:
   upgcmd\upgcmd.exe -i $mainImage

Contents:
   upgcmd\upgcmd.exe + 3 DLLs   vendor flashing tool V1.4.2
   flash.bat                    one-click flash (writes flash-log.txt)
   *.img                        firmware images

Note: images are produced by our own Zig toolchain (wk) and are
byte-identical to the vendor mk_image.py output at the same timestamp.
"@
[System.IO.File]::WriteAllText((Join-Path $Stage "README.txt"), $readme, (New-Object System.Text.UTF8Encoding($true)))

# ---------------------------------------------------------------- zip
if (Test-Path $Out) { Remove-Item $Out -Force }
Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $Out -CompressionLevel Optimal

Write-Host ""
Write-Host "toolkit : $Out"
Write-Host ("size    : {0:N2} MB" -f ((Get-Item $Out).Length / 1MB))
Write-Host "images  : $($Image.Count) ($mainImage as main)"
