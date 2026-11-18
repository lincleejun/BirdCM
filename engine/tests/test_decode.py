import pytest

from birdcm import decode


def test_exiftool_refuses_injected_arguments():
    et = decode.ExifTool()
    et._ask = lambda args: pytest.fail("must not reach the exiftool protocol")   # noqa: E731
    for bad in ["/p/a.ARW\n-Artist=x\n-overwrite_original", "/p/a\r.ARW", "relative.ARW", "-tagsFromFile"]:
        with pytest.raises(ValueError):
            et.read(["/p/ok.ARW", bad])


def test_scan_listing_refuses_newline_names(tmp_path):
    (tmp_path / "ok.jpg").write_bytes(b"x")
    assert [p.name for p in decode.list_photos(tmp_path)] == ["ok.jpg"]
    (tmp_path / "a\n-Artist=x.jpg").write_bytes(b"x")
    with pytest.raises(ValueError, match="换行"):
        decode.list_photos(tmp_path)
