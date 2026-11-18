//! 私有资源二进制生成 —— 对应参考工程
//! `tools/scripts/mk_private_resource.py` / `aic_private_resource/_core.py`。
//!
//! 段格式：`[type:u32][data_len:u32][payload]`，最后写 `SECT_END`。
//! 配置为 JSON（允许 `//` 注释与尾逗号），可合并多个文件，后写覆盖先写。
const std = @import("std");
const image_cfg = @import("image_cfg.zig");

pub const Error = error{
    BadConfig,
    MissingField,
    BadNumber,
    MissingKeyFile,
};

pub const SECT_DRAM: u32 = 0x41490001;
pub const SECT_UART: u32 = 0x41490002;
pub const SECT_JTAG: u32 = 0x41490003;
pub const SECT_UPGMODE: u32 = 0x41490004;
pub const SECT_PART: u32 = 0x41490005;
pub const SECT_PSRAM: u32 = 0x41490006;
pub const SECT_REGCFG: u32 = 0x41490007;
pub const SECT_SECURITY_KEYDATA: u32 = 0x41490008;
pub const SECT_END: u32 = 0x4149FFFF;

const DDR_FIELDS = [_][]const u8{
    "type",     "memsize", "freq",   "zq",     "odt",    "para1",  "para2",
    "mr0",      "mr1",     "mr2",    "mr3",    "mr4",     "mr5",    "mr6",
    "tpr0",     "tpr1",    "tpr2",   "tpr3",   "tpr4",    "tpr5",   "tpr6",
    "tpr7",     "tpr8",    "tpr9",   "tpr10",  "tpr11",   "tpr12",  "tpr13",
    "tpr14",    "tpr15",   "tpr16",  "tpr17",  "tpr18",
};

const PSRAM_COMMON_FIELDS = [_][]const u8{
    "clock",           "cs0_pins",        "cs1_pins",
    "xspi_ctl",        "xspi_tcr",        "xspi_cfg",
    "xspi_ldo",        "psram_cfg0",      "psram_cfg1",
    "xspi_cs0_iocfg1", "xspi_cs0_iocfg2", "xspi_cs0_iocfg3",
    "xspi_cs0_iocfg4", "xspi_cs1_iocfg1", "xspi_cs1_iocfg2",
    "xspi_cs1_iocfg3", "xspi_cs1_iocfg4",
};
const PSRAM_RESET_FIELDS = [_][]const u8{ "proto", "buf" };
const PSRAM_GETID_FIELDS = [_][]const u8{ "proto", "id", "buf" };
const PSRAM_INIT_FIELDS = [_][]const u8{
    "proto0", "buf0", "proto1", "buf1",
    "proto2", "buf2", "proto3", "buf3",
};
const PSRAM_XIP_FIELDS = [_][]const u8{ "wr_proto", "wr_buf", "rd_proto", "rd_buf" };
const PSRAM_BACKUP_FIELDS = [_][]const u8{
    "buf0", "buf1", "buf2", "buf3", "buf4",
    "buf5", "buf6", "buf7", "buf8", "buf9",
};

const UART_FIELDS = [_][]const u8{
    "uart_id", "uart_tx_pin_cfg_reg", "uart_tx_pin_cfg_val",
    "uart_rx_pin_cfg_reg", "uart_rx_pin_cfg_val",
};
const JTAG_FIELDS = [_][]const u8{
    "jtag_id",
    "jtag_do_pin_cfg_reg", "jtag_do_pin_cfg_val",
    "jtag_di_pin_cfg_reg", "jtag_di_pin_cfg_val",
    "jtag_ms_pin_cfg_reg", "jtag_ms_pin_cfg_val",
    "jtag_ck_pin_cfg_reg", "jtag_ck_pin_cfg_val",
};
const REGCFG_FIELDS = [_][]const u8{ "reg", "val", "dly" };
const UPGMODE_FIELDS = [_][]const u8{
    "upgmode_pin_cfg_reg", "upgmode_pin_cfg_val",
    "upgmode_pin_input_reg", "upgmode_pin_input_msk",
    "upgmode_pin_input_val", "upgmode_pin_pullup_dly",
};

fn parseU32(text: []const u8) !u32 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len == 0) return Error.BadNumber;
    return std.fmt.parseInt(u32, s, 0) catch Error.BadNumber;
}

fn valueU32(v: std.json.Value) !u32 {
    return switch (v) {
        .string => |s| parseU32(s),
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else Error.BadNumber,
        else => Error.BadNumber,
    };
}

fn writeU32(w: *std.Io.Writer, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try w.writeAll(&buf);
}

