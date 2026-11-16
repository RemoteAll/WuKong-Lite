//! ELF → AIC 可启动镜像 —— 对应 Luban-Lite `tools/scripts/elf2image`：
//! 读取 ELF 的 PT_LOAD 段，按最小物理地址展开为连续固件，再套 64 字节 AIC 头。
//!
//! 支持 ELF32 / ELF64（小端），覆盖 D13x 等 RISC-V 目标。
const std = @import("std");
const image = @import("../bsp/common/image.zig");

pub const PT_LOAD: u32 = 1;

pub const ElfInfo = struct {
    is_64: bool,
    entry: u64,
    load_address: u64,
    /// 固件跨度（最大 paddr+memsz 与最小 paddr 的差）
    span: u64,
    segments: usize,
};

const EhdrOffsets = struct {
    entry: usize,
    phoff: usize,
    phentsize: usize,
    phnum: usize,
};

fn ehdrOffsets(is_64: bool) EhdrOffsets {
    return if (is_64)
        .{ .entry = 24, .phoff = 32, .phentsize = 54, .phnum = 56 }
    else
        .{ .entry = 24, .phoff = 28, .phentsize = 42, .phnum = 44 };
}

fn readU16(bytes: []const u8, off: usize) !u16 {
    if (off + 2 > bytes.len) return error.TruncatedElf;
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) !u32 {
    if (off + 4 > bytes.len) return error.TruncatedElf;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readU64(bytes: []const u8, off: usize) !u64 {
    if (off + 8 > bytes.len) return error.TruncatedElf;
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

fn elfClass(bytes: []const u8) !bool {
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.BadElfMagic;
    if (bytes.len < 6) return error.TruncatedElf;
    const class = bytes[4];
    if (class != 1 and class != 2) return error.UnsupportedElfClass;
    if (bytes[5] != 1) return error.UnsupportedEndian;
    if (bytes.len < 52) return error.TruncatedElf;
    return class == 2;
}

/// 只读取 ELF 的装载信息（不展开数据）。
pub fn inspect(elf: []const u8) !ElfInfo {
    const is_64 = try elfClass(elf);
    const offs = ehdrOffsets(is_64);

    const entry: u64 = if (is_64) try readU64(elf, offs.entry) else try readU32(elf, offs.entry);
    const phoff: u64 = if (is_64) try readU64(elf, offs.phoff) else try readU32(elf, offs.phoff);
    const phentsize: u16 = try readU16(elf, offs.phentsize);
    const phnum: u16 = try readU16(elf, offs.phnum);

    if (phnum == 0 or phentsize == 0) return error.NoProgramHeaders;
    const expected: u16 = if (is_64) 56 else 32;
    if (phentsize < expected) return error.BadProgramHeaderSize;

    var min_addr: u64 = std.math.maxInt(u64);
    var max_end: u64 = 0;
    var segments: usize = 0;

    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const base: usize = @intCast(phoff + @as(u64, i) * phentsize);
        const p_type = try readU32(elf, base);
        if (p_type != PT_LOAD) continue;

        var vaddr: u64 = 0;
        var paddr: u64 = 0;
        var memsz: u64 = 0;
        if (is_64) {
            vaddr = try readU64(elf, base + 16);
            paddr = try readU64(elf, base + 24);
            memsz = try readU64(elf, base + 40);
        } else {
            vaddr = try readU32(elf, base + 8);
            paddr = try readU32(elf, base + 12);
            memsz = try readU32(elf, base + 20);
        }
        const addr = if (paddr != 0) paddr else vaddr;
        if (memsz == 0) continue;
        segments += 1;
        if (addr < min_addr) min_addr = addr;
        if (addr + memsz > max_end) max_end = addr + memsz;
    }

    if (segments == 0) return error.NoLoadSegments;
    return .{
        .is_64 = is_64,
        .entry = entry,
        .load_address = min_addr,
        .span = max_end - min_addr,
        .segments = segments,
    };
}

/// 把 ELF 展开为 AIC 镜像（等价 elf2image 的输出）。
pub fn convert(allocator: std.mem.Allocator, elf: []const u8, head_ver: u32) ![]u8 {
    const info = try inspect(elf);
    if (info.span == 0 or info.span > std.math.maxInt(u32)) return error.ImageTooLarge;
    if (info.load_address > std.math.maxInt(u32) or info.entry > std.math.maxInt(u32)) return error.AddressTooLarge;

    const firmware = try allocator.alloc(u8, @intCast(info.span));
    defer allocator.free(firmware);
    @memset(firmware, 0);

    const is_64 = info.is_64;
    const offs = ehdrOffsets(is_64);
    const phoff: u64 = if (is_64) try readU64(elf, offs.phoff) else try readU32(elf, offs.phoff);
    const phentsize: u16 = try readU16(elf, offs.phentsize);
    const phnum: u16 = try readU16(elf, offs.phnum);

    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const base: usize = @intCast(phoff + @as(u64, i) * phentsize);
        const p_type = try readU32(elf, base);
        if (p_type != PT_LOAD) continue;

        var p_offset: u64 = 0;
        var vaddr: u64 = 0;
        var paddr: u64 = 0;
        var filesz: u64 = 0;
        var memsz: u64 = 0;
        if (is_64) {
            p_offset = try readU64(elf, base + 8);
            vaddr = try readU64(elf, base + 16);
            paddr = try readU64(elf, base + 24);
            filesz = try readU64(elf, base + 32);
            memsz = try readU64(elf, base + 40);
        } else {
            p_offset = try readU32(elf, base + 4);
            vaddr = try readU32(elf, base + 8);
            paddr = try readU32(elf, base + 12);
            filesz = try readU32(elf, base + 16);
            memsz = try readU32(elf, base + 20);
        }
        if (memsz == 0) continue;

        const addr = if (paddr != 0) paddr else vaddr;
        const dest: usize = @intCast(addr - info.load_address);
        const n: usize = @intCast(filesz);
        if (p_offset + filesz > elf.len) return error.TruncatedSegment;
        if (dest + n > firmware.len) return error.SegmentOutOfRange;
        @memcpy(firmware[dest..][0..n], elf[@intCast(p_offset)..][0..n]);
    }

    return image.createV1(
        allocator,
        firmware,
        @intCast(info.load_address),
        @intCast(info.entry),
        null,
        head_ver,
    );
}

