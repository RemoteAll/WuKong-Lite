//! RSA 密钥加密 / PKCS#1 导出 —— 对应参考工程
//! `tools/scripts/encrypt_rsa_key.py`（PyCryptodome 实现）。
//!
//! 用途：把 RSA 密钥（n/e[/d/p/q/u]）按“AIC 硬件加解密引擎读小端”的口径
//! 转成小端字节流，用 AES-128-ECB 或 DES-ECB 加密后重新编码为 DER，
//! 供安全启动把密钥写入 flash / 交给硬件解密使用。
//!
//! 与参考实现的对齐点（逐字节一致，已用 openssl 生成密钥对拍）：
//!   * 私钥导出为 PKCS#1 `RSAPrivateKey`：`{version, n, e, d, p, q, dp, dq, qinv}`；
//!   * 公钥导出为 PKCS#1 `RSAPublicKey`：`{n, e}`（参考脚本默认 pkcs=1）；
//!   * 每个整数先转小端并补零到 keysize，ECB 加密后再转回大端最小表示；
//!   * **只有 n 在密文末尾追加 0x01**（让 n 的长度恒大于其它分量）；
//!   * keysize 按 n 的位长分档：>3072→512、>2048→384、>1024→256、>512→128、>500→64；
//!   * dp = d % (p-1)、dq = d % (q-1)，qinv 沿用原密钥的 u（不重算）。
//!
//! 与参考实现的已知差异：参考脚本对「公钥 + 对称密钥」会因访问 `key.p`
//! 直接抛异常（PyCryptodome 公钥无 CRT 分量），这里按语义实现（只加密 n/e）。
const std = @import("std");
const Managed = std.math.big.int.Managed;
const des = @import("des.zig");

pub const Error = error{
    BadPem,
    BadDer,
    UnsupportedKey,
    UnsupportedKeySize,
    BadSymKeySize,
};

pub const Kind = enum { private, public };

/// 已解析的 RSA 密钥；n/e/d/p/q/u 均为**大端**字节（可能带 DER 的 0x00 前导）。
pub const Key = struct {
    der: []u8,
    kind: Kind,
    n: []const u8,
    e: []const u8,
    d: ?[]const u8 = null,
    p: ?[]const u8 = null,
    q: ?[]const u8 = null,
    u: ?[]const u8 = null,

    pub fn deinit(self: *Key, allocator: std.mem.Allocator) void {
        allocator.free(self.der);
        self.* = undefined;
    }

    /// n 的位长（与 PyCryptodome `size_in_bits()` 同口径：去掉前导零字节）。
    pub fn bits(self: *const Key) usize {
        var i: usize = 0;
        while (i < self.n.len and self.n[i] == 0) i += 1;
        return (self.n.len - i) * 8;
    }
};

// ---------------------------------------------------------------------------
// DER 读取
// ---------------------------------------------------------------------------
const Tlv = struct { tag: u8, value: []const u8 };

fn readTlv(data: []const u8, pos: *usize) !Tlv {
    if (pos.* + 2 > data.len) return Error.BadDer;
    const tag = data[pos.*];
    var i = pos.* + 1;
    var len: usize = 0;
    const first = data[i];
    i += 1;
    if (first & 0x80 == 0) {
        len = first;
    } else {
        const n = first & 0x7f;
        if (n == 0 or n > 4) return Error.BadDer;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (i >= data.len) return Error.BadDer;
            len = (len << 8) | data[i];
            i += 1;
        }
    }
    if (i + len > data.len) return Error.BadDer;
    pos.* = i + len;
    return .{ .tag = tag, .value = data[i .. i + len] };
}

fn expectTag(data: []const u8, pos: *usize, tag: u8) ![]const u8 {
    const tlv = try readTlv(data, pos);
    if (tlv.tag != tag) return Error.BadDer;
    return tlv.value;
}

fn isPem(data: []const u8) bool {
    return std.mem.find(u8, data, "-----BEGIN") != null;
}

