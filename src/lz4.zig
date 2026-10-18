//! 最小 LZ4 block 格式解压(无依赖),对应 python lz4.block.decompress(data, uncompressed_size=n)。
const std = @import("std");

pub fn decompress(src: []const u8, dst: []u8) ![]u8 {
    var si: usize = 0;
    var di: usize = 0;
    while (si < src.len) {
        const token = src[si];
        si += 1;
        var lit_len: usize = token >> 4;
        if (lit_len == 15) {
            while (true) {
                if (si >= src.len) return error.Corrupt;
                const b = src[si];
                si += 1;
                lit_len += b;
                if (b != 255) break;
            }
        }
        if (si + lit_len > src.len or di + lit_len > dst.len) return error.Corrupt;
        @memcpy(dst[di..][0..lit_len], src[si..][0..lit_len]);
        si += lit_len;
        di += lit_len;
        if (si >= src.len) break; // 最后一块只有字面量
        if (si + 2 > src.len) return error.Corrupt;
        const offset = std.mem.readInt(u16, src[si..][0..2], .little);
        si += 2;
        if (offset == 0) return error.Corrupt;
        var match_len: usize = token & 0x0F;
        if (match_len == 15) {
            while (true) {
                if (si >= src.len) return error.Corrupt;
                const b = src[si];
                si += 1;
                match_len += b;
                if (b != 255) break;
            }
        }
        match_len += 4;
        if (offset > di) return error.Corrupt;
        var mpos = di - offset;
        if (di + match_len > dst.len) return error.Corrupt;
        var i: usize = 0;
        while (i < match_len) : (i += 1) { // 允许重叠(如 offset=1 的游程)
            dst[di] = dst[mpos];
            di += 1;
            mpos += 1;
        }
    }
    return dst[0..di];
}

test "lz4 roundtrip simple" {
    // 用 python 生成的样例在 fgks 测试里覆盖;这里只测游程重叠路径
    var buf: [64]u8 = undefined;
    const compressed = [_]u8{ 0x11, 'A', 0x10, 0x00 }; // 1 字面量 + 5 长度匹配 offset=1
    const out = try decompress(&compressed, &buf);
    try std.testing.expectEqualSlices(u8, "AAAAAA", out);
}
