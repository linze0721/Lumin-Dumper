const std = @import("std");
const fgks = @import("fgks.zig");
const unityfs = @import("unityfs.zig");
const pio = @import("posixio.zig");

const usage =
    \\Lumin-Dumper —— 绿梦(时空之声) FairGuard 离线解密 / 剧情提取工具
    \\
    \\子命令:
    \\  keystream-test [根目录]          自测 4 组 (密文,密钥流) 样本
    \\  decrypt <容器> [输出.dec]        离线解密单个 UnityFS 容器(数据区前 1280 字节)
    \\  story <表目录> <输出目录>        从 dialogue*Datas + 文本表还原完整剧情(TXT+CSV)
    \\  info <容器>                      打印容器头/块表/节点
    \\
    \\依赖: libunicorn.so.2(构建期 -Dunicorn-lib= 目录,或系统安装)。
    \\依赖数据: fg_rwxp.bin(libFairGuard rwxp 段转储,仓库自带)。
    \\
;

fn join(a: []const u8, b: []const u8) []const u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ a, b }) catch "";
}

fn print(comptime f: []const u8, args: anytype) void {
    pio.stdoutWrite(std.heap.page_allocator, f, args);
}

fn initFg(alloc: std.mem.Allocator, root: []const u8) !void {
    const code = pio.readAlloc(alloc, join(root, "fg_rwxp.bin")) catch return error.FgRwxpMissing;
    try fgks.init(code);
}


fn keystreamTest(alloc: std.mem.Allocator, root: []const u8) !u8 {
    initFg(alloc, root) catch {
        print("缺 fg_rwxp.bin(应在 {s})", .{root});
        return 1;
    };
    const samples = [_]struct { ks: []const u8, ct: []const u8 }{
        .{ .ks = "ks_cs000.bin", .ct = "yoo/yoo/ClientStatic/BundleFiles/00/000de5ed11403d52ea24f5ef61a4108b/__data" },
        .{ .ks = "ks_dll.bin", .ct = "yoo/yoo/Dll/BundleFiles/e4/e4d84398a9fd9d65fad71e4ed6612989/__data" },
        .{ .ks = "ks_assets.bin", .ct = "yoo/yoo/Assets/BundleFiles/6a/6ada6720af3cba9ad9802f9a5be563b8/__data" },
        .{ .ks = "ks_du3d.bin", .ct = "du3d_orig.bin" },
    };
    var ok = true;
    for (samples) |s| {
            const ct = pio.readAlloc(alloc, join(root, s.ct)) catch {

            print("{s}: SKIP(缺文件)", .{s.ks});
            continue;
        };
        const ref = pio.readAlloc(alloc, join(root, s.ks)) catch continue;
        const ks = fgks.keystream(alloc, ct) catch {
            print("{s}: EMU FAIL", .{s.ks});
            ok = false;
            continue;
        };
        const m = @min(@as(usize, 1280), ref.len);
        const match = std.mem.eql(u8, ks[0..m], ref[0..m]);
        print("{s}: match {}", .{ s.ks, match });
        if (!match) ok = false;
    }
    return if (ok) 0 else 1;
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var it = init.args.iterate();
    var args = std.ArrayList([]const u8).empty;
    while (it.next()) |a| try args.append(alloc, a);
    const argv = args.items;
    if (argv.len < 2) {
        print("{s}", .{usage});
        return 2;
    }
    if (std.mem.eql(u8, argv[1], "keystream-test")) {
        const root = if (argv.len > 2) argv[2] else ".";
        return try keystreamTest(alloc, root);
    }
    if (std.mem.eql(u8, argv[1], "decrypt")) {
        if (argv.len < 3) {
            print("{s}", .{usage});
            return 2;
        }
        initFg(alloc, ".") catch {
            print("缺 fg_rwxp.bin(当前目录)", .{});
            return 1;
        };
        const data = pio.readAlloc(alloc, argv[1]) catch {
            print("读不到 {s}", .{argv[1]});
            return 1;
        };
        const out = try fgks.decryptBytes(alloc, data);
        const dst = if (argv.len > 3) argv[3] else try std.fmt.allocPrint(alloc, "{s}.dec", .{argv[2]});
        try pio.writeAll(dst, out);
        print("已解密 -> {s} ({d} 字节)", .{ dst, out.len });
        return 0;
    }
    if (std.mem.eql(u8, argv[1], "info")) {
        if (argv.len < 3) return 2;
        const data = pio.readAlloc(alloc, argv[2]) catch return 1;
        var c = try unityfs.parse(alloc, data);
        defer c.deinit();
        print("version={d} unity={s} rev={s} blocks={d} nodes={d} data_start={d}", .{
            c.version, c.unity_version, c.unity_revision, c.blocks.len, c.nodes.len, c.data_start,
        });
        return 0;
    }
    print("{s}", .{usage});
    return 2;
}

test "lz4 overlap" {
    _ = @import("lz4.zig");
}
