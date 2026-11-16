//! Kconfig 配置系统 —— 复刻 Luban-Lite 的方案配置流程：
//!
//!   target/configs/<prj>_defconfig  +  Kconfig 树
//!        -> .config            （等价 SConstruct 里 chk_prj_config 的产物）
//!        -> cconfig.h          （C 侧宏定义）
//!
//! 支持的核心语法：
//!   * config / menuconfig 声明，bool / tristate / string / int / hex 类型
//!   * def_bool / def_tristate
//!   * prompt、default（可带 if 条件）、depends on、select、range
//!   * if ... endif 条件块、menu ... endmenu、choice ... endchoice（仅作分组）
//!   * source "相对路径"（支持尾部 * 通配）
//!   * help / ---help--- 帮助块
//!   * option env="NAME"（记录，不参与求值）
//!
//! 表达式求值：`!`、`&&`、`||`、`=`、`!=`、括号；bool/tristate 以 y/m/n 参与比较，
//! 未定义的符号按 `n` 处理。
const std = @import("std");

pub const ItemType = enum { unknown, bool_, tristate, string, int_, hex };

fn isBoolType(t: ItemType) bool {
    return t == .bool_ or t == .tristate;
}

pub const Expr = union(enum) {
    symbol: []const u8,
    literal: []const u8,
    not: *const Expr,
    and_: struct { lhs: *const Expr, rhs: *const Expr },
    or_: struct { lhs: *const Expr, rhs: *const Expr },
    eq: struct { lhs: *const Expr, rhs: *const Expr, negate: bool },
};

pub const Default = struct {
    value: *const Expr,
    cond: ?*const Expr = null,
};

pub const Select = struct {
    target: []const u8,
    cond: ?*const Expr = null,
};

