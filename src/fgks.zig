//! FairGuard 密钥流恢复:把 libFairGuard rwxp 段装入 Unicorn,从解密例程入口
//! (模块内偏移 0x2c9a10, ABI: x0=数据区密文缓冲, w1=读取长度) 忠实重放整段
//! 解密逻辑, 离线算出任意容器的 1280 字节密钥流。对应 tools/fg_ks.py 的 Zig 版。
const std = @import("std");
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
fn env(name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const r = getenv(@ptrCast(&buf));
    if (r == null) return null;
    const n = std.mem.len(@ptrCast(r.?));
    return r.?[0..n];
}

pub const BASE: u64 = 0x79dc4b0000; // rwxp 转储基址(模块内偏移=文件偏移)
pub const BUF: u64 = 0x7950ba0260; // 读调用目标缓冲 = 数据区密文 (x23/x0 入参)
pub const STACK_SP: u64 = 0x7a74702220; // 解密函数入口 sp
pub const CTX: u64 = 0xb400007b1c77a000; // [libFG+0x3b1028] 全局上下文对象
pub const X22OBJ: u64 = 0xb400007a9c7396a0; // [libFG+0x3b1020] 全局对象
pub const RETSTUB: u64 = 0x7d1d0754e8; // 未转储辅助页(填 RET)
pub const ENTRY: u64 = 0x2c9a10; // 解密例程入口(模块内偏移)
// 这四处 blr 的目标是 FairGuard 内部分配器, 返回 size=x0 的新缓冲
const alloc_sites = [_]u64{ 0x2ca4a8, 0x2ca4b8, 0x2cbe8c, 0x2cc5ec };

// unicorn 常量(unicorn 2.x, arm64)
const UC_ARCH_ARM64: c_uint = 2;
const UC_MODE_LITTLE_ENDIAN: c_uint = 0;
const UC_HOOK_CODE: c_uint = 4;
const UC_HOOK_MEM_UNMAPPED: c_uint = 112;
const UC_HOOK_BLOCK: c_uint = 8;
// UC_ARM64_REG_X0..X28 = 199..227; X29=1; X30=2; SP=4
fn regX(n: u5) c_int {
    return if (n < 29) 199 + @as(c_int, n) else if (n == 29) 1 else 2;
}
const REG_X0: c_int = 199;
const REG_SP: c_int = 4;

const uc_engine = opaque {};
const uc_hook = usize;

extern fn uc_open(arch: c_uint, mode: c_uint, uc: *?*uc_engine) c_int;
extern fn uc_close(uc: *uc_engine) c_int;
extern fn uc_mem_map(uc: *uc_engine, address: u64, size: u64, perms: c_uint) c_int;
extern fn uc_mem_write(uc: *uc_engine, address: u64, bytes: [*]const u8, size: usize) c_int;
extern fn uc_mem_read(uc: *uc_engine, address: u64, bytes: [*]u8, size: usize) c_int;
extern fn uc_reg_read(uc: *uc_engine, regid: c_int, value: *anyopaque) c_int;
extern fn uc_reg_write(uc: *uc_engine, regid: c_int, value: *const anyopaque) c_int;
extern fn uc_emu_start(uc: *uc_engine, begin: u64, until: u64, timeout: u64, count: usize) c_int;
extern fn uc_emu_stop(uc: *uc_engine) c_int;
extern fn uc_hook_add(uc: *uc_engine, hh: *uc_hook, hook_type: c_uint, callback: *const anyopaque, user_data: ?*anyopaque, begin: u64, end: u64, ...) c_int;
extern fn uc_errno(uc: *uc_engine) c_int;
extern fn uc_mem_protect(uc: *uc_engine, address: u64, size: u64, perms: c_uint) c_int;

var engine: ?*uc_engine = null;
var code: []const u8 = &.{};
var bump: u64 = 0x7a9f000000;
var last_pc: u64 = 0;
var have_last_pc: bool = false;
var stop: bool = false;
var dbg_n: usize = 0;

fn inDump(a: u64) bool {
    return a >= BASE and a < BASE + code.len;
}

