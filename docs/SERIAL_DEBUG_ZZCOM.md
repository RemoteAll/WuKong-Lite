# 用 ZZCOM 调试 Zig 固件（串口）

> 场景：D123BBV（d12x / demo68-nor）开发板，Windows 上通过 USB-UART 抓启动日志。
> 工具：`F:\Code\Zig\ZZCOM`（纯 Win32 串口调试助手 + MCP 服务端）。

## 1. 串口识别

```powershell
Get-CimInstance Win32_SerialPort | Select-Object DeviceID, Description, PNPDeviceID
```

实测（2026-11-19）：`COM3` = `USB-SERIAL CH343`（`VID_1A86&PID_55D3`），`COM1` 为主板自带串口。

## 2. 构建 ZZCOM

ZZCOM 需要 **Zig 0.17.x**（`build.zig` 使用 `std.lang.Optimize`，0.15.x 会报错）：

```powershell
$zig = 'E:\Soft\zig-x86_64-windows-0.17.1\zig-x86_64-windows-0.17.1\zig.exe'
cd F:\Code\Zig\ZZCOM
& $zig build
# 产物：zig-out\bin\zzcom-x64.exe / zzcom-mcp-x64.exe
```

## 3. 用 MCP 接口收发（推荐，AI/脚本可复用）

ZZCOM 提供两种 MCP 传输，共用同一套工具（`serial_list_ports` / `serial_open` / `serial_read` / `serial_write` / `serial_close` / `serial_status` / `serial_set_lines`）：

- HTTP：`zzcom-x64.exe` 界面里菜单 **MCP → 启用**，端点 `http://127.0.0.1:8765/mcp`，需 Bearer 令牌（见 `zzcom.ini`）。
- stdio：`zzcom-mcp-x64.exe`，每行一条 JSON-RPC。

本仓库可直接用 ZZCOM 自带的 PowerShell 客户端（无需 VS Code MCP 配置）：

```powershell
# 列出串口
powershell -NoProfile -File F:\Code\Zig\ZZCOM\tools\serial-ctl.ps1 -Action list

# 抓 10 秒日志（115200，默认不拉高 DTR/RTS）
powershell -NoProfile -File F:\Code\Zig\ZZCOM\tools\serial-ctl.ps1 -Action capture `
  -Port COM3 -Baud 115200 -Seconds 10 -Log F:\Code\Zig\ZZCOM\artifacts\uart-com3.txt

# 发一行命令（回车换行）
powershell -NoProfile -File F:\Code\Zig\ZZCOM\tools\serial-ctl.ps1 -Action send `
  -Port COM3 -Baud 115200 -Text "help" -Newline 3 -Seconds 3

# 复位脉冲（DTR/RTS 低-高切换，视板子自动下载电路而定）
powershell -NoProfile -File F:\Code\Zig\ZZCOM\tools\serial-ctl.ps1 -Action lines -Port COM3 -Dtr $false -Rts $false
```

### DTR/RTS 默认值（2026-11-19 调整）

ZZCOM 打开串口**默认不拉高 DTR/RTS**（`DTR_CONTROL_DISABLE` / `RTS_CONTROL_DISABLE`）。
同类工具对照：Tera Term 默认拉高（`FlowCtrlDTR=1/FlowCtrlRTS=1`）、picocom 默认“系统相关、多数拉高”但提供 `--lower-dtr/--lower-rts`、Node `serialport` 默认 `DTR_CONTROL_DISABLE`（源码注释 “disable DTR to avoid reset”）。
需要拉高时：界面勾选 `DTR`/`RTS` 复选框，或 MCP `serial_open` 传 `"dtr":true,"rts":true`。

## 4. 已实测结果（2026-11-19）

| 项目 | 结果 |
|---|---|
| COM3 打开 | 成功（CH343 驱动正常） |
| 115200 抓 6 s / 90 s | **0 字节**（RX=0 TX=0） |
| 115200 / 921600 / 1500000 / 3000000 发 `0d 0d 0d` 后读 2 s | **无任何回显** |
| DTR/RTS 拉低后再抓 | 仍 0 字节 |

结论：板子当前**没有任何串口输出**，不是 ZZCOM 收发链路的问题（工具侧已确认能打开、能发送）。

## 5. 现场排查清单（按顺序）

1. **供电**：板上电源灯/屏背光是否亮？只插 USB 转串口线不一定给 SoC 供电。
2. **接线**：COM3 的 CH343 是否接到板子标注的调试串口（UART0/DEBUG）？TX/RX 是否交叉、GND 是否共地。
3. **复位**：按板载复位键或断电重上电，同时保持抓包（`-Seconds 90`）。
4. **启动方式**：PA0 是否被拉低（刷机模式）？刷机模式下应用不运行、控制台可能无输出。
5. **波特率**：Luban-Lite 默认控制台 115200；若改过 `CONFIG_UART0_BAUD` 需对应调整。
6. **固件本身**：黑屏且串口全静默 → 优先怀疑 bootloader/SPL 阶段就没跑起来（供电、时钟、镜像损坏）。

## 6. 抓到日志之后

- 原始字节保存在 `-Log` 指定文件，同时脚本会把可打印部分打印到终端（`RX n B`）。
- 如需 HEX 查看：`-Action capture` 输出的是解码文本；逐字节分析可用 MCP `serial_read` 返回的 `HEX:` 行。
