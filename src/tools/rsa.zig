//! RSA PKCS#1 v1.5（SHA-256）签名/验签 —— 对应参考工程
//! `mk_image.py` 里 PyCryptodome `PKCS1_v1_5` 的签名流程与 U-Boot
//! `bootm` 的 RSA 校验。
//!
//! 边界：
//!   * 只支持 PKCS#1 v1.5 + SHA-256（参考里 rsa2048/rsa3072 常用组合）；
//!   * 私钥支持 `RSA PRIVATE KEY`(PKCS#1) 与 `PRIVATE KEY`(PKCS#8)；
//!   * 公钥支持 `PUBLIC KEY`(SPKI) 与 `RSA PUBLIC KEY`(PKCS#1)；
//!   * 不支持加密私钥、PSS、SM2。
const std = @import("std");
const Managed = std.math.big.int.Managed;

pub const Error = error{
    BadPem,
    BadDer,
    UnsupportedKey,
    BadKeySize,
    InvalidSignature,
};

// ---------------------------------------------------------------------------
// PEM / DER
// ---------------------------------------------------------------------------
const Der = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(self: *Der) !u8 {
        if (self.pos >= self.data.len) return Error.BadDer;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    const Tlv = struct { tag: u8, value: []const u8 };

    fn readTlv(self: *Der) !Tlv {
        const tag = try self.readByte();
        const first = try self.readByte();
        var len: usize = 0;
        if (first & 0x80 == 0) {
            len = first;
        } else {
            const n = first & 0x7f;
            if (n == 0 or n > 4) return Error.BadDer;
            var i: usize = 0;
            while (i < n) : (i += 1) len = (len << 8) | try self.readByte();
        }
        if (self.pos + len > self.data.len) return Error.BadDer;
        const value = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return .{ .tag = tag, .value = value };
    }

    fn expect(self: *Der, tag: u8) ![]const u8 {
        const tlv = try self.readTlv();
        if (tlv.tag != tag) return Error.BadDer;
        return tlv.value;
    }
};

fn base64DecodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, text);
    return out;
}

/// 解析 PEM，返回 DER 字节（调用者释放）。
pub fn pemToDer(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin_marker = "-----BEGIN";
    const start = std.mem.find(u8, pem, begin_marker) orelse return Error.BadPem;
    const line_end = std.mem.findScalar(u8, pem[start..], '\n') orelse return Error.BadPem;
    const header_end = start + line_end + 1;
    const end_marker = std.mem.find(u8, pem[header_end..], "-----END") orelse return Error.BadPem;
    const body = pem[header_end .. header_end + end_marker];

    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    for (body) |c| {
        if (c == '\r' or c == '\n' or c == ' ' or c == '\t') continue;
        try cleaned.append(allocator, c);
    }
    return base64DecodeAlloc(allocator, cleaned.items);
}

fn isPrivateLabel(pem: []const u8) bool {
    return std.mem.find(u8, pem, "PRIVATE KEY-----") != null;
}
fn isPkcs8(pem: []const u8) bool {
    // "BEGIN PRIVATE KEY" 而不是 "BEGIN RSA PRIVATE KEY"
    return std.mem.find(u8, pem, "BEGIN PRIVATE KEY") != null;
}

// ---------------------------------------------------------------------------
// 大整数
// ---------------------------------------------------------------------------
fn managedFromBigEndian(allocator: std.mem.Allocator, bytes: []const u8) !Managed {
    var buf: [1200]u8 = undefined;
    // 去掉 DER INTEGER 的符号前导 0
    var i: usize = 0;
    while (i + 1 < bytes.len and bytes[i] == 0) i += 1;
    const hex = bytesToHex(buf[0..], bytes[i..]);
    var m = try Managed.init(allocator);
    errdefer m.deinit();
    try m.setString(16, hex);
    return m;
}

fn bytesToHex(buf: []u8, bytes: []const u8) []u8 {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        buf[i * 2] = digits[bytes[i] >> 4];
        buf[i * 2 + 1] = digits[bytes[i] & 0x0f];
    }
    return buf[0 .. bytes.len * 2];
}

fn modMul(a: *Managed, b: *Managed, m: *const Managed, tmp: *Managed, q: *Managed, r: *Managed) !void {
    try tmp.mul(a, b);
    try q.divFloor(r, tmp, m);
    try a.copy(r.toConst());
}

