//! Android sparse image（`img2simg` / `simg2img`）—— 对应参考工程
//! `tools/scripts/img2simg.exe`（makefatfs / 分区打包后用到的稀疏化步骤）。
//!
//! 块划分规则经参考工具实测：
//!   * 连续全零块 → FILL 块（fill = 0），不使用 DONT_CARE；
//!   * 其余块 → RAW 块，**非零重复块也不折叠**；
//!   * 末尾不足一块按 0 补齐，total_blks 向上取整。
const std = @import("std");

pub const MAGIC: u32 = 0xed26ff3a;
pub const HEADER_SIZE: usize = 28;
pub const CHUNK_HEADER_SIZE: usize = 12;

pub const ChunkType = enum(u16) {
    raw = 0xcac1,
    fill = 0xcac2,
    dont_care = 0xcac3,
    crc32 = 0xcac4,
    _,
};

pub const Header = struct {
    block_size: u32,
    total_blocks: u32,
    total_chunks: u32,
    image_checksum: u32,
};

pub const Error = error{
    Truncated,
    TooShort,
    BadMagic,
    BadVersion,
    BadChunk,
    OutOfMemory,
};

pub fn readHeader(data: []const u8) !Header {
    if (data.len < HEADER_SIZE) return Error.TooShort;
    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != MAGIC) return Error.BadMagic;
    const major = std.mem.readInt(u16, data[4..6], .little);
    const minor = std.mem.readInt(u16, data[6..8], .little);
    _ = minor;
    if (major != 1) return Error.BadVersion;
    const file_hdr_sz = std.mem.readInt(u16, data[8..10], .little);
    const chunk_hdr_sz = std.mem.readInt(u16, data[10..12], .little);
    if (file_hdr_sz != HEADER_SIZE or chunk_hdr_sz != CHUNK_HEADER_SIZE) return Error.BadVersion;
    return .{
        .block_size = std.mem.readInt(u32, data[12..16], .little),
        .total_blocks = std.mem.readInt(u32, data[16..20], .little),
        .total_chunks = std.mem.readInt(u32, data[20..24], .little),
        .image_checksum = std.mem.readInt(u32, data[24..28], .little),
    };
}

fn blockIsZero(block: []const u8) bool {
    for (block) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn appendChunkHeader(out: *std.ArrayList(u8), a: std.mem.Allocator, typ: ChunkType, blocks: u32, total_bytes: u32) !void {
    var buf: [CHUNK_HEADER_SIZE]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], @backingInt(typ), .little);
    std.mem.writeInt(u16, buf[2..4], 0, .little);
    std.mem.writeInt(u32, buf[4..8], blocks, .little);
    std.mem.writeInt(u32, buf[8..12], total_bytes, .little);
    try out.appendSlice(a, &buf);
}

/// raw → sparse（与参考 `img2simg <raw> <sparse> [block]` 逐字节一致）。
pub fn toSparse(allocator: std.mem.Allocator, raw: []const u8, block_size: u32) ![]u8 {
    if (block_size == 0) return Error.BadChunk;
    const blk: usize = block_size;
    const total_blocks: u32 = @intCast((raw.len + blk - 1) / blk);
    if (total_blocks == 0) return Error.TooShort;

    // 先统计 chunk 数
    var chunks: u32 = 0;
    var i: usize = 0;
    while (i < total_blocks) : (i += 1) {
        const start = i * blk;
        const end = @min(start + blk, raw.len);
        const zero = blockIsZero(raw[start..end]);
        chunks += 1;
        var j = i + 1;
        while (j < total_blocks) : (j += 1) {
            const s2 = j * blk;
            const e2 = @min(s2 + blk, raw.len);
            const z2 = blockIsZero(raw[s2..e2]);
            if (z2 != zero) break;
        }
        i = j - 1;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var header: [HEADER_SIZE]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], MAGIC, .little);
    std.mem.writeInt(u16, header[4..6], 1, .little);
    std.mem.writeInt(u16, header[6..8], 0, .little);
    std.mem.writeInt(u16, header[8..10], HEADER_SIZE, .little);
    std.mem.writeInt(u16, header[10..12], CHUNK_HEADER_SIZE, .little);
    std.mem.writeInt(u32, header[12..16], block_size, .little);
    std.mem.writeInt(u32, header[16..20], total_blocks, .little);
    std.mem.writeInt(u32, header[20..24], chunks, .little);
    std.mem.writeInt(u32, header[24..28], 0, .little);
    try out.appendSlice(allocator, &header);

    i = 0;
    while (i < total_blocks) {
        const start = i * blk;
        const end = @min(start + blk, raw.len);
        const zero = blockIsZero(raw[start..end]);

        var j = i + 1;
        while (j < total_blocks) : (j += 1) {
            const s2 = j * blk;
            const e2 = @min(s2 + blk, raw.len);
            if (blockIsZero(raw[s2..e2]) != zero) break;
        }
        const count: u32 = @intCast(j - i);

        if (zero) {
            try appendChunkHeader(&out, allocator, .fill, count, @as(u32, 4 + CHUNK_HEADER_SIZE));
            const fill: [4]u8 = @splat(0);
            try out.appendSlice(allocator, &fill);
        } else {
            const data_bytes: u32 = @intCast(count * block_size);
            try appendChunkHeader(&out, allocator, .raw, count, data_bytes + @as(u32, CHUNK_HEADER_SIZE));
            const data_start = i * blk;
            const data_end = @min(j * blk, raw.len);
            try out.appendSlice(allocator, raw[data_start..data_end]);
            var pad: u32 = data_bytes - @as(u32, @intCast(data_end - data_start));
            while (pad > 0) : (pad -= 1) try out.append(allocator, 0);
        }
        i = j;
    }

    return out.toOwnedSlice(allocator);
}

