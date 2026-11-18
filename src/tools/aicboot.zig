//! AIC 启动镜像 v2（`AIC ` 头 + loader + resource + 签名/MD5）
//! —— 逐字节复刻 `tools/scripts/mk_image.py` 的 `aic_boot_create_image_v2()`。
//!
//! 面向 `image_cfg.json` 的 `pre-process.aicimage.<name>` 配置（`mk_image.py -p` 的
//! aicimage 部分），支持：
//!   * 头版本 `head_ver`、`anti-rollback counter`（fw_ver）
//!   * `loader { file, load address, entry point }`（可省略，如纯 PBP 组件）
//!   * `resource { pbp, private, pubkey }`（写盘时按 32 字节对齐、整体 256 字节对齐）
//!   * `encryption { algo, key, iv }`：
//!       - `aes-128-cbc`（loader 走 CBC）
//!       - `ssk_derived_key = true` 时密钥 = AES-128-ECB(SSK, "0123456789abcdef")
//!   * `signature { algo, privkey }`：`rsa,2048`（PKCS#1 v1.5 SHA-256）、`hmac,sha256`
//!   * 未签名时按 `checksum-algo`（默认 md5）追加摘要，再回填整体 32 位校验和
//!   * `with_ext = true`（loader 在 DRAM 里运行时 loader 长度记 0、给 `loader_ext_offset`）
//!
//! 未支持（配置里一旦出现就明确报错，不静默糊过去）：`sm2` 签名、`sm4-*` / `chacha20`
//! 加密、`aes-128-ctr`、`pbp2` / `private2`（带二次签名/加密的资源变体）。
const std = @import("std");
const image_cfg = @import("image_cfg.zig");
const rsa = @import("rsa.zig");
const crypt = @import("crypt.zig");

pub const Error = error{
    BadConfig,
    MissingFile,
    UnsupportedAlgorithm,
    UnsupportedResource,
    LoaderTooLarge,
    NoAicImageEntries,
};

/// 头部固定 256 字节（4B magic + 20 个 u32 字段）。
pub const HEADER_SIZE: usize = 256;
const DATA_ALIGN: usize = 2048;
const META_ALIGN: usize = 512;

const SIGN_ALGO_RSA2048: u8 = 1;
const SIGN_ALGO_SM2: u8 = 2;
const SIGN_ALGO_HMAC_SHA256: u8 = 3;
const ENC_ALGO_AES128_CBC: u8 = 1;
const ENC_ALGO_SM4_ECB: u8 = 2;
const ENC_ALGO_SM4_CBC: u8 = 3;
const ENC_ALGO_AES128_CTR: u8 = 4;
const ENC_ALGO_CHACHA20: u8 = 5;

pub const Options = struct {
    cfg_path: []const u8,
    datadir: []const u8,
    keydir: ?[]const u8 = null,
};

pub const Generation = struct {
    name: []const u8,
    size: usize,
};

const FileSize = struct {
    raw: usize,
    rounded: usize,
};

const Res = struct {
    private: ?FileSize = null,
    private2: ?FileSize = null,
    pubkey: ?FileSize = null,
    pbp: ?FileSize = null,
    pbp2: ?FileSize = null,
    iv: ?FileSize = null,
    loader: ?FileSize = null,
};

fn roundUp(x: usize, y: usize) usize {
    return ((x + y - 1) / y) * y;
}

fn joinPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return allocator.dupe(u8, name);
    const last = dir[dir.len - 1];
    if (last == '/' or last == '\\') return std.mem.concat(allocator, u8, &.{ dir, name });
    return std.mem.concat(allocator, u8, &.{ dir, "/", name });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// 等价 Python `get_file_path(fpath, dirpath)`：先 dir+name，再按原样。
fn resolvePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    dirs: []const []const u8,
) !?[]u8 {
    for (dirs) |d| {
        if (d.len == 0) continue;
        const cand = try joinPath(allocator, d, name);
        if (fileExists(io, cand)) return cand;
        allocator.free(cand);
    }
    if (fileExists(io, name)) return try allocator.dupe(u8, name);
    return null;
}

