//! upgcmd 服务端 TCP 客户端（P0-3 传输层）—— 与 `upgcmd server` 的 9100 端口会话。
//!
//! 只做「连接 + 发一帧 + 收一帧」的最小会话；连续多帧（上传分块）由上层按需调用。
//! 协议细节见 `upg_frame.zig`（帧/CRC）与 `upg_payload.zig`（载荷形状）。
//!
//! 说明：传输层用 `tcp.zig`（Windows 走 ws2_32 + SO_RCVTIMEO，POSIX 走 std.posix），
//! 因为 Zig 0.17.1 的 `std.Io` 在 Windows 上不支持带期限的网络读（详见 tcp.zig 顶部说明）。
//! 主机名必须先解成 IP 字面量（不做 DNS）。
const std = @import("std");
const upg_frame = @import("upg_frame.zig");
const tcp = @import("tcp.zig");

pub const Error = error{
    BadHost,
    NotConnected,
    UnexpectedResponse,
    ConnectionClosed,
    Timeout,
    ConnectionRefused,
};

pub const NetOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9100,
    /// 单次收发的期限（毫秒，0=不限）。
    timeout_ms: u32 = 5000,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    conn: tcp.Conn,
    buf: std.ArrayList(u8) = .empty,

    pub fn connect(allocator: std.mem.Allocator, opt: NetOptions) !Session {
        const conn = tcp.Conn.connect(opt.host, opt.port, opt.timeout_ms) catch |err| switch (err) {
            error.BadHost => return Error.BadHost,
            error.Timeout => return Error.Timeout,
            error.ConnectionRefused => return Error.ConnectionRefused,
            error.ConnectionClosed => return Error.ConnectionClosed,
            error.Unexpected => return Error.NotConnected,
            else => return err,
        };
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn deinit(self: *Session) void {
        self.conn.close();
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// 发送一帧。
    pub fn send(self: *Session, cmd: u8, payload: []const u8) !void {
        const frame = try upg_frame.encode(self.allocator, cmd, payload);
        defer self.allocator.free(frame);
        try self.conn.sendAll(frame);
    }

    /// 读一帧（每读带 OS 层超时）；返回的 payload 由调用者释放。
    pub fn recv(self: *Session) !upg_frame.Decoded {
        var chunk: [4096]u8 = undefined;
        while (true) {
            if (self.buf.items.len >= upg_frame.MIN_SIZE) {
                if (upg_frame.decode(self.buf.items)) |d| {
                    const owned = try self.buf.toOwnedSlice(self.allocator);
                    defer self.allocator.free(owned);
                    // 只保留这一帧，剩余字节回填（正常一问一答场景剩余为空）
                    const rest = owned[d.frame_len..];
                    const payload = try self.allocator.dupe(u8, owned[upg_frame.HEADER_SIZE..][0..d.payload.len]);
                    self.buf.clearRetainingCapacity();
                    try self.buf.appendSlice(self.allocator, rest);
                    return .{ .cmd = d.cmd, .payload = payload, .frame_len = d.frame_len };
                } else |err| switch (err) {
                    error.TooShort, error.LengthMismatch => {}, // 继续读
                    else => return err,
                }
            }
            const n = self.conn.recv(&chunk) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                error.ConnectionClosed => return Error.ConnectionClosed,
                else => return err,
            };
            if (n == 0) return Error.ConnectionClosed;
            try self.buf.appendSlice(self.allocator, chunk[0..n]);
        }
    }

    /// 一问一答：发请求帧，读一帧并校验响应 cmd = req | 0x80。
    /// 返回的 payload 由调用者释放（`allocator` 用于返回副本，可与 Session 的不同）。
    pub fn request(
        self: *Session,
        allocator: std.mem.Allocator,
        cmd: u8,
        payload: []const u8,
    ) ![]u8 {
        try self.send(cmd, payload);
        const resp = try self.recv();
        defer allocator.free(resp.payload);
        if (resp.cmd != (cmd | upg_frame.Cmd.rsp_mask)) return Error.UnexpectedResponse;
        return allocator.dupe(u8, resp.payload);
    }
};

// ---------------------------------------------------------------------------
// 单测（不联网部分）
// ---------------------------------------------------------------------------
test "upg_client：BadHost 明确报错" {
    // 用不可解析的主机名触发 BadHost（不发包、不联网）
    try std.testing.expectError(Error.BadHost, Session.connect(std.testing.allocator, .{ .host = "localhost", .port = 1 }));
}
