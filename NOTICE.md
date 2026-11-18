# Notices: models and data

BirdCM's code is MIT. The models are downloaded (see `models.toml`), never committed, and each keeps its own licence.

| File | What | Licence / terms |
|---|---|---|
| `bioclip-2.5-vith14-visual-int8.safetensors` | BioCLIP 2.5 image tower, rounded to int8 ([imageomics/bioclip-2.5-vith14](https://huggingface.co/imageomics/bioclip-2.5-vith14)) | MIT; please cite BioCLIP 2.5 |
| `bioclip-2.5-vith14-avilist-2026-names.npz` | 11,172 AviList v2026 species as text vectors | AviList: CC BY 4.0 (AviList Core Team. 2026. AviList: The Global Avian Checklist, v2026. https://doi.org/10.2173/avilist.v2026); TreeOfLife-200M vectors CC0 |
| `owlv2-base-patch16-ensemble-int8.safetensors` | OWLv2 detector, int8 ([google/owlv2-base-patch16-ensemble](https://huggingface.co/google/owlv2-base-patch16-ensemble)) | Apache-2.0 |
| `parts.safetensors`, `flight.safetensors` | Eye/beak and flight heads (bioclip-bird-heads) | **Non-commercial use only** (trained on CUB-200-2011 and CC BY-NC photos) |
| `clear.safetensors` | "Is there a clear bird" gate (bioclip-bird-heads) | Trained only on CC BY and CC0 photos; CC BY asks for attribution: the photo list with attributions is `clear-training-photos.csv`, published with the weights. No non-commercial restriction on our reading |
| `aesthetic.safetensors` | Whole-photo aesthetic head on BioCLIP block 15 | Fitted on EVA scores (CC0). The EVA images come from AVA / dpchallenge.com and stay the photographers' copyright; **their licence for this use is not established** — treat as personal / research use until settled (`AESTHETIC-WEIGHTS-LICENSE.md`) |
| `engine/birdcm/data/names-zh.csv` (in this repository) | Chinese bird names, 5,330 of 11,172 species | Wikidata labels, CC0 (from gardener's `data/names/names-zh.csv`); not proofread |

Pending (not shipped yet): BirdNET geo data (CC BY-NC-SA 4.0), the GBIF / IUCN rarity table.
