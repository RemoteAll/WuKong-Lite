//! 崩溃日志（panic dump）解析 —— 对应参考工程 `tools/scripts/panic_parse.py`。
//!
//! 输入：串口打印的崩溃日志 + 对应的 ELF。
//! 输出：CPU 异常类型、寄存器（代码段内的值给出 `file:line` 或 `symbol+offset`）、
//!       从 `stack:` 段里挑出落在代码段内的返回地址并逐条定位。
//!
//! 与参考实现的差异：
//!   * `__stext` / `__etext` 由本模块**自己解析 ELF 符号表**得到（参考脚本调用 `readelf` + `findstr`）；
//!   * 行号定位优先调用 `--addr2line` 指定的工具（默认 `toolchain/bin/riscv64-unknown-elf-addr2line`）；
//!     工具缺失时退化为 `symbol+0xNN`，不会像参考脚本那样直接失败退出。
const std = @import("std");

pub const Cpu = enum { riscv, csky };

pub const Register = struct {
    name: []const u8,
    value: u32,
};

pub const Frame = struct {
    addr: u32,
};

/// 单个寄存器的定位结果。
pub const Located = struct {
    /// `file:line`（addr2line）或 `symbol+0xNN`；空表示无法定位。
    text: []u8,
    pub fn deinit(self: *Located, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Report = struct {
    cpu: Cpu,
    exception: u8,
    exception_name: []const u8,
    regs: []Register,
    text_start: u32,
    text_end: u32,
    stack_start: u32,
    stack_end: u32,
    frames: []Frame,
    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.regs);
        allocator.free(self.frames);
        self.* = undefined;
    }

    pub fn inText(self: *const Report, addr: u32) bool {
        return addr >= self.text_start and addr <= self.text_end;
    }
};

// ---------------------------------------------------------------------------
// ELF 符号表
// ---------------------------------------------------------------------------
pub const Symbol = struct {
    name: []const u8,
    value: u64,
    size: u64,
    is_func: bool,
};

pub const SymTab = struct {
    arena: std.heap.ArenaAllocator,
    symbols: []Symbol,

    pub fn deinit(self: *SymTab) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// 按名字精确查符号值。
    pub fn valueOf(self: *const SymTab, name: []const u8) ?u64 {
        for (self.symbols) |s| {
            if (std.mem.eql(u8, s.name, name)) return s.value;
        }
        return null;
    }

    /// 找 <= addr 且最接近的符号（优先函数符号），返回 `symbol+0xNN` 形式的描述。
    pub fn describe(self: *const SymTab, allocator: std.mem.Allocator, addr: u64) ![]u8 {
        var best: ?Symbol = null;
        for (self.symbols) |s| {
            if (s.value == 0 or s.value > addr) continue;
            const better = if (best) |b|
                (s.is_func and !b.is_func) or (s.is_func == b.is_func and s.value >= b.value)
            else
                true;
            if (better) best = s;
        }
        const b = best orelse return allocator.dupe(u8, "");
        if (b.name.len == 0) return allocator.dupe(u8, "");
        return std.fmt.allocPrint(allocator, "{s}+0x{x}", .{ b.name, addr - b.value });
    }
};

fn readU16(data: []const u8, off: usize, endian: std.builtin.Endian) !u16 {
    if (off + 2 > data.len) return error.BadElf;
    return std.mem.readInt(u16, data[off..][0..2], endian);
}

fn readU32(data: []const u8, off: usize, endian: std.builtin.Endian) !u32 {
    if (off + 4 > data.len) return error.BadElf;
    return std.mem.readInt(u32, data[off..][0..4], endian);
}

fn readU64(data: []const u8, off: usize, endian: std.builtin.Endian) !u64 {
    if (off + 8 > data.len) return error.BadElf;
    return std.mem.readInt(u64, data[off..][0..8], endian);
}