fn pemToDer(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin = std.mem.find(u8, pem, "-----BEGIN") orelse return Error.BadPem;
    const line_end = std.mem.findScalar(u8, pem[begin..], '\n') orelse return Error.BadPem;
    const body_start = begin + line_end + 1;
    const end_rel = std.mem.find(u8, pem[body_start..], "-----END") orelse return Error.BadPem;
    const body = pem[body_start .. body_start + end_rel];

    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    for (body) |c| {
        if (c == '\r' or c == '\n' or c == ' ' or c == '\t') continue;
        try cleaned.append(allocator, c);
    }
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(cleaned.items);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, cleaned.items);
    return out;
}

fn parsePkcs1Private(der: []const u8) !struct {
    version: []const u8,
    n: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
} {
    var pos: usize = 0;
    const seq = try expectTag(der, &pos, 0x30);
    var p: usize = 0;
    const version = try expectTag(seq, &p, 0x02);
    const n = try expectTag(seq, &p, 0x02);
    const e = try expectTag(seq, &p, 0x02);
    const d = try expectTag(seq, &p, 0x02);
    const pp = try expectTag(seq, &p, 0x02);
    const q = try expectTag(seq, &p, 0x02);
    const dp = try expectTag(seq, &p, 0x02);
    const dq = try expectTag(seq, &p, 0x02);
    const qinv = try expectTag(seq, &p, 0x02);
    return .{ .version = version, .n = n, .e = e, .d = d, .p = pp, .q = q, .dp = dp, .dq = dq, .qinv = qinv };
}

fn parsePkcs1Public(der: []const u8) !struct { n: []const u8, e: []const u8 } {
    var pos: usize = 0;
    const seq = try expectTag(der, &pos, 0x30);
    var p: usize = 0;
    const n = try expectTag(seq, &p, 0x02);
    const e = try expectTag(seq, &p, 0x02);
    return .{ .n = n, .e = e };
}

/// PKCS#8 PrivateKeyInfo → 内层 PKCS#1 字节切片。
fn unwrapPkcs8(der: []const u8) ![]const u8 {
    var pos: usize = 0;
    const seq = try expectTag(der, &pos, 0x30);
    var p: usize = 0;
    _ = try expectTag(seq, &p, 0x02); // version
    _ = try readTlv(seq, &p); // AlgorithmIdentifier
    const octets = try expectTag(seq, &p, 0x04);
    return octets;
}

/// SPKI SubjectPublicKeyInfo → 内层 PKCS#1 RSAPublicKey 字节切片。
fn unwrapSpki(der: []const u8) ![]const u8 {
    var pos: usize = 0;
    const seq = try expectTag(der, &pos, 0x30);
    var p: usize = 0;
    _ = try readTlv(seq, &p); // AlgorithmIdentifier
    const bits = try expectTag(seq, &p, 0x03);
    if (bits.len == 0 or bits[0] != 0) return Error.BadDer; // 未使用位数必须为 0
    return bits[1..];
}

/// 解析 PEM 或裸 DER 的 RSA 密钥（私钥优先）。
pub fn loadKey(allocator: std.mem.Allocator, data: []const u8) !Key {
    const der = if (isPem(data)) try pemToDer(allocator, data) else try allocator.dupe(u8, data);
    errdefer allocator.free(der);

    // PEM 走标签判定；裸 DER 依次尝试 PKCS#1 私钥 → PKCS#8 私钥 → SPKI/ PKCS#1 公钥。
    var pkcs1_der: []const u8 = der;
    if (isPem(data)) {
        if (std.mem.find(u8, data, "RSA PRIVATE KEY") != null) {
            pkcs1_der = der;
        } else if (std.mem.find(u8, data, "PRIVATE KEY") != null) {
            pkcs1_der = try unwrapPkcs8(der);
        } else if (std.mem.find(u8, data, "RSA PUBLIC KEY") != null) {
            pkcs1_der = der;
        } else if (std.mem.find(u8, data, "PUBLIC KEY") != null) {
            pkcs1_der = try unwrapSpki(der);
        } else {
            return Error.UnsupportedKey;
        }
    }

    // 先按私钥解析；裸 DER 时再尝试 PKCS#8 内层。
    if (parsePkcs1Private(pkcs1_der)) |k| {
        return .{ .der = der, .kind = .private, .n = k.n, .e = k.e, .d = k.d, .p = k.p, .q = k.q, .u = k.qinv };
    } else |_| {}
    if (!isPem(data)) {
        if (unwrapPkcs8(der)) |inner| {
            if (parsePkcs1Private(inner)) |k| {
                return .{ .der = der, .kind = .private, .n = k.n, .e = k.e, .d = k.d, .p = k.p, .q = k.q, .u = k.qinv };
            } else |_| {}
        } else |_| {}
    }

    if (parsePkcs1Public(pkcs1_der)) |pub_key| {
        return .{ .der = der, .kind = .public, .n = pub_key.n, .e = pub_key.e };
    } else |_| {}
    if (!isPem(data)) {
        if (unwrapSpki(der)) |inner| {
            const pub_key = try parsePkcs1Public(inner);
            return .{ .der = der, .kind = .public, .n = pub_key.n, .e = pub_key.e };
        } else |_| {}
    }
    return Error.UnsupportedKey;
}