fn statSize(io: std.Io, path: []const u8) !usize {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return Error.MissingFile;
    return @intCast(st.size);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch Error.MissingFile;
}

fn signLen(cfg: std.json.ObjectMap) usize {
    const sig = image_cfg.getObj(cfg, "signature") orelse return 0;
    const algo = image_cfg.getStr(sig, "algo") orelse return 0;
    if (std.mem.eql(u8, algo, "rsa,2048")) return 256;
    if (std.mem.eql(u8, algo, "sm2")) return 64;
    if (std.mem.eql(u8, algo, "hmac,sha256")) return 32;
    return 0;
}

fn cksumAuxLen(cfg: std.json.ObjectMap) usize {
    const algo = image_cfg.getStr(cfg, "checksum-algo") orelse return 16;
    const trimmed = std.mem.trim(u8, algo, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "md5")) return 16;
    if (std.ascii.eqlIgnoreCase(trimmed, "sm3")) return 32;
    return 0;
}

fn encAlgoId(cfg: std.json.ObjectMap) !u8 {
    const enc = image_cfg.getObj(cfg, "encryption") orelse return 0;
    const algo = image_cfg.getStr(enc, "algo") orelse return 0;
    if (std.mem.eql(u8, algo, "aes-128-cbc")) return ENC_ALGO_AES128_CBC;
    if (std.mem.eql(u8, algo, "sm4-ecb")) return ENC_ALGO_SM4_ECB;
    if (std.mem.eql(u8, algo, "sm4-cbc")) return ENC_ALGO_SM4_CBC;
    if (std.mem.eql(u8, algo, "aes-128-ctr")) return ENC_ALGO_AES128_CTR;
    if (std.mem.eql(u8, algo, "chacha20")) return ENC_ALGO_CHACHA20;
    return Error.UnsupportedAlgorithm;
}

fn encIvLen(algo_id: u8) usize {
    return switch (algo_id) {
        ENC_ALGO_CHACHA20 => 12,
        ENC_ALGO_SM4_ECB => 0,
        else => 16,
    };
}

fn withExt(cfg: std.json.ObjectMap) bool {
    const v = image_cfg.getStr(cfg, "with_ext") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "TRUE");
}

fn useSskDerived(cfg: std.json.ObjectMap) bool {
    const v = image_cfg.getStr(cfg, "ssk_derived_key") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "TRUE");
}

fn loaderAddr(cfg: std.json.ObjectMap) !struct { load: u32, entry: u32 } {
    var load: u32 = 0;
    var entry: u32 = 0;
    const ld = image_cfg.getObj(cfg, "loader") orelse return .{ .load = 0, .entry = 0 };
    const load_s = image_cfg.getStr(ld, "load address");
    const entry_s = image_cfg.getStr(ld, "entry point");
    if (load_s) |s| {
        if (std.mem.find(u8, s, "CONFIG_AIC_BOOTLOADER_") != null) return Error.BadConfig;
        load = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 0) catch return Error.BadConfig;
    }
    if (entry_s) |s| {
        if (std.mem.find(u8, s, "CONFIG_AIC_BOOTLOADER_") != null) return Error.BadConfig;
        entry = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 0) catch return Error.BadConfig;
    }
    if (load_s != null and entry_s == null) entry = load + 256;
    if (load_s == null and entry_s != null) load = entry - 256;
    return .{ .load = load, .entry = entry };
}

/// 读资源文件大小并做对齐（对应 `_add_resource_file_sizes`）。
fn addResourceSize(
    res: *Res,
    kind: enum { private, private2, pubkey, pbp, pbp2 },
    cfg_res: std.json.ObjectMap,
    dirs: []const []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    key: []const u8,
    align_to: usize,
) !void {
    const name = image_cfg.getStr(cfg_res, key) orelse return;
    const path = try resolvePath(allocator, io, name, dirs) orelse return Error.MissingFile;
    defer allocator.free(path);
    const size = try statSize(io, path);
    const fs: FileSize = .{ .raw = size, .rounded = roundUp(size, align_to) };
    switch (kind) {
        .private => res.private = fs,
        .private2 => res.private2 = fs,
        .pubkey => res.pubkey = fs,
        .pbp => res.pbp = fs,
        .pbp2 => res.pbp2 = fs,
    }
}