pub const Item = struct {
    name: []const u8,
    typ: ItemType = .unknown,
    prompt: ?[]const u8 = null,
    defaults: []const Default = &.{},
    depends: ?*const Expr = null,
    selects: []const Select = &.{},
    help: []const u8 = "",
    env_var: ?[]const u8 = null,
    /// 已求值的配置值："y"/"m"、字符串、十进制或 0x 数字。
    value: ?[]const u8 = null,
    /// 值来自 defconfig 或用户 set，select 不得覆盖。
    explicit: bool = false,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    index: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .index = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.items.deinit(self.index.allocator);
        self.index.deinit();
        self.arena.deinit();
    }

    fn alloc(self: *Config) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn addItem(self: *Config, name: []const u8) !usize {
        const dup = try self.alloc().dupe(u8, name);
        const id = self.items.items.len;
        try self.items.append(self.index.allocator, .{ .name = dup });
        try self.index.put(dup, id);
        return id;
    }

    pub fn find(self: *Config, name: []const u8) ?*Item {
        const id = self.index.get(name) orelse return null;
        return &self.items.items[id];
    }

    pub fn get(self: *Config, name: []const u8) ?[]const u8 {
        const it = self.find(name) orelse return null;
        return it.value;
    }

    /// 手动设置一个值（`wk config set` / defconfig 共用）。
    pub fn set(self: *Config, name: []const u8, value: []const u8) !void {
        const it = self.find(name) orelse return error.UnknownSymbol;
        it.value = try self.alloc().dupe(u8, value);
        it.explicit = true;
    }

    // ------------------------------------------------------------------
    // 文本解析
    // ------------------------------------------------------------------

    /// 解析一段 Kconfig 文本。`conds` 为外层 if 条件栈（source 递归时复用）。
    pub fn parseText(self: *Config, text: []const u8, conds: *std.ArrayList(*const Expr), io: ?std.Io, base_dir: []const u8, depth: usize) anyerror!void {
        if (depth > 16) return error.SourceTooDeep;
        var current: ?usize = null;
        var cur_depends: ?*const Expr = null;
        var cur_defaults: std.ArrayList(Default) = .empty;
        defer cur_defaults.deinit(self.alloc());
        var cur_selects: std.ArrayList(Select) = .empty;
        defer cur_selects.deinit(self.alloc());
        var cur_prompt: ?[]const u8 = null;
        var cur_type: ItemType = .unknown;
        var cur_env: ?[]const u8 = null;
        var cur_help: std.ArrayList(u8) = .empty;
        defer cur_help.deinit(self.alloc());

        var lines = std.mem.splitScalar(u8, text, '\n');
        var pending_help = false;
        var help_indent: usize = 0;

        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const stripped = std.mem.trim(u8, line, " \t");

            // help 块：缩进行（或空行）属于帮助文本
            if (pending_help) {
                if (stripped.len == 0) {
                    try cur_help.appendSlice(self.alloc(), "\n");
                    continue;
                }
                const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
                if (help_indent == 0) help_indent = indent;
                if (indent >= help_indent) {
                    try cur_help.appendSlice(self.alloc(), stripped);
                    try cur_help.append(self.alloc(), '\n');
                    continue;
                }
                pending_help = false;
            }
            if (stripped.len == 0) continue;
            if (std.mem.startsWith(u8, stripped, "#")) continue;

            const kw_end = std.mem.findAny(u8, stripped, " \t") orelse stripped.len;
            const kw = stripped[0..kw_end];
            const rest = std.mem.trim(u8, stripped[kw_end..], " \t");

            if (std.mem.eql(u8, kw, "config") or std.mem.eql(u8, kw, "menuconfig")) {
                try self.finishItem(&current, cur_type, cur_prompt, cur_depends, &cur_defaults, &cur_selects, cur_env, &cur_help, conds);
                current = try self.addItem(rest);
                cur_type = .unknown;
                cur_prompt = null;
                cur_depends = null;
                cur_env = null;
                help_indent = 0;
                continue;
            }

            if (std.mem.eql(u8, kw, "if")) {
                const expr = try self.parseExpr(rest);
                try conds.append(self.index.allocator, expr);
                continue;
            }
            if (std.mem.eql(u8, kw, "endif")) {
                if (conds.items.len > 0) _ = conds.pop();
                continue;
            }
            if (std.mem.eql(u8, kw, "menu") or std.mem.eql(u8, kw, "comment") or
                std.mem.eql(u8, kw, "mainmenu") or std.mem.eql(u8, kw, "endmenu") or
                std.mem.eql(u8, kw, "choice") or std.mem.eql(u8, kw, "endchoice") or
                std.mem.eql(u8, kw, "visible"))
            {
                continue;
            }
            if (std.mem.eql(u8, kw, "source") or std.mem.eql(u8, kw, "rsource")) {
                const quoted = stripQuotes(rest);
                if (io) |io_handle| {
                    try self.loadSource(io_handle, base_dir, quoted, conds, depth + 1);
                }
                continue;
            }
            if (std.mem.eql(u8, kw, "help") or std.mem.eql(u8, kw, "---help---")) {
                pending_help = true;
                help_indent = 0;
                continue;
            }

            // ---- 以下都是 config 属性 ----
            if (current == null) continue;

            if (std.mem.eql(u8, kw, "bool") or std.mem.eql(u8, kw, "boolean")) {
                cur_type = .bool_;
                try self.parsePromptAttr(rest, &cur_prompt);
            } else if (std.mem.eql(u8, kw, "tristate")) {
                cur_type = .tristate;
                try self.parsePromptAttr(rest, &cur_prompt);
            } else if (std.mem.eql(u8, kw, "string")) {
                cur_type = .string;
                try self.parsePromptAttr(rest, &cur_prompt);
            } else if (std.mem.eql(u8, kw, "int")) {
                cur_type = .int_;
                try self.parsePromptAttr(rest, &cur_prompt);
            } else if (std.mem.eql(u8, kw, "hex")) {
                cur_type = .hex;
                try self.parsePromptAttr(rest, &cur_prompt);
            } else if (std.mem.eql(u8, kw, "def_bool") or std.mem.eql(u8, kw, "def_tristate")) {
                cur_type = if (std.mem.eql(u8, kw, "def_bool")) .bool_ else .tristate;
                try self.appendDefault(&cur_defaults, rest);
            } else if (std.mem.eql(u8, kw, "prompt")) {
                try self.parsePromptAttr(rest, &cur_prompt);
            } else if (std.mem.eql(u8, kw, "default")) {
                try self.appendDefault(&cur_defaults, rest);
            } else if (std.mem.eql(u8, kw, "depends")) {
                const dep_expr = if (std.mem.startsWith(u8, rest, "on"))
                    std.mem.trim(u8, rest[2..], " \t")
                else
                    rest;
                const expr = try self.parseExpr(dep_expr);
                cur_depends = try andExpr(self, cur_depends, expr);
            } else if (std.mem.eql(u8, kw, "select")) {
                try self.appendSelect(&cur_selects, rest);
            } else if (std.mem.eql(u8, kw, "range")) {
                // 仅做语法兼容
            } else if (std.mem.eql(u8, kw, "option")) {
                if (std.mem.startsWith(u8, rest, "env")) {
                    if (std.mem.findScalar(u8, rest, '=')) |eq| {
                        const v = stripQuotes(std.mem.trim(u8, rest[eq + 1 ..], " \t"));
                        cur_env = try self.alloc().dupe(u8, v);
                    }
                }
            }
        }

        try self.finishItem(&current, cur_type, cur_prompt, cur_depends, &cur_defaults, &cur_selects, cur_env, &cur_help, conds);
    }

    fn finishItem(
        self: *Config,
        current: *?usize,
        typ: ItemType,
        prompt: ?[]const u8,
        depends: ?*const Expr,
        defaults: *std.ArrayList(Default),
        selects: *std.ArrayList(Select),
        env: ?[]const u8,
        help: *std.ArrayList(u8),
        conds: *std.ArrayList(*const Expr),
    ) !void {
        if (current.*) |idx| {
            const it = &self.items.items[idx];
            it.typ = if (typ == .unknown) .bool_ else typ;
            it.prompt = prompt;
            it.defaults = try defaults.toOwnedSlice(self.alloc());
            it.selects = try selects.toOwnedSlice(self.alloc());
            it.env_var = env;
            it.help = try self.alloc().dupe(u8, help.items);
            it.depends = depends;
            for (conds.items) |c| {
                it.depends = try andExpr(self, it.depends, c);
            }
            current.* = null;
        }
        help.clearRetainingCapacity();
    }

    fn parsePromptAttr(self: *Config, rest: []const u8, prompt: *?[]const u8) !void {
        _ = self;
        if (rest.len == 0) return;
        if (rest[0] == '"') {
            const end = std.mem.findScalarPos(u8, rest, 1, '"') orelse rest.len - 1;
            prompt.* = rest[1..@min(end, rest.len)];
        } else {
            prompt.* = null;
        }
    }

    fn appendDefault(self: *Config, defaults: *std.ArrayList(Default), rest: []const u8) !void {
        var value_text = rest;
        var cond: ?*const Expr = null;
        if (std.mem.find(u8, rest, " if ")) |idx| {
            value_text = std.mem.trim(u8, rest[0..idx], " \t");
            cond = try self.parseExpr(std.mem.trim(u8, rest[idx + 4 ..], " \t"));
        }
        const expr = try self.parseValueExpr(value_text);
        try defaults.append(self.alloc(), .{ .value = expr, .cond = cond });
    }

    fn appendSelect(self: *Config, selects: *std.ArrayList(Select), rest: []const u8) !void {
        var target = rest;
        var cond: ?*const Expr = null;
        if (std.mem.find(u8, rest, " if ")) |idx| {
            target = std.mem.trim(u8, rest[0..idx], " \t");
            cond = try self.parseExpr(std.mem.trim(u8, rest[idx + 4 ..], " \t"));
        }
        try selects.append(self.alloc(), .{
            .target = try self.alloc().dupe(u8, target),
            .cond = cond,
        });
    }

    // ------------------------------------------------------------------
    // 表达式
    // ------------------------------------------------------------------

    pub fn parseExpr(self: *Config, text: []const u8) std.mem.Allocator.Error!*const Expr {
        var p = ExprParser{ .text = text, .pos = 0, .arena = self.alloc() };
        return try p.parseOr();
    }

    fn parseValueExpr(self: *Config, text: []const u8) !*const Expr {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return error.EmptyExpression;
        if (trimmed[0] == '"') {
            const lit = stripQuotes(trimmed);
            const node = try self.alloc().create(Expr);
            node.* = .{ .literal = try self.alloc().dupe(u8, lit) };
            return node;
        }
        var is_literal = std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "n") or std.mem.eql(u8, trimmed, "m");
        if (!is_literal) {
            if (std.fmt.parseInt(u64, trimmed, 0)) |_| {
                is_literal = true;
            } else |_| {}
        }
        const node = try self.alloc().create(Expr);
        if (is_literal) {
            node.* = .{ .literal = try self.alloc().dupe(u8, trimmed) };
        } else {
            node.* = .{ .symbol = try self.alloc().dupe(u8, trimmed) };
        }
        return node;
    }

    // ------------------------------------------------------------------
    // defconfig 应用与求值
    // ------------------------------------------------------------------

    pub fn applyDefconfig(self: *Config, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "#")) continue;
            if (!std.mem.startsWith(u8, line, "CONFIG_")) continue;
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            const name = line["CONFIG_".len..eq];
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }
            if (self.find(name) == null) {
                const idx = try self.addItem(name);
                self.items.items[idx].typ = if (std.mem.eql(u8, value, "y") or std.mem.eql(u8, value, "m")) .bool_ else .string;
            }
            try self.set(name, value);
        }
    }

    fn valueOf(self: *Config, name: []const u8) []const u8 {
        const it = self.find(name) orelse return "n";
        return it.value orelse "n";
    }

    fn evalBool(self: *Config, e: *const Expr) bool {
        return switch (e.*) {
            .symbol => |s| blk: {
                const v = self.valueOf(s);
                break :blk std.mem.eql(u8, v, "y") or std.mem.eql(u8, v, "m");
            },
            .literal => |l| std.mem.eql(u8, l, "y") or std.mem.eql(u8, l, "m"),
            .not => |x| !self.evalBool(x),
            .and_ => |p| self.evalBool(p.lhs) and self.evalBool(p.rhs),
            .or_ => |p| self.evalBool(p.lhs) or self.evalBool(p.rhs),
            .eq => |p| blk: {
                const l = self.evalValue(p.lhs) orelse "n";
                const r = self.evalValue(p.rhs) orelse "n";
                const same = std.mem.eql(u8, l, r);
                break :blk if (p.negate) !same else same;
            },
        };
    }

    fn evalValue(self: *Config, e: *const Expr) ?[]const u8 {
        return switch (e.*) {
            .symbol => |s| blk: {
                const it = self.find(s) orelse break :blk null;
                break :blk it.value;
            },
            .literal => |l| l,
            else => if (self.evalBool(e)) "y" else "n",
        };
    }

    /// 迭代求值直到收敛（处理 default 引用、select 传播）。
    pub fn resolve(self: *Config) void {
        var pass: usize = 0;
        while (pass < 32) : (pass += 1) {
            var changed = false;

            for (self.items.items) |*it| {
                const dep_ok = if (it.depends) |d| self.evalBool(d) else true;
                var new_value: ?[]const u8 = null;
                if (!dep_ok) {
                    // 依赖不满足：布尔项按 n，其余项视为未设置
                    new_value = if (isBoolType(it.typ)) "n" else null;
                } else {
                    var picked: ?[]const u8 = null;
                    for (it.defaults) |d| {
                        if (d.cond) |c| {
                            if (!self.evalBool(c)) continue;
                        }
                        picked = self.evalValue(d.value);
                        break;
                    }
                    if (picked) |v| {
                        new_value = v;
                    } else if (isBoolType(it.typ)) {
                        new_value = "n";
                    } else if (it.prompt != null and it.typ == .string) {
                        new_value = "";
                    } else if (it.prompt != null) {
                        new_value = "0";
                    }
                }
                if (it.explicit) new_value = it.value;
                if (!optEql(it.value, new_value)) {
                    it.value = new_value;
                    changed = true;
                }
            }

            // select 传播
            for (self.items.items) |it| {
                if (!isBoolType(it.typ) or it.explicit) continue;
                const v = it.value orelse continue;
                if (!(std.mem.eql(u8, v, "y") or std.mem.eql(u8, v, "m"))) continue;
                for (it.selects) |sel| {
                    if (sel.cond) |c| {
                        if (!self.evalBool(c)) continue;
                    }
                    if (self.find(sel.target)) |t| {
                        if (t.explicit) continue;
                        if (!optEql(t.value, "y")) {
                            t.value = "y";
                            changed = true;
                        }
                    }
                }
            }

            if (!changed) break;
        }
    }

    // ------------------------------------------------------------------
    // 输出
    // ------------------------------------------------------------------

    pub fn writeDotConfig(self: *Config, writer: *std.Io.Writer) !void {
        try writer.writeAll("#\n# Automatically generated file; DO NOT EDIT.\n# WuKong-Lite configuration\n#\n");
        for (self.items.items) |it| {
            const val = it.value;
            if (isBoolType(it.typ)) {
                if (val) |v| {
                    if (std.mem.eql(u8, v, "y") or std.mem.eql(u8, v, "m")) {
                        try writer.print("CONFIG_{s}={s}\n", .{ it.name, v });
                    } else if (it.prompt != null or it.explicit) {
                        try writer.print("# CONFIG_{s} is not set\n", .{it.name});
                    }
                } else if (it.prompt != null) {
                    try writer.print("# CONFIG_{s} is not set\n", .{it.name});
                }
            } else if (val) |v| {
                if (it.typ == .string) {
                    try writer.print("CONFIG_{s}=\"{s}\"\n", .{ it.name, v });
                } else {
                    try writer.print("CONFIG_{s}={s}\n", .{ it.name, v });
                }
            }
        }
    }

    pub fn writeHeader(self: *Config, writer: *std.Io.Writer) !void {
        try writer.writeAll("/*\n * Automatically generated file; DO NOT EDIT.\n * WuKong-Lite configuration header\n */\n");
        try writer.writeAll("#ifndef _WUKONG_CCONFIG_H_\n#define _WUKONG_CCONFIG_H_\n\n");
        for (self.items.items) |it| {
            const val = it.value;
            if (isBoolType(it.typ)) {
                if (val) |v| {
                    if (std.mem.eql(u8, v, "y")) {
                        try writer.print("#define CONFIG_{s} 1\n", .{it.name});
                    } else if (std.mem.eql(u8, v, "m")) {
                        try writer.print("#define CONFIG_{s} 2\n", .{it.name});
                    } else {
                        try writer.print("/* #undef CONFIG_{s} */\n", .{it.name});
                    }
                } else {
                    try writer.print("/* #undef CONFIG_{s} */\n", .{it.name});
                }
            } else if (val) |v| {
                if (it.typ == .string) {
                    try writer.print("#define CONFIG_{s} \"{s}\"\n", .{ it.name, v });
                } else {
                    try writer.print("#define CONFIG_{s} {s}\n", .{ it.name, v });
                }
            } else {
                try writer.print("/* #undef CONFIG_{s} */\n", .{it.name});
            }
        }
        try writer.writeAll("\n#endif /* _WUKONG_CCONFIG_H_ */\n");
    }

    // ------------------------------------------------------------------
    // source 加载
    // ------------------------------------------------------------------

    fn loadSource(self: *Config, io: std.Io, base_dir: []const u8, rel: []const u8, conds: *std.ArrayList(*const Expr), depth: usize) anyerror!void {
        const a = self.arena.allocator();
        if (std.mem.findScalar(u8, rel, '*') != null) {
            const dir_rel = std.fs.path.dirname(rel) orelse ".";
            const pattern = std.fs.path.basename(rel);
            const dir_path = try std.fs.path.resolveAlloc(a, &.{ base_dir, dir_rel });
            var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (matchGlob(pattern, entry.name)) {
                    const path = try std.fs.path.resolveAlloc(a, &.{ dir_path, entry.name });
                    try self.loadFile(io, path, conds, depth);
                }
            }
            return;
        }
        const path = try std.fs.path.resolveAlloc(a, &.{ base_dir, rel });
        try self.loadFile(io, path, conds, depth);
    }

    fn loadFile(self: *Config, io: std.Io, path: []const u8, conds: *std.ArrayList(*const Expr), depth: usize) anyerror!void {
        const a = self.arena.allocator();
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const dir = std.fs.path.dirname(path) orelse ".";
        try self.parseText(text, conds, io, dir, depth);
    }
};

