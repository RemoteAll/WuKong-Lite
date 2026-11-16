//! 内置命令集（对应 RT-Thread msh 常用命令的 host 版）。
const std = @import("std");
const shell_mod = @import("shell.zig");
const partition = @import("../bsp/common/partition.zig");

const Shell = shell_mod.Shell;

fn help(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = args;
    try out.writeAll("WuKong-Lite shell commands:\n");
    try out.print("{s:<16} {s}\n", .{ "Command", "Description" });
    try out.writeAll("--------------------------------------------------\n");
    for (shell.commands) |cmd| {
        try out.print("{s:<16} {s}\n", .{ cmd.name, cmd.desc });
        if (cmd.usage.len > 0) try out.print("{s:<16}   usage: {s}\n", .{ "", cmd.usage });
    }
}

fn version(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = shell;
    _ = args;
    const builtin = @import("builtin");
    try out.print("WuKong-Lite 0.1.0 (Zig {s}, {s})\n", .{
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    try out.writeAll("Luban-Lite compatible SDK reimplementation\n");
}

fn uptime(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = args;
    const ms = shell.kernel.ticks();
    try out.print("uptime: {d}.{d:0>3}s ({d} ticks)\n", .{ ms / 1000, ms % 1000, ms });
}

fn ps(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = args;
    const threads = try shell.kernel.threadSnapshot(shell.allocator);
    defer shell.allocator.free(threads);
    try out.print("{s:<6} {s:<20} {s}\n", .{ "TID", "Name", "State" });
    try out.writeAll("----------------------------------------\n");
    for (threads) |t| {
        try out.print("{d:<6} {s:<20} {s}\n", .{ t.id, t.name, if (t.running) "running" else "finished" });
    }
}

fn free(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = args;
    const used = shell.heap.usedBytes();
    const peak = shell.heap.peakBytes();
    try out.print("heap used  : {d} bytes\n", .{used});
    try out.print("heap peak  : {d} bytes\n", .{peak});
    try out.print("alloc calls: {d}\n", .{shell.heap.allocCount()});
    try out.print("free calls : {d}\n", .{shell.heap.freeCount()});
}

fn date(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = args;
    const now = std.Io.Timestamp.now(shell.io, .real);
    const seconds = now.toSeconds();
    if (seconds < 0) {
        try out.print("epoch {d}s\n", .{seconds});
        return;
    }
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try out.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC\n", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

fn listDevice(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = args;
    try shell.devices.dump(out);
}

fn part(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len < 2) {
        try out.writeAll("usage: part <MTD=spi0.0:512k(spl),-(data)>\n");
        return;
    }
    const parts = try partition.parseMtd(shell.allocator, args[1]);
    defer shell.allocator.free(parts);
    try partition.dump(out, parts);
}

fn gpio(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    const g = shell.gpio orelse {
        try out.writeAll("gpio0 not registered\n");
        return;
    };
    if (args.len >= 4 and std.mem.eql(u8, args[1], "write")) {
        const pin = try std.fmt.parseInt(u32, args[2], 0);
        const value = try std.fmt.parseInt(u32, args[3], 0);
        try g.set(pin, value != 0);
        try out.print("gpio{d} = {d}\n", .{ pin, value });
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "read")) {
        const pin = try std.fmt.parseInt(u32, args[2], 0);
        const value = try g.get(pin);
        try out.print("gpio{d} = {d}\n", .{ pin, @intFromBool(value) });
    } else {
        try out.writeAll("usage: gpio write <pin> <0|1>\n       gpio read <pin>\n");
    }
}

fn reboot(shell: *Shell, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = shell;
    _ = args;
    try out.writeAll("reboot: simulated on host, session keeps running\n");
}

pub const default_commands = [_]shell_mod.Command{
    .{ .name = "help", .usage = "help", .desc = "列出所有命令", .run = help },
    .{ .name = "version", .usage = "version", .desc = "版本信息", .run = version },
    .{ .name = "uptime", .usage = "uptime", .desc = "系统节拍", .run = uptime },
    .{ .name = "ps", .usage = "ps", .desc = "线程列表", .run = ps },
    .{ .name = "free", .usage = "free", .desc = "堆使用统计", .run = free },
    .{ .name = "date", .usage = "date", .desc = "当前 UTC 时间", .run = date },
    .{ .name = "list_device", .usage = "list_device", .desc = "已注册设备", .run = listDevice },
    .{ .name = "part", .usage = "part <MTD=...>", .desc = "解析并打印分区表", .run = part },
    .{ .name = "gpio", .usage = "gpio write|read <pin> [0|1]", .desc = "GPIO 读写", .run = gpio },
    .{ .name = "reboot", .usage = "reboot", .desc = "重启（模拟）", .run = reboot },
};
