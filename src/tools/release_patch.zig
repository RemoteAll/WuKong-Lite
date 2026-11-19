//! repo 工作区补丁导出 —— 对应 Luban-Lite `tools/scripts/release_patch.py`：
//!
//!   把 `.repo` 管理的子项目提交，转换成可直接 `git am` 到单体仓库的补丁：
//!
//!   * 解析 `.repo/manifest.xml`（含 `<include>`、`<linkfile>` 路径重映射）；
//!   * 每个子项目按 `-t/--tag` 取范围（原始 commit SHA 含边界，tag/分支不含）；
//!   * `git format-patch --no-renames` 产补丁，再逐行重写：
//!       `diff --git a/X b/X`、`--- a/X`、`+++ b/X`、diffstat 行 → 加上项目路径 / linkfile 重映射；
//!       `Subject: [PATCH] <prefix>: <原标题>`；
//!   * 按提交者时间 + git 序号重命名，最后统一编号输出。
//!
//! 与参考的差异（均为“更保真”，不影响对拍结果）：
//!   * 参考以 `errors='replace'` 解码 patch；我们按**字节**处理，非 UTF-8 内容原样保留；
//!   * 参考把 `%ct` 转本地时间；我们用 `git show --format=%ci`（同为本地时区）再格式化，
//!     不依赖平台时区 API。
const std = @import("std");
const ext_tool = @import("ext_tool.zig");

pub const Error = error{
    NotRepoWorkspace,
    MissingTag,
    BadCount,
    NoMatchingProjects,
    NoPatches,
    PatchTooLarge,
    GitFailed,
};

pub const LinkFile = struct {
    src: []const u8,
    dest: []const u8,
};

pub const Project = struct {
    name: []const u8,
    path: []const u8,
    linkfiles: []LinkFile,
};

pub const Options = struct {
    /// 工作区根（含 `.repo/manifest.xml`），默认当前目录。
    root: []const u8 = ".",
    tag: ?[]const u8 = null,
    /// 逗号分隔的项目路径过滤。
    projects: ?[]const u8 = null,
    output: ?[]const u8 = null,
    count: ?usize = null,
    list: bool = false,
    verbose: bool = false,
};

pub const Summary = struct {
    projects: usize = 0,
    patches: usize = 0,
    output_dir: []u8 = &.{},
    /// `--list` 的文本（仅在 list 模式有内容）。
    listing: []u8 = &.{},

    pub fn deinit(self: Summary, allocator: std.mem.Allocator) void {
        if (self.output_dir.len > 0) allocator.free(self.output_dir);
        if (self.listing.len > 0) allocator.free(self.listing);
    }
};

/// 输出重定向（参考的 `pr_info` / `pr_warn` / `pr_err`）。
pub const Logger = struct {
    writer: ?*std.Io.Writer = null,

    fn line(self: Logger, prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
        const w = self.writer orelse return;
        w.print("{s} " ++ fmt ++ "\n", .{prefix} ++ args) catch {};
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.line(">>>", fmt, args);
    }

    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.line("!!!", fmt, args);
    }

    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.line("***", fmt, args);
    }
};

// ---------------------------------------------------------------------------
// manifest.xml 解析（只处理 `<project>` / `<linkfile>` / `<include>`）
// ---------------------------------------------------------------------------

const Tag = struct {
    name: []const u8,
    self_closing: bool,
    closing: bool,
    attrs: std.StringHashMap([]const u8),
    /// 标签在源文本中的结束位置（属性之后）。
    end: usize,

    fn attr(self: Tag, key: []const u8) ?[]const u8 {
        return self.attrs.get(key);
    }
};

fn findTag(src: []const u8, from: usize, map: *std.StringHashMap([]const u8)) ?Tag {
    const lt = std.mem.findScalar(u8, src[from..], '<') orelse return null;
    var i = from + lt + 1;
    if (i >= src.len) return null;
    // 跳过注释 / 处理指令
    if (std.mem.startsWith(u8, src[i..], "!--")) {
        const end = std.mem.find(u8, src[i..], "-->") orelse return null;
        return findTag(src, i + end + 3, map);
    }
    if (std.mem.startsWith(u8, src[i..], "?")) {
        const end = std.mem.findScalar(u8, src[i..], '>') orelse return null;
        return findTag(src, i + end + 1, map);
    }

    const closing = src[i] == '/';
    if (closing) i += 1;

    const name_start = i;
    while (i < src.len and !std.mem.eql(u8, src[i..][0..1], " ") and src[i] != '\t' and
        src[i] != '\n' and src[i] != '\r' and src[i] != '>' and src[i] != '/') : (i += 1)
    {}
    const name = src[name_start..i];

    map.clearRetainingCapacity();

    var self_closing = false;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r')) i += 1;
        if (i >= src.len) break;
        if (src[i] == '>') {
            i += 1;
            break;
        }
        if (src[i] == '/') {
            self_closing = true;
            i += 1;
            continue;
        }
        // 属性名
        const ks = i;
        while (i < src.len and src[i] != '=' and src[i] != '>' and src[i] != ' ' and src[i] != '/') i += 1;
        const key = src[ks..i];
        while (i < src.len and (src[i] == ' ' or src[i] == '=')) i += 1;
        if (i >= src.len or (src[i] != '"' and src[i] != '\'')) continue;
        const quote = src[i];
        i += 1;
        const vs = i;
        while (i < src.len and src[i] != quote) i += 1;
        const val = src[vs..i];
        if (i < src.len) i += 1;
        map.put(key, val) catch {};
    }

    return .{ .name = name, .self_closing = self_closing, .closing = closing, .attrs = map.*, .end = i };
}