// ---------------------------------------------------------------------------
// DER 写出
// ---------------------------------------------------------------------------
fn appendLength(list: *std.ArrayList(u8), allocator: std.mem.Allocator, len: usize) !void {
    if (len < 0x80) {
        try list.append(allocator, @intCast(len));
        return;
    }
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    var v = len;
    while (v > 0) : (v >>= 8) {
        buf[n] = @intCast(v & 0xff);
        n += 1;
    }
    try list.append(allocator, 0x80 | @as(u8, @intCast(n)));
    var i = n;
    while (i > 0) {
        i -= 1;
        try list.append(allocator, buf[i]);
    }
}

fn appendTlv(list: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: u8, body: []const u8) !void {
    try list.append(allocator, tag);
    try appendLength(list, allocator, body.len);
    try list.appendSlice(allocator, body);
}

fn appendSequence(list: *std.ArrayList(u8), allocator: std.mem.Allocator, body: []const u8) !void {
    return appendTlv(list, allocator, 0x30, body);
}

/// DER INTEGER：去前导零；为空取 0；最高位为 1 时补 0x00。
fn appendInteger(list: *std.ArrayList(u8), allocator: std.mem.Allocator, be: []const u8) !void {
    var i: usize = 0;
    while (i < be.len and be[i] == 0) i += 1;
    const body = be[i..];
    if (body.len == 0) {
        const zero = [_]u8{0};
        return appendTlv(list, allocator, 0x02, &zero);
    }
    if (body[0] & 0x80 != 0) {
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(allocator);
        try tmp.append(allocator, 0);
        try tmp.appendSlice(allocator, body);
        return appendTlv(list, allocator, 0x02, tmp.items);
    }
    return appendTlv(list, allocator, 0x02, body);
}

fn buildPrivateDer(
    allocator: std.mem.Allocator,
    n: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const zero = [_]u8{0};
    try appendTlv(&body, allocator, 0x02, &zero); // version
    try appendInteger(&body, allocator, n);
    try appendInteger(&body, allocator, e);
    try appendInteger(&body, allocator, d);
    try appendInteger(&body, allocator, p);
    try appendInteger(&body, allocator, q);
    try appendInteger(&body, allocator, dp);
    try appendInteger(&body, allocator, dq);
    try appendInteger(&body, allocator, qinv);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSequence(&out, allocator, body.items);
    return out.toOwnedSlice(allocator);
}

/// PKCS#1 `RSAPublicKey` DER：`SEQUENCE { n, e }`。
pub fn buildPublicDer(allocator: std.mem.Allocator, n: []const u8, e: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try appendInteger(&body, allocator, n);
    try appendInteger(&body, allocator, e);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSequence(&out, allocator, body.items);
    return out.toOwnedSlice(allocator);
}

