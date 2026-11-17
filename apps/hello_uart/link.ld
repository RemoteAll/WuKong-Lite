/* D13x 裸机链接脚本：入口 0x41000000（os 分区加载地址），栈在 0x41080000。 */
ENTRY(_start)
SECTIONS
{
    . = 0x41000000;
    .text : { *(.text._start) *(.text*) *(.rodata*) }
    .data : { *(.data*) *(.sdata*) }
    .bss  : { *(.bss*) *(.sbss*) *(COMMON) }
    __stack_top = 0x41080000;
}
