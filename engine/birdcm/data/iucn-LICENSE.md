# iucn.csv: licence and attribution

`iucn.csv` is **not** under BirdCM's MIT licence. It is licensed under
[Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/legalcode),
the licence of its source. Keep this notice with every copy of the file or of data derived from it.

## Source

IUCN (2026). The IUCN Red List of Threatened Species. Version 2026-1. https://www.iucnredlist.org.
Downloaded on 2026-07-28. https://doi.org/10.15468/0qnb58

- The checklist dataset IUCN itself publishes through GBIF (publishing organisation: International Union for
  Conservation of Nature, GBIF organisation `d44af9a3-e779-40c0-a186-79e7717c6d2b`): dataset key `19491596-35ae-4a91-9a98-85cf505f1bd3`,
  https://www.gbif.org/dataset/19491596-35ae-4a91-9a98-85cf505f1bd3
- Archive: https://hosted-datasets.gbif.org/datasets/iucn/iucn-latest.zip, Red List version 2026-1, published
  2026-07-28, downloaded by us 2026-11-19, sha256 `2ed2c5f75667fa2dee9dc718406b5ba094fa9312e548934916b16c0c509ccb7d`
- Basis for the licence: the archive's own metadata (`eml.xml`: "This work is licensed under a Creative Commons
  Attribution (CC-BY) 4.0 License", identifier CC-BY-4.0) and the GBIF registry entry of the dataset
  (`license: http://creativecommons.org/licenses/by/4.0/legalcode`), both read 2026-11-19. This covers this
  dataset. It does not cover the Red List website or API, whose own terms restrict commercial use; BirdCM does not
  use them.

## Changes we made

Built by `engine/tools/build_iucn.py`; the file is a small extract, modified from the source:

- Only birds (class Aves, rank species), and of each only the **global** category, written as its code
  (LC, NT, VU, EN, CR, EW, EX, DD). No assessment text, ranges, names in other languages or other fields.
- Scientific names were matched to AviList v2026 (11,172 species). The `match` column says how, per row:
  `exact` the same name (10,288); `synonym` a reviewed synonym from GBIF Backbone Taxonomy or a Wikidata taxon
  synonym, in `data/species-map.sqlite` (115); `genus` a genus transfer, another name Wikidata lists for the species
  with the same epithet in a different genus (187); `spelling` the same genus and an epithet differing only in its
  Latin gender ending (7). The last three only to a source name that is not an AviList species, one to one.
  `iucn_name` is the name in the source when it differs.
- 575 AviList species have no matched assessment and no row. A missing row means "not matched", not "Not Evaluated".
- A category is the one IUCN gives the taxon of the matched name. Where AviList and IUCN (BirdLife) draw a species'
  limits differently, it may not describe exactly the same population.

The matching and any errors in it are ours. IUCN and GBIF do not endorse BirdCM or this use of the data.