/// 公钥 `SubjectPublicKeyInfo` DER（PyCryptodome `exportKey('DER')` 对公钥的输出形态）：
/// `SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { 0x00 || RSAPublicKey } }`。
pub fn buildSpkiDer(allocator: std.mem.Allocator, n: []const u8, e: []const u8) ![]u8 {
    const rsa_pub = try buildPublicDer(allocator, n, e);
    defer allocator.free(rsa_pub);

    // AlgorithmIdentifier: OID 1.2.840.113549.1.1.1 + NULL
    const alg_body = [_]u8{ 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00 };
    var alg: std.ArrayList(u8) = .empty;
    defer alg.deinit(allocator);
    try appendSequence(&alg, allocator, &alg_body);

    var bits: std.ArrayList(u8) = .empty;
    defer bits.deinit(allocator);
    try bits.append(allocator, 0); // 未使用位数
    try bits.appendSlice(allocator, rsa_pub);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, alg.items);
    try appendTlv(&body, allocator, 0x03, bits.items);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSequence(&out, allocator, body.items);
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// 整数变换
// ---------------------------------------------------------------------------
/// keysize 分档（与参考脚本一致）。
pub fn keySizeForBits(bits: usize) !usize {
    if (bits > 3072) return 512;
    if (bits > 2048) return 384;
    if (bits > 1024) return 256;
    if (bits > 512) return 128;
    if (bits > 500) return 64;
    return Error.UnsupportedKeySize;
}

/// 大端值 → 定长小端（去掉 DER 前导零后反转，左侧补零）。
pub fn toLittleEndianPadded(allocator: std.mem.Allocator, be: []const u8, size: usize) ![]u8 {
    var i: usize = 0;
    while (i < be.len and be[i] == 0) i += 1;
    const trimmed = be[i..];
    if (trimmed.len > size) return Error.UnsupportedKeySize;
    const out = try allocator.alloc(u8, size);
    @memset(out, 0);
    for (trimmed, 0..) |_, k| out[k] = trimmed[trimmed.len - 1 - k];
    return out;
}

fn bigEndianFromLittle(le: []const u8) []const u8 {
    // 找到最高的非零字节（小端尾部），返回其大端切片。
    var end = le.len;
    while (end > 0 and le[end - 1] == 0) end -= 1;
    if (end == 0) return le[0..0];
    return le[0..end]; // 小端切片本身；由 reverseInto 处理
}

const BigEndianOwned = struct {
    buf: []u8,
    pub fn slice(self: BigEndianOwned) []const u8 {
        return self.buf;
    }
};

/// 小端字节 → 大端最小表示（调用者释放；全零返回长度 0）。
fn reverseToBigEndian(allocator: std.mem.Allocator, le: []const u8) !BigEndianOwned {
    const trimmed = bigEndianFromLittle(le);
    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |b, i| out[trimmed.len - 1 - i] = b;
    return .{ .buf = out };
}

fn aesEcbEncryptInPlace(key: [16]u8, data: []u8) void {
    var ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        var block: [16]u8 = undefined;
        @memcpy(&block, data[i..][0..16]);
        ctx.encrypt(data[i..][0..16], &block);
    }
}

fn desEcbEncryptInPlace(key: [8]u8, data: []u8) void {
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        var block: [8]u8 = undefined;
        @memcpy(&block, data[i..][0..8]);
        des.encryptBlock(key, &block);
        @memcpy(data[i..][0..8], &block);
    }
}

pub const SymKey = union(enum) {
    aes: [16]u8,
    des: [8]u8,

    pub fn fromBytes(bytes: []const u8) !SymKey {
        if (bytes.len == 16) {
            var k: [16]u8 = undefined;
            @memcpy(&k, bytes);
            return .{ .aes = k };
        }
        if (bytes.len == 8) {
            var k: [8]u8 = undefined;
            @memcpy(&k, bytes);
            return .{ .des = k };
        }
        return Error.BadSymKeySize;
    }

    fn encryptInPlace(self: SymKey, data: []u8) void {
        switch (self) {
            .aes => |k| aesEcbEncryptInPlace(k, data),
            .des => |k| desEcbEncryptInPlace(k, data),
        }
    }

    pub fn blockSize(self: SymKey) usize {
        return switch (self) {
            .aes => 16,
            .des => 8,
        };
    }
};

