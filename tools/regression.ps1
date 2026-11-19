# WuKong-Lite 一键回归（Windows PowerShell 5.1）
#
# 覆盖：构建 → 单测 → 全部 wk 子命令冒烟（每个子命令都至少跑一次真实输入）
# 约定：
#   * 退出码 0 = 全绿；1 = 有 FAIL，或通过数低于阈值（阈值只能抬高）
#   * 夹具缺失一律打 SKIP + 原因，**不计入 PASS**，禁止静默跳过
#   * 报告落 artifacts/regression/report-<时间戳>.txt
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\regression.ps1
#   powershell ... -File tools\regression.ps1 -SkipBuild      # 跳过构建（省时间）
#   powershell ... -File tools\regression.ps1 -MinTests 106 -MinCases 34

param(
    [switch]$SkipBuild,
    [int]$MinTests = 127,
    [int]$MinCases = 34
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifacts = Join-Path $repo 'artifacts\regression'
$work = Join-Path $artifacts "work-$ts"
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
New-Item -ItemType Directory -Force -Path $work | Out-Null
$report = Join-Path $artifacts "report-$ts.txt"

$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:lines = New-Object System.Collections.Generic.List[string]
$script:failures = New-Object System.Collections.Generic.List[string]

function Log([string]$text) {
    $script:lines.Add($text)
    Write-Host $text
}

function Case-Pass([string]$name) {
    $script:pass++
    Log ("  PASS  " + $name)
}
function Case-Fail([string]$name, [string]$detail) {
    $script:fail++
    $script:failures.Add($name)
    Log ("  FAIL  " + $name + "  -- " + $detail)
}
function Case-Skip([string]$name, [string]$reason) {
    $script:skip++
    Log ("  SKIP  " + $name + "  -- " + $reason)
}

# 跑一条命令：期望退出码集合 + 可选 ASCII 标记（避免中文在管道里编码失真）
function Run-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Args,
        [int[]]$ExpectedExit = @(0),
        [string]$Match = '',
        [string]$WorkDir = ''
    )
    $exe = Join-Path $repo 'zig-out\bin\wk.exe'
    $old = Get-Location
    if ($WorkDir -ne '') { Push-Location $WorkDir }
    try {
        $text = (& $exe @Args 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        if ($WorkDir -ne '') { Pop-Location } else { Set-Location $old }
    }
    $ok = $ExpectedExit -contains $code
    if ($ok -and $Match -ne '' -and -not $text.Contains($Match)) { $ok = $false }
    if ($ok) {
        Case-Pass $Name
    } else {
        $head = ($text -replace '\s+', ' ')
        if ($head.Length -gt 160) { $head = $head.Substring(0, 160) }
        Case-Fail $Name ("exit=" + $code + " out=" + $head)
    }
}

Log ("[回归] 仓库: " + $repo)
Log ("[回归] 工作目录: " + $work)
Log ''

# ---------------------------------------------------------------------------
# 1) 构建
# ---------------------------------------------------------------------------
if ($SkipBuild) {
    Case-Skip 'zig build' '指定 -SkipBuild'
} else {
    Push-Location $repo
    $buildOut = (& zig build 2>&1 | Out-String)
    $buildCode = $LASTEXITCODE
    Pop-Location
    if ($buildCode -eq 0) { Case-Pass 'zig build' } else { Case-Fail 'zig build' $buildOut }
}

# ---------------------------------------------------------------------------
# 2) 单测（同时取出总数，低于阈值算失败）
# ---------------------------------------------------------------------------
Push-Location $repo
$testOut = (& zig build test 2>&1 | Out-String)
$testCode = $LASTEXITCODE
Pop-Location
if ($testCode -ne 0) {
    Case-Fail 'zig build test' $testOut
} else {
    $exeTest = Get-ChildItem (Join-Path $repo '.zig-cache\o') -Recurse -Filter 'test.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $total = 0
    if ($exeTest) {
        $runOut = (& $exeTest.FullName 2>&1 | Out-String)
        if ($runOut -match 'All (\d+) tests passed') { $total = [int]$Matches[1] }
    }
    if ($total -ge $MinTests) {
        Case-Pass ("zig build test (" + $total + " 项, 阈值 " + $MinTests + ")")
    } else {
        Case-Fail 'zig build test' ("通过数 " + $total + " < 阈值 " + $MinTests)
    }
}

