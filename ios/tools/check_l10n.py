#!/usr/bin/env python3
"""List Chinese string literals in ios/BirdCM/*.swift that the compiler did not extract as localizable.

Needs a build first (SWIFT_EMIT_LOC_STRINGS writes *.stringsdata with each extracted literal's line and column):
  python3 ios/tools/check_l10n.py [DerivedData]      # default ios/DerivedData
A literal is fine when it was extracted (Text("…"), String(localized:), …) or is listed in ALLOWED below with the
reason; anything else is printed and the script exits 1. Comments are skipped.
"""
import json, re, sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
CJK = re.compile('[　-〿一-鿿＀-￯]')  # ideographs and full-width punctuation
# file: literals that stay Chinese on purpose, each with why. Internal keys are shown through LocalizedStringKey(…) or a
# lookup into the catalog where they reach the screen.
TIER = 'rarity tier: stored label and ThemeContrast key, shown through loc()'
STAGE = 'diagnostics stage key, shown through loc()'
EXIF = 'Shooting.fields key (Codable), shown through LocalizedStringKey'
PLACE = 'stored place label compared as identity, shown through Place.display / placeName'
BIRD = 'bird name (Debug fixture)'
ALLOWED = {
    'App.swift': {'地图选点': PLACE, '照片拍摄位置': PLACE, '当前位置': PLACE, '褐鹈鹕': BIRD, '数据不足': TIER, '检测': STAGE},
    'Engine.swift': {'裁剪与缩放': STAGE, '地点先验': STAGE, '名录、小头与查表': STAGE, '当前主体总计': STAGE, '数据不足': TIER},
    'Explore.swift': {w: TIER for w in ['无记录', '罕见', '少见', '不常见', '常见']},
    'Geo.swift': {**{w: TIER for w in ['常见', '不常见', '少见', '罕见', '不太可能']},
                  **{w: 'Season raw value, shown through LocalizedStringKey / loc()' for w in ['全年', '繁殖季', '非繁殖季']}},
    'Place.swift': {w: EXIF for w in ['相机', '镜头', '焦距', '光圈', '快门', '曝光补偿']},
    'Preview.swift': {**{w: BIRD for w in ['乌鸫', '红翅黑鹂', '大尾拟八哥', '白头海雕', '白尾海雕', '棕榈鬼鸮', '褐鹈鹕', '美洲白鹈鹕']},
                      '美国 · 加利福尼亚州': PLACE, '不常见': TIER, '常见': TIER, **{w: EXIF for w in ['相机', '焦距', '光圈', '快门', '曝光补偿']}},
    'Reference.swift': {w: 'cached reference card credit / changes, shown through loc()' for w in ['维基百科贡献者', '原文摘录；简体由维基百科自动转换', '原文摘录', '缩放为 640 px 宽']},
    'Rarity.swift': {w: TIER for w in ['数据不足', '未知', '时间未知', '无记录', '罕见', '少见', '不常见', '常见']},
    'ResultView.swift': {**{w: EXIF for w in ['相机', '镜头', '焦距', '光圈', '快门', '曝光补偿']}, '罕见': TIER, '少见': TIER,
                         '此地此季': 'picks an accessibility identifier for UI tests (run in zh-Hans)', '地图选点': PLACE},
    'Settings.swift': {'。. ': 'characters trimmed from an error message'},
    'Stats.swift': {w: TIER for w in ['无记录', '罕见', '少见', '不常见', '常见']},
    'Store.swift': {w: TIER for w in ['常见', '不常见', '少见', '罕见', '无记录']},
}


def literals(src):
    """(line, col, text) of every string literal outside comments; col is 1-based at the opening quote."""
    out, i, n, line, lstart = [], 0, len(src), 1, 0

    def string(i, line, lstart):
        multi = src.startswith('"""', i)
        q = '"""' if multi else '"'
        start_line, start_col = line, i - lstart + 1
        i += len(q); buf = []
        while i < n:
            c = src[i]
            if c == '\n': line += 1; lstart = i + 1
            if c == '\\' and i + 1 < n and src[i + 1] == '(':
                i, line, lstart = expr(i + 2, line, lstart); buf.append('\\(…)'); continue
            if c == '\\': buf.append(src[i:i + 2]); i += 2; continue
            if src.startswith(q, i):
                out.append((start_line, start_col, ''.join(buf))); return i + len(q), line, lstart
            buf.append(c); i += 1
        return i, line, lstart

    def expr(i, line, lstart):
        depth = 1
        while i < n and depth:
            c = src[i]
            if c == '"': i, line, lstart = string(i, line, lstart); continue
            if c == '\n': line += 1; lstart = i + 1
            depth += c == '('; depth -= c == ')'; i += 1
        return i, line, lstart

    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i); seg = src[i:j]; line += seg.count('\n')
            if '\n' in seg: lstart = i + seg.rfind('\n') + 1
            i = j + 2; continue
        if c == '"': i, line, lstart = string(i, line, lstart); continue
        if c == '\n': line += 1; lstart = i + 1
        i += 1
    return out


def main():
    dd = Path(sys.argv[1]) if len(sys.argv) > 1 else IOS / 'DerivedData'
    extracted = {}
    for f in dd.glob('Build/Intermediates.noindex/BirdCM.build/*/BirdCM.build/Objects-normal/*/*.stringsdata'):
        d = json.loads(f.read_text())
        for rows in d.get('tables', {}).values():
            for r in rows:
                loc = r['location']; extracted.setdefault(Path(d['source']).name, set()).add((loc['startingLine'], loc['startingColumn']))
    if not extracted:
        sys.exit(f'no .stringsdata under {dd}; build the BirdCM target first')
    bad = 0
    for f in sorted((IOS / 'BirdCM').glob('*.swift')):
        allowed, src = ALLOWED.get(f.name, {}), f.read_text()
        lines = src.split('\n')
        for line, col, text in literals(src):
            bcol = len(lines[line - 1][:col - 1].encode()) + 1  # the compiler counts UTF-8 bytes or characters
            if not CJK.search(text) or {(line, col), (line, bcol)} & extracted.get(f.name, set()) or text in allowed:
                continue
            bad += 1; print(f'{f.name}:{line}:{col}: "{text}"')
    print(f'{bad} unlocalized Chinese literal(s)')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