/// out = base^exp mod modulus（out 长度固定为 modulus 字节长度）
fn modexpFixed(
    allocator: std.mem.Allocator,
    base: []const u8,
    exp: []const u8,
    modulus: []const u8,
    out: []u8,
) !void {
    var mi: usize = 0;
    while (mi < modulus.len and modulus[mi] == 0) mi += 1;
    const k = modulus.len - mi;
    if (out.len != k) return Error.BadKeySize;

    var n = try managedFromBigEndian(allocator, modulus);
    defer n.deinit();
    var m = try managedFromBigEndian(allocator, base);
    defer m.deinit();

    var result = try Managed.initSet(allocator, 1);
    defer result.deinit();
    var tmp = try Managed.init(allocator);
    defer tmp.deinit();
    var q = try Managed.init(allocator);
    defer q.deinit();
    var r = try Managed.init(allocator);
    defer r.deinit();

    // 逐位 MSB→LSB
    var started = false;
    for (exp) |byte| {
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            if (!started) {
                if (byte & bit == 0) continue;
                started = true;
            }
            // result = result^2 mod n
            try modMul(&result, &result, &n, &tmp, &q, &r);
            if (byte & bit != 0) {
                // result = result * base mod n
                try modMul(&result, &m, &n, &tmp, &q, &r);
            }
        }
    }
    result.toConst().writeTwosComplement(out, .big);
}

// ---------------------------------------------------------------------------
// 密钥解析
// ---------------------------------------------------------------------------
pub const PrivateKey = struct {
    der: []u8,
    n: []u8,
    e: []u8,
    d: []u8,

    pub fn deinit(self: *PrivateKey, allocator: std.mem.Allocator) void {
        allocator.free(self.der);
        allocator.free(self.n);
        allocator.free(self.e);
        allocator.free(self.d);
    }

    pub fn bits(self: *const PrivateKey) usize {
        var i: usize = 0;
        while (i < self.n.len and self.n[i] == 0) i += 1;
        return (self.n.len - i) * 8;
    }
};

pub const PublicKey = struct {
    der: []u8,
    n: []u8,
    e: []u8,

    pub fn deinit(self: *PublicKey, allocator: std.mem.Allocator) void {
        allocator.free(self.der);
        allocator.free(self.n);
        allocator.free(self.e);
    }
};

fn parseRsaPrivate(der: []const u8) !struct { n: []const u8, e: []const u8, d: []const u8 } {
    var outer = Der{ .data = der };
    const seq = try outer.expect(0x30);
    var it = Der{ .data = seq };
    _ = try it.expect(0x02); // version
    const n = try it.expect(0x02);
    const e = try it.expect(0x02);
    const d = try it.expect(0x02);
    return .{ .n = n, .e = e, .d = d };
}

fn parseRsaPublic(der: []const u8) !struct { n: []const u8, e: []const u8 } {
    var outer = Der{ .data = der };
    const seq = try outer.expect(0x30);
    var it = Der{ .data = seq };
    const n = try it.expect(0x02);
    const e = try it.expect(0x02);
    return .{ .n = n, .e = e };
}

pub fn parsePrivatePem(allocator: std.mem.Allocator, pem: []const u8) !PrivateKey {
    const der = try pemToDer(allocator, pem);
    errdefer allocator.free(der);

    var pkcs1: []const u8 = der;
    var inner: ?[]u8 = null;
    defer if (inner) |i| allocator.free(i);

    if (isPkcs8(pem)) {
        var outer = Der{ .data = der };
        const seq = try outer.expect(0x30);
        var it = Der{ .data = seq };
        _ = try it.expect(0x02); // version
        _ = try it.expect(0x30); // AlgorithmIdentifier
        const octet = try it.expect(0x04);
        inner = try allocator.dupe(u8, octet);
        pkcs1 = inner.?;
    } else if (!isPrivateLabel(pem)) {
        return Error.UnsupportedKey;
    }

    const parts = try parseRsaPrivate(pkcs1);
    return .{
        .der = der,
        .n = try allocator.dupe(u8, parts.n),
        .e = try allocator.dupe(u8, parts.e),
        .d = try allocator.dupe(u8, parts.d),
    };
}