/// 加载 Kconfig 树（从文件入口，自动处理 source）。
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!Config {
    var cfg = Config.init(allocator);
    errdefer cfg.deinit();
    var conds: std.ArrayList(*const Expr) = .empty;
    defer conds.deinit(allocator);
    try cfg.loadFile(io, path, &conds, 0);
    return cfg;
}

fn matchGlob(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.startsWith(u8, pattern, "*")) {
        return std.mem.endsWith(u8, name, pattern[1..]);
    }
    if (std.mem.endsWith(u8, pattern, "*")) {
        return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, pattern, name);
}

fn stripQuotes(s_in: []const u8) []const u8 {
    const s = std.mem.trim(u8, s_in, " \t");
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn andExpr(self: *Config, a: ?*const Expr, b: *const Expr) !*const Expr {
    if (a) |lhs| {
        const node = try self.alloc().create(Expr);
        node.* = .{ .and_ = .{ .lhs = lhs, .rhs = b } };
        return node;
    }
    return b;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// ----------------------------------------------------------------------
// 表达式解析器
// ----------------------------------------------------------------------

const Tag = std.meta.Tag(Tok);

const Tok = union(enum) {
    sym: []const u8,
    str: []const u8,
    num: []const u8,
    and_tok,
    or_tok,
    not_tok,
    eq_tok,
    ne_tok,
    lparen,
    rparen,
    eof,
};

const ExprParser = struct {
    text: []const u8,
    pos: usize,
    arena: std.mem.Allocator,

    fn peek(self: *ExprParser) Tok {
        var i = self.pos;
        while (i < self.text.len and (self.text[i] == ' ' or self.text[i] == '\t')) i += 1;
        if (i >= self.text.len) return .eof;
        const c = self.text[i];
        if (c == '(') return .lparen;
        if (c == ')') return .rparen;
        if (c == '!') {
            if (i + 1 < self.text.len and self.text[i + 1] == '=') return .ne_tok;
            return .not_tok;
        }
        if (c == '=') return .eq_tok;
        if (c == '&' and i + 1 < self.text.len and self.text[i + 1] == '&') return .and_tok;
        if (c == '|' and i + 1 < self.text.len and self.text[i + 1] == '|') return .or_tok;
        if (c == '"') {
            const end = std.mem.findScalarPos(u8, self.text, i + 1, '"') orelse self.text.len;
            return .{ .str = self.text[i + 1 .. end] };
        }
        var j = i;
        while (j < self.text.len) : (j += 1) {
            const ch = self.text[j];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-' or ch == '/') continue;
            break;
        }
        if (j == i) return .eof;
        const tok = self.text[i..j];
        if (tok[0] >= '0' and tok[0] <= '9') return .{ .num = tok };
        return .{ .sym = tok };
    }

    fn advance(self: *ExprParser, tok: Tok) void {
        var i = self.pos;
        while (i < self.text.len and (self.text[i] == ' ' or self.text[i] == '\t')) i += 1;
        switch (tok) {
            .and_tok, .or_tok, .eq_tok, .ne_tok => self.pos = i + 2,
            .not_tok, .lparen, .rparen => self.pos = i + 1,
            .str => |s| self.pos = i + 2 + s.len,
            .sym, .num => |s| self.pos = i + s.len,
            .eof => self.pos = i,
        }
    }

    fn parseOr(self: *ExprParser) std.mem.Allocator.Error!*const Expr {
        var lhs = try self.parseAnd();
        while (true) {
            const tok = self.peek();
            switch (tok) {
                .or_tok => {
                    self.advance(tok);
                    const rhs = try self.parseAnd();
                    const node = try self.arena.create(Expr);
                    node.* = .{ .or_ = .{ .lhs = lhs, .rhs = rhs } };
                    lhs = node;
                },
                else => break,
            }
        }
        return lhs;
    }

    fn parseAnd(self: *ExprParser) std.mem.Allocator.Error!*const Expr {
        var lhs = try self.parseUnary();
        while (true) {
            const tok = self.peek();
            switch (tok) {
                .and_tok => {
                    self.advance(tok);
                    const rhs = try self.parseUnary();
                    const node = try self.arena.create(Expr);
                    node.* = .{ .and_ = .{ .lhs = lhs, .rhs = rhs } };
                    lhs = node;
                },
                else => break,
            }
        }
        return lhs;
    }

    fn parseUnary(self: *ExprParser) std.mem.Allocator.Error!*const Expr {
        const tok = self.peek();
        switch (tok) {
            .not_tok => {
                self.advance(tok);
                const inner = try self.parseUnary();
                const node = try self.arena.create(Expr);
                node.* = .{ .not = inner };
                return node;
            },
            else => return self.parsePrimary(),
        }
    }

    fn parsePrimary(self: *ExprParser) std.mem.Allocator.Error!*const Expr {
        const tok = self.peek();
        var lhs: *const Expr = undefined;
        switch (tok) {
            .lparen => {
                self.advance(tok);
                lhs = try self.parseOr();
                const closing = self.peek();
                if (@as(Tag, closing) == .rparen) self.advance(closing);
            },
            .sym => |s| {
                self.advance(tok);
                const node = try self.arena.create(Expr);
                node.* = .{ .symbol = try self.arena.dupe(u8, s) };
                lhs = node;
            },
            .num => |s| {
                self.advance(tok);
                const node = try self.arena.create(Expr);
                node.* = .{ .literal = try self.arena.dupe(u8, s) };
                lhs = node;
            },
            .str => |s| {
                self.advance(tok);
                const node = try self.arena.create(Expr);
                node.* = .{ .literal = try self.arena.dupe(u8, s) };
                lhs = node;
            },
            else => {
                const node = try self.arena.create(Expr);
                node.* = .{ .literal = "y" };
                lhs = node;
            },
        }

        const next_tok = self.peek();
        const tag = @as(Tag, next_tok);
        if (tag == .eq_tok or tag == .ne_tok) {
            const negate = tag == .ne_tok;
            self.advance(next_tok);
            const rhs = try self.parsePrimary();
            const node = try self.arena.create(Expr);
            node.* = .{ .eq = .{ .lhs = lhs, .rhs = rhs, .negate = negate } };
            return node;
        }
        return lhs;
    }
};

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

const sample_kconfig =
    \\mainmenu "WuKong-Lite test"
    \\
    \\config PRJ_CHIP
    \\    string "SoC"
    \\    default "d13x"
    \\
    \\config PRJ_BOARD
    \\    string "Board"
    \\    default "demo88-nor"
    \\
    \\config AIC_CHIP_D13X
    \\    bool
    \\    default y
    \\
    \\config AIC_USING_UART0
    \\    bool "UART0"
    \\    default y if AIC_CHIP_D13X
    \\
    \\config AIC_USING_I2C2
    \\    bool "I2C2"
    \\    depends on AIC_CHIP_D13X && !AIC_USING_UART0
    \\    default n
    \\
    \\config AIC_CONSOLE_NAME
    \\    string "Console device name"
    \\    default "uart0"
    \\
    \\config AIC_BAUD
    \\    int "Baud rate"
    \\    default 115200
    \\
    \\config AIC_USING_SEL
    \\    bool
    \\    default y
    \\    select AIC_SEL_TARGET
    \\
    \\config AIC_SEL_TARGET
    \\    bool
    \\
    \\if AIC_CHIP_D13X
    \\config AIC_IN_IF
    \\    bool "inside if"
    \\    default y
    \\endif
;

test "Kconfig 解析 + defconfig + 求值" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    var conds: std.ArrayList(*const Expr) = .empty;
    defer conds.deinit(allocator);
    try cfg.parseText(sample_kconfig, &conds, null, ".", 0);

    try cfg.applyDefconfig(
        \\CONFIG_PRJ_BOARD="myboard"
        \\CONFIG_AIC_USING_UART0=y
        \\
    );
    cfg.resolve();

    try std.testing.expectEqualStrings("d13x", cfg.get("PRJ_CHIP").?);
    try std.testing.expectEqualStrings("myboard", cfg.get("PRJ_BOARD").?);
    try std.testing.expectEqualStrings("y", cfg.get("AIC_CHIP_D13X").?);
    try std.testing.expectEqualStrings("y", cfg.get("AIC_USING_UART0").?);
    try std.testing.expectEqualStrings("uart0", cfg.get("AIC_CONSOLE_NAME").?);
    try std.testing.expectEqualStrings("115200", cfg.get("AIC_BAUD").?);
    try std.testing.expectEqualStrings("y", cfg.get("AIC_USING_SEL").?);
    // select 传播
    try std.testing.expectEqualStrings("y", cfg.get("AIC_SEL_TARGET").?);
    // depends on 条件为假（UART0 已开启）→ I2C2 保持 n
    try std.testing.expectEqualStrings("n", cfg.get("AIC_USING_I2C2").?);
    // if 块内的依赖成立
    try std.testing.expectEqualStrings("y", cfg.get("AIC_IN_IF").?);
}

test "Kconfig 输出 .config 与 cconfig.h" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();
    var conds: std.ArrayList(*const Expr) = .empty;
    defer conds.deinit(allocator);
    try cfg.parseText(sample_kconfig, &conds, null, ".", 0);
    cfg.resolve();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try cfg.writeDotConfig(&aw.writer);
    const dot = aw.written();
    try std.testing.expect(std.mem.find(u8, dot, "CONFIG_PRJ_CHIP=\"d13x\"") != null);
    try std.testing.expect(std.mem.find(u8, dot, "CONFIG_AIC_USING_UART0=y") != null);
    try std.testing.expect(std.mem.find(u8, dot, "# CONFIG_AIC_USING_I2C2 is not set") != null);

    var hw: std.Io.Writer.Allocating = .init(allocator);
    defer hw.deinit();
    try cfg.writeHeader(&hw.writer);
    const header = hw.written();
    try std.testing.expect(std.mem.find(u8, header, "#define CONFIG_AIC_CHIP_D13X 1") != null);
    try std.testing.expect(std.mem.find(u8, header, "#define CONFIG_PRJ_CHIP \"d13x\"") != null);
    try std.testing.expect(std.mem.find(u8, header, "/* #undef CONFIG_AIC_USING_I2C2 */") != null);
}
