//! upgcmd 请求载荷构造 —— 与参考客户端 `aicupg_client.py` 的各方法**逐字节一致**。
//!
//! 参考客户端用 `json.dumps(...)`（默认 `separators=(', ', ': ')`、`ensure_ascii=True`、
//! 保持插入顺序）生成载荷，所以这里不做"标准 JSON 编码"，而是按相同规则拼字符串：
//!   * 键顺序与参考一致；
//!   * 冒号后一个空格、逗号后一个空格；
//!   * `true` / `false` 小写；
//!   * 非 ASCII 一律 `\uXXXX`（含代理对），`"` `\` 与控制字符按 JSON 规则转义。
const std = @import("std");

/// Python `json.dumps` 默认的字符串转义规则（`ensure_ascii=True`）。
fn appendJsonString(list: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try list.append(a, '"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try list.appendSlice(a, "\\\""),
            '\\' => try list.appendSlice(a, "\\\\"),
            '\n' => try list.appendSlice(a, "\\n"),
            '\r' => try list.appendSlice(a, "\\r"),
            '\t' => try list.appendSlice(a, "\\t"),
            0x08 => try list.appendSlice(a, "\\b"),
            0x0c => try list.appendSlice(a, "\\f"),
            else => {
                if (c < 0x20) {
                    try list.print(a, "\\u{x:0>4}", .{c});
                } else if (c < 0x80) {
                    try list.append(a, c);
                } else {
                    // 非 ASCII：按 UTF-8 解码成码点，再写成 \uXXXX（BMP 之外用代理对）
                    const len = std.unicode.utf8ByteSequenceLength(c) catch {
                        try list.print(a, "\\u{x:0>4}", .{c});
                        continue;
                    };
                    if (i + len > s.len) {
                        try list.print(a, "\\u{x:0>4}", .{c});
                        continue;
                    }
                    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
                        try list.print(a, "\\u{x:0>4}", .{c});
                        continue;
                    };
                    i += len - 1;
                    if (cp <= 0xFFFF) {
                        try list.print(a, "\\u{x:0>4}", .{cp});
                    } else {
                        const v = cp - 0x10000;
                        const hi: u16 = @intCast(0xD800 + (v >> 10));
                        const lo: u16 = @intCast(0xDC00 + (v & 0x3FF));
                        try list.print(a, "\\u{x:0>4}\\u{x:0>4}", .{ hi, lo });
                    }
                }
            },
        }
    }
    try list.append(a, '"');
}

fn finish(list: *std.ArrayList(u8), a: std.mem.Allocator) ![]u8 {
    return list.toOwnedSlice(a);
}

/// `{"task_id": N}`
pub fn taskOnly(a: std.mem.Allocator, task_id: u64) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"task_id\": {d}}}", .{task_id});
}

/// `{"task_id": N, "params": {"port": "...", "baudrate": N}}`
pub fn configDevice(a: std.mem.Allocator, task_id: u64, port: []const u8, baudrate: u32) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    try list.print(a, "{{\"task_id\": {d}, \"params\": {{\"port\": ", .{task_id});
    try appendJsonString(&list, a, port);
    try list.print(a, ", \"baudrate\": {d}}}}}", .{baudrate});
    return finish(&list, a);
}

/// `{"task_id": N, "params": {"image_path": "...", "auto_reboot": true, "partition_mode": "all"}}`
/// 参考客户端会把路径里的 `\` 统一成 `/`，这里由调用方先行归一。
pub fn burnImage(
    a: std.mem.Allocator,
    task_id: u64,
    image_path: []const u8,
    auto_reboot: bool,
    partition_mode: []const u8,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    try list.print(a, "{{\"task_id\": {d}, \"params\": {{\"image_path\": ", .{task_id});
    try appendJsonString(&list, a, image_path);
    try list.print(a, ", \"auto_reboot\": {s}, \"partition_mode\": ", .{if (auto_reboot) "true" else "false"});
    try appendJsonString(&list, a, partition_mode);
    try list.appendSlice(a, "}}");
    return finish(&list, a);
}

