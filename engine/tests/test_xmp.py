"""XMP sidecars for Lightroom (R1), on copies in tmp_path only: fields read back by exiftool, an existing sidecar's
own fields kept (attribute and element forms), undo to the byte, originals untouched, JPEG / DNG skipped.
The .ARW / .JPG / .DNG here are a few random bytes: the sidecar code never decodes a photo."""
import hashlib
import json
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from birdcm import names, xmp
from birdcm.app import create_app
from birdcm.store import Store
from test_corrections import H, PORT, res
from test_queue import FakeEngine

pytestmark = pytest.mark.skipif(not shutil.which("exiftool"), reason="needs exiftool")
FIX = Path(__file__).parent / "fixtures" / "xmp"
CAT = {"Pycnonotus sinensis": {"en": "Light-vented Bulbul", "zh": "白头鹎"}, "Egretta garzetta": {"en": "Little Egret", "zh": "白鹭"},
       "Thalasseus maximus": {"en": "Royal Tern", "zh": "橙嘴凤头燕鸥"}}
RDF = "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}"
LANG = "{http://www.w3.org/XML/1998/namespace}lang"
OURS = {"{http://ns.adobe.com/xap/1.0/}Rating", "{http://ns.adobe.com/xmp/1.0/DynamicMedia/}pick",
        "{http://ns.adobe.com/xmp/1.0/DynamicMedia/}good", *xmp.KEYWORD_TAGS}


def props(el):
    d = {k: v for k, v in el.attrib.items() if not k.startswith(RDF) and k != LANG}
    for c in el:
        d[c.tag] = val(c)
    return d


def val(el):
    """A property's value whatever the serialisation: attribute or element, rdf:Description or parseType nesting."""
    kids = list(el)
    if kids and kids[0].tag in (RDF + "Bag", RDF + "Seq", RDF + "Alt"):
        items = [(li.get(LANG), val(li)) for li in kids[0]]
        return (kids[0].tag, sorted(items, key=repr) if kids[0].tag == RDF + "Bag" else items)
    if kids and kids[0].tag == RDF + "Description":
        return props(kids[0])
    return props(el) or (el.text or "").strip()


def flat(data: bytes) -> dict:
    """Every top-level property, keyed by namespace URI + name (the prefix does not matter)."""
    out = {}
    for d in ET.fromstring(data).iter(RDF + "Description"):
        if d.get(RDF + "about") is not None:
            out.update(props(d))
    return out


def readback(path: Path, raw: bool = False) -> dict:
    """exiftool's view; raw: read <stem>.xmp the way exiftool finds a RAW's sidecar (-srcfile %d%f.xmp)."""
    cmd = ["exiftool", "-j", "-xmp:all", *(["-srcfile", "%d%f.xmp"] if raw else []), str(path)]
    return json.loads(subprocess.run(cmd, capture_output=True, check=True).stdout)[0]


def sums(folder: Path) -> dict:
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.iterdir() if p.suffix.lower() != ".xmp"}


def setup(tmp_path, monkeypatch):
    """A.ARW 白头鹎 淘汰 (no sidecar), B.ARW 白鹭 3 星 (attribute-form sidecar), C.ARW 橙嘴凤头燕鸥 2 星 (element-form
    sidecar named C.XMP), D.JPG, E.DNG."""
    monkeypatch.setattr(names, "catalogue", lambda: CAT)
    folder = tmp_path / "photos"
    folder.mkdir()
    kinds = {"A.ARW": "Pycnonotus sinensis", "B.ARW": "Egretta garzetta", "C.ARW": "Thalasseus maximus",
             "D.JPG": "Egretta garzetta", "E.DNG": "Egretta garzetta"}
    for k, n in enumerate(kinds):
        (folder / n).write_bytes(bytes([k]) * 64 + n.encode())
    shutil.copy(FIX / "attr-form.xmp", folder / "B.xmp")
    shutil.copy(FIX / "elem-form.xmp", folder / "C.XMP")
    store = Store(tmp_path / "t.db")
    guarded, _api = create_app(PORT, token="tok", store=store, engine_factory=FakeEngine, start_scheduler=False)
    files = [(str(folder / n), (folder / n).stat().st_size, (folder / n).stat().st_mtime_ns) for n in kinds]
    sid = store.create_scan(str(folder), False, None, {"keep": 50}, "fp", files)
    for k, p in enumerate(store.queued(sid)):
        sci = kinds[Path(p["path"]).name]
        r = res(30 * k, sci)
        r["species"]["label"]["en"] = CAT[sci]["en"]                 # as the classifier names it (res() puts the Latin)
        store.commit(p["id"], r, None)
    store.set_state(sid, "completed")
    _api.state.scheduler.rerate_now(sid)
    c = TestClient(guarded, base_url=f"http://127.0.0.1:{PORT}")
    ids = {p["file"]: p["id"] for p in store.snapshot(sid)["photos"]}
    for n, s in (("A.ARW", -1), ("B.ARW", 3), ("C.ARW", 2)):
        assert c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids[n]], "stars": s}, headers=H).status_code == 200
    return c, store, sid, folder, ids


