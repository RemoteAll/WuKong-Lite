//! WuKong-Lite 命令行入口（等价 Luban-Lite 的 `scons` + `tools/scripts/*` 工具集）。
//!
//! 子命令：
//!   wk defconfig <方案> | --list     应用 defconfig，生成 .config / cconfig.h
//!   wk config list|get|set           查看/修改 .config（并同步 cconfig.h）
//!   wk image part|env|aic|pack|pagetable|dump
//!   wk shell [-c "cmd"]              msh 风格命令行（uart0/gpio0 模拟设备）
//!   wk run hello                     HelloWorld 示例（线程 + 邮箱 + 信号量）
//!   wk demo                          端到端演示：配置 → 打包 → 解析
const std = @import("std");
const aic = @import("aic.zig");
const kconfig = aic.kconfig;
const image_cfg = aic.image_cfg;
const partition_table = aic.partition_table;
const pack = aic.pack;
const itb = aic.itb;
const its = aic.its;
const elf2aic = aic.elf2aic;
const crypt = aic.crypt;
const fdt_reader = aic.fdt_reader;
const fat = aic.fat;
const rsa = aic.rsa;
const sparse = aic.sparse;
const cpio = aic.cpio;
const fw_image = aic.fw_image;
const image = aic.image;
const env_image = aic.env_image;
const partition = aic.partition;
const utils = aic.utils;
const codegen = aic.codegen;
const modules = aic.modules;
const board_config = @import("generated/config.zig");

const osal = @import("kernel/common/osal.zig");
const device = @import("kernel/common/device.zig");
const heapmod = @import("kernel/common/heap.zig");
const uart_drv = @import("bsp/artinchip/drv/uart.zig");
const gpio_drv = @import("bsp/artinchip/drv/gpio.zig");
const shell_mod = @import("shell/shell.zig");
const cmds = @import("shell/cmds.zig");
const helloworld = @import("application/helloworld.zig");

const CONFIG_DIR = "wk/config";
const IMAGE_DIR = "wk/image";
const KCONFIG_ROOT = "wk/Kconfig";
const CONFIG_PLANS = "wk/target/configs";
const GENERATED_CONFIG = "src/generated/config.zig";
const BUILD_PLAN = "wk/config/build_plan.json";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (args_it.next()) |arg| {
        try argv.append(gpa, try aa.dupe(u8, arg));
    }

    const stdout = std.Io.File.stdout();
    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = stdout.writer(io, &out_buf);
    const out = &out_writer.interface;

    const result = dispatch(io, aa, argv.items, out);
    result catch |err| {
        try out.flush();
        std.debug.print("wk: error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    try out.flush();
}

fn dispatch(io: std.Io, aa: std.mem.Allocator, argv: []const []const u8, out: *std.Io.Writer) !void {
    if (argv.len < 2) {
        try usage(out);
        return;
    }
    const cmd = argv[1];
    const rest = argv[2..];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try usage(out);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try cmdVersion(out);
    } else if (std.mem.eql(u8, cmd, "defconfig")) {
        try cmdDefconfig(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "config")) {
        try cmdConfig(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "build")) {
        try cmdBuild(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "image")) {
        try cmdImage(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "shell")) {
        try cmdShell(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try cmdRun(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "demo")) {
        try cmdDemo(io, aa, out);
    } else {
        try out.print("wk: unknown command: {s}\n", .{cmd});
        try usage(out);
        return error.UnknownCommand;
    }
}

fn usage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\WuKong-Lite 0.1.0 — Luban-Lite 兼容 SDK（Zig 实现）
        \\
        \\用法: wk <command> [args]
        \\
        \\  defconfig <方案> | --list   应用 target/configs 下的方案，生成 wk/config/.config
        \\  config list                打印 .config
        \\  config get <SYMBOL>        查询配置项
        \\  config set <SYMBOL> <值>   修改配置项并同步 cconfig.h
        \\  build                      按 .config 生成 config.zig 与编译计划（等价 SConscript）
        \\
        \\  image part --config <json> [--out header.h] [--json parts.json]
        \\  image env  (--config <json> | --input env.txt --size 4096) [--redundant] [-o env.bin]
        \\  image aic  --input <bin> [--load 0x...] [--entry 0x...] [-o out.aic]
        \\  image elf2aic --input <elf> [--head-ver 0x...] [-o out.aic]
        \\  image elf2its --input <elf> [--version 1.0.0] [--hash crc32,md5|--no-hash] [-o out_os.its]
        \\  image pack --config <json> [--datadir <dir>] [-o out.img]
        \\  image itb --kernel <bin> [--fdt <dtb>] [--ramdisk <bin>] [--load 0x...] [--entry 0x...] [-o out.itb]
        \\            或 --its <xxx.its> [--timestamp <u32>] [-o out.itb]
        \\  image pagetable --input <spl.bin> [--page 2] [--block 128] [--planes 1] [-o page.bin]
        \\  image crypt --input <bin> --key <32hex> --iv <32hex> [--decrypt] [--pad zero|pkcs7] [-o out.bin]
        \\  image fitinfo --input <itb> [--dump] [--verify]
        \\  image fat --input-dir <dir> --output <img> --size <bytes> [--sector 512] [--cluster 8] [--label NAME]
        \\          （--auto 可省略 --size，按内容估算，等价 makefatfs.py -a）
        \\  image rsasign --input <file> --key <priv.pem> [-o sig.bin]
        \\  image rsaverify --input <file> --key <pub.pem> --sig <sig.bin>
        \\  image simg --input <raw> [--output <sparse>] [--block 4096] [--unsparse]
        \\  image cpio --list <file> --input-dir <dir> -o <ota.cpio> [--format crc|newc] [--mtime 0]
        \\  image dump <file>
        \\
        \\  shell [-c "cmd"]            交互式 msh（uart0 / gpio0 模拟设备）
        \\  run hello                   HelloWorld 示例
        \\  demo                        端到端演示（配置 → 打包 → 解析）
        \\
    );
}

fn cmdVersion(out: *std.Io.Writer) !void {
    const builtin = @import("builtin");
    try out.print("WuKong-Lite 0.1.0 (Zig {s}, {s})\n", .{ builtin.zig_version_string, @tagName(builtin.mode) });
    try out.print("当前方案: {s} ({s}/{s}/{s}/{s})\n", .{
        board_config.PRJ_DEFCONFIG_FILENAME,
        board_config.PRJ_CHIP,
        board_config.PRJ_BOARD,
        board_config.PRJ_KERNEL,
        board_config.PRJ_APP,
    });
    try out.writeAll("兼容目标: Luban-Lite 2.0（ArtInChip D13x/D12x/D21x 等 SoC 的 SDK 结构）\n");
}

