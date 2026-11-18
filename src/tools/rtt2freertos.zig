//! RT-Thread defconfig → FreeRTOS defconfig —— 对应参考工程
//! `tools/scripts/rtt2freertos.py`。
//!
//! 只改 Kconfig 符号，不动驱动/板级源码：把一块板子的 rt-thread 方案
//! 过滤成「bare 驱动 + 组件包」可用的 FreeRTOS 方案。
//!
//! 规则来源（逐条照搬参考脚本的语义，顺序不可调换）：
//!   1. `_rewrite`：默认 y 的符号保留其 `is not set`、改 `PRJ_KERNEL` /
//!      `PRJ_DEFCONFIG_FILENAME`、把 `RT_CONSOLE_DEVICE_NAME` 折成
//!      `AIC_BAREMETAL_CONSOLE_UART`、DFS 内核符号映射到组件符号、
//!      丢弃没有对应裸机 flash 设备的 `AIC_USING_QSPI<N>`；
//!   2. `_filter`：先黑名单（AIC 框架驱动 / 仅 RT 的组件包 / bsp/peripheral /
//!      图形栈），再白名单（`KEEP_EXACT` / `KEEP_PREFIX` / 非驱动的 `AIC_` 选项）；
//!   3. 末尾补 `FORCE_OFF` 显式关闭、bare console 三件套、bare 存储链。
//!
//! 与参考脚本的差异：参考脚本用 Python text 模式写回，在 Windows 上输出恒为
//! CRLF；我们统一写 LF（对拍时忽略 `\r`）。`--verify`（依赖 kconfiglib 的
//! 符号可见性校验）未移植。
const std = @import("std");

pub const Error = error{
    NoProjectHeader,
    NotRtThread,
};

// ---------------------------------------------------------------------------
// 规则表（与参考脚本逐项一致，顺序也一致）
// ---------------------------------------------------------------------------
const AIC_FRAMEWORK_SWITCHES = [_][]const u8{
    "AIC_USING_TOUCH",
    "AIC_USING_TSEN",
    "AIC_USING_MTOP",
    "AIC_USING_CE",
    "AIC_USING_SID",
    "AIC_USING_GPAI",
    "AIC_USING_RTP",
    "AIC_USING_HRTIMER0",
    "AIC_ADCIM_DRV",
    "AIC_STARTUP_UI_SHOW",
    "AIC_MPP",
    "LPKG_USING_BONNIE",
    "LPKG_USING_CPU_USAGE",
};

const PACKAGE_RT_ONLY_SWITCHES = [_][]const u8{
    "RT_USING_DFS_MNTTABLE",
    "LPKG_USING_CHERRYUSB",
    "LPKG_CHERRYUSB",
    "AIC_USING_USB0_HOST",
    "AIC_USING_USB1_HOST",
    "LPKG_USING_CPU_LOAD",
    "LPKG_USING_MHZ",
    "LPKG_USING_I2C_TOOLS",
    "LPKG_USING_PINMUX_CHECHK",
    "AIC_ENV_INTERFACE",
    "LPKG_USING_OTA_DOWNLOADER",
    "LPKG_USING_HTTP_OTA_DOWNLOADER",
    "LPKG_USING_AIC_AUTHORIZATION",
    "LPKG_USING_AIC_SPIENC_AUTHORIZATION",
    "LPKG_USING_USERID",
    "LPKG_USING_CJSON",
    "LPKG_MPP",
    "LPKG_USING_MINIMP3",
    "LPKG_USING_LWIP",
    "LPKG_LWIP",
    "LPKG_USING_NETUTILS",
    "LPKG_USING_NETTOOLS",
    "LPKG_NETUTILS",
    "LPKG_USING_COMP_HID_TABLE1",
    "LPKG_USING_COMP_UAC_TABLE1",
};