def test_write_merge_undo(tmp_path, monkeypatch):
    c, store, sid, folder, ids = setup(tmp_path, monkeypatch)
    originals = sums(folder)
    before = {n: (folder / n).read_bytes() for n in ("B.xmp", "C.XMP")}

    plan = c.post(f"/api/scans/{sid}/xmp", json={"dry": True}, headers=H).json()
    assert plan == {"create": 1, "modify": 2, "skipped": {xmp.SKIP_FORMAT: 2}, "last": None}
    assert sorted(p.name for p in folder.iterdir()) == ["A.ARW", "B.ARW", "B.xmp", "C.ARW", "C.XMP", "D.JPG", "E.DNG"]  # dry writes nothing

    r = c.post(f"/api/scans/{sid}/xmp", json={}, headers=H).json()
    assert (r["created"], r["modified"], r["skipped"]) == (1, 2, {xmp.SKIP_FORMAT: 2})
    # one sidecar per RAW, same stem, the existing C.XMP kept its name; nothing for D.JPG / E.DNG, no temporary file left
    assert sorted(p.name for p in folder.iterdir()) == ["A.ARW", "A.xmp", "B.ARW", "B.xmp", "C.ARW", "C.XMP", "D.JPG", "E.DNG"]
    assert sums(folder) == originals

    a = readback(folder / "A.ARW", raw=True)                       # found from the RAW's name, as exiftool / Lightroom do
    assert a["Rating"] == -1 and a["Pick"] == -1 and a["Good"] is False
    assert a["Subject"] == ["白头鹎", "Light-vented Bulbul", "Pycnonotus sinensis"]
    assert a["HierarchicalSubject"] == ["白头鹎", "Light-vented Bulbul", "Pycnonotus sinensis"]
    assert "白头鹎".encode() in (folder / "A.xmp").read_bytes()    # UTF-8 on disk, not an escape
    assert (folder / "A.xmp").stat().st_mode & 0o777 == 0o644      # not mkstemp's 0600
    b, cc = readback(folder / "B.xmp"), readback(folder / "C.XMP")
    assert b["Rating"] == 3 and "白鹭" in b["Subject"] and "Pick" not in b
    assert cc["Rating"] == 2 and "橙嘴凤头燕鸥" in cc["Subject"] and cc["Pick"] == 1      # the person's Pick flag kept

    for n in ("B.xmp", "C.XMP"):                                   # every field of the person's, item by item
        old, new = flat(before[n]), flat((folder / n).read_bytes())
        assert {k: v for k, v in old.items() if k not in OURS} == {k: v for k, v in new.items() if k not in OURS}
        for k in xmp.KEYWORD_TAGS:                                 # their keywords all there, ours added beside
            o = {x for _, x in old.get(k, ("", []))[1]}
            assert o <= {x for _, x in new[k][1]}
    assert flat(before["C.XMP"])["{http://ns.adobe.com/xmp/1.0/DynamicMedia/}pick"] == "1"
    kept = flat((folder / "B.xmp").read_bytes())                   # the comparison is not of two empty dicts
    assert kept["{http://example.com/ns/custom/1.0/}Note"] == "私有字段 private"
    assert kept["{http://ns.adobe.com/camera-raw-settings/1.0/}ToneCurvePV2012"] == (RDF + "Seq", [(None, "0, 0"), (None, "64, 58"), (None, "255, 255")])
    assert kept["{http://ns.adobe.com/xap/1.0/mm/}History"][1][0][1]["{http://ns.adobe.com/xap/1.0/sType/ResourceEvent#}action"] == "saved"

    # a second export after a species correction: the old species keywords go, our earlier write stays undoable
    first_a = (folder / "A.xmp").read_bytes()
    c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids["A.ARW"], "scope": "one", "sci": "Egretta garzetta"}, headers=H)
    c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids["A.ARW"]], "stars": 1}, headers=H)
    r2 = c.post(f"/api/scans/{sid}/xmp", json={"ids": [ids["A.ARW"]]}, headers=H).json()
    assert (r2["created"], r2["modified"]) == (0, 1)
    a = readback(folder / "A.xmp")
    assert a["Subject"] == ["白鹭", "Little Egret", "Egretta garzetta"] and a["Rating"] == 1 and "Pick" not in a

    u = c.post(f"/api/scans/{sid}/xmp/undo", headers=H).json()     # back to the first export
    assert (u["deleted"], u["restored"], u["kept"]) == (0, 1, [])
    assert (folder / "A.xmp").read_bytes() == first_a
    u = c.post(f"/api/scans/{sid}/xmp/undo", headers=H).json()     # back to before anything
    assert (u["deleted"], u["restored"], u["kept"]) == (1, 2, [])
    assert sorted(p.name for p in folder.iterdir()) == ["A.ARW", "B.ARW", "B.xmp", "C.ARW", "C.XMP", "D.JPG", "E.DNG"]
    assert {n: (folder / n).read_bytes() for n in before} == before  # byte for byte
    assert sums(folder) == originals
    assert c.post(f"/api/scans/{sid}/xmp/undo", headers=H).json()["batch"] is None


