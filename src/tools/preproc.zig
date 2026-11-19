//! `image_cfg.json` 的 `pre-process` 流水线 —— 复刻 `mk_image.py` 的
//! `firmware_component_preproc()`：按配置里出现的顺序执行各段处理器。
//!
//! 已实现（与参考逐字节一致）：
//!   * `aicprivate`  → 私有资源二进制（复用 `privres`，等价 `_priv_build`）
//!   * `itb`         → ITS → FIT（`its.parse` + `buildFdt`；可选 `dtb`、`bin{src,dst}` 拼接）
//!   * `uboot_env`   → 环境变量镜像（分区前缀 + 可选冗余，复用 `pack.buildEnv`）
//!   * `aicimage`    → AIC 启动镜像 v2（`aicboot.createImageV2`）
//!   * `concatenate` → 顺序拼接（支持 `[files]` 与 `{files, max_size}` 两种写法）
//!   * `elf2itb`     → ELF → ITS（`elf2aic.itsSegments`，description 固定 "Luban-lite firmware"）
//!                     → FIT（external data + 0x800 块对齐），见 `runElf2itb`
//!   * `data_crypt`  → 固件加密（调厂商 `firmware_security_encrypt`，与 SDK 用法一致）
//!
//! 未实现（遇到明确报错，不静默跳过）：
//!   * `aicboot`     → 遗留 v1 头，Luban-Lite 1.0.6 之后不再使用
//!   * `spienc` / `spienctool` → 依赖厂商预编译工具（无源码）
const std = @import("std");
const image_cfg = @import("image_cfg.zig");
const privres = @import("privres.zig");
const fwenc = @import("fwenc.zig");
const pack = @import("pack.zig");
const its = @import("its.zig");
const aicboot = @import("aicboot.zig");
const partition_table = @import("partition_table.zig");
const utils = @import("../bsp/common/utils.zig");

pub const Error = error{
    BadConfig,
    MissingFile,
    UnsupportedProc,
    VendorToolRequired,
    ComponentTooLarge,
    NoPreProcess,
};

pub const Kind = enum { aicprivate, itb, elf2itb, uboot_env, aicimage, concatenate, data_crypt };

pub const Step = struct {
    /// 段名（如 `aicimage`）
    proc: []const u8,
    /// 产物文件名（相对 datadir）
    name: []const u8,
    size: usize,
    kind: Kind,
};

pub const Options = struct {
    cfg_path: []const u8,
    datadir: []const u8,
    keydir: ?[]const u8 = null,
    /// FIT 的 `timestamp`（与 `SOURCE_DATE_EPOCH` 对齐即可逐字节对拍）。
    timestamp: u32 = 0,
    /// 厂商工具目录（`mkuffs` / `firmware_security_encrypt`）；空则用 PATH。
    tool_dir: ?[]const u8 = null,
};

fn joinPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return allocator.dupe(u8, name);
    const last = dir[dir.len - 1];
    if (last == '/' or last == '\\') return std.mem.concat(allocator, u8, &.{ dir, name });
    return std.mem.concat(allocator, u8, &.{ dir, "/", name });
}

fn resolveIn(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]u8 {
    // 参考的 get_file_path(name, dir)：先 dir+name，再按原样
    const joined = try joinPath(allocator, dir, name);
    if (std.Io.Dir.cwd().statFile(io, joined, .{})) |_| {
        return joined;
    } else |_| {
        allocator.free(joined);
    }
    if (std.Io.Dir.cwd().statFile(io, name, .{})) |_| {
        return try allocator.dupe(u8, name);
    } else |_| {
        return Error.MissingFile;
    }
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch Error.MissingFile;
}

/// 解析目录：先 datadir/name，再按原样（参考的 `get_file_path(name, datadir)`）。
fn resolveDirIn(allocator: std.mem.Allocator, io: std.Io, datadir: []const u8, name: []const u8) ![]u8 {
    const joined = try joinPath(allocator, datadir, name);
    if (std.Io.Dir.cwd().statFile(io, joined, .{})) |_| {
        return joined;
    } else |_| {
        allocator.free(joined);
    }
    if (std.Io.Dir.cwd().statFile(io, name, .{})) |_| {
        return try allocator.dupe(u8, name);
    } else |_| {
        return Error.MissingFile;
    }
}