fn writeU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}

fn writeU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

test "ELF32 单段转换为 AIC 镜像" {
    const allocator = std.testing.allocator;
    var elf: [0x110]u8 = @splat(0);
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 1; // ELF32
    elf[5] = 1; // little endian
    elf[6] = 1; // version

    writeU32(&elf, 24, 0x40100100); // e_entry
    writeU32(&elf, 28, 52); // e_phoff
    writeU16(&elf, 42, 32); // e_phentsize
    writeU16(&elf, 44, 1); // e_phnum

    // PT_LOAD：offset 0x100，vaddr 0x40100000，filesz 4，memsz 8
    const ph = 52;
    writeU32(&elf, ph + 0, PT_LOAD);
    writeU32(&elf, ph + 4, 0x100);
    writeU32(&elf, ph + 8, 0x40100000);
    writeU32(&elf, ph + 12, 0x40100000);
    writeU32(&elf, ph + 16, 4);
    writeU32(&elf, ph + 20, 8);
    @memcpy(elf[0x100..0x104], "ABCD");

    const info = try inspect(&elf);
    try std.testing.expectEqual(@as(u64, 0x40100000), info.load_address);
    try std.testing.expectEqual(@as(u64, 0x40100100), info.entry);
    try std.testing.expectEqual(@as(u64, 8), info.span);
    try std.testing.expectEqual(@as(usize, 1), info.segments);

    const img = try convert(allocator, &elf, image.HEAD_VER_1_0_0);
    defer allocator.free(img);

    try image.verify(img);
    const header = try image.decodeV1(img);
    try std.testing.expectEqual(@as(u32, 0x40100000), header.load_address);
    try std.testing.expectEqual(@as(u32, 0x40100100), header.entry_point);
    try std.testing.expectEqual(@as(u32, 8), header.firmware_len);
    try std.testing.expectEqualStrings("ABCD", img[image.SIZE_V1..][0..4]);
    try std.testing.expectEqual(@as(u8, 0), img[image.SIZE_V1 + 4]);
}

