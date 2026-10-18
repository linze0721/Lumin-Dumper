#!/usr/bin/env python3
"""从 dialogue*Datas + textmap 还原完整剧情剧本。

用法: python3 tools/extract_story.py <表目录> <输出目录>
  表目录需含: dialogueAVGDatas / dialogueNPCAVGDatas / dialogueMissionAVGDatas (同结构),
              dialogueCharacterDatas(说话人), 以及 textmaps_csv/{MainStory,shortcommon}.csv
输出: <输出目录>/AVG_<组id>.txt 每场一个剧本 + <输出目录>/剧情全量.csv
"""
import csv
import json
import os
import sys


def load(p):
    return json.load(open(p, encoding='utf-8', errors='surrogateescape'))


def find_textmaps(src):
    cand = [os.path.join(src, 'textmaps_csv'), os.path.join(os.path.dirname(src), 'textmaps_csv'), src]
    for c in cand:
        if os.path.exists(os.path.join(c, 'MainStory.csv')):
            return c
    raise FileNotFoundError('textmaps_csv not found near ' + src)


def textmap(src, coll):
    p = os.path.join(find_textmaps(src), coll + '.csv')
    return {r['id']: r for r in csv.DictReader(open(p, encoding='utf-8-sig'))}


def main(argv):
    src, dst = argv[1], argv[2]
    os.makedirs(dst, exist_ok=True)
    main_txt = textmap(src, 'MainStory')
    short = textmap(src, 'shortcommon')
    chars = load(os.path.join(src, 'dialogueCharacterDatas.bytes'))

    def speaker_name(speaker_txt_id, speaker_id, is_player):
        if speaker_id:
            info = chars.get(str(speaker_id)) or {}
            nm = info.get('NameLocal')
            if nm:
                r = short.get(str(nm))
                if r:
                    return r['key']
            return str(speaker_id)
        if speaker_txt_id:
            r = short.get(str(speaker_txt_id))
            if r:
                return r['key']
        return ''

    groups = {}
    for tab in ('dialogueAVGDatas', 'dialogueNPCAVGDatas', 'dialogueMissionAVGDatas'):
        p = os.path.join(src, tab + '.bytes')
        if not os.path.exists(p):
            continue
        d = load(p)
        for rid, r in d.items():
            gid = int(rid) // 1000
            groups.setdefault(gid, []).append((tab, int(rid), r))
    allrows = []
    nfiles = 0
    for gid in sorted(groups):
        lines = sorted(groups[gid], key=lambda x: x[1])
        body = []
        for tab, rid, r in lines:
            who = speaker_name(r.get('Speaker'), r.get('SpeakerId'), r.get('SpeakerIsPlayer'))
            tm = main_txt.get(str(r.get('Content')))
            txt = (tm or {}).get('key') or (short.get(str(r.get('Content'))) or {}).get('key') or ''
            if not txt:
                txt = (tm or {}).get('zh') or ''
            txt = txt.replace('<playername/>', '主角')
            if who:
                body.append('【%s】%s' % (who, txt))
            else:
                body.append(txt)
            allrows.append((gid, tab, rid, who, txt))
        if not any(l.strip() for l in body):
            continue
        open(os.path.join(dst, 'AVG_%d.txt' % gid), 'w', encoding='utf-8').write(
            '第%d场(%d 句)\n\n' % (gid, len(body)) + '\n'.join(body) + '\n')
        nfiles += 1
    with open(os.path.join(dst, '剧情全量.csv'), 'w', newline='', encoding='utf-8-sig') as w:
        wr = csv.writer(w)
        wr.writerow(['场', '来源表', '行Id', '说话人', '台词'])
        wr.writerows(allrows)
    print('场数 %d,台词 %d 条 -> %s' % (nfiles, len(allrows), dst))


if __name__ == '__main__':
    sys.exit(main(sys.argv))
