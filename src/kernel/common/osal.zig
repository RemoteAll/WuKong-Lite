//! OSAL 抽象 —— 对应 Luban-Lite `kernel/common`（aicos_* 系列）：
//! 线程、互斥量、信号量、邮箱（mailbox）、时钟节拍。
//!
//! 在 Zig 0.17 的新 I/O 模型上，阻塞操作需要 `std.Io`，因此 `Kernel` 持有它，
//! 各原语也通过 `Kernel` 创建。
const std = @import("std");

pub const Kernel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    start: std.Io.Timestamp,
    registry_mutex: std.Io.Mutex = .init,
    threads: std.ArrayList(ThreadEntry) = .empty,

    pub const ThreadEntry = struct {
        id: usize,
        name: []const u8,
        running: bool,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Kernel {
        return .{
            .allocator = allocator,
            .io = io,
            .start = std.Io.Timestamp.now(io, .awake),
        };
    }

    pub fn deinit(self: *Kernel) void {
        self.threads.deinit(self.allocator);
    }

    /// 系统节拍（毫秒）。
    pub fn ticks(self: *Kernel) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake);
        const dur = self.start.durationTo(now);
        if (dur.nanoseconds <= 0) return 0;
        return @intCast(@divTrunc(dur.nanoseconds, std.time.ns_per_ms));
    }

    pub fn sleepMs(self: *Kernel, ms: u64) void {
        self.io.sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
    }

    pub fn registerThread(self: *Kernel, name: []const u8) !usize {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        const id = self.threads.items.len;
        try self.threads.append(self.allocator, .{ .id = id, .name = name, .running = true });
        return id;
    }

    pub fn finishThread(self: *Kernel, id: usize) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        for (self.threads.items) |*t| {
            if (t.id == id) t.running = false;
        }
    }

    pub fn threadCount(self: *Kernel) usize {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        return self.threads.items.len;
    }

    /// 快照线程表（调用者负责 free）。
    pub fn threadSnapshot(self: *Kernel, allocator: std.mem.Allocator) ![]ThreadEntry {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        return allocator.dupe(ThreadEntry, self.threads.items);
    }

    /// 创建线程（C 风格入口：`fn (ctx: ?*anyopaque) void`）。
    pub fn spawn(
        self: *Kernel,
        name: []const u8,
        function: *const fn (?*anyopaque) void,
        ctx: ?*anyopaque,
    ) !std.Thread {
        _ = try self.registerThread(name);
        return std.Thread.spawn(.{}, function, .{ctx});
    }
};

pub const Mutex = struct {
    io: std.Io,
    inner: std.Io.Mutex = .init,

    pub fn init(io: std.Io) Mutex {
        return .{ .io = io };
    }

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(self.io);
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

pub const Semaphore = struct {
    io: std.Io,
    inner: std.Io.Semaphore = .{},

    pub fn init(io: std.Io) Semaphore {
        return .{ .io = io };
    }

    pub fn wait(self: *Semaphore) void {
        self.inner.waitUncancelable(self.io);
    }

    pub fn post(self: *Semaphore) void {
        self.inner.post(self.io);
    }
};

/// 邮箱：固定容量的 32 位消息队列（对应 RT-Thread `rt_mb_*`）。
pub const Mailbox = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    buf: []u32,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !Mailbox {
        if (capacity == 0) return error.InvalidCapacity;
        return .{ .io = io, .buf = try allocator.alloc(u32, capacity) };
    }

    pub fn deinit(self: *Mailbox, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.buf = &.{};
    }

    /// 非阻塞投递：队列满返回 false。
    pub fn tryPost(self: *Mailbox, value: u32) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == self.buf.len) return false;
        self.buf[self.tail] = value;
        self.tail = (self.tail + 1) % self.buf.len;
        self.count += 1;
        self.cond.signal(self.io);
        return true;
    }

    /// 阻塞投递。
    pub fn post(self: *Mailbox, value: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.count == self.buf.len) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.buf[self.tail] = value;
        self.tail = (self.tail + 1) % self.buf.len;
        self.count += 1;
        self.cond.signal(self.io);
    }

    /// 非阻塞接收。
    pub fn tryPend(self: *Mailbox) ?u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        const v = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.count -= 1;
        self.cond.signal(self.io);
        return v;
    }

    /// 阻塞接收。
    pub fn pend(self: *Mailbox) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.count == 0) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        const v = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.count -= 1;
        self.cond.signal(self.io);
        return v;
    }
};

test "邮箱 FIFO 与容量限制" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mb = try Mailbox.init(std.testing.allocator, io, 2);
    defer mb.deinit(std.testing.allocator);

    try std.testing.expect(mb.tryPend() == null);
    try std.testing.expect(mb.tryPost(1));
    try std.testing.expect(mb.tryPost(2));
    try std.testing.expect(!mb.tryPost(3));
    try std.testing.expectEqual(@as(u32, 1), mb.tryPend().?);
    try std.testing.expect(mb.tryPost(3));
    try std.testing.expectEqual(@as(u32, 2), mb.tryPend().?);
    try std.testing.expectEqual(@as(u32, 3), mb.tryPend().?);
    try std.testing.expect(mb.tryPend() == null);
}

test "信号量阻塞唤醒（生产者/消费者）" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sem = Semaphore.init(io);
    var kernel = Kernel.init(std.testing.allocator, io);
    defer kernel.deinit();

    const Ctx = struct {
        sem: *Semaphore,
        value: u32 = 0,
        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.sem.wait();
            self.value = 42;
        }
    };
    var ctx = Ctx{ .sem = &sem };
    const t = try kernel.spawn("worker", Ctx.run, &ctx);
    kernel.sleepMs(10);
    sem.post();
    t.join();
    try std.testing.expectEqual(@as(u32, 42), ctx.value);
}