/// 等价 `aic_boot_get_resource_file_size()`。
fn collectSizes(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: std.json.ObjectMap,
    dirs: []const []const u8,
    datadir: []const u8,
) !Res {
    var res: Res = .{};
    const sl = signLen(cfg);

    if (image_cfg.getObj(cfg, "resource")) |r| {
        try addResourceSize(&res, .private, r, dirs, io, allocator, "private", 32);
        try addResourceSize(&res, .private2, r, dirs, io, allocator, "private2", if (sl != 0) sl else 4);
        try addResourceSize(&res, .pubkey, r, dirs, io, allocator, "pubkey", 32);
        try addResourceSize(&res, .pbp, r, dirs, io, allocator, "pbp", 32);
        try addResourceSize(&res, .pbp2, r, dirs, io, allocator, "pbp2", if (sl != 0) sl else 16);
    }

    if (image_cfg.getObj(cfg, "encryption")) |enc| {
        if (image_cfg.getStr(enc, "iv")) |iv_name| {
            const path = try resolvePath(allocator, io, iv_name, dirs) orelse return Error.MissingFile;
            defer allocator.free(path);
            const size = try statSize(io, path);
            res.iv = .{ .raw = size, .rounded = roundUp(size, 32) };
        }
    }

    if (image_cfg.getObj(cfg, "loader")) |ld| {
        if (image_cfg.getStr(ld, "file")) |file_name| {
            // loader 只在 datadir 里找（与参考一致）
            const path = try joinPath(allocator, datadir, file_name);
            defer allocator.free(path);
            const size = try statSize(io, path);
            if (size > 4 * 1024 * 1024) return Error.LoaderTooLarge;
            res.loader = .{ .raw = size, .rounded = roundUp(size, 256) };
        }
    }
    return res;
}

/// 等价 `aic_boot_calc_image_length()`。
fn imageLength(res: *const Res, resource_start: usize, sign_len: usize) usize {
    var total = resource_start;
    if (res.pubkey) |f| total += f.rounded;
    if (res.iv) |f| total += f.rounded;
    if (res.private2) |f| {
        total += f.rounded;
    } else if (res.private) |f| {
        total += f.rounded;
    }
    if (res.pbp2) |f| {
        total += f.rounded;
    } else if (res.pbp) |f| {
        total += f.rounded;
    }
    total = roundUp(total, 256);
    return total + sign_len;
}

const EncKey = struct {
    key: [16]u8,
    iv: [16]u8 = @splat(0),
};

/// 等价 `aic_boot_get_encryption_key()`：只支持 AES-128（key/iv 各 16B）。
fn encryptionKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: std.json.ObjectMap,
    dirs: []const []const u8,
    ssk_derived: bool,
) !EncKey {
    const enc = image_cfg.getObj(cfg, "encryption") orelse return Error.BadConfig;
    const key_name = image_cfg.getStr(enc, "key") orelse return Error.BadConfig;
    const key_path = try resolvePath(allocator, io, key_name, dirs) orelse return Error.MissingFile;
    defer allocator.free(key_path);
    const key_bytes = try readFile(allocator, io, key_path);
    defer allocator.free(key_bytes);
    if (key_bytes.len < 16) return Error.BadConfig;

    var out: EncKey = .{ .key = undefined };
    if (ssk_derived) {
        // HSK = AES-128-ECB(SSK, "0123456789abcdef")
        const ssk: [16]u8 = key_bytes[0..16].*;
        const km = "0123456789abcdef".*;
        var ctx = std.crypto.core.aes.Aes128.initEnc(ssk);
        var blk: [16]u8 = undefined;
        ctx.encrypt(&blk, &km);
        out.key = blk;
    } else {
        out.key = key_bytes[0..16].*;
    }

    if (image_cfg.getStr(enc, "iv")) |iv_name| {
        const iv_path = try resolvePath(allocator, io, iv_name, dirs) orelse return Error.MissingFile;
        defer allocator.free(iv_path);
        const iv_bytes = try readFile(allocator, io, iv_path);
        defer allocator.free(iv_bytes);
        if (iv_bytes.len < 16) return Error.BadConfig;
        out.iv = iv_bytes[0..16].*;
    }
    return out;
}