fn writeOut(io: std.Io, datadir: []const u8, name: []const u8, data: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{
        datadir,
        if (datadir.len != 0 and datadir[datadir.len - 1] != '/' and datadir[datadir.len - 1] != '\\') "/" else "",
        name,
    }) catch return Error.BadConfig;
    if (std.fs.path.dirname(path)) |d| {
        if (d.len != 0) std.Io.Dir.cwd().createDirPath(io, d) catch {};
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn runAicprivate(
    allocator: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    items: std.json.ObjectMap,
    steps: *std.ArrayList(Step),
) !void {
    var it = items.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const obj = image_cfg.asObject(e.value_ptr.*) orelse return Error.BadConfig;
        const arr = image_cfg.getArray(obj, "cfg") orelse return Error.BadConfig;

        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| allocator.free(p);
            paths.deinit(allocator);
        }
        for (arr.items) |v| {
            const s = switch (v) {
                .string => |s| s,
                else => return Error.BadConfig,
            };
            const p = try resolveIn(allocator, io, datadir, s);
            try paths.append(allocator, p);
        }

        const data = try privres.build(allocator, io, paths.items);
        defer allocator.free(data);
        try writeOut(io, datadir, name, data);
        try steps.append(allocator, .{
            .proc = "aicprivate",
            .name = try allocator.dupe(u8, name),
            .size = data.len,
            .kind = .aicprivate,
        });
    }
}

fn runItb(
    allocator: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    items: std.json.ObjectMap,
    timestamp: u32,
    steps: *std.ArrayList(Step),
) !void {
    var it = items.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const obj = image_cfg.asObject(e.value_ptr.*) orelse return Error.BadConfig;
        const its_name = image_cfg.getStr(obj, "its") orelse return Error.BadConfig;
        const its_path = try resolveIn(allocator, io, datadir, its_name);
        defer allocator.free(its_path);

        var parsed = try its.parse(allocator, io, its_path);
        defer parsed.deinit();
        // 条目带 keydir 时先做图像加密、再做签名（与参考 build_itb 的顺序一致：
        // cipher → 计算 hash → image 签名 → config 签名），哈希在 cipherImages 里已按密文重算。
        if (image_cfg.getStr(obj, "keydir")) |kdir| {
            const key_dir = try resolveDirIn(allocator, io, datadir, kdir);
            defer allocator.free(key_dir);
            _ = its.cipherImages(&parsed, allocator, io, key_dir) catch |err| switch (err) {
                error.MissingKey => return Error.MissingFile,
                else => return err,
            };
            _ = its.signImages(&parsed, allocator, io, key_dir, timestamp) catch |err| switch (err) {
                error.MissingKey => return Error.MissingFile,
                else => return err,
            };
            _ = its.signConfigurations(&parsed, allocator, io, key_dir, timestamp) catch |err| switch (err) {
                error.MissingKey => return Error.MissingFile,
                else => return err,
            };
        }
        // mk_image.py 的 itb_create_image() 固定 external_data=True + block_align=0x800
        const blob = try parsed.buildFdtExternal(allocator, timestamp, 0x800);
        defer allocator.free(blob);
        try writeOut(io, datadir, name, blob);
        try steps.append(allocator, .{
            .proc = "itb",
            .name = try allocator.dupe(u8, name),
            .size = blob.len,
            .kind = .itb,
        });

        // 可选：把 SPL 与 dtb 拼在一起（参考用 `cat src dtb > dst`）
        if (image_cfg.getObj(obj, "bin")) |bin_obj| {
            const src_name = image_cfg.getStr(bin_obj, "src") orelse return Error.BadConfig;
            const dst_name = image_cfg.getStr(bin_obj, "dst") orelse return Error.BadConfig;
            const dtb_name = image_cfg.getStr(obj, "dtb") orelse return Error.BadConfig;
            const src_path = try resolveIn(allocator, io, datadir, src_name);
            defer allocator.free(src_path);
            const dtb_path = try resolveIn(allocator, io, datadir, dtb_name);
            defer allocator.free(dtb_path);
            const src_data = try readFile(allocator, io, src_path);
            defer allocator.free(src_data);
            const dtb_data = try readFile(allocator, io, dtb_path);
            defer allocator.free(dtb_data);
            const cat = try std.mem.concat(allocator, u8, &.{ src_data, dtb_data });
            defer allocator.free(cat);
            try writeOut(io, datadir, dst_name, cat);
            try steps.append(allocator, .{
                .proc = "itb.bin",
                .name = try allocator.dupe(u8, dst_name),
                .size = cat.len,
                .kind = .itb,
            });
        }
    }
}

