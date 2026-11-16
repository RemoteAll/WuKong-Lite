//! msh 风格命令解释器 —— 对应 RT-Thread `finsh/msh` 的最小实现：
//! 命令注册表、按空白分词、逐行执行、交互式提示符。
const std = @import("std");
const osal = @import("../kernel/common/osal.zig");
const device = @import("../kernel/common/device.zig");
const heap = @import("../kernel/common/heap.zig");
const gpio_drv = @import("../bsp/artinchip/drv/gpio.zig");

pub const Command = struct {
    name: []const u8,
    usage: []const u8,
    desc: []const u8,
    run: *const fn (shell: *Shell, args: []const []const u8, out: *std.Io.Writer) anyerror!void,
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    kernel: *osal.Kernel,
    devices: *device.Registry,
    heap: *heap.Counting,
    gpio: ?*gpio_drv.Gpio = null,
    commands: []const Command = &.{},
    prompt: []const u8 = "msh /> ",

    /// 执行一行命令；返回 false 表示空行。
    pub fn exec(self: *Shell, line: []const u8, out: *std.Io.Writer) !bool {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(self.allocator);

        var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
        while (it.next()) |tok| try tokens.append(self.allocator, tok);
        if (tokens.items.len == 0) return false;

        const name = tokens.items[0];
        for (self.commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) {
                try cmd.run(self, tokens.items, out);
                return true;
            }
        }
        try out.print("-sh: command not found: {s}\n", .{name});
        try out.writeAll("type 'help' to list commands\n");
        return true;
    }

    /// 交互式 shell：从 stdin 读行，直到 `exit` / `quit` / EOF。
    pub fn run(self: *Shell, out: *std.Io.Writer) !void {
        var in_buf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(self.io, &in_buf);
        const in = &reader.interface;

        while (true) {
            try out.writeAll(self.prompt);
            try out.flush();

            const line = in.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                error.StreamTooLong => {
                    try out.writeAll("error: line too long\n");
                    continue;
                },
                else => return err,
            };

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) break;
            if (std.mem.eql(u8, trimmed, "clear")) {
                try out.writeAll("\x1b[2J\x1b[H");
                continue;
            }
            _ = self.exec(trimmed, out) catch |err| {
                try out.print("error: {s}\n", .{@errorName(err)});
            };
            try out.flush();
        }
    }
};

test "shell 分词与未知命令" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var kernel = osal.Kernel.init(std.testing.allocator, io);
    defer kernel.deinit();
    var registry = device.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var counting = heap.Counting.init(std.testing.allocator);

    var shell = Shell{
        .allocator = std.testing.allocator,
        .io = io,
        .kernel = &kernel,
        .devices = &registry,
        .heap = &counting,
        .commands = &.{},
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.testing.expect(!(try shell.exec("   ", &aw.writer)));
    try std.testing.expect(try shell.exec("nope a b", &aw.writer));
    try std.testing.expect(std.mem.find(u8, aw.written(), "command not found: nope") != null);
}