fn field(w: *std.Io.Writer, obj: std.json.ObjectMap, name: []const u8, default: []const u8) !void {
    if (obj.get(name)) |v| {
        try writeU32(w, try valueU32(v));
    } else {
        try writeU32(w, try parseU32(default));
    }
}

fn encodeFields(
    w: *std.Io.Writer,
    obj: ?std.json.ObjectMap,
    fields: []const []const u8,
    default: []const u8,
) !void {
    for (fields) |f| {
        if (obj) |o| {
            try field(w, o, f, default);
        } else {
            try writeU32(w, try parseU32(default));
        }
    }
}

fn writeSection(w: *std.Io.Writer, sect: u32, payload: []const u8) !void {
    try writeU32(w, sect);
    try writeU32(w, @intCast(payload.len));
    try w.writeAll(payload);
}

fn payloadDram(a: std.mem.Allocator, dram: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try writeU32(&out.writer, @intCast(dram.count()));
    var it = dram.iterator();
    while (it.next()) |entry| {
        const obj = image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig;
        try encodeFields(&out.writer, obj, &DDR_FIELDS, "0");
    }
    return out.toOwnedSlice();
}

fn subObj(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    return image_cfg.getObj(obj, name);
}

fn payloadPsram(a: std.mem.Allocator, psram: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try writeU32(&out.writer, @intCast(psram.count()));
    var it = psram.iterator();
    while (it.next()) |entry| {
        const obj = image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig;
        try encodeFields(&out.writer, subObj(obj, "common"), &PSRAM_COMMON_FIELDS, "0");
        try encodeFields(&out.writer, subObj(obj, "reset"), &PSRAM_RESET_FIELDS, "0xFFFFFFFF");
        try encodeFields(&out.writer, subObj(obj, "getid"), &PSRAM_GETID_FIELDS, "0xFFFFFFFF");
        try encodeFields(&out.writer, subObj(obj, "init"), &PSRAM_INIT_FIELDS, "0xFFFFFFFF");
        try encodeFields(&out.writer, subObj(obj, "xip_cfg"), &PSRAM_XIP_FIELDS, "0xFFFFFFFF");
        try encodeFields(&out.writer, subObj(obj, "backup"), &PSRAM_BACKUP_FIELDS, "0xFFFFFFFF");
    }
    return out.toOwnedSlice();
}

fn payloadUart(a: std.mem.Allocator, uart: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var it = uart.iterator();
    while (it.next()) |entry| {
        const obj = image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig;
        try encodeFields(&out.writer, obj, &UART_FIELDS, "0");
    }
    return out.toOwnedSlice();
}

fn payloadJtag(a: std.mem.Allocator, jtag: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try field(&out.writer, jtag, "jtag_only", "0");
    var it = jtag.iterator();
    while (it.next()) |entry| {
        const obj = image_cfg.asObject(entry.value_ptr.*) orelse continue;
        try encodeFields(&out.writer, obj, &JTAG_FIELDS, "0");
    }
    return out.toOwnedSlice();
}

fn payloadRegcfg(a: std.mem.Allocator, cfg: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const count_text = image_cfg.getStr(cfg, "count") orelse "0";
    const requested = try parseU32(count_text);
    const regs = image_cfg.getArray(cfg, "regs") orelse return Error.MissingField;
    const count: u32 = @min(requested, @as(u32, @intCast(regs.items.len)));
    try writeU32(&out.writer, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj = image_cfg.asObject(regs.items[i]) orelse continue;
        try encodeFields(&out.writer, obj, &REGCFG_FIELDS, "0");
    }
    return out.toOwnedSlice();
}

fn payloadUpgmode(a: std.mem.Allocator, cfg: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try encodeFields(&out.writer, cfg, UPGMODE_FIELDS[0 .. UPGMODE_FIELDS.len - 1], "0");
    try field(&out.writer, cfg, UPGMODE_FIELDS[UPGMODE_FIELDS.len - 1], "500");
    return out.toOwnedSlice();
}

fn payloadPartitions(a: std.mem.Allocator, parts: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    if (image_cfg.getArray(parts, "type")) |types| {
        for (types.items) |t| {
            const name = switch (t) {
                .string => |s| s,
                else => continue,
            };
            const val = image_cfg.getStr(parts, name) orelse continue;
            try out.writer.print("{s}={s};", .{ name, val });
        }
    }
    const remainder = out.written().len % 4;
    const pad_len: usize = if (remainder == 0) 4 else 4 - remainder;
    var zeros: [4]u8 = @splat(0);
    try out.writer.writeAll(zeros[0..pad_len]);
    return out.toOwnedSlice();
}