/// `elf2itb`：ELF → ITS（等价 `elf2image.elf2its`）→ ITB（`build_itb`，external data + 0x800 对齐）。
///
/// 与 `itb` 段唯一的区别是 **ITS 现场由 ELF 生成**（`itb` 段用的是配置里已有的 `.its` 文件）。
/// 参考 `firmware_component_preproc_elf2itb()` 还支持 `signature` / `encryption`，
/// 本仓库尚未实现这两项 —— 配置里一旦启用就明确报错，不静默产出未签名镜像。
fn runElf2itb(
    allocator: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    items: std.json.ObjectMap,
    version: []const u8,
    timestamp: u32,
    steps: *std.ArrayList(Step),
) !void {
    const elf2aic = @import("elf2aic.zig");

    var it = items.iterator();
    while (it.next()) |e| {
        const itb_name = e.key_ptr.*;
        const obj = image_cfg.asObject(e.value_ptr.*) orelse return Error.BadConfig;

        if (image_cfg.getObj(obj, "signature") != null or image_cfg.getObj(obj, "encryption") != null) {
            return Error.UnsupportedProc;
        }

        const elf_name = image_cfg.getStr(obj, "elf") orelse return Error.BadConfig;
        const elf_path = try resolveIn(allocator, io, datadir, elf_name);
        defer allocator.free(elf_path);
        const elf = try readFile(allocator, io, elf_path);
        defer allocator.free(elf);

        const segs = try elf2aic.itsSegments(allocator, elf);
        defer elf2aic.freeItsSegments(allocator, segs);

        // 段数据与参考一致：写到数据目录（`seg0.bin`…）
        for (segs, 0..) |seg, i| {
            const seg_name = try std.fmt.allocPrint(allocator, "seg{d}.bin", .{i});
            defer allocator.free(seg_name);
            try writeOut(io, datadir, seg_name, seg.data);
        }

        // ITS 名：`xxx.itb` → `xxx.its`
        const its_name = if (std.mem.endsWith(u8, itb_name, ".itb"))
            try std.fmt.allocPrint(allocator, "{s}.its", .{itb_name[0 .. itb_name.len - 4]})
        else
            try std.fmt.allocPrint(allocator, "{s}.its", .{itb_name});
        defer allocator.free(its_name);

        var algos: std.ArrayList([]const u8) = .empty;
        defer algos.deinit(allocator);
        if (image_cfg.getArray(obj, "hash")) |arr| {
            for (arr.items) |v| {
                const algo = switch (v) {
                    .string => |sv| sv,
                    else => return Error.BadConfig,
                };
                try algos.append(allocator, algo);
            }
        }

        var its_text: std.Io.Writer.Allocating = .init(allocator);
        defer its_text.deinit();
        try elf2aic.generateIts(&its_text.writer, segs, version, "Luban-lite firmware", algos.items);
        // 参考 `_generate_its()` 以文本模式写文件 → Windows 上 ITS 是 CRLF；
        // ITB 本身不受影响（换行在 DTS 解析阶段就被吃掉），但对拍要字节一致。
        const its_bytes = try utils.toPlatformNewlines(allocator, its_text.written());
        defer allocator.free(its_bytes);
        try writeOut(io, datadir, its_name, its_bytes);

        // ITS → ITB（与 `itb` 段同样的 external data + 0x800 对齐）
        const its_path = try resolveIn(allocator, io, datadir, its_name);
        defer allocator.free(its_path);
        var parsed = try its.parse(allocator, io, its_path);
        defer parsed.deinit();
        const blob = try parsed.buildFdtExternal(allocator, timestamp, 0x800);
        defer allocator.free(blob);
        try writeOut(io, datadir, itb_name, blob);
        try steps.append(allocator, .{
            .proc = "elf2itb",
            .name = try allocator.dupe(u8, itb_name),
            .size = blob.len,
            .kind = .elf2itb,
        });
    }
}