# ---------------------------------------------------------------------------
# 3) 夹具准备
# ---------------------------------------------------------------------------
$ref = 'G:\Code\C\luban-lite'
$elf = Join-Path $repo 'wk\image\apps\hello_uart.elf'
$bin = Join-Path $repo 'wk\image\apps\hello_uart.bin'
$map = Join-Path $repo 'wk\image\apps\hello_uart.map'

# 自建 FS 夹具：fs clean 是破坏性用例，绝不能指向仓库里的真实目录
$fsSrc = Join-Path $work 'fs-src'
New-Item -ItemType Directory -Force -Path (Join-Path $fsSrc 'sub') | Out-Null
@('hello wukong-lite', 'regression fixture') -join "`n" | Set-Content -Path (Join-Path $fsSrc 'root.txt') -Encoding ASCII
[IO.File]::WriteAllBytes((Join-Path $fsSrc 'sub\a.bin'), [byte[]](0..63))
$refImgCfg = Join-Path $ref 'target\d13x\demo88-nor\pack\image_cfg.json'
$refPrivCfg = Join-Path $repo 'artifacts\sec\pbp_security.json'
$refKeyDer = Join-Path $ref 'target\d13x\demo88-nor-secure\pack\keys\rsa_private_key.der'
$refPubDer = Join-Path $ref 'target\d13x\demo88-nor-secure\pack\keys\rsa_public_key.der'
$refRtDef = Join-Path $ref 'target\configs\d13x_demo88-nor_rt-thread_helloworld_defconfig'

$panicLog = Join-Path $work 'panic.log'
@(
    'CPU Exception: NO.5',
    'mepc: 0x40041d84',
    'mcause: 0x00000005',
    'x1 : 0x40004123 x2 : 0x4000ff00',
    'stack_addr:0x4000e000',
    'stack_addr_end:0x40010000',
    'stack:',
    ' 0x40004123 0x400045f8'
) -join "`n" | Set-Content -Path $panicLog -Encoding ASCII

$cpioList = Join-Path $work 'cpio_list.txt'
@('root.txt', 'sub/a.bin') -join "`n" | Set-Content -Path $cpioList -Encoding ASCII

$envTxt = Join-Path $work 'env.txt'
@('bootdelay=0', 'bootcmd=run distro_bootcmd', 'baudrate=115200') -join "`n" | Set-Content -Path $envTxt -Encoding ASCII

$aesKey = Join-Path $work 'aes.key'
[IO.File]::WriteAllBytes($aesKey, [byte[]](0..15))

# ---------------------------------------------------------------------------
# 4) 顶层命令
# ---------------------------------------------------------------------------
Log ''
Log '[4] 顶层命令'
Run-Case -Name 'wk version'             -Args @('version') -Match 'WuKong-Lite'
Run-Case -Name 'wk help'                -Args @('-h') -Match 'image part'
Run-Case -Name 'wk（无参打印用法）'      -Args @() -ExpectedExit @(0) -Match 'wk <command>'
Run-Case -Name 'wk defconfig --list'    -Args @('defconfig', '--list') -WorkDir $repo
Run-Case -Name 'wk config list'         -Args @('config', 'list') -WorkDir $repo -Match 'CONFIG_'
Run-Case -Name 'wk build'               -Args @('build') -WorkDir $repo
Run-Case -Name 'wk shell -c help'       -Args @('shell', '-c', 'help')
Run-Case -Name 'wk run hello'           -Args @('run', 'hello')
Run-Case -Name 'wk demo'                -Args @('demo')

if (Test-Path $ref) {
    Run-Case -Name 'wk sdk-update（只读扫描）' -Args @('sdk-update', '--root', $ref) -Match 'pinmux.c'
} else {
    Case-Skip 'wk sdk-update' '参考 SDK 不存在'
}

if (Test-Path $refRtDef) {
    Run-Case -Name 'wk rtt2freertos' -Args @('rtt2freertos', $refRtDef, '-o', (Join-Path $work 'ft_defconfig')) -Match 'written to'
} else {
    Case-Skip 'wk rtt2freertos' '缺少 rt-thread defconfig 夹具'
}

Run-Case -Name 'wk panic（无 ELF）' -Args @('panic', '-l', $panicLog) -Match 'CPU: RISC-V'

# ---------------------------------------------------------------------------
# 5) image 子命令
# ---------------------------------------------------------------------------
Log ''
Log '[5] image 子命令'
$imgOut = Join-Path $work 'img'
New-Item -ItemType Directory -Force -Path $imgOut | Out-Null