fn payloadSecurity(
    a: std.mem.Allocator,
    io: std.Io,
    sec: std.json.ObjectMap,
    config_dir: []const u8,
) ![]u8 {
    const keydata = image_cfg.getObj(sec, "keydata") orelse return Error.MissingField;
    const version_text = image_cfg.getStr(keydata, "version") orelse "1";
    const file_name = image_cfg.getStr(keydata, "file") orelse return Error.MissingField;
    const path = try std.fs.path.join(a, &.{ config_dir, file_name });
    defer a.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return Error.MissingKeyFile;
    defer a.free(data);

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try writeU32(&out.writer, try parseU32(version_text));
    try out.writer.writeAll(data);
    const remainder = data.len % 4;
    if (remainder != 0) {
        var zeros: [4]u8 = @splat(0);
        try out.writer.writeAll(zeros[0 .. 4 - remainder]);
    }
    return out.toOwnedSlice();
}

fn buildSystem(
    a: std.mem.Allocator,
    w: *std.Io.Writer,
    system: std.json.ObjectMap,
) !void {
    var it = system.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const obj = image_cfg.asObject(entry.value_ptr.*) orelse continue;
        const sect: u32 = if (std.mem.eql(u8, key, "upgmode"))
            SECT_UPGMODE
        else if (std.mem.eql(u8, key, "uart"))
            SECT_UART
        else if (std.mem.eql(u8, key, "jtag"))
            SECT_JTAG
        else if (std.mem.eql(u8, key, "regcfg"))
            SECT_REGCFG
        else
            continue;

        const payload = switch (sect) {
            SECT_UPGMODE => try payloadUpgmode(a, obj),
            SECT_UART => try payloadUart(a, obj),
            SECT_JTAG => try payloadJtag(a, obj),
            SECT_REGCFG => try payloadRegcfg(a, obj),
            else => unreachable,
        };
        defer a.free(payload);
        try writeSection(w, sect, payload);
    }
}

pub fn build(
    a: std.mem.Allocator,
    io: std.Io,
    config_paths: []const []const u8,
) ![]u8 {
    if (config_paths.len == 0) return Error.BadConfig;

    var parsed: std.ArrayList(image_cfg.ParsedConfig) = .empty;
    defer {
        for (parsed.items) |*p| p.deinit();
        parsed.deinit(a);
    }
    var merged: std.json.ObjectMap = .empty;
    defer merged.deinit(a);

    for (config_paths) |path| {
        var pc = try image_cfg.load(a, io, path);
        try parsed.append(a, pc);
        const root = image_cfg.asObject(pc.root().*) orelse return Error.BadConfig;
        var it = root.iterator();
        while (it.next()) |entry| {
            try merged.put(a, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    const config_dir = std.fs.path.dirname(config_paths[0]) orelse ".";

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();

    var it = merged.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "_")) continue;
        if (std.mem.eql(u8, key, "dram")) {
            const payload = try payloadDram(a, image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig);
            defer a.free(payload);
            try writeSection(&out.writer, SECT_DRAM, payload);
        } else if (std.mem.eql(u8, key, "psram")) {
            const payload = try payloadPsram(a, image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig);
            defer a.free(payload);
            try writeSection(&out.writer, SECT_PSRAM, payload);
        } else if (std.mem.eql(u8, key, "partitions")) {
            const payload = try payloadPartitions(a, image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig);
            defer a.free(payload);
            try writeSection(&out.writer, SECT_PART, payload);
        } else if (std.mem.eql(u8, key, "security")) {
            const payload = try payloadSecurity(a, io, image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig, config_dir);
            defer a.free(payload);
            try writeSection(&out.writer, SECT_SECURITY_KEYDATA, payload);
        } else if (std.mem.eql(u8, key, "system")) {
            try buildSystem(a, &out.writer, image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig);
        }
    }

    try writeU32(&out.writer, SECT_END);
    try writeU32(&out.writer, 0);
    return out.toOwnedSlice();
}

test "privres：dram/partitions/end 布局" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const cfg_path = try std.fs.path.join(a, &.{ root, "private.json" });
    defer a.free(cfg_path);
    const text =
        \\{
        \\  // 注释与尾逗号
        \\  "dram": {"ddr0": {"type":"1","memsize":"0x1000000"}},
        \\  "partitions": {"type":["spi"], "spi":"0:512k(spl)"},
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = text });

    const data = try build(a, io, &.{cfg_path});
    defer a.free(data);

    try std.testing.expectEqual(@as(u32, SECT_DRAM), std.mem.readInt(u32, data[0..4], .little));
    try std.testing.expectEqual(@as(u32, 4 + DDR_FIELDS.len * 4), std.mem.readInt(u32, data[4..8], .little));
    const end = data.len - 8;
    try std.testing.expectEqual(@as(u32, SECT_END), std.mem.readInt(u32, data[end..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, data[end + 4 ..][0..4], .little));
}