// ---------------------------------------------------------------------------
// 配置相关
// ---------------------------------------------------------------------------

fn cmdDefconfig(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len == 0) {
        try out.writeAll("usage: wk defconfig <方案名> | --list\n");
        return error.MissingArgument;
    }
    if (std.mem.eql(u8, args[0], "--list") or std.mem.eql(u8, args[0], "list")) {
        var dir = try std.Io.Dir.cwd().openDir(io, CONFIG_PLANS, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        try out.writeAll("可用方案:\n");
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, "_defconfig")) continue;
            const name = entry.name[0 .. entry.name.len - "_defconfig".len];
            try out.print("  {s}\n", .{name});
        }
        return;
    }

    const plan = args[0];
    const file_name = if (std.mem.endsWith(u8, plan, "_defconfig"))
        try aa.dupe(u8, plan)
    else
        try std.fmt.allocPrint(aa, "{s}_defconfig", .{plan});
    const plan_path = try std.fs.path.join(aa, &.{ CONFIG_PLANS, file_name });

    const plan_text = std.Io.Dir.cwd().readFileAlloc(io, plan_path, aa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("wk: 方案不存在: {s}\n", .{plan_path});
            try out.writeAll("可用方案请执行: wk defconfig --list\n");
            return error.PlanNotFound;
        },
        else => return err,
    };

    var cfg = try kconfig.load(aa, io, KCONFIG_ROOT);
    defer cfg.deinit();
    try cfg.applyDefconfig(plan_text);
    cfg.resolve();

    try std.Io.Dir.cwd().createDirPath(io, CONFIG_DIR);

    var dot: std.Io.Writer.Allocating = .init(aa);
    defer dot.deinit();
    try cfg.writeDotConfig(&dot.writer);
    const dot_path = try std.fs.path.join(aa, &.{ CONFIG_DIR, ".config" });
    try writeText(io, dot_path, dot.written());

    var hdr: std.Io.Writer.Allocating = .init(aa);
    defer hdr.deinit();
    try cfg.writeHeader(&hdr.writer);
    const hdr_path = try std.fs.path.join(aa, &.{ CONFIG_DIR, "cconfig.h" });
    try writeText(io, hdr_path, hdr.written());

    const prj_name = try projectName(aa, &cfg, file_name);
    var info: std.Io.Writer.Allocating = .init(aa);
    defer info.deinit();
    try info.writer.writeAll("{\n");
    try writeJsonField(&info.writer, "defconfig", file_name, true);
    try writeJsonField(&info.writer, "project", prj_name, true);
    try writeJsonField(&info.writer, "chip", cfg.get("PRJ_CHIP") orelse "unknown", true);
    try writeJsonField(&info.writer, "board", cfg.get("PRJ_BOARD") orelse "unknown", true);
    try writeJsonField(&info.writer, "kernel", cfg.get("PRJ_KERNEL") orelse "unknown", true);
    try writeJsonField(&info.writer, "app", cfg.get("PRJ_APP") orelse "unknown", false);
    try info.writer.writeAll("}\n");
    const info_path = try std.fs.path.join(aa, &.{ CONFIG_DIR, "build_info.json" });
    try writeText(io, info_path, info.written());

    // 生成 src/generated/config.zig 与编译计划（等价 SConscript 模块收集）
    const cfg_zig_path = try writeGeneratedConfig(io, aa, &cfg, dot.written());

    try out.print("已应用方案: {s}\n", .{file_name});
    try out.print("  {s}\n  {s}\n  {s}\n  {s}\n  {s}\n", .{ dot_path, hdr_path, info_path, cfg_zig_path, BUILD_PLAN });
    try out.print("工程: {s} (chip={s} board={s} kernel={s} app={s})\n", .{
        prj_name,
        cfg.get("PRJ_CHIP") orelse "?",
        cfg.get("PRJ_BOARD") orelse "?",
        cfg.get("PRJ_KERNEL") orelse "?",
        cfg.get("PRJ_APP") orelse "?",
    });
}

fn projectName(aa: std.mem.Allocator, cfg: *kconfig.Config, defconfig_name: []const u8) ![]const u8 {
    if (cfg.get("PRJ_CHIP")) |chip| {
        if (cfg.get("PRJ_BOARD")) |board| {
            if (cfg.get("PRJ_KERNEL")) |kernel| {
                if (cfg.get("PRJ_APP")) |app| {
                    return std.fmt.allocPrint(aa, "{s}_{s}_{s}_{s}", .{ chip, board, kernel, app });
                }
            }
        }
    }
    const base = defconfig_name[0 .. defconfig_name.len - "_defconfig".len];
    return aa.dupe(u8, base);
}

fn writeJsonField(w: *std.Io.Writer, key: []const u8, value: []const u8, comma: bool) !void {
    try w.print("  \"{s}\": \"{s}\"{s}\n", .{ key, value, if (comma) "," else "" });
}

fn cmdConfig(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    const dot_path = try std.fs.path.join(aa, &.{ CONFIG_DIR, ".config" });
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        const text = try readText(io, aa, dot_path);
        try out.writeAll(text);
        return;
    }
    if (std.mem.eql(u8, args[0], "get")) {
        if (args.len < 2) return error.MissingArgument;
        const text = try readText(io, aa, dot_path);
        const value = dotConfigGet(text, args[1]);
        if (value) |v| {
            try out.print("{s}\n", .{v});
        } else {
            try out.writeAll("n\n");
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len < 3) return error.MissingArgument;
        const text = try readText(io, aa, dot_path);
        const updated = try dotConfigSet(aa, text, args[1], args[2]);
        defer aa.free(updated);
        try writeText(io, dot_path, updated);

        var hdr: std.Io.Writer.Allocating = .init(aa);
        defer hdr.deinit();
        try writeCconfigFromDot(&hdr.writer, updated);
        const hdr_path = try std.fs.path.join(aa, &.{ CONFIG_DIR, "cconfig.h" });
        try writeText(io, hdr_path, hdr.written());

        const cfg_zig_path = try writeGeneratedConfigFromDot(io, aa, updated);

        try out.print("CONFIG_{s}={s}\n", .{ normalizeSymbol(args[1]), args[2] });
        try out.print("已更新 {s}、{s} 与 {s}\n", .{ dot_path, hdr_path, cfg_zig_path });
        return;
    }
    try out.writeAll("usage: wk config list|get <SYMBOL>|set <SYMBOL> <值>\n");
}

