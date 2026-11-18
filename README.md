# BirdCM · 观羽

Local web app for bird photographers: cull a shoot of ~1,500 RAW photos (find the bird, name it, eye / beak,
flying or not) on your own Mac. Photos never leave the computer and the photo folder is only read.

Status: engine, queue, API and the batch review UI work end to end. Clear-bird gate, head sharpness, location
prior, rarity, star rating, aesthetic score and the single-photo view are pending (the UI shows them as 待定).

## Run

Needs macOS, [uv](https://docs.astral.sh/uv/), Node 20+, and `exiftool` (`brew install exiftool`).

```
cd web && npm install && npm run build && cd ..
cd engine
uv run birdcm models fetch        # downloads + sha256-checks the models into ~/Library/Caches/BirdCM/models
uv run birdcm serve               # http://127.0.0.1:8765/ (add --no-open to skip opening the browser)
uv run birdcm scan /path/to/photos --limit 20 [--json]    # command line, no database
uv run pytest                     # tests (the real-model smoke test is skipped without models)
```

Development with local model copies: `BIRDCM_MODEL_DIR=/…/bioclip-bird/release:/…/bioclip-bird/heads-repo-release`.
`BIRDCM_DATA_DIR` (SQLite) and `BIRDCM_CACHE_DIR` (thumbnails, models) move BirdCM's own files; it refuses to scan a
folder that contains either. UI development: `birdcm serve --no-open` plus `cd web && npm run dev`.

Docs: `docs/design.md` (design), `docs/perf.md` (measurements), `docs/deviations.md` (where the code differs).

## Licences

Code: MIT. Models are downloaded, not in this repository, and keep their own licences (`models.toml`):
BioCLIP 2.5 (MIT), OWLv2 (Apache-2.0), AviList names (CC BY 4.0). **The eye/beak and flight heads are for
non-commercial use only.** Chinese bird names: Wikidata labels (CC0), `engine/birdcm/data/names-zh.csv`.
