//! 由 Kconfig 配置生成 Zig 常量模块 —— 等价 `chk_prj_config` 把 `.config`
//! 变成编译期可见的 `rtconfig.h` / `cconfig.h`。
//!
//! 生成目标：`src/generated/config.zig`
//!   * bool/tristate -> `pub const XXX = true/false;`
//!   * string        -> `pub const XXX = "value";`
//!   * int/hex       -> `pub const XXX: u64 = 123;`
//!
//! 代码里可用 `@import("generated/config.zig")` 在编译期裁剪模块注册逻辑。
const std = @import("std");
const kconfig = @import("kconfig.zig");

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn isNumeric(value: []const u8) bool {
    if (std.fmt.parseInt(u64, value, 0)) |_| return true else |_| {}
    if (std.fmt.parseInt(i64, value, 0)) |_| return true else |_| {}
    return false;
}

fn writeBool(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    const enabled = std.mem.eql(u8, value, "y") or std.mem.eql(u8, value, "m");
    try w.print("pub const {s} = {};\n", .{ name, enabled });
}

fn writeInt(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    // 保留 0x 写法；十进制原样
    try w.print("pub const {s}: u64 = {s};\n", .{ name, value });
}

/// 从 Kconfig 配置对象生成 Zig 源文本。
pub fn generate(cfg: *kconfig.Config, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\//! 自动生成文件：由 `wk defconfig` / `wk config set` 写入，请勿手工修改。
        \\//! 对应 Luban-Lite 的 cconfig.h（编译期配置常量）。
        \\
        \\
    );
    for (cfg.items.items) |it| {
        const value = it.value orelse continue;
        switch (it.typ) {
            .bool_, .tristate => try writeBool(writer, it.name, value),
            .string => {
                try writer.print("pub const {s} = ", .{it.name});
                try writeEscaped(writer, value);
                try writer.writeAll(";\n");
            },
            .int_, .hex => try writeInt(writer, it.name, value),
            .unknown => {
                // defconfig 中额外声明的符号：按值推断类型
                if (std.mem.eql(u8, value, "y") or std.mem.eql(u8, value, "m") or std.mem.eql(u8, value, "n")) {
                    try writeBool(writer, it.name, value);
                } else if (isNumeric(value)) {
                    try writeInt(writer, it.name, value);
                } else {
                    try writer.print("pub const {s} = ", .{it.name});
                    try writeEscaped(writer, value);
                    try writer.writeAll(";\n");
                }
            },
        }
    }
}

/// 从 `.config` 文本生成 Zig 源（`wk config set` 使用，无需 Kconfig 类型信息）。
pub fn generateFromDot(writer: *std.Io.Writer, dot_text: []const u8) !void {
    try writer.writeAll(
        \\//! 自动生成文件：由 `wk defconfig` / `wk config set` 写入，请勿手工修改。
        \\//! 对应 Luban-Lite 的 cconfig.h（编译期配置常量）。
        \\
        \\
    );
    var lines = std.mem.splitScalar(u8, dot_text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# CONFIG_") and std.mem.endsWith(u8, line, " is not set")) {
            const name = line["# CONFIG_".len .. line.len - " is not set".len];
            try writer.print("pub const {s} = false;\n", .{name});
            continue;
        }
        if (!std.mem.startsWith(u8, line, "CONFIG_")) continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const name = line["CONFIG_".len..eq];
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, value, "y") or std.mem.eql(u8, value, "m") or std.mem.eql(u8, value, "n")) {
            try writeBool(writer, name, value);
        } else if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            try writer.print("pub const {s} = ", .{name});
            try writeEscaped(writer, value[1 .. value.len - 1]);
            try writer.writeAll(";\n");
        } else if (isNumeric(value)) {
            try writeInt(writer, name, value);
        } else {
            try writer.print("pub const {s} = ", .{name});
            try writeEscaped(writer, value);
            try writer.writeAll(";\n");
        }
    }
}

test "从 Kconfig 生成 Zig 常量" {
    const allocator = std.testing.allocator;
    var cfg = kconfig.Config.init(allocator);
    defer cfg.deinit();

    var conds: std.ArrayList(*const kconfig.Expr) = .empty;
    defer conds.deinit(allocator);
    try cfg.parseText(
        \\config AIC_UART_DRV
        \\    bool "UART"
        \\    default y
        \\config AIC_USING_LVGL
        \\    bool "LVGL"
        \\    default n
        \\config AIC_BOARD_CONSOLE
        \\    string "console"
        \\    default "uart0"
        \\config AIC_BOOTLOADER_LOAD_BASE
        \\    hex "load"
        \\    default 0x40100000
        \\config AIC_BAUD
        \\    int "baud"
        \\    default 115200
    , &conds, null, ".", 0);
    cfg.resolve();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try generate(&cfg, &aw.writer);
    const text = aw.written();

    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_UART_DRV = true;") != null);
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_USING_LVGL = false;") != null);
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_BOARD_CONSOLE = \"uart0\";") != null);
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_BOOTLOADER_LOAD_BASE: u64 = 0x40100000;") != null);
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_BAUD: u64 = 115200;") != null);
}

test "从 .config 文本生成 Zig 常量" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try generateFromDot(&aw.writer,
        \\CONFIG_AIC_UART_DRV=y
        \\# CONFIG_AIC_USING_LVGL is not set
        \\CONFIG_AIC_BOARD_CONSOLE="uart0"
        \\CONFIG_AIC_BAUD=115200
        \\
    );
    const text = aw.written();
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_UART_DRV = true;") != null);
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_USING_LVGL = false;") != null);
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_BOARD_CONSOLE = \"uart0\";") != null);
    try std.testing.expect(std.mem.find(u8, text, "pub const AIC_BAUD: u64 = 115200;") != null);
}