pub const Encrypted = struct {
    /// 私钥：`<base>_encrypted.der`；公钥：`<base>_encrypted.der`（PKCS#1 公钥结构）。
    main_der: []u8,
    /// 公钥模式额外输出 `<base>_encrypted_pkcs1.der`（与 main 内容一致，保留参考命名）。
    extra_pkcs1_der: ?[]u8 = null,
    pub fn deinit(self: *Encrypted, allocator: std.mem.Allocator) void {
        allocator.free(self.main_der);
        if (self.extra_pkcs1_der) |x| allocator.free(x);
        self.* = undefined;
    }
};

fn encryptComponent(
    allocator: std.mem.Allocator,
    be: []const u8,
    size: usize,
    sym: SymKey,
) !BigEndianOwned {
    const le = try toLittleEndianPadded(allocator, be, size);
    defer allocator.free(le);
    sym.encryptInPlace(le);
    return reverseToBigEndian(allocator, le);
}

fn modMinusOne(
    allocator: std.mem.Allocator,
    value_be: []const u8,
    modulus_be: []const u8,
) !BigEndianOwned {
    // 去掉符号前导零
    var vi: usize = 0;
    while (vi + 1 < value_be.len and value_be[vi] == 0) vi += 1;
    var mi: usize = 0;
    while (mi + 1 < modulus_be.len and modulus_be[mi] == 0) mi += 1;

    var v = try managedFromBigEndian(allocator, value_be[vi..]);
    defer v.deinit();
    var m = try managedFromBigEndian(allocator, modulus_be[mi..]);
    defer m.deinit();
    var one = try Managed.initSet(allocator, 1);
    defer one.deinit();
    var m1 = try Managed.init(allocator);
    defer m1.deinit();
    try m1.sub(&m, &one); // m1 = p - 1
    if (@as(usize, @intCast(m1.bitCountAbs())) == 0) return Error.BadDer;

    var q = try Managed.init(allocator);
    defer q.deinit();
    var r = try Managed.init(allocator);
    defer r.deinit();
    try q.divFloor(&r, &v, &m1);

    const limbs = r.limbs;
    const byte_len = limbs.len * @sizeOf(std.math.big.Limb);
    const tmp = try allocator.alloc(u8, byte_len);
    defer allocator.free(tmp);
    @memset(tmp, 0);
    r.toConst().writeTwosComplement(tmp, .big);
    return reverseTrim(allocator, tmp);
}

fn reverseTrim(allocator: std.mem.Allocator, be: []const u8) !BigEndianOwned {
    var i: usize = 0;
    while (i < be.len and be[i] == 0) i += 1;
    const body = be[i..];
    const out = try allocator.alloc(u8, body.len);
    @memcpy(out, body);
    return .{ .buf = out };
}

