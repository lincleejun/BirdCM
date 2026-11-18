"""The range rule (confirm.py) and Lightroom variant pairing."""
import numpy as np
import pytest

from birdcm import confirm, models


def look(names, ps, level="species", genus_p=0.99):
    top5 = [{"sci": s, "en": s, "zh": None, "p": p} for s, p in zip(names, ps)]
    gen = names[0].split(" ")[0]
    return {"top5": top5, "level": level, "label": top5[0] if level == "species" else None,
            "genus": {"sci": gen + " sp.", "en": None, "zh": None, "p": genus_p},
            "visual": top5[0], "_ids": list(range(len(names)))}


def test_expected_somewhere_but_not_over_most_of_the_place_is_flagged():
    lk = confirm.decide(look(["Tyrannus melancholicus", "Tyrannus couchii"], [0.99, 0.01]), np.array([0.15, 0.002]), np.array([0.016, 0.0]))
    assert lk["level"] == "species" and lk["check"] == "rare" and "override" not in lk


def test_expected_over_the_place_is_plain():
    lk = confirm.decide(look(["A b", "A c"], [0.99, 0.01]), np.array([0.5, 0.5]), np.array([0.2, 0.2]))
    assert lk["level"] == "species" and "check" not in lk


def test_not_expected_anywhere_is_not_confirmed_and_says_why_without_reordering():
    lk = confirm.decide(look(["Haliaeetus albicilla", "Haliaeetus leucocephalus"], [0.998, 0.002]),
                        np.array([0.0, 0.6]), np.array([0.0, 0.4]))
    assert lk["level"] == "genus" and lk["label"]["sci"] == "Haliaeetus sp."
    assert [c["sci"] for c in lk["top5"]] == ["Haliaeetus albicilla", "Haliaeetus leucocephalus"]   # order kept
    assert lk["override"]["visual"]["sci"] == "Haliaeetus albicilla" and lk["override"]["local"]["sci"] == "Haliaeetus leucocephalus"


def test_unmapped_species_is_prior_unknown_not_absent():
    """Codex C2: a species the geo model does not list (NaN) is not vetoed as "not here"."""
    lk = confirm.decide(look(["Anas laysanensis", "Anas platyrhynchos"], [0.97, 0.02]), np.array([np.nan, 0.6]), np.array([np.nan, 0.5]))
    assert lk["level"] == "species" and lk["prior"] == {"unknown": True} and "override" not in lk and "check" not in lk


try:
    _P = models.paths()
except FileNotFoundError:
    _P = None


@pytest.mark.skipif(_P is None or "geo" not in (_P or {}), reason="geo model not installed")
def test_california_november_real_prior():
    """Regression: the impossible names seen on a California batch stay unconfirmed; a Tropical Kingbird (a scarce
    but regular autumn visitor on the coast) stays a species with the flag, even with the region's centroid in the
    Sierra Nevada."""
    from birdcm import geo
    sci = [str(s) for s in np.load(_P["names"])["scientific"]]
    g = geo.Geo(str(_P["geo"]), sci)
    wide, typical = g.spread(37.2, -119.5, "2026-11-14T10:00:00", "region", "美国 · 加利福尼亚州")
    for bad in ("Xenopsaris albinucha", "Pelecanus philippensis", "Gelochelidon macrotarsa", "Agelasticus thilius",
                "Toxostoma cinereum"):
        i = sci.index(bad)
        lk = look([bad, "Zz zz"], [0.97, 0.01])
        lk["_ids"] = [i, 0]
        assert confirm.decide(lk, wide, typical)["level"] != "species", bad
    i = sci.index("Tyrannus melancholicus")
    lk = look(["Tyrannus melancholicus", "Tyrannus couchii"], [1.0, 0.0])
    lk["_ids"] = [i, sci.index("Tyrannus couchii")]
    out = confirm.decide(lk, wide, typical)
    assert out["level"] == "species" and out["check"] == "rare"
    # a point on the coast (the Bay Area): the geo model expects it there in November, so confirmed without the flag
    wide, typical = g.spread(37.32, -122.02, "2026-11-14T10:00:00", "device")
    lk = look(["Tyrannus melancholicus", "Tyrannus couchii"], [1.0, 0.0])
    lk["_ids"] = [i, sci.index("Tyrannus couchii")]
    out = confirm.decide(lk, wide, typical)
    assert out["level"] == "species" and "check" not in out


def test_lightroom_variants_pair_with_their_raw(tmp_path):
    from birdcm.decode import pair_variants
    names = ["A1.ARW", "A1-Enhanced-NR.dng", "A2.ARW", "A2-HDR.dng", "B3-Enhanced-NR.dng", "C4.dng", "C4-Enhanced.dng"]
    ps = [tmp_path / n for n in names]
    for p in ps:
        p.write_bytes(b"x")
    shots, var = pair_variants(ps)
    assert [p.name for p in shots] == ["A1.ARW", "A2.ARW", "A2-HDR.dng", "B3-Enhanced-NR.dng", "C4.dng"]
    assert var == {str(tmp_path / "A1.ARW"): [str(tmp_path / "A1-Enhanced-NR.dng")], str(tmp_path / "C4.dng"): [str(tmp_path / "C4-Enhanced.dng")]}
    ex = {str(tmp_path / "A1.ARW"): {"taken_at": "2026-11-14T10:00:00.12", "camera": "X"},
          str(tmp_path / "A1-Enhanced-NR.dng"): {"taken_at": "2026-11-14T10:00:00", "camera": "X"},
          str(tmp_path / "C4.dng"): {"taken_at": "2026-11-14T10:00:00", "camera": "X"},
          str(tmp_path / "C4-Enhanced.dng"): {"taken_at": "2026-11-14T11:00:00", "camera": "X"}}       # another shot
    shots, var = pair_variants(ps, lambda paths: ex)
    assert list(var) == [str(tmp_path / "A1.ARW")] and tmp_path / "C4-Enhanced.dng" in shots


def test_variants_are_stored_on_the_shot(tmp_path):
    from birdcm.store import Store
    st = Store(tmp_path / "t.db")
    sid = st.create_scan(str(tmp_path), False, None, {}, "fp", [("/x/A1.ARW", 1, 1), ("/x/A2.ARW", 1, 1)], {"/x/A1.ARW": ["/x/A1-Enhanced-NR.dng"]})
    ph = {p["file"]: p for p in st.snapshot(sid)["photos"]}
    assert ph["A1.ARW"]["variants"] == ["/x/A1-Enhanced-NR.dng"] and ph["A2.ARW"]["variants"] == [] and len(ph) == 2
