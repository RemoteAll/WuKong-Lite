# littlefs（内置副本）

- 来源：Luban-Lite `packages/third-party/littlefs`（上游 littlefs 2.5，`LFS_VERSION 0x00020005`）。
- 文件：`lfs.c`、`lfs.h`、`lfs_util.c`、`lfs_util.h`（原样复制，未修改）。
- 许可证：BSD-1-Clause，见 `LICENSE.md`。
- 用途：`wk image littlefs` 通过 Zig `TranslateC` 绑定调用，生成与设备端 littlefs 2.x 兼容的镜像；
  Zig 侧只做目录遍历、内存块设备与镜像裁剪，不重复实现文件系统格式。