fn parseManifestFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]Project {
    var tmp = std.heap.ArenaAllocator.init(arena);
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, tmp.allocator(), .limited(8 << 20));
    defer tmp.deinit();

    var attr_map = std.StringHashMap([]const u8).init(tmp.allocator());

    var list: std.ArrayList(Project) = .empty;

    // 只收集**顶层**（manifest 的直接子元素）的 project / linkfile（等价 ElementTree 的 findall）
    var depth: usize = 0;
    var cur: ?Project = null;
    var cur_links: std.ArrayList(LinkFile) = .empty;
    var pos: usize = 0;

    while (findTag(src, pos, &attr_map)) |tag| {
        pos = tag.end;
        if (tag.closing) {
            if (depth > 0) depth -= 1;
            if (depth == 1 and cur != null) {
                var p = cur.?;
                p.linkfiles = try cur_links.toOwnedSlice(arena);
                try list.append(arena, p);
                cur = null;
                cur_links = .empty;
            }
            continue;
        }

        if (depth == 1 and std.mem.eql(u8, tag.name, "project")) {
            const nm = try arena.dupe(u8, tag.attr("name") orelse "");
            const raw_path = try arena.dupe(u8, tag.attr("path") orelse "");
            cur = .{
                .name = nm,
                .path = std.mem.trimEnd(u8, raw_path, "/"),
                .linkfiles = &.{},
            };
            cur_links = .empty;
        } else if (depth == 2 and cur != null and std.mem.eql(u8, tag.name, "linkfile")) {
            const src_attr = tag.attr("src") orelse "";
            const dst_attr = tag.attr("dest") orelse "";
            if (src_attr.len > 0 and dst_attr.len > 0) {
                try cur_links.append(arena, .{
                    .src = try arena.dupe(u8, src_attr),
                    .dest = try arena.dupe(u8, dst_attr),
                });
            }
        }

        if (!tag.self_closing) {
            depth += 1;
        } else if (depth == 1 and cur != null and std.mem.eql(u8, tag.name, "project")) {
            var p = cur.?;
            p.linkfiles = try cur_links.toOwnedSlice(arena);
            try list.append(arena, p);
            cur = null;
            cur_links = .empty;
        }
    }

    return list.toOwnedSlice(arena);
}

/// `<include name="x.xml"/>` 的名字列表（顶层）。
fn parseIncludes(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![][]const u8 {
    var tmp = std.heap.ArenaAllocator.init(arena);
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, tmp.allocator(), .limited(8 << 20));
    defer tmp.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    var attr_map = std.StringHashMap([]const u8).init(tmp.allocator());

    var depth: usize = 0;
    var pos: usize = 0;
    while (findTag(src, pos, &attr_map)) |tag| {
        pos = tag.end;
        if (tag.closing) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 1 and std.mem.eql(u8, tag.name, "include")) {
            if (tag.attr("name")) |n| {
                if (n.len > 0) try list.append(arena, try arena.dupe(u8, n));
            }
        }
        if (!tag.self_closing) depth += 1;
    }
    return list.toOwnedSlice(arena);
}

/// manifest 解析结果（字符串与切片都归 arena 所有，`deinit` 一次性释放）。
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    projects: []Project,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// 解析 manifest（含 `<include>`，参考 `parse_manifest()`）。
pub fn parseManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest_path: []const u8,
    log: Logger,
) !Manifest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayList(Project) = .empty;

    const main = try parseManifestFile(a, io, manifest_path);
    try list.appendSlice(a, main);

    const repo_dir = std.fs.path.dirname(manifest_path) orelse ".";
    const manifests_dir = try std.fs.path.join(a, &.{ repo_dir, "manifests" });

    const includes = try parseIncludes(a, io, manifest_path);

    for (includes) |inc| {
        const inc_path = try std.fs.path.join(a, &.{ manifests_dir, inc });
        if (std.Io.Dir.cwd().statFile(io, inc_path, .{})) |_| {
            const more = try parseManifestFile(a, io, inc_path);
            try list.appendSlice(a, more);
        } else |_| {
            log.warn("Included manifest not found: {s}", .{inc_path});
        }
    }

    return .{ .arena = arena, .projects = try list.toOwnedSlice(a) };
}

// ---------------------------------------------------------------------------
// 路径与标题变换
// ---------------------------------------------------------------------------

/// 参考 `get_subject_prefix()`：路径最后一段按 `-` 取第一段。
pub fn subjectPrefix(project_path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, project_path, "/");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
    if (std.mem.findScalar(u8, last, '-')) |i| return last[0..i];
    return last;
}