/// 解析 DER 私钥（自动区分 PKCS#1 `RSAPrivateKey` 与 PKCS#8 `PrivateKeyInfo`）。
pub fn parsePrivateDer(allocator: std.mem.Allocator, der_in: []const u8) !PrivateKey {
    const der = try allocator.dupe(u8, der_in);
    errdefer allocator.free(der);

    var pkcs1: []const u8 = der;
    var inner: ?[]u8 = null;
    defer if (inner) |i| allocator.free(i);

    // PKCS#8 = SEQ { INTEGER version, SEQ algid, OCTET STRING(RSAPrivateKey) }
    // PKCS#1 = SEQ { INTEGER version, INTEGER n, INTEGER e, INTEGER d, ... }
    var outer = Der{ .data = der };
    const seq = try outer.expect(0x30);
    var probe = Der{ .data = seq };
    const ver = try probe.readTlv();
    if (ver.tag != 0x02) return Error.BadDer;
    const second = try probe.readTlv();
    if (second.tag == 0x30) {
        var it = Der{ .data = seq };
        _ = try it.expect(0x02); // version
        _ = try it.expect(0x30); // AlgorithmIdentifier
        const octet = try it.expect(0x04);
        inner = try allocator.dupe(u8, octet);
        pkcs1 = inner.?;
    }

    const parts = try parseRsaPrivate(pkcs1);
    return .{
        .der = der,
        .n = try allocator.dupe(u8, parts.n),
        .e = try allocator.dupe(u8, parts.e),
        .d = try allocator.dupe(u8, parts.d),
    };
}

/// 解析私钥：自动识别 PEM / DER（PKCS#1 或 PKCS#8）。
pub fn parsePrivate(allocator: std.mem.Allocator, bytes: []const u8) !PrivateKey {
    if (std.mem.find(u8, bytes, "-----BEGIN") != null) return parsePrivatePem(allocator, bytes);
    return parsePrivateDer(allocator, bytes);
}

pub fn parsePublicPem(allocator: std.mem.Allocator, pem: []const u8) !PublicKey {
    const der = try pemToDer(allocator, pem);
    errdefer allocator.free(der);

    var rsa_der: []const u8 = der;
    var inner: ?[]u8 = null;
    defer if (inner) |i| allocator.free(i);

    if (std.mem.find(u8, pem, "BEGIN PUBLIC KEY") != null) {
        // SPKI: SEQ { SEQ alg, BIT STRING { SEQ{n,e} } }
        var outer = Der{ .data = der };
        const seq = try outer.expect(0x30);
        var it = Der{ .data = seq };
        _ = try it.expect(0x30);
        const bits = try it.expect(0x03);
        if (bits.len < 1) return Error.BadDer;
        inner = try allocator.dupe(u8, bits[1..]); // 跳过 unused bits
        rsa_der = inner.?;
    } else if (std.mem.find(u8, pem, "BEGIN RSA PUBLIC KEY") == null) {
        return Error.UnsupportedKey;
    }

    const parts = try parseRsaPublic(rsa_der);
    return .{
        .der = der,
        .n = try allocator.dupe(u8, parts.n),
        .e = try allocator.dupe(u8, parts.e),
    };
}

// ---------------------------------------------------------------------------
// PKCS#1 v1.5
// ---------------------------------------------------------------------------
const sha256_digest_info = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};

fn buildEmSha256(allocator: std.mem.Allocator, data: []const u8, k: usize) ![]u8 {
    if (k < sha256_digest_info.len + 32 + 11) return Error.BadKeySize;
    const em = try allocator.alloc(u8, k);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});

    em[0] = 0x00;
    em[1] = 0x01;
    @memset(em[2 .. k - sha256_digest_info.len - 32 - 1], 0xFF);
    em[k - sha256_digest_info.len - 32 - 1] = 0x00;
    @memcpy(em[k - sha256_digest_info.len - 32 ..][0..sha256_digest_info.len], &sha256_digest_info);
    @memcpy(em[k - 32 ..], &digest);
    return em;
}

/// 生成 PKCS#1 v1.5 SHA-256 签名（返回 k 字节）。
pub fn signSha256(
    allocator: std.mem.Allocator,
    key: *const PrivateKey,
    data: []const u8,
) ![]u8 {
    const n = key.n;
    var ni: usize = 0;
    while (ni < n.len and n[ni] == 0) ni += 1;
    const k = n.len - ni;
    const em = try buildEmSha256(allocator, data, k);
    defer allocator.free(em);

    const sig = try allocator.alloc(u8, k);
    errdefer allocator.free(sig);
    try modexpFixed(allocator, em, key.d, n, sig);
    return sig;
}

/// 校验 PKCS#1 v1.5 SHA-256 签名。
pub fn verifySha256(
    allocator: std.mem.Allocator,
    key: *const PublicKey,
    data: []const u8,
    signature: []const u8,
) !bool {
    var ni: usize = 0;
    while (ni < key.n.len and key.n[ni] == 0) ni += 1;
    const k = key.n.len - ni;
    if (signature.len != k) return false;

    const em = try buildEmSha256(allocator, data, k);
    defer allocator.free(em);

    const out = try allocator.alloc(u8, k);
    defer allocator.free(out);
    try modexpFixed(allocator, signature, key.e, key.n, out);
    return std.mem.eql(u8, em, out);
}

