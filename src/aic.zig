//! WuKong-Lite 顶层模块：集中导出各层实现，供 CLI 与单元测试引用。
//!
//! 目录与 Luban-Lite 的对应关系：
//!   bsp/common        <-  bsp/common（镜像/分区/CRC/env 等公共层）
//!   kernel/common     <-  kernel/common（OSAL 抽象）
//!   bsp/artinchip/drv <-  驱动层（host 模拟实现）
//!   tools             <-  tools/scripts（Kconfig、镜像打包工具）
//!   application       <-  application/<kernel>/<app>
pub const crc32 = @import("bsp/common/crc32.zig");
pub const checksum = @import("bsp/common/checksum.zig");
pub const image = @import("bsp/common/image.zig");
pub const partition = @import("bsp/common/partition.zig");
pub const utils = @import("bsp/common/utils.zig");
pub const env_image = @import("bsp/common/env_image.zig");
pub const gpt = @import("bsp/common/gpt.zig");
pub const fw_image = @import("bsp/common/fw_image.zig");
pub const kconfig = @import("tools/kconfig.zig");
pub const image_cfg = @import("tools/image_cfg.zig");
pub const partition_table = @import("tools/partition_table.zig");
pub const pack = @import("tools/pack.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