/// 参考 `transform_patch_path()`。
pub fn transformPath(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    project_path: []const u8,
    linkfiles: []const LinkFile,
) ![]u8 {
    for (linkfiles) |lf| {
        if (std.mem.eql(u8, file_path, lf.src)) return allocator.dupe(u8, lf.dest);
        if (file_path.len > lf.src.len and std.mem.startsWith(u8, file_path, lf.src) and
            file_path[lf.src.len] == '/')
        {
            const rest = file_path[lf.src.len + 1 ..];
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, lf.dest, "/"), rest });
        }
    }
    if (project_path.len > 0) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_path, file_path });
    return allocator.dupe(u8, file_path);
}

const PatchState = struct {
    in_diffstat: bool = false,
    in_diff_section: bool = false,
};

fn isSeparator(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), "---");
}

/// 参考 `_transform_line()`：返回 null 表示原样输出。
fn transformLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    project_path: []const u8,
    linkfiles: []const LinkFile,
    prefix: []const u8,
    state: *PatchState,
) !?[]u8 {
    if (isSeparator(line) and !state.in_diff_section) {
        state.in_diffstat = true;
        return null;
    }

    if (std.mem.startsWith(u8, line, "diff --git a/")) {
        state.in_diffstat = false;
        state.in_diff_section = true;
        const rest = line["diff --git a/".len..];
        if (std.mem.find(u8, rest, " b/")) |idx| {
            const a_path = rest[0..idx];
            const b_path = rest[idx + " b/".len ..];
            const na = try transformPath(allocator, a_path, project_path, linkfiles);
            defer allocator.free(na);
            const nb = try transformPath(allocator, b_path, project_path, linkfiles);
            defer allocator.free(nb);
            return try std.fmt.allocPrint(allocator, "diff --git a/{s} b/{s}", .{ na, nb });
        }
        return null;
    }

    if (std.mem.startsWith(u8, line, "Subject: ")) {
        const subject = line["Subject: ".len..];
        // 去掉 `[PATCH]` / `[PATCH n/m]` 前缀
        var clean = subject;
        if (std.mem.startsWith(u8, clean, "[PATCH")) {
            if (std.mem.findScalar(u8, clean, ']')) |close| {
                clean = std.mem.trimStart(u8, clean[close + 1 ..], " \t");
            }
        }
        return try std.fmt.allocPrint(allocator, "Subject: [PATCH] {s}: {s}", .{ prefix, clean });
    }

    if (std.mem.startsWith(u8, line, "--- a/")) {
        const old_path = line[6..];
        const np = try transformPath(allocator, old_path, project_path, linkfiles);
        defer allocator.free(np);
        return try std.fmt.allocPrint(allocator, "--- a/{s}", .{np});
    }

    if (std.mem.startsWith(u8, line, "+++ b/")) {
        const old_path = line[6..];
        const np = try transformPath(allocator, old_path, project_path, linkfiles);
        defer allocator.free(np);
        return try std.fmt.allocPrint(allocator, "+++ b/{s}", .{np});
    }

    if (state.in_diffstat) {
        // diffstat 行：`  <path>  | <n> ++--`（缩进 + 路径 + 空白 + `|` + 空白 + 统计）。
        // 参考正则 `^(\s+)(.+)(\s+\|\s+.*)$` 的 group2 是贪婪的：路径**保留**自身的
        // 尾随空白，`\s+` 只吃掉 `|` 前最后一个空白 —— 必须照抄，否则列对齐会与参考不同。
        const bar = std.mem.lastIndexOfScalar(u8, line, '|') orelse return null;
        if (bar == 0 or bar + 1 >= line.len) return null;
        if (!std.ascii.isWhitespace(line[bar - 1]) or !std.ascii.isWhitespace(line[bar + 1])) return null;
        const sep = bar - 1;
        var indent_end: usize = 0;
        while (indent_end < line.len and (line[indent_end] == ' ' or line[indent_end] == '\t')) indent_end += 1;
        if (indent_end == 0 or indent_end >= sep) return null;
        const indent = line[0..indent_end];
        const path_part = line[indent_end..sep];
        const stat_part = line[sep..];

        // 重命名行 `{old => new}` / `pre{old => new}post`
        if (std.mem.findScalar(u8, path_part, '{')) |ob| {
            if (std.mem.find(u8, path_part[ob..], " => ")) |rel| {
                const arrow = ob + rel;
                if (std.mem.findScalar(u8, path_part[arrow..], '}')) |rel2| {
                    const close = arrow + rel2;
                    const pre = path_part[0..ob];
                    const new_name = path_part[arrow + " => ".len .. close];
                    const post = path_part[close + 1 ..];
                    const full = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ pre, new_name, post });
                    defer allocator.free(full);
                    const np = try transformPath(allocator, full, project_path, linkfiles);
                    defer allocator.free(np);
                    return try std.fmt.allocPrint(allocator, "{s}{{{s} => {s}}}{s}", .{ indent, np, np, stat_part });
                }
            }
        }

        const np = try transformPath(allocator, path_part, project_path, linkfiles);
        defer allocator.free(np);
        return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ indent, np, stat_part });
    }

    return null;
}