/// m 的模逆（扩展欧几里得，全程保持在 [0,m) 内，避免负数分支）。
/// 对应 PyCryptodome 的 `Integer(q).inverse(p)`（导出 PKCS#1 系数时使用）。
fn modInverse(
    allocator: std.mem.Allocator,
    a_be: []const u8,
    m_be: []const u8,
) !BigEndianOwned {
    var a = try managedFromBigEndian(allocator, a_be);
    defer a.deinit();
    var m = try managedFromBigEndian(allocator, m_be);
    defer m.deinit();
    if (m.eqlZero() or a.eqlZero()) return Error.BadDer;

    // a = a mod m
    var q = try Managed.init(allocator);
    defer q.deinit();
    var rem = try Managed.init(allocator);
    defer rem.deinit();
    try q.divFloor(&rem, &a, &m);
    try a.copy(rem.toConst());

    // t0=0, t1=1；r0=m, r1=a
    var t0 = try Managed.initSet(allocator, 0);
    defer t0.deinit();
    var t1 = try Managed.initSet(allocator, 1);
    defer t1.deinit();
    var r0 = try Managed.init(allocator);
    defer r0.deinit();
    try r0.copy(m.toConst());
    var r1 = try Managed.init(allocator);
    defer r1.deinit();
    try r1.copy(a.toConst());

    var qq = try Managed.init(allocator);
    defer qq.deinit();
    var rr = try Managed.init(allocator);
    defer rr.deinit();
    var prod = try Managed.init(allocator);
    defer prod.deinit();
    var t2 = try Managed.init(allocator);
    defer t2.deinit();
    var diff = try Managed.init(allocator);
    defer diff.deinit();
    var mm = try Managed.init(allocator);
    defer mm.deinit();

    while (!r1.eqlZero()) {
        try qq.divFloor(&rr, &r0, &r1); // qq = r0/r1, rr = r0%r1
        // t2 = (t0 - qq*t1) mod m
        try prod.mul(&qq, &t1);
        try qq.divFloor(&mm, &prod, &m); // mm = (qq*t1) mod m
        // t0 + (m - mm) 后再取模，保证非负
        try diff.sub(&m, &mm); // m - mm  ∈ [0,m]
        try t2.add(&t0, &diff); // t0 + (m-mm) ∈ [0,2m)
        try qq.divFloor(&mm, &t2, &m);
        try t2.copy(mm.toConst());

        try t0.copy(t1.toConst());
        try t1.copy(t2.toConst());
        try r0.copy(r1.toConst());
        try r1.copy(rr.toConst());
    }

    // r0 必须为 1 才存在模逆
    var one = try Managed.initSet(allocator, 1);
    defer one.deinit();
    if (r0.order(one) != .eq) return Error.BadDer;

    const byte_len = t0.limbs.len * @sizeOf(std.math.big.Limb);
    const tmp = try allocator.alloc(u8, byte_len);
    defer allocator.free(tmp);
    @memset(tmp, 0);
    t0.toConst().writeTwosComplement(tmp, .big);
    return reverseTrim(allocator, tmp);
}

fn managedFromBigEndian(allocator: std.mem.Allocator, bytes: []const u8) !Managed {
    if (bytes.len == 0) return Managed.initSet(allocator, 0);
    const hex = try allocator.alloc(u8, bytes.len * 2);
    defer allocator.free(hex);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = digits[b >> 4];
        hex[i * 2 + 1] = digits[b & 0x0f];
    }
    var m = try Managed.init(allocator);
    errdefer m.deinit();
    try m.setString(16, hex);
    return m;
}

/// 按参考脚本口径加密整把密钥（n 密文后追加 0x01）。
pub fn encryptKey(allocator: std.mem.Allocator, key: *const Key, sym: SymKey) !Encrypted {
    const size = try keySizeForBits(key.bits());

    const n_owned = try encryptComponent(allocator, key.n, size, sym);
    defer allocator.free(n_owned.buf);
    // n 的密文末尾追加 0x01，再当作大端数（即前置 0x01）。
    const n2 = try allocator.alloc(u8, n_owned.buf.len + 1);
    defer allocator.free(n2);
    n2[0] = 0x01;
    @memcpy(n2[1..], n_owned.buf);

    const e_owned = try encryptComponent(allocator, key.e, size, sym);
    defer allocator.free(e_owned.buf);

    if (key.kind == .public) {
        // 参考脚本对公钥走 `exportKey('DER')`，即 SubjectPublicKeyInfo；
        // 同时另写一份 PKCS#1 公钥（`_encrypted_pkcs1.der`）。
        const spki = try buildSpkiDer(allocator, n2, e_owned.buf);
        errdefer allocator.free(spki);
        const pkcs1 = try buildPublicDer(allocator, n2, e_owned.buf);
        return .{ .main_der = spki, .extra_pkcs1_der = pkcs1 };
    }

    const d_owned = try encryptComponent(allocator, key.d.?, size, sym);
    defer allocator.free(d_owned.buf);
    const p_owned = try encryptComponent(allocator, key.p.?, size, sym);
    defer allocator.free(p_owned.buf);
    const q_owned = try encryptComponent(allocator, key.q.?, size, sym);
    defer allocator.free(q_owned.buf);

    const dp = try modMinusOne(allocator, d_owned.buf, p_owned.buf);
    defer allocator.free(dp.buf);
    const dq = try modMinusOne(allocator, d_owned.buf, q_owned.buf);
    defer allocator.free(dq.buf);

    // 参考脚本的最后一个字段是 `Integer(q).inverse(p)`，按**加密后**的 p/q 现算，
    // 与原密钥的 qInv 无关（原 qInv 不透传）。
    const qinv = try modInverse(allocator, q_owned.buf, p_owned.buf);
    defer allocator.free(qinv.buf);

    const out = try buildPrivateDer(
        allocator,
        n2,
        e_owned.buf,
        d_owned.buf,
        p_owned.buf,
        q_owned.buf,
        dp.buf,
        dq.buf,
        qinv.buf,
    );
    return .{ .main_der = out };
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------
test "rsa_key：小端定长补零与回转" {
    const a = std.testing.allocator;
    const be = [_]u8{ 0x00, 0x01, 0x02 };
    const le = try toLittleEndianPadded(a, &be, 4);
    defer a.free(le);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x01, 0x00, 0x00 }, le);
}