// ---------------------------------------------------------------------------
// 测试（向量由参考 tools/scripts/openssl.exe 生成）
// ---------------------------------------------------------------------------
const test_priv_pem =
    "-----BEGIN PRIVATE KEY-----\n" ++
    "MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAnpHvk0oUy9DIddLj\n" ++
    "y4EaTfjAmVVY9VgjH9nO7FmdnK2zI0Kzg2wjoglSAsWBjN9kyYZA5AD94l0SKPfh\n" ++
    "8GVrJQIDAQABAkEAiHDb6ymYQVOx2SgQGABLaQH8fzNf6yPefT6F/PqTUscMl0fO\n" ++
    "WwHOoxgth0O1lanXLREW3lFBZJbbGYSo+/EA1QIhAMvUqgrfG4/t8ZyUcQUNs5xi\n" ++
    "cDbaXTJwgMC6NrXZxupPAiEAxye3XNRFkLCGdQmUJKM8vUyF3eC6Kcyb1Sa4HiKR\n" ++
    "WksCIGZzrUirneH5WqE2Z5x/p5DqVbbsiT2qGL1Gm+tJ3Fa3AiEAuE62MC+2zYfA\n" ++
    "d5HMyvdS3/Fwtf0i7EoSMXoqzKC7Ge8CIGe/Zdx+3m+s5GQ4Nrbxi5NaPTl+tpVC\n" ++
    "XY8O5n/VOPrz\n" ++
    "-----END PRIVATE KEY-----\n";

const test_pub_pem =
    "-----BEGIN PUBLIC KEY-----\n" ++
    "MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAJ6R75NKFMvQyHXS48uBGk34wJlVWPVY\n" ++
    "Ix/ZzuxZnZytsyNCs4NsI6IJUgLFgYzfZMmGQOQA/eJdEij34fBlayUCAwEAAQ==\n" ++
    "-----END PUBLIC KEY-----\n";

const test_sig_hex = "99ab297b8524b1a5137abd0833f7641a13281ff3b937141b3d105d4da32239e35d574bef80f13214ef7782b4b198623be4fb43acecd1972518bd0b211d4b45c2";
const test_data = "WuKong-Lite RSA test vector\n";

test "RSA PKCS#1 v1.5 SHA-256 与 openssl 向量一致" {
    const allocator = std.testing.allocator;

    var priv = try parsePrivatePem(allocator, test_priv_pem);
    defer priv.deinit(allocator);
    const sig = try signSha256(allocator, &priv, test_data);
    defer allocator.free(sig);

    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, test_sig_hex);
    try std.testing.expectEqualSlices(u8, &expected, sig);

    var pub_key = try parsePublicPem(allocator, test_pub_pem);
    defer pub_key.deinit(allocator);
    try std.testing.expect(try verifySha256(allocator, &pub_key, test_data, sig));
    try std.testing.expect(!try verifySha256(allocator, &pub_key, "tampered", sig));
}

test "RSA DER 私钥（PKCS#1 / PKCS#8）与 PEM 等价" {
    const allocator = std.testing.allocator;

    // 由测试用 PEM 现解出 DER，避免再嵌一份 1KB 夹具
    const der = try pemToDer(allocator, test_priv_pem);
    defer allocator.free(der);

    var from_der = try parsePrivateDer(allocator, der);
    defer from_der.deinit(allocator);
    var from_pem = try parsePrivatePem(allocator, test_priv_pem);
    defer from_pem.deinit(allocator);
    try std.testing.expectEqualSlices(u8, from_pem.n, from_der.n);
    try std.testing.expectEqualSlices(u8, from_pem.e, from_der.e);
    try std.testing.expectEqualSlices(u8, from_pem.d, from_der.d);

    // parsePrivate 自动识别 DER / PEM
    var auto_der = try parsePrivate(allocator, der);
    defer auto_der.deinit(allocator);
    try std.testing.expectEqualSlices(u8, from_pem.n, auto_der.n);
    var auto_pem = try parsePrivate(allocator, test_priv_pem);
    defer auto_pem.deinit(allocator);
    try std.testing.expectEqualSlices(u8, from_pem.n, auto_pem.n);

    // RSA-1024 的 keysize 必须是 64 字节标记（用签名长度间接确认）
    const sig = try signSha256(allocator, &from_der, test_data);
    defer allocator.free(sig);
    try std.testing.expectEqual(@as(usize, 64), sig.len);
}
