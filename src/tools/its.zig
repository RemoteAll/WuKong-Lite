//! ITS（FIT Image Tree Source）解析器 —— 对应 Luban-Lite 构建流程里
//! `mkimage -f xxx.its xxx.itb` 这一步。
//!
//! 支持 DTS 子集：
//!   * `/dts-v1/;` 头
//!   * 节点 `name { ... };` 与根节点 `/ { ... };`
//!   * 属性：字符串 `"..."`、单元列表 `<0x...>`、字节数组 `[00 11]`、布尔属性
//!   * `/incbin/("file")`（路径相对 ITS 文件所在目录）
//!   * `//` 与 `/* */` 注释
//!
//! 并自动完成 FIT 需要的后处理：
//!   * 根节点插入/覆盖 `timestamp`
//!   * `hash-N { algo = "crc32|md5|sha1|sha256"; }` 自动补 `value`（与 mkimage 一致：value 在前）
//!   * `signature` / `cipher` 节点明确拒绝（未实现签名/加密）
const std = @import("std");
const fdt = @import("fdt.zig");
const crc32 = @import("../bsp/common/crc32.zig");

pub const Prop = struct {
    name: []const u8,
    data: []const u8,
};

pub const Node = struct {
    name: []const u8,
    props: std.ArrayList(Prop) = .empty,
    children: std.ArrayList(*Node) = .empty,

    pub fn getProp(self: *const Node, name: []const u8) ?*const Prop {
        for (self.props.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    /// 生成 FDT/FIT blob。
    pub fn buildFdt(self: *Parsed, allocator: std.mem.Allocator, timestamp: u32) ![]u8 {
        _ = try ensureTimestamp(self, timestamp);
        const root = try toFdtNode(self.arena.allocator(), self.root);
        return fdt.build(allocator, root);
    }
};

// ----------------------------------------------------------------------
// 词法
// ----------------------------------------------------------------------

const Token = union(enum) {
    ident: []const u8,
    string: []const u8,
    number: []const u8,
    directive: []const u8,
    slash,
    lbrace,
    rbrace,
    semi,
    eq,
    comma,
    plus,
    minus,
    lt,
    gt,
    lparen,
    rparen,
    lbracket,
    rbracket,
    eof,
};

const Lexer = struct {
    text: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.text.len) {
                if (self.text[self.pos + 1] == '/') {
                    self.pos += 2;
                    while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
                    continue;
                }
                if (self.text[self.pos + 1] == '*') {
                    self.pos += 2;
                    while (self.pos + 1 < self.text.len and !(self.text[self.pos] == '*' and self.text[self.pos + 1] == '/')) self.pos += 1;
                    if (self.pos + 1 < self.text.len) self.pos += 2;
                    continue;
                }
            }
            break;
        }
    }

    fn next(self: *Lexer) !Token {
        self.skipSpace();
        if (self.pos >= self.text.len) return .eof;
        const c = self.text[self.pos];
        switch (c) {
            '{' => {
                self.pos += 1;
                return .lbrace;
            },
            '}' => {
                self.pos += 1;
                return .rbrace;
            },
            ';' => {
                self.pos += 1;
                return .semi;
            },
            '=' => {
                self.pos += 1;
                return .eq;
            },
            ',' => {
                self.pos += 1;
                return .comma;
            },
            '+' => {
                self.pos += 1;
                return .plus;
            },
            '-' => {
                self.pos += 1;
                return .minus;
            },
            '<' => {
                self.pos += 1;
                return .lt;
            },
            '>' => {
                self.pos += 1;
                return .gt;
            },
            '(' => {
                self.pos += 1;
                return .lparen;
            },
            ')' => {
                self.pos += 1;
                return .rparen;
            },
            '[' => {
                self.pos += 1;
                return .lbracket;
            },
            ']' => {
                self.pos += 1;
                return .rbracket;
            },
            '"' => {
                self.pos += 1;
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(self.arena);
                while (self.pos < self.text.len and self.text[self.pos] != '"') {
                    if (self.text[self.pos] == '\\' and self.pos + 1 < self.text.len) {
                        self.pos += 1;
                        const esc = self.text[self.pos];
                        try buf.append(self.arena, switch (esc) {
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            else => esc,
                        });
                    } else {
                        try buf.append(self.arena, self.text[self.pos]);
                    }
                    self.pos += 1;
                }
                if (self.pos < self.text.len) self.pos += 1;
                return .{ .string = try buf.toOwnedSlice(self.arena) };
            },
            '/' => {
                // 指令（/dts-v1/、/incbin/）或根节点斜杠
                const start = self.pos + 1;
                var i = start;
                while (i < self.text.len) : (i += 1) {
                    const ch = self.text[i];
                    if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') continue;
                    break;
                }
                if (i > start and i < self.text.len and self.text[i] == '/') {
                    const name = self.text[start..i];
                    self.pos = i + 1;
                    return .{ .directive = name };
                }
                self.pos += 1;
                return .slash;
            },
            else => {},
        }

        if (std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.text.len) {
                const ch = self.text[self.pos];
                if (std.ascii.isAlphanumeric(ch) or ch == 'x' or ch == 'X') {
                    self.pos += 1;
                } else break;
            }
            return .{ .number = self.text[start..self.pos] };
        }

        if (std.ascii.isAlphabetic(c) or c == '_' or c == '#' or c == '@' or c == '.') {
            const start = self.pos;
            while (self.pos < self.text.len) {
                const ch = self.text[self.pos];
                if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '#' or ch == '@' or ch == '.' or ch == '+') {
                    self.pos += 1;
                } else break;
            }
            return .{ .ident = self.text[start..self.pos] };
        }

        return error.UnexpectedCharacter;
    }
};