/// `{"task_id": N, "params": {"command": "..."}}`
pub fn sendCmd(a: std.mem.Allocator, task_id: u64, command: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    try list.print(a, "{{\"task_id\": {d}, \"params\": {{\"command\": ", .{task_id});
    try appendJsonString(&list, a, command);
    try list.appendSlice(a, "}}");
    return finish(&list, a);
}

/// `{"task_id": N, "params": {"timeout_sec": N}}`
pub fn getLog(a: std.mem.Allocator, task_id: u64, timeout_sec: u32) ![]u8 {
    return std.fmt.allocPrint(
        a,
        "{{\"task_id\": {d}, \"params\": {{\"timeout_sec\": {d}}}}}",
        .{ task_id, timeout_sec },
    );
}

/// `{"filename": "...", "file_size": N, "remote_dir": "..."}`（注意：参考客户端此命令**不带 task_id**）
pub fn uploadFirmware(
    a: std.mem.Allocator,
    filename: []const u8,
    file_size: u64,
    remote_dir: []const u8,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, "{\"filename\": ");
    try appendJsonString(&list, a, filename);
    try list.print(a, ", \"file_size\": {d}, \"remote_dir\": ", .{file_size});
    try appendJsonString(&list, a, remote_dir);
    try list.append(a, '}');
    return finish(&list, a);
}

/// 参考客户端的路径归一：`\` → `/`（burn_image 用）。
pub fn normalizePath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try a.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

// ---------------------------------------------------------------------------
// 单测（期望值来自 Python json.dumps 的实际输出）
// ---------------------------------------------------------------------------
test "upg_payload：task_id 载荷与 json.dumps 一致" {
    const a = std.testing.allocator;
    const p = try taskOnly(a, 1);
    defer a.free(p);
    try std.testing.expectEqualStrings("{\"task_id\": 1}", p);
}

test "upg_payload：configDevice 含空格与整数" {
    const a = std.testing.allocator;
    const p = try configDevice(a, 1, "COM4", 115200);
    defer a.free(p);
    try std.testing.expectEqualStrings("{\"task_id\": 1, \"params\": {\"port\": \"COM4\", \"baudrate\": 115200}}", p);
}

test "upg_payload：burnImage 路径与布尔" {
    const a = std.testing.allocator;
    const p = try burnImage(a, 2, "C:/temp/x.img", true, "all");
    defer a.free(p);
    try std.testing.expectEqualStrings(
        "{\"task_id\": 2, \"params\": {\"image_path\": \"C:/temp/x.img\", \"auto_reboot\": true, \"partition_mode\": \"all\"}}",
        p,
    );
}

test "upg_payload：反斜杠与中文按 json.dumps 规则转义" {
    const a = std.testing.allocator;
    const p = try uploadFirmware(a, "固件.img", 1024, "C:\\temp\\aicupg_firmware\\");
    defer a.free(p);
    // Python: json.dumps({"filename": "固件.img", "file_size": 1024,
    //                     "remote_dir": "C:\\temp\\aicupg_firmware\\"})
    try std.testing.expectEqualStrings(
        "{\"filename\": \"\\u56fa\\u4ef6.img\", \"file_size\": 1024, \"remote_dir\": \"C:\\\\temp\\\\aicupg_firmware\\\\\"}",
        p,
    );
}

test "upg_payload：sendCmd / getLog 形状" {
    const a = std.testing.allocator;
    const c = try sendCmd(a, 3, "reset");
    defer a.free(c);
    try std.testing.expectEqualStrings("{\"task_id\": 3, \"params\": {\"command\": \"reset\"}}", c);

    const l = try getLog(a, 4, 5);
    defer a.free(l);
    try std.testing.expectEqualStrings("{\"task_id\": 4, \"params\": {\"timeout_sec\": 5}}", l);
}

test "upg_payload：路径归一" {
    const a = std.testing.allocator;
    const p = try normalizePath(a, "C:\\temp\\a.img");
    defer a.free(p);
    try std.testing.expectEqualStrings("C:/temp/a.img", p);
}
