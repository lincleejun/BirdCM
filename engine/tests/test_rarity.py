import os
from pathlib import Path

import pytest

from birdcm import rarity

DB = Path("/Users/outman/workspace/personal/bioclip-bird/release/rarity-us-ca-cn.sqlite")


def test_region_key_label_and_point():
    assert rarity.region_key(0, 0, "美国 · 加利福尼亚州") == ("US", "California")
    assert rarity.region_key(0, 0, "日本") == ("JP", None)
    assert rarity.region_key(36.6, -121.9) == ("US", "California")           # Monterey
    assert rarity.region_key(39.9, 116.4) == ("CN", "Beijing")
    assert rarity.region_key(35.7, 139.7)[0] == "JP"                          # no divisions for Japan: country point


@pytest.mark.skipif(not DB.is_file(), reason="rarity table not here")
def test_lookup_against_the_research_self_check():
    r = rarity.Rarity(str(DB))
    assert r.lookup("Anas platyrhynchos", 36.6, -121.9, None, 11)["label"] == "常见"
    assert r.lookup("Not a bird", 36.6, -121.9, None, 11)["label"] == "未知"
    assert r.lookup("Anas platyrhynchos", 35.7, 139.7, None, 11)["label"] == "数据不足"     # Japan: not covered yet
    assert r.lookup("Anas platyrhynchos", None, None, None, 11)["label"] == "数据不足"
    assert r.lookup("Anas platyrhynchos", 36.6, -121.9, None, None)["label"] == "时间未知"
    x = r.lookup("Passer montanus", None, None, "中国 · 北京市", 5)
    assert x["label"] == "常见" and x["region"] == "CHN.2_1" and x["iucn"] == "LC"
