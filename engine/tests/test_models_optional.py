"""A fresh clone with only the released files: the optional ones are reported, not required."""
import hashlib

from birdcm import models


def test_optional_unreleased_files_do_not_block(tmp_path, monkeypatch):
    req = tmp_path / "req.bin"
    req.write_bytes(b"required")
    sha = hashlib.sha256(b"required").hexdigest()
    man = tmp_path / "models.toml"
    man.write_text(f'''
[[file]]
name = "req.bin"
role = "tower"
url = "https://example.invalid/req.bin"
sha256 = "{sha}"
bytes = 8

[[file]]
name = "clear.safetensors"
role = "clear"
optional = true
released = false
url = "https://example.invalid/clear"
sha256 = "{'0' * 64}"
bytes = 1
''')
    monkeypatch.setattr(models, "MANIFEST", man)
    monkeypatch.setenv("BIRDCM_MODEL_DIR", str(tmp_path))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    st = models.status()
    assert st["ready"] and st["missing"] == []
    assert st["optional_missing"][0]["name"] == "clear.safetensors" and not st["optional_missing"][0]["released"]
    assert set(models.paths()) == {"tower"}
    logs = []
    assert models.fetch(logs.append) == 0 and any("还没有发布" in x for x in logs)


def test_no_rarity_table_reads_as_no_data():
    from birdcm.pipeline import rarity_for
    sp = {"level": "species", "label": {"sci": "A b"}}
    assert rarity_for(None, sp, {})["label"] == "数据不足"
