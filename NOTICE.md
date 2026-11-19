# Notices: models and data

BirdCM's code is MIT. Desktop models are downloaded (see `models.toml`), never committed, and each keeps its own licence.

| File | What | Licence / terms |
|---|---|---|
| `bioclip-2.5-vith14-visual-int8.safetensors` | BioCLIP 2.5 image tower, rounded to int8 ([imageomics/bioclip-2.5-vith14](https://huggingface.co/imageomics/bioclip-2.5-vith14)) | MIT; please cite BioCLIP 2.5 |
| `bioclip-2.5-vith14-avilist-2026-names.npz` | 11,172 AviList v2026 species as text vectors | AviList: CC BY 4.0 (AviList Core Team. 2026. AviList: The Global Avian Checklist, v2026. https://doi.org/10.2173/avilist.v2026); TreeOfLife-200M vectors CC0 |
| `owlv2-base-patch16-ensemble-int8.safetensors` | OWLv2 detector, int8 ([google/owlv2-base-patch16-ensemble](https://huggingface.co/google/owlv2-base-patch16-ensemble)) | Apache-2.0 |
| `parts.safetensors`, `flight.safetensors` | Eye/beak and flight heads (bioclip-bird-heads) | **Non-commercial use only** (trained on CUB-200-2011 and CC BY-NC photos) |
| `clear.safetensors` | "Is there a clear bird" gate (bioclip-bird-heads) | Trained only on CC BY and CC0 photos; CC BY asks for attribution: the photo list with attributions is `clear-training-photos.csv`, published with the weights. No non-commercial restriction on our reading |
| `aesthetic.safetensors` | Whole-photo aesthetic head on BioCLIP block 15 | Fitted on EVA scores (CC0). The EVA images come from AVA / dpchallenge.com and stay the photographers' copyright; **their licence for this use is not established** — treat as personal / research use until settled (`AESTHETIC-WEIGHTS-LICENSE.md`) |
| `BirdNET+_Geomodel_V3.0.4_Global_14K_FP32.onnx` | Location prior, BirdNET+ geo model 3.0.4 (birdnet-team/geomodel release v3.0.4), downloaded from that release, never committed | The geomodel repository's `LICENSE-MODELS.md` (https://github.com/birdnet-team/geomodel/blob/main/LICENSE-MODELS.md, read 2026-11-17 on `main`) says **Apache-2.0** for model weights and label files. The `birdnet` pip package README (https://github.com/birdnet-team/birdnet) says its models are **CC BY-NC-SA 4.0**. We download the release file directly and do not use the pip package; the two statements conflict and the owner should decide which to rely on. Please cite BirdNET |
| `engine/birdcm/data/avilist-birdnet-geo3.csv` (in this repository) | AviList row -> geo model output index, derived from gardener's `avilist_map.csv` and the model's label order | Index numbers only |
| `engine/birdcm/data/countries.csv`, `regions.csv` (in this repository) | Representative points and Chinese / English names of countries and US / CA / CN first-level divisions | Hand-entered approximate points (±1–2°), MIT with the code |
| `rarity-us-ca-cn.sqlite` | GBIF record counts per region and month, tiered, and IUCN categories (bioclip-bird `distill/rarity_pack.py`) | GBIF.org occurrence data, accessed 2026-11-17 — cite "GBIF.org (17 November 2026) GBIF Occurrence Download / search API". IUCN: "IUCN (2026). The IUCN Red List of Threatened Species. Version 2026-1. https://doi.org/10.15468/0qnb58". IUCN's terms on redistribution are unclear (owner to decide); `BIRDCM_IUCN=0` turns the IUCN column off everywhere |
| `rarity-global.sqlite` (optional, not released yet; replaces the US / CA / CN table when installed) | GBIF record counts per ISO 3166 region and month, tiered, with coverage (own counts / the country's month / 数据不足), IUCN categories, and region outlines for the offline point -> region lookup (bioclip-bird `distill/rarity_global.py`) | GBIF.org occurrence data, accessed 2026-11-17/18 — cite "GBIF.org (18 November 2026) GBIF Occurrence Download / search API". IUCN as above (same unresolved redistribution question; `BIRDCM_IUCN=0` hides it). Shapes and division names: Natural Earth 1:50m v5.1.1, public domain (names from Wikidata, CC0); country names Unicode CLDR |
| Map tiles (not shipped) | Shown only in the map dialog, loaded from tile.openstreetmap.org when it is opened | © OpenStreetMap contributors, ODbL; attribution shown on the map; OSM tile usage policy (no prefetching) |
| `engine/birdcm/data/zh-names.csv` (in this repository) | Chinese bird names (simplified, and traditional where the source has one) for 11,113 of 11,172 AviList v2026 species; `source` column per row | 11,111 rows from the "Chinese" / "Chinese (Traditional)" columns of the IOC World Bird List Multilingual Version v15.2 (`Multiling IOC 15.2.xlsx`, https://www.worldbirdnames.org/new/ioc-lists/master-list-2/, downloaded 2026-11-17, sha256 fb130d0d…5d82). The site states: "IOC World Bird List v15.2 by Frank Gill, David Donsker & Pamela Rasmussen (Eds) is licensed under a Creative Commons Attribution 3.0 Unported License." (http://creativecommons.org/licenses/by/3.0/). Cite: Gill F, D Donsker & P Rasmussen (Eds). 2026. IOC World Bird List (v15.2). doi 10.14344/IOC.ML.15.2. Multilingual list compiled by Peter Kovalik; its Chinese names are credited to Zheng Guangmei (Ed.) 2021, *A Checklist on the Classification and Distribution of the Birds of the World* (2nd ed., Science Press); Jian Mei 2023; China Bird Report Editors 2022, *The CBR Checklist of Birds of China* v10.0; Zheng Zuoxin 2002, 世界鸟类名称 (2nd ed.); traditional names: Juan Ching-Sung 2017, *World Traditional Chinese Bird List* (Wild Bird Society of Taipei). The spreadsheet itself has no separate licence line for these columns: we rely on the site-wide CC BY 3.0 statement. 2 rows from Wikidata labels (https://www.wikidata.org/wiki/Wikidata:Licensing: "All data in Wikidata has a CC0 license."). Matched by scientific name, then by identical English name for genus transfers, plus 6 reviewed lumps where AviList's broader species takes the IOC name of a lumped constituent (4 by identical English name; *Porphyrio porphyrio* 紫水鸡 and *Taeniopygia guttata* 斑胸草雀 by judgement: the taxon seen in China / the US); *Butorides striata* left empty and *B. virescens* from Wikidata because the IOC names look swapped; 59 species (mostly 2025–26 splits) have no name and show English |
| `engine/birdcm/data/region-grid.csv`, `engine/birdcm/data/boundaries.json` (in this repository) | Points covering each country and first-level division of the place list (reading the location prior over a whole region), and their simplified outlines (which country / division a point is in) | Derived from Natural Earth 1:50m cultural vectors v5.1.1 (admin 0 countries, admin 1 states/provinces), public domain (https://www.naturalearthdata.com/about/terms-of-use/); built by `engine/tools/build_region_grid.py` |
| `engine/birdcm/data/ebird-names.csv` (in this repository) | For each AviList v2026 species: the Clements v2026 English name and the Cornell Lab species code, for the eBird import file | From the AviList v2026 extended file (columns "ENGLISH NAME: CLEMENTS v2026", "SPECIES CODE CORNELL LAB"), CC BY 4.0: AviList Core Team. 2026. AviList: The Global Avian Checklist, v2026. https://doi.org/10.2173/avilist.v2026 ; built by `engine/tools/build_ebird_names.py` |
| `data/species-map.sqlite` (in this repository, shared by both platforms) | For each AviList v2026 species: Wikidata QID and zh/en Wikipedia article titles, Commons image file name (P18), iNaturalist taxon id, GBIF key, eBird code, with a match state and note per source; aliases with source and licence per row (`docs/species-map-report.md`, built by `engine/tools/build_species_map.py`) | Wikidata CC0 (ids, sitelinks, labels, synonyms); GBIF Backbone Taxonomy (`/v2/species/match`) ids and names, CC BY 4.0 — cite GBIF Secretariat, GBIF Backbone Taxonomy, doi:10.15468/39omei, accessed 2026-11-18; iNaturalist API ids, names and ranks (facts only); AviList v2026 and IOC 15.2 as above (Clements English and traditional Chinese aliases). The licence of each alias row is in its `licence` column |
| Wikipedia summaries and Wikimedia Commons images (not shipped; fetched on demand by the engine, cached in the cache dir) | Species page 物种参考: a short original-language extract of the mapped zh (else en) article and one Commons file | Wikipedia text CC BY-SA 4.0, Wikipedia contributors, shown with title, link, history and revision; each Commons file under its own licence, checked per file (CC0 / CC BY / CC BY-SA with a version; CC BY-NC labelled NC; ND, unknown, public domain without a verified basis refused), author and licence shown under the image |


## Bundled in the macOS app (macos/)

| Component | Licence / terms |
|---|---|
| ExifTool 13.64 by Phil Harvey (https://exiftool.org), unmodified, in `观羽.app/Contents/Resources/engine/exiftool` | "This is free software; you can redistribute it and/or modify it under the same terms as Perl itself": the Artistic License or the GNU GPL (version 1 or later), at the recipient's choice. Both texts ship in `Contents/Resources/licenses` (`ExifTool-LICENSE.txt`, `ExifTool-GPL.pod`) |
| CPython 3.12 (python-build-standalone) and the engine's locked Python dependencies | PSF License and each package's own licence (in its `*.dist-info`); see `macos/THIRD-PARTY.md` |

The iOS Round 3 build uses the global table described below; desktop table selection is separate.

## Native iOS application (`ios/`)

The native app's code is MIT. Its downloaded `mobile-v0` BioCLIP 2.5 Core ML tower uses 8-bit weights (MIT),
`Detector.mlpackage` is D-FINE nano (Apache-2.0), and `Heads.mlpackage` uses the same eye/beak and flight weights
listed above: **non-commercial use only**, disclosed in the app's About screen. Models are bundled in Round 3 and never committed.
The app bundles the Chinese-name table with the IOC v15.2 CC BY 3.0 attribution above, and the clear gate's small
linear parameters together with `clear-training-photos.csv` and `CLEAR-WEIGHTS-LICENSE.md`.
BirdNET runs the original SHA-checked FP32 ONNX weights using an exported fixed graph and Apple's Accelerate;
this does not change the conflicting licence statements recorded above. GBIF/IUCN attribution is also in About;
`-hideIUCN YES` disables IUCN display. The global rarity table is supplied by a local path at build time, pinned by SHA256 in
`ios/tools/fetch_models.py`; development keeps a `-rarityPath` override.
Only verified CC0 iNaturalist images (including a resized derivative) are in `ios/Tests/Fixtures`; their sources,
attributions and original hashes are recorded in `photos.json`. No owner's photographs are included.

## Round 3: files inside the iOS installation

The iOS app now bundles models, compiled on the build machine. No models are committed to Git.
`ios/tools/model-assets.json` pins every published source file and SHA256. `Models/integrity.json`
is generated from the actual compiled resources; launch checks it without copying files from the bundle.

| Bundled file(s) | Licence and attribution |
|---|---|
| `Models/BioCLIP.mlmodelc/**` | BioCLIP 2.5 int8, MIT, Imageomics; compiled from the mobile-v0 release |
| `Models/Detector.mlmodelc/**` | D-FINE nano, Apache-2.0; compiled from mobile-v0 |
| `Models/Heads.mlmodelc/**` | Eye/beak and flight heads, non-commercial only; CUB-200-2011 and CC BY-NC training sources |
| `Models/names.f16`, `Models/names.tsv` | TreeOfLife-200M text vectors CC0; AviList Core Team (2026), AviList v2026, CC BY 4.0, doi:10.2173/avilist.v2026 |
| `Models/BirdNET+_Geomodel_V3.0.4_Global_14K_FP32.onnx` | Direct official v3.0.4 release. Both conflicting licence statements above remain unresolved: geomodel LICENSE-MODELS.md Apache-2.0; birdnet README CC BY-NC-SA 4.0. Cite BirdNET |
| `geo-graph.json`, `avilist-birdnet-geo3.json` | Exported fixed graph/index mapping for those BirdNET weights; same unresolved model statements |
| `clear.json`, `CLEAR-WEIGHTS-LICENSE.md`, `clear-training-photos.csv` | Clear linear weights derived from CC BY / CC0 training photos; complete attribution and weight licence travel with the app |
| `Models/rarity-global.sqlite` | GBIF.org (17 November 2026), GBIF Occurrence Download / search API. IUCN (2026), The IUCN Red List of Threatened Species v2026-1, doi:10.15468/0qnb58. Redistribution of IUCN remains unresolved. `BIRDCM_BUNDLE_IUCN=0` removes every IUCN value from the shipped SQLite data at build time; default 1 for personal builds. Natural Earth shapes public domain |
| `zh-names.json` | IOC World Bird List v15.2, Gill, Donsker & Rasmussen (Eds), doi:10.14344/IOC.ML.15.2, CC BY 3.0; multilingual compilation Peter Kovalik, detailed Chinese credits above. Wikidata fallback CC0 |
| `countries.json`, `regions.json` | Hand-entered representative locations and translations, MIT |
| `region-grid.json`, `boundaries.json` | Natural Earth 1:50m v5.1.1, public domain, https://www.naturalearthdata.com/about/terms-of-use/ |
| `Models/*.source-sha`, `Models/integrity.json`, `Models/iucn-build-flag` | Generated build metadata, MIT with BirdCM code |
| `Localizable.xcstrings`, `PrivacyInfo.xcprivacy`, `NOTICE.md`, app icons / executable | BirdCM code, translations, metadata and generated icon, MIT |

Apple MapKit search/tiles are provided by Apple at runtime; their native attribution is preserved.
Test photos remain CC0-only and are not resources of the Release app. No owner photographs are used.

- App icon and product mark (kingfisher, round-4 design B, `ios/BirdCM/Assets.xcassets`, sources in `ios/design/icon/`): original artwork made for this project, under the project's MIT licence.
- `ios/BirdCM/Resources/ebird-names.csv`: an unchanged copy of `engine/birdcm/data/ebird-names.csv` above (AviList v2026 extended file, CC BY 4.0), bundled in the iOS app for the eBird link and file.
