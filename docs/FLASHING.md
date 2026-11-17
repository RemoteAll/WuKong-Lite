# 烧写到芯片模组（官方 upgcmd 路径）

Luban-Lite 的官方烧写文档在 `doc/skills/aiburn/`，已原样迁移到
`docs/official/skills/aiburn/`。实际烧写工具有两条路：

1. **`upgcmd.exe` 直接烧**（本 SDK 自带，推荐）：UART 或 USB，命令行即可。
2. **AIBURN 脚本**（`aiburn.py` + upgcmd Server `:9100` + 串口日志）：
   本 SDK 的 `upgcmd.exe` **没有** server 模式，这一路需要厂商带 server 的版本。

## 关于“upgcmd 是否开源”

- SDK 里只有**预编译**的 `tools/scripts/upgcmd`（Linux ELF）与 `upgcmd.exe`（32 位 Windows），
  没有主机端源码（二进制里能看到构建路径 `aicupg/upgcmd/main.cpp`、libusb + UsbDk）。
- **设备端协议是开源的**：`application/baremetal/bootloader/lib/aicupg/*.c`
  （含 `uart_proto_layer.c`、`nor_fwc.c`、`nand_fwc.c` 等）。
- **上位机客户端也是开源的**：`doc/skills/aiburn/scripts/aiburn/aicupg_client.py`（Apache-2.0），
  但它走 TCP 连 upgcmd Server，不是直接操作 USB/UART。

## 一、准备可运行的 upgcmd（只需一次）

`upgcmd.exe` 缺 3 个 SDK 内没有的 DLL，已提供脚本自动补齐：

```powershell
powershell -ExecutionPolicy Bypass -File tools\fetch-upgcmd-deps.ps1 -SdkRoot G:\Code\C\luban-lite
```

脚本会下载并解包到 `wk\image\tools\upgcmd`（已 gitignore）：

| DLL | 来源 | 作用 |
|-----|------|------|
| `UsbDkHelper.dll` | UsbDk 1.0.22 x86 MSI | USB 后端（libusb 的 UsbDk 模式） |
| `libgcc_s_dw2-1.dll` | MSYS2 `mingw-w64-i686-libgcc` | 32 位 GCC 运行库 |
| `libwinpthread-1.dll` | MSYS2 `mingw-w64-i686-libwinpthread` | libgcc 的传递依赖 |

依赖 7-Zip（`C:\Program Files\7-Zip\7z.exe` 或 PATH 中的 `7z`）。

## 二、生成镜像并烧写

```powershell
# 1) 用真实厂商 bootloader/OS 打 AIC.FW，并生成烧写脚本
wk image flashpack --payload-dir payload --out-dir flash

# 2) 先看命令
cd flash
.\flash-upgcmd.ps1 -Monitor COM5 -DryRun

# 3) UART 烧写（默认）
.\flash-upgcmd.ps1 -Monitor COM5

#    或 USB（先 upgcmd -l 查 bus:portnum；需安装 UsbDk 驱动）
.\flash-upgcmd.ps1 -Dev 1:5
```

等价的原生命令：

```powershell
upgcmd.exe -i demo88-nor.img -u COM5 -p -v
upgcmd.exe -i demo88-nor.img -d 1:5 -p -v
upgcmd.exe -l                 # 列 USB 设备
upgcmd.exe -e demo88-nor.img  # 只解析/解包镜像
```

`upgcmd V1.4.2` 还支持：`chipdata <file>`、`jtagunlock`、`continue`、
`write/read/writel/readl`、`memtest`、`exec <addr>`。

## 三、本机已验证（2026-11-17）

- 补齐 3 个 DLL 后 `upgcmd -h` 正常输出版本与全部子命令；
- `upgcmd -l` 在无设备时输出 `No usbupg device is found.`（预期）；
- `upgcmd -e demo88-nor.img` **成功解析本工具生成的 AIC.FW**，列出并解出：
  `image.updater.psram/spl_loader`、`image.info`、`image.target.spl/env/env_r/os/rodata/data`。

## 四、常见问题

| 现象 | 处理 |
|------|------|
| `upgcmd.exe` 退出码 `0xC0000135` | 缺 DLL：跑 `tools\fetch-upgcmd-deps.ps1` |
| `No usbupg device is found` | USB 未进升级模式 / 未装 UsbDk 驱动；或改用 `-u COMx` |
| UART 打不开串口 | 串口被占用，或 `-b` 波特率不匹配 |
| 烧完不启动 | 先看串口 SPL；`bootloader.aic` 必须是厂商 PBP+loader 组合 |
| AIBURN 连不上 9100 | 本 SDK 的 upgcmd 无 server 模式，用方式一或厂商 server 版 |

## 边界

- WuKong-Lite 不生成 PBP，也不实现 USB/UART 升级协议；只做镜像格式、打包、
  校验、生成脚本。**bootloader 与 OS 必须来自厂商 SDK/发布包。**