/// 打印 sparse 头与 chunk 表（对应参考 `simg_dump.py -v` 的文本口径）。
pub fn dump(writer: *std.Io.Writer, path: []const u8, data: []const u8) !void {
    const h = try readHeader(data);
    try writer.print("{s}: Total of {d} {d}-byte output blocks in {d} input chunks.\n", .{
        path, h.total_blocks, h.block_size, h.total_chunks,
    });
    if (h.image_checksum != 0) {
        try writer.print("checksum=0x{X:0>8}\n", .{h.image_checksum});
    }
    try writer.print("            input_bytes      output_blocks\n", .{});
    try writer.print("chunk    offset     number  offset  number\n", .{});

    var pos: usize = HEADER_SIZE;
    var out_block: u32 = 0;
    var i: u32 = 0;
    while (i < h.total_chunks) : (i += 1) {
        if (pos + CHUNK_HEADER_SIZE > data.len) return Error.Truncated;
        const typ: u16 = std.mem.readInt(u16, data[pos..][0..2], .little);
        const blocks = std.mem.readInt(u32, data[pos..][4..8], .little);
        const total_sz = std.mem.readInt(u32, data[pos..][8..12], .little);
        if (total_sz < CHUNK_HEADER_SIZE) return Error.BadChunk;
        const data_sz = total_sz - CHUNK_HEADER_SIZE;
        if (pos + total_sz > data.len) return Error.Truncated;

        try writer.print("{d:4} {d:10} {d:10} {d:7} {d:7} ", .{
            i + 1, pos + CHUNK_HEADER_SIZE, data_sz, out_block, blocks,
        });

        switch (typ) {
            @backingInt(ChunkType.raw) => {
                if (data_sz != blocks * h.block_size) return Error.BadChunk;
                try writer.writeAll("Raw data\n");
            },
            @backingInt(ChunkType.fill) => {
                if (data_sz != 4) return Error.BadChunk;
                const fill = std.mem.readInt(u32, data[pos + CHUNK_HEADER_SIZE ..][0..4], .little);
                try writer.print("Fill with 0x{X:0>8}\n", .{fill});
            },
            @backingInt(ChunkType.dont_care) => {
                if (data_sz != 0) return Error.BadChunk;
                try writer.writeAll("Don't care\n");
            },
            @backingInt(ChunkType.crc32) => {
                if (data_sz != 4) return Error.BadChunk;
                const crc = std.mem.readInt(u32, data[pos + CHUNK_HEADER_SIZE ..][0..4], .little);
                try writer.print("Unverified CRC32 0x{X:0>8}\n", .{crc});
            },
            else => try writer.print("Unknown chunk type 0x{X:0>4}\n", .{typ}),
        }

        pos += total_sz;
        out_block += blocks;
    }

    try writer.print("     {d:10}            {d:7}         End\n", .{ pos, out_block });
    if (h.total_blocks != out_block) {
        try writer.print("The header said we should have {d} output blocks, but we saw {d}\n", .{ h.total_blocks, out_block });
    }
    if (pos < data.len) {
        try writer.print("There were {d} bytes of extra data at the end of the file.\n", .{data.len - pos});
    }
}

