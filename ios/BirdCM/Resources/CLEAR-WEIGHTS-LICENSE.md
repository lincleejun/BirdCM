# clear.safetensors: training data and licence

`clear.safetensors` (12.7 KB, sha256 `d105665ac6ae8f9ded3480af00c9d85b628d13d61c9f3219f3d96cfee109bd8a`) is the
"is there a clear bird in this crop" gate from `heads-repo/clear.py`. It is one linear layer on BioCLIP 2.5's final
image vector, plus two thresholds (`z_min`, `cos_min`).

Unlike `parts.safetensors` and `flight.safetensors`, **it is trained only on CC BY and CC0 photos.** No CC BY-NC,
no share-alike, no CUB, no evaluation-set photo and no owner photo was used:

- 3,000 iNaturalist photos from `bioclip-bird/data/inat-raw`, using only the `cc-by` (2,456) and `cc0` (544) rows of
  its manifest. Golden photos were left out with `distill/embed.py`'s `leaked()`.
- 685 photos (long side 1,000 px or more) from the birding reference set `../birding/spec/media`: CC BY 4.0
  (536) and CC0 (149). Museum specimens and golden photos were left out. For the 684 GBIF photos, each licence
  was checked against the raw GBIF record (`../birding/spec/raw/gbif`). In every case it is the photo's own
  licence, not the occurrence record's.
- Synthetic copies of those photos' bird crops: blurred, defocused, shrunk, or cut to a part.

Every photo, with its licence and attribution, is listed in `clear-training-photos.csv`.

Our reading: CC0 needs nothing. CC BY asks for attribution if the photos, or something adapted from them, are
redistributed. Whether a 1,024-number linear layer counts as an adaptation is unsettled. Shipping the CSV with the
weights meets the attribution terms either way. On that reading the weights carry **no non-commercial
restriction**. They are built on BioCLIP 2.5 (MIT) and need its image tower and the AviList names matrix
(AviList CC BY 4.0) to run. This is our reading, not legal advice.
