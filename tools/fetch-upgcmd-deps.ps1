# 准备可直接运行的 ArtInChip upgcmd（免安装 SDK 环境）
#
# 背景：SDK 只提供预编译的 upgcmd.exe，它依赖三个不在 SDK 内的 DLL：
#   - UsbDkHelper.dll      （UsbDk 运行时，USB 后端；UART 模式也要能被加载）
#   - libgcc_s_dw2-1.dll   （32 位 MinGW GCC 运行库）
#   - libwinpthread-1.dll  （32 位 MinGW 线程库，libgcc 的传递依赖）
# 本脚本从官方发布源下载并解包，生成一个可直接执行的 upgcmd 目录。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\fetch-upgcmd-deps.ps1
#   powershell -ExecutionPolicy Bypass -File tools\fetch-upgcmd-deps.ps1 -SdkRoot G:\Code\C\luban-lite
#
# 依赖：Windows + 7-Zip（C:\Program Files\7-Zip\7z.exe 或 PATH 中的 7z）。
# 产物默认在 tools\upgcmd（已被 .gitignore 忽略，不会入库）。

param(
    [string]$SdkRoot = "",
    [string]$OutDir = "",
    [string]$TempDir = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $PSScriptRoot "..\tools\upgcmd"
}
if ([string]::IsNullOrWhiteSpace($TempDir)) {
    $TempDir = Join-Path $env:TEMP "wukong-upgcmd-deps"
}

function Find-7z {
    $candidates = @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "未找到 7-Zip（7z.exe）。请先安装 7-Zip，或把 7z.exe 加入 PATH。"
}

if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    $guess = "G:\Code\C\luban-lite"
    if (Test-Path $guess) { $SdkRoot = $guess }
}
if ([string]::IsNullOrWhiteSpace($SdkRoot) -or -not (Test-Path (Join-Path $SdkRoot "tools\scripts\upgcmd.exe"))) {
    throw "找不到 upgcmd.exe：请用 -SdkRoot 指向 luban-lite 根目录（或设置 LUBAN_LITE_ROOT）"
}

$sevenZip = Find-7z
New-Item -ItemType Directory -Force $OutDir, $TempDir | Out-Null

# 固定版本，便于复现
$usbdkUrl = "https://github.com/daynix/UsbDk/releases/download/v1.00-22/UsbDk_1.0.22_x86.msi"
$libgccUrl = "https://repo.msys2.org/mingw/mingw32/mingw-w64-i686-libgcc-16.2.0-7-any.pkg.tar.zst"
$winpthreadUrl = "https://repo.msys2.org/mingw/mingw32/mingw-w64-i686-libwinpthread-14.0.0.r598.ge3d18511f-1-any.pkg.tar.zst"

function Fetch($url, $file) {
    $dest = Join-Path $TempDir $file
    if (-not (Test-Path $dest)) {
        Write-Host "下载 $url"
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 $url -OutFile $dest
        } catch {
            Remove-Item $dest -ErrorAction SilentlyContinue
            curl.exe -sL --max-time 120 $url -o $dest
            if ($LASTEXITCODE -ne 0) { throw "下载失败：$url" }
        }
    }
    return $dest
}

function Extract-Msys2Dll($url, $file, $dllName) {
    $pkg = Fetch $url $file
    $zstOut = Join-Path $TempDir ("zst_" + [IO.Path]::GetFileNameWithoutExtension($file))
    & $sevenZip x $pkg "-o$zstOut" -y | Out-Null
    $tarPath = Join-Path $zstOut ([IO.Path]::GetFileNameWithoutExtension($file))
    if (-not (Test-Path $tarPath)) { throw "未找到解包后的 tar：$tarPath" }
    $out = Join-Path $TempDir ("out_" + [IO.Path]::GetFileNameWithoutExtension($file))
    & $sevenZip x $tarPath "-o$out" -y | Out-Null
    $dll = Get-ChildItem -Path $out -Recurse -Filter $dllName | Select-Object -First 1
    if (-not $dll) { throw "$file 中未找到 $dllName" }
    Copy-Item $dll.FullName (Join-Path $OutDir $dllName) -Force
}

Write-Host "== 解包 UsbDkHelper.dll =="
$msi = Fetch $usbdkUrl "UsbDk_x86.msi"
$usbdkDir = Join-Path $TempDir "usbdk"
& $sevenZip x $msi "-o$usbdkDir" -y | Out-Null
$helper = Get-ChildItem -Path $usbdkDir -Filter "UsbDkHelper.dll*" | Select-Object -First 1
if (-not $helper) { throw "UsbDk MSI 中未找到 UsbDkHelper.dll" }
Copy-Item $helper.FullName (Join-Path $OutDir "UsbDkHelper.dll") -Force

Write-Host "== 解包 libgcc_s_dw2-1.dll / libwinpthread-1.dll =="
Extract-Msys2Dll $libgccUrl "libgcc.zst" "libgcc_s_dw2-1.dll"
Extract-Msys2Dll $winpthreadUrl "libwinpthread.zst" "libwinpthread-1.dll"

Copy-Item (Join-Path $SdkRoot "tools\scripts\upgcmd.exe") $OutDir -Force

Write-Host ""
Write-Host "完成：$OutDir"
Write-Host "验证："
& (Join-Path $OutDir "upgcmd.exe") -h | Select-Object -First 6
Write-Host ""
Write-Host "烧写："
Write-Host "  UART: upgcmd.exe -i <firmware.img> -u COM5 -p -v"
Write-Host "  USB : upgcmd.exe -i <firmware.img> -d <bus:portnum> -p -v  （需已安装 UsbDk 驱动）"
Write-Host "  列设备: upgcmd.exe -l"
Write-Host "  解析镜像: upgcmd.exe -e <firmware.img>"
