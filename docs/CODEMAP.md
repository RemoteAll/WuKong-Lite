# WuKong-Lite 源码地图

> 供开发者和 AI Agent 快速定位实现。对照参考项目 `G:\Code\C\luban-lite`。

## 1. 配置与方案

| 文件 | 作用 |
|------|------|
| `wk/Kconfig` | 顶层配置树（Kernel / Build options / source 子配置） |
| `wk/target/d13x/Kconfig.chip` | d13x 芯片能力清单（`AIC_*_DRV`、版本号、外设开关） |
| `wk/target/d13x/demo88-nor/Kconfig.board` | demo88-nor 板级配置（介质、串口、启动地址） |
| `wk/target/configs/d13x_demo88-nor_rt-thread_helloworld_defconfig` | 方案配置 |
| `wk/config/.config` | 生成：配置结果（不提交） |
| `wk/config/cconfig.h` | 生成：C 宏头（不提交） |
| `wk/config/build_info.json` | 生成：工程元信息（不提交） |

## 2. 公共格式层 `src/bsp/common/`

| 文件 | 对应 Luban-Lite | 关键实现 |
|------|-----------------|----------|
| `crc32.zig` | `bsp/common/crc32/crc32.c` | 编译期生成 256 项表，ISO-HDLC |
| `checksum.zig` | `bsp/common/image/image.c` | `image_calc_checksum` / `image_verify_checksum` |
| `image.zig` | `bsp/common/include/aic_image.h` | `HeaderV1`(64B) / `HeaderV2`(80B)、构造/校验/dump |
| `partition.zig` | `bsp/common/partition/partition.c` | `parseMtd` / `parseGpt` / 名称查找 / dump |
| `gpt.zig` | `bsp/common/include/disk_part.h` | GPT 头/MBR/条目结构、CRC 校验、主备表生成 |
| `env_image.zig` | `tools/scripts/mkenvimage` + `packages/artinchip/env/env.c` | 单份/双份 env、CRC、前缀 |
| `utils.zig` | `tools/scripts/*.py` 小函数 | `sizeStrToInt`、`roundUp`、hexdump、定长字符串 |

## 3. 内核抽象 `src/kernel/common/`

| 文件 | 作用 |
|------|------|
| `osal.zig` | `Kernel`（节拍/线程表/睡眠）、`Mutex`、`Semaphore`、`Mailbox` |
| `device.zig` | `Device` + `DeviceOps` + `Registry`（注册/打开/引用计数/读写） |
| `heap.zig` | `Counting` 分配器包装（used/peak/alloc/free 统计，供 `free` 命令） |

## 4. 驱动（host 模拟）`src/bsp/artinchip/drv/`

| 文件 | 设备名 | 说明 |
|------|--------|------|
| `uart.zig` | `uart0` | char 设备，write → stdout |
| `gpio.zig` | `gpio0` | 128 引脚电平表，read/write |

## 5. 工具链 `src/tools/`

| 文件 | 对应脚本 | 说明 |
|------|----------|------|
| `kconfig.zig` | `tools/env` + `aic_build.py::chk_prj_config` | Kconfig 解析/表达式/求值/输出 |
| `image_cfg.zig` | `mk_image.py::parse_image_cfg` | 去注释 JSON、media/part/attr 解析 |
| `partition_table.zig` | `gen_partition_table.py` | MTD/UBI/GPT 宏、FAL 表、JSON、env 前缀 |
| `pack.zig` | `mk_image.py`（打包部分） | AIC.FW 组装、AIC 镜像、env、页表 |

## 6. 应用与 shell

| 文件 | 说明 |
|------|------|
| `src/shell/shell.zig` | 分词、命令分派、交互式循环（stdin） |
| `src/shell/cmds.zig` | `help/version/uptime/ps/free/date/list_device/part/gpio/reboot` |
| `src/application/helloworld.zig` | 线程 + 邮箱 + 信号量示例 |
| `src/main.zig` | `wk` CLI：`defconfig/config/image/shell/run/demo` |
| `src/aic.zig` | 顶层模块导出（测试入口） |

## 7. 关键格式速查

### AIC 镜像头 V1（64 字节，小端）

```
0x00 magic(4)       = 0x20434941 "AIC "
0x04 checksum(4)    = ~sum32(image with checksum=0)
0x08 head_ver(4)    0x00010000
0x0C image_len(4)
0x10 fwver_counter/revision/minor/major (4×u8)
0x14 firmware_len(4)
0x18 load_address(4)
0x1C entry_point(4)
0x20 sign_algo(4) 0x24 encrypt_algo(4)
0x28..0x3F sign/iv offset+len (6×u32)
```

### AIC.FW 固件包

```
+0        文件头 348B（"AIC.FW" + platform/product/version/media_type + meta/file 区偏移/大小）
+2048     META 表，每项 512B（"META" + name/partition/part_offset/part_size/dev/offset/size/crc/ram/attr/file）
file_off  数据区，每个文件 2 KiB 对齐，空隙填 0
```

### U-Boot env

```
单一：u32 crc32(data) | data[size-4]（NUL 分隔，0x00 填充）
双份：u32 crc | u8 flags(1=active,0=obsolete) | data[size-5]，连续两份
```

### NAND 页表（AICP）

```
head(20B): "AICP" + entry_cnt(u32) + page_size(u16) + pages_per_block(u8) + 0xFF + planes(u8) + 7×0xFF
entry(20B)×101: pageaddr1 + pageaddr2 + checksum2 + reserved + checksum1
校验和写在偏移 36（首个 entry 的 checksum1），整页 sum+1==0
```

## 8. 常见任务

- **加一个新的板级方案**：复制 `wk/target/configs/*_defconfig` 改 `PRJ_*`，在对应 `Kconfig.board` 增加开关，执行 `wk defconfig`。
- **加一个配置项**：在 Kconfig 中 `config XXX`，`bool/string/int` + `default`；生成结果自动进 `.config` / `cconfig.h`。
- **加一个镜像组件**：编辑板级 `image_cfg.json` 的 `image.target`，`part` 指向已定义分区；`wk demo` / `wk image pack` 验证。
- **排查镜像**：`wk image dump <file>`（自动识别 AIC / AIC.FW / env）。