// ---------------------------------------------------------------------------
// 补丁文件扫描
// ---------------------------------------------------------------------------

/// 参考 `scan_patch_commit_sha()`：从首行 `From <sha> <date>` 取 SHA。
pub fn scanCommitSha(content: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "From ")) {
            const rest = line[5..];
            const end = std.mem.findScalar(u8, rest, ' ') orelse rest.len;
            const sha = rest[0..end];
            if (!isHex(sha) or sha.len < 7 or sha.len > 40) return null;
            return sha;
        }
        if (isSeparator(line)) return null;
    }
    return null;
}

fn isHex(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn monthIndex(name: []const u8) ?u32 {
    for (months, 0..) |m, i| {
        if (std.mem.eql(u8, m, name)) return @intCast(i + 1);
    }
    return null;
}

/// 解析 RFC 2822 `Date:` 行 → `YYYYMMDDHHMMSS`。
pub fn parseRfc2822(date: []const u8) ?[14]u8 {
    // `Thu, 20 Nov 2025 10:00:00 +0800`
    var i: usize = 0;
    if (std.mem.findScalar(u8, date, ',')) |comma| {
        i = std.mem.trimStart(u8, date[comma + 1 ..], " \t").ptr - date.ptr;
    }
    var it = std.mem.tokenizeAny(u8, date[i..], " \t");
    const day_s = it.next() orelse return null;
    const mon_s = it.next() orelse return null;
    const year_s = it.next() orelse return null;
    const time_s = it.next() orelse return null;

    const day = std.fmt.parseInt(u32, day_s, 10) catch return null;
    const mon = monthIndex(mon_s) orelse return null;
    const year = std.fmt.parseInt(u32, year_s, 10) catch return null;

    var tit = std.mem.splitScalar(u8, time_s, ':');
    const hh = std.fmt.parseInt(u32, tit.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(u32, tit.next() orelse return null, 10) catch return null;
    const ss = std.fmt.parseInt(u32, tit.next() orelse "0", 10) catch 0;

    var out: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{ year, mon, day, hh, mm, ss }) catch return null;
    return out;
}

/// `YYYY-MM-DD HH:MM:SS +0800`（`git show --format=%ci`）→ `YYYYMMDDHHMMSS`。
pub fn parseGitIsoLocal(s: []const u8) ?[14]u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len < 19) return null;
    var out: [14]u8 = undefined;
    @memcpy(out[0..4], t[0..4]);
    @memcpy(out[4..6], t[5..7]);
    @memcpy(out[6..8], t[8..10]);
    @memcpy(out[8..10], t[11..13]);
    @memcpy(out[10..12], t[14..16]);
    @memcpy(out[12..14], t[17..19]);
    for (out) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return out;
}

/// 参考 `scan_patch_date()`：只读头部到 `---` 分隔。
pub fn scanPatchDate(content: []const u8) ?[14]u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "Date: ")) return parseRfc2822(line[6..]);
        if (isSeparator(line)) return null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// git 调用
// ---------------------------------------------------------------------------

fn git(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    args: []const []const u8,
) !ext_tool.RunOutcome {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
        try argv.append(allocator, "-C");
        try argv.append(allocator, dir);
    }
    try argv.appendSlice(allocator, args);
    return ext_tool.run(allocator, io, argv.items);
}

fn joinPath(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    if (std.mem.eql(u8, root, ".") or root.len == 0) return allocator.dupe(u8, rel);
    return std.fs.path.join(allocator, &.{ root, rel });
}

pub const GenerateResult = struct {
    patches: [][]u8,
    pub fn deinit(self: GenerateResult, allocator: std.mem.Allocator) void {
        for (self.patches) |p| allocator.free(p);
        allocator.free(self.patches);
    }
};

