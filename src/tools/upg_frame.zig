//! `upgcmd server` 帧协议（P0-3 的主机侧底座）—— 依据 open-source 主机客户端
//! `docs/official/skills/aiburn/scripts/aiburn/aicupg_client.py` 实现并对拍。
//!
//! 帧格式（小端）：
//!   `AA 55 | version(1) | cmdtype(1) | length(4, LE) | payload | crc16(2, LE) | 55 AA`
//! 其中 `crc16` = CRC16-CCITT（poly 0x1021，初值 0xFFFF，覆盖 头部 8 字节 + payload）。
//!
//! 本模块只负责**编解码与校验**（不碰串口/TCP）；烧写流程（burn/upload）后续在
//! 这一层之上实现。校验语义与参考客户端一致：magic、tail、version、长度足够、CRC。
const std = @import("std");

pub const MAGIC_HIGH: u8 = 0xAA;
pub const MAGIC_LOW: u8 = 0x55;
pub const VERSION: u8 = 0x01;
pub const TAIL_HIGH: u8 = 0x55;
pub const TAIL_LOW: u8 = 0xAA;

pub const HEADER_SIZE: usize = 8;
pub const FOOTER_SIZE: usize = 4;
pub const MIN_SIZE: usize = HEADER_SIZE + FOOTER_SIZE;

/// 命令字（与参考客户端常量一一对应）。
pub const Cmd = struct {
    pub const config_device: u8 = 0x01;
    pub const get_device_list: u8 = 0x02;
    pub const get_hw_info: u8 = 0x03;
    pub const burn_image: u8 = 0x10;
    pub const cancel_burn: u8 = 0x12;
    pub const get_log: u8 = 0x20;
    pub const send_cmd: u8 = 0x21;
    pub const help: u8 = 0x30;
    pub const proto_version: u8 = 0x31;
    pub const heartbeat: u8 = 0x32;
    pub const log_stream: u8 = 0x22;
    pub const start_log_monitor: u8 = 0x23;
    pub const stop_log_monitor: u8 = 0x24;
    pub const serial_write: u8 = 0x25;
    pub const upload_firmware: u8 = 0x40;
    pub const firmware_chunk: u8 = 0x41;
    pub const upload_firmware_finish: u8 = 0x42;
    pub const get_upload_dir: u8 = 0x43;
    /// 响应位：设备侧回包把 cmd 与 0x80 相或。
    pub const rsp_mask: u8 = 0x80;
};

