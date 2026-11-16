//! 自动生成文件：由 `wk defconfig` / `wk config set` 写入，请勿手工修改。
//! 对应 Luban-Lite 的 cconfig.h（编译期配置常量）。

pub const PRJ_DEFCONFIG_FILENAME = "d13x_demo88-nor_rt-thread_helloworld_defconfig";
pub const PRJ_CHIP = "d13x";
pub const PRJ_BOARD = "demo88-nor";
pub const PRJ_KERNEL = "rt-thread";
pub const PRJ_APP = "helloworld";
pub const KERNEL_RT_THREAD = true;
pub const KERNEL_BAREMETAL = false;
pub const KERNEL_HEAP_SIZE: u64 = 1048576;
pub const AIC_IMAGE_PACK = true;
pub const AIC_IMAGE_META_ALIGN: u64 = 512;
pub const AIC_CHIP_D13X = true;
pub const AIC_CHIP_FAMILY = "artinchip-d13x";
pub const AIC_CMU_DRV = true;
pub const AIC_CMU_DRV_VER = "31";
pub const AIC_GPIO_DRV = true;
pub const AIC_GPIO_DRV_VER = "21";
pub const AIC_UART_DRV = true;
pub const AIC_UART_DRV_VER = "14";
pub const AIC_MAILBOX_DRV = true;
pub const AIC_MAILBOX_DRV_VER = "11";
pub const AIC_USING_UART0 = true;
pub const AIC_USING_GPIO = true;
pub const AIC_CONSOLE_DEVICE = "uart0";
pub const AIC_IRQ_STACK_SIZE: u64 = 4096;
pub const AIC_BOARD_DEMO88_NOR = true;
pub const AIC_BOARD_MEDIA = "spi-nor";
pub const AIC_BOARD_SPINOR_SIZE = "16m";
pub const AIC_BOARD_CONSOLE = "uart0";
pub const AIC_BOARD_CONSOLE_BAUD: u64 = 115200;
pub const AIC_BOOTLOADER_LOAD_BASE: u64 = 0x40100000;
pub const AIC_BOOTLOADER_TEXT_BASE: u64 = 0x40100000;
pub const AIC_USING_LVGL = false;
