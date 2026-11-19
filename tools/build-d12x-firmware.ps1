# 一键构建指定芯片/板型的 Luban-Lite 固件（AIC.FW），用于 upgcmd / AiBurn 烧写。
#
# 背景（实测）：
#   * `D123BBV` 是 **d12x** 系列芯片（`bsp/artinchip/sys/d12x/ram_param.c` 里 `/* D123BBV 8M */`
#     → 并行 PSRAM 8 MiB，mark_id 0x08）；d13x 的 ram_param 里没有 D123 项。
#   * 参考 SDK 的 d12x 方案存在一处**名称不一致**：链接产物是 `<soc>.elf`（实测为 `d13x.elf`），
#     而 `target/d12x/*/pack/image_cfg.json` 的 `elf2itb` 段写的是 `d12x.elf`，
#     因此 SCons 的 POST_ACTION 跑 mk_image.py 会报 `File d12x.elf is not exist`。
#     `.config` 里是 `CONFIG_AIC_CHIP_D12X=y`（编译宏正确），所以只需把 ELF 复制成配置期望的名字。
#   * 本脚本会先撤销 `tools/attach-zig-sdk.ps1` 的注入（若存在），产出**官方 main.c** 固件，
#     避免 Zig SDK 的 LVGL 代码在新芯片上未经验证。要 Zig 版请显式加 `-WithZig`。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\build-d12x-firmware.ps1
#   powershell -ExecutionPolicy Bypass -File tools\build-d12x-firmware.ps1 -Board demo68-nand
#   powershell -ExecutionPolicy Bypass -File tools\build-d12x-firmware.ps1 -Chip d12x -Board hmi-nor -WithZig
param(
    [string]$Chip = "d12x",
    [string]$Board = "demo68-nor",
    [string]$Kernel = "rt-thread",
    [string]$App = "helloworld",
    [string]$BuildRoot = "",
    [switch]$WithZig,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..") -ErrorAction SilentlyContinue
if (-not $Repo) { $Repo = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($BuildRoot)) { $BuildRoot = Join-Path $Repo "build\luban-lite" }
if (-not (Test-Path $BuildRoot)) { throw "构建工作区不存在: $BuildRoot（见 docs/LVGL_FIRMWARE.md）" }

$py = "C:/Users/qcjxb/AppData/Local/Programs/Python/Python312/python.exe"
if (-not (Test-Path $py)) { $py = "python" }

$bootDef = "${Chip}_${Board}_baremetal_bootloader_defconfig"
$appDef = "${Chip}_${Board}_${Kernel}_${App}_defconfig"
$outName = "${Chip}_${Board}_${Kernel}_${App}"
$imgDir = Join-Path $BuildRoot "output\$outName\images"
$logDir = Join-Path $Repo "artifacts"
New-Item -ItemType Directory -Force $logDir | Out-Null

function Invoke-Tool {
    param([string]$Label, [string[]]$ArgList)
    # PS 5.1：外部命令的 stderr 在 $ErrorActionPreference='Stop' 下会被当终止错误，这里临时放宽
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $py @ArgList 2>&1 | Tee-Object -FilePath (Join-Path $logDir "build-$Chip-$Board.log") -Append | Out-Null
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) { throw "$Label 失败（退出码 $code），日志: artifacts\build-$Chip-$Board.log" }
    Write-Host "  [ok] $Label"
}

# ---------------------------------------------------------------- 环境变量
$env:RTT_EXEC_PATH = Join-Path $BuildRoot "toolchain\bin"
$toolPaths = @(
    (Join-Path $Repo "build\toolbin"),
    "D:\Program Files\Git\usr\bin",
    "G:\Code\C\luban-lite\tools\env\tools\bin"
) | Where-Object { Test-Path $_ }
if ($toolPaths.Count -gt 0) { $env:PATH = ($toolPaths -join ';') + ';' + $env:PATH }
$env:PYTHONPATH = Join-Path $BuildRoot "tools\scripts"
$env:PYTHONIOENCODING = "utf-8"
if (-not $WithZig) { Remove-Item Env:WK_REPO -ErrorAction SilentlyContinue }

