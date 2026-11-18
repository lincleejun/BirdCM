"""eBird Record Format export."""
from birdcm import ebird

GOLDEN = ("Tropical Kingbird,Tyrannus,melancholicus,X,,California US,,,11/14/2026,10:02,CA,US,Incidental,,,N,,,"
          "From BirdCM photo review (2 photos); not a complete count\n")


def photo(i, sci, t, en=None, gps=None, level="species", rejected=False, boxes=1, stars=1, fix=None):
    lab = {"sci": sci, "en": en or sci, "zh": None, "p": 0.99}
    sp = {"level": level, "label": lab, "top5": [lab]}
    return {"id": i, "path": f"/x/DSC{i:05d}.ARW", "stars": stars, "species_fix": fix,
            "result": {"rejected": rejected, "species": sp, "exif": {"taken_at": t, "gps": gps},
                       "boxes": [{"box": [0, 0, 1, 1], "clear": True, "species": sp}] * boxes}}


REGION = {"label": "美国 · 加利福尼亚州", "lat": 37.2, "lon": -119.5, "source": "region"}


def test_golden_row_column_order_and_formats():
    ps = [photo(1, "Tyrannus melancholicus", "2026-11-14T10:02:31"), photo(2, "Tyrannus melancholicus", "2026-11-14T10:40:00")]
    assert ebird.record_csv(ps, REGION, ["Tyrannus melancholicus"]) == GOLDEN
    assert GOLDEN.count(",") == 18                                   # 19 columns
    assert not GOLDEN.startswith("﻿") and '"' not in GOLDEN     # no BOM, no quotation marks


def test_stationary_has_duration_and_observers():
    ps = [photo(1, "Tyrannus melancholicus", "2026-11-14T10:02:31"), photo(2, "Tyrannus melancholicus", "2026-11-14T10:40:00")]
    row = ebird.record_csv(ps, REGION, ["Tyrannus melancholicus"], protocol="Stationary").split(",")
    assert row[12] == "Stationary" and row[13] == "1" and row[14] == "38" and row[15] == "N"


def test_days_and_places_make_separate_checklists_and_selection_applies():
    ps = [photo(1, "Thalasseus elegans", "2026-11-14T09:00:00"), photo(2, "Thalasseus elegans", "2026-11-15T09:00:00"),
          photo(3, "Thalasseus elegans", "2026-11-15T10:00:00", gps=[37.43, -122.08]),
          photo(4, "Calypte anna", "2026-11-14T09:30:00")]
    rows = ebird.record_csv(ps, REGION, ["Thalasseus elegans"]).strip().split("\n")
    assert len(rows) == 3 and all(r.startswith("Elegant Tern,") for r in rows)
    gps_row = [r for r in rows if "37.43000" in r][0].split(",")
    assert gps_row[6] == "37.43000" and gps_row[7] == "-122.08000" and gps_row[10] == "CA" and gps_row[11] == "US"


def test_counts_comments_genus_and_escaping():
    ps = [photo(1, "Accipiter cooperii", "2026-11-14T09:00:00", en="Cooper's Hawk, adult", boxes=2),
          photo(2, "Tyrannus sp.", "2026-11-14T09:05:00", level="genus")]
    pl = ebird.plan(ps, REGION)
    assert pl["species"][0]["max_in_frame"] == 2 and pl["species"][1]["name_check"] == "genus"
    out = ebird.record_csv(ps, REGION, ["Accipiter cooperii"], counts={"Accipiter cooperii": "2"},
                           comments={"Accipiter cooperii": 'perched, "calling"\non a pole'}, with_files=True)
    f = out.strip().split(",")
    assert len(f) == 19 and f[3] == "2" and '"' not in out and "\n" not in out.strip()
    assert f[4] == "perched calling on a pole photos: DSC00001.ARW"
    assert "Tyrannus" not in out                                       # genus-only only when chosen
    assert ebird.record_csv(ps, REGION, ["Tyrannus sp."]).split(",")[:3] == ["", "Tyrannus", "sp."]


def test_burst_correction_wins_and_rejected_confirmed_photos_count():
    fix = {"level": "species", "label": {"sci": "Thalasseus elegans", "en": "Elegant Tern", "zh": None, "p": 0.4}}
    ps = [photo(1, "Thalasseus maximus", "2026-11-14T09:00:00", fix=fix),
          photo(2, "Thalasseus elegans", "2026-11-14T09:01:00", rejected=True, stars=-1)]
    pl = ebird.plan(ps, REGION)
    assert [s["sci"] for s in pl["species"]] == ["Thalasseus elegans"] and pl["species"][0]["photos"] == 2
