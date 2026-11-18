# D13x demo88-nor · LVGL V9 固件（2026-11-18）

> 目标：生成一个能点亮 1024×600 LVDS 屏、运行 LVGL V9 `demo_hub` 的可烧录镜像。
> 当前状态：**已构建成功、`upgcmd -e` 可完整解析；尚未上板点亮**（本机未检测到
> USB 升级设备，CP2102N 串口驱动也未安装）。

## 1. 目标硬件

默认按 `d13x demo88-nor` 方案构建，配置来自官方 defconfig：

- `CONFIG_LVGL_V_9=y`
- `CONFIG_AIC_LVGL_DEMO=y`
- `CONFIG_AIC_LVGL_DEMO_HUB_DEMO=y`
- `CONFIG_AIC_DISP_LVDS=y` / `CONFIG_AICFB_RGB565=y`
- `CONFIG_AIC_PANEL_1024X600_RESOLUTION=y`
- 触摸：`CONFIG_AIC_TOUCH_PANEL_GT911=y`（I2C2，RST PA.10，INT PA.11）

如果实际板卡不是 `d13x demo88-nor` 或屏不是 1024×600 LVDS，需要改
`target/configs/d13x_demo88-nor_rt-thread_helloworld_defconfig` 或改用对应板级配置，
否则可能无显示/花屏。

## 2. 构建（不修改只读参考仓库）

构建工作区：`build/luban-lite`（已在 `.gitignore` 中忽略）。

```powershell
# 1) 建立目录联接（参考 SDK 只读）
cd G:\Code\Zig\WuKong-Lite
New-Item -ItemType Directory -Force build\luban-lite | Out-Null
$root='G:\Code\C\luban-lite'
$dst=(Resolve-Path 'build\luban-lite').Path
foreach($d in @('application','bsp','kernel','packages','target','tools','patches')){
    New-Item -ItemType Junction -Path (Join-Path $dst $d) -Target (Join-Path $root $d) -Force | Out-Null
}
Copy-Item (Join-Path $root 'SConstruct'),(Join-Path $root 'SConscript'),(Join-Path $root 'Kconfig') $dst -Force

# 2) 工具链（本机已有 Xuantie V3.2.0）
$tc='G:\Code\Zig\WuKong-Lite\wk\image\xuantie\Xuantie-900-gcc-elf-newlib-mingw-V3.2.0-20250627'
foreach($d in @('bin','include','lib','libexec','riscv64-unknown-elf','share')){
    New-Item -ItemType Junction -Path (Join-Path $dst "toolchain\$d") -Target (Join-Path $tc $d) -Force | Out-Null
}

# 3) G++ 14 需要显式 zifencei：复制 rtconfig.py 到工作区根并修改 DEVICE
Copy-Item (Join-Path $root 'bsp\artinchip\sys\d13x\rtconfig.py') (Join-Path $dst 'rtconfig.py') -Force
$t = Get-Content (Join-Path $dst 'rtconfig.py') -Raw -Encoding UTF8
$t = $t.Replace("zpsfoperand' + ISA_TAG + '_xtheade", "zpsfoperand_zifencei' + ISA_TAG + '_xtheade")
Set-Content (Join-Path $dst 'rtconfig.py') -Value $t -Encoding UTF8

# 4) 构建 bootloader（生成 image_cfg 的 load/entry 与 bootloader.bin）
cd $dst
$env:RTT_EXEC_PATH=(Resolve-Path 'toolchain\bin').Path
$env:PATH='G:\Code\C\luban-lite\tools\env\tools\bin;' + $env:PATH
python -m SCons --apply-def=28
python -m SCons -j8

# 5) 构建 LVGL 应用镜像
python -m SCons --apply-def=29
python -m SCons -j8
```

最终镜像：

```text
build/luban-lite/output/d13x_demo88-nor_rt-thread_helloworld/images/d13x_demo88-nor_v1.0.0.img
```

本机实测：`12,263,936` 字节，SHA256
`9F507AB8DC25CB31C4F4439E5842EF62FF3B0EE61382A841728760CFF1640BF2`。
`upgcmd -e` 能解析出 `image.info`、`updater.psram/spl`、`target.spl/env/env_r/os/rodata/data`。

## 3. 烧录

### 方式 A：USB（推荐）

1. 开发板进入刷机模式：短路烧录引脚 **PA0 到地** 后上电，或按住板上 `uboot` 键上电/reset。
2. USB 线接板子的 **USB0**（不是 CP2102 串口），电脑应出现升级设备。
3. 执行：

```powershell
cd G:\Code\Zig\WuKong-Lite
.\wk\image\tools\upgcmd\upgcmd.exe -l
# 记下 bus:portnum，例如 1:5
.\wk\image\tools\upgcmd\upgcmd.exe -i artifacts\lvgl-firmware\d13x_demo88-nor_v1.0.0.img -d 1:5 -p -v
```

### 方式 B：UART

1. 安装 CP210x 驱动，确认设备管理器出现 `COMx`。
2. 开发板进入刷机模式（PA0 接地 / uboot 键）。
3. 执行：

```powershell
.\wk\image\tools\upgcmd\upgcmd.exe -i artifacts\lvgl-firmware\d13x_demo88-nor_v1.0.0.img -u COM5 -p -v
```

烧录完成后断开 PA0/松开按键并重新上电；串口控制台默认 `uart0`，LVGL 应显示
`demo_hub` 界面。若黑屏，先确认屏型/分辨率与 `CONFIG_AIC_DISP_LVDS`、
`CONFIG_AIC_PANEL_1024X600_RESOLUTION` 是否匹配。

## 4. 已知边界

- 该固件来自**官方 Luban-Lite 设备侧代码**（bootloader/RTOS/LVGL/HAL），
  不是 WuKong-Lite 自己实现的设备侧固件；WuKong-Lite 目前只负责主机侧镜像工具链。
- 构建工作区是目录联接，删除 `build/luban-lite` 不会影响参考 SDK。
- 本机 `upgcmd -l` 当前无设备；需先让板子进入刷机模式并接 USB0。