fn runUbootEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.json.Value,
    datadir: []const u8,
    items: std.json.ObjectMap,
    steps: *std.ArrayList(Step),
) !void {
    const prefix = try partition_table.partsForEnv(allocator, root);
    defer allocator.free(prefix);

    var it = items.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const obj = image_cfg.asObject(e.value_ptr.*) orelse return Error.BadConfig;
        const file = image_cfg.getStr(obj, "file") orelse return Error.BadConfig;
        const size_str = image_cfg.getStr(obj, "size") orelse "4096";
        const size: usize = @intCast(try utils.sizeStrToInt(size_str));
        const redundant = if (image_cfg.getStr(obj, "redundant")) |r|
            std.mem.find(u8, r, "enable") != null
        else
            false;

        const in_path = try resolveIn(allocator, io, datadir, file);
        defer allocator.free(in_path);
        const image_bytes = try pack.buildEnv(allocator, io, in_path, size, redundant, prefix);
        defer allocator.free(image_bytes);
        try writeOut(io, datadir, name, image_bytes);
        try steps.append(allocator, .{
            .proc = "uboot_env",
            .name = try allocator.dupe(u8, name),
            .size = image_bytes.len,
            .kind = .uboot_env,
        });
    }
}

fn runAicimage(
    allocator: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    keydir: []const u8,
    items: std.json.ObjectMap,
    steps: *std.ArrayList(Step),
) !void {
    var it = items.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const cfg = image_cfg.asObject(e.value_ptr.*) orelse return Error.BadConfig;
        const bytes = try aicboot.createImageV2(allocator, io, cfg, datadir, keydir);
        defer allocator.free(bytes);
        try writeOut(io, datadir, name, bytes);
        try steps.append(allocator, .{
            .proc = "aicimage",
            .name = try allocator.dupe(u8, name),
            .size = bytes.len,
            .kind = .aicimage,
        });
    }
}

/// `data_crypt` 段：调用厂商 `firmware_security_encrypt`（与参考
/// `mk_image.py::data_crypt_create_image` 同样的参数与路径解析规则）。
fn runDataCrypt(
    allocator: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    keydir: []const u8,
    tool_dir: ?[]const u8,
    items: std.json.ObjectMap,
    steps: *std.ArrayList(Step),
) !void {
    var it = items.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const cfg = image_cfg.asObject(e.value_ptr.*) orelse return Error.BadConfig;
        const key_name = image_cfg.getStr(cfg, "key") orelse return Error.BadConfig;
        const input_name = image_cfg.getStr(cfg, "input") orelse return Error.BadConfig;

        // 路径解析：key/nonce 先 keydir 再 datadir（等价参考 get_file_path）
        const key_path = try resolveKeyOrData(allocator, io, keydir, datadir, key_name);
        defer allocator.free(key_path);
        var nonce_path: ?[]u8 = null;
        defer if (nonce_path) |p| allocator.free(p);
        if (image_cfg.getStr(cfg, "nonce")) |n| {
            nonce_path = try resolveKeyOrData(allocator, io, keydir, datadir, n);
        }

        const input_path = try resolveIn(allocator, io, datadir, input_name);
        defer allocator.free(input_path);
        const out_path = try joinPath(allocator, datadir, name);
        defer allocator.free(out_path);

        try fwenc.run(allocator, io, .{
            .key = key_path,
            .nonce = nonce_path,
            .tweak = image_cfg.getStr(cfg, "tweak"),
            .input = input_path,
            .output = out_path,
            .tool_dir = tool_dir,
        });

        const st = std.Io.Dir.cwd().statFile(io, out_path, .{}) catch return Error.MissingFile;
        try steps.append(allocator, .{
            .proc = "data_crypt",
            .name = try allocator.dupe(u8, name),
            .size = @intCast(st.size),
            .kind = .data_crypt,
        });
    }
}

