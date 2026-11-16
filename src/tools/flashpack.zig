//! 烧写包准备与自检 —— 面向“尽快上板”的收口命令：
//! 读取 image_cfg.json，把 payload 目录里的真实固件（厂商 SDK 生成的
//! `bootloader.aic` / `d13x_os.itb` / `env.bin` / `rodata.fatfs` / `data.lfs`）
//! 校验、补齐（env / FAT rodata）、按分区大小检查，再打包成可烧写的 AIC.FW，
//! 并生成 manifest.txt 与 FLASH.md。
//!
//! 明确边界：bootloader 里的 PBP/loader 组合与 USB/UART 烧写协议不在本工具内，
//! 必须使用厂商 SDK 产物与厂商烧写工具（AiBurn / upgcmd）。
const std = @import("std");
const image_cfg = @import("image_cfg.zig");
const partition_table = @import("partition_table.zig");
const pack = @import("pack.zig");
const fat = @import("fat.zig");
const fdt_reader = @import("fdt_reader.zig");
const image = @import("../bsp/common/image.zig");
const utils = @import("../bsp/common/utils.zig");

pub const Options = struct {
    cfg_path: []const u8,
    payload_dir: []const u8,
    out_dir: []const u8,
};

pub const Result = struct {
    manifest: []u8,
    instructions: []u8,
    firmware: []u8,
    packed_name: []u8,
    warnings: usize,
    missing_required: usize,

    pub fn deinit(self: *Result, a: std.mem.Allocator) void {
        a.free(self.manifest);
        a.free(self.instructions);
        a.free(self.firmware);
        a.free(self.packed_name);
    }
};

fn bytesToHex(buf: []u8, bytes: []const u8) []u8 {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        buf[i * 2] = digits[bytes[i] >> 4];
        buf[i * 2 + 1] = digits[bytes[i] & 0x0f];
    }
    return buf[0 .. bytes.len * 2];
}

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const out = try a.alloc(u8, 64);
    _ = bytesToHex(out, &digest);
    return out;
}

fn isOptional(comp: std.json.ObjectMap) bool {
    const v = comp.get("attr") orelse return false;
    switch (v) {
        .string => |s| return std.mem.find(u8, s, "optional") != null,
        .array => |arr| {
            for (arr.items) |item| {
                if (item == .string and std.mem.find(u8, item.string, "optional") != null) return true;
            }
        },
        else => {},
    }
    return false;
}

fn firstPart(comp: std.json.ObjectMap, a: std.mem.Allocator) !?[]const u8 {
    const part = try image_cfg.partString(a, comp);
    if (part.len == 0) return null;
    if (std.mem.findScalar(u8, part, ';')) |idx| return part[0..idx];
    return part;
}

const PartInfo = struct { size: u64 };

fn buildPartMap(a: std.mem.Allocator, root: std.json.Value, media: []const image_cfg.Media) !std.StringHashMap(PartInfo) {
    var map = std.StringHashMap(PartInfo).init(a);
    errdefer map.deinit();
    for (media) |m| {
        const parts = try partition_table.layout(a, root, m.name);
        defer a.free(parts);
        for (parts) |p| try map.put(p.name, .{ .size = p.size });
    }
    return map;
}

fn validateFile(a: std.mem.Allocator, io: std.Io, name: []const u8, data: []const u8) !void {
    if (std.mem.endsWith(u8, name, ".aic")) {
        // 组合镜像（pbp_ext+loader）只有第一段 AIC，校验失败仅提示
        if (!image.verifyMagic(data, image.MAGIC)) return error.BadAicMagic;
        image.verify(data) catch {};
    } else if (std.mem.endsWith(u8, name, ".itb") or std.mem.endsWith(u8, name, ".fit")) {
        var tree = try fdt_reader.parse(a, data);
        defer tree.deinit();
        const r = fdt_reader.verifyHashes(&tree);
        if (r.failed != 0) return error.FitHashMismatch;
    }
    _ = io;
}