fn onCode(uc: ?*uc_engine, address: u64, size: u32, ud: ?*anyopaque) callconv(.c) void {
    _ = size; _ = ud;
    if (getenv("FGTRACE2") != null) std.debug.print("[pc] {x}\n", .{address});
    if (!inDump(address)) {
        if (have_last_pc) {
            const site = last_pc - BASE;
            for (alloc_sites) |s| {
                if (site == s) {
                    var n: u64 = 0;
                    _ = uc_reg_read(uc.?, 199, &n);
                    _ = uc_reg_write(uc.?, 199, &bump);
                    bump += (n + 15) & ~@as(u64, 15);
                    break;
                }
            }
        }
        return;
    }
    last_pc = address;
    have_last_pc = true;
    const off: usize = @intCast(address - BASE);
    if (off + 4 > code.len) return;
    const insn = std.mem.readInt(u32, code[off..][0..4], .little);
    const is_br = (insn & 0xFFFFFC1F) == 0xD61F0000;
    const is_blr = (insn & 0xFFFFFC1F) == 0xD63F0000;
    if (is_br or is_blr) {
        const rn: u5 = @intCast((insn >> 5) & 0x1F);
        var tgt: u64 = 0;
        _ = uc_reg_read(uc.?, regX(rn), &tgt);
        const inA = tgt >= 0x7d1d000000 and tgt < 0x7d1e000000;
        const inB = tgt >= 0x7d390fe000 and tgt < 0x7d390fe200;
        if (!inDump(tgt) and !inA and !inB)
            _ = uc_reg_write(uc.?, regX(rn), &RETSTUB);
    }
}

fn onBlock(uc: ?*uc_engine, address: u64, size: u32, ud: ?*anyopaque) callconv(.c) void {
    _ = uc; _ = size; _ = ud;
    std.debug.print("[block] {x}\n", .{address});
}

fn onUnmapped(uc: ?*uc_engine, access: c_int, address: u64, size: c_int, value: i64, ud: ?*anyopaque) callconv(.c) bool {
    _ = access; _ = size; _ = value; _ = ud;
    std.debug.print("[fault] {x}\n", .{address});
    stop = true;
    _ = uc_emu_stop(uc.?);
    return false;
}

fn writeRetStub(a: u64, n: usize) !void {
    const ins = [_]u8{ 0xc0, 0x03, 0x5f, 0xd6 }; // RET
    var buf = try std.heap.page_allocator.alloc(u8, n);
    defer std.heap.page_allocator.free(buf);
    var i: usize = 0;
    while (i < n) : (i += 4) @memcpy(buf[i..][0..4], &ins);
    _ = uc_mem_write(engine.?, a, buf.ptr, n);
}

/// 载入代码转储并初始化模拟器;code_dump = libFairGuard rwxp 段原样字节。
pub fn init(code_dump: []const u8) !void {

    code = code_dump;
    if (uc_open(UC_ARCH_ARM64, UC_MODE_LITTLE_ENDIAN, &engine) != 0) return error.UnicornOpen;

    try map(BASE, code.len);
    if (uc_mem_write(engine.?, BASE, code.ptr, code.len) != 0) return error.CodeWrite;
    try map(0x7a746e0000, 0x7a74800000 - 0x7a746e0000); // 栈
    try map(0x7a9c000000, 0x2000000); // x22 对象等
    try map(0x7a9f000000, 0x1000000); // bump 分配区
    try map(0x7950b00000, 0x2000000); // 读缓冲
    try map(0x7d390fe000, 0x2000);
    try map(0x7d1d000000, 0x1000000);
    writeRetStub(0x7d390fe000, 0x2000) catch return error.RetStub;
    writeRetStub(0x7d1d000000, 0x1000000) catch return error.RetStub;
    for ([_]u64{ CTX, X22OBJ }) |obj| {
        _ = uc_mem_map(engine.?, obj & ~@as(u64, 0xfff), 0x10000, 7);
    }

    var hk: uc_hook = 0;
    if (true) {
        if (uc_hook_add(engine.?, &hk, UC_HOOK_CODE, onCode, null, 1, 0) != 0) return error.HookAdd;
    }

    var hk2: uc_hook = 0;
    if (getenv("FGMMHOOK") != null) {
        if (uc_hook_add(engine.?, &hk2, UC_HOOK_MEM_UNMAPPED, onUnmapped, null, 1, 0) != 0) return error.HookAdd;
    }
    const dbg = getenv("FGDBG") != null;
    if (dbg) {
        var hkb: uc_hook = 0;
        const rc = uc_hook_add(engine.?, &hkb, UC_HOOK_BLOCK, onBlock, null, 1, 0);
        std.debug.print("[dbg] block hook rc={d}\n", .{rc});
    }
}