/// key 类文件查找：先 keydir 再 datadir。
fn resolveKeyOrData(
    allocator: std.mem.Allocator,
    io: std.Io,
    keydir: []const u8,
    datadir: []const u8,
    name: []const u8,
) ![]u8 {
    if (resolveIn(allocator, io, keydir, name)) |p| return p else |_| {}
    return resolveIn(allocator, io, datadir, name);
}

fn runConcatenate(
    allocator: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    items: std.json.ObjectMap,
    steps: *std.ArrayList(Step),
) !void {
    var it = items.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        var list: ?std.json.Array = null;
        var max_size: usize = 0;
        switch (e.value_ptr.*) {
            .array => |a| list = a,
            .object => |o| {
                list = image_cfg.getArray(o, "files") orelse return Error.BadConfig;
                if (image_cfg.getStr(o, "max_size")) |s| max_size = @intCast(try utils.sizeStrToInt(s));
            },
            else => return Error.BadConfig,
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (list.?.items) |v| {
            const s = switch (v) {
                .string => |s| s,
                else => return Error.BadConfig,
            };
            const p = try resolveIn(allocator, io, datadir, s);
            defer allocator.free(p);
            const data = try readFile(allocator, io, p);
            defer allocator.free(data);
            try out.appendSlice(allocator, data);
        }
        if (max_size != 0 and out.items.len > max_size) return Error.ComponentTooLarge;
        try writeOut(io, datadir, name, out.items);
        try steps.append(allocator, .{
            .proc = "concatenate",
            .name = try allocator.dupe(u8, name),
            .size = out.items.len,
            .kind = .concatenate,
        });
    }
}