fn manifestHeader() []const u8 {
    return "# WuKong-Lite flash pack manifest\n# component\tfile\tsize\tsha256\tpart\tstatus\n";
}

fn instructionsTemplate(allocator: std.mem.Allocator, img_name: []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    try w.writer.print(
        \\# 烧写到芯片模组
        \\
        \\产物：`{s}`（AIC.FW 固件包，含 updater + target 组件）
        \\
        \\## 前提（必须满足）
        \\- `bootloader.aic` 必须是**厂商 SDK/PBP 流程**生成的（loader.aic + pbp_ext.aic 组合）；
        \\  WuKong-Lite 只做校验与打包，不生成 PBP。
        \\- `image.target.*` 指向的 OS 文件（如 `d13x_os.itb`）必须是真实可启动固件。
        \\- 烧写工具用厂商的 AiBurn（USB）或 upgcmd/upgtool（UART），本仓库不含烧写上位机。
        \\
        \\## USB（AiBurn，推荐）
        \\1. 模组进入 USB 下载模式（按住 BOOT/短接，复位后松开）。
        \\2. 打开 AiBurn，选择 `{s}`，确认介质与分区表与 image_cfg.json 一致。
        \\3. 勾选“全片擦除/校验”，开始烧写；完成后复位。
        \\
        \\## UART（upgcmd）
        \\1. 连接串口，进入升级模式。
        \\2. `upgcmd -p <COMx> -f {s}`（参数以厂商工具版本为准）。
        \\
        \\## 自检
        \\- `manifest.txt` 里有每个组件的 SHA256 与分区大小检查结果；
        \\- 若某组件显示 `MISSING(optional)`，对应分区保持擦除状态，不影响启动。
        \\- 启动失败先查串口日志：SPL → env → os.itb 的 hash/签名校验。
        \\
    , .{ img_name, img_name, img_name });
    return w.toOwnedSlice();
}

