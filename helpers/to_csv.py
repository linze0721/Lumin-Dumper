#!/usr/bin/env python3
"""把 dump 出的配置表与 textmap 转成人类可读格式(CSV, UTF-8-BOM, Excel 直接打开)。

用法:
  python3 tools/to_csv.py cs_tables cs_tables_csv                     # 配置表 -> 每表一个 CSV
  python3 tools/to_csv.py cs_tables_localization textmaps_csv --loc   # textmap -> 每集合一个四语对照 CSV
表格式: JSON dict{ id -> row } 或 list[row];行内嵌套值压成紧凑 JSON 字符串列。
textmap: <集合> Shared Data.json 的 m_Entries 提供 id->key,与各语言 m_TableData(id->m_Localized)按 id 合并。
"""
import csv
import json
import os
import sys


def flat_row(row):
    out = {}
    for k, v in row.items():
        if isinstance(v, (dict, list)):
            out[k] = json.dumps(v, ensure_ascii=False, separators=(',', ':'))
        else:
            out[k] = v
    return out


def tables_to_csv(src, dst):
    os.makedirs(dst, exist_ok=True)
    n = 0
    for f in sorted(os.listdir(src)):
        if not f.endswith('.bytes'):
            continue
        data = json.load(open(os.path.join(src, f), encoding='utf-8', errors='surrogateescape'))
        if isinstance(data, dict) and data and all(isinstance(v, dict) for v in data.values()):
            items = [(k, v) for k, v in data.items()]
        elif isinstance(data, dict):
            # 异构键值表(标量/列表/字典混合):两列 id,value(嵌套值 JSON 编码)
            rows = [(k, {'value': json.dumps(v, ensure_ascii=False, separators=(',', ':'))}) for k, v in data.items()]
            cols = ['value']
            name = f[:-6]
            with open(os.path.join(dst, name + '.csv'), 'w', newline='', encoding='utf-8-sig') as w:
                wr = csv.writer(w)
                wr.writerow(['id'] + cols)
                for k, r in rows:
                    wr.writerow([k] + [r.get(c, '') for c in cols])
            n += 1
            continue
        elif isinstance(data, list):
            items = [(str(i), v) for i, v in enumerate(data) if isinstance(v, dict)]
        else:
            continue
        rows = [(k, flat_row(v)) for k, v in items]
        cols = []
        for _, r in rows:
            for c in r:
                if c not in cols:
                    cols.append(c)
        name = f[:-6]
        with open(os.path.join(dst, name + '.csv'), 'w', newline='', encoding='utf-8-sig') as w:
            wr = csv.writer(w)
            wr.writerow(['id'] + cols)
            for k, r in rows:
                wr.writerow([k] + [r.get(c, '') for c in cols])
        n += 1
    return n


def loc_to_csv(src, dst):
    os.makedirs(dst, exist_ok=True)
    shared = {}
    for f in sorted(os.listdir(src)):
        if f.endswith('.json') and 'Shared Data' in f:
            coll = f[:-len(' Shared Data.json')]
            d = json.load(open(os.path.join(src, f), encoding='utf-8', errors='surrogateescape'))
            shared[coll] = {str(e.get('m_Id')): e.get('m_Key', '') for e in (d.get('m_Entries') or [])}
    langs = [('zh', '_zh.json'), ('en', '_en.json'), ('ja', '_ja.json')]
    n = 0
    for coll, keys in shared.items():
        table = {}
        for tag, suf in langs:
            p = os.path.join(src, coll + suf)
            if not os.path.exists(p):
                continue
            d = json.load(open(p, encoding='utf-8', errors='surrogateescape'))
            for e in d.get('m_TableData') or []:
                table.setdefault(str(e.get('m_Id')), {})[tag] = e.get('m_Localized', '')
        with open(os.path.join(dst, coll + '.csv'), 'w', newline='', encoding='utf-8-sig') as w:
            wr = csv.writer(w)
            wr.writerow(['id', 'key', 'zh', 'en', 'ja'])
            for i in sorted(keys, key=lambda x: int(x) if x.isdigit() else 0):
                t = table.get(i, {})
                wr.writerow([i, keys[i], t.get('zh', ''), t.get('en', ''), t.get('ja', '')])
        n += 1
    return n


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    if '--loc' in argv:
        n = loc_to_csv(src, dst)
        print('textmap CSV written:', n, '->', dst)
    else:
        n = tables_to_csv(src, dst)
        print('table CSV written:', n, '->', dst)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