/// 根据当前 `.config` 生成 `src/generated/config.zig` 与 `build_plan.json`（返回生成文件路径）。
fn writeGeneratedConfigFromDot(io: std.Io, aa: std.mem.Allocator, dot_text: []const u8) ![]const u8 {
    var zig: std.Io.Writer.Allocating = .init(aa);
    defer zig.deinit();
    try codegen.generateFromDot(&zig.writer, dot_text);
    try writeText(io, GENERATED_CONFIG, zig.written());

    try writeBuildPlan(io, aa, dot_text);
    return GENERATED_CONFIG;
}

/// 从带类型信息的 Kconfig 配置直接生成（defconfig 路径）。
fn writeGeneratedConfig(io: std.Io, aa: std.mem.Allocator, cfg: *kconfig.Config, dot_text: []const u8) ![]const u8 {
    var zig: std.Io.Writer.Allocating = .init(aa);
    defer zig.deinit();
    try codegen.generate(cfg, &zig.writer);
    try writeText(io, GENERATED_CONFIG, zig.written());

    try writeBuildPlan(io, aa, dot_text);
    return GENERATED_CONFIG;
}

fn writeBuildPlan(io: std.Io, aa: std.mem.Allocator, dot_text: []const u8) !void {
    const status = try modules.evaluate(aa, dot_text);
    defer modules.freeStatus(aa, status);

    var plan: std.Io.Writer.Allocating = .init(aa);
    defer plan.deinit();
    try modules.writePlanJson(aa, status, &plan.writer);
    try writeText(io, BUILD_PLAN, plan.written());
}

fn cmdBuild(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    _ = args;
    const dot_path = try std.fs.path.join(aa, &.{ CONFIG_DIR, ".config" });
    const dot_text = std.Io.Dir.cwd().readFileAlloc(io, dot_path, aa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try out.writeAll("wk: 尚未生成 .config，请先执行 wk defconfig <方案>\n");
            return error.ConfigMissing;
        },
        else => return err,
    };

    _ = try writeGeneratedConfigFromDot(io, aa, dot_text);

    const status = try modules.evaluate(aa, dot_text);
    defer modules.freeStatus(aa, status);

    try out.print("{s:<8} {s:<18} {s}\n", .{ "Enable", "Module", "Sources" });
    try out.writeAll("------------------------------------------------------------\n");
    var enabled_count: usize = 0;
    for (status) |s| {
        if (s.enabled) enabled_count += 1;
        try out.print("[{s}]      {s:<18} {d}\n", .{
            if (s.enabled) "x" else " ",
            s.module.name,
            s.module.sources.len,
        });
        if (!s.enabled and s.missing.len > 0) {
            try out.writeAll("           missing: ");
            for (s.missing, 0..) |m, i| {
                if (i != 0) try out.writeAll(", ");
                try out.writeAll(m);
            }
            try out.writeByte('\n');
        }
    }
    try out.print("\n模块: {d}/{d} 启用\n", .{ enabled_count, status.len });
    try out.print("已生成 {s} 与 {s}\n", .{ GENERATED_CONFIG, BUILD_PLAN });
    try out.writeAll("下一步: zig build （Zig 会按 config.zig 的常量裁剪注册逻辑）\n");
}

fn normalizeSymbol(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "CONFIG_")) name["CONFIG_".len..] else name;
}

fn dotConfigGet(text: []const u8, symbol: []const u8) ?[]const u8 {
    const sym = normalizeSymbol(symbol);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "CONFIG_")) {
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, line["CONFIG_".len..eq], sym)) {
                var v = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
                if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
                return v;
            }
        }
    }
    return null;
}

fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn looksNumeric(value: []const u8) bool {
    if (std.fmt.parseInt(u64, value, 0)) |_| return true else |_| {}
    _ = std.fmt.parseInt(i64, value, 0) catch return false;
    return true;
}

fn dotConfigSet(aa: std.mem.Allocator, text: []const u8, symbol_in: []const u8, value: []const u8) ![]u8 {
    const sym = normalizeSymbol(symbol_in);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(aa);

    var found = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const is_entry = std.mem.startsWith(u8, line, "CONFIG_");
        const is_unset = std.mem.startsWith(u8, line, "# CONFIG_") and std.mem.endsWith(u8, line, " is not set");
        if (is_entry) {
            const eq = std.mem.findScalar(u8, line, '=') orelse {
                try out.appendSlice(aa, line);
                try out.append(aa, '\n');
                continue;
            };
            if (std.mem.eql(u8, line["CONFIG_".len..eq], sym)) {
                found = true;
                const old_value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
                const was_string = old_value.len >= 2 and old_value[0] == '"';
                if (std.mem.eql(u8, value, "y") or std.mem.eql(u8, value, "m") or std.mem.eql(u8, value, "n")) {
                    if (std.mem.eql(u8, value, "n")) {
                        try appendFmt(&out, aa, "# CONFIG_{s} is not set\n", .{sym});
                    } else {
                        try appendFmt(&out, aa, "CONFIG_{s}={s}\n", .{ sym, value });
                    }
                } else if (!was_string and looksNumeric(value)) {
                    try appendFmt(&out, aa, "CONFIG_{s}={s}\n", .{ sym, value });
                } else {
                    try appendFmt(&out, aa, "CONFIG_{s}=\"{s}\"\n", .{ sym, value });
                }
                continue;
            }
        } else if (is_unset) {
            const inner = line["# CONFIG_".len .. line.len - " is not set".len];
            if (std.mem.eql(u8, inner, sym)) {
                found = true;
                if (std.mem.eql(u8, value, "y") or std.mem.eql(u8, value, "m")) {
                    try appendFmt(&out, aa, "CONFIG_{s}={s}\n", .{ sym, value });
                } else {
                    try out.appendSlice(aa, line);
                    try out.append(aa, '\n');
                }
                continue;
            }
        }
        try out.appendSlice(aa, line);
        try out.append(aa, '\n');
    }
    if (!found) {
        try appendFmt(&out, aa, "CONFIG_{s}={s}\n", .{ sym, value });
    }
    return out.toOwnedSlice(aa);
}

fn writeCconfigFromDot(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("/*\n * Automatically generated file; DO NOT EDIT.\n * WuKong-Lite configuration header\n */\n");
    try w.writeAll("#ifndef _WUKONG_CCONFIG_H_\n#define _WUKONG_CCONFIG_H_\n\n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "CONFIG_")) {
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            const name = line["CONFIG_".len..eq];
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            if (std.mem.eql(u8, value, "y")) {
                try w.print("#define CONFIG_{s} 1\n", .{name});
            } else if (std.mem.eql(u8, value, "m")) {
                try w.print("#define CONFIG_{s} 2\n", .{name});
            } else if (std.mem.startsWith(u8, value, "\"")) {
                try w.print("#define CONFIG_{s} {s}\n", .{ name, value });
            } else {
                try w.print("#define CONFIG_{s} {s}\n", .{ name, value });
            }
        } else if (std.mem.startsWith(u8, line, "# CONFIG_") and std.mem.endsWith(u8, line, " is not set")) {
            const name = line["# CONFIG_".len .. line.len - " is not set".len];
            try w.print("/* #undef CONFIG_{s} */\n", .{name});
        }
    }
    try w.writeAll("\n#endif /* _WUKONG_CCONFIG_H_ */\n");
}

