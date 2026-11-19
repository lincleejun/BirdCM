import hashlib
import os

from birdcm import models


def test_startup_does_not_hash_model_files_when_unchanged(tmp_path, monkeypatch):
    """sha256 once per file version, remembered on disk: a second start (or the status right after a download) reads
    the memo; a changed file is hashed again."""
    src = tmp_path / "src"
    src.mkdir()
    (src / "a.bin").write_bytes(b"weights a")
    man = tmp_path / "models.toml"
    man.write_text("".join(f'[[file]]\nname = "{n}"\nrole = "{n}"\nurl = "file://{src}/{n}"\nsha256 = "{hashlib.sha256(d).hexdigest()}"\n'
                           f'bytes = {len(d)}\n' for n, d in (("a.bin", b"weights a"), ("b.bin", b"weights b"))))
    (src / "b.bin").write_bytes(b"weights b")              # served from here, downloaded into the cache
    monkeypatch.setattr(models, "MANIFEST", man)
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setenv("BIRDCM_MODEL_DIR", str(tmp_path / "local"))
    (tmp_path / "local").mkdir()
    os.replace(src / "a.bin", tmp_path / "local" / "a.bin")
    (src / "a.bin").write_bytes(b"weights a")
    hashed = []
    real = models._sha256
    monkeypatch.setattr(models, "_sha256", lambda p: hashed.append(p.name) or real(p))
    assert models.fetch(log=lambda *_: None) == 0           # a.bin found (hashed once), b.bin downloaded (hashed as written)
    assert hashed == ["a.bin"]
    for _ in range(3):                                      # three starts: status, the fingerprint's digest, the engine's paths
        assert models.status()["ready"]
        models.digest()
        models.paths()
    assert hashed == ["a.bin"]
    os.utime(tmp_path / "local" / "a.bin", ns=(1, 1))      # same bytes, new mtime: a new version, checked once more
    models.status()
    models.status()
    assert hashed == ["a.bin", "a.bin"]


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