/// sparse → raw（返回 total_blks * block_size 的展开数据，尾部补零）。
pub fn fromSparse(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const header = try readHeader(data);
    const total: usize = @as(usize, header.total_blocks) * header.block_size;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);

    var pos: usize = HEADER_SIZE;
    var block: usize = 0;
    var ci: u32 = 0;
    while (ci < header.total_chunks) : (ci += 1) {
        if (pos + CHUNK_HEADER_SIZE > data.len) return Error.Truncated;
        const typ = std.mem.readInt(u16, data[pos..][0..2], .little);
        const count: usize = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const total_bytes: usize = std.mem.readInt(u32, data[pos + 8 ..][0..4], .little);
        pos += CHUNK_HEADER_SIZE;
        const payload = total_bytes - CHUNK_HEADER_SIZE;
        if (pos + payload > data.len) return Error.Truncated;

        switch (typ) {
            @backingInt(ChunkType.raw) => {
                const bytes = count * header.block_size;
                if (block + count > header.total_blocks or payload < bytes) return Error.BadChunk;
                @memcpy(out[block * header.block_size ..][0..bytes], data[pos..][0..bytes]);
                block += count;
            },
            @backingInt(ChunkType.fill) => {
                if (payload < 4 or block + count > header.total_blocks) return Error.BadChunk;
                const value: [4]u8 = data[pos..][0..4].*;
                var k: usize = 0;
                while (k < count) : (k += 1) {
                    const off = (block + k) * header.block_size;
                    var p: usize = 0;
                    while (p < header.block_size) : (p += 4) {
                        @memcpy(out[off + p ..][0..4], &value);
                    }
                }
                block += count;
            },
            @backingInt(ChunkType.dont_care) => {
                if (block + count > header.total_blocks) return Error.BadChunk;
                block += count;
            },
            @backingInt(ChunkType.crc32) => {},
            else => return Error.BadChunk,
        }
        pos += payload;
    }
    if (block != header.total_blocks) return Error.BadChunk;
    return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
test "sparse：零块 FILL、非零 RAW、尾部补齐" {
    const allocator = std.testing.allocator;
    const blk = 16;
    const blob = "0123456789abcdef" ++ "0123456789abcdef"; // 2 个相同非零块
    const sparse = try toSparse(allocator, blob, blk);
    defer allocator.free(sparse);

    const h = try readHeader(sparse);
    try std.testing.expectEqual(@as(u32, 16), h.block_size);
    try std.testing.expectEqual(@as(u32, 2), h.total_blocks);
    try std.testing.expectEqual(@as(u32, 1), h.total_chunks);
    try std.testing.expectEqual(@as(usize, 28 + 12 + 32), sparse.len);
}

test "sparse：往返与头字段" {
    const allocator = std.testing.allocator;
    const blk = 32;
    const raw = try allocator.alloc(u8, blk * 5 + 7);
    defer allocator.free(raw);
    @memset(raw, 0);
    @memcpy(raw[blk..][0..3], "abc");
    @memset(raw[blk * 2 .. blk * 5], 0xAA);

    const sparse = try toSparse(allocator, raw, blk);
    defer allocator.free(sparse);

    const h = try readHeader(sparse);
    try std.testing.expectEqual(@as(u32, 32), h.block_size);
    try std.testing.expectEqual(@as(u32, 6), h.total_blocks);

    const back = try fromSparse(allocator, sparse);
    defer allocator.free(back);
    try std.testing.expectEqualSlices(u8, raw, back[0..raw.len]);
    for (back[raw.len..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "sparse：dump 头与 chunk 表" {
    const allocator = std.testing.allocator;
    const blk = 32;
    var raw: [blk * 2]u8 = @splat(0);
    raw[blk] = 0xAB;

    const sparse = try toSparse(allocator, &raw, blk);
    defer allocator.free(sparse);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try dump(&aw.writer, "x.simg", sparse);

    const text = aw.written();
    try std.testing.expect(std.mem.find(u8, text, "Total of 2 32-byte output blocks in 2 input chunks.") != null);
    try std.testing.expect(std.mem.find(u8, text, "Fill with 0x00000000") != null);
    try std.testing.expect(std.mem.find(u8, text, "Raw data") != null);
    try std.testing.expect(std.mem.find(u8, text, "         End") != null);
}

test "sparse：坏 magic" {
    var buf: [28]u8 = @splat(0);
    try std.testing.expectError(error.BadMagic, readHeader(&buf));
}