// ---------------------------------------------------------------------------
// 镜像工具
// ---------------------------------------------------------------------------

fn cmdImage(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len == 0) {
        try out.writeAll("usage: wk image <part|env|aic|pack|pagetable|dump> ...\n");
        return error.MissingArgument;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "part")) {
        const cfg_path = getOpt(rest, "--config") orelse return error.MissingArgument;
        var cfg = try image_cfg.load(aa, io, cfg_path);
        defer cfg.deinit();

        const json = try partition_table.generateJson(aa, cfg.root().*);
        defer aa.free(json);
        if (getOpt(rest, "--json")) |p| {
            try writeText(io, p, json);
            try out.print("分区 JSON: {s}\n", .{p});
        } else {
            try out.writeAll(json);
        }

        const header = try partition_table.generateHeader(aa, cfg.root().*);
        defer aa.free(header);
        if (getOpt(rest, "--out")) |p| {
            var buf: std.Io.Writer.Allocating = .init(aa);
            defer buf.deinit();
            try buf.writer.writeAll("/* This is an auto generated file, please don't modify it. */\n\n");
            try buf.writer.writeAll("#ifndef _AIC_IMAGE_CFG_JSON_PARTITION_TABLE_H_\n#define _AIC_IMAGE_CFG_JSON_PARTITION_TABLE_H_\n\n");
            try buf.writer.writeAll(header);
            try buf.writer.writeAll("\n#endif\n");
            try writeText(io, p, buf.written());
            try out.print("分区头文件: {s}\n", .{p});
        }
        return;
    }

    if (std.mem.eql(u8, sub, "env")) {
        var size: usize = 4096;
        var redundant = hasFlag(rest, "--redundant");
        var input: ?[]const u8 = getOpt(rest, "--input");
        var prefix: []const u8 = "";
        var default_out: []const u8 = "env.bin";

        if (getOpt(rest, "--config")) |cfg_path| {
            var cfg = try image_cfg.load(aa, io, cfg_path);
            defer cfg.deinit();
            const root_obj = image_cfg.asObject(cfg.root().*) orelse return error.BadConfig;
            const pre = image_cfg.getObj(root_obj, "pre-process") orelse return error.BadConfig;
            const uenv = image_cfg.getObj(pre, "uboot_env") orelse return error.BadConfig;
            var it = uenv.iterator();
            const entry = it.next() orelse return error.BadConfig;
            const env_name = entry.key_ptr.*;
            const env_obj = image_cfg.asObject(entry.value_ptr.*) orelse return error.BadConfig;
            const file = image_cfg.getStr(env_obj, "file") orelse "env.txt";
            const size_str = image_cfg.getStr(env_obj, "size") orelse "4096";
            size = @intCast(try utils.sizeStrToInt(size_str));
            if (image_cfg.getStr(env_obj, "redundant")) |r| redundant = std.mem.find(u8, r, "enable") != null;
            default_out = env_name;
            const base_dir = std.fs.path.dirname(cfg_path) orelse ".";
            input = try std.fs.path.join(aa, &.{ base_dir, file });
            const pfx = try partition_table.partsForEnv(aa, cfg.root().*);
            prefix = pfx; // aa 生命周期覆盖整个命令
        }

        const in_path = input orelse return error.MissingArgument;
        const image_bytes = try pack.buildEnv(aa, io, in_path, size, redundant, prefix);
        defer aa.free(image_bytes);

        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse
            try std.fs.path.join(aa, &.{ IMAGE_DIR, default_out });
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, image_bytes);
        try out.print("环境变量镜像: {s} ({d} bytes, redundant={})\n", .{ out_path, image_bytes.len, redundant });
        return;
    }

    if (std.mem.eql(u8, sub, "aic")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const load_addr = try parseU32Opt(rest, "--load", 0x40100000);
        const entry = try parseU32Opt(rest, "--entry", load_addr);
        const head_ver = try parseU32Opt(rest, "--head-ver", 0x0001_0000);
        const bytes = try pack.buildAicImage(aa, io, input, load_addr, entry, head_ver);
        defer aa.free(bytes);
        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse
            try std.fs.path.join(aa, &.{ IMAGE_DIR, "bootloader.aic" });
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, bytes);
        try out.print("AIC 镜像: {s} ({d} bytes, load=0x{X:0>8}, entry=0x{X:0>8})\n", .{ out_path, bytes.len, load_addr, entry });
        return;
    }

    if (std.mem.eql(u8, sub, "pack")) {
        const cfg_path = getOpt(rest, "--config") orelse return error.MissingArgument;
        const datadir = getOpt(rest, "--datadir") orelse (std.fs.path.dirname(cfg_path) orelse ".");
        const bytes = try pack.buildFirmware(aa, io, cfg_path, datadir);
        defer aa.free(bytes);

        var cfg = try image_cfg.load(aa, io, cfg_path);
        defer cfg.deinit();
        const root_obj = image_cfg.asObject(cfg.root().*) orelse return error.BadConfig;
        const info = image_cfg.getObj(root_obj, "image") orelse return error.BadConfig;
        const info_obj = image_cfg.getObj(info, "info") orelse return error.BadConfig;
        const product = image_cfg.getStr(info_obj, "product") orelse "firmware";

        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse
            try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}.img", .{product}) });
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, bytes);
        try out.print("固件包: {s} ({d} bytes)\n", .{ out_path, bytes.len });
        try fw_image.dump(out, bytes);
        return;
    }

    if (std.mem.eql(u8, sub, "elf2its")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const elf = try readBytes(io, aa, input);
        defer aa.free(elf);

        const segs = try elf2aic.itsSegments(aa, elf);
        defer elf2aic.freeItsSegments(aa, segs);

        const its_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
            const base = std.fs.path.basename(input);
            const stem = if (std.mem.endsWith(u8, base, ".elf")) base[0 .. base.len - 4] else base;
            break :blk try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}_os.its", .{stem}) });
        };
        const out_dir = std.fs.path.dirname(its_path) orelse ".";
        try std.Io.Dir.cwd().createDirPath(io, out_dir);

        for (segs, 0..) |seg, i| {
            const seg_path = try std.fs.path.join(aa, &.{ out_dir, try std.fmt.allocPrint(aa, "seg{d}.bin", .{i}) });
            try writeBytes(io, seg_path, seg.data);
        }

        var its_text: std.Io.Writer.Allocating = .init(aa);
        defer its_text.deinit();
        const version = getOpt(rest, "--version") orelse "1.0.0";
        const description = getOpt(rest, "--description") orelse "Luban-lite firmware";
        var algos: std.ArrayList([]const u8) = .empty;
        defer algos.deinit(aa);
        if (!hasFlag(rest, "--no-hash")) {
            if (getOpt(rest, "--hash")) |list| {
                var it = std.mem.splitScalar(u8, list, ',');
                while (it.next()) |algo| {
                    if (algo.len > 0) try algos.append(aa, algo);
                }
            } else {
                try algos.append(aa, "crc32");
                try algos.append(aa, "md5");
            }
        }
        try elf2aic.generateIts(&its_text.writer, segs, version, description, algos.items);
        try writeBytes(io, its_path, its_text.written());

        try out.print("ITS 文件: {s}（{d} 个段, 数据目录 {s}）\n", .{ its_path, segs.len, out_dir });
        for (segs, 0..) |seg, i| {
            try out.print("  seg{d}.bin  {d} bytes  load=0x{X:0>8} entry=0x{X:0>8}\n", .{ i, seg.data.len, seg.load_addr, seg.entry });
        }
        return;
    }

    if (std.mem.eql(u8, sub, "elf2aic")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const elf = try readBytes(io, aa, input);
        defer aa.free(elf);

        const info = try elf2aic.inspect(elf);
        const head_ver = try parseU32Opt(rest, "--head-ver", image.HEAD_VER_1_0_0);
        const out_bytes = try elf2aic.convert(aa, elf, head_ver);
        defer aa.free(out_bytes);

        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
            const base = std.fs.path.basename(input);
            const stem = if (std.mem.endsWith(u8, base, ".elf")) base[0 .. base.len - 4] else base;
            break :blk try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}.aic", .{stem}) });
        };
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, out_bytes);
        try out.print("AIC 镜像: {s} ({d} bytes, load=0x{X:0>8}, entry=0x{X:0>8}, span={d}, PT_LOAD={d})\n", .{
            out_path,
            out_bytes.len,
            info.load_address,
            info.entry,
            info.span,
            info.segments,
        });
        return;
    }

    if (std.mem.eql(u8, sub, "itb")) {
        if (getOpt(rest, "--its")) |its_path| {
            var parsed = try its.parse(aa, io, its_path);
            defer parsed.deinit();

            const timestamp = parseOptionalU32(rest, "--timestamp") orelse currentTimestamp(io);
            const blob = try parsed.buildFdt(aa, timestamp);
            defer aa.free(blob);

            const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
                const base = std.fs.path.basename(its_path);
                const stem = if (std.mem.endsWith(u8, base, ".its")) base[0 .. base.len - 4] else base;
                break :blk try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}.itb", .{stem}) });
            };
            try ensureParentDir(io, out_path);
            try writeBytes(io, out_path, blob);
            try out.print("FIT 镜像: {s} ({d} bytes, 来源 {s}, timestamp=0x{X:0>8})\n", .{
                out_path, blob.len, its_path, timestamp,
            });
            return;
        }

        const kernel_path = getOpt(rest, "--kernel") orelse return error.MissingArgument;
        const kernel_data = try readBytes(io, aa, kernel_path);
        defer aa.free(kernel_data);

        var opts = itb.Options{
            .description = getOpt(rest, "--description") orelse "WuKong-Lite FIT image",
            .timestamp = parseOptionalU32(rest, "--timestamp") orelse currentTimestamp(io),
            .default_config = getOpt(rest, "--config") orelse "conf-1",
            .kernel = .{
                .name = getOpt(rest, "--kernel-name") orelse "kernel-1",
                .data = kernel_data,
                .arch = getOpt(rest, "--arch") orelse "riscv",
                .os = getOpt(rest, "--os") orelse "linux",
                .load = parseOptionalU32(rest, "--load"),
                .entry = parseOptionalU32(rest, "--entry"),
            },
        };

        var fdt_data: ?[]u8 = null;
        defer if (fdt_data) |d| aa.free(d);
        if (getOpt(rest, "--fdt")) |p| {
            fdt_data = try readBytes(io, aa, p);
            opts.fdt = .{ .name = "fdt-1", .data = fdt_data.?, .type_ = "flat_dt" };
        }
        var ramdisk_data: ?[]u8 = null;
        defer if (ramdisk_data) |d| aa.free(d);
        if (getOpt(rest, "--ramdisk")) |p| {
            ramdisk_data = try readBytes(io, aa, p);
            opts.ramdisk = .{ .name = "ramdisk-1", .data = ramdisk_data.?, .type_ = "ramdisk" };
        }

        const blob = try itb.build(aa, opts);
        defer aa.free(blob);

        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
            const base = std.fs.path.basename(kernel_path);
            const stem = if (std.mem.endsWith(u8, base, ".bin")) base[0 .. base.len - 4] else base;
            break :blk try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}.itb", .{stem}) });
        };
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, blob);
        try out.print("FIT 镜像: {s} ({d} bytes, kernel={s}, fdt={s}, 配置={s})\n", .{
            out_path,
            blob.len,
            opts.kernel.name,
            if (opts.fdt) |f| f.name else "-",
            opts.default_config,
        });
        return;
    }

    if (std.mem.eql(u8, sub, "crypt")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const key = try crypt.parseHex16(getOpt(rest, "--key") orelse return error.MissingArgument);
        const iv = try crypt.parseHex16(getOpt(rest, "--iv") orelse return error.MissingArgument);
        const decrypt_mode = hasFlag(rest, "--decrypt");
        const pad = if (getOpt(rest, "--pad")) |p|
            (if (std.mem.eql(u8, p, "zero")) crypt.Pad.zero else if (std.mem.eql(u8, p, "pkcs7")) crypt.Pad.pkcs7 else crypt.Pad.none)
        else
            crypt.Pad.none;

        const data = try readBytes(io, aa, input);
        defer aa.free(data);

        const result = if (decrypt_mode)
            try crypt.decrypt(aa, data, key, iv)
        else
            try crypt.encrypt(aa, data, key, iv, pad);
        defer aa.free(result);

        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
            const base = std.fs.path.basename(input);
            break :blk try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}.{s}.bin", .{ base, if (decrypt_mode) "dec" else "enc" }) });
        };
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, result);
        try out.print("{s}: {s} ({d} -> {d} bytes, AES-128-CBC)\n", .{
            if (decrypt_mode) "解密" else "加密",
            out_path,
            data.len,
            result.len,
        });
        return;
    }

    if (std.mem.eql(u8, sub, "fitinfo")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const blob = try readBytes(io, aa, input);
        defer aa.free(blob);

        var tree = fdt_reader.parse(aa, blob) catch |err| {
            try out.print("FIT 解析失败（{s}）：{s}\n", .{ input, @errorName(err) });
            return;
        };
        defer tree.deinit();

        try out.print("FIT: {s}\n", .{input});
        try out.print("  totalsize={d} version={d} struct@{d}/{d} strings@{d}/{d}\n", .{
            tree.header.totalsize,
            tree.header.version,
            tree.header.off_dt_struct,
            tree.header.size_dt_struct,
            tree.header.off_dt_strings,
            tree.header.size_dt_strings,
        });
        if (fdt_reader.getBe32(tree.root, "timestamp")) |ts| {
            try out.print("  timestamp=0x{x} ({d})\n", .{ ts, ts });
        }
        if (fdt_reader.getString(tree.root, "description")) |d| {
            try out.print("  description={s}\n", .{d});
        }

        if (fdt_reader.findChild(tree.root, "images")) |images| {
            try out.print("  images: {d}\n", .{images.children.items.len});
            for (images.children.items) |img| {
                const data_len: usize = if (fdt_reader.findProp(img, "data")) |d| d.len else 0;
                try out.print("    {s}: data={d} bytes, type={s}\n", .{
                    img.name,
                    data_len,
                    fdt_reader.getString(img, "type") orelse "-",
                });
            }
        }
        if (fdt_reader.findChild(tree.root, "configurations")) |configs| {
            try out.print("  configurations: {d} (default={s})\n", .{
                configs.children.items.len,
                fdt_reader.getString(configs, "default") orelse "-",
            });
        }

        if (hasFlag(rest, "--verify")) {
            const r = fdt_reader.verifyHashes(&tree);
            try out.print("  校验: checked={d} failed={d} skipped_external={d}\n", .{ r.checked, r.failed, r.skipped_external });
            if (r.failed != 0) return error.HashMismatch;
        }
        if (hasFlag(rest, "--dump")) {
            try fdt_reader.dump(out, tree.root, 0);
        }
        return;
    }

    if (std.mem.eql(u8, sub, "fat")) {
        const input_dir = getOpt(rest, "--input-dir") orelse return error.MissingArgument;
        const output = getOpt(rest, "--output") orelse getOpt(rest, "-o") orelse return error.MissingArgument;
        const auto = hasFlag(rest, "--auto");
        const size_text = getOpt(rest, "--size") orelse (if (auto) "0" else return error.MissingArgument);
        const total_bytes = aic.utils.sizeStrToInt(size_text) catch return error.InvalidArgument;
        const sector: u16 = if (getOpt(rest, "--sector")) |v| @intCast(std.fmt.parseInt(usize, v, 0) catch return error.InvalidArgument) else 512;
        const cluster: u8 = if (getOpt(rest, "--cluster")) |v| @intCast(std.fmt.parseInt(usize, v, 0) catch return error.InvalidArgument) else 8;

        var builder = try fat.Builder.init(aa, .{
            .total_bytes = total_bytes,
            .sector_size = sector,
            .cluster_sectors = cluster,
            .volume_label = getOpt(rest, "--label") orelse "NO NAME",
            .mtime = if (getOpt(rest, "--mtime")) |v| @intCast(std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument) else 0,
        });
        defer builder.deinit();

        builder.addTreeFromDir(io, input_dir) catch |err| {
            try out.print("读取目录失败（{s}）：{s}\n", .{ input_dir, @errorName(err) });
            return;
        };

        if (auto) {
            builder.opts.total_bytes = try builder.autoTotalBytes();
        }
        const img = try builder.build();
        defer aa.free(img);

        try ensureParentDir(io, output);
        try writeBytes(io, output, img);
        try out.print("FAT: {s} ({d} bytes, sector={d}, cluster={d} sectors, label={s})\n", .{
            output,
            img.len,
            sector,
            cluster,
            builder.opts.volume_label,
        });
        return;
    }

    if (std.mem.eql(u8, sub, "rsasign")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const key_path = getOpt(rest, "--key") orelse return error.MissingArgument;
        const data = try readBytes(io, aa, input);
        defer aa.free(data);
        const pem = try readBytes(io, aa, key_path);
        defer aa.free(pem);

        var key = rsa.parsePrivatePem(aa, pem) catch |err| {
            try out.print("私钥解析失败（{s}）：{s}\n", .{ key_path, @errorName(err) });
            return;
        };
        defer key.deinit(aa);

        const sig = try rsa.signSha256(aa, &key, data);
        defer aa.free(sig);

        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
            break :blk try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}.sig", .{std.fs.path.basename(input)}) });
        };
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, sig);
        try out.print("RSA PKCS#1 v1.5 SHA-256: {s}（{d} bytes，key {d} bits）-> {s}\n", .{
            input,
            sig.len,
            key.bits(),
            out_path,
        });
        return;
    }

    if (std.mem.eql(u8, sub, "rsaverify")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const key_path = getOpt(rest, "--key") orelse return error.MissingArgument;
        const sig_path = getOpt(rest, "--sig") orelse return error.MissingArgument;
        const data = try readBytes(io, aa, input);
        defer aa.free(data);
        const pem = try readBytes(io, aa, key_path);
        defer aa.free(pem);
        const sig = try readBytes(io, aa, sig_path);
        defer aa.free(sig);

        var key = rsa.parsePublicPem(aa, pem) catch |err| {
            try out.print("公钥解析失败（{s}）：{s}\n", .{ key_path, @errorName(err) });
            return error.SignatureMismatch;
        };
        defer key.deinit(aa);

        const ok = try rsa.verifySha256(aa, &key, data, sig);
        try out.print("验签 {s}: {s}\n", .{ if (ok) "成功" else "失败", input });
        if (!ok) return error.SignatureMismatch;
        return;
    }

    if (std.mem.eql(u8, sub, "simg")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const data = try readBytes(io, aa, input);
        defer aa.free(data);
        const unsparse = hasFlag(rest, "--unsparse");

        const result = if (unsparse)
            try sparse.fromSparse(aa, data)
        else blk: {
            const block: u32 = if (getOpt(rest, "--block")) |v| @intCast(std.fmt.parseInt(usize, v, 0) catch return error.InvalidArgument) else 4096;
            break :blk try sparse.toSparse(aa, data, block);
        };
        defer aa.free(result);

        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
            const base = std.fs.path.basename(input);
            break :blk try std.fs.path.join(aa, &.{ IMAGE_DIR, try std.fmt.allocPrint(aa, "{s}.{s}", .{ base, if (unsparse) "raw" else "sparse" }) });
        };
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, result);
        try out.print("simg: {s} -> {s}（{d} -> {d} bytes，{s}）\n", .{
            input,
            out_path,
            data.len,
            result.len,
            if (unsparse) "sparse->raw" else "raw->sparse",
        });
        return;
    }

    if (std.mem.eql(u8, sub, "cpio")) {
        const list_path = getOpt(rest, "--list") orelse return error.MissingArgument;
        const output = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse return error.MissingArgument;
        const input_dir = getOpt(rest, "--input-dir") orelse ".";
        const format: cpio.Format = if (getOpt(rest, "--format")) |v|
            (if (std.mem.eql(u8, v, "newc")) cpio.Format.newc else cpio.Format.crc)
        else
            cpio.Format.crc;
        const mtime: u32 = if (getOpt(rest, "--mtime")) |v| @intCast(std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument) else 0;

        const list = try readBytes(io, aa, list_path);
        defer aa.free(list);

        var entries: std.ArrayList(cpio.Entry) = .empty;
        defer entries.deinit(aa);
        var it = std.mem.splitScalar(u8, list, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const is_dir_hint = std.mem.endsWith(u8, line, "/");
            const name = std.mem.trimEnd(u8, line, "/");
            const joined = try std.fs.path.join(aa, &.{ input_dir, name });
            defer aa.free(joined);

            const stat = std.Io.Dir.cwd().statFile(io, joined, .{}) catch |err| {
                try out.print("跳过 {s}（{s}）\n", .{ name, @errorName(err) });
                continue;
            };
            const is_dir = is_dir_hint or stat.kind == .directory;
            const data = if (is_dir) "" else try readBytes(io, aa, joined);
            defer if (!is_dir) aa.free(data);
            try entries.append(aa, .{
                .name = try aa.dupe(u8, name),
                .data = if (is_dir) "" else try aa.dupe(u8, data),
                .is_dir = is_dir,
                .mtime = mtime,
            });
        }

        const archive = try cpio.build(aa, entries.items, format);
        defer aa.free(archive);
        try ensureParentDir(io, output);
        try writeBytes(io, output, archive);
        try out.print("cpio: {s}（{d} entries，{d} bytes，{s}）\n", .{
            output,
            entries.items.len,
            archive.len,
            if (format == .crc) "crc" else "newc",
        });
        return;
    }

    if (std.mem.eql(u8, sub, "pagetable")) {
        const input = getOpt(rest, "--input") orelse return error.MissingArgument;
        const page = try parseU32Opt(rest, "--page", 2);
        const block = try parseU32Opt(rest, "--block", 128);
        const planes = try parseU32Opt(rest, "--planes", 1);
        const bytes = try pack.buildPageTable(aa, io, input, page, block, @intCast(planes));
        defer aa.free(bytes);
        const out_path = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse
            try std.fs.path.join(aa, &.{ IMAGE_DIR, "page_table.bin" });
        try ensureParentDir(io, out_path);
        try writeBytes(io, out_path, bytes);
        try out.print("NAND 页表: {s} ({d} bytes, page={d}KiB, block={d}KiB)\n", .{ out_path, bytes.len, page, block });
        return;
    }

    if (std.mem.eql(u8, sub, "dump")) {
        const path = if (rest.len > 0) rest[0] else return error.MissingArgument;
        const bytes = try readBytes(io, aa, path);
        defer aa.free(bytes);
        if (fw_image.headerIsValid(bytes)) {
            try fw_image.dump(out, bytes);
        } else if (image.verifyMagic(bytes, image.MAGIC)) {
            try image.dump(out, bytes);
            image.verify(bytes) catch |err| {
                try out.print("校验: 失败 ({s})\n", .{@errorName(err)});
                return;
            };
            try out.writeAll("校验: OK\n");
        } else if (env_image.parse(bytes)) |parsed| {
            try out.print("环境变量镜像: {d} bytes, redundant={}\n", .{ bytes.len, parsed.redundant });
            try env_image.printData(out, parsed.data);
        } else |_| {
            try out.print("未知镜像格式: {s}\n", .{path});
            return error.UnknownImageFormat;
        }
        return;
    }

    try out.print("wk: 未知 image 子命令: {s}\n", .{sub});
    return error.UnknownCommand;
}