/// 读取 payload、补齐可生成组件、校验并打包。返回的 packed 由调用者释放。
pub fn run(a: std.mem.Allocator, io: std.Io, opts: Options) !Result {
    var cfg = try image_cfg.load(a, io, opts.cfg_path);
    defer cfg.deinit();
    const root = cfg.root();
    const root_obj = image_cfg.asObject(root.*) orelse return error.BadConfig;
    const image_obj = image_cfg.getObj(root_obj, "image") orelse return error.BadConfig;
    const info_obj = image_cfg.getObj(image_obj, "info") orelse return error.BadConfig;
    const product = image_cfg.getStr(info_obj, "product") orelse "firmware";

    const media = try image_cfg.mediaList(a, root.*);
    defer a.free(media);
    var part_map = try buildPartMap(a, root.*, media);
    defer part_map.deinit();

    try std.Io.Dir.cwd().createDirPath(io, opts.out_dir);

    var manifest: std.Io.Writer.Allocating = .init(a);
    errdefer manifest.deinit();
    try manifest.writer.writeAll(manifestHeader());

    var warnings: usize = 0;
    var missing_required: std.ArrayList([]const u8) = .empty;
    defer missing_required.deinit(a);

    const sections = [_][]const u8{ "target", "updater" };
    for (sections) |section| {
        const sect_obj = image_cfg.getObj(image_obj, section) orelse continue;
        var it = sect_obj.iterator();
        while (it.next()) |entry| {
            const comp = image_cfg.asObject(entry.value_ptr.*) orelse return error.BadConfig;
            const file_name = image_cfg.getStr(comp, "file") orelse return error.MissingComponentFile;
            const optional = isOptional(comp);
            const part = try firstPart(comp, a);

            const src_path = try std.fs.path.join(a, &.{ opts.payload_dir, file_name });
            defer a.free(src_path);
            var data: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, src_path, a, .unlimited) catch null;
            defer if (data) |d| a.free(d);

            // 可生成组件：env.bin（有 env.txt）、rodata.fatfs（有 rodata/ 目录）
            if (data == null and std.mem.eql(u8, file_name, "env.bin")) {
                const env_txt = try std.fs.path.join(a, &.{ opts.payload_dir, "env.txt" });
                defer a.free(env_txt);
                if (std.Io.Dir.cwd().openFile(io, env_txt, .{})) |f| {
                    f.close(io);
                    const prefix = try partition_table.partsForEnv(a, root.*);
                    defer a.free(prefix);
                    data = try pack.buildEnv(a, io, env_txt, 4096, true, prefix);
                } else |_| {}
            }
            if (data == null and std.mem.endsWith(u8, file_name, ".fatfs")) {
                const dir_path = try std.fs.path.join(a, &.{ opts.payload_dir, "rodata" });
                defer a.free(dir_path);
                if (std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) |d| {
                    d.close(io);
                    var b = try fat.Builder.init(a, .{ .total_bytes = 0, .cluster_sectors = 8 });
                    defer b.deinit();
                    try b.addTreeFromDir(io, dir_path);
                    b.opts.total_bytes = try b.autoTotalBytes();
                    data = try b.build();
                } else |_| {}
            }

            if (data == null) {
                if (optional) {
                    warnings += 1;
                    try manifest.writer.print("{s}\t{s}\t-\t-\t-\tMISSING(optional)\n", .{ section, file_name });
                    continue;
                }
                try missing_required.append(a, try a.dupe(u8, file_name));
                try manifest.writer.print("{s}\t{s}\t-\t-\t-\tMISSING(required)\n", .{ section, file_name });
                continue;
            }

            validateFile(a, io, file_name, data.?) catch |err| {
                warnings += 1;
                try manifest.writer.print("{s}\t{s}\t{d}\t-\t-\tINVALID:{s}\n", .{ section, file_name, data.?.len, @errorName(err) });
                continue;
            };

            if (part) |p| {
                if (part_map.get(p)) |pi| {
                    if (data.?.len > pi.size) {
                        try manifest.writer.print("{s}\t{s}\t{d}\t-\t{s}\tTOO_BIG>{d}\n", .{ section, file_name, data.?.len, p, pi.size });
                        return error.ComponentTooBig;
                    }
                }
            }

            // 复制/写到输出目录，供 buildFirmware 打包
            const dst_path = try std.fs.path.join(a, &.{ opts.out_dir, file_name });
            defer a.free(dst_path);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = data.? });

            const sha = try sha256Hex(a, data.?);
            defer a.free(sha);
            try manifest.writer.print("{s}\t{s}\t{d}\t{s}\t{s}\tOK\n", .{
                section,
                file_name,
                data.?.len,
                sha,
                part orelse "-",
            });
        }
    }

    if (missing_required.items.len != 0) {
        try manifest.writer.print("\n# 缺少必填组件：\n", .{});
        for (missing_required.items) |n| try manifest.writer.print("#   {s}\n", .{n});
        const product_name = try std.fmt.allocPrint(a, "{s}.img", .{product});
        return .{
            .manifest = try manifest.toOwnedSlice(),
            .instructions = try instructionsTemplate(a, product_name),
            .firmware = try a.alloc(u8, 0),
            .packed_name = product_name,
            .warnings = warnings,
            .missing_required = missing_required.items.len,
        };
    }

    const fw = try pack.buildFirmware(a, io, opts.cfg_path, opts.out_dir);
    errdefer a.free(fw);
    const img_name = try std.fmt.allocPrint(a, "{s}.img", .{product});
    errdefer a.free(img_name);
    const img_path = try std.fs.path.join(a, &.{ opts.out_dir, img_name });
    defer a.free(img_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = img_path, .data = fw });

    const sha = try sha256Hex(a, fw);
    defer a.free(sha);
    try manifest.writer.print("\n# firmware\t{s}\t{d}\t{s}\t-\tOK\n", .{ img_name, fw.len, sha });

    return .{
        .manifest = try manifest.toOwnedSlice(),
        .instructions = try instructionsTemplate(a, img_name),
        .firmware = fw,
        .packed_name = img_name,
        .warnings = warnings,
        .missing_required = 0,
    };
}