/// 按配置顺序执行 `pre-process` 的全部段。
pub fn run(allocator: std.mem.Allocator, io: std.Io, opt: Options) ![]Step {
    var parsed = try image_cfg.load(allocator, io, opt.cfg_path);
    defer parsed.deinit();
    const root_obj = image_cfg.asObject(parsed.root().*) orelse return Error.BadConfig;
    const pre = image_cfg.getObj(root_obj, "pre-process") orelse
        image_cfg.getObj(root_obj, "temporary") orelse return Error.NoPreProcess;
    const keydir = opt.keydir orelse opt.datadir;

    var steps: std.ArrayList(Step) = .empty;
    errdefer {
        for (steps.items) |s| {
            allocator.free(s.name);
        }
        steps.deinit(allocator);
    }

    var it = pre.iterator();
    while (it.next()) |e| {
        const proc = e.key_ptr.*;
        const items = image_cfg.asObject(e.value_ptr.*) orelse return Error.BadConfig;
        if (std.mem.eql(u8, proc, "aicprivate")) {
            try runAicprivate(allocator, io, opt.datadir, items, &steps);
        } else if (std.mem.eql(u8, proc, "itb")) {
            try runItb(allocator, io, opt.datadir, items, opt.timestamp, &steps);
        } else if (std.mem.eql(u8, proc, "elf2itb")) {
            // 参考：`cfg.get("image", {}).get("info", {}).get("version", "1.0.0")` —— 缺整段也不报错
            const version = blk: {
                const image_obj = image_cfg.getObj(root_obj, "image") orelse break :blk "1.0.0";
                const info_obj = image_cfg.getObj(image_obj, "info") orelse break :blk "1.0.0";
                break :blk image_cfg.getStr(info_obj, "version") orelse "1.0.0";
            };
            try runElf2itb(allocator, io, opt.datadir, items, version, opt.timestamp, &steps);
        } else if (std.mem.eql(u8, proc, "uboot_env")) {
            try runUbootEnv(allocator, io, parsed.root().*, opt.datadir, items, &steps);
        } else if (std.mem.eql(u8, proc, "aicimage")) {
            try runAicimage(allocator, io, opt.datadir, keydir, items, &steps);
        } else if (std.mem.eql(u8, proc, "concatenate")) {
            try runConcatenate(allocator, io, opt.datadir, items, &steps);
        } else if (std.mem.eql(u8, proc, "data_crypt")) {
            try runDataCrypt(allocator, io, opt.datadir, keydir, opt.tool_dir, items, &steps);
        } else if (std.mem.eql(u8, proc, "aicboot")) {
            return Error.UnsupportedProc;
        } else if (std.mem.eql(u8, proc, "spienc") or std.mem.eql(u8, proc, "spienctool")) {
            // 这两个段在 20 个官方 image_cfg.json 里出现 0 次，且同样只有预编译 exe；
            // 真要用时按厂商 exe 包装（同 data_crypt）即可。
            return Error.VendorToolRequired;
        } else {
            return Error.UnsupportedProc;
        }
    }
    return steps.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------
fn testPath(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/preproc-test/{s}", .{name}) catch unreachable;
}

test "preproc：concatenate 按顺序拼接，max_size 超限报错" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-cache/preproc-test";

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    var b3: [128]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = testPath(&b1, "a.bin"), .data = "AAA" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = testPath(&b2, "b.bin"), .data = "BB" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = testPath(&b3, "cfg.json"),
        .data = "{\"pre-process\":{\"concatenate\":{\"out.bin\":[\"a.bin\",\"b.bin\"]}}}",
    });

    const steps = try run(allocator, io, .{ .cfg_path = testPath(&b3, "cfg.json"), .datadir = dir });
    defer {
        for (steps) |s| {
            allocator.free(s.name);
        }
        allocator.free(steps);
    }
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqual(@as(usize, 5), steps[0].size);

    var b4: [128]u8 = undefined;
    const out = try std.Io.Dir.cwd().readFileAlloc(io, testPath(&b4, "out.bin"), allocator, .unlimited);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, "AAABB", out);

    // max_size = 4 < 5 → ComponentTooLarge
    var b5: [128]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = testPath(&b5, "cfg2.json"),
        .data = "{\"pre-process\":{\"concatenate\":{\"out2.bin\":{\"files\":[\"a.bin\",\"b.bin\"],\"max_size\":\"4\"}}}}",
    });
    try std.testing.expectError(Error.ComponentTooLarge, run(allocator, io, .{
        .cfg_path = testPath(&b5, "cfg2.json"),
        .datadir = dir,
    }));
}

test "preproc: elf2itb 段拒绝 signature / encryption（不静默产出未签名镜像）" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-cache/preproc-test";

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var b1: [160]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = testPath(&b1, "cfg_sig.json"),
        .data = "{\"pre-process\":{\"elf2itb\":{\"os.itb\":{\"elf\":\"x.elf\"," ++
            "\"hash\":[\"crc32\"],\"signature\":{\"algo\":\"sha256\"}}}}}",
    });
    try std.testing.expectError(Error.UnsupportedProc, run(allocator, io, .{
        .cfg_path = testPath(&b1, "cfg_sig.json"),
        .datadir = dir,
    }));

    var b2: [160]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = testPath(&b2, "cfg_enc.json"),
        .data = "{\"pre-process\":{\"elf2itb\":{\"os.itb\":{\"elf\":\"x.elf\"," ++
            "\"encryption\":{\"algo\":\"aes-128-cbc\"}}}}}",
    });
    try std.testing.expectError(Error.UnsupportedProc, run(allocator, io, .{
        .cfg_path = testPath(&b2, "cfg_enc.json"),
        .datadir = dir,
    }));
}

test "preproc: elf2itb 段缺 ELF 时明确报 MissingFile" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-cache/preproc-test";

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var b: [160]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = testPath(&b, "cfg_missing.json"),
        .data = "{\"pre-process\":{\"elf2itb\":{\"os.itb\":{\"elf\":\"nope.elf\"}," ++
            "\"hash\":[\"crc32\"]}}}",
    });
    try std.testing.expectError(Error.MissingFile, run(allocator, io, .{
        .cfg_path = testPath(&b, "cfg_missing.json"),
        .datadir = dir,
    }));
}
