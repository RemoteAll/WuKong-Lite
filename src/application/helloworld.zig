//! HelloWorld 示例应用 —— 对应 Luban-Lite `application/rt-thread/helloworld`：
//! 主线程 + 生产者线程通过邮箱通信、信号量同步，并打印启动横幅。
const std = @import("std");
const osal = @import("../kernel/common/osal.zig");

const Producer = struct {
    kernel: *osal.Kernel,
    mailbox: *osal.Mailbox,
    done: *osal.Semaphore,
    count: u32,

    fn entry(ctx: ?*anyopaque) void {
        const self: *Producer = @ptrCast(@alignCast(ctx.?));
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const msg = 1000 + i;
            while (!self.mailbox.tryPost(msg)) {
                self.kernel.sleepMs(2);
            }
            self.kernel.sleepMs(5);
        }
        self.done.post();
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    var kernel = osal.Kernel.init(allocator, io);
    defer kernel.deinit();

    const main_id = try kernel.registerThread("main");

    var mailbox = try osal.Mailbox.init(allocator, io, 8);
    defer mailbox.deinit(allocator);
    var done = osal.Semaphore.init(io);

    const count: u32 = 5;

    try out.writeAll("\n");
    try out.writeAll(" \\ | /\n");
    try out.writeAll("  WuKong-Lite  (Luban-Lite compatible SDK)\n");
    try out.writeAll("  Hello World!\n\n");

    var producer = Producer{
        .kernel = &kernel,
        .mailbox = &mailbox,
        .done = &done,
        .count = count,
    };

    const producer_id = try kernel.registerThread("producer");
    const thread = try std.Thread.spawn(.{}, Producer.entry, .{&producer});

    var received: u32 = 0;
    while (received < count) : (received += 1) {
        const msg = mailbox.pend();
        try out.print("[main] recv msg: {d} (remaining {d})\n", .{ msg, count - received - 1 });
        try out.flush();
    }
    done.wait();
    thread.join();
    kernel.finishThread(producer_id);
    kernel.finishThread(main_id);

    try out.print("[main] {d} messages received, exit\n", .{received});
    try out.flush();
}
