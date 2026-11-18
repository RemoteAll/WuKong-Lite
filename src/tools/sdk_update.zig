//! `sdk_update.py` 等价实现：批量修复 `target/**/*pinmux.c` 里的旧格式代码。
//!
//! 参考脚本做的事（逐条对齐）：
//!   1. 若缺少 `#include <aic_utils.h>`，则在**最后一条 `#include` 之后**补一行；
//!   2. 若缺少 `uint32_t aic_pinmux_config_size = ARRAY_SIZE(aic_pinmux_config);`，在文件末尾补一行；
//!   3. 删除 `extern size_t __dtb_pos_f;` 这一行；
//!   4. 删除 `struct aic_pinmux` 定义块与 `void aic_board_pinmux_init(void)` 函数块
//!      （按花括号计数跳过整块）。
//!
//! 差异：参考脚本必须在 SDK 根目录跑（靠 `./tools/scripts/sdk_update.py` 是否存在做校验），
//! 这里用 `--root` 显式指定，且默认只打印将要修改的文件，加 `--write` 才落盘。
//! 另外参考脚本在 Windows 下以 text 模式写回，会把**整个文件**的行尾改成 CRLF；
//! 我们保留原有行尾（LF），内容逐行等价（对拍时忽略 `\r`）。
const std = @import("std");

pub const Error = error{ NotAnSdkRoot, WriteFailed };

const INCLUDE_LINE = "#include <aic_utils.h>";
const SIZE_LINE = "uint32_t aic_pinmux_config_size = ARRAY_SIZE(aic_pinmux_config);";

/// 判断一行是否包含 `#include`（参考脚本用 `line.find('#include') != -1`）。
fn isIncludeLine(line: []const u8) bool {
    return std.mem.find(u8, line, "#include") != null;
}

fn countByte(s: []const u8, needle: u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == needle) n += 1;
    }
    return n;
}