Push-Location $BuildRoot
try {
    # ------------------------------------------------------------ Zig 注入处理
    $mainC = Join-Path $BuildRoot "application\rt-thread\helloworld\main.c"
    $zigDir = Join-Path $BuildRoot "application\rt-thread\helloworld\zig_sdk"
    if ($WithZig) {
        Write-Host "[1/5] 注入 Zig SDK ..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo "tools\attach-zig-sdk.ps1") -BuildRoot $BuildRoot | Out-Null
        $env:WK_REPO = $Repo
    } else {
        Write-Host "[1/5] 撤销 Zig SDK 注入（产出官方固件）..."
        if (Test-Path $zigDir) { Remove-Item -Recurse -Force $zigDir }
        if (Test-Path $mainC) {
            $raw = [System.IO.File]::ReadAllText($mainC)
            $raw = $raw.Replace("extern void wk_sdk_demo(void);`r`n`r`n", "")
            $raw = $raw.Replace("extern void wk_sdk_demo(void);`n`n", "")
            $raw = $raw.Replace("    wk_sdk_demo();`r`n", "")
            $raw = $raw.Replace("    wk_sdk_demo();`n", "")
            [System.IO.File]::WriteAllText($mainC, $raw, (New-Object System.Text.UTF8Encoding($true)))
        }
    }

    if (-not $SkipBuild) {
        # -------------------------------------------------------- bootloader
        Write-Host "[2/5] bootloader: $bootDef"
        Invoke-Tool "apply-def $bootDef" @("-m", "SCons", "--apply-def=$bootDef", "-Q")
        Invoke-Tool "build bootloader" @("-m", "SCons", "-j8", "-Q")

        # -------------------------------------------------------- application
        Write-Host "[3/5] application: $appDef"
        Invoke-Tool "apply-def $appDef" @("-m", "SCons", "--apply-def=$appDef", "-Q")
        Invoke-Tool "build application" @("-m", "SCons", "-j8", "-Q")
    } else {
        Write-Host "[2/5][3/5] 跳过编译（-SkipBuild）"
    }

    # ------------------------------------------------------------ ELF 名对齐
    Write-Host "[4/5] 对齐 ELF 名（SDK 的 d12x 方案产物名与 image_cfg 期望不一致）..."
    if (-not (Test-Path $imgDir)) { throw "找不到产物目录: $imgDir" }
    $want = Join-Path $imgDir "$Chip.elf"
    if (-not (Test-Path $want)) {
        $other = Get-ChildItem $imgDir -Filter "*.elf" | Where-Object { $_.BaseName -ne $Chip } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $other) { throw "产物目录里没有 ELF: $imgDir" }
        Copy-Item $other.FullName $want -Force
        Write-Host "  复制 $($other.Name) -> $Chip.elf"
    } else {
        Write-Host "  已存在 $Chip.elf"
    }

    # ------------------------------------------------------------ 打包 AIC.FW
    Write-Host "[5/5] 打包 AIC.FW ..."
    Invoke-Tool "mk_image" @("tools\scripts\mk_image.py", "-v",
        "-c", (Join-Path $imgDir "image_cfg.json"), "-d", $imgDir)

    $img = Get-ChildItem $imgDir -Filter "$($Chip)_$($Board)_*.img" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $img) { throw "未生成 .img（检查 image_cfg.json 的 platform/product）" }

    $dstDir = Join-Path $Repo "artifacts\firmware-$Chip"
    New-Item -ItemType Directory -Force $dstDir | Out-Null
    Copy-Item $img.FullName $dstDir -Force
    $hash = (Get-FileHash (Join-Path $dstDir $img.Name) -Algorithm SHA256).Hash
    Write-Host ""
    Write-Host "产物: artifacts\firmware-$Chip\$($img.Name)"
    Write-Host "大小: $($img.Length) B"
    Write-Host "SHA256: $hash"
    Write-Host ""
    Write-Host "烧写（UART，需先跑 tools\fetch-upgcmd-deps.ps1 补齐 DLL）:"
    Write-Host "  wk\image\tools\upgcmd\upgcmd.exe -i `"$($img.FullName)`" -u COM5 -p -v"
} finally {
    Pop-Location
}
