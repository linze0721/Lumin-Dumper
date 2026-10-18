#!/bin/sh
# 构建脚本: 需要 zig 与 libunicorn.so.2
zig build -Dunicorn-lib="${1:-../venv/lib/python3.14/site-packages/unicorn/lib}"