test "非 ELF 文件报错" {
    const elf = "not an elf file";
    try std.testing.expectError(error.BadElfMagic, inspect(elf));
}

// ---------------------------------------------------------------------------
// elf2its：按 Luban-Lite `elf2image` 的规则提取段并生成 ITS
// ---------------------------------------------------------------------------

const SHT_NOBITS: u32 = 8;
const SHF_ALLOC: u64 = 0x2;

const Phdr = struct {
    p_type: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_filesz: u64,
    p_memsz: u64,
};

const Shar = struct {
    sh_type: u32,
    sh_flags: u64,
    sh_addr: u64,
    sh_offset: u64,
    sh_size: u64,
};

fn shdrOffsets(is_64: bool) struct { shoff: usize, shentsize: usize, shnum: usize } {
    return if (is_64)
        .{ .shoff = 40, .shentsize = 58, .shnum = 60 }
    else
        .{ .shoff = 32, .shentsize = 46, .shnum = 48 };
}

fn parsePhdrs(allocator: std.mem.Allocator, elf: []const u8, is_64: bool) ![]Phdr {
    const offs = ehdrOffsets(is_64);
    const phoff: u64 = if (is_64) try readU64(elf, offs.phoff) else try readU32(elf, offs.phoff);
    const phentsize: u16 = try readU16(elf, offs.phentsize);
    const phnum: u16 = try readU16(elf, offs.phnum);

    var list: std.ArrayList(Phdr) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const base: usize = @intCast(phoff + @as(u64, i) * phentsize);
        var p = Phdr{ .p_type = try readU32(elf, base), .p_offset = 0, .p_vaddr = 0, .p_filesz = 0, .p_memsz = 0 };
        if (is_64) {
            p.p_offset = try readU64(elf, base + 8);
            p.p_vaddr = try readU64(elf, base + 16);
            p.p_filesz = try readU64(elf, base + 32);
            p.p_memsz = try readU64(elf, base + 40);
        } else {
            p.p_offset = try readU32(elf, base + 4);
            p.p_vaddr = try readU32(elf, base + 8);
            p.p_filesz = try readU32(elf, base + 16);
            p.p_memsz = try readU32(elf, base + 20);
        }
        try list.append(allocator, p);
    }
    return list.toOwnedSlice(allocator);
}

fn parseShdrs(allocator: std.mem.Allocator, elf: []const u8, is_64: bool) ![]Shar {
    const offs = shdrOffsets(is_64);
    const shoff: u64 = if (is_64) try readU64(elf, offs.shoff) else try readU32(elf, offs.shoff);
    const shentsize: u16 = try readU16(elf, offs.shentsize);
    const shnum: u16 = try readU16(elf, offs.shnum);
    if (shnum == 0) return &.{};

    var list: std.ArrayList(Shar) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const base: usize = @intCast(shoff + @as(u64, i) * shentsize);
        var s = Shar{ .sh_type = try readU32(elf, base + 4), .sh_flags = 0, .sh_addr = 0, .sh_offset = 0, .sh_size = 0 };
        if (is_64) {
            s.sh_flags = try readU64(elf, base + 8);
            s.sh_addr = try readU64(elf, base + 16);
            s.sh_offset = try readU64(elf, base + 24);
            s.sh_size = try readU64(elf, base + 32);
        } else {
            s.sh_flags = try readU32(elf, base + 8);
            s.sh_addr = try readU32(elf, base + 12);
            s.sh_offset = try readU32(elf, base + 16);
            s.sh_size = try readU32(elf, base + 20);
        }
        try list.append(allocator, s);
    }
    return list.toOwnedSlice(allocator);
}