/// 等价 `aic_boot_get_loader_bytes_v2()`。
fn loaderBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: std.json.ObjectMap,
    res: *const Res,
    dirs: []const []const u8,
    datadir: []const u8,
) ![]u8 {
    const lf = res.loader orelse return allocator.alloc(u8, 0);

    const ld = image_cfg.getObj(cfg, "loader").?;
    const file_name = image_cfg.getStr(ld, "file") orelse return Error.BadConfig;
    const path = try joinPath(allocator, datadir, file_name);
    defer allocator.free(path);
    const raw = try readFile(allocator, io, path);
    defer allocator.free(raw);
    if (raw.len == 0) return Error.MissingFile;

    const out = try allocator.alloc(u8, lf.rounded);
    @memset(out, 0);
    @memcpy(out[0..@min(raw.len, lf.rounded)], raw[0..@min(raw.len, lf.rounded)]);

    const algo_id = try encAlgoId(cfg);
    if (algo_id == 0) return out;
    if (algo_id != ENC_ALGO_AES128_CBC) return Error.UnsupportedAlgorithm;

    const ek = try encryptionKey(allocator, io, cfg, dirs, useSskDerived(cfg));
    const enc = try crypt.encrypt(allocator, out, ek.key, ek.iv, .none);
    allocator.free(out);
    return enc;
}

/// 等价 `aic_boot_get_resource_bytes()`：pbp → private → pubkey → iv，整体 256 对齐。
fn resourceBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: std.json.ObjectMap,
    res: *const Res,
    dirs: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const r = image_cfg.getObj(cfg, "resource");
    if (res.pbp2 != null) return Error.UnsupportedResource; // PBP2 需要二次加签，未实现

    if (res.pbp) |f| {
        const name = image_cfg.getStr(r.?, "pbp") orelse return Error.BadConfig;
        const path = try resolvePath(allocator, io, name, dirs) orelse return Error.MissingFile;
        defer allocator.free(path);
        try appendPadded(&out, allocator, io, path, f.rounded);
    }
    if (res.private2 != null) return Error.UnsupportedResource; // 同上
    if (res.private) |f| {
        const name = image_cfg.getStr(r.?, "private") orelse return Error.BadConfig;
        const path = try resolvePath(allocator, io, name, dirs) orelse return Error.MissingFile;
        defer allocator.free(path);
        try appendPadded(&out, allocator, io, path, f.rounded);
    }
    if (res.pubkey) |f| {
        const name = image_cfg.getStr(r.?, "pubkey") orelse return Error.BadConfig;
        const path = try resolvePath(allocator, io, name, dirs) orelse return Error.MissingFile;
        defer allocator.free(path);
        try appendPadded(&out, allocator, io, path, f.rounded);
    }
    if (res.iv) |f| {
        const enc = image_cfg.getObj(cfg, "encryption").?;
        const name = image_cfg.getStr(enc, "iv") orelse return Error.BadConfig;
        const path = try resolvePath(allocator, io, name, dirs) orelse return Error.MissingFile;
        defer allocator.free(path);
        try appendPadded(&out, allocator, io, path, f.rounded);
    }

    if (out.items.len > 0) {
        const padded = roundUp(out.items.len, 256);
        if (padded != out.items.len) try out.appendNTimes(allocator, 0, padded - out.items.len);
    }
    return out.toOwnedSlice(allocator);
}

fn appendPadded(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    size: usize,
) !void {
    const data = try readFile(allocator, io, path);
    defer allocator.free(data);
    const n = @min(data.len, size);
    try out.appendSlice(allocator, data[0..n]);
    if (size > n) try out.appendNTimes(allocator, 0, size - n);
}

