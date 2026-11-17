# upgcmd 二进制里的“源码线索”

## 结论

`main.cpp` 只是编译时写进二进制的**调试路径字符串**，SDK 里并没有这个文件，
官方公开仓库也没有主机端 `upgcmd` 源码。

## 证据

1. 全 SDK 搜索 `main.cpp` 只命中无关文件：
   - `packages/third-party/mklittlefs/main.cpp`
   - `tools/cmake/share/cmake-3.16/Modules/CheckIPOSupported/main.cpp`
2. `tools/scripts/upgcmd`（Linux ELF，565 KB）**未 strip**：
   - 含 `.debug_info`、`.debug_line`、`.symtab`；
   - 嵌入的构建路径：
     ```
     /home/artmem.com/mintao.duan/workspace/aicupg/upgcmd
     /home/artmem.com/mintao.duan/workspace/aicupg/libaicupg
     /home/artmem.com/mintao.duan/workspace/aicupg/libaicimg
     /home/artmem.com/mintao.duan/workspace/aicupg/libusb-1.0.23/libusb
     ```
   - 源码文件名：`main.cpp`、`app_proto_layer.c`、`data_trans_layer.c`、
     `aic_image.c`、`libaicupg.h`、`libuart.h`、`libusb.h` 等。
3. `artmem.com` 是厂商内部构建机域名（公网无法解析），对应仓库未公开。
4. 官方 GitHub：
   - `artinchip/luban-lite` 只有**设备端** `application/baremetal/bootloader/lib/aicupg/*`；
   - `artinchip/tools` 只有 AiBurn/AiBurnPro/AiBurnID 安装包；
   - 全站搜索 `upgcmd`/`aicupg` 无官方主机端仓库。

## 能从二进制里读到什么

Linux 版符号表共 736 个符号，其中 47 个与 `aicupg` 相关，函数名与设备端命令一一对应：

```
aicupg_app_proto_init/exit          aicupg_trans_init/exit
aicupg_ping_device                  aicupg_trans_send_pkt/recv_pkt
aicupg_cmd_set_upg_cfg             aicupg_cmd_get_hwinfo
aicupg_cmd_get_partition_table      aicupg_cmd_get_storage_media
aicupg_cmd_send_fwc_data_start/update/final
aicupg_cmd_read_fwc_data_start/final
aicupg_cmd_set_fwc_meta             aicupg_cmd_get_fwc_crc
aicupg_cmd_get_fwc_burn_result      aicupg_cmd_get_fwc_run_result
aicupg_cmd_continue_boot            aicupg_cmd_jtag_unlock
aicupg_cmd_exec                     aicupg_cmd_run_shell_str
aicupg_cmd_read/write               aicupg_cmd_get_mem_buf/free_mem_buf
libaicupg_init/exit                 libaicupg_get_link_mode/set_verbose
```

这些名字和**开源的设备端实现**（`lib/aicupg/*.c`，如 `app_proto_layer.c` 的对应命令）
是同一套协议；DWARF 只包含文件/行号/类型信息，**不包含源码文本**。

## 可行路径

1. **直接用预编译**（最快）：`tools/fetch-upgcmd-deps.ps1` 补齐 3 个 DLL，
   已验证 `upgcmd -e` 能解析本仓库生成的 AIC.FW。
2. **向厂商索取源码**：内部仓库名可从路径推断为 `aicupg`（含 `upgcmd`/`libaicupg`/`libaicimg`）。
3. **自写主机端**：以开源的设备端 `lib/aicupg` 协议为准，实现 UART 客户端；
   不需要 UsbDk，只需串口。符号表可作为行为对照，但不能替代源码。