/// 解析 ELF 的 `.symtab`（ELF32/ELF64，大/小端均可）。
pub fn parseSymbols(allocator: std.mem.Allocator, data: []const u8) !SymTab {
    if (data.len < 0x34) return error.BadElf;
    if (!std.mem.eql(u8, data[0..4], "\x7fELF")) return error.BadElf;
    const class = data[4];
    const endian: std.builtin.Endian = switch (data[5]) {
        1 => .little,
        2 => .big,
        else => return error.BadElf,
    };
    const is64 = class == 2;

    const shoff: u64 = if (is64)
        try readU64(data, 0x28, endian)
    else
        try readU32(data, 0x20, endian);
    const shentsize: u16 = if (is64)
        try readU16(data, 0x3A, endian)
    else
        try readU16(data, 0x2E, endian);
    const shnum: u16 = if (is64)
        try readU16(data, 0x3C, endian)
    else
        try readU16(data, 0x30, endian);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(aa);

    var idx: usize = 0;
    while (idx < shnum) : (idx += 1) {
        const base = @as(usize, @intCast(shoff)) + idx * shentsize;
        if (base + shentsize > data.len) break;
        const sh_type = try readU32(data, base + 4, endian);
        if (sh_type != 2) continue; // SHT_SYMTAB
        const sh_offset: u64 = if (is64)
            try readU64(data, base + 0x18, endian)
        else
            try readU32(data, base + 0x10, endian);
        const sh_size: u64 = if (is64)
            try readU64(data, base + 0x20, endian)
        else
            try readU32(data, base + 0x14, endian);
        const sh_link = try readU32(data, base + (if (is64) @as(usize, 0x28) else 0x18), endian);

        // 取字符串表
        const str_base = @as(usize, @intCast(shoff)) + @as(usize, sh_link) * shentsize;
        if (str_base + shentsize > data.len) continue;
        const str_off: u64 = if (is64)
            try readU64(data, str_base + 0x18, endian)
        else
            try readU32(data, str_base + 0x10, endian);
        const str_size: u64 = if (is64)
            try readU64(data, str_base + 0x20, endian)
        else
            try readU32(data, str_base + 0x14, endian);
        if (str_off + str_size > data.len) continue;
        const strtab = data[@intCast(str_off)..@intCast(str_off + str_size)];

        const entsize: usize = if (is64) 24 else 16;
        var off: usize = @intCast(sh_offset);
        const end: usize = @intCast(sh_offset + sh_size);
        while (off + entsize <= end and off + entsize <= data.len) : (off += entsize) {
            const st_name = try readU32(data, off, endian);
            const st_value: u64 = if (is64)
                try readU64(data, off + 8, endian)
            else
                try readU32(data, off + 4, endian);
            const st_size: u64 = if (is64)
                try readU64(data, off + 16, endian)
            else
                try readU32(data, off + 8, endian);
            const st_info = data[off + (if (is64) @as(usize, 4) else 12)];
            const st_shndx = try readU16(data, off + (if (is64) @as(usize, 6) else 14), endian);
            if (st_shndx == 0 or st_name >= strtab.len) continue; // UNDEF / 无名
            const name_end = std.mem.findScalarPos(u8, strtab, st_name, 0) orelse strtab.len;
            const name = strtab[st_name..name_end];
            try symbols.append(aa, .{
                .name = name,
                .value = st_value,
                .size = st_size,
                .is_func = (st_info & 0xf) == 2,
            });
        }
    }

    return .{ .arena = arena, .symbols = try symbols.toOwnedSlice(aa) };
}

// ---------------------------------------------------------------------------
// 日志解析
// ---------------------------------------------------------------------------
fn riscvExceptionName(code: u8) []const u8 {
    return switch (code) {
        0 => "Reserved",
        1 => "Fetch Instruction Access Fault",
        2 => "Illegal Instruction",
        3 => "Breakpoint Fault",
        4 => "Load Instruction Address Misaligned",
        5 => "Load Instruction Access Fault",
        6 => "Store/AMO Address Misaligned",
        7 => "Store/AMO Access Fault",
        8 => "Environment Call from U-Mode",
        9 => "Environment Call from S-Mode",
        11 => "Environment Call from M-Mode",
        12 => "Fetch Instruction page error",
        13 => "Load Instruction page error",
        15 => "Store/AMO Instruction page error",
        24 => "NMI",
        else => "Unknown",
    };
}

fn cskyExceptionName(code: u8) []const u8 {
    return switch (code) {
        0 => "Reset Fault",
        1 => "Instruction Address Misaligned",
        2 => "Instruction Access Fault",
        4 => "Illegal Instruction",
        5 => "Privileged Instruction",
        7 => "Breakpoint Fault",
        8 => "Unrecoverable Fault",
        16 => "TRAP0 Fault",
        17 => "TRAP1 Fault",
        18 => "TRAP2 Fault",
        19 => "TRAP3 Fault",
        22 => "Tspend interrupt",
        else => "Unknown",
    };
}