/// 32 位小端累加取反（等价 `aic_boot_checksum`）。
fn checksum(data: []const u8) u32 {
    var total: u32 = 0;
    var off: usize = 0;
    while (off + 4 <= data.len) : (off += 4) {
        total +%= std.mem.readInt(u32, data[off..][0..4], .little);
    }
    return ~total;
}

fn putU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

/// 生成签名（`aic_boot_gen_signature_bytes`）。
fn signatureBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: std.json.ObjectMap,
    dirs: []const []const u8,
    bootimg: []const u8,
) ![]u8 {
    const sig = image_cfg.getObj(cfg, "signature") orelse return Error.BadConfig;
    const algo = image_cfg.getStr(sig, "algo") orelse return Error.BadConfig;
    const key_name = image_cfg.getStr(sig, "privkey") orelse return Error.BadConfig;
    const key_path = try resolvePath(allocator, io, key_name, dirs) orelse return Error.MissingFile;
    defer allocator.free(key_path);
    const key_bytes = try readFile(allocator, io, key_path);
    defer allocator.free(key_bytes);

    if (std.mem.eql(u8, algo, "rsa,2048")) {
        var key = try rsa.parsePrivate(allocator, key_bytes);
        defer key.deinit(allocator);
        if (key.bits() != 2048) return Error.UnsupportedAlgorithm; // 参考只支持 RSA-2048
        return rsa.signSha256(allocator, &key, bootimg);
    }
    if (std.mem.eql(u8, algo, "hmac,sha256")) {
        if (key_bytes.len != 16) return Error.BadConfig;
        // HMAC 密钥 = AES-128-ECB(privkey16, bootimg[0..64])
        if (bootimg.len < 64) return Error.BadConfig;
        var ctx = std.crypto.core.aes.Aes128.initEnc(key_bytes[0..16].*);
        var hmackey: [64]u8 = undefined;
        var i: usize = 0;
        while (i < 64) : (i += 16) {
            ctx.encrypt(hmackey[i..][0..16], bootimg[i..][0..16]);
        }
        const mac_size = std.crypto.auth.hmac.sha2.HmacSha256.mac_length;
        var mac: [mac_size]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, bootimg, &hmackey);
        return allocator.dupe(u8, &mac);
    }
    if (std.mem.eql(u8, algo, "sm2")) return Error.UnsupportedAlgorithm;
    return Error.UnsupportedAlgorithm;
}