const PERIPHERAL_RT_ONLY_SWITCHES = [_][]const u8{
    "AIC_USING_CAMERA",
    "AIC_I2S_CODEC",
    "AIC_BT",
    "AIC_WLAN",
    "WIFI_USING_SDIOWIFI_ATBM",
    "AIC_WIRELESS",
    "AIC_RTC_PCF8563",
    "AIC_RTC_RX8010",
    "AIC_ENCODER_HEC40",
    "AIC_GYRO_SC7A20H",
    "AIC_QSPI_LCD_INTERFACE",
    "AIC_USING_CTP",
};

const GRAPHICS_SWITCHES = [_][]const u8{
    "AIC_LVGL",
    "LPKG_USING_LVGL",
    "LPKG_LVGL",
    "LVGL_V",
    "LV",
};

const DfsMapEntry = struct {
    kernel: []const u8,
    component: []const []const u8,
};

const DFS_MAP = [_]DfsMapEntry{
    .{ .kernel = "RT_USING_DFS_ELMFAT", .component = &.{ "CONFIG_LPKG_USING_DFS", "CONFIG_LPKG_USING_DFS_ELMFAT" } },
    .{ .kernel = "RT_USING_DFS_ROMFS", .component = &.{ "CONFIG_LPKG_USING_DFS", "CONFIG_LPKG_USING_DFS_ROMFS" } },
    .{ .kernel = "RT_USING_DFS_UFFS", .component = &.{ "CONFIG_LPKG_USING_DFS", "CONFIG_LPKG_USING_DFS_UFFS" } },
    .{ .kernel = "RT_USING_DFS_LITTLEFS", .component = &.{ "CONFIG_LPKG_USING_DFS", "CONFIG_LPKG_USING_DFS_LITTLEFS" } },
    .{ .kernel = "RT_DFS_ELM_USE_LFN_0", .component = &.{"CONFIG_LPKG_DFS_ELM_USE_LFN_0"} },
    .{ .kernel = "RT_DFS_ELM_USE_LFN_1", .component = &.{"CONFIG_LPKG_DFS_ELM_USE_LFN_1"} },
    .{ .kernel = "RT_DFS_ELM_USE_LFN_2", .component = &.{"CONFIG_LPKG_DFS_ELM_USE_LFN_2"} },
    .{ .kernel = "RT_DFS_ELM_USE_LFN_3", .component = &.{"CONFIG_LPKG_DFS_ELM_USE_LFN_3"} },
    .{ .kernel = "RT_DFS_ELM_LFN_UNICODE_0", .component = &.{"CONFIG_LPKG_DFS_ELM_LFN_UNICODE_0"} },
    .{ .kernel = "RT_DFS_ELM_LFN_UNICODE_1", .component = &.{"CONFIG_LPKG_DFS_ELM_LFN_UNICODE_1"} },
    .{ .kernel = "RT_DFS_ELM_LFN_UNICODE_2", .component = &.{"CONFIG_LPKG_DFS_ELM_LFN_UNICODE_2"} },
    .{ .kernel = "RT_DFS_ELM_LFN_UNICODE_3", .component = &.{"CONFIG_LPKG_DFS_ELM_LFN_UNICODE_3"} },
};

const BARE_CONSOLE_BASE = [_][]const u8{
    "CONFIG_AIC_CONSOLE_BARE_DRV=y",
    "CONFIG_AIC_PRINTF_BARE_DRV=y",
};

const BARE_STORAGE_MTD = "CONFIG_AIC_MTD_BARE_DRV=y";
const BARE_STORAGE_NAND = [_][]const u8{
    "CONFIG_AIC_NFTL_SUPPORT=y",
    "CONFIG_AIC_NFLT_USED_LIB=y",
};
const BARE_STORAGE_NOR = [_][]const u8{
    "CONFIG_LPKG_USING_SFUD=y",
};