// ---------------------------------------------------------------------------
// shell / 示例 / demo
// ---------------------------------------------------------------------------

fn cmdShell(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    var counting = heapmod.Counting.init(gpa);
    const allocator = counting.allocator();

    var kernel = osal.Kernel.init(allocator, io);
    defer kernel.deinit();
    _ = try kernel.registerThread("msh");

    var registry = device.Registry.init(allocator);
    defer registry.deinit();

    var uart: uart_drv.Uart = undefined;
    if (board_config.AIC_UART_DRV and board_config.AIC_USING_UART0) {
        uart.init(board_config.AIC_CONSOLE_DEVICE, io);
        try registry.register(&uart.dev);
    }

    var gpio: gpio_drv.Gpio = .{};
    if (board_config.AIC_GPIO_DRV and board_config.AIC_USING_GPIO) {
        gpio.init("gpio0");
        try registry.register(&gpio.dev);
    }

    var shell = shell_mod.Shell{
        .allocator = allocator,
        .io = io,
        .kernel = &kernel,
        .devices = &registry,
        .heap = &counting,
        .gpio = if (board_config.AIC_GPIO_DRV and board_config.AIC_USING_GPIO) &gpio else null,
        .commands = &cmds.default_commands,
    };

    if (getOpt(args, "-c")) |cmdline| {
        _ = try shell.exec(cmdline, out);
        return;
    }

    try out.print("\nWuKong-Lite msh [{s}/{s}] (type 'help', 'exit' to quit)\n", .{ board_config.PRJ_CHIP, board_config.PRJ_BOARD });
    try out.flush();
    try shell.run(out);
}