pub const ItsSegment = struct {
    load_addr: u32,
    entry: u32,
    data: []u8,

    pub fn deinit(self: *ItsSegment, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

fn lessThanShar(_: void, a: Shar, b: Shar) bool {
    return a.sh_addr < b.sh_addr;
}

/// 按参考实现提取 ITS 段（每段对应一个 PT_LOAD，XIP 时把入口段提到第一段）。
pub fn itsSegments(allocator: std.mem.Allocator, elf: []const u8) ![]ItsSegment {
    const is_64 = try elfClass(elf);
    const info = try inspect(elf);
    const phdrs = try parsePhdrs(allocator, elf, is_64);
    defer allocator.free(phdrs);
    const shdrs = try parseShdrs(allocator, elf, is_64);
    defer allocator.free(shdrs);

    var list: std.ArrayList(ItsSegment) = .empty;
    errdefer {
        for (list.items) |*seg| seg.deinit(allocator);
        list.deinit(allocator);
    }

    for (phdrs) |ph| {
        if (ph.p_type != PT_LOAD or ph.p_filesz == 0) continue;
        const ph_end = ph.p_vaddr + ph.p_memsz;

        var sections: std.ArrayList(Shar) = .empty;
        defer sections.deinit(allocator);
        for (shdrs) |sh| {
            if (sh.sh_size == 0) continue;
            if (sh.sh_flags & SHF_ALLOC == 0) continue;
            if (sh.sh_addr < ph.p_vaddr or sh.sh_addr >= ph_end) continue;
            try sections.append(allocator, sh);
        }
        std.mem.sort(Shar, sections.items, {}, lessThanShar);

        // 计算 PROGBITS 覆盖范围（NOBITS 跳过）
        var first_addr: ?u64 = null;
        var last_end: u64 = 0;
        for (sections.items) |sh| {
            if (sh.sh_type == SHT_NOBITS) continue;
            if (first_addr == null) first_addr = sh.sh_addr;
            if (sh.sh_addr + sh.sh_size > last_end) last_end = sh.sh_addr + sh.sh_size;
        }

        var data: []u8 = &.{};
        if (first_addr) |base| {
            const len: usize = @intCast(last_end - base);
            data = try allocator.alloc(u8, len);
            @memset(data, 0);
            for (sections.items) |sh| {
                if (sh.sh_type == SHT_NOBITS) continue;
                const src: usize = @intCast(sh.sh_offset);
                const n: usize = @intCast(sh.sh_size);
                if (src + n > elf.len) {
                    allocator.free(data);
                    return error.TruncatedSegment;
                }
                const dst: usize = @intCast(sh.sh_addr - base);
                @memcpy(data[dst..][0..n], elf[src..][0..n]);
            }
        }

        try list.append(allocator, .{
            .load_addr = @intCast(ph.p_vaddr),
            .entry = @intCast(info.entry),
            .data = data,
        });
    }

    // XIP：入口地址在 0x60000000 以上时，入口所在段必须排在第一位
    if (info.entry > 0x60000000) {
        for (list.items, 0..) |seg, i| {
            if (seg.load_addr == info.entry and i != 0) {
                std.mem.swap(ItsSegment, &list.items[0], &list.items[i]);
                break;
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeItsSegments(allocator: std.mem.Allocator, segs: []ItsSegment) void {
    for (segs) |*seg| seg.deinit(allocator);
    allocator.free(segs);
}

/// 生成 ITS 文本（与 `elf2image/_core.py::_generate_its` 输出格式一致）。
pub fn generateIts(
    writer: *std.Io.Writer,
    segs: []const ItsSegment,
    version: []const u8,
    description: []const u8,
    hash_algos: []const []const u8,
) !void {
    try writer.writeAll("/dts-v1/;\n\n/ {\n");
    try writer.print("\tdescription = \"ArtInChip Luban-lite\";\n", .{});
    try writer.print("\t#address-cells = <1>;\n\n", .{});
    try writer.print("\timages {{\n\t\tversion = \"{s}\";\n", .{version});
    for (segs, 0..) |seg, i| {
        try writer.print("\t\tseg{d} {{\n", .{i});
        try writer.print("\t\t\tdescription = \"ArtInChip segment {d}\";\n", .{i});
        try writer.print("\t\t\tdata = /incbin/(\"./seg{d}.bin\");\n", .{i});
        try writer.writeAll("\t\t\ttype = \"firmware\";\n");
        try writer.writeAll("\t\t\tarch = \"riscv\";\n");
        try writer.writeAll("\t\t\tos = \"artinchip\";\n");
        try writer.print("\t\t\tload = <0x{x}>;\n", .{seg.load_addr});
        try writer.print("\t\t\tentry = <0x{x}>;\n", .{seg.entry});
        for (hash_algos, 0..) |algo, j| {
            try writer.print("\t\t\thash-{d} {{\n\t\t\t\talgo = \"{s}\";\n\t\t\t}};\n", .{ j + 1, algo });
        }
        try writer.writeAll("\t\t};\n");
    }
    try writer.writeAll("\t};\n\n\tconfigurations {\n");
    try writer.writeAll("\t\tdefault = \"conf-1\";\n\t\tconf-1 {\n");
    try writer.print("\t\t\tdescription = \"{s}\";\n", .{description});
    try writer.writeAll("\t\t\tfirmware = ");
    for (segs, 0..) |_, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("\"seg{d}\"", .{i});
    }
    try writer.writeAll(";\n\t\t};\n\t};\n};\n");
}

test "elf2its：段提取与 ITS 文本" {
    const allocator = std.testing.allocator;
    var elf: [0x140]u8 = @splat(0);
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 1;
    elf[5] = 1;
    elf[6] = 1;

    writeU32(&elf, 24, 0x40100000); // e_entry
    writeU32(&elf, 28, 52); // e_phoff
    writeU16(&elf, 42, 32); // e_phentsize
    writeU16(&elf, 44, 1); // e_phnum
    writeU32(&elf, 32, 0x100); // e_shoff
    writeU16(&elf, 46, 40); // e_shentsize
    writeU16(&elf, 48, 2); // e_shnum
    writeU16(&elf, 50, 0); // e_shstrndx

    // PT_LOAD
    const ph = 52;
    writeU32(&elf, ph + 0, PT_LOAD);
    writeU32(&elf, ph + 4, 0x120);
    writeU32(&elf, ph + 8, 0x40100000);
    writeU32(&elf, ph + 12, 0x40100000);
    writeU32(&elf, ph + 16, 4);
    writeU32(&elf, ph + 20, 8);

    // section 0: NULL
    // section 1: PROGBITS, ALLOC, addr 0x40100000, offset 0x120, size 4
    const sh = 0x100 + 40;
    writeU32(&elf, sh + 4, 1); // sh_type = SHT_PROGBITS
    writeU32(&elf, sh + 8, 2); // SHF_ALLOC
    writeU32(&elf, sh + 12, 0x40100000);
    writeU32(&elf, sh + 16, 0x120);
    writeU32(&elf, sh + 20, 4);
    @memcpy(elf[0x120..0x124], "ABCD");

    const segs = try itsSegments(allocator, &elf);
    defer freeItsSegments(allocator, segs);

    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqual(@as(u32, 0x40100000), segs[0].load_addr);
    try std.testing.expectEqualSlices(u8, "ABCD", segs[0].data);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try generateIts(&aw.writer, segs, "1.0.0", "Luban-lite firmware", &.{ "crc32", "md5" });
    const text = aw.written();
    try std.testing.expect(std.mem.find(u8, text, "data = /incbin/(\"./seg0.bin\");") != null);
    try std.testing.expect(std.mem.find(u8, text, "load = <0x40100000>;") != null);
    try std.testing.expect(std.mem.find(u8, text, "algo = \"crc32\";") != null);
    try std.testing.expect(std.mem.find(u8, text, "firmware = \"seg0\";") != null);
}

