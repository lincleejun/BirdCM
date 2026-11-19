import sys
from birdcm import rarity, value
t = rarity.Rarity(sys.argv[1])
for sci, reg, m, label, photo in [("Pyrocephalus rubinus", "US-CA", 11, "朱红霸鹟 Cupertino（期望 8.5–9.5）", False),
        ("Haliaeetus albicilla", "CN-LN", 1, "白尾海雕 大连冬季（期望 6–7.5）", False),
        ("Haliaeetus albicilla", "US-CA", 11, "白尾海雕 Cupertino 拍到（期望 9–10）", True),
        ("Pica serica", "US-CA", 11, "喜鹊 加州 搜索", False), ("Pica serica", "US-CA", 11, "喜鹊 加州 拍到", True),
        ("Passer domesticus", "US-CA", 11, "家麻雀 加州", False), ("Calcarius pictus", "US-CA", 11, "斯氏铁爪鹀 加州", False),
        ("Gymnogyps californianus", "US-CA", 11, "加州神鹫 加州", False), ("Gymnogyps californianus", None, None, "加州神鹫 不选地点", False)]:
    v = value.value(t, sci, reg, m, photo)
    print(f"{label:30s} base {v['base']:.2f} regional {'—' if v['regional'] is None else format(v['regional'], '.2f')} {v['status']}")
