"""One BioCLIP 2.5 pass per subject crop: species over all 11,172 AviList names, plus the block-15 heads
(beak / eye points with visibility, P(flying)). Follows bioclip-bird's examples/identify.py; the tower computes
in float16 on a GPU, the names product and softmax in float32."""
from __future__ import annotations

import csv
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from safetensors.torch import load_file

from birdcm.detect import unpack
from birdcm.geometry import SIZE

VISION = {"image_size": 224, "layers": 32, "width": 1280, "head_width": 80, "patch_size": 14}
MEAN, STD = (0.48145466, 0.4578275, 0.40821073), (0.26862954, 0.26130258, 0.27577711)
PATCH, GRID, LAYER = 14, 16, 15
# Image-only naming level (gardener's rule, before any location prior): species when the first name has at least
# SPECIES_P and leads the second by SPECIES_MARGIN; else the genus when its names together reach GENUS_P; else
# uncertain. Constants until the geo research replaces them (docs/deviations.md).
SPECIES_P, SPECIES_MARGIN, GENUS_P = 0.5, 0.3, 0.6
EYE_VISIBLE = 0.5
ZH = Path(__file__).with_name("data") / "names-zh.csv"


def square(im: Image.Image) -> Image.Image:
    """Shortest side to 224, centre crop (the teacher's framing; geometry.square_map is its coordinate map)."""
    k = SIZE / min(im.size)
    w, h = round(im.width * k), round(im.height * k)
    left, top = (w - SIZE) // 2, (h - SIZE) // 2
    return im.resize((w, h), Image.Resampling.BICUBIC).crop((left, top, left + SIZE, top + SIZE))


class Tower:
    def __init__(self, tower: str, names: str, parts: str, flight: str, device: str) -> None:
        import open_clip
        model = open_clip.model._build_vision_tower(1024, open_clip.model.CLIPVisionCfg(**VISION))
        model.load_state_dict(unpack(load_file(tower)))
        self.dtype = torch.float32 if device == "cpu" else torch.float16
        self.device, self.model = device, model.eval().to(device=device, dtype=self.dtype)
        self.got: dict = {}
        self.model.transformer.resblocks[LAYER].register_forward_hook(lambda _m, _i, o: self.got.__setitem__("t", o))
        z = np.load(names)
        self.matrix = torch.from_numpy(z["matrix"].astype(np.float32)).to(device)
        self.scale = float(z["logit_scale"])
        self.sci, self.en = [str(s) for s in z["scientific"]], [str(s) for s in z["common"]]
        genera, inverse = np.unique(np.array([str(t[5]) for t in z["taxonomy"]]), return_inverse=True)
        self.genera, self.genus_of = [str(g) for g in genera], torch.from_numpy(inverse).to(device)
        with open(ZH, newline="", encoding="utf-8") as f:
            self.zh = {r["scientific"]: r["zh"] for r in csv.DictReader(f)}
        self.parts = {k: v.float().to(device) for k, v in load_file(parts).items()}
        self.flight = {k: v.float().to(device) for k, v in load_file(flight).items()}
        self.mean = torch.tensor(MEAN, device=device).view(1, 3, 1, 1)
        self.std = torch.tensor(STD, device=device).view(1, 3, 1, 1)

    def name(self, i: int, p: float) -> dict:
        return {"sci": self.sci[i], "en": self.en[i], "zh": self.zh.get(self.sci[i]), "p": round(p, 4)}

    @torch.no_grad()
    def __call__(self, crops: list[Image.Image]) -> list[dict]:
        """Per crop (any size; squared here): {top5, level, label, beak, eyes, p_fly} with points in 224 pixels."""
        if not crops:
            return []
        x = torch.from_numpy(np.stack([np.asarray(square(c), np.float32) / 255 for c in crops])).permute(0, 3, 1, 2).to(self.device)
        f = self.model(((x - self.mean) / self.std).to(self.dtype)).float()
        f = f / f.norm(dim=-1, keepdim=True)
        p = (self.scale * f @ self.matrix.T).softmax(-1)                          # (b, 11172) float32
        gmass = torch.zeros(len(crops), len(self.genera), device=self.device).index_add_(1, self.genus_of, p)
        tokens = self.got["t"][:, 1:].float()                                     # (b, 256, 1280); token 0 = class
        pts, vis = self._parts(tokens)
        fly = self._flight(tokens)
        top = p.topk(5)
        out = []
        for b in range(len(crops)):
            ids, ps = top.indices[b].tolist(), top.values[b].tolist()
            g = int(gmass[b].argmax())
            if ps[0] >= SPECIES_P and ps[0] - ps[1] >= SPECIES_MARGIN:
                level, label = "species", self.name(ids[0], ps[0])
            elif float(gmass[b, g]) >= GENUS_P:
                level, label = "genus", {"sci": self.genera[g] + " sp.", "en": None, "zh": None, "p": round(float(gmass[b, g]), 4)}
            else:
                level, label = "uncertain", None
            out.append({"top5": [self.name(i, s) for i, s in zip(ids, ps)], "level": level, "label": label,
                        "beak": pts[b, 0].tolist(), "eyes": [pts[b, 1].tolist(), pts[b, 2].tolist()],
                        "p_beak": float(vis[b, 0]), "p_eyes": [float(vis[b, 1]), float(vis[b, 2])],
                        "p_fly": float(fly[b])})
        return out

    def _parts(self, tokens: torch.Tensor) -> tuple[np.ndarray, np.ndarray]:
        """Beak / left eye / right eye: ((b, 3, 2) points in the 224 input, (b, 3) P(visible))."""
        h = self.parts
        x = torch.nn.functional.layer_norm(tokens, (tokens.shape[-1],), h["norm.weight"], h["norm.bias"])
        x = torch.nn.functional.gelu(x @ h["fc.weight"].T + h["fc.bias"])
        o = (x @ h["out.weight"].T + h["out.bias"]).view(len(tokens), GRID * GRID, 3, 3)
        cell = o[..., 0].argmax(1)                                                # (b, 3) most likely patch per part
        off = torch.sigmoid(torch.gather(o[..., 1:], 1, cell[:, None, :, None].expand(-1, 1, 3, 2))[:, 0])
        pts = (torch.stack([cell % GRID, cell // GRID], -1) + off) * PATCH
        vis = torch.sigmoid(x.mean(1) @ h["vis.weight"].T + h["vis.bias"])
        return pts.cpu().numpy(), vis.cpu().numpy()

    def _flight(self, tokens: torch.Tensor) -> np.ndarray:
        h = self.flight
        z = (tokens.mean(1) - h["mean"]) / h["std"]
        return torch.sigmoid(z @ h["weight"] + h["bias"]).reshape(-1).cpu().numpy()