if (Test-Path $refImgCfg) {
    Run-Case -Name 'image part' -Args @('image', 'part', '--config', $refImgCfg,
        '--out', (Join-Path $imgOut 'partition_table.h'), '--json', (Join-Path $imgOut 'parts.json'))
    Run-Case -Name 'image env' -Args @('image', 'env', '--config', $refImgCfg,
        '--input', $envTxt, '--size', '4096', '-o', (Join-Path $imgOut 'env.bin'))
    Run-Case -Name 'image partlist' -Args @('image', 'partlist', '--config', $refImgCfg,
        '--output', (Join-Path $imgOut 'partition_file_list.h'))
    Run-Case -Name 'image linkaddr' -Args @('image', 'linkaddr', '--config', (Join-Path $repo 'wk\config\.config'),
        '--input', $refImgCfg, '--output', (Join-Path $imgOut 'linkaddr.json'))
} else {
    Case-Skip 'image part/env/partlist/linkaddr' '缺少 image_cfg.json 夹具'
}

Run-Case -Name 'image aic' -Args @('image', 'aic', '--input', $bin, '-o', (Join-Path $imgOut 'hello.aic'))
Run-Case -Name 'image dump' -Args @('image', 'dump', (Join-Path $imgOut 'hello.aic')) -Match 'AIC'
Run-Case -Name 'image elf2aic' -Args @('image', 'elf2aic', '--input', $elf, '-o', (Join-Path $imgOut 'elf2aic.aic'))
Run-Case -Name 'image elf2its' -Args @('image', 'elf2its', '--input', $elf, '-o', (Join-Path $imgOut 'os.its'))
Run-Case -Name 'image itb' -Args @('image', 'itb', '--kernel', $bin, '-o', (Join-Path $imgOut 'os.itb'))
Run-Case -Name 'image fitinfo --dump' -Args @('image', 'fitinfo', '--input', (Join-Path $imgOut 'os.itb'), '--dump')
Run-Case -Name 'image pagetable' -Args @('image', 'pagetable', '--input', $bin, '-o', (Join-Path $imgOut 'page.bin'))
Run-Case -Name 'image crypt' -Args @('image', 'crypt', '--input', $bin,
    '--key', '000102030405060708090a0b0c0d0e0f', '--iv', '0f0e0d0c0b0a09080706050403020100',
    '--pad', 'zero', '-o', (Join-Path $imgOut 'enc.bin'))
Run-Case -Name 'image fat' -Args @('image', 'fat', '--input-dir', $fsSrc,
    '--output', (Join-Path $imgOut 'fs.img'), '--size', '65536')
Run-Case -Name 'image simg（打包）' -Args @('image', 'simg', '--input', (Join-Path $imgOut 'fs.img'),
    '--output', (Join-Path $imgOut 'fs.sparse'))
Run-Case -Name 'image simg --dump' -Args @('image', 'simg', '--input', (Join-Path $imgOut 'fs.sparse'), '--dump') -Match 'Total'
Run-Case -Name 'image cpio' -Args @('image', 'cpio', '--list', $cpioList, '--input-dir', $fsSrc,
    '-o', (Join-Path $imgOut 'fs.cpio'))
Run-Case -Name 'image merge' -Args @('image', 'merge', '--output', (Join-Path $imgOut 'merged.bin'),
    '--input', (Join-Path $repo 'wk\image\merge_a.bin'),
    '--input', (Join-Path $repo 'wk\image\merge_b.bin'),
    '--input', (Join-Path $repo 'wk\image\merge_c.bin'))
Run-Case -Name 'image linksize' -Args @('image', 'linksize', '--map', $map, '--out-dir', $imgOut)
Run-Case -Name 'image partcheck' -Args @('image', 'partcheck',
    '-c', (Join-Path $repo 'artifacts\partcheck\image_cfg.json'), '-d', (Join-Path $repo 'artifacts\partcheck'))
Run-Case -Name 'image littlefs' -Args @('image', 'littlefs', '-i', $fsSrc,
    '-o', (Join-Path $imgOut 'fs.lfs'), '-b', '4096')

if (Test-Path $refPrivCfg) {
    Run-Case -Name 'image privres' -Args @('image', 'privres', '-c', $refPrivCfg, '-o', (Join-Path $imgOut 'priv.bin'))
    Run-Case -Name 'image pbp' -Args @('image', 'pbp', '-i', (Join-Path $imgOut 'priv.bin'), '-o', (Join-Path $imgOut 'pbp.bin'))
} else {
    Case-Skip 'image privres/pbp' '缺少 pbp_security.json 夹具'
}