/// 参考 `generate_patches()`：为一个项目产出 `format-patch` 文件（路径在 `out_dir`）。
fn generatePatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    proj_dir: []const u8,
    proj_name: []const u8,
    base_ref: []const u8,
    out_dir: []const u8,
    max_count: ?usize,
    log: Logger,
) ![][]u8 {
    var empty: [][]u8 = &.{};
    _ = &empty;

    if (std.Io.Dir.cwd().statFile(io, proj_dir, .{})) |_| {} else |_| {
        log.warn("Project path not found: {s}, skipping", .{proj_dir});
        return allocator.dupe([]u8, &.{});
    }
    const dot_git = try std.fs.path.join(allocator, &.{ proj_dir, ".git" });
    defer allocator.free(dot_git);
    if (std.Io.Dir.cwd().statFile(io, dot_git, .{})) |_| {} else |_| {
        log.warn("Not a git repository: {s}, skipping", .{proj_dir});
        return allocator.dupe([]u8, &.{});
    }

    // rev-parse --verify '<ref>^{commit}'
    const peeled = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{base_ref});
    defer allocator.free(peeled);
    var r = try git(allocator, io, proj_dir, &.{ "rev-parse", "--verify", peeled });
    defer r.deinit(allocator);
    if (r.code != 0) {
        log.info("Ref '{s}' not found in {s}, skipping", .{ base_ref, proj_name });
        return allocator.dupe([]u8, &.{});
    }
    const base_commit = try allocator.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n"));
    defer allocator.free(base_commit);

    // merge-base --is-ancestor <base> HEAD
    r.deinit(allocator);
    r = try git(allocator, io, proj_dir, &.{ "merge-base", "--is-ancestor", base_commit, "HEAD" });
    if (r.code != 0) {
        r.deinit(allocator);
        const short = if (base_commit.len > 8) base_commit[0..8] else base_commit;
        log.warn("Ref '{s}' ({s}) is not an ancestor of HEAD in {s}, skipping (wrong start point)", .{ base_ref, short, proj_name });
        return allocator.dupe([]u8, &.{});
    }
    r.deinit(allocator);

    const is_sha = isHex(base_ref) and base_ref.len >= 4 and base_ref.len <= 40;
    var list_spec: []const u8 = undefined;
    var base_is_root = false;
    if (is_sha) {
        const parent = try std.fmt.allocPrint(allocator, "{s}^", .{base_commit});
        defer allocator.free(parent);
        r = try git(allocator, io, proj_dir, &.{ "rev-parse", "--verify", "-q", parent });
        const has_parent = r.code == 0 and std.mem.trim(u8, r.stdout, " \t\r\n").len > 0;
        r.deinit(allocator);
        if (has_parent) {
            list_spec = try std.fmt.allocPrint(allocator, "{s}^..HEAD", .{base_commit});
        } else {
            base_is_root = true;
            list_spec = try allocator.dupe(u8, "HEAD");
        }
    } else {
        list_spec = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{base_commit});
    }
    defer allocator.free(list_spec);

    // rev-list --reverse --topo-order <spec>
    r = try git(allocator, io, proj_dir, &.{ "rev-list", "--reverse", "--topo-order", list_spec });
    defer r.deinit(allocator);
    var commits: std.ArrayList([]const u8) = .empty;
    defer commits.deinit(allocator);
    {
        var it = std.mem.tokenizeAny(u8, r.stdout, " \t\r\n");
        while (it.next()) |c| try commits.append(allocator, c);
    }
    if (commits.items.len == 0) {
        log.info("No commits since '{s}' in {s}", .{ base_ref, proj_name });
        return allocator.dupe([]u8, &.{});
    }

    const truncated = if (max_count) |mc| commits.items.len > mc else false;
    const end_commit = if (max_count) |mc| commits.items[@min(mc, commits.items.len) - 1] else commits.items[commits.items.len - 1];

    const patch_range = if (is_sha and base_is_root)
        try std.fmt.allocPrint(allocator, "{s}", .{end_commit})
    else if (is_sha)
        try std.fmt.allocPrint(allocator, "{s}^..{s}", .{ base_commit, end_commit })
    else
        try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base_commit, end_commit });
    defer allocator.free(patch_range);

    // format-patch --topo-order <range> -o <dir> --no-renames
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "format-patch");
    try args.append(allocator, "--topo-order");
    if (is_sha and base_is_root) try args.append(allocator, "--root");
    try args.append(allocator, patch_range);
    try args.append(allocator, "-o");
    try args.append(allocator, out_dir);
    try args.append(allocator, "--no-renames");

    r = try git(allocator, io, proj_dir, args.items);
    defer r.deinit(allocator);
    if (r.code != 0) {
        log.err("git format-patch failed in {s}: {s}", .{ proj_dir, std.mem.trim(u8, r.stderr, " \t\r\n") });
        return allocator.dupe([]u8, &.{});
    }

    const patches = try listPatches(allocator, io, out_dir);
    if (patches.len > 0) {
        if (truncated) {
            log.info("Generated {d} patch(es) from {s} (limited to first {d})", .{ patches.len, proj_name, max_count.? });
        } else {
            log.info("Generated {d} patch(es) from {s}", .{ patches.len, proj_name });
        }
    }
    return patches;
}

fn listPatches(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return list.toOwnedSlice(allocator);
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".patch")) continue;
        try list.append(allocator, try std.fs.path.join(allocator, &.{ dir, e.name }));
    }
    std.mem.sort([]u8, list.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return list.toOwnedSlice(allocator);
}

fn writeTransformed(
    allocator: std.mem.Allocator,
    io: std.Io,
    in_path: []const u8,
    out_path: []const u8,
    proj_path: []const u8,
    linkfiles: []const LinkFile,
    prefix: []const u8,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, in_path, allocator, .limited(512 << 20)) catch |err| switch (err) {
        error.StreamTooLong => return Error.PatchTooLarge,
        else => return err,
    };
    defer allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // 参考用的是 Python 文本模式：读入时 universal-newlines 把 `\r\n` / `\r` 归一成 `\n`，
    // 写出时再把 `\n` 换成**平台默认换行**（Windows 上是 CRLF）。这里照同样语义实现，
    // 否则本机产物与参考的 patch 每行差一个 `\r`（`git am` 虽都能用，但无法逐字节对拍）。
    const newline: []const u8 = if (@import("builtin").os.tag == .windows) "\r\n" else "\n";
    var state: PatchState = .{};
    var pos: usize = 0;
    while (pos < content.len) {
        const nl = std.mem.findScalar(u8, content[pos..], '\n');
        var line = if (nl) |k| content[pos .. pos + k] else content[pos..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (try transformLine(allocator, line, proj_path, linkfiles, prefix, &state)) |new_line| {
            defer allocator.free(new_line);
            try out.writer.writeAll(new_line);
        } else {
            try out.writer.writeAll(line);
        }
        try out.writer.writeAll(newline);
        pos = if (nl) |k| pos + k + 1 else content.len;
    }

    if (std.fs.path.dirname(out_path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.written() });
}

