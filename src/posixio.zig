//! 极薄 POSIX 文件封装: 避开 std.fs/std.io 在 0.16 的 Io 重构,接口保持稳定。
const std = @import("std");

const c = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 64;
const O_TRUNC: c_int = 512;

pub fn readAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), O_RDONLY);
    if (fd < 0) return error.FileNotFound;
    defer _ = c.close(fd);
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(alloc);
    var chunk: [1 << 20]u8 = undefined;
    while (true) {
        const r = c.read(fd, &chunk, chunk.len);
        if (r < 0) return error.ReadFailed;
        if (r == 0) break;
        try list.appendSlice(alloc, chunk[0..@intCast(r)]);
    }
    return try list.toOwnedSlice(alloc);
}

pub fn writeAll(path: []const u8, data: []const u8) !void {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const w = c.write(fd, data[off..].ptr, data.len - off);
        if (w <= 0) return error.WriteFailed;
        off += @intCast(w);
    }
}

pub fn makePath(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = makePathRaw(@ptrCast(&buf));
}

fn makePathRaw(p: [*:0]u8) bool {
    // 逐级 mkdir(忽略已存在)
    var i: usize = 0;
    while (p[i] != 0) : (i += 1) {
        if (p[i] == '/' and i > 0) {
            p[i] = 0;
            _ = mkdirRaw(p);
            p[i] = '/';
        }
    }
    return mkdirRaw(p);
}

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
fn mkdirRaw(p: [*:0]u8) bool {
    return mkdir(p, 0o755) == 0;
}

pub fn exists(path: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return false;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), 0); // O_RDONLY
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
}

pub fn stdoutWrite(alloc: std.mem.Allocator, comptime f: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, f, args) catch return;
    var off: usize = 0;
    while (off < s.len) {
        const w = c.write(1, s[off..].ptr, s.len - off);
        if (w <= 0) return;
        off += @intCast(w);
    }
}
