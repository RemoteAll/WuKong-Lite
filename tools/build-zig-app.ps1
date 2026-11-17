# 构建 WuKong-Lite 的 Zig 裸机应用（D13x）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\build-zig-app.ps1 -App hello_uart
#   powershell -ExecutionPolicy Bypass -File tools\build-zig-app.ps1 -App hello_uart -Gcc <riscv64-unknown-elf-gcc.exe>
#
# 前提：Zig 在 PATH；官方 Xuantie GCC 已解压（默认找 wk\image\xuantie\...\bin\riscv64-unknown-elf-gcc.exe）。

param(
    [Parameter(Mandatory = $true)][string]$App,
    [string]$Gcc = "",
    [string]$OutDir = "",
    [string]$Load = "0x41000000",
    [string]$Entry = "_start"
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$AppDir = Join-Path $Repo "apps\$App"
if (-not (Test-Path (Join-Path $AppDir "main.zig"))) {
    throw "找不到应用：$AppDir\main.zig"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Repo "wk\image\apps"
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

if ([string]::IsNullOrWhiteSpace($Gcc)) {
    $cand = Get-ChildItem -Path (Join-Path $Repo "wk\image\xuantie") -Recurse -Filter "riscv64-unknown-elf-gcc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) { $Gcc = $cand.FullName }
}
if ([string]::IsNullOrWhiteSpace($Gcc) -or -not (Test-Path $Gcc)) {
    throw "找不到 riscv64-unknown-elf-gcc.exe：请用 -Gcc 指定，或先解压官方工具链到 wk\image\xuantie"
}

Write-Host "== 编译 Zig 目标文件 =="
Push-Location $AppDir
try {
    & zig build-obj main.zig -target riscv32-freestanding-none `
        -mcpu=generic_rv32+d+f+c+a+m -O ReleaseSmall
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj 失败" }
} finally {
    Pop-Location
}
$obj = Join-Path $OutDir "$App.o"
Move-Item (Join-Path $AppDir "main.o") $obj -Force

Write-Host "== 链接（Xuantie GCC）=="
$elf = Join-Path $OutDir "$App.elf"
$map = Join-Path $OutDir "$App.map"
$ld = Join-Path $AppDir "link.ld"
& $Gcc -march=rv32imafdc -mabi=ilp32d -mcmodel=medany -nostdlib -nostartfiles `
    "-Wl,-T,$ld" "-Wl,-e,$Entry" "-Wl,-Map=$map" $obj -o $elf
if ($LASTEXITCODE -ne 0) { throw "链接失败" }

# 可选：用 wk 转成 AIC 镜像，并导出裸 bin（供 upgcmd write/exec 直接跑）
$wk = Join-Path $Repo "zig-out\bin\wk.exe"
$aic = Join-Path $OutDir "$App.aic"
$bin = Join-Path $OutDir "$App.bin"
if (Test-Path $wk) {
    & $wk image elf2aic --input $elf -o $aic | Out-Null
    if (Test-Path $aic) { Write-Host "AIC: $aic" }
}
$objcopy = Join-Path (Split-Path $Gcc) "riscv64-unknown-elf-objcopy.exe"
if (Test-Path $objcopy) {
    & $objcopy -O binary $elf $bin
    if ($LASTEXITCODE -ne 0) { throw "objcopy 失败" }
}

Write-Host ""
Write-Host "完成："
Write-Host "  OBJ : $obj"
Write-Host "  ELF : $elf"
Write-Host "  MAP : $map"
if (Test-Path $aic) { Write-Host "  AIC : $aic" }
if (Test-Path $bin) { Write-Host "  BIN : $bin" }
Write-Host ""
Write-Host "直接跑到 RAM（设备已进 USB/UART 升级模式）："
if (Test-Path $bin) {
    Write-Host "  upgcmd.exe write $Load $bin"
    Write-Host "  upgcmd.exe exec $Load"
} else {
    Write-Host "  upgcmd.exe write $Load <objcopy -O binary 产物>"
}
Write-Host "或把 .elf/.itb 按方案打包后烧到 os 分区。"