/// CRC16-CCITT（poly 0x1021，初值 0xFFFF），与参考客户端逐位一致。
pub fn crc16Ccitt(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

pub const Error = error{FrameTooShort};

/// 编码一帧（调用者释放）。
pub fn encode(allocator: std.mem.Allocator, cmd: u8, payload: []const u8) ![]u8 {
    const total = HEADER_SIZE + payload.len + FOOTER_SIZE;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    out[0] = MAGIC_HIGH;
    out[1] = MAGIC_LOW;
    out[2] = VERSION;
    out[3] = cmd;
    std.mem.writeInt(u32, out[4..8], @intCast(payload.len), .little);
    @memcpy(out[HEADER_SIZE..][0..payload.len], payload);

    const crc = crc16Ccitt(out[0 .. HEADER_SIZE + payload.len]);
    std.mem.writeInt(u16, out[HEADER_SIZE + payload.len ..][0..2], crc, .little);
    out[total - 2] = TAIL_HIGH;
    out[total - 1] = TAIL_LOW;
    return out;
}

pub const Decoded = struct {
    cmd: u8,
    payload: []const u8,
    /// 帧总长度（含头尾），便于串口流式消费。
    frame_len: usize,
};

pub const DecodeError = error{
    TooShort,
    BadMagic,
    BadTail,
    BadVersion,
    LengthMismatch,
    BadCrc,
};

pub fn decodeErrorText(err: DecodeError) []const u8 {
    return switch (err) {
        error.TooShort => "帧长度不足",
        error.BadMagic => "帧头不是 AA55",
        error.BadTail => "帧尾不是 55AA",
        error.BadVersion => "不支持的协议版本",
        error.LengthMismatch => "长度字段与实际数据不符",
        error.BadCrc => "CRC16 校验失败",
    };
}

/// 解码一帧。校验顺序与参考客户端一致（magic → tail → version → 长度 → CRC）。
pub fn decode(frame: []const u8) DecodeError!Decoded {
    if (frame.len < MIN_SIZE) return error.TooShort;
    if (frame[0] != MAGIC_HIGH or frame[1] != MAGIC_LOW) return error.BadMagic;
    if (frame[frame.len - 2] != TAIL_HIGH or frame[frame.len - 1] != TAIL_LOW) return error.BadTail;

    const version = frame[2];
    const cmd = frame[3];
    const payload_len: usize = std.mem.readInt(u32, frame[4..8], .little);
    if (version != VERSION) return error.BadVersion;

    const payload_end = HEADER_SIZE + payload_len;
    if (frame.len < payload_end + FOOTER_SIZE) return error.LengthMismatch;

    const received_crc = std.mem.readInt(u16, frame[payload_end..][0..2], .little);
    if (received_crc != crc16Ccitt(frame[0..payload_end])) return error.BadCrc;

    return .{
        .cmd = cmd,
        .payload = frame[HEADER_SIZE..payload_end],
        .frame_len = payload_end + FOOTER_SIZE,
    };
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------
test "upg_frame：CRC16-CCITT 标准向量" {
    // "123456789" 的 CRC16-CCITT/FALSE 标准值 0x29B1
    try std.testing.expectEqual(@as(u16, 0x29B1), crc16Ccitt("123456789"));
    try std.testing.expectEqual(@as(u16, 0xFFFF), crc16Ccitt(""));
}

test "upg_frame：编码布局与参考客户端一致" {
    const a = std.testing.allocator;
    const payload = "{\"a\":1}";
    const frame = try encode(a, Cmd.proto_version, payload);
    defer a.free(frame);

    try std.testing.expectEqual(@as(usize, HEADER_SIZE + payload.len + FOOTER_SIZE), frame.len);
    try std.testing.expectEqual(MAGIC_HIGH, frame[0]);
    try std.testing.expectEqual(MAGIC_LOW, frame[1]);
    try std.testing.expectEqual(VERSION, frame[2]);
    try std.testing.expectEqual(Cmd.proto_version, frame[3]);
    try std.testing.expectEqual(@as(u32, payload.len), std.mem.readInt(u32, frame[4..8], .little));
    try std.testing.expectEqualStrings(payload, frame[HEADER_SIZE..][0..payload.len]);

    const crc = std.mem.readInt(u16, frame[HEADER_SIZE + payload.len ..][0..2], .little);
    try std.testing.expectEqual(crc16Ccitt(frame[0 .. HEADER_SIZE + payload.len]), crc);
    try std.testing.expectEqual(TAIL_HIGH, frame[frame.len - 2]);
    try std.testing.expectEqual(TAIL_LOW, frame[frame.len - 1]);
}

test "upg_frame：空 payload 与往返解码" {
    const a = std.testing.allocator;
    const frame = try encode(a, Cmd.get_device_list, "");
    defer a.free(frame);
    try std.testing.expectEqual(MIN_SIZE, frame.len);

    const d = try decode(frame);
    try std.testing.expectEqual(Cmd.get_device_list, d.cmd);
    try std.testing.expectEqual(@as(usize, 0), d.payload.len);
    try std.testing.expectEqual(MIN_SIZE, d.frame_len);
}

test "upg_frame：各类损坏帧被拒绝" {
    const a = std.testing.allocator;
    const frame = try encode(a, Cmd.burn_image, "{\"img\":\"x.img\"}");
    defer a.free(frame);

    const short = frame[0 .. MIN_SIZE - 1];
    try std.testing.expectError(error.TooShort, decode(short));

    var bad = try a.dupe(u8, frame);
    defer a.free(bad);

    bad[0] = 0x00;
    try std.testing.expectError(error.BadMagic, decode(bad));
    bad[0] = MAGIC_HIGH;

    bad[bad.len - 1] = 0x00;
    try std.testing.expectError(error.BadTail, decode(bad));
    bad[bad.len - 1] = TAIL_LOW;

    bad[2] = 0x09;
    try std.testing.expectError(error.BadVersion, decode(bad));
    bad[2] = VERSION;

    bad[HEADER_SIZE] ^= 0xFF; // 改 payload → CRC 失配
    try std.testing.expectError(error.BadCrc, decode(bad));
}

test "upg_frame：长度字段与数据不符被拒绝" {
    const a = std.testing.allocator;
    const frame = try encode(a, Cmd.get_log, "{}");
    defer a.free(frame);
    var bad = try a.dupe(u8, frame);
    defer a.free(bad);
    std.mem.writeInt(u32, bad[4..8], 99, .little);
    try std.testing.expectError(error.LengthMismatch, decode(bad));
}
