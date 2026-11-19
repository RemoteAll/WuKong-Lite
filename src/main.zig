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
const merge = aic.merge;
const ota = aic.ota;
const linkaddr = aic.linkaddr;
const linksize = aic.linksize;
const partlist = aic.partlist;
const partcheck = aic.partcheck;
const littlefs = aic.littlefs;
const fsinstall = aic.fsinstall;
const sdk_update = aic.sdk_update;
const rtt2freertos = aic.rtt2freertos;
const upg_frame = aic.upg_frame;
const upg_payload = aic.upg_payload;
const upg_client = aic.upg_client;
const panic = aic.panic;
const preboot = aic.preboot;
const privres = aic.privres;
const aicboot = aic.aicboot;
const preproc = aic.preproc;
const rsa_key = aic.rsa_key;
const flashpack = aic.flashpack;
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

// Windows 控制台代码页（见 main() 里的说明）。
extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) c_int;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Windows 控制台默认是 GBK(936)，而本程序统一输出 UTF-8 中文 —— 仅在 stdout
    // 是终端时切换输出代码页，避免 `wk` 的中文提示在 PowerShell 里显示成乱码。
    // 重定向到文件/管道时不改动（不影响落盘内容）。
    if (@import("builtin").os.tag == .windows) {
        if (std.Io.File.stdout().isTty(io) catch false) {
            _ = SetConsoleOutputCP(65001);
            _ = SetConsoleCP(65001);
        }
    }

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
    } else if (std.mem.eql(u8, cmd, "fs")) {
        try cmdFs(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "sdk-update")) {
        try cmdSdkUpdate(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "rtt2freertos")) {
        try cmdRtt2Freertos(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "upg")) {
        try cmdUpg(io, aa, rest, out);
    } else if (std.mem.eql(u8, cmd, "panic")) {
        try cmdPanic(io, aa, rest, out);
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

/// `wk sdk-update --root <SDK 根目录> [--write]` —— 等价 `tools/scripts/sdk_update.py`。
fn cmdSdkUpdate(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    const root = getOpt(args, "--root") orelse getOpt(args, "-r") orelse ".";
    const write = hasFlag(args, "--write");
    const result = sdk_update.updateRoot(aa, io, root, write, out) catch |err| {
        try out.print("sdk-update 失败：{s}（root={s}）\n", .{ @errorName(err), root });
        return err;
    };
    try out.print(
        "sdk-update: 扫描 {d} 个 pinmux.c，{s} {d} 个（{s}）\n",
        .{ result.scanned, if (write) "修复" else "待修复", result.changed, if (write) "已落盘" else "加 --write 落盘" },
    );
}

/// `wk panic -l <log> [-e <elf>] [-c riscv|csky] [--addr2line <tool>]` —— 等价 `panic_parse.py`。
fn cmdPanic(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    const log_path = getOpt(args, "--log") orelse getOpt(args, "-l") orelse return error.MissingArgument;
    const elf_path = getOpt(args, "--elf") orelse getOpt(args, "-e");

    var cpu: panic.Cpu = .riscv;
    if (getOpt(args, "--cpu") orelse getOpt(args, "-c")) |name| {
        if (std.ascii.eqlIgnoreCase(name, "riscv") or
            std.ascii.eqlIgnoreCase(name, "c906") or
            std.ascii.eqlIgnoreCase(name, "e906") or
            std.ascii.eqlIgnoreCase(name, "e907"))
        {
            cpu = .riscv;
        } else if (std.ascii.eqlIgnoreCase(name, "ck802") or std.ascii.eqlIgnoreCase(name, "csky")) {
            cpu = .csky;
        } else {
            try out.print("panic: 不支持的 CPU「{s}」（可用 riscv / c906 / csky）\n", .{name});
            return error.InvalidArgument;
        }
    }

    const log = try readText(io, aa, log_path);
    defer aa.free(log);
    const verbose = hasFlag(args, "--verbose") or hasFlag(args, "-v");
    const elf: ?[]u8 = if (elf_path) |p| try readBytes(io, aa, p) else null;
    defer if (elf) |e| aa.free(e);

    var report = panic.analyze(aa, .{ .log = log, .elf = elf, .cpu = cpu }) catch |err| {
        try out.print("panic 解析失败：{s}（log={s}）\n", .{ @errorName(err), log_path });
        return err;
    };
    defer report.deinit(aa);

    // 参考脚本会先把 `ELF:` 行打印出来（其余信息在其后）。
    if (elf != null) try out.print("ELF: {s}\n\n", .{elf_path.?});

    var table: ?panic.SymTab = null;
    defer if (table) |*t| t.deinit();
    if (elf) |e| {
        table = panic.parseSymbols(aa, e) catch |err| blk: {
            try out.print("panic: ELF 符号表解析失败（{s}），仅按地址输出\n", .{@errorName(err)});
            break :blk null;
        };
    }

    // addr2line：显式指定 > 默认工具链路径（存在则用）
    var addr2line: ?[]const u8 = getOpt(args, "--addr2line");
    if (addr2line == null) {
        const candidates = [_][]const u8{
            "toolchain/bin/riscv64-unknown-elf-addr2line.exe",
            "toolchain/bin/riscv64-unknown-elf-addr2line",
        };
        for (candidates) |cand| {
            if (std.Io.Dir.cwd().statFile(io, cand, .{})) |_| {
                addr2line = cand;
                break;
            } else |_| {}
        }
    }

    // addr2line 输出里的绝对路径按「当前目录 + /」裁剪（与参考脚本 replace(SDK_DIR,'') 同口径）
    const cwd_z: ?[:0]u8 = std.process.currentPathAlloc(io, aa) catch null;
    defer if (cwd_z) |p| aa.free(p);
    const sdk_dir: ?[]u8 = if (cwd_z) |p| try std.fmt.allocPrint(aa, "{s}/", .{p}) else null;
    defer if (sdk_dir) |s| aa.free(s);

    try out.print("CPU: {s}\n", .{switch (cpu) {
        .riscv => "RISC-V",
        .csky => "CSKY",
    }});
    if (verbose) {
        try out.print("[verbose] log={d} B, elf={s}, registers={d}, frames={d}\n", .{
            log.len, elf_path orelse "(none)", report.regs.len, report.frames.len,
        });
    }
    if (addr2line != null) try out.writeAll("Toolchain: riscv64-unknown-elf\n");
    if (elf != null) {
        try out.print(
            "Text section: 0x{x:0>8} - 0x{x:0>8}, size: {d} Bytes\n",
            .{ report.text_start, report.text_end, report.text_end -% report.text_start },
        );
    }

    try out.writeAll("\n---------------------------------------------------------------\nCPU Registers:\n---------------------------------------------------------------\n");
    if (report.regs.len == 0) {
        try out.writeAll("No CPU registers found\n");
    } else {
        try out.print("CPU Exception: {d} ({s})\n", .{ report.exception, report.exception_name });
        for (report.regs) |reg| {
            var loc_buf: []u8 = &.{};
            if (elf != null and report.inText(reg.value)) loc_buf = try locateAddr(aa, io, addr2line, elf_path, &table, sdk_dir, reg.value);
            defer if (loc_buf.len > 0) aa.free(loc_buf);
            const alias = panic.regAlias(reg.name);
            if (alias.len > 0) {
                try out.print("{s} ({s}): 0x{x:0>8} {s}\n", .{ reg.name, alias, reg.value, loc_buf });
            } else {
                try out.print("{s}: 0x{x:0>8} {s}\n", .{ reg.name, reg.value, loc_buf });
            }
        }
    }

    if (elf == null) return;
    try out.writeAll("\n---------------------------------------------------------------\nCall Stack:\n---------------------------------------------------------------\n");
    try out.print(
        "Stack section: 0x{x:0>8} - 0x{x:0>8}, size: {d} Bytes\n",
        .{ report.stack_start, report.stack_end, report.stack_end -% report.stack_start },
    );
    for (report.frames, 0..) |frame, idx| {
        const loc = try locateAddr(aa, io, addr2line, elf_path, &table, sdk_dir, frame.addr);
        defer if (loc.len > 0) aa.free(loc);
        try out.print("{d:2}: [0x{x:0>8}] {s}\n", .{ idx, frame.addr, loc });
    }
}

/// 地址定位：优先 addr2line（file:line），失败退回 ELF 符号（symbol+0xNN）。
fn locateAddr(
    aa: std.mem.Allocator,
    io: std.Io,
    addr2line: ?[]const u8,
    elf_path: ?[]const u8,
    table: *?panic.SymTab,
    sdk_dir: ?[]const u8,
    addr: u32,
) ![]u8 {
    if (addr2line) |tool| {
        if (elf_path) |elf| {
            const text = try panic.locateWithAddr2Line(aa, io, tool, elf, addr, sdk_dir);
            if (text.len > 0) return text;
            aa.free(text);
        }
    }
    if (table.*) |*t| return t.describe(aa, addr);
    return aa.dupe(u8, "");
}

/// `wk rtt2freertos <defconfig> [-o out] [--dry-run]` —— 等价 `tools/scripts/rtt2freertos.py`。
fn cmdRtt2Freertos(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    const input_path = blk: {
        for (args) |a| {
            if (!std.mem.startsWith(u8, a, "-")) break :blk a;
        }
        return error.MissingArgument;
    };

    var opts = rtt2freertos.Options{};
    if (getOpt(args, "--console-uart")) |v| {
        opts.console_uart = std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument;
    }
    if (getOpt(args, "--sysname")) |v| opts.sysname = v;

    const input = try readText(io, aa, input_path);
    defer aa.free(input);

    var result = rtt2freertos.convert(aa, input, opts) catch |err| switch (err) {
        rtt2freertos.Error.NoProjectHeader => {
            try out.print("rtt2freertos: {s} 缺少工程头（PRJ_CHIP/PRJ_BOARD/PRJ_KERNEL/PRJ_APP）\n", .{input_path});
            return err;
        },
        rtt2freertos.Error.NotRtThread => {
            try out.print("rtt2freertos: {s} 的 PRJ_KERNEL 不是 rt-thread，本工具只处理 rt-thread 方案\n", .{input_path});
            return err;
        },
        else => return err,
    };
    defer result.deinit();

    const out_path = getOpt(args, "--output") orelse getOpt(args, "-o") orelse blk: {
        const dir = std.fs.path.dirname(input_path) orelse ".";
        break :blk try std.fmt.allocPrint(aa, "{s}/{s}_defconfig", .{ dir, result.plan_name });
    };
    const out_path_owned = (getOpt(args, "--output") orelse getOpt(args, "-o")) == null;
    defer if (out_path_owned) aa.free(out_path);

    try out.print("input  : {s}\n", .{input_path});
    try out.print("output : {s}\n", .{out_path});
    try out.print("plan   : {s}\n\n", .{result.plan_name});

    const report = result.report;
    if (report.kept_off.len > 0) {
        try out.print("kept explicitly off ({d}, they default to y in the target tree):\n", .{report.kept_off.len});
        for (report.kept_off) |n| try out.print("  - {s}\n", .{n});
    }
    if (report.dropped.len > 0) {
        try out.print("dropped functional switches ({d}):\n", .{report.dropped.len});
        const shown = @min(report.dropped.len, 15);
        for (report.dropped[0..shown]) |n| try out.print("  - {s}\n", .{n});
        if (report.dropped.len > shown) try out.print("  ... {d} more\n", .{report.dropped.len - shown});
    }
    if (report.silent > 0) {
        try out.print("silently dropped non-functional options (kernel options / value settings): {d}\n", .{report.silent});
    }
    if (report.mapped.len > 0) {
        try out.writeAll("mapped:\n");
        for (report.mapped) |n| try out.print("  - {s}\n", .{n});
    }
    if (report.added.len > 0) {
        try out.print("added ({d}):\n", .{report.added.len});
        for (report.added) |n| try out.print("  - {s}\n", .{n});
    }
    try out.writeAll("\n");

    if (hasFlag(args, "--dry-run") or hasFlag(args, "-n")) {
        try out.writeAll("--- preview (nothing written) ---\n");
        try out.writeAll(result.text);
        return;
    }

    try writeText(io, out_path, result.text);
    try out.print("written to {s}\n", .{out_path});
    try out.print("\nnext steps:\n  scons --apply-def={s}_defconfig && scons -j8\n", .{result.plan_name});
}

/// `wk upg frame --cmd <n> [--payload <text>|--payload-file <f>] [-o out.bin]`
/// `wk upg decode -i <frame.bin>` —— upgcmd 帧协议编解码（P0-3 底座）。
fn cmdUpg(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len == 0) {
        try out.writeAll(
            "usage: wk upg frame --cmd <n> [--payload <text>|--payload-file <f>] [-o out.bin]\n" ++
                "       wk upg decode -i <frame.bin>\n" ++
                "       wk upg <heartbeat|proto-version|hw-info|device-list|upload-dir|cancel|help> [--task-id N]\n" ++
                "       wk upg config-device --port <COM4|bus:port> [--baudrate N]\n" ++
                "       wk upg burn --image <path> [--no-reboot] [--partition all]\n" ++
                "       wk upg send-cmd --command <text>\n" ++
                "       wk upg get-log [--timeout N]\n" ++
                "       wk upg upload-start --file <path> [--remote-dir <dir>]\n" ++
                "       （以上请求可加 --send 直连 upgcmd server：--server-host 127.0.0.1 --server-port 9100）\n",
        );
        return error.MissingArgument;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "frame")) {
        const cmd_text = getOpt(rest, "--cmd") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const cmd = std.fmt.parseInt(u8, cmd_text, 0) catch return error.InvalidArgument;
        const payload: []const u8 = if (getOpt(rest, "--payload-file")) |p|
            try readBytes(io, aa, p)
        else
            getOpt(rest, "--payload") orelse getOpt(rest, "-p") orelse "";
        defer if (getOpt(rest, "--payload-file") != null) aa.free(payload);

        const frame = try upg_frame.encode(aa, cmd, payload);
        defer aa.free(frame);
        if (getOpt(rest, "--output") orelse getOpt(rest, "-o")) |p| {
            try writeBytes(io, p, frame);
            try out.print("upg frame: {d} B -> {s}\n", .{ frame.len, p });
        }
        for (frame) |b| try out.print("{x:0>2}", .{b});
        try out.writeAll("\n");
        return;
    }

    if (std.mem.eql(u8, sub, "decode")) {
        const path = getOpt(rest, "--input") orelse getOpt(rest, "-i") orelse return error.MissingArgument;
        const data = try readBytes(io, aa, path);
        defer aa.free(data);
        const d = upg_frame.decode(data) catch |err| {
            const text = switch (err) {
                error.TooShort => upg_frame.decodeErrorText(error.TooShort),
                error.BadMagic => upg_frame.decodeErrorText(error.BadMagic),
                error.BadTail => upg_frame.decodeErrorText(error.BadTail),
                error.BadVersion => upg_frame.decodeErrorText(error.BadVersion),
                error.LengthMismatch => upg_frame.decodeErrorText(error.LengthMismatch),
                error.BadCrc => upg_frame.decodeErrorText(error.BadCrc),
            };
            try out.print("upg decode 失败：{s}（{s}）\n", .{ text, path });
            return err;
        };
        try out.print("cmd      : 0x{x:0>2}\n", .{d.cmd});
        try out.print("payload  : {d} B\n", .{d.payload.len});
        try out.print("frame_len: {d} B\n", .{d.frame_len});
        if (d.payload.len > 0) {
            // 二进制 payload（固件分块等）只在合法 UTF-8 时按文本打印，否则打十六进制
            if (std.unicode.utf8ValidateSlice(d.payload)) {
                try out.print("payload: {s}\n", .{d.payload});
            } else {
                try out.writeAll("payload(hex): ");
                for (d.payload) |b| try out.print("{x:0>2}", .{b});
                try out.writeAll("\n");
            }
        }
        return;
    }

    // ---- 高层请求：载荷构造与参考 aicupg_client.py 逐字节一致 ----
    const task_id: u64 = blk: {
        if (getOpt(rest, "--task-id")) |v| break :blk std.fmt.parseInt(u64, v, 0) catch return error.InvalidArgument;
        break :blk 1;
    };
    const out_path = getOpt(rest, "--output") orelse getOpt(rest, "-o");

    // `--send` 时直接与 upgcmd server 会话（默认 127.0.0.1:9100）。
    // 注意：设备端口用 `--port`，服务端端口用 `--server-port`，避免同名。
    const net: ?upg_client.NetOptions = if (hasFlag(rest, "--send")) .{
        .host = getOpt(rest, "--server-host") orelse "127.0.0.1",
        .port = if (getOpt(rest, "--server-port")) |v| (std.fmt.parseInt(u16, v, 0) catch return error.InvalidArgument) else 9100,
        .timeout_ms = if (getOpt(rest, "--timeout")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else
            5000,
    } else null;

    const simple = [_]struct { name: []const u8, cmd: u8 }{
        .{ .name = "heartbeat", .cmd = upg_frame.Cmd.heartbeat },
        .{ .name = "proto-version", .cmd = upg_frame.Cmd.proto_version },
        .{ .name = "hw-info", .cmd = upg_frame.Cmd.get_hw_info },
        .{ .name = "device-list", .cmd = upg_frame.Cmd.get_device_list },
        .{ .name = "upload-dir", .cmd = upg_frame.Cmd.get_upload_dir },
        .{ .name = "cancel", .cmd = upg_frame.Cmd.cancel_burn },
        .{ .name = "help", .cmd = upg_frame.Cmd.help },
    };
    for (simple) |s| {
        if (!std.mem.eql(u8, sub, s.name)) continue;
        const payload = try upg_payload.taskOnly(aa, task_id);
        defer aa.free(payload);
        try emitUpgFrame(io, aa, out, s.cmd, payload, out_path, s.name, net);
        return;
    }

    if (std.mem.eql(u8, sub, "config-device")) {
        const port = getOpt(rest, "--port") orelse return error.MissingArgument;
        const baud: u32 = if (getOpt(rest, "--baudrate")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else
            0;
        const payload = try upg_payload.configDevice(aa, task_id, port, baud);
        defer aa.free(payload);
        try emitUpgFrame(io, aa, out, upg_frame.Cmd.config_device, payload, out_path, "config-device", net);
        return;
    }

    if (std.mem.eql(u8, sub, "burn")) {
        const image_path = getOpt(rest, "--image") orelse getOpt(rest, "-i") orelse return error.MissingArgument;
        const normalized = try upg_payload.normalizePath(aa, image_path);
        defer aa.free(normalized);
        const partition_mode = getOpt(rest, "--partition") orelse "all";
        const payload = try upg_payload.burnImage(
            aa,
            task_id,
            normalized,
            !hasFlag(rest, "--no-reboot"),
            partition_mode,
        );
        defer aa.free(payload);
        try emitUpgFrame(io, aa, out, upg_frame.Cmd.burn_image, payload, out_path, "burn", net);
        return;
    }

    if (std.mem.eql(u8, sub, "send-cmd")) {
        const command = getOpt(rest, "--command") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const payload = try upg_payload.sendCmd(aa, task_id, command);
        defer aa.free(payload);
        try emitUpgFrame(io, aa, out, upg_frame.Cmd.send_cmd, payload, out_path, "send-cmd", net);
        return;
    }

    if (std.mem.eql(u8, sub, "get-log")) {
        const timeout: u32 = if (getOpt(rest, "--timeout")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else
            5;
        const payload = try upg_payload.getLog(aa, task_id, timeout);
        defer aa.free(payload);
        try emitUpgFrame(io, aa, out, upg_frame.Cmd.get_log, payload, out_path, "get-log", net);
        return;
    }

    if (std.mem.eql(u8, sub, "upload-start")) {
        const file = getOpt(rest, "--file") orelse getOpt(rest, "-f") orelse return error.MissingArgument;
        const stat = std.Io.Dir.cwd().statFile(io, file, .{}) catch |err| {
            try out.print("upg upload-start: 无法读取 {s}（{s}）\n", .{ file, @errorName(err) });
            return err;
        };
        const remote_dir = getOpt(rest, "--remote-dir") orelse "C:\\temp\\aicupg_firmware\\";
        const payload = try upg_payload.uploadFirmware(aa, std.fs.path.basename(file), stat.size, remote_dir);
        defer aa.free(payload);
        try emitUpgFrame(io, aa, out, upg_frame.Cmd.upload_firmware, payload, out_path, "upload-start", net);
        return;
    }

    try out.print("upg: 未知子命令 {s}（可用 frame / decode / 见 wk upg 无参帮助）\n", .{sub});
    return error.UnknownCommand;
}

/// 打印（并按需落盘）一帧；给了 `net` 就发到 upgcmd server 并打印响应。
fn emitUpgFrame(
    io: std.Io,
    aa: std.mem.Allocator,
    out: *std.Io.Writer,
    cmd: u8,
    payload: []const u8,
    out_path: ?[]const u8,
    label: []const u8,
    net: ?upg_client.NetOptions,
) !void {
    const frame = try upg_frame.encode(aa, cmd, payload);
    defer aa.free(frame);
    if (out_path) |p| {
        try writeBytes(io, p, frame);
        try out.print("upg {s}: cmd=0x{x:0>2} payload={d} B frame={d} B -> {s}\n", .{ label, cmd, payload.len, frame.len, p });
    }
    for (frame) |b| try out.print("{x:0>2}", .{b});
    try out.writeAll("\n");

    const opt = net orelse return;
    var session = upg_client.Session.connect(aa, opt) catch |err| {
        try out.print("upg: 连接 {s}:{d} 失败（{s}）\n", .{ opt.host, opt.port, @errorName(err) });
        return err;
    };
    defer session.deinit();

    const resp = session.request(aa, cmd, payload) catch |err| {
        try out.print(
            "upg: 请求 cmd=0x{x:0>2} 失败（{s}；host={s}:{d}）\n",
            .{ cmd, @errorName(err), opt.host, opt.port },
        );
        return err;
    };
    defer aa.free(resp);

    try out.print("resp: cmd=0x{x:0>2} payload={d} B\n", .{ cmd | upg_frame.Cmd.rsp_mask, resp.len });
    if (resp.len > 0) {
        if (std.unicode.utf8ValidateSlice(resp)) {
            try out.print("{s}\n", .{resp});
        } else {
            for (resp) |b| try out.print("{x:0>2}", .{b});
            try out.writeAll("\n");
        }
    }
}

fn cmdFs(io: std.Io, aa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len == 0) return error.MissingArgument;
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "install")) {
        const src = getOpt(rest, "--src") orelse getOpt(rest, "-s") orelse return error.MissingArgument;
        const dst = getOpt(rest, "--dst") orelse getOpt(rest, "-d") orelse return error.MissingArgument;
        const sdkout = getOpt(rest, "--sdkout") orelse getOpt(rest, "-o");
        fsinstall.install(aa, io, src, dst, sdkout) catch |err| {
            try out.print("fs install 失败：{s}（src={s} dst={s}）\n", .{ @errorName(err), src, dst });
            return err;
        };
        try out.print("fs install: {s} -> {s}\n", .{ src, dst });
        return;
    }

    if (std.mem.eql(u8, sub, "clean")) {
        const list = getOpt(rest, "--clean") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const sdkout = getOpt(rest, "--sdkout") orelse getOpt(rest, "-o");
        fsinstall.clean(aa, io, list, sdkout) catch |err| {
            try out.print("fs clean 失败：{s}（list={s}）\n", .{ @errorName(err), list });
            return err;
        };
        try out.print("fs clean: {s}\n", .{list});
        return;
    }

    try out.print("fs: 未知子命令 {s}（可用 install / clean）\n", .{sub});
    return error.UnknownCommand;
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
        \\  image pack --config <json> [--datadir <dir>] [-o out.img] [--compare <ref.img>]
        \\            或 --sdk-output <C-SDK-images-dir>（自动取其中的 image_cfg.json 与组件）
        \\  image itb --kernel <bin> [--fdt <dtb>] [--ramdisk <bin>] [--load 0x...] [--entry 0x...] [-o out.itb]
        \\            或 --its <xxx.its> [--keydir <dir>] [--keydest <dtb>] [-r] [--timestamp <u32>] [-o out.itb]
        \\  image pagetable --input <spl.bin> [--page 2] [--block 128] [--planes 1] [-o page.bin]
        \\  image crypt --input <bin> --key <32hex> --iv <32hex> [--decrypt] [--pad zero|pkcs7] [-o out.bin]
        \\  image fitinfo --input <itb> [--dump] [--verify]
        \\  image fat --input-dir <dir> --output <img> --size <bytes> [--sector 512] [--cluster 8] [--label NAME]
        \\          （--auto 可省略 --size，按内容估算，等价 makefatfs.py -a；--fullpart 读 partition_file_list.h；--fat32 强制 FAT32）
        \\  image rsasign --input <file> --key <priv.pem> [-o sig.bin]
        \\  image rsaverify --input <file> --key <pub.pem> --sig <sig.bin>
        \\  image simg --input <raw> [--output <sparse>] [--block 4096] [--unsparse]
        \\  image simg --input <sparse> --dump            # 打印头与 chunk 表
        \\  image cpio --list <file> --input-dir <dir> -o <ota.cpio> [--format crc|newc] [--mtime 0]
        \\  image merge --output <file> --input <file> [--input <file> ...]
        \\  image ota --ota-cfg <ota-subimgs.cfg> --image-cfg <image_cfg.json> [--input-dir <dir>] [--out-dir <dir>]
        \\  image linkaddr --config <.config> --input <image_cfg.json> [--output <json>]
        \\  image linksize --map <file.map> [--out-dir <dir>]
        \\  image partlist --config <image_cfg.json> --output <partition_file_list.h>
        \\  image partcheck -c <image_cfg.json> -d <packed-dir> [-t 90] [--strict]
        \\  image littlefs -i <dir> -o <image.lfs> -b <block> [-p <page>] [-s <size>] [-r <n>] [--all]
        \\  image pbp -i <pbp.bin> -o <out.bin> [-m PBP2] [-k <pnk.bin>]
        \\  image privres -c <cfg.json> [-l <cfg2.json,cfg3.json>] [-o <out.bin>]
        \\  image aicimage -c <image_cfg.json> -d <datadir> [-k <keydir>]   (AIC 启动镜像 v2：签名/加密)
        \\  image preproc -c <image_cfg.json> -d <datadir> [-k <keydir>] [--tooldir <dir>] [--timestamp <u32>]   (整条 pre-process 流水线)
        \\  image rsakey -r <key.pem|der> [--aes-key <16B> | --des-key <8B>] [-o <outdir>]
        \\  image uffs -i <dir> -o <img> -g <blockpages> -p <page> -s <oob> [-t <tooldir>]   (调厂商 mkuffs，与 SDK 用法一致)
        \\  image fwenc --key <k> [--nonce <n>] [--tweak <t>] --infile <i> --outfile <o> [-t <tooldir>]   (调 firmware_security_encrypt)
        \\  image flashpack [--config <image_cfg.json>] [--payload-dir <dir>] [--out-dir <dir>]
        \\  image dump <file>
        \\
        \\  fs install -s <src> -d <dst> [-o <sdkout>]
        \\  fs clean -c <path1,path2> [-o <sdkout>]
        \\  sdk-update --root <SDK 根目录>     修复 target/**/*pinmux.c（等价 sdk_update.py）
        \\  rtt2freertos <defconfig> [-o <out>] [--dry-run] [--sysname aic]
        \\                                    rt-thread 方案 → freertos 方案（等价 rtt2freertos.py）
        \\  upg frame --cmd <n> [--payload <text>|--payload-file <f>] [-o out.bin]
        \\  upg decode -i <frame.bin>        upgcmd 帧协议编解码（AA55/CRC16-CCITT/55AA）
        \\  panic -l <panic.log> [-e <elf>] [-c riscv|csky] [--addr2line <tool>]
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
        var cfg_owned: ?[]u8 = null;
        defer if (cfg_owned) |p| aa.free(p);
        const sdk_output = getOpt(rest, "--sdk-output");
        const cfg_path = if (sdk_output) |dir| blk: {
            cfg_owned = try std.fs.path.join(aa, &.{ dir, "image_cfg.json" });
            break :blk cfg_owned.?;
        } else getOpt(rest, "--config") orelse return error.MissingArgument;
        const datadir = sdk_output orelse getOpt(rest, "--datadir") orelse (std.fs.path.dirname(cfg_path) orelse ".");
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

        if (getOpt(rest, "--compare")) |ref_path| {
            const ref = try readBytes(io, aa, ref_path);
            defer aa.free(ref);
            const cmp = pack.compareBytes(ref, bytes);
            try out.print(
                "对比: 参考 {d} B / Zig {d} B，DIFF={d}",
                .{ cmp.ref_len, cmp.zig_len, cmp.diff },
            );
            if (cmp.first) |off| try out.print("，首个差异 @0x{X}", .{off});
            try out.writeByte('\n');
            if (cmp.diff != 0) return error.FirmwareMismatch;
        }
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
        // `-K/--keydest`：把 keydir 里的公钥注入**已存在**的目标 DTB（等价 mkimage -K /
        // u-boot `rsa_add_verify_data`），与 ITS 构建互不干扰。
        if (getOpt(rest, "--keydest") orelse getOpt(rest, "-K")) |keydest| {
            const keydir = getOpt(rest, "--keydir") orelse getOpt(rest, "-k") orelse
                return error.MissingArgument;
            const require_keys = hasFlag(rest, "--require-keys") or hasFlag(rest, "-r");
            const n = try its.injectPubkeys(aa, io, keydir, keydest, require_keys);
            try out.print("公钥注入: {s}（{d} 个密钥，keydir={s}）\n", .{ keydest, n, keydir });
            return;
        }

        if (getOpt(rest, "--its")) |its_path| {
            var parsed = try its.parse(aa, io, its_path);
            defer parsed.deinit();

            const timestamp = parseOptionalU32(rest, "--timestamp") orelse currentTimestamp(io);
            // 与参考 build_itb 同序：先 cipher（密文覆盖 hash 值）再签名（image → config）。
            if (getOpt(rest, "--keydir") orelse getOpt(rest, "-k")) |keydir| {
                const encrypted = try its.cipherImages(&parsed, aa, io, keydir);
                const signed = try its.signImages(&parsed, aa, io, keydir, timestamp);
                const signed_cfg = try its.signConfigurations(&parsed, aa, io, keydir, timestamp);
                if (encrypted + signed + signed_cfg > 0) {
                    try out.print("加密 {d} 个镜像 / 签名 {d} 个镜像 / 签名 {d} 个配置（keydir={s}）\n", .{
                        encrypted, signed, signed_cfg, keydir,
                    });
                }
            }
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
        const fullpart = hasFlag(rest, "--fullpart");
        // 参考 `-r/--raw` 表示「不把镜像裁剪到内容大小」。我们本来就按给定大小/分区大小
        // 分配，从不裁剪，因此该开关等价于默认行为；此处接受以兼容既有构建脚本。
        const _raw = hasFlag(rest, "--raw") or hasFlag(rest, "-r");
        _ = _raw;
        // 参考 `makefatfs.py` 的 NFTL 预留块：仅当该镜像属于 nftl 分区时生效。
        const reserved_blocks: ?u64 = if (getOpt(rest, "--reserved") orelse getOpt(rest, "-b")) |v|
            (std.fmt.parseInt(u64, v, 0) catch return error.InvalidArgument)
        else
            null;
        const is_nftl = partitionIsNftl(io, aa, output) catch false;
        const nftl_reserved: u64 = if (is_nftl) blk: {
            const blocks: u64 = if (reserved_blocks) |n| (if (n > 50) n + 1 else 51) else 51;
            break :blk blocks * 64 * 2048;
        } else 0;

        const size_text = getOpt(rest, "--size") orelse (if (auto or fullpart) "0" else return error.MissingArgument);
        var total_bytes = aic.utils.sizeStrToInt(size_text) catch return error.InvalidArgument;
        if (fullpart or (auto and is_nftl)) {
            const part_size = try partitionSizeForImage(io, aa, output);
            if (is_nftl) {
                if (part_size <= nftl_reserved) {
                    try out.print("FAT: 分区 {d} B 不大于 NFTL 预留 {d} B（{s}）\n", .{ part_size, nftl_reserved, output });
                    return error.PartitionTooSmall;
                }
                total_bytes = part_size - nftl_reserved;
            } else {
                total_bytes = part_size;
            }
        }
        const sector: u16 = if (getOpt(rest, "--sector")) |v| @intCast(std.fmt.parseInt(usize, v, 0) catch return error.InvalidArgument) else 512;
        const cluster: u8 = if (getOpt(rest, "--cluster")) |v| @intCast(std.fmt.parseInt(usize, v, 0) catch return error.InvalidArgument) else 8;

        var builder = try fat.Builder.init(aa, .{
            .total_bytes = total_bytes,
            .sector_size = sector,
            .cluster_sectors = cluster,
            .volume_label = getOpt(rest, "--label") orelse "NO NAME",
            .mtime = if (getOpt(rest, "--mtime")) |v| @intCast(std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument) else 0,
            .fat32 = hasFlag(rest, "--fat32"),
        });
        defer builder.deinit();

        builder.addTreeFromDir(io, input_dir) catch |err| {
            try out.print("读取目录失败（{s}）：{s}\n", .{ input_dir, @errorName(err) });
            return;
        };

        if (auto) {
            // auto + NFTL：参考以「分区大小 - 预留」为最终尺寸（autoTotalBytes 的结果不参与）
            if (!(is_nftl)) builder.opts.total_bytes = try builder.autoTotalBytes();
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
        if (hasFlag(rest, "--dump")) {
            try sparse.dump(out, input, data);
            return;
        }
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

    if (std.mem.eql(u8, sub, "merge")) {
        const output = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse return error.MissingArgument;
        var inputs: std.ArrayList([]const u8) = .empty;
        defer inputs.deinit(aa);
        try collectOpts(rest, aa, "--input", &inputs);
        try collectOpts(rest, aa, "-i", &inputs);
        if (inputs.items.len == 0) return error.MissingArgument;

        var blobs: std.ArrayList([]u8) = .empty;
        defer {
            for (blobs.items) |b| aa.free(b);
            blobs.deinit(aa);
        }
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(aa);
        var total: usize = 0;
        for (inputs.items) |path| {
            const data = try readBytes(io, aa, path);
            total += data.len;
            try blobs.append(aa, data);
            try parts.append(aa, data);
        }

        const merged = try merge.merge(aa, parts.items);
        defer aa.free(merged);
        try ensureParentDir(io, output);
        try writeBytes(io, output, merged);
        try out.print("merge: {d} 个文件 -> {s}（{d} bytes）\n", .{ inputs.items.len, output, total });
        return;
    }

    if (std.mem.eql(u8, sub, "ota")) {
        const ota_cfg = getOpt(rest, "--ota-cfg") orelse return error.MissingArgument;
        const image_cfg_path = getOpt(rest, "--image-cfg") orelse return error.MissingArgument;
        const out_dir = getOpt(rest, "--out-dir") orelse IMAGE_DIR;
        const input_dir = getOpt(rest, "--input-dir") orelse out_dir;
        const mtime = parseU32Opt(rest, "--mtime", 0) catch return error.InvalidArgument;

        var result = ota.run(aa, io, .{
            .ota_cfg = ota_cfg,
            .image_cfg = image_cfg_path,
            .input_dir = input_dir,
            .out_dir = out_dir,
            .mtime = mtime,
        }) catch |err| {
            try out.print("ota 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        defer result.deinit(aa);
        try out.print("ota: version {s}，{d} 个文件，ota.cpio {d} bytes -> {s}\n", .{
            result.version, result.files, result.archive.len, out_dir,
        });
        return;
    }

    if (std.mem.eql(u8, sub, "linkaddr")) {
        const config_path = getOpt(rest, "--config") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const input = getOpt(rest, "--input") orelse getOpt(rest, "-i") orelse return error.MissingArgument;
        const output = getOpt(rest, "-o") orelse getOpt(rest, "--output") orelse blk: {
            break :blk try std.fmt.allocPrint(aa, "{s}.tmp", .{input});
        };
        defer if (getOpt(rest, "-o") == null and getOpt(rest, "--output") == null) aa.free(output);

        const config = try readText(io, aa, config_path);
        defer aa.free(config);
        const image_cfg_text = try readText(io, aa, input);
        defer aa.free(image_cfg_text);

        const rewritten = linkaddr.rewrite(aa, config, image_cfg_text) catch |err| {
            try out.print("linkaddr 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        defer aa.free(rewritten);
        try ensureParentDir(io, output);
        try writeText(io, output, rewritten);
        const v = linkaddr.calculate(config) catch unreachable;
        try out.print("linkaddr: text=0x{x} load=0x{x} -> {s}\n", .{ v.text, v.load, output });
        return;
    }

    if (std.mem.eql(u8, sub, "linksize")) {
        const map_path = getOpt(rest, "--map") orelse getOpt(rest, "-m") orelse return error.MissingArgument;
        const out_dir = getOpt(rest, "--out-dir");
        const result = linksize.run(aa, io, map_path, out_dir) catch |err| {
            try out.print("linksize 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        defer {
            aa.free(result.summary);
            aa.free(result.detail);
            aa.free(result.dironly);
        }
        try out.print("linksize: 已生成 <base>.summary.csv / .detail.csv / .dironly.csv\n", .{});
        return;
    }

    if (std.mem.eql(u8, sub, "extract")) {
        const img = if (rest.len > 0 and !std.mem.startsWith(u8, rest[0], "-")) rest[0] else
            (getOpt(rest, "--input") orelse getOpt(rest, "-i") orelse return error.MissingArgument);
        const out_dir = getOpt(rest, "--output") orelse getOpt(rest, "-o");
        const res = aic.fwextract.extract(aa, io, img, out_dir) catch |err| {
            try out.print("extract 失败：{s}（img={s}）\n", .{ @errorName(err), img });
            return err;
        };
        defer res.deinit(aa);
        for (res.entries) |e| {
            try out.print("  {s} {d} B\n", .{ e.name, e.size });
        }
        try out.print("解包: {s}（{d} 个组件", .{ res.out_dir, res.entries.len });
        if (res.tar_entries > 0) try out.print("，其中 tar 解出 {d} 个", .{res.tar_entries});
        try out.writeAll("）\n");
        return;
    }

    if (std.mem.eql(u8, sub, "uffs")) {
        const input_dir = getOpt(rest, "--input") orelse getOpt(rest, "-i") orelse return error.MissingArgument;
        const out_file = getOpt(rest, "--output") orelse getOpt(rest, "-o") orelse return error.MissingArgument;
        const block_pages = std.fmt.parseInt(u64, getOpt(rest, "--blockpagecount") orelse getOpt(rest, "-g") orelse
            return error.MissingArgument, 0) catch return error.InvalidArgument;
        const page_size = std.fmt.parseInt(u64, getOpt(rest, "--pagesize") orelse getOpt(rest, "-p") orelse
            return error.MissingArgument, 0) catch return error.InvalidArgument;
        const oob_size = std.fmt.parseInt(u64, getOpt(rest, "--oobsize") orelse getOpt(rest, "-s") orelse
            return error.MissingArgument, 0) catch return error.InvalidArgument;
        const tool_dir = getOpt(rest, "--tooldir") orelse getOpt(rest, "-t");

        const res = aic.uffs.run(aa, io, .{
            .input_dir = input_dir,
            .out_file = out_file,
            .block_pages = block_pages,
            .page_size = page_size,
            .oob_size = oob_size,
            .tool_dir = tool_dir,
        }) catch |err| {
            try out.print("uffs 失败：{s}（in={s}, out={s}, page={d}, block_pages={d}, oob={d}, tooldir={s}）\n", .{
                @errorName(err), input_dir, out_file, page_size, block_pages, oob_size, tool_dir orelse "(PATH)",
            });
            return err;
        };
        defer aa.free(res.output);
        try out.print("UFFS: {s}（分区 {d} B / {d} 块，page={d}, block_pages={d}, oob={d}）\n", .{
            res.output, res.part_size, res.part_blocks, page_size, block_pages, oob_size,
        });
        return;
    }

    if (std.mem.eql(u8, sub, "fwenc")) {
        const key = getOpt(rest, "--key") orelse getOpt(rest, "-k") orelse return error.MissingArgument;
        const input = getOpt(rest, "--infile") orelse getOpt(rest, "-i") orelse return error.MissingArgument;
        const output = getOpt(rest, "--outfile") orelse getOpt(rest, "-o") orelse return error.MissingArgument;
        const tool_dir = getOpt(rest, "--tooldir") orelse getOpt(rest, "-t");

        aic.fwenc.run(aa, io, .{
            .key = key,
            .nonce = getOpt(rest, "--nonce") orelse getOpt(rest, "-n"),
            .tweak = getOpt(rest, "--tweak"),
            .input = input,
            .output = output,
            .tool_dir = tool_dir,
        }) catch |err| {
            try out.print("fwenc 失败：{s}（key={s}, in={s}, out={s}, tooldir={s}）\n", .{
                @errorName(err), key, input, output, tool_dir orelse "(PATH)",
            });
            return err;
        };
        try out.print("固件加密: {s} -> {s}（key={s}）\n", .{ input, output, key });
        return;
    }

    if (std.mem.eql(u8, sub, "burner")) {
        const cfg_path = getOpt(rest, "--config") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const data_dir = getOpt(rest, "--datadir") orelse getOpt(rest, "-d") orelse return error.MissingArgument;
        const out_dir = getOpt(rest, "--outdir") orelse getOpt(rest, "-o") orelse data_dir;

        var res = aic.burner.build(aa, io, cfg_path, data_dir, out_dir) catch |err| {
            try out.print("burner 失败：{s}（cfg={s}, datadir={s}, outdir={s}）\n", .{
                @errorName(err), cfg_path, data_dir, out_dir,
            });
            return err;
        };
        defer res.deinit(aa);
        for (res.files, res.sizes) |f, sz| {
            try out.print("  {s} {d} B\n", .{ f, sz });
        }
        try out.print("burner: {d} 个文件 -> {s}\n", .{ res.files.len, out_dir });
        return;
    }

    if (std.mem.eql(u8, sub, "partlist")) {
        const cfg_path = getOpt(rest, "--config") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const output = getOpt(rest, "--output") orelse getOpt(rest, "-o") orelse return error.MissingArgument;
        const text = partlist.generate(aa, io, cfg_path) catch |err| {
            try out.print("partlist 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        defer aa.free(text);
        try ensureParentDir(io, output);
        try writeText(io, output, text);
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len > 0) lines += 1;
        }
        try out.print("partlist: {d} 项 -> {s}\n", .{ lines, output });
        return;
    }

    if (std.mem.eql(u8, sub, "partcheck")) {
        const cfg_path = getOpt(rest, "--config") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const dir_path = getOpt(rest, "--dir") orelse getOpt(rest, "-d") orelse return error.MissingArgument;
        const threshold: f64 = if (getOpt(rest, "--threshold")) |v|
            (std.fmt.parseFloat(f64, v) catch return error.InvalidArgument)
        else if (getOpt(rest, "-t")) |v|
            (std.fmt.parseFloat(f64, v) catch return error.InvalidArgument)
        else
            90;
        var result = partcheck.run(aa, io, cfg_path, dir_path, threshold) catch |err| {
            try out.print("partcheck 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        defer partcheck.deinitResult(aa, &result);
        try out.writeAll(result.text);
        if (hasFlag(rest, "--strict") and result.overflow > 0) return partcheck.Error.PartitionOverflow;
        return;
    }

    if (std.mem.eql(u8, sub, "pbp")) {
        const input = getOpt(rest, "--input") orelse getOpt(rest, "-i") orelse return error.MissingArgument;
        const output = getOpt(rest, "--output") orelse getOpt(rest, "-o") orelse return error.MissingArgument;
        const magic = getOpt(rest, "--magic") orelse getOpt(rest, "-m") orelse "PBP2";
        const pnk = getOpt(rest, "--pnk") orelse getOpt(rest, "-k");
        const result = preboot.build(aa, io, .{
            .input = input,
            .output = output,
            .magic = magic,
            .pnk = pnk,
        }) catch |err| {
            try out.print("pbp 失败：{s}（input={s}）\n", .{ @errorName(err), input });
            return err;
        };
        try out.print(
            "pbp: {s}（输入 {d} B，对齐后 {d} B，加密={s}）\n",
            .{ output, result.input_size, result.padded_size, if (result.encrypted) "是" else "否" },
        );
        return;
    }

    if (std.mem.eql(u8, sub, "privres")) {
        const cfg = getOpt(rest, "--config") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(aa);
        try paths.append(aa, cfg);
        if (getOpt(rest, "--config-list") orelse getOpt(rest, "-l")) |list| {
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |p| {
                const trimmed = std.mem.trim(u8, p, " \t\r\n");
                if (trimmed.len > 0) try paths.append(aa, trimmed);
            }
        }
        const output = if (getOpt(rest, "--output") orelse getOpt(rest, "-o")) |p|
            p
        else blk: {
            const dot = std.mem.lastIndexOfScalar(u8, paths.items[0], '.') orelse paths.items[0].len;
            break :blk try std.fmt.allocPrint(aa, "{s}.bin", .{paths.items[0][0..dot]});
        };
        defer if ((getOpt(rest, "--output") orelse getOpt(rest, "-o")) == null) aa.free(output);

        const data = privres.build(aa, io, paths.items) catch |err| {
            try out.print("privres 失败：{s}（config={s}）\n", .{ @errorName(err), cfg });
            return err;
        };
        defer aa.free(data);
        try writeBytes(io, output, data);
        try out.print("privres: {d} B -> {s}\n", .{ data.len, output });
        return;
    }

    if (std.mem.eql(u8, sub, "aicimage")) {
        const cfg = getOpt(rest, "--config") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const datadir = getOpt(rest, "--datadir") orelse getOpt(rest, "-d") orelse return error.MissingArgument;
        const keydir = getOpt(rest, "--keydir") orelse getOpt(rest, "-k");
        const gens = aicboot.preprocess(aa, io, .{
            .cfg_path = cfg,
            .datadir = datadir,
            .keydir = keydir,
        }) catch |err| {
            try out.print("aicimage 失败：{s}（config={s}，datadir={s}）\n", .{ @errorName(err), cfg, datadir });
            return err;
        };
        defer {
            for (gens) |g| aa.free(g.name);
            aa.free(gens);
        }
        for (gens) |g| {
            try out.print("aicimage: {s} {d} B\n", .{ g.name, g.size });
        }
        return;
    }

    if (std.mem.eql(u8, sub, "preproc")) {
        const cfg = getOpt(rest, "--config") orelse getOpt(rest, "-c") orelse return error.MissingArgument;
        const datadir = getOpt(rest, "--datadir") orelse getOpt(rest, "-d") orelse return error.MissingArgument;
        const keydir = getOpt(rest, "--keydir") orelse getOpt(rest, "-k");
        const ts = parseOptionalU32(rest, "--timestamp") orelse currentTimestamp(io);
        const steps = preproc.run(aa, io, .{
            .cfg_path = cfg,
            .datadir = datadir,
            .keydir = keydir,
            .timestamp = ts,
            .tool_dir = getOpt(rest, "--tooldir"),
        }) catch |err| {
            try out.print("preproc 失败：{s}（config={s}，datadir={s}）\n", .{ @errorName(err), cfg, datadir });
            return err;
        };
        defer {
            for (steps) |s| aa.free(s.name);
            aa.free(steps);
        }
        for (steps) |s| {
            try out.print("preproc[{s}]: {s} {d} B\n", .{ s.proc, s.name, s.size });
        }
        return;
    }

    if (std.mem.eql(u8, sub, "rsakey")) {
        const key_path = getOpt(rest, "--rsa") orelse getOpt(rest, "-r") orelse return error.MissingArgument;
        const aes_path = getOpt(rest, "--aes-key") orelse getOpt(rest, "-a");
        const des_path = getOpt(rest, "--des-key") orelse getOpt(rest, "-d");
        if (aes_path != null and des_path != null) {
            try out.writeAll("rsakey: --aes-key 与 --des-key 只能给一个\n");
            return error.InvalidArgument;
        }

        const data = try readBytes(io, aa, key_path);
        defer aa.free(data);
        var key = rsa_key.loadKey(aa, data) catch |err| {
            try out.print("rsakey 解析密钥失败：{s}（{s}）\n", .{ @errorName(err), key_path });
            return err;
        };
        defer key.deinit(aa);

        // 输出基名：与参考脚本一致，取密钥文件去扩展名的路径。
        const dot = std.mem.lastIndexOfScalar(u8, std.fs.path.basename(key_path), '.');
        const stem = if (dot) |d| key_path[0 .. key_path.len - (std.fs.path.basename(key_path).len - d)] else key_path;
        const out_dir = getOpt(rest, "--out-dir") orelse getOpt(rest, "-o");

        if (aes_path == null and des_path == null) {
            const der = try rsa_key.buildPublicDer(aa, key.n, key.e);
            defer aa.free(der);
            const path = try joinOutPath(aa, out_dir, stem, "_pubkey_pkcs1.der");
            defer aa.free(path);
            try writeBytes(io, path, der);
            try out.print("rsakey: {s}（PKCS#1 公钥 {d} B，kind={s}）\n", .{ path, der.len, @tagName(key.kind) });
            return;
        }

        const sym_bytes_path = aes_path orelse des_path.?;
        const sym_data = try readBytes(io, aa, sym_bytes_path);
        defer aa.free(sym_data);
        const sym = rsa_key.SymKey.fromBytes(sym_data) catch |err| {
            try out.print(
                "rsakey 读取对称密钥失败：{s}（{s}，{d} B，需 16 B AES 或 8 B DES）\n",
                .{ @errorName(err), sym_bytes_path, sym_data.len },
            );
            return err;
        };

        var enc = rsa_key.encryptKey(aa, &key, sym) catch |err| {
            try out.print("rsakey 加密密钥失败：{s}（{s}）\n", .{ @errorName(err), key_path });
            return err;
        };
        defer enc.deinit(aa);

        const path = try joinOutPath(aa, out_dir, stem, "_encrypted.der");
        defer aa.free(path);
        try writeBytes(io, path, enc.main_der);
        try out.print(
            "rsakey: {s}（kind={s}，{d} B，{s}-ECB）\n",
            .{ path, @tagName(key.kind), enc.main_der.len, if (aes_path != null) "AES-128" else "DES" },
        );
        if (enc.extra_pkcs1_der) |extra| {
            const extra_path = try joinOutPath(aa, out_dir, stem, "_encrypted_pkcs1.der");
            defer aa.free(extra_path);
            try writeBytes(io, extra_path, extra);
            try out.print("rsakey: {s}（{d} B）\n", .{ extra_path, extra.len });
        }
        return;
    }

    if (std.mem.eql(u8, sub, "littlefs")) {
        const input = getOpt(rest, "--input") orelse getOpt(rest, "-i") orelse return error.MissingArgument;
        const output = getOpt(rest, "--output") orelse getOpt(rest, "-o") orelse return error.MissingArgument;
        const block_text = getOpt(rest, "--block") orelse getOpt(rest, "-b") orelse return error.MissingArgument;
        const block = std.fmt.parseInt(u32, block_text, 0) catch return error.InvalidArgument;
        const page: u32 = if (getOpt(rest, "--page")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else if (getOpt(rest, "-p")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else
            256;
        const image_size: ?u32 = if (getOpt(rest, "--size")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else if (getOpt(rest, "-s")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else
            null;
        const reserved: ?u32 = if (getOpt(rest, "--reserved")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else if (getOpt(rest, "-r")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return error.InvalidArgument)
        else
            null;

        const result = littlefs.build(aa, io, .{
            .input_dir = input,
            .output = output,
            .block_size = block,
            .page_size = page,
            .image_size = image_size,
            .reserved = reserved,
            .add_all = hasFlag(rest, "--all"),
        }) catch |err| {
            try out.print("littlefs 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        try out.print(
            "littlefs: {s}（镜像 {d} B，裁剪后 {d} B）\n",
            .{ output, result.image_size, result.trimmed_size },
        );
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

    if (std.mem.eql(u8, sub, "flashpack")) {
        const cfg_path = getOpt(rest, "--config") orelse "wk/target/d13x/demo88-nor/pack/image_cfg.json";
        const payload_dir = getOpt(rest, "--payload-dir") orelse try std.fs.path.join(aa, &.{ IMAGE_DIR, "demo" });
        const out_dir = getOpt(rest, "--out-dir") orelse try std.fs.path.join(aa, &.{ IMAGE_DIR, "flash" });

        var result = flashpack.run(aa, io, .{
            .cfg_path = cfg_path,
            .payload_dir = payload_dir,
            .out_dir = out_dir,
        }) catch |err| {
            try out.print("flashpack 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        defer result.deinit(aa);

        const manifest_path = try std.fs.path.join(aa, &.{ out_dir, "manifest.txt" });
        defer aa.free(manifest_path);
        try writeBytes(io, manifest_path, result.manifest);
        const flash_md_path = try std.fs.path.join(aa, &.{ out_dir, "FLASH.md" });
        defer aa.free(flash_md_path);
        try writeBytes(io, flash_md_path, result.instructions);

        try out.print("flashpack: {s}/{s}（{d} bytes，warnings={d}）\n", .{ out_dir, result.packed_name, result.firmware.len, result.warnings });
        try out.print("  已生成 manifest.txt 与 FLASH.md\n", .{});
        if (result.missing_required != 0) {
            try out.print("  仍有 {d} 个必填组件缺失，请按 manifest.txt 补齐后重跑\n", .{result.missing_required});
            return error.MissingRequiredComponents;
        }
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

/// 收集可重复选项：`--input a --input b` 或 `--input=a`。
fn collectOpts(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    name: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, name)) {
            if (i + 1 < args.len) try out.append(allocator, args[i + 1]);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') {
            try out.append(allocator, a[name.len + 1 ..]);
        }
        i += 1;
    }
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

/// 拼接输出路径：给了 `--out-dir` 就放进该目录，否则沿用输入路径（参考脚本口径）。
fn joinOutPath(
    allocator: std.mem.Allocator,
    out_dir: ?[]const u8,
    stem_path: []const u8,
    suffix: []const u8,
) ![]u8 {
    if (out_dir) |d| {
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.fs.path.basename(stem_path), suffix });
        defer allocator.free(name);
        return std.fs.path.join(allocator, &.{ d, name });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem_path, suffix });
}

/// 该镜像是否属于 NFTL 分区（等价 `makefatfs.check_is_nftl_part`：查同目录
/// `partition.json` 的 `partitions.nftl` 是否包含 `<镜像名去扩展名>:`）。
fn partitionIsNftl(io: std.Io, allocator: std.mem.Allocator, output: []const u8) !bool {
    const dir = std.fs.path.dirname(output) orelse ".";
    const json_path = try std.fs.path.join(allocator, &.{ dir, "partition.json" });
    defer allocator.free(json_path);
    const text = readText(io, allocator, json_path) catch return false;
    defer allocator.free(text);

    const key_at = std.mem.find(u8, text, "\"nftl\"") orelse return false;
    var i = key_at + "\"nftl\"".len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == ':')) i += 1;
    if (i >= text.len or text[i] != '"') return false;
    const start = i + 1;
    const end = std.mem.findScalarPos(u8, text, start, '"') orelse return false;
    const nftl_value = text[start..end];

    const base = std.fs.path.basename(output);
    const stem = if (std.mem.findScalar(u8, base, '.')) |dot| base[0..dot] else base;
    const needle = try std.fmt.allocPrint(allocator, "{s}:", .{stem});
    defer allocator.free(needle);
    return std.mem.find(u8, nftl_value, needle) != null;
}

fn partitionSizeForImage(io: std.Io, allocator: std.mem.Allocator, output: []const u8) !u64 {
    const dir = std.fs.path.dirname(output) orelse ".";
    const list_path = try std.fs.path.join(allocator, &.{ dir, "partition_file_list.h" });
    defer allocator.free(list_path);
    const text = readText(io, allocator, list_path) catch return error.MissingPartitionSize;
    defer allocator.free(text);

    const base = std.fs.path.basename(output);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var cols: [3][]const u8 = undefined;
        var ci: usize = 0;
        var cit = std.mem.splitScalar(u8, raw, ',');
        while (cit.next()) |part| : (ci += 1) {
            if (ci < 3) cols[ci] = std.mem.trim(u8, part, " \t\r");
        }
        if (ci < 3) continue;
        var name = std.mem.trim(u8, cols[1], " \t\r\"*");
        for ([_][]const u8{ ".sparse.enc", ".sparse", ".enc" }) |suffix| {
            if (std.mem.endsWith(u8, name, suffix)) {
                name = name[0 .. name.len - suffix.len];
                break;
            }
        }
        if (!std.mem.eql(u8, name, base)) continue;
        return std.fmt.parseInt(u64, cols[2], 0) catch return error.InvalidArgument;
    }
    return error.MissingPartitionSize;
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(io, dir);
    }
}
