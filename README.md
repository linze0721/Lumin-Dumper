# Lumin-Dumper

绿梦(时空之声,`com.zhuziplay.lvmengnew.op`)FairGuard 资源加密的**离线解密工具**,纯 Zig 实现(无 Python 依赖)。

## 原理

每个 UnityFS 容器的数据区前 1280 字节被逐文件密钥流 XOR([0,32) 掩码恒为 `0xB7`,[32,1280) 可变)。
密钥由**文件内容**派生,解密发生在 libFairGuard 内部(ARM64 rwxp 段,入口模块内偏移 `0x2c9a10`,
ABI: `x0`=数据区密文缓冲、`w1`=读取长度)。

本工具把该 rwxp 段(`fg_rwxp.bin`,4.27 MB,仓库自带)装入 Unicorn,从入口忠实重放整段解密逻辑,
即可离线对任意容器算出密钥流——不再需要运行游戏。

## 构建

```bash
# 需要 zig ≥0.16 与 libunicorn.so.2(unicorn 2.x,pip 装包内或系统安装均可)
zig build -Dunicorn-lib=/path/to/unicorn/lib
# 二进制在 zig-out/bin/lumin-dumper
```

## 使用

```bash
# 1) 自测 4 组 (密文,密钥流) 样本: 根目录须含 fg_rwxp.bin / ks_*.bin / yoo/ / du3d_orig.bin
./lumin-dumper keystream-test <工作区根>

# 2) 离线解密单个容器(数据区前 1280 字节 XOR 密钥流) → 输出 <容器>.dec
./lumin-dumper decrypt <容器.__data> [输出.dec]

# 3) 打印容器 UnityFS 头/块表/节点
./lumin-dumper info <容器>
```

## 直接批量导出全部表

解密 + 按块 LZ4 解压 + UnityPy 取 TextAsset,可用仓库 `helpers/` 里的 Python 辅助脚本
(纯分析脚本,不属于核心工具):

```bash
python3 helpers/extract_story.py <表目录> <输出目录>      # 剧情还原(每场一个 TXT + 全量 CSV)
python3 helpers/to_csv.py <表目录> <输出目录>            # 表 → CSV(Utf-8 BOM, Excel 直开)
python3 helpers/to_csv.py <textmap目录> <输出> --loc    # textmap → 四语对照 CSV
```

## 已验证

- `keystream-test`:4/4 组样本与运行时捕获的密钥流逐字节一致(cs000 / dll / assets / du3d)。
- 377 个 ClientStatic 容器全部离线解密成功(约 35 秒,对应 Lumin-Data 仓库的全部 374 张表)。

## 目录

```
src/main.zig       CLI 子命令与 UnityFS/info 集成
src/fgks.zig       Unicorn 重放 FairGuard 解密例程(核心)
src/unityfs.zig    UnityFS 头/块表/节点解析(含内置 LZ4 block 解压 src/lz4.zig)
src/posixio.zig    极薄 POSIX 文件封装(稳定 API)
fg_rwxp.bin        libFairGuard rwxp 段转储(自包含,勿删)
helpers/*.py       表→CSV、剧情→TXT/CSV 的辅助脚本(非核心)
```

## 法律

仅用于个人对该游戏的备份/复现研究;请勿用于商业用途或破坏任何第三方的技术保护措施。
