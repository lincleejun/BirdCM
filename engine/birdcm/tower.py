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
# Naming level, on the posterior (location prior applied): species when the first name has at least SPECIES_P and
# leads the second by SPECIES_MARGIN; else the genus when its names together reach GENUS_P; else uncertain.
# Chosen on the evaluation set only (bench/calibrate.py, 5-fold CV by species, docs/eval.md): precision among confirmed
# species >= 97 % at the highest coverage. The margin added nothing once P is this high, so it is 0.
SPECIES_P, SPECIES_MARGIN, GENUS_P = 0.94, 0.0, 0.94
RANGE_EPS, RANGE_TAU = 0.01, 0.05       # gardener's rules.py: p_geo below EPS = not here; a congener at TAU or more is


def level_of(p1: float, p2: float, genus_p: float) -> str:
    if p1 >= SPECIES_P and p1 - p2 >= SPECIES_MARGIN:
        return "species"
    return "genus" if genus_p >= GENUS_P else "uncertain"
EYE_VISIBLE = 0.5
ZH = Path(__file__).with_name("data") / "names-zh.csv"


def square(im: Image.Image) -> Image.Image:
    """Shortest side to 224, centre crop (the teacher's framing; geometry.square_map is its coordinate map)."""
    k = SIZE / min(im.size)
    w, h = round(im.width * k), round(im.height * k)
    left, top = (w - SIZE) // 2, (h - SIZE) // 2
    return im.resize((w, h), Image.Resampling.BICUBIC).crop((left, top, left + SIZE, top + SIZE))


class Tower:
    def __init__(self, tower: str, names: str, parts: str, flight: str, device: str, clear: str | None = None,
                 aesthetic: str | None = None) -> None:
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
        self.clear = {k: v.float().to(device) for k, v in load_file(clear).items()} if clear else None
        self.aes = {k: v.to(device) for k, v in load_file(aesthetic).items()} if aesthetic else None
        self.mean = torch.tensor(MEAN, device=device).view(1, 3, 1, 1)
        self.std = torch.tensor(STD, device=device).view(1, 3, 1, 1)

    def name(self, i: int, p: float) -> dict:
        return {"sci": self.sci[i], "en": self.en[i], "zh": self.zh.get(self.sci[i]), "p": round(p, 4)}

    @torch.no_grad()
    def __call__(self, items: list) -> list[dict]:
        """Per item, a crop or (crop, p_geo or None): {top5, level, label, genus, beak, eyes, p_fly, clear, max_cos}, points
        in 224 pixels. With p_geo the location prior weighs the whole 11,172-name distribution before anything is cut."""
        if not items:
            return []
        crops = [it[0] if isinstance(it, tuple) else it for it in items]
        priors = [it[1] if isinstance(it, tuple) else None for it in items]
        x = torch.from_numpy(np.stack([np.asarray(square(c), np.float32) / 255 for c in crops])).permute(0, 3, 1, 2).to(self.device)
        f = self.model(((x - self.mean) / self.std).to(self.dtype)).float()
        f = f / f.norm(dim=-1, keepdim=True)
        cos = f @ self.matrix.T                                                   # (b, 11172) float32
        p = (self.scale * cos).softmax(-1)
        if any(g is not None for g in priors):
            from birdcm.geo import FLOOR
            w = torch.stack([torch.from_numpy(np.asarray(g, np.float32)) + FLOOR if g is not None else torch.ones(p.shape[1])
                             for g in priors]).to(self.device)
            p = p * w
            p = p / p.sum(-1, keepdim=True).clamp_min(1e-30)
        max_cos = cos.max(-1).values
        clear = self._clear(f, max_cos)
        gmass = torch.zeros(len(crops), len(self.genera), device=self.device).index_add_(1, self.genus_of, p)
        tokens = self.got["t"][:, 1:].float()                                     # (b, 256, 1280); token 0 = class
        pts, vis = self._parts(tokens)
        fly = self._flight(tokens)
        top = p.topk(5)
        out = []
        for b in range(len(crops)):
            ids, ps = top.indices[b].tolist(), top.values[b].tolist()
            g = int(gmass[b].argmax())
            genus = {"sci": self.genera[g] + " sp.", "en": None, "zh": None, "p": round(float(gmass[b, g]), 4)}
            level = level_of(ps[0], ps[1], genus["p"])
            pg = priors[b]
            if pg is not None and pg[ids[0]] < RANGE_EPS:          # gardener's range veto: "not found here" cannot be confirmed
                level = level_of(0.0, 0.0, genus["p"])
                gen = self.sci[ids[0]].split(" ")[0]
                k = next((k for k, i in enumerate(ids) if self.sci[i].split(" ")[0] == gen and pg[i] >= RANGE_TAU), None)
                if k:                                              # a congener that does live here goes first
                    ids.insert(0, ids.pop(k))
                    ps.insert(0, ps.pop(k))
            label = self.name(ids[0], ps[0]) if level == "species" else genus if level == "genus" else None
            out.append({"top5": [self.name(i, s) for i, s in zip(ids, ps)], "level": level, "label": label, "genus": genus,
                        "max_cos": round(float(max_cos[b]), 4),
                        "beak": pts[b, 0].tolist(), "eyes": [pts[b, 1].tolist(), pts[b, 2].tolist()],
                        "p_beak": float(vis[b, 0]), "p_eyes": [float(vis[b, 1]), float(vis[b, 2])],
                        "p_fly": float(fly[b]), "clear": clear[b]})
        return out

    def _clear(self, f: torch.Tensor, max_cos: torch.Tensor) -> list[bool | None]:
        """The clear-bird gate (bioclip-bird-heads clear.py passes()): a linear layer on the unit image vector and its
        best cosine to the names, both thresholds stored in the file. Its thresholds were set on float16 MPS features;
        this computes the vector the same way (float16 tower, normalised in float32). None without the head file."""
        h = self.clear
        if h is None:
            return [None] * len(f)
        z = ((f - h["mean"]) / h["std"]) @ h["weight"] + h["bias"]
        return ((z.reshape(-1) >= h["z_min"]) & (max_cos >= h["cos_min"])).tolist()

    @torch.no_grad()
    def aesthetic(self, frames: list[np.ndarray]) -> list[float | None]:
        """Whole-photo aesthetic score, 0-1 (EVA general score / 10): a second tower pass over the whole frame, mean of the
        block-15 patch tokens, the linear head of aesthetic.safetensors. None without the head file."""
        if self.aes is None or not frames:
            return [None] * len(frames)
        h = self.aes
        squash = int(h["frame"]) == 1
        ims = [Image.fromarray(f).resize((SIZE, SIZE), Image.Resampling.BICUBIC) if squash else square(Image.fromarray(f))
               for f in frames]
        x = torch.from_numpy(np.stack([np.asarray(im, np.float32) / 255 for im in ims])).permute(0, 3, 1, 2).to(self.device)
        self.model(((x - self.mean) / self.std).to(self.dtype))
        t = self.got["t"][:, 1:].float().mean(1)                                   # (b, 1280)
        y = ((t - h["mean"]) / h["std"]) @ h["weight"] + h["bias"]
        y = ((y - h["lo"]) / (h["hi"] - h["lo"])).clamp(0, 1)
        return [round(float(v), 4) for v in y.reshape(-1)]

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
