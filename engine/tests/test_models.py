import hashlib

from birdcm import models


def test_fetch_checks_sha256(tmp_path, monkeypatch):
    src = tmp_path / "src"
    src.mkdir()
    (src / "good.bin").write_bytes(b"good weights")
    (src / "evil.bin").write_bytes(b"tampered")
    sha = hashlib.sha256(b"good weights").hexdigest()
    man = tmp_path / "models.toml"
    man.write_text(f'''
[[file]]
name = "good.bin"
role = "a"
url = "file://{src}/good.bin"
sha256 = "{sha}"
bytes = 12
[[file]]
name = "bad.bin"
role = "b"
url = "file://{src}/evil.bin"
sha256 = "{sha}"
bytes = 12
''')
    monkeypatch.setattr(models, "MANIFEST", man)
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.delenv("BIRDCM_MODEL_DIR", raising=False)
    assert models.fetch(log=lambda *_: None) == 1
    dest = tmp_path / "cache" / "models"
    assert (dest / "good.bin").read_bytes() == b"good weights"
    assert sorted(p.name for p in dest.iterdir()) == ["good.bin"]          # no bad file, no .part left
    st = models.status()
    assert not st["ready"] and st["missing"] == ["bad.bin"]