const DEFAULT_Y_SWITCHES = [_][]const u8{
    "AIC_AUDIO_DMIC",
    "AIC_BARCODE_BEEP",
    "AIC_DISP_BOOTUP_LOGO",
    "AIC_I2S_CODEC_TLV320",
    "AIC_USING_DE",
    "AIC_USING_GE",
    "AIC_USING_SDMC1",
    "AIC_USING_THREAD_STACK_TRACE",
    "AIC_USING_VE",
    "LPKG_MPP",
    "LPKG_USING_ENV",
    "LPKG_USING_FDTLIB",
    "LPKG_USING_MINIMP3",
    "LPKG_USING_NETTOOLS",
    "RGB_DATA_MIRROT",
    "USBDEV_MSC_THREAD",
    "USBD_MSC_STORAGE_USING_HOTPLUG",
};

const FORCE_OFF = [_][]const u8{
    "LPKG_MPP",
    "LPKG_USING_MINIMP3",
    "LPKG_USING_NETTOOLS",
};

const KEEP_EXACT = [_][]const u8{
    "AIC_CONSOLE_BARE_DRV",
    "AIC_PRINTF_BARE_DRV",
    "AIC_BAREMETAL_CONSOLE_UART",
    "AIC_CONSOLE_SYSNAME",
    "AIC_MTD_BARE_DRV",
    "AIC_NFTL_SUPPORT",
    "AIC_NFLT_USED_LIB",
    "LPKG_USING_SFUD",
    "LPKG_USING_DFS",
    "LPKG_USING_DFS_ELMFAT",
    "LPKG_USING_DFS_ROMFS",
    "LPKG_USING_DFS_UFFS",
    "LPKG_USING_DFS_LITTLEFS",
    "DFS_FILESYSTEMS_MAX",
    "AIC_USING_DMA",
    "AIC_USING_RTC",
    "AIC_USING_WDT",
    "AIC_USING_WRI",
    "AIC_INTERRUPTSTACK_SIZE",
};

const KEEP_PREFIX = [_][]const u8{
    "PRJ_",
    "KERNEL_",
    "DRIVER_",
    "AIC_DRAM_",
    "AIC_PSRAM_",
    "AIC_USING_UART",
    "AIC_USING_QSPI",
    "AIC_QSPI0_DEVICE",
    "AIC_QSPI1_DEVICE",
    "AIC_QSPI2_DEVICE",
    "AIC_QSPI3_DEVICE",
    "AIC_QSPI4_DEVICE",
    "AIC_USING_SDMC",
    "RT_DFS_ELM",
    "AIC_USING_FS_IMAGE",
    "AIC_FS_IMAGE",
};

const REPORTED_PREFIXES = [_][]const u8{
    "AIC_USING_", "AIC_I2S_",  "AIC_WLAN",   "AIC_BT",  "AIC_RTC_", "AIC_ENCODER",
    "AIC_GYRO",   "AIC_GMAC",  "LPKG_",      "PKG_",    "AIC_LVGL",
};

const AIC_DRIVER_PATTERNS = [_][]const u8{
    "AIC_USING_", "AIC_I2S",    "AIC_I2C",  "AIC_SPI",   "AIC_CAN",    "AIC_AUDIO",
    "AIC_CODEC",  "AIC_CAMERA", "AIC_TOUCH", "AIC_CTP",  "AIC_TSEN",   "AIC_GPAI",
    "AIC_CE",     "AIC_SID",    "AIC_MTOP", "AIC_RTP",   "AIC_HRTIMER", "AIC_ADCIM",
    "AIC_VE",     "AIC_GE",     "AIC_DVP",  "AIC_DE",    "AIC_GMAC",   "AIC_WLAN",
    "AIC_BT",     "AIC_ENCODER", "AIC_GYRO", "AIC_USB",  "AIC_MMC",    "AIC_PWM",
    "AIC_KEYADC", "AIC_PSADC",  "AIC_DISP", "AIC_PAN",   "AIC_RING_BUFFER",
};

fn startsWithAny(s: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (std.mem.startsWith(u8, s, p)) return true;
    }
    return false;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

fn bareName(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "CONFIG_")) name["CONFIG_".len..] else name;
}

