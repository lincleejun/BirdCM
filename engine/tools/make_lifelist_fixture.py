"""Regenerate the shared life-list golden files from docs/fixtures/lifelist/fixture-v1.json:
fixture-v1.birdcm (the desktop's export of the fixture) and ebird-v1.csv (its life-list eBird file, fallback included).

  cd engine && uv run python tools/make_lifelist_fixture.py

Synthetic data only. The archive's archive_id / created_utc differ on every run; its facts do not.
"""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))

from birdcm import archive, ebird  # noqa: E402
from lifelist_fixture import FIXTURE, native  # noqa: E402


class Patch:
    def setattr(self, obj, name, value):
        setattr(obj, name, value)


def main() -> None:
    with tempfile.TemporaryDirectory() as d:
        store, lib, _ = native(Path(d), Patch())
        lib.rebuild()
        archive.export(lib, FIXTURE.parent / "fixture-v1.birdcm")
        (FIXTURE.parent / "ebird-v1.csv").write_bytes(ebird.lifelist_csv(lib.index(), fallback="include").encode())
    print("wrote", FIXTURE.parent / "fixture-v1.birdcm", FIXTURE.parent / "ebird-v1.csv")


if __name__ == "__main__":
    main()