fn cmdRun(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    const app = if (args.len > 0) args[0] else "hello";
    if (std.mem.eql(u8, app, "hello") or std.mem.eql(u8, app, "helloworld")) {
        try helloworld.run(aa, io, out);
        return;
    }
    try out.print("wk run: 未知应用 {s}（目前支持 hello）\n", .{app});
    return error.UnknownApp;
}

fn cmdDemo(io: std.Io, aa: std.mem.Allocator, out: *std.Io.Writer) !void {
    const demo_dir = try std.fs.path.join(aa, &.{ IMAGE_DIR, "demo" });
    try std.Io.Dir.cwd().createDirPath(io, demo_dir);

    // 1) 应用方案（若尚未生成 .config）
    const plan_path = try std.fs.path.join(aa, &.{ CONFIG_PLANS, "d13x_demo88-nor_rt-thread_helloworld_defconfig" });
    const plan_text = try readText(io, aa, plan_path);
    var cfg = try kconfig.load(aa, io, KCONFIG_ROOT);
    defer cfg.deinit();
    try cfg.applyDefconfig(plan_text);
    cfg.resolve();
    try std.Io.Dir.cwd().createDirPath(io, CONFIG_DIR);
    var dot: std.Io.Writer.Allocating = .init(aa);
    defer dot.deinit();
    try cfg.writeDotConfig(&dot.writer);
    try writeText(io, try std.fs.path.join(aa, &.{ CONFIG_DIR, ".config" }), dot.written());
    var hdr: std.Io.Writer.Allocating = .init(aa);
    defer hdr.deinit();
    try cfg.writeHeader(&hdr.writer);
    try writeText(io, try std.fs.path.join(aa, &.{ CONFIG_DIR, "cconfig.h" }), hdr.written());

    _ = try writeGeneratedConfig(io, aa, &cfg, dot.written());

    // 2) 生成演示用原始文件
    const payloads = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "psram.bin", .data = "WUKONG-PSRAM-INIT-PAYLOAD\n" },
        .{ .name = "bootloader.bin", .data = "WUKONG-BOOTLOADER-CODE\n" },
        .{ .name = "os.bin", .data = "WUKONG-RTOS-KERNEL-IMAGE\n" },
        .{ .name = "data.bin", .data = "WUKONG-LITTLEFS-DATA\n" },
        .{ .name = "rodata.bin", .data = "WUKONG-FATFS-RODATA\n" },
        .{ .name = "env.txt", .data = "osAB_next=A\nupgrade_available=0\nbootlimit=5\nbootcount=0\n" },
    };
    for (payloads) |p| {
        const path = try std.fs.path.join(aa, &.{ demo_dir, p.name });
        try writeText(io, path, p.data);
    }

    // 3) 生成 bootloader.aic / os.aic（loader 镜像）
    const load_addr: u32 = 0x40100000;
    const bl_aic = try pack.buildAicImage(aa, io, try std.fs.path.join(aa, &.{ demo_dir, "bootloader.bin" }), load_addr, load_addr, image.HEAD_VER_1_0_0);
    defer aa.free(bl_aic);
    try writeBytes(io, try std.fs.path.join(aa, &.{ demo_dir, "bootloader.aic" }), bl_aic);

    const os_load: u32 = 0x41000000;
    const os_aic = try pack.buildAicImage(aa, io, try std.fs.path.join(aa, &.{ demo_dir, "os.bin" }), os_load, os_load, image.HEAD_VER_1_0_0);
    defer aa.free(os_aic);
    try writeBytes(io, try std.fs.path.join(aa, &.{ demo_dir, "os.aic" }), os_aic);

    // 4) 分区串 + 环境变量镜像
    const cfg_path = try std.fs.path.join(aa, &.{"wk/target/d13x/demo88-nor/pack/image_cfg.json"});
    var image_cfg_parsed = try image_cfg.load(aa, io, cfg_path);
    defer image_cfg_parsed.deinit();
    const prefix = try partition_table.partsForEnv(aa, image_cfg_parsed.root().*);
    const env = try pack.buildEnv(aa, io, try std.fs.path.join(aa, &.{ demo_dir, "env.txt" }), 4096, true, prefix);
    defer aa.free(env);
    try writeBytes(io, try std.fs.path.join(aa, &.{ demo_dir, "env.bin" }), env);

    // 5) 打包 AIC.FW 固件
    const fw = try pack.buildFirmware(aa, io, cfg_path, demo_dir);
    defer aa.free(fw);
    const fw_path = try std.fs.path.join(aa, &.{ demo_dir, "demo88-nor.img" });
    try writeBytes(io, fw_path, fw);

    // 6) 分区表头文件 / JSON
    const parts_header = try partition_table.generateHeader(aa, image_cfg_parsed.root().*);
    defer aa.free(parts_header);
    var full_header: std.Io.Writer.Allocating = .init(aa);
    defer full_header.deinit();
    try full_header.writer.writeAll("/* This is an auto generated file, please don't modify it. */\n\n");
    try full_header.writer.writeAll(header_prologue);
    try full_header.writer.writeAll(parts_header);
    try full_header.writer.writeAll("\n#endif\n");
    try writeText(io, try std.fs.path.join(aa, &.{ demo_dir, "partition_table.h" }), full_header.written());

    const parts_json = try partition_table.generateJson(aa, image_cfg_parsed.root().*);
    defer aa.free(parts_json);
    try writeText(io, try std.fs.path.join(aa, &.{ demo_dir, "partition.json" }), parts_json);

    // 7) 输出摘要
    try out.print("== WuKong-Lite demo ==\n", .{});
    try out.print("工作目录: {s}\n", .{demo_dir});
    try out.print("  bootloader.bin  -> bootloader.aic ({d} bytes)\n", .{bl_aic.len});
    try out.print("  os.bin          -> os.aic       ({d} bytes)\n", .{os_aic.len});
    try out.print("  env.txt         -> env.bin      ({d} bytes, redundant)\n", .{env.len});
    try out.print("  image_cfg.json  -> demo88-nor.img ({d} bytes)\n\n", .{fw.len});
    try out.writeAll("固件包内容:\n");
    try fw_image.dump(out, fw);
    try out.writeAll("\n分区表头文件片段:\n");
    try out.writeAll(parts_header);
    try out.flush();
}