/// 黑名单：AIC 框架驱动 + 仅 RT 的组件包 + bsp/peripheral 驱动 + 图形栈。
pub fn isBlacklisted(name: []const u8) bool {
    const bare = bareName(name);
    const lists = .{ AIC_FRAMEWORK_SWITCHES, PACKAGE_RT_ONLY_SWITCHES, PERIPHERAL_RT_ONLY_SWITCHES, GRAPHICS_SWITCHES };
    inline for (lists) |list| {
        for (list) |sw| {
            if (std.mem.eql(u8, bare, sw)) return true;
            if (std.mem.startsWith(u8, bare, sw) and bare.len > sw.len and bare[sw.len] == '_') return true;
        }
    }
    return false;
}

/// 白名单：黑名单优先，其次精确表 / 前缀表 / 非驱动的 AIC_ 选项。
pub fn isKept(name: []const u8) bool {
    const bare = bareName(name);
    if (isBlacklisted(name)) return false;
    if (contains(&KEEP_EXACT, bare)) return true;
    if (startsWithAny(bare, &KEEP_PREFIX)) return true;
    if (std.mem.startsWith(u8, bare, "AIC_") and
        std.mem.find(u8, bare, "_TEST") == null and
        !startsWithAny(bare, &AIC_DRIVER_PATTERNS))
    {
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// defconfig 解析
// ---------------------------------------------------------------------------
const Entry = struct {
    name: ?[]const u8,
    line: []const u8,
    /// `# CONFIG_X is not set`
    not_set: bool = false,
    /// `CONFIG_X=...` 的 `=` 之后部分
    value: []const u8 = "",
};

fn isValidSymbolChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn parseLine(line: []const u8) Entry {
    if (std.mem.startsWith(u8, line, "CONFIG_")) {
        if (std.mem.findScalar(u8, line, '=')) |eq| {
            const name = line[0..eq];
            var ok = name.len > "CONFIG_".len;
            if (ok) {
                for (name["CONFIG_".len..]) |c| {
                    if (!isValidSymbolChar(c)) {
                        ok = false;
                        break;
                    }
                }
            }
            if (ok) return .{ .name = name, .line = line, .value = line[eq + 1 ..] };
        }
    }
    const suffix = " is not set";
    if (std.mem.startsWith(u8, line, "# ") and std.mem.endsWith(u8, line, suffix)) {
        const name = line[2 .. line.len - suffix.len];
        if (name.len > "CONFIG_".len and std.mem.startsWith(u8, name, "CONFIG_")) {
            var ok = true;
            for (name["CONFIG_".len..]) |c| {
                if (!isValidSymbolChar(c)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return .{ .name = name, .line = line, .not_set = true };
        }
    }
    return .{ .name = null, .line = line };
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        // 输入可能是 CRLF：Python text 模式会把 \r\n 归一成 \n，这里同样剥掉 \r。
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try list.append(allocator, line);
    }
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) _ = list.pop();
    return list;
}

fn getValue(entries: []const Entry, name: []const u8) ?[]const u8 {
    for (entries) |e| {
        const n = e.name orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        if (e.not_set) return null;
        return std.mem.trim(u8, std.mem.trim(u8, e.value, " \t\r\n"), "\"");
    }
    return null;
}

fn readConsoleUart(entries: []const Entry) u32 {
    const prefix = "CONFIG_RT_CONSOLE_DEVICE_NAME=\"uart";
    for (entries) |e| {
        const n = e.name orelse continue;
        if (!std.mem.eql(u8, n, "CONFIG_RT_CONSOLE_DEVICE_NAME")) continue;
        if (!std.mem.startsWith(u8, e.line, prefix)) continue;
        const rest = e.line[prefix.len..];
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits == 0) continue;
        return std.fmt.parseInt(u32, rest[0..digits], 10) catch 0;
    }
    return 0;
}

/// `AIC_USING_QSPI<N>` 实际挂了裸机 flash 设备的总线集合（只看符号名）。
fn readQspiBuses(entries: []const Entry) !u5 {
    var mask: u5 = 0;
    const prefix = "CONFIG_AIC_QSPI";
    for (entries) |e| {
        const n = e.name orelse continue;
        if (!std.mem.startsWith(u8, n, prefix) or n.len <= prefix.len + 1) continue;
        const digit = n[prefix.len];
        if (!std.ascii.isDigit(digit)) continue;
        const rest = n[prefix.len + 1 ..];
        if (std.mem.eql(u8, rest, "_DEVICE_SPINOR") or std.mem.eql(u8, rest, "_DEVICE_SPINAND")) {
            const idx: u3 = @intCast(digit - '0');
            if (idx < 5) mask |= (@as(u5, 1) << idx);
        }
    }
    return mask;
}

fn readStorage(entries: []const Entry) !struct { spinand: bool, spinor: bool, dfs: bool } {
    var spinand = false;
    var spinor = false;
    var bus: u32 = 0;
    while (bus < 5) : (bus += 1) {
        const nand_name = try std.fmt.allocPrint(std.heap.page_allocator, "CONFIG_AIC_QSPI{d}_DEVICE_SPINAND", .{bus});
        defer std.heap.page_allocator.free(nand_name);
        const nor_name = try std.fmt.allocPrint(std.heap.page_allocator, "CONFIG_AIC_QSPI{d}_DEVICE_SPINOR", .{bus});
        defer std.heap.page_allocator.free(nor_name);
        if (getValue(entries, nand_name)) |v| {
            if (std.mem.eql(u8, v, "y")) spinand = true;
        }
        if (getValue(entries, nor_name)) |v| {
            if (std.mem.eql(u8, v, "y")) spinor = true;
        }
    }
    var dfs = false;
    for (entries) |e| {
        const n = e.name orelse continue;
        if (std.mem.startsWith(u8, n, "CONFIG_RT_USING_DFS") or std.mem.startsWith(u8, n, "CONFIG_LPKG_USING_DFS")) {
            dfs = true;
            break;
        }
    }
    return .{ .spinand = spinand, .spinor = spinor, .dfs = dfs };
}

// ---------------------------------------------------------------------------
// 转换
// ---------------------------------------------------------------------------
pub const Options = struct {
    /// 不给则从 `RT_CONSOLE_DEVICE_NAME` 推导。
    console_uart: ?u32 = null,
    sysname: []const u8 = "aic",
};

pub const Report = struct {
    kept_off: []const []const u8 = &.{},
    dropped: []const []const u8 = &.{},
    mapped: []const []const u8 = &.{},
    added: []const []const u8 = &.{},
    silent: usize = 0,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    /// 目标 defconfig 内容（LF，末尾带 \n）
    text: []const u8,
    plan_name: []const u8,
    report: Report,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Converter = struct {
    allocator: std.mem.Allocator, // arena
    out_text: std.mem.Allocator,
    entries: []const Entry,
    sysname: []const u8,
    console_uart: u32,
    qspi_buses: u5,
    lines: std.ArrayList([]const u8) = .empty,
    seen: std.StringHashMap(void),
    kept_off: std.ArrayList([]const u8) = .empty,
    dropped: std.ArrayList([]const u8) = .empty,
    mapped: std.ArrayList([]const u8) = .empty,
    added: std.ArrayList([]const u8) = .empty,
    silent: usize = 0,

    fn write(self: *Converter, line: []const u8) !bool {
        const entry = parseLine(line);
        if (entry.name) |name| {
            if (self.seen.contains(name)) return false;
            try self.seen.put(try self.allocator.dupe(u8, name), {});
        }
        try self.lines.append(self.out_text, try self.allocator.dupe(u8, line));
        return true;
    }

    fn dropOrphanQspi(self: *Converter, bare: []const u8, name: []const u8) !bool {
        const prefix = "AIC_USING_QSPI";
        if (!std.mem.startsWith(u8, bare, prefix) or bare.len != prefix.len + 1) return false;
        const digit = bare[prefix.len];
        if (!std.ascii.isDigit(digit)) return false;
        if (self.qspi_buses == 0) return false; // 没有任何总线配置时不做裁剪
        const idx_num: u8 = digit - '0';
        const carried = if (idx_num < 5)
            (self.qspi_buses & (@as(u5, 1) << @as(u3, @intCast(idx_num)))) != 0
        else
            false;
        if (carried) return false;
        try self.dropped.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} (no AIC_QSPI{c}_DEVICE_* configured)", .{ name, digit }));
        return true;
    }

    fn rewrite(self: *Converter, entry: Entry, new_name: []const u8) !bool {
        const name = entry.name.?;
        const bare = bareName(name);

        if (entry.not_set and contains(&DEFAULT_Y_SWITCHES, bare)) {
            if (try self.write(entry.line)) {
                try self.kept_off.append(self.allocator, try self.allocator.dupe(u8, name));
            }
            return true;
        }

        if (std.mem.eql(u8, name, "CONFIG_PRJ_KERNEL")) {
            _ = try self.write("CONFIG_PRJ_KERNEL=\"freertos\"");
            try self.mapped.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} -> \"freertos\"", .{name}));
            return true;
        }
        if (std.mem.eql(u8, name, "CONFIG_PRJ_DEFCONFIG_FILENAME")) {
            const line = try std.fmt.allocPrint(self.allocator, "CONFIG_PRJ_DEFCONFIG_FILENAME=\"{s}_defconfig\"", .{new_name});
            _ = try self.write(line);
            try self.mapped.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} -> {s}_defconfig", .{ name, new_name }));
            return true;
        }
        if (std.mem.eql(u8, name, "CONFIG_RT_CONSOLE_DEVICE_NAME")) {
            try self.mapped.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "RT_CONSOLE_DEVICE_NAME -> AIC_BAREMETAL_CONSOLE_UART={d}",
                .{self.console_uart},
            ));
            return true;
        }

        for (DFS_MAP) |m| {
            if (!std.mem.eql(u8, bare, m.kernel)) continue;
            for (m.component) |sym| {
                const line = try std.fmt.allocPrint(self.allocator, "{s}=y", .{sym});
                if (try self.write(line)) {
                    try self.mapped.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} -> {s}", .{ name, sym }));
                }
            }
            return true;
        }

        return self.dropOrphanQspi(bare, name);
    }

    fn filter(self: *Converter, entry: Entry) !void {
        const name = entry.name.?;
        if (isKept(name)) {
            _ = try self.write(entry.line);
            return;
        }
        const bare = bareName(name);
        if (startsWithAny(bare, &REPORTED_PREFIXES)) {
            try self.dropped.append(self.allocator, try self.allocator.dupe(u8, name));
        } else {
            self.silent += 1;
        }
    }

    fn run(self: *Converter, new_name: []const u8) !void {
        for (self.entries) |entry| {
            if (entry.name == null) {
                try self.lines.append(self.out_text, try self.allocator.dupe(u8, entry.line));
                continue;
            }
            if (try self.rewrite(entry, new_name)) continue;
            try self.filter(entry);
        }
        try self.appendForcedOff();
        try self.appendConsole();
        try self.appendStorage();
    }

    fn appendForcedOff(self: *Converter) !void {
        for (FORCE_OFF) |bare| {
            const line = try std.fmt.allocPrint(self.allocator, "# CONFIG_{s} is not set", .{bare});
            if (try self.write(line)) {
                try self.added.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} (Kconfig default is y)", .{line}));
            }
        }
    }

    fn appendConsole(self: *Converter) !void {
        for (BARE_CONSOLE_BASE) |line| {
            if (try self.write(line)) try self.added.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        {
            const line = try std.fmt.allocPrint(self.allocator, "CONFIG_AIC_BAREMETAL_CONSOLE_UART={d}", .{self.console_uart});
            if (try self.write(line)) try self.added.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        if (self.sysname.len > 0) {
            const line = try std.fmt.allocPrint(self.allocator, "CONFIG_AIC_CONSOLE_SYSNAME=\"{s}\"", .{self.sysname});
            if (try self.write(line)) try self.added.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    fn appendStorage(self: *Converter) !void {
        const st = try readStorage(self.entries);
        if (st.spinand or st.spinor or st.dfs) {
            if (try self.write(BARE_STORAGE_MTD)) try self.added.append(self.allocator, try self.allocator.dupe(u8, BARE_STORAGE_MTD));
        }
        if (st.spinand) {
            for (BARE_STORAGE_NAND) |line| {
                if (try self.write(line)) try self.added.append(self.allocator, try self.allocator.dupe(u8, line));
            }
        }
        if (st.spinor) {
            for (BARE_STORAGE_NOR) |line| {
                if (try self.write(line)) try self.added.append(self.allocator, try self.allocator.dupe(u8, line));
            }
        }
    }
};

/// 执行转换。`input` 是 rt-thread defconfig 的全文。
pub fn convert(allocator: std.mem.Allocator, input: []const u8, opts: Options) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    const lines = try splitLines(tmp.allocator(), input);
    const entry_list = try tmp.allocator().alloc(Entry, lines.items.len);
    for (lines.items, 0..) |line, i| entry_list[i] = parseLine(line);

    const chip = getValue(entry_list, "CONFIG_PRJ_CHIP");
    const board = getValue(entry_list, "CONFIG_PRJ_BOARD");
    const kernel = getValue(entry_list, "CONFIG_PRJ_KERNEL");
    const app = getValue(entry_list, "CONFIG_PRJ_APP");

    if (chip == null or board == null or kernel == null or app == null or
        chip.?.len == 0 or board.?.len == 0 or kernel.?.len == 0 or app.?.len == 0)
    {
        return Error.NoProjectHeader;
    }
    if (!std.mem.eql(u8, kernel.?, "rt-thread")) return Error.NotRtThread;

    const plan_name = try std.fmt.allocPrint(aa, "{s}_{s}_freertos_{s}", .{ chip.?, board.?, app.? });

    var conv = Converter{
        .allocator = aa,
        .out_text = aa,
        .entries = entry_list,
        .sysname = opts.sysname,
        .console_uart = opts.console_uart orelse readConsoleUart(entry_list),
        .qspi_buses = try readQspiBuses(entry_list),
        .seen = std.StringHashMap(void).init(aa),
    };
    try conv.run(plan_name);

    // 拼接输出文本（LF，末尾补换行）。
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(aa);
    for (conv.lines.items, 0..) |line, i| {
        if (i > 0) try buf.append(aa, '\n');
        try buf.appendSlice(aa, line);
    }
    try buf.append(aa, '\n');

    return .{
        .arena = arena,
        .text = buf.items,
        .plan_name = plan_name,
        .report = .{
            .kept_off = conv.kept_off.items,
            .dropped = conv.dropped.items,
            .mapped = conv.mapped.items,
            .added = conv.added.items,
            .silent = conv.silent,
        },
    };
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------
const sample =
    \\# comment
    \\CONFIG_PRJ_CHIP="d13x"
    \\CONFIG_PRJ_BOARD="demo88-nor"
    \\CONFIG_PRJ_KERNEL="rt-thread"
    \\CONFIG_PRJ_APP="helloworld"
    \\CONFIG_PRJ_DEFCONFIG_FILENAME="d13x_demo88-nor_rt-thread_helloworld_defconfig"
    \\CONFIG_RT_CONSOLE_DEVICE_NAME="uart1"
    \\CONFIG_AIC_USING_UART1=y
    \\CONFIG_AIC_USING_QSPI0=y
    \\CONFIG_AIC_QSPI0_DEVICE_SPINOR=y
    \\CONFIG_AIC_USING_QSPI2=y
    \\CONFIG_RT_USING_DFS=y
    \\CONFIG_RT_USING_DFS_ELMFAT=y
    \\CONFIG_AIC_USING_TOUCH=y
    \\CONFIG_AIC_CLK_PLL_FRA0_FREQ=792000000
    \\CONFIG_AIC_USING_DE=y
    \\# CONFIG_LPKG_MPP is not set
    \\
;

test "rtt2freertos：改写工程头与控制台、映射 DFS、丢弃无设备 QSPI" {
    const a = std.testing.allocator;
    var res = try convert(a, sample, .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("d13x_demo88-nor_freertos_helloworld", res.plan_name);
    const out = res.text;
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_PRJ_KERNEL=\"freertos\"\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_PRJ_DEFCONFIG_FILENAME=\"d13x_demo88-nor_freertos_helloworld_defconfig\"\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_BAREMETAL_CONSOLE_UART=1\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_LPKG_USING_DFS=y\nCONFIG_LPKG_USING_DFS_ELMFAT=y\n") != null);
    // 黑名单里的触摸被丢弃
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_USING_TOUCH") == null);
    // 没有 SPINOR/SPINAND 的总线 2 被丢弃，总线 0 保留
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_USING_QSPI0=y\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_USING_QSPI2") == null);
    // 非驱动 AIC_ 选项保留
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_CLK_PLL_FRA0_FREQ=792000000\n") != null);
    // RT_CONSOLE_DEVICE_NAME 本身不落到输出里
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_RT_CONSOLE_DEVICE_NAME") == null);
    // 存储链：SPINOR → MTD + SFUD
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_MTD_BARE_DRV=y\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_LPKG_USING_SFUD=y\n") != null);
    // console 三件套
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_CONSOLE_BARE_DRV=y\nCONFIG_AIC_PRINTF_BARE_DRV=y\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "CONFIG_AIC_CONSOLE_SYSNAME=\"aic\"\n") != null);
}