fn fmtTs(buf: *[14]u8, ts: ?[14]u8) []const u8 {
    const t = ts orelse "00010101000000".*;
    @memcpy(buf, &t);
    return buf;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

fn normPath(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var it = std.mem.tokenizeAny(u8, s, "/\\");
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.writer.writeByte('/');
        first = false;
        try out.writer.writeAll(seg);
    }
    return out.toOwnedSlice();
}

/// 参考 `--projects` 过滤：按规范化路径匹配，未命中的给出告警，全部未命中则报错。
fn filterProjects(
    arena: std.mem.Allocator,
    projects: []const Project,
    spec: []const u8,
    log: Logger,
) ![]Project {
    var selected: std.ArrayList([]const u8) = .empty;
    var sit = std.mem.splitScalar(u8, spec, ',');
    while (sit.next()) |raw| {
        const key = try normPath(arena, std.mem.trim(u8, raw, " \t"));
        if (key.len == 0) continue;
        var dup = false;
        for (selected.items) |s2| {
            if (std.mem.eql(u8, s2, key)) dup = true;
        }
        if (dup) continue;
        var found = false;
        for (projects) |p| {
            const np = try normPath(arena, p.path);
            if (std.mem.eql(u8, np, key)) found = true;
        }
        if (!found) {
            log.warn("Project \"{s}\" not found in manifest", .{std.mem.trim(u8, raw, " \t")});
            continue;
        }
        try selected.append(arena, key);
    }
    if (selected.items.len == 0) {
        log.err("No matching projects found. Use --list to see available projects.", .{});
        return Error.NoMatchingProjects;
    }

    var filtered: std.ArrayList(Project) = .empty;
    for (projects) |p| {
        const np = try normPath(arena, p.path);
        for (selected.items) |s2| {
            if (std.mem.eql(u8, s2, np)) {
                try filtered.append(arena, p);
                break;
            }
        }
    }
    return filtered.toOwnedSlice(arena);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opt: Options,
    log: Logger,
) !Summary {
    const manifest_path = try joinPath(allocator, opt.root, ".repo/manifest.xml");
    defer allocator.free(manifest_path);
    if (std.Io.Dir.cwd().statFile(io, manifest_path, .{})) |_| {} else |_| {
        log.err("Current directory is not the root of a repo workspace", .{});
        log.err("Expected {s} not found", .{manifest_path});
        return Error.NotRepoWorkspace;
    }

    log.info("Repo workspace root: {s}", .{opt.root});

    var manifest = try parseManifest(allocator, io, manifest_path, log);
    defer manifest.deinit();
    var projects = manifest.projects;
    log.info("Found {d} projects in manifest", .{projects.len});

    if (opt.list) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("Available projects:\n");
        for (projects) |p| {
            try out.writer.print("  {s}", .{p.path});
            var pad: usize = if (p.path.len < 35) 35 - p.path.len else 1;
            while (pad > 0) : (pad -= 1) try out.writer.writeByte(' ');
            try out.writer.writeAll("(linkfiles: ");
            if (p.linkfiles.len == 0) {
                try out.writer.writeAll("none");
            } else {
                for (p.linkfiles, 0..) |lf, i| {
                    if (i != 0) try out.writer.writeAll(", ");
                    try out.writer.print("{s}->{s}", .{ lf.src, lf.dest });
                }
            }
            try out.writer.writeAll(")\n");
        }
        return .{ .projects = projects.len, .listing = try out.toOwnedSlice() };
    }

    const tag = opt.tag orelse {
        log.err("--tag is required (accepts tag, commit SHA, or branch ref)", .{});
        return Error.MissingTag;
    };
    if (opt.count) |c| {
        if (c == 0) {
            log.err("--count must be a positive integer", .{});
            return Error.BadCount;
        }
    }

    // -p/--projects 过滤（容忍多余斜杠）
    if (opt.projects) |spec| {
        projects = try filterProjects(manifest.arena.allocator(), projects, spec, log);
        log.info("Filtered to {d} project(s)", .{projects.len});
    }

    // 输出目录
    const output_dir: []u8 = if (opt.output) |o|
        try allocator.dupe(u8, o)
    else blk: {
        const now = std.Io.Timestamp.now(io, .real);
        const secs = @max(@as(i64, now.toSeconds()), 0);
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(secs, 86400) * 86400 + @mod(secs, 86400)) };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        break :blk try std.fmt.allocPrint(allocator, "patch_output_{d:0>4}-{d:0>2}-{d:0>2}", .{
            yd.year, md.month.numeric(), md.day_index + 1,
        });
    };
    errdefer allocator.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    log.info("Output directory: {s}", .{output_dir});

    // 暂存目录
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.release_stage", .{output_dir});
    defer allocator.free(stage_dir);
    std.Io.Dir.cwd().deleteTree(io, stage_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, stage_dir);

    var total: usize = 0;
    var summary = Summary{};

    // 逐项目生成 + 变换
    for (projects, 0..) |p, idx| {
        const proj_dir = try joinPath(allocator, opt.root, p.path);
        defer allocator.free(proj_dir);
        const gitout = try std.fmt.allocPrint(allocator, "{s}/git-{d}", .{ stage_dir, idx });
        defer allocator.free(gitout);
        try std.Io.Dir.cwd().createDirPath(io, gitout);

        const patches = generatePatches(allocator, io, proj_dir, p.name, tag, gitout, opt.count, log) catch |err| {
            log.warn("Project {s} skipped: {s}", .{ p.name, @errorName(err) });
            continue;
        };
        defer {
            for (patches) |f| allocator.free(f);
            allocator.free(patches);
        }

        const prefix = subjectPrefix(p.path);
        for (patches) |pf| {
            const base = std.fs.path.basename(pf);
            var gitnum: []const u8 = "9999";
            var orig: []const u8 = base;
            if (base.len > 5 and isFourDigits(base[0..4]) and base[4] == '-') {
                gitnum = base[0..4];
                orig = base[5..];
            }

            const content = std.Io.Dir.cwd().readFileAlloc(io, pf, allocator, .limited(512 << 20)) catch |err| switch (err) {
                error.StreamTooLong => return Error.PatchTooLarge,
                else => return err,
            };
            defer allocator.free(content);

            var ts_buf: [14]u8 = undefined;
            var ts: ?[14]u8 = null;
            if (scanCommitSha(content)) |sha| {
                var r = try git(allocator, io, proj_dir, &.{ "show", "-s", "--format=%ci", sha });
                defer r.deinit(allocator);
                if (r.code == 0) ts = parseGitIsoLocal(r.stdout);
            }
            if (ts == null) ts = scanPatchDate(content);
            const ts_str = fmtTs(&ts_buf, ts);

            const stage_name = try std.fmt.allocPrint(allocator, "{s}_{s}_{s}_{s}", .{ ts_str, gitnum, prefix, orig });
            defer allocator.free(stage_name);
            const stage_path = try std.fs.path.join(allocator, &.{ stage_dir, stage_name });
            defer allocator.free(stage_path);
            try writeTransformed(allocator, io, pf, stage_path, p.path, p.linkfiles, prefix);
            total += 1;
        }
        // 删除临时 patch 目录，避免与 stage 混淆
        std.Io.Dir.cwd().deleteTree(io, gitout) catch {};
    }

    if (total == 0) {
        log.err("No patches generated. Does ref \"{s}\" exist in any project?", .{tag});
        return Error.NoPatches;
    }
    log.info("Total patches collected: {d}", .{total});

    // 排序 + 统一编号复制到输出目录
    const staged = try listPatches(allocator, io, stage_dir);
    defer {
        for (staged) |f| allocator.free(f);
        allocator.free(staged);
    }
    for (staged, 0..) |sp, i| {
        var base = std.fs.path.basename(sp);
        // 去掉 `YYYYMMDDHHMMSS_<gitnum>_` 前缀
        if (base.len > 19 and base[14] == '_' and isFourDigits(base[15..19]) and base[19] == '_') {
            base = base[20..];
        }
        const out_name = try std.fmt.allocPrint(allocator, "{d:0>4}-{s}", .{ i + 1, base });
        defer allocator.free(out_name);
        const src = try std.fs.path.join(allocator, &.{ stage_dir, std.fs.path.basename(sp) });
        defer allocator.free(src);
        const dst = try std.fs.path.join(allocator, &.{ output_dir, out_name });
        defer allocator.free(dst);
        try copyFile(allocator, io, src, dst);
        log.info("  [{d:0>4}] {s}", .{ i + 1, out_name });
    }

    std.Io.Dir.cwd().deleteTree(io, stage_dir) catch {};

    log.info("Done! {d} patches written to: {s}", .{ total, output_dir });
    log.info("Apply them in the monolithic repo with:", .{});
    log.info("  cd <monorepo> && git am {s}/*.patch", .{output_dir});

    summary.projects = projects.len;
    summary.patches = total;
    summary.output_dir = output_dir;
    return summary;
}

