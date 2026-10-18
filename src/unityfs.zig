//! UnityFS 容器头/块表/节点解析(与 tools/unityfs.py 逐字节对齐,大端字段)。
const std = @import("std");
const lz4 = @import("lz4.zig");

pub const Block = struct { us: u32, cs: u32, flags: u16 };
pub const Node = struct { off: i64, size: i64, flags: u32, name: []const u8 };

pub const Container = struct {
    version: u32,
    unity_version: []const u8,
    unity_revision: []const u8,
    size: i64,
    cib: u32,
    ubi: u32,
    flags: u32,
    info_off: usize,
    data_start: usize,
    blocks: []Block,
    nodes: []Node,
    /// 解析期间分配的内存(含 info 解压缓冲与字符串),调用方负责释放
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Container) void {
        self.arena.deinit();
    }
};

fn readCstr(data: []const u8, o: *usize) ![]const u8 {
    if (o.* >= data.len) return error.Corrupt;
    const end = std.mem.indexOfScalarPos(u8, data, o.*, 0) orelse return error.Corrupt;
    const s = data[o.*..end];
    o.* = end + 1;
    return s;
}

/// 只需容器头部前 ~info_off+cib 字节;blocksInfo 需要解压时给全 head(建议 ≥1MB)。
pub fn parse(alloc: std.mem.Allocator, head: []const u8) !Container {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (head.len < 8 or !std.mem.eql(u8, head[0..8], "UnityFS\x00")) return error.NotUnityFS;
    var o: usize = 8;
    const ver = std.mem.readInt(u32, head[o..][0..4], .big);
    o += 4;
    const uver = try readCstr(head, &o);
    const urev = try readCstr(head, &o);
    const size = std.mem.readInt(i64, head[o..][0..8], .big);
    o += 8;
    const cib = std.mem.readInt(u32, head[o..][0..4], .big);
    o += 4;
    const ubi = std.mem.readInt(u32, head[o..][0..4], .big);
    o += 4;
    const flags = std.mem.readInt(u32, head[o..][0..4], .big);
    o += 4;
    if (flags & 0x80 != 0) o += 16;
    const info_off = (o + 15) & ~@as(usize, 15);
    if (info_off + cib > head.len) return error.NeedMoreBytes;
    const info_raw = head[info_off..][0..cib];
    const info = if (flags & 0x40 != 0)
        try lz4.decompress(info_raw, try a.alloc(u8, ubi))
    else
        info_raw;
    if (info.len < 20) return error.Corrupt;
    var p: usize = 16; // 与 python 一致:跳过 info 头 16 字节
    const nblocks = std.mem.readInt(u32, info[p..][0..4], .big);
    p += 4;
    const blocks = try a.alloc(Block, nblocks);
    for (blocks) |*bl| {
        bl.us = std.mem.readInt(u32, info[p..][0..4], .big);
        bl.cs = std.mem.readInt(u32, info[p..][0..4], .big);
        bl.flags = std.mem.readInt(u16, info[p..][0..2], .big);
        p += 10;
    }
    const nnodes = std.mem.readInt(u32, info[p..][0..4], .big);
    p += 4;
    const nodes = try a.alloc(Node, nnodes);
    for (nodes) |*nd| {
        nd.off = std.mem.readInt(i64, info[p..][0..8], .big);
        p += 8;
        nd.size = std.mem.readInt(i64, info[p..][0..8], .big);
        p += 8;
        nd.flags = std.mem.readInt(u32, info[p..][0..4], .big);
        p += 4;
        nd.name = try a.dupe(u8, try readCstr(info, &p));
    }
    return .{
        .version = ver,
        .unity_version = try a.dupe(u8, uver),
        .unity_revision = try a.dupe(u8, urev),
        .size = size,
        .cib = cib,
        .ubi = ubi,
        .flags = flags,
        .info_off = info_off,
        .data_start = (info_off + cib + 15) & ~@as(usize, 15),
        .blocks = blocks,
        .nodes = nodes,
        .arena = arena,
    };
}