/// RISC-V 寄存器别名（与参考脚本一致）。
pub fn regAlias(name: []const u8) []const u8 {
    const table = .{
        .{ "x0", "zero" }, .{ "x1", "ra" },  .{ "x2", "sp" },  .{ "x3", "gp" },
        .{ "x4", "tp" },   .{ "x5", "t0" },  .{ "x6", "t1" },  .{ "x7", "t2" },
        .{ "x8", "s0/fp" }, .{ "x9", "s1" }, .{ "x10", "a0" }, .{ "x11", "a1" },
        .{ "x12", "a2" },  .{ "x13", "a3" }, .{ "x14", "a4" }, .{ "x15", "a5" },
        .{ "x16", "a6" },  .{ "x17", "a7" }, .{ "x18", "s2" }, .{ "x19", "s3" },
        .{ "x20", "s4" },  .{ "x21", "s5" }, .{ "x22", "s6" }, .{ "x23", "s7" },
        .{ "x24", "s8" },  .{ "x25", "s9" }, .{ "x26", "s10" }, .{ "x27", "s11" },
        .{ "x28", "t3" },  .{ "x29", "t4" }, .{ "x30", "t5" }, .{ "x31", "t6" },
    };
    inline for (table) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return "";
}

fn hexValue(text: []const u8) ?u32 {
    var t = std.mem.trim(u8, text, " \t\r\n,");
    if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) t = t[2..];
    if (t.len == 0) return null;
    return std.fmt.parseInt(u32, t, 16) catch null;
}

fn findValueAfterColon(line: []const u8) ?u32 {
    const colon = std.mem.findScalar(u8, line, ':') orelse return null;
    return hexValue(line[colon + 1 ..]);
}

/// 解析日志中的寄存器与异常号（顺序与日志一致）。
pub fn parseRegisters(
    allocator: std.mem.Allocator,
    log: []const u8,
    cpu: Cpu,
) !struct { exception: u8, regs: []Register } {
    var regs: std.ArrayList(Register) = .empty;
    errdefer regs.deinit(allocator);
    var exception: u8 = 0xFF;
    var found = false;

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!found) {
            if (std.mem.find(u8, line, "CPU Exception:") == null) continue;
            if (std.mem.find(u8, line, "NO.")) |p| {
                const digits = line[p + 3 ..];
                var n: usize = 0;
                while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
                exception = std.fmt.parseInt(u8, digits[0..n], 10) catch 0xFF;
            }
            found = true;
            continue;
        }
        if (line.len < 2) continue;

        const specials: []const []const u8 = switch (cpu) {
            .riscv => &.{ "mcause", "mtval", "mepc", "mstatus" },
            .csky => &.{ "epsr", "epc" },
        };
        var matched = false;
        for (specials) |name| {
            if (!matched and std.mem.find(u8, line, name) != null) {
                if (findValueAfterColon(line)) |v| {
                    try regs.append(allocator, .{ .name = name, .value = v });
                    matched = true;
                }
            }
        }
        if (matched) continue;

        if (std.mem.find(u8, line, ": ") == null) continue;
        // 形如 `x1: 0x00000000` 或 `x1 : 0x0 x2 : 0x0`：按冒号/空白切分后两两成对
        var it = std.mem.tokenizeAny(u8, line, ": \t");
        while (it.next()) |name| {
            const val = it.next() orelse break;
            if (hexValue(val)) |v| {
                try regs.append(allocator, .{ .name = name, .value = v });
            }
        }
    }

    return .{ .exception = exception, .regs = try regs.toOwnedSlice(allocator) };
}

