"""Find birds: OWLv2 base/16 ensemble, weights from the int8 file, one fixed prompt "a bird".

No Hugging Face download at run time: the model's config.json (revision cfd3195ba4ea9592eec887ded089f4c08eff231d)
is defaults plus the values below, the prompt is pre-tokenised, and the image preprocessing (pad to a square of
the long side with grey 0.5, resize to 960, CLIP mean/std) runs here on the device. Checked against
Owlv2Processor in tests/test_models_smoke.py.
"""
from __future__ import annotations

import numpy as np
import torch
from safetensors.torch import load_file

from birdcm.geometry import dedupe

SIDE = 960
MEAN, STD = (0.48145466, 0.4578275, 0.40821073), (0.26862954, 0.26130258, 0.27577711)
PROMPT_IDS = [49406, 320, 3329, 49407] + [0] * 12          # CLIP tokens of "a bird", padded to 16
FLOOR, SECOND, SECOND_TOP, SAME = 0.3, 0.1, 3, 0.5          # gardener's bird vocabulary floor and its second pass


def unpack(raw: dict) -> dict:
    """int8 file -> float32 state dict (KEY.q8 * KEY.s8 per row; the rest as stored)."""
    out = {}
    for k, v in raw.items():
        if k.endswith(".q8"):
            out[k[:-3]] = v.float() * raw[k[:-3] + ".s8"].float().view(-1, *[1] * (v.ndim - 1))
        elif not k.endswith(".s8"):
            out[k] = v
    return out


class Detector:
    def __init__(self, weights: str, device: str, half: bool = False) -> None:
        from transformers import Owlv2Config, Owlv2ForObjectDetection
        cfg = Owlv2Config(text_config={"model_type": "owlv2_text_model"},
                          vision_config={"image_size": SIDE, "model_type": "owlv2_vision_model", "patch_size": 16},
                          projection_dim=512, logit_scale_init_value=2.6592, initializer_factor=1.0)
        model = Owlv2ForObjectDetection(cfg)
        dtypes = {k: v.dtype for k, v in model.state_dict().items()}
        model.load_state_dict({k: v.to(dtypes[k]) for k, v in unpack(load_file(weights)).items()})
        self.dtype = torch.float16 if half else torch.float32
        self.device, self.model = device, model.to(device=device, dtype=self.dtype).eval()
        self.ids = torch.tensor([PROMPT_IDS], device=device)
        self.mask = (self.ids != 0).long()
        self.mean = torch.tensor(MEAN, device=device).view(1, 3, 1, 1)
        self.std = torch.tensor(STD, device=device).view(1, 3, 1, 1)

    def prepare(self, frames: list[np.ndarray]) -> torch.Tensor:
        out = []
        for f in frames:
            h, w = f.shape[:2]
            x = torch.from_numpy(f).to(self.device).permute(2, 0, 1).float() / 255
            s = max(h, w)
            x = torch.nn.functional.pad(x, (0, s - w, 0, s - h), value=0.5)
            out.append(torch.nn.functional.interpolate(x[None], size=(SIDE, SIDE), mode="bilinear", antialias=True, align_corners=False))
        return ((torch.cat(out) - self.mean) / self.std).to(self.dtype)

    @torch.no_grad()
    def __call__(self, frames: list[np.ndarray]) -> list[list[tuple[float, tuple[float, float, float, float]]]]:
        """Per frame: [(score, normalised (x0, y0, x1, y1))], strongest first, deduplicated."""
        if not frames:
            return []
        b = len(frames)
        out = self.model(input_ids=self.ids.expand(b, -1), attention_mask=self.mask.expand(b, -1),
                         pixel_values=self.prepare(frames))
        scores = torch.sigmoid(out.logits.float()[..., 0]).cpu().numpy()        # (b, patches)
        boxes = out.pred_boxes.float().cpu().numpy()                             # cx, cy, w, h in the padded square
        result = []
        for f, sc, bx in zip(frames, scores, boxes):
            h, w = f.shape[:2]
            s = max(h, w)
            keep = np.flatnonzero(sc >= FLOOR)
            if not len(keep):                                                   # nothing sure: the 3 best above 0.1
                keep = [i for i in np.argsort(-sc)[:SECOND_TOP] if sc[i] >= SECOND]
            found = []
            for i in keep:
                cx, cy, bw, bh = (float(v) for v in bx[i] * s)
                x0, y0 = max(0.0, cx - bw / 2) / w, max(0.0, cy - bh / 2) / h
                x1, y1 = min(float(w), cx + bw / 2) / w, min(float(h), cy + bh / 2) / h
                if x1 > x0 and y1 > y0:
                    found.append((float(sc[i]), (x0, y0, x1, y1)))
            result.append(dedupe(found, SAME))
        return result
