//! 带超时的 TCP 客户端（`wk upg --send` 用）。
//!
//! 为什么不用 `std.Io.net`：
//! Zig 0.17.1 的 Threaded 后端在 Windows 上**只支持阻塞式网络读**——
//! `std/Io/Threaded.zig` 的 `batchDrainSubmittedWindows` 里写得很直白：
//! ```zig
//! .net_read => |*o| {
//!     // TODO integrate with overlapped I/O or equivalent to avoid this error
//!     if (concurrency) return error.ConcurrencyUnavailable;
//! ```
//! 也就是说 `Batch.awaitConcurrent`（唯一的 std 定时等待手段）对 `net_read` 直接失败；
//! 而 `stream.shutdown(.both)` 实测**不会**让已挂起的 AFD RECEIVE 立即完成
//! （300 ms 期限实测要等对端关闭、3 s 才返回）。所以超时只能靠 OS 层的
//! `SO_RCVTIMEO` / `SO_SNDTIMEO`：Windows 用 `ws2_32`，POSIX 用 `std.posix`。
//!
//! 边界：只支持 IP 字面量（不做 DNS），与 `IpAddress.parse` 的既有约束一致。
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

pub const Error = error{
    BadHost,
    Timeout,
    ConnectionClosed,
    ConnectionRefused,
    Unexpected,
};

const W = std.os.windows;

const ws2 = if (is_windows) struct {
    const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?*anyopaque,
    };
    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.winapi) c_int;
    extern "ws2_32" fn socket(af: c_int, socket_type: c_int, protocol: c_int) callconv(.winapi) usize;
    extern "ws2_32" fn connect(s: usize, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(s: usize, level: c_int, name: c_int, val: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn WSAStringToAddressW(
        address_string: [*:0]const u16,
        address_family: c_int,
        lp_protocol_info: ?*anyopaque,
        lp_address: *anyopaque,
        lp_address_length: *c_int,
    ) callconv(.winapi) c_int;

    const WSAETIMEDOUT: c_int = 10060;
    const WSAECONNREFUSED: c_int = 10061;
    const WSAENETUNREACH: c_int = 10051;
    const WSAEHOSTUNREACH: c_int = 10065;
    const INVALID_SOCKET: usize = ~@as(usize, 0);
    const SOCKET_ERROR: c_int = -1;

    var started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    fn ensureStartup() !void {
        if (started.load(.acquire)) return;
        var data: WSADATA = undefined;
        if (WSAStartup(0x0202, &data) != 0) return Error.Unexpected;
        started.store(true, .release);
    }
} else struct {};

/// 连接句柄：Windows 是 WinSock `SOCKET`，POSIX 是 fd。
const Handle = if (is_windows) usize else std.posix.socket_t;

pub const Conn = struct {
    handle: Handle,
    /// 单次 `recv` 的期限（毫秒），0 = 不限。
    read_timeout_ms: u32,

    /// 连接；`timeout_ms` 同时作用于后续收发（`SO_RCVTIMEO` / `SO_SNDTIMEO`）。
    pub fn connect(host: []const u8, port: u16, timeout_ms: u32) !Conn {
        return if (is_windows) connectWindows(host, port, timeout_ms) else connectPosix(host, port, timeout_ms);
    }

    pub fn close(self: *Conn) void {
        if (is_windows) {
            _ = ws2.closesocket(self.handle);
        } else {
            std.posix.close(self.handle);
        }
        self.* = undefined;
    }

    /// 发完整个缓冲区（部分发送会继续；超时返回 `Error.Timeout`）。
    pub fn sendAll(self: *Conn, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const chunk = bytes[off..];
            const len: c_int = @intCast(@min(chunk.len, 1 << 20));
            const n = if (is_windows)
                ws2.send(self.handle, chunk.ptr, len, 0)
            else
                std.posix.send(self.handle, chunk[0..@intCast(len)], 0) catch |err| return mapPosix(err);
            if (is_windows and n == ws2.SOCKET_ERROR) return mapWsa(ws2.WSAGetLastError());
            const sent: usize = @intCast(n);
            if (sent == 0) return Error.ConnectionClosed;
            off += sent;
        }
    }

    /// 读一段；返回 0 表示对端关闭；`Error.Timeout` 表示超过 `read_timeout_ms`。
    pub fn recv(self: *Conn, buf: []u8) !usize {
        const len: c_int = @intCast(@min(buf.len, 1 << 20));
        const n = if (is_windows)
            ws2.recv(self.handle, buf.ptr, len, 0)
        else
            std.posix.recv(self.handle, buf[0..@intCast(len)], 0) catch |err| return mapPosix(err);
        if (is_windows and n == ws2.SOCKET_ERROR) return mapWsa(ws2.WSAGetLastError());
        return @intCast(n);
    }

    fn mapWsa(code: c_int) Error {
        return switch (code) {
            ws2.WSAETIMEDOUT => Error.Timeout,
            ws2.WSAECONNREFUSED => Error.ConnectionRefused,
            ws2.WSAENETUNREACH, ws2.WSAEHOSTUNREACH => Error.Unexpected,
            else => Error.Unexpected,
        };
    }

    fn mapPosix(err: anyerror) Error {
        return switch (err) {
            error.WouldBlock => Error.Timeout,
            error.ConnectionRefused => Error.ConnectionRefused,
            error.ConnectionResetByPeer => Error.ConnectionClosed,
            else => Error.Unexpected,
        };
    }

    // -----------------------------------------------------------------------
    // Windows：ws2_32 + SO_RCVTIMEO / SO_SNDTIMEO（DWORD 毫秒）
    // -----------------------------------------------------------------------
    fn connectWindows(host: []const u8, port: u16, timeout_ms: u32) !Conn {
        try ws2.ensureStartup();
        const sock = ws2.socket(W.ws2_32.AF.INET, W.ws2_32.SOCK.STREAM, W.ws2_32.IPPROTO.TCP);
        if (sock == ws2.INVALID_SOCKET) return Error.Unexpected;
        errdefer _ = ws2.closesocket(sock);

        setWindowsTimeout(sock, W.ws2_32.SO.RCVTIMEO, timeout_ms) catch return Error.Unexpected;
        setWindowsTimeout(sock, W.ws2_32.SO.SNDTIMEO, timeout_ms) catch return Error.Unexpected;

        const addr = try makeWindowsAddr(host, port);
        if (ws2.connect(sock, @ptrCast(&addr.storage), addr.len) == ws2.SOCKET_ERROR) {
            return mapWsa(ws2.WSAGetLastError());
        }
        return .{ .handle = sock, .read_timeout_ms = timeout_ms };
    }

    fn setWindowsTimeout(sock: usize, opt: c_int, timeout_ms: u32) !void {
        var ms: u32 = timeout_ms;
        if (ws2.setsockopt(sock, W.ws2_32.SOL.SOCKET, opt, @ptrCast(&ms), @sizeOf(u32)) == ws2.SOCKET_ERROR) {
            return Error.Unexpected;
        }
    }

    const WinAddr = struct { storage: W.ws2_32.sockaddr.storage, len: c_int };

    fn makeWindowsAddr(host: []const u8, port: u16) !WinAddr {
        var storage: W.ws2_32.sockaddr.storage = undefined;
        // 先按 "host:port" 让系统解析；WSAStringToAddressW 不接受 AF_UNSPEC，
        // 必须逐个地址族试（v4 优先，v6 兜底）。
        const endpoint = try std.fmt.allocPrint(std.heap.page_allocator, "{s}:{d}", .{ host, port });
        defer std.heap.page_allocator.free(endpoint);
        const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, endpoint) catch return Error.BadHost;
        defer std.heap.page_allocator.free(wide);
        for ([_]c_int{ W.ws2_32.AF.INET, W.ws2_32.AF.INET6 }) |family| {
            var len: c_int = @sizeOf(W.ws2_32.sockaddr.storage);
            if (ws2.WSAStringToAddressW(wide.ptr, family, null, @ptrCast(&storage), &len) == 0) {
                return .{ .storage = storage, .len = len };
            }
        }
        return Error.BadHost;
    }
};