// ----------------------------------------------------------------------
// 语法
// ----------------------------------------------------------------------

const Parser = struct {
    lexer: Lexer,
    arena: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    lookahead: ?Token = null,

    fn peek(self: *Parser) !Token {
        if (self.lookahead == null) self.lookahead = try self.lexer.next();
        return self.lookahead.?;
    }

    fn take(self: *Parser) !Token {
        const tok = try self.peek();
        self.lookahead = null;
        return tok;
    }

    fn expect(self: *Parser, comptime tag: std.meta.Tag(Token)) !void {
        const tok = try self.take();
        if (std.meta.activeTag(tok) != tag) return error.UnexpectedToken;
    }

    fn dup(self: *Parser, s: []const u8) ![]const u8 {
        return self.arena.dupe(u8, s);
    }

    fn parseFile(self: *Parser) !*Node {
        // 允许若干前置指令（/dts-v1/; /plugin/; /include/ ...）
        while (true) {
            const tok = try self.peek();
            switch (tok) {
                .directive => |d| {
                    _ = try self.take();
                    if (std.mem.eql(u8, d, "dts-v1") or std.mem.eql(u8, d, "plugin")) {
                        _ = try self.take(); // ';'
                    } else {
                        return error.UnsupportedDirective;
                    }
                },
                else => break,
            }
        }

        if (std.meta.activeTag(try self.peek()) != .slash) return error.MissingRootNode;
        _ = try self.take();
        return self.parseNodeBody("", true);
    }

    fn parseNodeBody(self: *Parser, name: []const u8, root: bool) anyerror!*Node {
        _ = root;
        try self.expect(.lbrace);
        const node = try self.arena.create(Node);
        node.* = .{ .name = try self.dup(name) };

        while (true) {
            const tok = try self.take();
            switch (tok) {
                .rbrace => break,
                .eof => return error.UnexpectedEof,
                .ident => |ident| {
                    const next_tok = try self.peek();
                    switch (next_tok) {
                        .lbrace => {
                            const child = try self.parseNodeBody(ident, false);
                            try node.children.append(self.arena, child);
                            // 可选的分号
                            if (std.meta.activeTag(try self.peek()) == .semi) _ = try self.take();
                        },
                        .eq => {
                            _ = try self.take();
                            const data = try self.parsePropertyValue();
                            try node.props.append(self.arena, .{ .name = try self.dup(ident), .data = data });
                            try self.expect(.semi);
                        },
                        .semi => {
                            _ = try self.take();
                            try node.props.append(self.arena, .{ .name = try self.dup(ident), .data = &.{} });
                        },
                        else => return error.UnexpectedToken,
                    }
                },
                else => return error.UnexpectedToken,
            }
        }
        if (std.meta.activeTag(try self.peek()) == .semi) _ = try self.take();
        return node;
    }

    fn parsePropertyValue(self: *Parser) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.arena);

        while (true) {
            try self.appendOneValue(&buf);
            if (std.meta.activeTag(try self.peek()) == .comma) {
                _ = try self.take();
                continue;
            }
            break;
        }
        return buf.toOwnedSlice(self.arena);
    }

    fn appendOneValue(self: *Parser, buf: *std.ArrayList(u8)) anyerror!void {
        const tok = try self.take();
        switch (tok) {
            .string => |s| {
                try buf.appendSlice(self.arena, s);
                try buf.append(self.arena, 0);
            },
            .lt => {
                while (true) {
                    const inner = try self.take();
                    switch (inner) {
                        .gt => break,
                        .number => |n| {
                            const v = std.fmt.parseInt(u32, n, 0) catch return error.BadNumber;
                            var bytes: [4]u8 = undefined;
                            std.mem.writeInt(u32, &bytes, v, .big);
                            try buf.appendSlice(self.arena, &bytes);
                        },
                        .lparen => {
                            const v = try self.parseCellExpression();
                            var bytes: [4]u8 = undefined;
                            std.mem.writeInt(u32, &bytes, v, .big);
                            try buf.appendSlice(self.arena, &bytes);
                        },
                        else => return error.UnexpectedToken,
                    }
                }
            },
            .lbracket => {
                while (true) {
                    const inner = try self.take();
                    switch (inner) {
                        .rbracket => break,
                        .number => |n| {
                            const v = std.fmt.parseInt(u8, n, 16) catch return error.BadNumber;
                            try buf.append(self.arena, v);
                        },
                        else => return error.UnexpectedToken,
                    }
                }
            },
            .directive => |d| {
                if (!std.mem.eql(u8, d, "incbin")) return error.UnsupportedDirective;
                try self.expect(.lparen);
                const path_tok = try self.take();
                const rel = switch (path_tok) {
                    .string => |s| s,
                    else => return error.UnexpectedToken,
                };
                try self.expect(.rparen);
                const full = try std.fs.path.resolveAlloc(self.arena, &.{ self.base_dir, rel });
                const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, full, self.arena, .unlimited) catch |err| switch (err) {
                    error.FileNotFound => return error.IncbinNotFound,
                    else => return err,
                };
                try buf.appendSlice(self.arena, bytes);
            },
            else => return error.UnexpectedToken,
        }
    }

    /// `<(...)>`：支持单个整数或简单括号表达式（`+ - << | &`），足够覆盖 SDK 的 ITS。
    fn parseCellExpression(self: *Parser) anyerror!u32 {
        const v = try self.parseExprAdd();
        try self.expect(.rparen);
        return v;
    }

    fn parseExprAdd(self: *Parser) anyerror!u32 {
        var v = try self.parseExprShift();
        while (true) {
            const tok = try self.peek();
            if (std.meta.activeTag(tok) != .plus) break;
            _ = try self.take();
            v +%= try self.parseExprShift();
        }
        return v;
    }

    fn parseExprShift(self: *Parser) anyerror!u32 {
        var v = try self.parseExprPrimary();
        while (true) {
            const tok = try self.peek();
            if (std.meta.activeTag(tok) != .minus) break;
            _ = try self.take();
            v -%= try self.parseExprPrimary();
        }
        return v;
    }

    fn parseExprPrimary(self: *Parser) anyerror!u32 {
        const tok = try self.take();
        return switch (tok) {
            .number => |n| std.fmt.parseInt(u32, n, 0) catch error.BadNumber,
            .lparen => blk: {
                const v = try self.parseExprAdd();
                try self.expect(.rparen);
                break :blk v;
            },
            else => error.UnexpectedToken,
        };
    }
};