fn isFourDigits(s: []const u8) bool {
    if (s.len != 4) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn copyFile(allocator: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(512 << 20));
    defer allocator.free(data);
    if (std.fs.path.dirname(dst)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data });
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------

test "release_patch.subjectPrefix" {
    try std.testing.expectEqualStrings("artinchip", subjectPrefix("bsp/artinchip"));
    try std.testing.expectEqualStrings("hal", subjectPrefix("bsp/artinchip/hal"));
    try std.testing.expectEqualStrings("rt", subjectPrefix("kernel/rt-thread"));
    try std.testing.expectEqualStrings("target", subjectPrefix("target"));
    try std.testing.expectEqualStrings("target", subjectPrefix("target/"));
}

test "release_patch.transformPath：linkfile 精确/前缀与默认前缀" {
    const allocator = std.testing.allocator;
    const links = [_]LinkFile{
        .{ .src = "a/b.h", .dest = "include/b.h" },
        .{ .src = "src", .dest = "dest" },
    };
    {
        const p = try transformPath(allocator, "a/b.h", "proj", &links);
        defer allocator.free(p);
        try std.testing.expectEqualStrings("include/b.h", p);
    }
    {
        const p = try transformPath(allocator, "src/x/y.c", "proj", &links);
        defer allocator.free(p);
        try std.testing.expectEqualStrings("dest/x/y.c", p);
    }
    {
        const p = try transformPath(allocator, "drv/pm.c", "bsp/artinchip", &.{});
        defer allocator.free(p);
        try std.testing.expectEqualStrings("bsp/artinchip/drv/pm.c", p);
    }
}