if (Test-Path $refPrivCfg) {
    # privres 的完整配置（pbp_cfg.json 在参考仓库）
    $pbpCfg = Join-Path $ref 'target\d13x\demo88-nor-secure\pack\pbp_cfg.json'
    if (Test-Path $pbpCfg) {
        Run-Case -Name 'image privres（完整 pbp_cfg）' -Args @('image', 'privres', '-c', $pbpCfg,
            '-o', (Join-Path $imgOut 'pbp_cfg.bin'))
    } else {
        Case-Skip 'image privres（完整 pbp_cfg）' '缺少 pbp_cfg.json'
    }
}

if (Test-Path $refKeyDer) {
    Run-Case -Name 'image rsakey（AES 加密私钥）' -Args @('image', 'rsakey', '-r', $refKeyDer,
        '-a', $aesKey, '-o', $imgOut)
    Run-Case -Name 'image rsakey（公钥导出）' -Args @('image', 'rsakey', '-r', $refPubDer, '-o', $imgOut)
} else {
    Case-Skip 'image rsakey' '缺少 RSA 密钥夹具'
}

# rsasign / rsaverify：用参考 SDK 里的 openssl 把 DER 转成 PEM 作夹具
$openssl = Join-Path $ref 'tools\scripts\openssl.exe'
if ((Test-Path $refKeyDer) -and (Test-Path $openssl)) {
    $pem = Join-Path $work 'priv.pem'
    $pubPem = Join-Path $work 'pub.pem'
    & $openssl rsa -inform DER -in $refKeyDer -out $pem 2>&1 | Out-Null
    & $openssl rsa -in $pem -pubout -out $pubPem 2>&1 | Out-Null
    if ((Test-Path $pem) -and (Test-Path $pubPem)) {
        $sigFile = Join-Path $work 'sig.bin'
        Run-Case -Name 'image rsasign' -Args @('image', 'rsasign', '--input', $bin, '--key', $pem, '-o', $sigFile) -Match 'PKCS#1'
        Run-Case -Name 'image rsaverify' -Args @('image', 'rsaverify', '--input', $bin, '--key', $pubPem, '--sig', $sigFile)
    } else {
        Case-Skip 'image rsasign / rsaverify' 'openssl 生成 PEM 失败'
    }
} else {
    Case-Skip 'image rsasign / rsaverify' '缺少 DER 私钥或 openssl 夹具'
}

# flashpack：用合成 payload（bootloader.aic + os.itb + env.txt + rodata/）出 AIC.FW
$refOtaCfg = Join-Path $ref 'target\d13x\demo88-nor\pack\ota-subimgs.cfg'
$osItb = Join-Path $imgOut 'os.itb'
if ((Test-Path $refImgCfg) -and (Test-Path $osItb)) {
    $pl = Join-Path $work 'payload'
    New-Item -ItemType Directory -Force -Path (Join-Path $pl 'rodata') | Out-Null
    Copy-Item $osItb (Join-Path $pl 'd13x_os.itb') -Force
    Copy-Item (Join-Path $imgOut 'hello.aic') (Join-Path $pl 'bootloader.aic') -Force
    Copy-Item (Join-Path $imgOut 'hello.aic') (Join-Path $pl 'usbupg-psram-init.aic') -Force
    Copy-Item (Join-Path $fsSrc 'root.txt') (Join-Path $pl 'rodata\root.txt') -Force
    Copy-Item $envTxt (Join-Path $pl 'env.txt') -Force
    $fwOut = Join-Path $work 'fw'
    New-Item -ItemType Directory -Force -Path $fwOut | Out-Null
    Run-Case -Name 'image flashpack' -Args @('image', 'flashpack', '--config', $refImgCfg, '--payload-dir', $pl, '--out-dir', $fwOut) -Match 'demo88-nor.img'

    if (Test-Path $refOtaCfg) {
        $otaIn = Join-Path $work 'ota-in'
        New-Item -ItemType Directory -Force -Path $otaIn | Out-Null
        Copy-Item $osItb (Join-Path $otaIn 'd13x_os.itb') -Force
        Copy-Item (Join-Path $imgOut 'fs.img') (Join-Path $otaIn 'rodata.fatfs') -Force
        Run-Case -Name 'image ota' -Args @('image', 'ota', '--ota-cfg', $refOtaCfg, '--image-cfg', $refImgCfg, '--input-dir', $otaIn, '--out-dir', (Join-Path $work 'ota-out')) -Match 'ota.cpio'
    } else {
        Case-Skip 'image ota' '缺少 ota-subimgs.cfg 夹具'
    }
} else {
    Case-Skip 'image flashpack / ota' '缺少 image_cfg 或 os.itb 夹具'
}