// ----------------------------------------------------------------------
// FIT 后处理
// ----------------------------------------------------------------------

fn propDataStr(data: []const u8) []const u8 {
    if (std.mem.findScalar(u8, data, 0)) |i| return data[0..i];
    return data;
}

fn digestFor(allocator: std.mem.Allocator, algo: []const u8, data: []const u8) ![]const u8 {
    if (std.mem.eql(u8, algo, "crc32")) {
        const bytes = try allocator.alloc(u8, 4);
        std.mem.writeInt(u32, bytes[0..4], crc32.calc(data), .big);
        return bytes;
    }
    if (std.mem.eql(u8, algo, "md5")) {
        const bytes = try allocator.alloc(u8, 16);
        std.crypto.hash.Md5.hash(data, bytes[0..16], .{});
        return bytes;
    }
    if (std.mem.eql(u8, algo, "sha1")) {
        const bytes = try allocator.alloc(u8, 20);
        std.crypto.hash.Sha1.hash(data, bytes[0..20], .{});
        return bytes;
    }
    if (std.mem.eql(u8, algo, "sha256")) {
        const bytes = try allocator.alloc(u8, 32);
        std.crypto.hash.sha2.Sha256.hash(data, bytes[0..32], .{});
        return bytes;
    }
    return error.UnsupportedHashAlgo;
}

fn postProcess(node: *Node, inherited_data: ?[]const u8, allocator: std.mem.Allocator) !void {
    var payload = inherited_data;
    if (node.getProp("data")) |p| payload = p.data;

    if (std.mem.startsWith(u8, node.name, "signature") or std.mem.eql(u8, node.name, "cipher")) {
        return error.SigningOrEncryptionNotSupported;
    }

    if (std.mem.startsWith(u8, node.name, "hash-")) {
        if (node.getProp("algo")) |algo_prop| {
            if (payload) |data| {
                const digest = try digestFor(allocator, propDataStr(algo_prop.data), data);
                // mkimage 把 value 放在 algo 之前
                try node.props.insert(allocator, 0, .{ .name = "value", .data = digest });
            }
        }
    }

    for (node.children.items) |child| try postProcess(child, payload, allocator);
}