/// 生成一个 AIC 启动镜像（等价 `aic_boot_create_image_v2`）。
pub fn createImageV2(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: std.json.ObjectMap,
    datadir: []const u8,
    keydir: []const u8,
) ![]u8 {
    const dirs = [_][]const u8{ keydir, datadir };
    var res = try collectSizes(allocator, io, cfg, &dirs, datadir);

    const algo_id = try encAlgoId(cfg);
    if (algo_id == ENC_ALGO_AES128_CTR or algo_id == ENC_ALGO_SM4_CBC or
        algo_id == ENC_ALGO_SM4_ECB or algo_id == ENC_ALGO_CHACHA20)
    {
        return Error.UnsupportedAlgorithm;
    }

    const loader = try loaderBytes(allocator, io, cfg, &res, &dirs, datadir);
    defer allocator.free(loader);

    const resource_start = HEADER_SIZE + (res.loader orelse FileSize{ .raw = 0, .rounded = 0 }).rounded;

    const sig_len = signLen(cfg);
    const aux_len = cksumAuxLen(cfg);
    const default_tail = if (sig_len != 0) sig_len else aux_len;
    const img_len = imageLength(&res, resource_start, default_tail);

    const resources = try resourceBytes(allocator, io, cfg, &res, &dirs);
    defer allocator.free(resources);

    // ---- 头部字段（顺序与参考 _gen_header_bytes 一致）----
    const addr = try loaderAddr(cfg);
    const ext = withExt(cfg);

    const sign_algo: u32 = if (sig_len == 0) 0 else switch (sig_len) {
        256 => SIGN_ALGO_RSA2048,
        32 => SIGN_ALGO_HMAC_SHA256,
        64 => SIGN_ALGO_SM2,
        else => 0,
    };
    const sign_length: u32 = @intCast(if (sig_len != 0) sig_len else aux_len);
    const sign_offset: u32 = @intCast(img_len - @as(usize, sign_length));

    // 资源偏移（pbp → private → pubkey → iv）
    var next_res = resource_start;
    var pbp_off: u32 = 0;
    var pbp_len: u32 = 0;
    if (res.pbp2) |f| {
        pbp_off = @intCast(next_res);
        pbp_len = @intCast(f.rounded);
        next_res += f.rounded;
    } else if (res.pbp) |f| {
        pbp_off = @intCast(next_res);
        pbp_len = @intCast(f.rounded);
        next_res += f.rounded;
    }
    var priv_off: u32 = 0;
    var priv_len: u32 = 0;
    if (res.private2) |f| {
        priv_off = @intCast(next_res);
        priv_len = @intCast(f.rounded);
        next_res += f.rounded;
    } else if (res.private) |f| {
        priv_off = @intCast(next_res);
        priv_len = @intCast(f.raw);
        next_res += f.rounded;
    }
    var key_off: u32 = 0;
    var key_len: u32 = 0;
    if (res.pubkey) |f| {
        key_off = @intCast(next_res);
        key_len = @intCast(f.raw);
        next_res += f.rounded;
    }
    var iv_off: u32 = 0;
    var iv_len: u32 = 0;
    if (res.iv) |f| {
        iv_off = @intCast(next_res);
        iv_len = @intCast(encIvLen(algo_id));
        next_res += f.rounded;
    }

    const fw_ver: u32 = blk: {
        const v = image_cfg.getInt(cfg, "anti-rollback counter") orelse break :blk 0;
        break :blk @intCast(v);
    };
    const head_ver: u32 = blk: {
        const s = image_cfg.getStr(cfg, "head_ver") orelse break :blk 0x00010001;
        break :blk std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 0) catch return Error.BadConfig;
    };
    const loader_len: u32 = if (ext) 0 else @intCast((res.loader orelse FileSize{ .raw = 0, .rounded = 0 }).raw);
    const ext_off: u32 = if (ext) @intCast(roundUp(img_len, META_ALIGN)) else 0;

    const total = HEADER_SIZE + loader.len + resources.len + (if (sig_len != 0) sig_len else aux_len);
    if (total != img_len) return Error.BadConfig; // 头部 img_len 与实际长度必须一致
    const out = try allocator.alloc(u8, HEADER_SIZE + loader.len + resources.len);
    @memset(out, 0);
    @memcpy(out[0..4], "AIC ");
    const fields = [_]u32{
        0, // checksum（签名后保持 0）
        head_ver,
        @intCast(img_len),
        fw_ver,
        loader_len,
        addr.load,
        addr.entry,
        sign_algo,
        algo_id,
        sign_offset,
        sign_length,
        key_off,
        key_len,
        iv_off,
        iv_len,
        priv_off,
        priv_len,
        pbp_off,
        pbp_len,
        ext_off,
    };
    for (fields, 0..) |f, i| putU32(out, 4 + i * 4, f);
    @memcpy(out[HEADER_SIZE..][0..loader.len], loader);
    @memcpy(out[HEADER_SIZE + loader.len ..][0..resources.len], resources);

    // ---- 尾部：签名 或 md5+校验和 ----
    if (sig_len != 0) {
        const sig = try signatureBytes(allocator, io, cfg, &dirs, out);
        defer allocator.free(sig);
        const full = try std.mem.concat(allocator, u8, &.{ out, sig });
        allocator.free(out);
        if (ext and full.len % META_ALIGN != 0) {
            const padded = roundUp(full.len, META_ALIGN);
            const buf = try allocator.alloc(u8, padded);
            @memset(buf, 0);
            @memcpy(buf[0..full.len], full);
            allocator.free(full);
            return buf;
        }
        return full;
    }

    if (aux_len == 32) return Error.UnsupportedAlgorithm; // sm3 摘要未实现
    // md5(bootimg[8:])
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(out[8..], &digest, .{});
    var full = try std.mem.concat(allocator, u8, &.{ out, &digest });
    allocator.free(out);
    if (ext and full.len % META_ALIGN != 0) {
        const padded = roundUp(full.len, META_ALIGN);
        const buf = try allocator.alloc(u8, padded);
        @memset(buf, 0);
        @memcpy(buf[0..full.len], full);
        allocator.free(full);
        full = buf;
    }
    // 回填整体校验和（使全镜像 32 位累加为 0）
    const cs = checksum(full);
    putU32(full, 4, cs);
    if (checksum(full) != 0) return Error.BadConfig;
    return full;
}

