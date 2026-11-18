param(
    [string]$OutDir = "",
    [string]$Zig = "zig"
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Repo "wk\image\apps"
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

Push-Location $Repo
try {
    Remove-Item "libapp.a" -Force -ErrorAction SilentlyContinue
    & $Zig build-lib device\app.zig `
        -target riscv32-freestanding-none `
        -mcpu=generic_rv32+d+f+c+a+m `
        -O ReleaseSmall
    if ($LASTEXITCODE -ne 0) { throw "zig build-lib failed" }
    if (-not (Test-Path "libapp.a")) { throw "libapp.a not produced" }
    Move-Item "libapp.a" (Join-Path $OutDir "libwksdk.a") -Force
} finally {
    Pop-Location
}

$lib = Join-Path $OutDir "libwksdk.a"
Write-Host "Zig SDK static library: $lib"
Write-Host "Link it into the official C firmware, and call wk_sdk_demo() from C."
