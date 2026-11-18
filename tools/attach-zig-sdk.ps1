param(
    [string]$BuildRoot = "",
    [string]$SdkRoot = "G:\Code\C\luban-lite"
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $BuildRoot = Join-Path $Repo "build\luban-lite"
}
if (-not (Test-Path $BuildRoot)) {
    throw "Build workspace not found: $BuildRoot (see docs/LVGL_FIRMWARE.md)"
}

$app = Join-Path $BuildRoot "application"
if ((Get-Item $app -ErrorAction SilentlyContinue).LinkType -eq "Junction") {
    cmd /c rmdir "$app"
    Copy-Item -Recurse (Join-Path $SdkRoot "application") $app
}
if (-not (Test-Path (Join-Path $app "rt-thread\helloworld\main.c"))) {
    throw "helloworld app not found under $app"
}

$zigDir = Join-Path $app "rt-thread\helloworld\zig_sdk"
New-Item -ItemType Directory -Force $zigDir | Out-Null
Copy-Item (Join-Path $Repo "device\integration\SConscript") (Join-Path $zigDir "SConscript") -Force

$main = Join-Path $app "rt-thread\helloworld\main.c"
$text = Get-Content $main -Raw -Encoding UTF8
if ($text -notmatch "wk_sdk_demo") {
    $text = $text -replace "(?m)^int main\(void\)\r?\n\{", "extern void wk_sdk_demo(void);`r`n`r`nint main(void)`r`n{`r`n    wk_sdk_demo();"
    Set-Content $main -Value $text -Encoding UTF8
    Write-Host "patched: $main"
} else {
    Write-Host "already patched: $main"
}

Write-Host ""
Write-Host "Now build with:"
Write-Host "  `$env:WK_REPO='$Repo'"
Write-Host "  cd $BuildRoot"
Write-Host "  python -m SCons -j8"