const header_prologue =
    \\#ifndef _AIC_IMAGE_CFG_JSON_PARTITION_TABLE_H_
    \\#define _AIC_IMAGE_CFG_JSON_PARTITION_TABLE_H_
    \\
;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

fn getOpt(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, name)) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
        if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') {
            return a[name.len + 1 ..];
        }
    }
    return null;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

fn parseU32Opt(args: []const []const u8, name: []const u8, default: u32) !u32 {
    const v = getOpt(args, name) orelse return default;
    return std.fmt.parseInt(u32, v, 0);
}

fn parseOptionalU32(args: []const []const u8, name: []const u8) ?u32 {
    const v = getOpt(args, name) orelse return null;
    return std.fmt.parseInt(u32, v, 0) catch null;
}

fn currentTimestamp(io: std.Io) u32 {
    const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
    if (seconds <= 0 or seconds > std.math.maxInt(u32)) return 0x5F00_0000;
    return @intCast(seconds);
}

fn writeText(io: std.Io, path: []const u8, text: []const u8) !void {
    try ensureParentDir(io, path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

fn writeBytes(io: std.Io, path: []const u8, data: []const u8) !void {
    try writeText(io, path, data);
}

fn readText(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

fn readBytes(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readText(io, allocator, path);
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(io, dir);
    }
}