test "rsa_key：keysize 分档与参考脚本一致" {
    try std.testing.expectEqual(@as(usize, 256), try keySizeForBits(2048));
    try std.testing.expectEqual(@as(usize, 384), try keySizeForBits(3072));
    try std.testing.expectEqual(@as(usize, 128), try keySizeForBits(1024));
    try std.testing.expectEqual(@as(usize, 64), try keySizeForBits(512));
    try std.testing.expectError(Error.UnsupportedKeySize, keySizeForBits(256));
}

test "rsa_key：PKCS#1 公钥 DER 结构" {
    const a = std.testing.allocator;
    const n = [_]u8{ 0x80, 0x01 }; // 最高位为 1 → 需补 0x00
    const e = [_]u8{ 0x01, 0x00, 0x01 };
    const der = try buildPublicDer(a, &n, &e);
    defer a.free(der);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x30, 0x0a,
        0x02, 0x03,
        0x00, 0x80,
        0x01, 0x02,
        0x03, 0x01,
        0x00, 0x01,
    }, der);
}

test "rsa_key：私钥 DER 可被自身解析器读回" {
    const a = std.testing.allocator;
    const n = [_]u8{0x0b};
    const e = [_]u8{0x01};
    const d = [_]u8{0x11};
    const p = [_]u8{0x03};
    const q = [_]u8{0x05};
    const dp = [_]u8{0x01};
    const dq = [_]u8{0x01};
    const qinv = [_]u8{0x02};
    const der = try buildPrivateDer(a, &n, &e, &d, &p, &q, &dp, &dq, &qinv);
    defer a.free(der);
    var key = try loadKey(a, der);
    defer key.deinit(a);
    try std.testing.expectEqual(Kind.private, key.kind);
    try std.testing.expectEqualSlices(u8, &n, key.n);
    try std.testing.expectEqualSlices(u8, &qinv, key.u.?);
    try std.testing.expectEqual(@as(usize, 8), key.bits());
}

test "rsa_key：n 密文追加 0x01 后仍可作为 DER 整数编码" {
    const a = std.testing.allocator;
    // 64 字节 n（512 位）→ keysize=64；n 密文追加 0x01 后首字节为 0x01。
    var n_be: [64]u8 = @splat(0);
    n_be[0] = 0x80; // 最高位置 1，确保位长为 512
    var key = Key{
        .der = try a.dupe(u8, ""),
        .kind = .public,
        .n = &n_be,
        .e = &[_]u8{0x03},
    };
    defer key.deinit(a);
    const zero16: [16]u8 = @splat(0);
    const enc = try encryptKey(a, &key, .{ .aes = zero16 });
    defer {
        var m = enc;
        m.deinit(a);
    }
    try std.testing.expectEqual(@as(u8, 0x30), enc.main_der[0]);
    // SPKI 内的 BIT STRING 含 PKCS#1 `SEQUENCE { INTEGER(n2=65B), INTEGER(e) }`
    const pat = [_]u8{ 0x02, 0x41, 0x01 };
    try std.testing.expect(std.mem.indexOf(u8, enc.main_der, &pat) != null);
    const pkcs1 = enc.extra_pkcs1_der orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x30, 0x81, 0x85, 0x02, 0x41, 0x01 }, pkcs1[0..6]);
}