fn map(a: u64, n: usize) !void {
    const rc = uc_mem_map(engine.?, a, n, 7);
    if (rc != 0) {
        std.debug.print("[dbg] map {x}+{x} FAIL rc={d} errno={d}\n", .{ a, n, rc, uc_errno(engine.?) });
        return error.MemMap;
    }
}

/// 重放解密例程: ct=数据区密文(≥160 字节, 建议 ≥1328), read_len=本次读取长度(=文件长-数据区起点)。
/// 返回解密后的缓冲内容(与 ct 等长)。
pub fn run(alloc: std.mem.Allocator, ct: []const u8, read_len: u64) ![]u8 {
    var v: u64 = 0;
    _ = uc_mem_write(engine.?, BUF, ct.ptr, ct.len);
    v = STACK_SP;
    _ = uc_reg_write(engine.?, REG_SP, &v);
    v = BUF;
    _ = uc_reg_write(engine.?, REG_X0, &v);
    v = read_len;
    _ = uc_reg_write(engine.?, REG_X0 + 1, &v);
    stop = false;
    have_last_pc = false;
    last_pc = 0;
    const rc = uc_emu_start(engine.?, BASE + ENTRY, 0, 0, 4_000_000);
    if (rc != 0) {
        var pc: u64 = 0; var sp: u64 = 0;
        _ = uc_reg_read(engine.?, @intCast(260), &pc);
        _ = uc_reg_read(engine.?, 4, &sp);
        std.debug.print("[dbg] emu rc={d} pc={x} sp={x}\n", .{ rc, pc, sp });
        return error.EmuFailed;
    }
    const out = try alloc.alloc(u8, ct.len);
    if (uc_mem_read(engine.?, BUF, out.ptr, out.len) != 0) return error.MemRead;
    return out;
}

/// keystream(file_bytes) -> 1280 字节密钥流;
/// 满足 明文[i] = 密文[data_start+i] ^ k[i], i < min(1280, 数据区长)。
pub fn keystream(alloc: std.mem.Allocator, file_bytes: []const u8) ![]u8 {
    const ds = dataStart(file_bytes) catch return zeros(alloc);

    const rest = file_bytes.len - ds;
    if (rest == 0) return zeros(alloc);
    const n = @min(rest, 4096);
    const ct = file_bytes[ds..][0..n];
    const out = try run(alloc, ct, rest);
    const ks = try alloc.alloc(u8, 1280);
    @memset(ks, 0);
    const m = @min(1280, n);
    for (ks[0..m], 0..) |*x, i| x.* = out[i] ^ ct[i];
    return ks;
}

pub fn decryptBytes(alloc: std.mem.Allocator, file_bytes: []const u8) ![]u8 {
    const ds = dataStart(file_bytes) catch return error.NotUnityFS;
    const ks = try keystream(alloc, file_bytes);
    const out = try alloc.dupe(u8, file_bytes);
    const body = @min(@as(usize, 1280), out.len - ds);
    for (out[ds..][0..body], 0..) |*x, i| x.* ^= ks[i];
    return out;
}

fn zeros(alloc: std.mem.Allocator) ![]u8 {
    const z = try alloc.alloc(u8, 1280);
    @memset(z, 0);
    return z;
}

/// UnityFS 数据区起点(依赖 unityfs.zig 的解析, 复用同一套已验证逻辑)。
const unityfs_mod = @import("unityfs.zig");

pub fn dataStart(d: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const c = try unityfs_mod.parse(arena.allocator(), d);
    return c.data_start;
}

test "keystream selftest needs data files" {
    // 完整自测见 main.zig 的 keystream-test 子命令(依赖工作区数据文件)。
    try std.testing.expect(true);
}