/// 对单个文件内容做变换（纯函数，便于单测）。
pub fn rewrite(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw| {
            try lines.append(allocator, raw);
        }
        // `splitScalar` 末尾会多出一个空串（源文件以 \n 结尾时），去掉它。
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
            _ = lines.pop();
        }
    }

    var has_header = false;
    var has_size = false;
    for (lines.items) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), INCLUDE_LINE)) has_header = true;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), SIZE_LINE)) has_size = true;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var header_started = false;
    var header_done = false;
    var in_struct = false;
    var in_function = false;
    var brace_count: isize = 0;

    for (lines.items) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");

        if (!has_header and !header_done) {
            if (!header_started and isIncludeLine(line)) header_started = true;
            if (header_started and !isIncludeLine(line)) {
                header_done = true;
                try out.appendSlice(allocator, INCLUDE_LINE);
                try out.append(allocator, '\n');
                // 参考脚本 `continue`：本行不再输出（该行是第一条非 include 行，
                // 由于前面刚插入了 include，Python 直接跳过它——这里保持同样行为）。
                continue;
            }
        }

        if (std.mem.eql(u8, line, "extern size_t __dtb_pos_f;")) continue;
        if (std.mem.eql(u8, line, "struct aic_pinmux")) {
            in_struct = true;
            brace_count = 0;
            continue;
        }
        if (std.mem.eql(u8, line, "void aic_board_pinmux_init(void)")) {
            in_function = true;
            brace_count = 0;
            continue;
        }
        if (in_struct) {
            brace_count += @as(isize, @intCast(countByte(line, '{'))) - @as(isize, @intCast(countByte(line, '}')));
            if (brace_count <= 0) in_struct = false;
            continue;
        }
        if (in_function) {
            brace_count += @as(isize, @intCast(countByte(line, '{'))) - @as(isize, @intCast(countByte(line, '}')));
            if (brace_count <= 0) in_function = false;
            continue;
        }

        _ = &line;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    if (!has_size) {
        try out.appendSlice(allocator, SIZE_LINE);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

pub const Result = struct {
    scanned: usize = 0,
    changed: usize = 0,
};

/// 递归处理 `<root>/target/**/*pinmux.c`。
pub fn updateRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    write: bool,
    out: *std.Io.Writer,
) !Result {
    // 与参考脚本一致：必须在 SDK 根（这里用 tools/scripts 目录做校验）。
    const probe = try std.fs.path.join(allocator, &.{ root, "tools", "scripts" });
    defer allocator.free(probe);
    var probe_dir = std.Io.Dir.cwd().openDir(io, probe, .{}) catch return Error.NotAnSdkRoot;
    probe_dir.close(io);

    const target = try std.fs.path.join(allocator, &.{ root, "target" });
    defer allocator.free(target);

    var dir = std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true }) catch |err| {
        try out.print("sdk-update: 无法打开 {s}（{s}）\n", .{ target, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    var result = Result{};
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, "pinmux.c")) continue;
        result.scanned += 1;

        const full = try std.fs.path.join(allocator, &.{ target, entry.path });
        defer allocator.free(full);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, full, allocator, .unlimited);
        defer allocator.free(text);
        const updated = try rewrite(allocator, text);
        defer allocator.free(updated);
        if (std.mem.eql(u8, updated, text)) continue;

        result.changed += 1;
        if (write) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = updated });
            try out.print("sdk-update: 已修复 {s}\n", .{entry.path});
        } else {
            try out.print("sdk-update: 待修复 {s}\n", .{entry.path});
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------
const sample_old =
    \\#include <stdio.h>
    \\#include <aic_core.h>
    \\extern size_t __dtb_pos_f;
    \\
    \\struct aic_pinmux
    \\{
    \\    unsigned int func;
    \\    unsigned int pin;
    \\};
    \\
    \\static const struct aic_pinmux aic_pinmux_config[] = {
    \\    {2, 0},
    \\};
    \\
    \\void aic_board_pinmux_init(void)
    \\{
    \\    unsigned int i = 0;
    \\    for (i = 0; i < ARRAY_SIZE(aic_pinmux_config); i++) {
    \\        hal_pinmux_config(aic_pinmux_config[i].pin, aic_pinmux_config[i].func);
    \\    }
    \\}
    \\
;

test "sdk_update：补 include、删旧结构体与函数、末尾补 size" {
    const a = std.testing.allocator;
    const updated = try rewrite(a, sample_old);
    defer a.free(updated);

    // include 插在最后一条 #include 之后
    try std.testing.expect(std.mem.find(u8, updated, "#include <aic_core.h>\n#include <aic_utils.h>\n") != null);
    // 旧结构体与旧函数块被整块删除
    try std.testing.expect(std.mem.find(u8, updated, "struct aic_pinmux\n") == null);
    try std.testing.expect(std.mem.find(u8, updated, "aic_board_pinmux_init") == null);
    try std.testing.expect(std.mem.find(u8, updated, "__dtb_pos_f") == null);
    // 数据表保留
    try std.testing.expect(std.mem.find(u8, updated, "static const struct aic_pinmux aic_pinmux_config[]") != null);
    // 末尾补 aic_pinmux_config_size
    try std.testing.expect(std.mem.endsWith(u8, updated, SIZE_LINE ++ "\n"));
}

test "sdk_update：已修复过的文件保持幂等" {
    const a = std.testing.allocator;
    const once = try rewrite(a, sample_old);
    defer a.free(once);
    const twice = try rewrite(a, once);
    defer a.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "sdk_update：无需修复的文件原样返回" {
    const a = std.testing.allocator;
    const clean =
        \\#include <aic_utils.h>
        \\int x;
        \\uint32_t aic_pinmux_config_size = ARRAY_SIZE(aic_pinmux_config);
        \\
    ;
    const out = try rewrite(a, clean);
    defer a.free(out);
    try std.testing.expectEqualStrings(clean, out);
}