test "release_patch.transformLine：路径/subject/diffstat" {
    const allocator = std.testing.allocator;
    var state: PatchState = .{};
    const links = [_]LinkFile{};

    // Subject：去掉 [PATCH n/m] 前缀并加项目前缀
    {
        const out = try transformLine(allocator, "Subject: [PATCH 2/3] fix: uart", "p", &links, "proj", &state);
        defer allocator.free(out.?);
        try std.testing.expectEqualStrings("Subject: [PATCH] proj: fix: uart", out.?);
    }
    // 分隔行 → 进入 diffstat（真实 patch 里在 diff --git 之前）
    {
        const out = try transformLine(allocator, "---", "bsp/x", &links, "x", &state);
        try std.testing.expect(out == null);
        try std.testing.expect(state.in_diffstat);
    }
    // diffstat 行
    {
        const out = try transformLine(allocator, " drv/a.c | 10 +++---", "bsp/x", &links, "x", &state);
        defer allocator.free(out.?);
        try std.testing.expectEqualStrings(" bsp/x/drv/a.c | 10 +++---", out.?);
    }
    // diff --git 结束 diffstat 段
    {
        const out = try transformLine(allocator, "diff --git a/drv/a.c b/drv/a.c", "bsp/x", &links, "x", &state);
        defer allocator.free(out.?);
        try std.testing.expectEqualStrings("diff --git a/bsp/x/drv/a.c b/bsp/x/drv/a.c", out.?);
        try std.testing.expect(!state.in_diffstat);
        try std.testing.expect(state.in_diff_section);
    }
    // hunk 内的普通行不动
    {
        state.in_diffstat = false;
        state.in_diff_section = true;
        const out = try transformLine(allocator, "+  a | b", "bsp/x", &links, "x", &state);
        try std.testing.expect(out == null);
    }
}

test "release_patch：patch 头部扫描与日期格式化" {
    const patch =
        \\From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001
        \\From: Dev <dev@example.com>
        \\Date: Thu, 20 Nov 2025 10:11:12 +0800
        \\Subject: [PATCH] hello
        \\
        \\---
        \\ a.c | 2 +-
        \\
    ;
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", scanCommitSha(patch).?);
    const d = scanPatchDate(patch).?;
    try std.testing.expectEqualStrings("20251120101112", &d);

    const g = parseGitIsoLocal("2025-11-20 10:11:12 +0800\n").?;
    try std.testing.expectEqualStrings("20251120101112", &g);

    // 无 Date 行时返回 null（参考回落到 datetime.min）
    try std.testing.expect(scanPatchDate("From x\n\n---\n") == null);
}

test "release_patch.parseManifest：project/linkfile/include" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<manifest>
        \\  <include name="extra.xml"/>
        \\  <project name="bsp/artinchip" path="bsp/artinchip/">
        \\    <linkfile src="a/b.h" dest="include/b.h"/>
        \\  </project>
        \\  <project name="target" path="target"/>
        \\</manifest>
    ;
    const extra =
        \\<?xml version="1.0"?>
        \\<manifest>
        \\  <project name="kernel" path="kernel/rt-thread"/>
        \\</manifest>
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "manifest.xml", .data = manifest_xml });
    try tmp.dir.createDirPath(io, "manifests");
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/extra.xml", .data = extra });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const manifest_path = try tmp.dir.realPathFileAlloc(io, "manifest.xml", arena.allocator());
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    const log = Logger{ .writer = &aw.writer };

    var manifest = try parseManifest(allocator, io, manifest_path, log);
    defer manifest.deinit();
    const projects = manifest.projects;

    try std.testing.expectEqual(@as(usize, 3), projects.len);
    try std.testing.expectEqualStrings("bsp/artinchip", projects[0].path);
    try std.testing.expectEqual(@as(usize, 1), projects[0].linkfiles.len);
    try std.testing.expectEqualStrings("a/b.h", projects[0].linkfiles[0].src);
    try std.testing.expectEqualStrings("include/b.h", projects[0].linkfiles[0].dest);
    try std.testing.expectEqualStrings("target", projects[1].path);
    try std.testing.expectEqualStrings("kernel/rt-thread", projects[2].path);
}