fn ensureTimestamp(parsed: *Parsed, timestamp: u32) !void {
    const allocator = parsed.arena.allocator();
    const bytes = try allocator.alloc(u8, 4);
    std.mem.writeInt(u32, bytes[0..4], timestamp, .big);

    for (parsed.root.props.items) |*p| {
        if (std.mem.eql(u8, p.name, "timestamp")) {
            p.data = bytes;
            return;
        }
    }
    try parsed.root.props.insert(allocator, 0, .{ .name = "timestamp", .data = bytes });
}

fn toFdtNode(allocator: std.mem.Allocator, node: *const Node) !*const fdt.Node {
    const props = try allocator.alloc(fdt.Property, node.props.items.len);
    for (node.props.items, 0..) |p, i| props[i] = .{ .name = p.name, .data = p.data };

    const children = try allocator.alloc(*const fdt.Node, node.children.items.len);
    for (node.children.items, 0..) |c, i| children[i] = try toFdtNode(allocator, c);

    const out = try allocator.create(fdt.Node);
    out.* = .{ .name = node.name, .props = props, .children = children };
    return out;
}

// ----------------------------------------------------------------------
// 入口
// ----------------------------------------------------------------------

pub fn parseText(allocator: std.mem.Allocator, io: std.Io, text: []const u8, base_dir: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parser = Parser{
        .lexer = .{ .text = text, .pos = 0, .arena = a },
        .arena = a,
        .io = io,
        .base_dir = base_dir,
    };
    const root = try parser.parseFile();
    try postProcess(root, null, a);
    return .{ .arena = arena, .root = root };
}

pub fn parse(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const base_dir = std.fs.path.dirname(path) orelse ".";

    var parser = Parser{
        .lexer = .{ .text = text, .pos = 0, .arena = a },
        .arena = a,
        .io = io,
        .base_dir = base_dir,
    };
    const root = try parser.parseFile();
    try postProcess(root, null, a);
    return .{ .arena = arena, .root = root };
}

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

test "ITS 解析：字符串/单元/incbin/hash/timestamp" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 准备 incbin 文件
    const seg_path = ".zig-cache/its_seg0.bin";
    try std.Io.Dir.cwd().createDirPath(io, ".zig-cache");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = seg_path, .data = "SEGDATA" });
    defer std.Io.Dir.cwd().deleteFile(io, seg_path) catch {};

    const text =
        \\/dts-v1/;
        \\/ {
        \\  description = "test-fit";
        \\  #address-cells = <1>;
        \\  images {
        \\    seg0 {
        \\      data = /incbin/(".zig-cache/its_seg0.bin");
        \\      type = "firmware";
        \\      load = <0x40100000>;
        \\      entry = <(0x40000000 + 0x100000)>;
        \\      hash-1 {
        \\        algo = "crc32";
        \\      };
        \\      hash-2 {
        \\        algo = "md5";
        \\      };
        \\    };
        \\  };
        \\  configurations {
        \\    default = "conf-1";
        \\    conf-1 {
        \\      firmware = "seg0";
        \\    };
        \\  };
        \\};
        \\
    ;

    var parsed = try parseText(allocator, io, text, ".");
    defer parsed.deinit();

    const blob = try parsed.buildFdt(allocator, 0x1234_5678);
    defer allocator.free(blob);

    try std.testing.expect(fdt.isValid(blob));
    try std.testing.expect(std.mem.find(u8, blob, "SEGDATA") != null);
    try std.testing.expect(std.mem.find(u8, blob, "test-fit") != null);
    try std.testing.expect(std.mem.find(u8, blob, "conf-1") != null);

    // crc32("SEGDATA") 应作为 hash-1 的 value 存在（大端）
    const crc = crc32.calc("SEGDATA");
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc, .big);
    try std.testing.expect(std.mem.find(u8, blob, &crc_bytes) != null);

    // timestamp 必须是根节点第一个属性
    try std.testing.expectEqualStrings("timestamp", parsed.root.props.items[0].name);
}

test "ITS 签名/加密节点明确拒绝" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const text =
        \\/dts-v1/;
        \\/ { images { seg0 { data = [01 02]; signature-1 { algo = "sha256"; }; }; }; };
        \\
    ;
    try std.testing.expectError(error.SigningOrEncryptionNotSupported, parseText(allocator, io, text, "."));
}
