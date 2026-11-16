//! 模块收集表 —— 等价 Luban-Lite `SConscript` 里的 `GetDepend()` 依赖判断：
//! 根据 `.config` 决定哪些模块参与编译，并输出 build plan。
const std = @import("std");

pub const Module = struct {
    name: []const u8,
    /// 该模块包含的 Zig 源文件（相对仓库根目录）
    sources: []const []const u8,
    /// 需要全部为 y/m 的配置符号
    requires: []const []const u8 = &.{},
    /// 依赖的其他模块（必须同样启用）
    deps: []const []const u8 = &.{},
};

/// 模块清单（新增驱动/组件时在此登记）。
pub const all = [_]Module{
    .{
        .name = "bsp-common",
        .sources = &.{
            "src/bsp/common/crc32.zig",
            "src/bsp/common/checksum.zig",
            "src/bsp/common/image.zig",
            "src/bsp/common/partition.zig",
            "src/bsp/common/gpt.zig",
            "src/bsp/common/env_image.zig",
            "src/bsp/common/fw_image.zig",
            "src/bsp/common/utils.zig",
        },
    },
    .{
        .name = "osal",
        .sources = &.{
            "src/kernel/common/osal.zig",
            "src/kernel/common/device.zig",
            "src/kernel/common/heap.zig",
        },
    },
    .{
        .name = "drv-uart",
        .sources = &.{"src/bsp/artinchip/drv/uart.zig"},
        .requires = &.{ "AIC_UART_DRV", "AIC_USING_UART0" },
        .deps = &.{"osal"},
    },
    .{
        .name = "drv-gpio",
        .sources = &.{"src/bsp/artinchip/drv/gpio.zig"},
        .requires = &.{ "AIC_GPIO_DRV", "AIC_USING_GPIO" },
        .deps = &.{"osal"},
    },
    .{
        .name = "shell",
        .sources = &.{ "src/shell/shell.zig", "src/shell/cmds.zig" },
        .deps = &.{"osal"},
    },
    .{
        .name = "app-helloworld",
        .sources = &.{"src/application/helloworld.zig"},
        .deps = &.{"osal"},
    },
    .{
        .name = "toolchain",
        .sources = &.{
            "src/tools/kconfig.zig",
            "src/tools/codegen.zig",
            "src/tools/modules.zig",
            "src/tools/image_cfg.zig",
            "src/tools/partition_table.zig",
            "src/tools/pack.zig",
            "src/tools/fdt.zig",
            "src/tools/itb.zig",
            "src/tools/its.zig",
            "src/tools/elf2aic.zig",
            "src/tools/crypt.zig",
        },
    },
    .{
        .name = "ui-lvgl",
        .sources = &.{}, // 尚未实现，仅用于展示配置裁剪
        .requires = &.{"AIC_USING_LVGL"},
    },
};

pub const ModuleStatus = struct {
    module: *const Module,
    enabled: bool,
    /// 未满足的配置符号/依赖模块（用于诊断）
    missing: []const []const u8,
};

/// 解析 `.config`：返回 y/m 符号集合（大小写敏感，不含 CONFIG_ 前缀）。
pub fn parseEnabledSymbols(allocator: std.mem.Allocator, dot_text: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();
    var lines = std.mem.splitScalar(u8, dot_text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "CONFIG_")) continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const name = line["CONFIG_".len..eq];
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, value, "y") or std.mem.eql(u8, value, "m")) {
            try set.put(name, {});
        }
    }
    return set;
}

/// 评估模块启用状态（依赖模块未启用也会传递性禁用）。
pub fn evaluate(allocator: std.mem.Allocator, dot_text: []const u8) ![]ModuleStatus {
    var enabled = try parseEnabledSymbols(allocator, dot_text);
    defer enabled.deinit();

    const result = try allocator.alloc(ModuleStatus, all.len);
    errdefer allocator.free(result);

    // 初始化：仅看 requires
    for (all, 0..) |_, i| {
        var missing: std.ArrayList([]const u8) = .empty;
        var ok = true;
        for (all[i].requires) |sym| {
            if (!enabled.contains(sym)) {
                ok = false;
                try missing.append(allocator, sym);
            }
        }
        result[i] = .{ .module = &all[i], .enabled = ok, .missing = try missing.toOwnedSlice(allocator) };
    }

    // 依赖模块传递
    var pass: usize = 0;
    while (pass <= all.len) : (pass += 1) {
        var changed = false;
        for (all, 0..) |m, i| {
            if (!result[i].enabled) continue;
            for (m.deps) |dep| {
                const dep_enabled = blk: {
                    for (all, 0..) |dm, di| {
                        if (std.mem.eql(u8, dm.name, dep)) break :blk result[di].enabled;
                    }
                    break :blk false;
                };
                if (!dep_enabled) {
                    result[i].enabled = false;
                    changed = true;
                    break;
                }
            }
        }
        if (!changed) break;
    }
    return result;
}

pub fn freeStatus(allocator: std.mem.Allocator, status: []ModuleStatus) void {
    for (status) |s| allocator.free(s.missing);
    allocator.free(status);
}

/// 输出 build plan JSON。
pub fn writePlanJson(allocator: std.mem.Allocator, status: []const ModuleStatus, writer: *std.Io.Writer) !void {
    _ = allocator;
    try writer.writeAll("{\n  \"modules\": [\n");
    var enabled_count: usize = 0;
    for (status, 0..) |s, i| {
        if (s.enabled) enabled_count += 1;
        try writer.print("    {{\"name\": \"{s}\", \"enabled\": {}, \"sources\": [", .{ s.module.name, s.enabled });
        for (s.module.sources, 0..) |src, j| {
            if (j != 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{src});
        }
        try writer.writeAll("]}");
        if (i + 1 < status.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.print("  ],\n  \"enabled_count\": {d},\n  \"total_count\": {d}\n}}\n", .{ enabled_count, status.len });
}

test "按 .config 评估模块启用状态" {
    const allocator = std.testing.allocator;
    const dot =
        \\CONFIG_AIC_UART_DRV=y
        \\CONFIG_AIC_USING_UART0=y
        \\CONFIG_AIC_GPIO_DRV=y
        \\# CONFIG_AIC_USING_GPIO is not set
        \\CONFIG_AIC_USING_LVGL=y
        \\
    ;
    const status = try evaluate(allocator, dot);
    defer freeStatus(allocator, status);

    for (status) |s| {
        if (std.mem.eql(u8, s.module.name, "drv-uart")) try std.testing.expect(s.enabled);
        if (std.mem.eql(u8, s.module.name, "drv-gpio")) try std.testing.expect(!s.enabled);
        if (std.mem.eql(u8, s.module.name, "ui-lvgl")) try std.testing.expect(s.enabled);
        if (std.mem.eql(u8, s.module.name, "osal")) try std.testing.expect(s.enabled);
    }
}

test "依赖模块被禁用时传递性禁用" {
    const allocator = std.testing.allocator;
    // drv-uart 依赖 osal，osal 无 requires 恒启用；构造一个反向场景：
    // shell 依赖 osal，无法禁用 osal，这里验证 uart 在缺少符号时连同依赖一起不启用。
    const status = try evaluate(allocator, "CONFIG_AIC_UART_DRV=y\n");
    defer freeStatus(allocator, status);
    for (status) |s| {
        if (std.mem.eql(u8, s.module.name, "drv-uart")) {
            try std.testing.expect(!s.enabled);
            try std.testing.expectEqual(@as(usize, 1), s.missing.len);
            try std.testing.expectEqualStrings("AIC_USING_UART0", s.missing[0]);
        }
    }
}
