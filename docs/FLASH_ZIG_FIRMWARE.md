# Zig SDK 固件烧写与现场排查（D13x demo88-nor）

> 交付物：`artifacts/lvgl-firmware/d13x_demo88-nor_zig_v1.0.0.img`  
> 大小：`12,265,984` 字节  
> SHA256：`EC8329B7BE44A4A78A8110542CF911EF5B3188C3A840EA3359507B4748FD0168`  
> 适用板卡：`d13x demo88-nor`（SPI NOR）、1024×600 LVDS、GT911 触摸。  
> 说明：bootloader / RT-Thread / HAL / LVGL 仍来自官方 Luban-Lite C SDK；
> Zig 以静态库链接进去，负责日志与 LVGL 顶层 Label。
## 1. 烧写前校验（在电脑上，不需要板子）

```powershell
cd G:\Code\Zig\WuKong-Lite
Get-FileHash artifacts\lvgl-firmware\d13x_demo88-nor_zig_v1.0.0.img -Algorithm SHA256
# 应为 EC8329B7BE44A4A78A8110542CF911EF5B3188C3A840EA3359507B4748FD0168

# upgcmd 解析镜像（必须用绝对路径；相对路径会报 Invalid arguments）
.\wk\image\tools\upgcmd\upgcmd.exe -e G:\Code\Zig\WuKong-Lite\artifacts\lvgl-firmware\d13x_demo88-nor_zig_v1.0.0.img
```

应列出 9 个组件：

```text
image.info / image.updater.psram / image.updater.spl
image.target.spl / image.target.env / image.target.env_r
image.target.os / image.target.rodata / image.target.data
```

如果 `upgcmd -e` 报 `Invalid arguments`，先确认传给 `-e` 的是**绝对路径**。

## 2. USB 烧写（推荐）

1. 开发板进入升级模式：**PA0 短接到地** 后上电，或按住板上 `uboot` 键上电/reset。
2. USB 线接板子的 **USB0**（升级口），不要接 CP2102 串口。
3. 电脑安装 UsbDk（upgcmd 的 USB 依赖），然后：

```powershell
cd G:\Code\Zig\WuKong-Lite
.\wk\image\tools\upgcmd\upgcmd.exe -l
# 记下输出里的 bus:port，例如 1:5

.\wk\image\tools\upgcmd\upgcmd.exe -i artifacts\lvgl-firmware\d13x_demo88-nor_zig_v1.0.0.img -d 1:5 -p -v
```

把 `1:5` 换成 `-l` 实际显示的 `bus:port`。

## 3. UART 烧写（USB 升级口不可用时）

1. 安装 CP210x 驱动，设备管理器确认出现 `COMx`。
2. 板子同样进入升级模式（PA0 接地 / uboot 键）。
3. 执行：

```powershell
.\wk\image\tools\upgcmd\upgcmd.exe -i artifacts\lvgl-firmware\d13x_demo88-nor_zig_v1.0.0.img -u COM5 -p -v
```

把 `COM5` 换成实际串口。不要在命令里写 `-b`，让工具自动协商波特率。

烧写完成后：断开 PA0 / 松开按键，重新上电。

## 4. 串口日志（现场判断的第一手证据）

控制台：**UART0，115200，8N1**。用任意串口工具抓日志，正常应看到：

```text
[zig-sdk] WuKong-Lite Zig SDK v0.1.0
[zig-sdk] board=d13x-demo88-nor, tick=..., ms=...
[zig-sdk] waiting for LVGL thread to call lv_user_gui_init
...
[zig-sdk] Zig Label created on LVGL top layer
```

同时应看到官方 `demo_hub` 启动日志；屏幕显示 demo_hub，Zig 的
`Hello from Zig SDK / WuKong-Lite + LVGL V9` Label 叠加在**顶层图层**。

### 判断表

| 现象 | 说明 / 下一步 |
|------|----------------|
| 完全看不到 `[zig-sdk]` | 固件没真正写进去，或写的是旧镜像；重新核对 SHA256、`upgcmd` 输出和分区偏移。 |
| 看到版本和 board，但没有 `Zig Label created` | 卡在 LVGL 初始化；看后面是否有 `LVGL top layer is null` 或 `lv_label_create failed`。 |
| `LVGL top layer is null` | LVGL 显示/面板初始化失败；先确认屏型、1024×600 LVDS 配置、背光和排线。 |
| `lv_label_create failed` | LVGL 堆/初始化异常；记录完整串口日志，先回退纯 C 固件确认硬件。 |
| 有 `Zig Label created` 但屏幕黑 | 不是 Zig 的问题；查背光、LVDS 排线、panel 配置。 |
| 启动即复位/卡死 | 先刷纯 C 固件对比；若纯 C 也异常，查供电/屏/Flash；若仅 Zig 版异常，保留串口 PC/RA 和完整日志。 |

## 5. 回退用纯 C 固件

同目录下的纯 C 基线（不含 Zig）：

```text
artifacts/lvgl-firmware/d13x_demo88-nor_v1.0.0.img
大小：12,263,936 B
SHA256：9F507AB8DC25CB31C4F4439E5842EF62FF3B0EE61382A841728760CFF1640BF2
```

烧写命令相同，只把文件名换掉。它是判断“硬件/屏/供电问题”还是
“Zig 集成问题”的基线。