fn findAddrAfter(log: []const u8, key: []const u8) u32 {
    const p = std.mem.find(u8, log, key) orelse return 0;
    var rest = std.mem.trimStart(u8, log[p + key.len ..], " \t");
    if (std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X")) rest = rest[2..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isHex(rest[n])) n += 1;
    if (n == 0) return 0;
    return std.fmt.parseInt(u32, rest[0..n], 16) catch 0;
}

/// 解析 `stack:` 之后出现的所有 0x 地址。
pub fn parseStackAddrs(allocator: std.mem.Allocator, log: []const u8) ![]u32 {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(allocator);

    const marker = std.mem.find(u8, log, "stack:") orelse return list.toOwnedSlice(allocator);
    var rest = log[marker + "stack:".len ..];
    if (std.mem.find(u8, rest, "stack:")) |next| rest = rest[0..next];

    var i: usize = 0;
    while (i + 1 < rest.len) : (i += 1) {
        if (rest[i] != '0' or (rest[i + 1] != 'x' and rest[i + 1] != 'X')) continue;
        var j = i + 2;
        while (j < rest.len and std.ascii.isHex(rest[j])) j += 1;
        if (j > i + 2) {
            if (std.fmt.parseInt(u32, rest[i + 2 .. j], 16)) |v| {
                try list.append(allocator, v);
            } else |_| {}
        }
        i = j - 1;
    }
    return list.toOwnedSlice(allocator);
}

pub const AnalyzeOptions = struct {
    log: []const u8,
    elf: ?[]const u8 = null,
    cpu: Cpu = .riscv,
};

/// 解析日志 + ELF，得到结构化报告。
pub fn analyze(allocator: std.mem.Allocator, opts: AnalyzeOptions) !Report {
    const parsed = try parseRegisters(allocator, opts.log, opts.cpu);
    errdefer allocator.free(parsed.regs);

    var text_start: u32 = 0;
    var text_end: u32 = 0;
    if (opts.elf) |elf| {
        var tab = try parseSymbols(allocator, elf);
        defer tab.deinit();
        if (tab.valueOf("__stext")) |v| text_start = @intCast(v);
        if (tab.valueOf("__etext")) |v| text_end = @intCast(v);
    }

    var frames: std.ArrayList(Frame) = .empty;
    errdefer frames.deinit(allocator);
    if (opts.elf != null) {
        const addrs = try parseStackAddrs(allocator, opts.log);
        defer allocator.free(addrs);
        for (addrs) |a| {
            if (a >= text_start and a <= text_end) try frames.append(allocator, .{ .addr = a });
        }
    }

    return .{
        .cpu = opts.cpu,
        .exception = parsed.exception,
        .exception_name = switch (opts.cpu) {
            .riscv => riscvExceptionName(parsed.exception),
            .csky => cskyExceptionName(parsed.exception),
        },
        .regs = parsed.regs,
        .text_start = text_start,
        .text_end = text_end,
        .stack_start = findAddrAfter(opts.log, "stack_addr:"),
        .stack_end = findAddrAfter(opts.log, "stack_addr_end:"),
        .frames = try frames.toOwnedSlice(allocator),
    };
}

/// 通过外部 `addr2line` 定位（形如 `<tool> -e <elf> -fp 0xADDR`）。
/// 工具不可用时返回空串，由调用方退化为 `symbol+0xNN`。
pub fn locateWithAddr2Line(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool: []const u8,
    elf_path: []const u8,
    addr: u32,
    sdk_dir: ?[]const u8,
) ![]u8 {
    var buf: [32]u8 = undefined;
    const addr_text = try std.fmt.bufPrint(&buf, "0x{x}", .{addr});
    const result = std.process.run(allocator, io, .{
        .argv = &.{ tool, "-e", elf_path, "-fp", addr_text },
    }) catch return allocator.dupe(u8, "");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return allocator.dupe(u8, "");

    const text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (text.len == 0 or std.mem.eql(u8, text, "??:0") or std.mem.eql(u8, text, "??:?")) {
        return allocator.dupe(u8, "");
    }
    if (sdk_dir) |dir| {
        if (std.mem.find(u8, text, dir) != null) {
            return std.mem.replaceOwned(u8, allocator, text, dir, "");
        }
    }
    return allocator.dupe(u8, text);
}

test "panic：解析 RISC-V 寄存器与异常号" {
    const a = std.testing.allocator;
    const log =
        \\CPU Exception: NO.5
        \\mepc: 0x400ef010
        \\mcause: 0x00000005
        \\x1:  0x41000100 x2 : 0x41000200
        \\stack_addr:0x41000000
        \\stack_addr_end:0x41001000
        \\stack:
        \\ 0x41000100 0x400ef010 0x10000000
    ;
    var report = try analyze(a, .{ .log = log });
    defer report.deinit(a);
    try std.testing.expectEqual(@as(u8, 5), report.exception);
    try std.testing.expectEqualStrings("Load Instruction Access Fault", report.exception_name);
    try std.testing.expectEqual(@as(usize, 4), report.regs.len);
    try std.testing.expectEqualStrings("mepc", report.regs[0].name);
    try std.testing.expectEqual(@as(u32, 0x400ef010), report.regs[0].value);
    try std.testing.expectEqual(@as(u32, 0x41000200), report.regs[3].value);
    try std.testing.expectEqual(@as(u32, 0x41000000), report.stack_start);
    try std.testing.expectEqual(@as(u32, 0x41001000), report.stack_end);
}

test "panic：栈地址只保留代码段内的值" {
    const a = std.testing.allocator;
    const log =
        \\CPU Exception: NO.2
        \\stack:
        \\  0x40001000 0x10000000 0x40002000
    ;
    const addrs = try parseStackAddrs(a, log);
    defer a.free(addrs);
    try std.testing.expectEqual(@as(usize, 3), addrs.len);
    try std.testing.expectEqual(@as(u32, 0x40001000), addrs[0]);
}

test "panic：寄存器别名表" {
    try std.testing.expectEqualStrings("sp", regAlias("x2"));
    try std.testing.expectEqualStrings("s0/fp", regAlias("x8"));
    try std.testing.expectEqualStrings("", regAlias("mepc"));
}

test "panic：ELF32 符号表解析（自造最小 ELF）" {
    const a = std.testing.allocator;
    // 布局：49 字节 ELF 头 + shstrtab? 这里只用 symtab 的 sh_link 指向 strtab 节。
    // 简化：2 个节头（0: NULL, 1: strtab, 2: symtab）
    const ehdr_size = 52;
    const shent = 40;
    const strtab = "\x00__stext\x00__etext\x00";
    const sym_ent = 16;
    const symtab_size = sym_ent * 3;

    const shoff = ehdr_size;
    const str_off = shoff + shent * 3;
    const sym_off = str_off + strtab.len;
    const total = sym_off + symtab_size;

    var buf = try a.alloc(u8, total);
    defer a.free(buf);
    @memset(buf, 0);

    // ELF 头
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 1; // ELF32
    buf[5] = 1; // little endian
    buf[6] = 1; // version
    std.mem.writeInt(u32, buf[0x20..][0..4], shoff, .little);
    std.mem.writeInt(u16, buf[0x2E..][0..2], shent, .little);
    std.mem.writeInt(u16, buf[0x30..][0..2], 3, .little);

    // 节 1：strtab
    std.mem.writeInt(u32, buf[shoff + shent + 4 ..][0..4], 3, .little); // SHT_STRTAB
    std.mem.writeInt(u32, buf[shoff + shent + 0x10 ..][0..4], str_off, .little);
    std.mem.writeInt(u32, buf[shoff + shent + 0x14 ..][0..4], strtab.len, .little);

    // 节 2：symtab（link=1）
    std.mem.writeInt(u32, buf[shoff + 2 * shent + 4 ..][0..4], 2, .little); // SHT_SYMTAB
    std.mem.writeInt(u32, buf[shoff + 2 * shent + 0x10 ..][0..4], sym_off, .little);
    std.mem.writeInt(u32, buf[shoff + 2 * shent + 0x14 ..][0..4], symtab_size, .little);
    std.mem.writeInt(u32, buf[shoff + 2 * shent + 0x18 ..][0..4], 1, .little); // sh_link

    @memcpy(buf[str_off..][0..strtab.len], strtab);

    // 符号 1：__stext = 0x40000000
    const s1 = sym_off + sym_ent;
    std.mem.writeInt(u32, buf[s1..][0..4], 1, .little); // name offset
    std.mem.writeInt(u32, buf[s1 + 4 ..][0..4], 0x40000000, .little);
    std.mem.writeInt(u32, buf[s1 + 8 ..][0..4], 0x100, .little);
    buf[s1 + 12] = 0x12; // STT_FUNC
    std.mem.writeInt(u16, buf[s1 + 14 ..][0..2], 1, .little); // shndx

    // 符号 2：__etext = 0x40001000
    const s2 = sym_off + sym_ent * 2;
    std.mem.writeInt(u32, buf[s2..][0..4], 9, .little);
    std.mem.writeInt(u32, buf[s2 + 4 ..][0..4], 0x40001000, .little);
    buf[s2 + 12] = 0x12;
    std.mem.writeInt(u16, buf[s2 + 14 ..][0..2], 1, .little);

    var tab = try parseSymbols(a, buf);
    defer tab.deinit();
    try std.testing.expectEqual(@as(?u64, 0x40000000), tab.valueOf("__stext"));
    try std.testing.expectEqual(@as(?u64, 0x40001000), tab.valueOf("__etext"));

    const desc = try tab.describe(a, 0x40000042);
    defer a.free(desc);
    try std.testing.expectEqualStrings("__stext+0x42", desc);
}