/// 处理 `pre-process.aicimage` 下的全部条目，写回 `datadir/<name>`。
pub fn preprocess(
    allocator: std.mem.Allocator,
    io: std.Io,
    opt: Options,
) ![]Generation {
    var cfg_parsed = try image_cfg.load(allocator, io, opt.cfg_path);
    defer cfg_parsed.deinit();
    const root = image_cfg.asObject(cfg_parsed.root().*) orelse return Error.BadConfig;

    const pre = image_cfg.getObj(root, "pre-process") orelse image_cfg.getObj(root, "temporary") orelse
        return Error.NoAicImageEntries;
    const aicimage = image_cfg.getObj(pre, "aicimage") orelse return Error.NoAicImageEntries;

    var datadir = opt.datadir;
    const keydir = opt.keydir orelse opt.datadir;

    var gens: std.ArrayList(Generation) = .empty;
    errdefer gens.deinit(allocator);

    var it = aicimage.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const cfg = image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig;
        const bytes = try createImageV2(allocator, io, cfg, datadir, keydir);
        defer allocator.free(bytes);

        const out_path = try joinPath(allocator, datadir, name);
        defer allocator.free(out_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bytes });
        try gens.append(allocator, .{ .name = try allocator.dupe(u8, name), .size = bytes.len });
    }
    datadir = opt.datadir;
    return gens.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// 单测（不依赖参考工具）
// ---------------------------------------------------------------------------
test "aicboot：roundUp 对齐" {
    try std.testing.expectEqual(@as(usize, 256), roundUp(1, 256));
    try std.testing.expectEqual(@as(usize, 256), roundUp(256, 256));
    try std.testing.expectEqual(@as(usize, 512), roundUp(257, 256));
    try std.testing.expectEqual(@as(usize, 32), roundUp(16, 32));
}

test "aicboot：checksum 使整镜像 32 位累加为 0" {
    var buf = @as([16]u8, @splat(0));
    @memcpy(buf[0..4], "AIC ");
    putU32(&buf, 4, checksum(&buf));
    try std.testing.expectEqual(@as(u32, 0), checksum(&buf));
}

test "aicboot：无 loader/无资源的头与校验和" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 构造最小配置：只有 head_ver，无 loader/resource/encryption/signature
    const json_text =
        \\{"head_ver":"0x00010002"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    defer parsed.deinit();
    const cfg = image_cfg.asObject(parsed.value) orelse return error.BadConfig;

    // datadir 用当前目录，最小配置下不会去读任何文件
    const bytes = try createImageV2(a, std.testing.io, cfg, ".", ".");
    try std.testing.expectEqual(HEADER_SIZE + 16, bytes.len); // 头 + md5
    try std.testing.expectEqualSlices(u8, "AIC ", bytes[0..4]);
    try std.testing.expectEqual(@as(u32, 0x00010002), std.mem.readInt(u32, bytes[8..12], .little)); // head_ver
    try std.testing.expectEqual(@as(u32, @intCast(bytes.len)), std.mem.readInt(u32, bytes[12..16], .little)); // img_len
    try std.testing.expectEqual(@as(u32, 0), checksum(bytes)); // 整镜像 32 位累加为 0
}
