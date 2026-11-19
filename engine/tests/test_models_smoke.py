"""Real models, skipped when they are not installed. Expected names from bioclip-bird's examples/identify.py on the
same images (float32 reference path)."""
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from birdcm import models

IMG = Path(__file__).resolve().parents[2] / "docs" / "prototype" / "img"
try:
    models.paths()
    READY = True
except FileNotFoundError:
    READY = False
pytestmark = [pytest.mark.skipif(not READY, reason="model files not installed (birdcm models fetch)"),
              # the owner's sample photos are gitignored (not published): absent in a fresh clone and in CI
              pytest.mark.skipif(not all((IMG / f"{k}.jpg").is_file() for k in ("000004_11", "000005_03", "000006_13")),
                                 reason="sample photos docs/prototype/img/*.jpg not here")]


@pytest.fixture(scope="module")
def engine():
    from birdcm.pipeline import Engine
    e = Engine(workers=1)
    yield e
    e.close()


def test_tower_matches_reference(engine):
    want = {"000005_03": ("Megaceryle alcyon", 1.0, False), "000004_11": ("Nannopterum auritum", 0.895, True),
            "000006_13": ("Setophaga coronata", 1.0, False)}
    looks = engine.tower([Image.open(IMG / f"{k}.jpg").convert("RGB") for k in want])
    for (sci, p, fly), look in zip(want.values(), looks):
        assert look["top5"][0]["sci"] == sci and abs(look["top5"][0]["p"] - p) < 0.02
        assert (look["p_fly"] >= 0.5) == fly


def test_detector_matches_hf_processor(engine):
    transformers = pytest.importorskip("transformers")
    try:
        proc = transformers.Owlv2Processor.from_pretrained("google/owlv2-base-patch16-ensemble",
                                                           revision="cfd3195ba4ea9592eec887ded089f4c08eff231d")
    except Exception:  # noqa: BLE001 - no cached processor files: nothing to compare with
        pytest.skip("Owlv2Processor files not in the local HF cache")
    import torch
    im = Image.open(IMG / "000004_11.jpg").convert("RGB")
    ours = engine.detector([np.array(im)])[0]
    det = engine.detector
    inp = proc(text=[["a bird"]], images=im, return_tensors="pt").to(det.device)
    with torch.no_grad():
        o = det.model(input_ids=inp["input_ids"], attention_mask=inp["attention_mask"], pixel_values=inp["pixel_values"].to(det.dtype))
    s = max(im.size)
    r = proc.post_process_grounded_object_detection(o, threshold=0.3, target_sizes=torch.tensor([[s, s]]))[0]
    best = int(r["scores"].argmax())
    ref = [float(v) for v in r["boxes"][best]]
    ref = [ref[0] / im.width, ref[1] / im.height, ref[2] / im.width, ref[3] / im.height]
    assert ours and abs(ours[0][0] - float(r["scores"][best])) < 0.05
    assert all(abs(a - b) < 0.02 for a, b in zip(ours[0][1], ref))