def test_undo_leaves_a_sidecar_changed_after_us(tmp_path, monkeypatch):
    c, store, sid, folder, ids = setup(tmp_path, monkeypatch)
    c.post(f"/api/scans/{sid}/xmp", json={}, headers=H)
    changed = (folder / "B.xmp").read_bytes().replace(b"</rdf:RDF>", b"<!-- Lightroom --></rdf:RDF>")
    (folder / "B.xmp").write_bytes(changed)
    u = c.post(f"/api/scans/{sid}/xmp/undo", headers=H).json()
    assert (u["deleted"], u["restored"]) == (1, 1)
    assert [k["file"] for k in u["kept"]] == ["B.xmp"]
    assert (folder / "B.xmp").read_bytes() == changed and not (folder / "A.xmp").exists()


def test_refuses_odd_sidecars(tmp_path, monkeypatch):
    c, store, sid, folder, ids = setup(tmp_path, monkeypatch)
    (folder / "B.xmp").write_bytes(b"<not xml")
    (folder / "C.XMP").unlink()
    (folder / "C.XMP").symlink_to(tmp_path / "elsewhere.xmp")
    r = c.post(f"/api/scans/{sid}/xmp", json={}, headers=H).json()
    assert r["created"] == 1 and r["modified"] == 0
    assert r["skipped"] == {xmp.SKIP_FORMAT: 2, xmp.SKIP_BAD: 1, xmp.SKIP_ODD: 1}
    assert (folder / "B.xmp").read_bytes() == b"<not xml" and not (tmp_path / "elsewhere.xmp").exists()


def test_reexport_keeps_a_keyword_the_person_had(tmp_path, monkeypatch):
    """C.XMP already has the keyword 白头鹎 (the person's). Named 白头鹎, exported, renamed, exported again: it stays."""
    c, store, sid, folder, ids = setup(tmp_path, monkeypatch)
    fix = lambda sci: c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids["C.ARW"], "scope": "one", "sci": sci}, headers=H)
    fix("Pycnonotus sinensis")
    c.post(f"/api/scans/{sid}/xmp", json={"ids": [ids["C.ARW"]]}, headers=H)
    assert set(readback(folder / "C.XMP")["Subject"]) == {"白头鹎", "家附近", "Light-vented Bulbul", "Pycnonotus sinensis"}  # a Bag: no order
    fix("Egretta garzetta")
    c.post(f"/api/scans/{sid}/xmp", json={"ids": [ids["C.ARW"]]}, headers=H)
    assert set(readback(folder / "C.XMP")["Subject"]) == {"白头鹎", "家附近", "白鹭", "Little Egret", "Egretta garzetta"}
    for _ in range(2):
        c.post(f"/api/scans/{sid}/xmp/undo", headers=H)
    assert (folder / "C.XMP").read_bytes() == (FIX / "elem-form.xmp").read_bytes()
