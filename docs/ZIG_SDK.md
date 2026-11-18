# 设备侧 Zig SDK（0.1）

> 目标：**官方 C SDK 保留**（bootloader / RT-Thread / HAL / LVGL），
> 同时提供一套 Zig 可调用的设备侧 SDK，编译成静态库链接进官方固件。
> 这样不是“用 Zig 重写整个 SDK”，而是让设备应用/业务代码可以用 Zig 写。

## 1. 分层

```text
┌─────────────────────────────────────────────┐
│  Zig 应用（device/app.zig）                  │
│  sdk.rt / sdk.gpio / sdk.lvgl / sdk.board    │
├─────────────────────────────────────────────┤
│  libwksdk.a（Zig 静态库，C ABI）              │
├─────────────────────────────────────────────┤
│  官方 C SDK：RT-Thread / HAL / LVGL / 启动    │
│  （bootloader、驱动、显示、触摸均保留官方）     │
└─────────────────────────────────────────────┘
```

## 2. 目录

| 文件 | 作用 |
|------|------|
| `device/sdk.zig` | SDK 入口，导出 `rt`/`gpio`/`lvgl`/`board` |
| `device/rt.zig` | `rt_kprintf`、`rt_thread_mdelay`、`rt_tick_get` 包装 |
| `device/gpio.zig` | `rt_pin_mode/write/read/get` 包装 |
| `device/lvgl.zig` | LVGL v9 常用 C API 的 extern 声明（不重写 LVGL） |
| `device/board.zig` | D13x demo88-nor 屏/触摸常量 |
| `device/app.zig` | 示例入口 `wk_sdk_demo()` / `wk_sdk_version()` |
| `device/integration/SConscript` | 把 `libwksdk.a` 注入官方 SCons 链接 |

## 3. 构建静态库

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-zig-sdk.ps1
# 产物：wk\image\apps\libwksdk.a
```

已验证：`riscv64-unknown-elf-nm` 能看到 `wk_sdk_demo`、`wk_sdk_version`。

## 4. 链接进官方 LVGL 固件

前提：已按 `docs/LVGL_FIRMWARE.md` 建好 `build/luban-lite` 工作区。

```powershell
powershell -ExecutionPolicy Bypass -File tools\attach-zig-sdk.ps1

cd build\luban-lite
$env:WK_REPO='G:\Code\Zig\WuKong-Lite'
$env:RTT_EXEC_PATH=(Resolve-Path 'toolchain\bin').Path
# 旧 MSYS echo/ls 会挂起；优先用 Git 的 MSYS2 工具 + 空 echo 垫片。
$env:PATH='G:\Code\Zig\WuKong-Lite\build\toolbin;D:\Program Files\Git\usr\bin;G:\Code\C\luban-lite\tools\env\tools\bin;' + $env:PATH
python -m SCons -j8
```

脚本做三件事：

1. 把官方 `application/` 复制到构建工作区（首次从目录联接切为真实副本）；
2. 在 `application/rt-thread/helloworld/zig_sdk/` 放入 SConscript，
   把 `libwksdk.a` 追加到链接库，并加 `-Wl,--wrap=lv_user_gui_init`；
3. 在 `main.c` 的 `main()` 开头调用 `wk_sdk_demo()`。

Zig 侧导出 `__wrap_lv_user_gui_init()`：官方 LVGL 线程在 `lv_init()`、
`lv_port_disp_init()` 之后调用 `lv_user_gui_init()`，链接器把它改接到 Zig 包装函数；
包装函数先调用 `__real_lv_user_gui_init()`，再在 **LVGL 顶层图层** 创建 Label。
这样不会在 LVGL 初始化之前调用 `lv_timer_create()`（那会访问未初始化的
`timer_ll_p`，启动即异常）。

## 5. 已验证

- 构建成功，最终镜像为 12,265,984 B；
- `d13x.elf` 中存在 `__wrap_lv_user_gui_init`，且 `lvgl_thread_entry` 的调用已重定向到它；
- `d13x.bin` 中存在 7 处 `[zig-sdk]` 日志字符串；
- `d13x.bin` 中存在 `Hello from Zig SDK`；Zig 在 LVGL 顶层图层创建并居中显示 Label，
  不会被 `demo_hub` 的页面遮住；
- 已移除启动早期 `lv_timer_create()`，避免 LVGL 未初始化时崩溃；
- LVGL 官方 demo_hub 仍由官方 C 代码初始化，Zig 只追加自己的 Label。

含 Zig SDK 的镜像：

```text
artifacts/lvgl-firmware/d13x_demo88-nor_zig_v1.0.0.img
大小：12,265,984 B
SHA256：EC8329B7BE44A4A78A8110542CF911EF5B3188C3A840EA3359507B4748FD0168
```

`upgcmd -e` 已验证可解析全部 9 个组件。烧写与现场排查见
`docs/FLASH_ZIG_FIRMWARE.md`。

> 注意：加了 Zig SDK 后，镜像不再与纯 C 版逐字节相同（这是预期差异）；
> 纯 C 版与 Zig 打包版的 `DIFF=0` 对比见 `docs/LVGL_FIRMWARE.md` 2.1 节。

## 6. 下一步

- 把 Label 改成按钮/图片等控件，补 `lv_obj_set_style_*`、`lv_event` 绑定；
- 补 UART、I2C、显示 framebuffer 等 HAL 包装；
- 把业务逻辑逐步迁到 `device/`，官方 C 驱动保持不动。

## 7. 边界

- 仍然**没有纯 Zig 的 bootloader/RT-Thread/HAL**；这些继续用官方 C SDK。
- 这套 SDK 的定位是“Zig 应用层 + C 设备层”，不是替换官方 SDK。
- LVGL 是 C 库，Zig 只绑定 API；跨线程操作必须走 LVGL 定时器/锁，不能直接在
  任意 Zig 线程里改控件。
