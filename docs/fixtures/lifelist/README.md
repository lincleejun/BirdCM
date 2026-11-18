# Shared life-list fixtures (desktop engine ↔ iOS)

Synthetic only: invented dates, coordinates and photo bytes. Contract: `docs/design-lifelist.md` §3, §5, §7, §8, §10.
The desktop tests that use these files: `engine/tests/test_library.py`, `engine/tests/test_library_api.py`.
Regenerate the binary / CSV goldens: `cd engine && uv run python tools/make_lifelist_fixture.py`.

| File | What it is |
|---|---|
| `fixture-v1.json` | The §10 deterministic fixture as a declaration: photos (bytes = UTF-8 of `bytes`, `{n}` expanded 1..`repeat`), capture times, places, subjects; expected totals per scope, group keys with estimate and photo count, first-seen days; vectors for `place_key`, `local_day` and `group_key`. |
| `fixture-v1.birdcm` | The desktop engine's export of that fixture (format v1). Importing it into an empty library must give exactly `expected`. |
| `ebird-v1.csv` | The desktop life-list eBird Record Format file for the fixture (all time, fallback-date rows included, counts X). |

## Decisions both sides follow

- **Photo identity**: lowercase hex SHA-256 of the whole original file. A file that cannot be read on the desktop gets
  `sha256("unresolved desktop photo/<path>|<size>|<mtime_ns>")` (never a content digest, never exported with a blob).
- **Stable UUID** (`stable_uuid(text)`): first 16 bytes of SHA-256(UTF-8 text); byte 6 = `(b6 & 0x0F) | 0x50`, byte 8 =
  `(b8 & 0x3F) | 0x80`; lowercase hyphenated. Vector: `stable_uuid("abc") = ba7816bf-8f01-5fea-8141-40de5dae2223`.
- **Desktop subject ID**: `stable_uuid("desktop subject/<hash>/<x0>,<y0>,<x1>,<y1>")`, each coordinate with six decimals
  (`%.6f`), normalised upright `[x0,y0,x1,y1]`. Vector: hash = 64 × `0`, box `[0.1,0.1,0.3,0.3]` →
  `8f37fa25-b453-5c52-8061-5ac2f8eb434f`. Photo-wide edit carrier: subject id `photo`.
- **Desktop record ID**: `stable_uuid("desktop native record/<hash>")`; 64 × `0` → `915ada0c-7c17-5a17-b77e-913d2508c95f`.
- **Place bucket**: `p:<floor(lat*100)>:<floor(lon*100)>` in IEEE double (lon +180 → −180, lat cell capped at 8999);
  `r:<ISO 3166 code>` for a region-only choice; `none`. **Group key**: compact JSON `["obs-v1",sci,local_day,place_key]`
  (no spaces, UTF-8 unescaped).
- **local_day**: the date part of the camera's wall-clock string, never converted through UTC or the device zone.
  Strict parse (`vectors.local_day`); invalid dates are treated as missing (fallback to first identification).
- **Archive**: SQLite, `application_id = 1112101441`, `user_version = 1`, DELETE journal. The §5 DDL is used verbatim,
  **including its indexes** (`ll_one_photo`, `ll_record_day`, `ll_subject_ordinal`, `ll_subject_record`,
  `ll_subject_species`), plus `archive_meta` and `archive_blob`; nothing else (no views, triggers, extra tables). The
  desktop reader accepts exactly these index names plus `sqlite_autoindex_*`. Desktop writes `producer=desktop`,
  `origin=desktop`, `relative_path=NULL`; payloads are stripped of keys named `path`, `stored`, `thumb`, `preview`,
  `folder` or ending in `_path`.
- **Subject in the archive**: `correction_state` is the effective human species state (`species` / `uncertain` /
  `none`); `count_edit` is set only when the estimate is not 1; `excluded` for an excluded box; `model_level` is the
  model's own level (`species|genus|uncertain|unclassified`).
- **eBird checklist**: one per (local_day, place bucket). Coordinates (5 decimals, latitude clamped to ±89.99999) are
  those of the checklist's first eligible evidence ordered by (capture wall time or "", photo hash, subject id); a region
  or no place has blank coordinates. Start time = earliest `HH:mm` of a photo- or user-dated row, else blank. Count X by
  default; checklist comment `From BirdCM photo review; not a complete count` (+ `; capture date missing
  (identification date used)` when any row uses the fallback date). State / country of a point through the one
  point → region mapping (`rarity.place_region`); the fixture's points (Chad, `TD`) give the same answer with or
  without the global rarity table.
