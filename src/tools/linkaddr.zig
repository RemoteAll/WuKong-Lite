//! 计算 bootloader 链接地址并替换 image_cfg.json 占位符 —— 对应参考工程
//! `tools/scripts/calc_linked_addr.py`。
//!
//! 规则与参考一致：
//!   * `CONFIG_AIC_BOOTLOADER_MEM_AUTO=y` 时，TEXT_BASE 由 RAM 顶 - HEAP - TEXT_SIZE 算出；
//!   * 否则直接取 `CONFIG_AIC_BOOTLOADER_TEXT_BASE`；
//!   * LOAD_BASE = TEXT_BASE - 0x100；
//!   * 依次替换 UPGRADE_TEXT/UPGRADE_LOAD/TEXT/LOAD 四个占位符。
const std = @import("std");

pub const Error = error{
    MissingConfig,
    BadNumber,
    Underflow,
};

/// 从 `.config` 文本中取 `KEY=value` 的原始值（去掉行尾空白）。
pub fn configValue(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, k, key)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

fn parseHex(text: []const u8, key: []const u8) !u64 {
    const v = configValue(text, key) orelse return Error.MissingConfig;
    return std.fmt.parseInt(u64, v, 0) catch Error.BadNumber;
}

fn heapBase(config: []const u8) !u64 {
    const heap = try parseHex(config, "CONFIG_AIC_BOOTLOADER_HEAP_SIZE");

    const candidates = [_]struct { size_key: []const u8, base_key: []const u8 }{
        .{ .size_key = "CONFIG_AIC_PSRAM_SIZE", .base_key = "CONFIG_CPU_PSRAM_BASE" },
        .{ .size_key = "CONFIG_AIC_DRAM_TOTAL_SIZE", .base_key = "CONFIG_CPU_DRAM_BASE" },
        .{ .size_key = "CONFIG_AIC_SRAM_TOTAL_SIZE", .base_key = "CONFIG_CPU_SRAM_BASE" },
        .{ .size_key = "CONFIG_AIC_SRAM_SIZE", .base_key = "CONFIG_CPU_SRAM_BASE" },
    };
    for (candidates) |c| {
        const size = parseHex(config, c.size_key) catch continue;
        if (size == 0) continue;
        const base = try parseHex(config, c.base_key);
        if (base + size < heap) return Error.Underflow;
        return base + size - heap;
    }
    return Error.MissingConfig;
}

/// 计算 (TEXT_BASE, LOAD_BASE)。
pub fn calculate(config: []const u8) !struct { text: u64, load: u64 } {
    const auto = configValue(config, "CONFIG_AIC_BOOTLOADER_MEM_AUTO");
    const text: u64 = if (auto != null and std.mem.eql(u8, auto.?, "y")) blk: {
        const heap = try heapBase(config);
        const text_size = try parseHex(config, "CONFIG_AIC_BOOTLOADER_TEXT_SIZE");
        if (heap < text_size) return Error.Underflow;
        break :blk heap - text_size;
    } else try parseHex(config, "CONFIG_AIC_BOOTLOADER_TEXT_BASE");

    if (text < 0x100) return Error.Underflow;
    return .{ .text = text, .load = text - 0x100 };
}

fn replaceAll(a: std.mem.Allocator, input: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (std.mem.find(u8, input[i..], needle)) |rel| {
        const at = i + rel;
        try out.appendSlice(a, input[i..at]);
        try out.appendSlice(a, repl);
        i = at + needle.len;
    }
    try out.appendSlice(a, input[i..]);
    return out.toOwnedSlice(a);
}

/// 按参考脚本顺序替换 4 个占位符（UPGRADE_* 在前，避免短名先命中）。
pub fn rewrite(a: std.mem.Allocator, config: []const u8, image_cfg: []const u8) ![]u8 {
    const v = try calculate(config);
    const text = try std.fmt.allocPrint(a, "0x{x}", .{v.text});
    defer a.free(text);
    const load = try std.fmt.allocPrint(a, "0x{x}", .{v.load});
    defer a.free(load);

    const replacements = [_]struct { needle: []const u8, value: []const u8 }{
        .{ .needle = "CONFIG_AIC_BOOTLOADER_UPGRADE_TEXT_BASE", .value = text },
        .{ .needle = "CONFIG_AIC_BOOTLOADER_UPGRADE_LOAD_BASE", .value = load },
        .{ .needle = "CONFIG_AIC_BOOTLOADER_TEXT_BASE", .value = text },
        .{ .needle = "CONFIG_AIC_BOOTLOADER_LOAD_BASE", .value = load },
    };

    var current = try a.dupe(u8, image_cfg);
    errdefer a.free(current);
    for (replacements) |r| {
        const next = try replaceAll(a, current, r.needle, r.value);
        a.free(current);
        current = next;
    }
    return current;
}

test "linkaddr：MEM_AUTO 计算 text/load" {
    const config =
        \\CONFIG_AIC_BOOTLOADER_MEM_AUTO=y
        \\CONFIG_AIC_PSRAM_SIZE=0x100000
        \\CONFIG_CPU_PSRAM_BASE=0x40000000
        \\CONFIG_AIC_BOOTLOADER_HEAP_SIZE=0x1000
        \\CONFIG_AIC_BOOTLOADER_TEXT_SIZE=0x10000
    ;
    const v = try calculate(config);
    try std.testing.expectEqual(@as(u64, 0x400EF000), v.text);
    try std.testing.expectEqual(@as(u64, 0x400EEF00), v.load);
}

test "linkaddr：显式 TEXT_BASE 与占位符替换" {
    const a = std.testing.allocator;
    const config =
        \\CONFIG_AIC_BOOTLOADER_MEM_AUTO=n
        \\CONFIG_AIC_BOOTLOADER_TEXT_BASE=0x41000000
    ;
    const cfg = "text=CONFIG_AIC_BOOTLOADER_TEXT_BASE load=CONFIG_AIC_BOOTLOADER_LOAD_BASE up=CONFIG_AIC_BOOTLOADER_UPGRADE_TEXT_BASE";
    const out = try rewrite(a, config, cfg);
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "text=0x41000000") != null);
    try std.testing.expect(std.mem.find(u8, out, "load=0x40ffff00") != null);
    try std.testing.expect(std.mem.find(u8, out, "up=0x41000000") != null);
}