test "rtt2freertos：默认 y 的符号保留 is not set 且不重复补 FORCE_OFF" {
    const a = std.testing.allocator;
    var res = try convert(a, sample, .{});
    defer res.deinit();
    // 源里已有 `# CONFIG_LPKG_MPP is not set`，不会再追加一条
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.find(u8, res.text[idx..], "# CONFIG_LPKG_MPP is not set")) |p| {
        count += 1;
        idx += p + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "rtt2freertos：缺工程头与非 rt-thread 方案报错" {
    const a = std.testing.allocator;
    try std.testing.expectError(Error.NoProjectHeader, convert(a, "CONFIG_AIC_USING_UART0=y\n", .{}));
    const freertos_input =
        \\CONFIG_PRJ_CHIP="d13x"
        \\CONFIG_PRJ_BOARD="b"
        \\CONFIG_PRJ_KERNEL="freertos"
        \\CONFIG_PRJ_APP="a"
        \\
    ;
    try std.testing.expectError(Error.NotRtThread, convert(a, freertos_input, .{}));
}

test "rtt2freertos：黑名单优先于 AIC_ 保守保留" {
    try std.testing.expect(isBlacklisted("CONFIG_AIC_USING_TOUCH"));
    try std.testing.expect(isBlacklisted("CONFIG_AIC_I2S_CODEC_TLV320"));
    try std.testing.expect(!isKept("CONFIG_AIC_USING_TOUCH"));
    try std.testing.expect(!isKept("CONFIG_LPKG_USING_LVGL"));
    try std.testing.expect(isKept("CONFIG_AIC_CLK_PLL_FRA0_FREQ"));
    try std.testing.expect(!isKept("CONFIG_AIC_UART_DRV_TEST"));
    try std.testing.expect(isKept("CONFIG_RT_DFS_ELM_DRIVES"));
}

test "rtt2freertos：空 sysname 不写 SYSNAME，console-uart 可覆盖" {
    const a = std.testing.allocator;
    var res = try convert(a, sample, .{ .sysname = "", .console_uart = 2 });
    defer res.deinit();
    try std.testing.expect(std.mem.find(u8, res.text, "CONFIG_AIC_CONSOLE_SYSNAME") == null);
    try std.testing.expect(std.mem.find(u8, res.text, "CONFIG_AIC_BAREMETAL_CONSOLE_UART=2\n") != null);
}