// ---------------------------------------------------------------------------
// POSIX：std.posix + SO_RCVTIMEO / SO_SNDTIMEO（timeval）
// ---------------------------------------------------------------------------
fn connectPosix(host: []const u8, port: u16, timeout_ms: u32) !Conn {
    const ip = std.Io.net.IpAddress.parse(host, port) catch return Error.BadHost;
    var addr: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = undefined;
    switch (ip) {
        .ip4 => |v4| {
            var in: std.posix.sockaddr.in = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = @bitCast(v4.bytes),
                .zero = @splat(0),
            };
            @memcpy(std.mem.asBytes(&addr)[0..@sizeOf(std.posix.sockaddr.in)], std.mem.asBytes(&in));
            addr_len = @sizeOf(std.posix.sockaddr.in);
        },
        .ip6 => |v6| {
            var in6: std.posix.sockaddr.in6 = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, port),
                .flowinfo = 0,
                .addr = v6.bytes,
                .scope_id = 0,
            };
            @memcpy(std.mem.asBytes(&addr)[0..@sizeOf(std.posix.sockaddr.in6)], std.mem.asBytes(&in6));
            addr_len = @sizeOf(std.posix.sockaddr.in6);
        },
    }

    const fd = try std.posix.socket(
        if (ip == .ip4) std.posix.AF.INET else std.posix.AF.INET6,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(fd);

    if (timeout_ms > 0) {
        const tv: std.posix.timeval = .{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
    }

    std.posix.connect(fd, @ptrCast(&addr), addr_len) catch |err| return Conn.mapPosix(err);
    return .{ .handle = fd, .read_timeout_ms = timeout_ms };
}

// ---------------------------------------------------------------------------
// 单测（不联网）
// ---------------------------------------------------------------------------
test "tcp：非法主机返回 BadHost" {
    try std.testing.expectError(Error.BadHost, Conn.connect("not-an-ip", 9100, 100));
}

test "tcp：端口 1 连接被拒（本机）" {
    const r = Conn.connect("127.0.0.1", 1, 300);
    if (r) |conn| {
        var c = conn;
        c.close();
        return error.SkipZigTest;
    } else |err| {
        try std.testing.expect(err == Error.ConnectionRefused or err == Error.Timeout);
    }
}