# ---------------------------------------------------------------------------
# 6) fs / upg
# ---------------------------------------------------------------------------
Log ''
Log '[6] fs / upg'
Run-Case -Name 'fs install' -Args @('fs', 'install', '-s', $fsSrc, '-d', (Join-Path $work 'inst'))
Run-Case -Name 'fs clean' -Args @('fs', 'clean', '-c', ((Join-Path $fsSrc 'root.txt') + ',' + (Join-Path $fsSrc 'sub\a.bin')))
if (-not (Test-Path (Join-Path $fsSrc 'root.txt'))) {
    Case-Pass 'fs clean 已删除目标文件'
} else {
    Case-Fail 'fs clean 已删除目标文件' 'root.txt 仍存在'
}

$frameFile = Join-Path $work 'frame.bin'
Run-Case -Name 'upg frame' -Args @('upg', 'frame', '--cmd', '0x31', '--payload', '{"v":"1"}', '-o', $frameFile) -Match 'aa550131'
Run-Case -Name 'upg decode' -Args @('upg', 'decode', '-i', $frameFile) -Match '0x31'
Run-Case -Name 'upg proto-version' -Args @('upg', 'proto-version', '-o', (Join-Path $work 'pv.bin')) -Match 'aa550131'
Run-Case -Name 'upg burn' -Args @('upg', 'burn', '--image', 'x.img') -Match 'aa550110'
Run-Case -Name 'upg config-device' -Args @('upg', 'config-device', '--port', 'COM4', '--baudrate', '115200') -Match 'aa550101'
Run-Case -Name 'upg send-cmd' -Args @('upg', 'send-cmd', '--command', 'reset') -Match 'aa550121'
Run-Case -Name 'upg get-log' -Args @('upg', 'get-log', '--timeout', '5') -Match 'aa550120'
Run-Case -Name 'upg upload-start' -Args @('upg', 'upload-start', '--file', $bin) -Match 'aa550140'
Run-Case -Name 'upg --send（无服务端应失败）' -Args @('upg', 'proto-version', '--send', '--server-port', '1',
    '--timeout', '300') -ExpectedExit @(1, 2, 3)

# ---------------------------------------------------------------------------
# 7) upg 会话对拍（mock 服务端）
# ---------------------------------------------------------------------------
Log ''
Log '[7] upg 会话对拍'
$py = 'C:\Users\qcjxb\AppData\Local\Programs\Python\Python312\python.exe'
if (-not (Test-Path $py)) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
if ($py -and (Test-Path $py)) {
    $env:PYTHONIOENCODING = 'utf-8'
    foreach ($script in @('check_upg_send.py', 'check_upg_timeout.py', 'check_aicimage.py', 'check_preproc.py', 'check_envparts.py', 'check_fitsign.py', 'check_fitcipher.py', 'check_fitconfsign.py', 'check_fitsign_algos.py', 'check_uffs.py', 'check_fwenc.py', 'check_fat_nftl.py', 'check_fwextract.py')) {
        $path = Join-Path $repo ('tools\checks\' + $script)
        if (-not (Test-Path $path)) { Case-Skip $script '脚本缺失'; continue }
        $text = (& $py $path 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Case-Pass $script
        } else {
            Case-Fail $script ((($text -replace '\s+', ' ').Trim()))
        }
    }
} else {
    Case-Skip 'upg 会话对拍' '未找到 python，跳过（不计入 PASS）'
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Log ''
Log ('[汇总] PASS=' + $script:pass + '  FAIL=' + $script:fail + '  SKIP=' + $script:skip)
if ($script:fail -gt 0) {
    Log ('[失败项] ' + ($script:failures -join '; '))
}
if ($script:pass -lt $MinCases) {
    Log ('[阈值] 通过数 ' + $script:pass + ' < ' + $MinCases + '（阈值只能抬高，不能降低）')
    $script:fail++
}

$script:lines | Set-Content -Path $report -Encoding UTF8
Log ('[报告] ' + $report)

if ($script:fail -gt 0) { exit 1 } else { exit 0 }
