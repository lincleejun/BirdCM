# BirdCM · 观羽

Local web app for bird photographers: cull a shoot of ~1,500 RAW photos (find the bird, name it, eye / beak,
flying or not) on your own Mac. Photos never leave the computer and the photo folder is only read.

Status: batch culling (find, name, eye / beak, flying, clear-bird gate, head sharpness, aesthetic, stars, CSV / JSON
export), the location prior (BirdNET geo, anywhere in the world: photo GPS, a map pin, the device's location or a
country / first-level division), burst consensus, rarity (US / CA / CN for now) and IUCN, the single-photo view
with history, and `birdcm eval` work end to end. Star defaults are the recorded strategy, not yet validated on the
owner's keeps. The map dialog is the app's only network use (OpenStreetMap tiles, loaded when it is opened).

## Run

Needs macOS, [uv](https://docs.astral.sh/uv/), Node 20+, and `exiftool` (`brew install exiftool`).

```
cd web && npm install && npm run build && cd ..
cd engine
uv run birdcm models fetch        # downloads + sha256-checks the models into ~/Library/Caches/BirdCM/models
uv run birdcm serve               # http://127.0.0.1:8765/ (add --no-open to skip opening the browser)
uv run birdcm scan /path/to/photos --limit 20 [--json]    # command line, no database
uv run birdcm eval --photos /path/to/eval/photos --kinds bird,mammal   # docs/eval.md
uv run pytest                     # tests (the real-model smoke test is skipped without models)
```

**Not released yet** (so a fresh `models fetch` reports them missing): `clear.safetensors` (clear-bird gate),
`aesthetic.safetensors` (aesthetic head) and `rarity-us-ca-cn.sqlite` (rarity + IUCN table). They will be attached to
the model repositories' releases once their data licences are settled; see `NOTICE.md`. The home-page photo and the
prototype's sample crops are the author's own pictures and are not in this repository.

Development with local model copies: `BIRDCM_MODEL_DIR=/…/bioclip-bird/release:/…/bioclip-bird/heads-repo-release`.
`BIRDCM_DATA_DIR` (SQLite) and `BIRDCM_CACHE_DIR` (thumbnails, models) move BirdCM's own files; it refuses to scan a
folder that contains either. UI development: `birdcm serve --no-open` plus `cd web && npm run dev`.

Docs: `docs/design.md` (design), `docs/perf.md` (speed), `docs/eval.md` (accuracy), `docs/deviations.md` (where the code differs), `NOTICE.md` (model licences).

## Licences

Code: MIT. Models are downloaded, not in this repository, and keep their own licences (`models.toml`):
BioCLIP 2.5 (MIT), OWLv2 (Apache-2.0), AviList names (CC BY 4.0). **The eye/beak and flight heads are for
non-commercial use only**; the aesthetic head's training-image licence is not established. Details in `NOTICE.md`.
