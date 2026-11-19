//! 外部厂商工具调用（与 SDK 的 C/Python 构建用法完全一致）。
//!
//! 背景：UFFS（`mkuffs`）与固件加密（`firmware_security_encrypt`）在 SDK 里**只有预编译二进制**，
//! SDK 自己的 `makeuffs.py` / `mk_image.py` 也是直接调用它们。因此我们同样调这些 exe，
//! 参数顺序与参考保持一致，产物逐字节可复现。
const std = @import("std");

pub const Error = error{
    ToolNotFound,
    ToolFailed,
};

/// 工具查找顺序（与参考 `mk_image.py` 的 `script_dir` 语义对齐）：
///   1. 显式 `--tooldir`（或 `WK_TOOLDIR` 环境变量）；
///   2. 裸名（交给系统 PATH）。
/// Windows 下优先试 `.exe` 后缀。返回的字符串由调用方释放。
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool_dir: ?[]const u8,
    name: []const u8,
) ![]u8 {
    const exe_suffix = if (@import("builtin").os.tag == .windows) ".exe" else "";

    if (tool_dir) |dir| {
        const trimmed = std.mem.trimEnd(u8, dir, "/\\");
        if (trimmed.len > 0) {
            if (exe_suffix.len > 0) {
                const p = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ trimmed, name, exe_suffix });
                if (std.Io.Dir.cwd().statFile(io, p, .{})) |_| return p else |_| allocator.free(p);
            }
            const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, name });
            if (std.Io.Dir.cwd().statFile(io, p, .{})) |_| return p else |_| allocator.free(p);
        }
    }

    // 兜底：裸名（PATH 解析由 spawn 完成）
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ name, exe_suffix });
}

pub const RunOutcome = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// 运行外部工具，收集 stdout/stderr（调用方负责 `deinit`）。
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !RunOutcome {
    const res = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 0xFF,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

test "ext_tool.resolve：显式目录不存在时退回裸名" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const p = try resolve(allocator, io, "/nonexistent-dir-xyz", "mkuffs");
    defer allocator.free(p);
    try std.testing.expect(std.mem.startsWith(u8, p, "mkuffs"));
}
