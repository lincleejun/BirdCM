# Export to eBird

Export → choose the birds → "导出 eBird 文件" writes `ebird-record-format.csv` in eBird's **Record Format** (no header
row, one row per species per checklist; a checklist is one day at one place). Format followed: eBird Help Center,
"Upload Spreadsheet Data to eBird", and its "Appendix A (eBird Data Fields)" PDF and Record Format sample sheet (all
read 2026-11-18): the 19 columns in Appendix A's order, its field lengths and ranges, MM/dd/yyyy dates, 24 h times,
duration in minutes, Y/N, X for present. Protocol names follow the current upload page (Incidental, Stationary); the
older Appendix A lists casual / stationary / traveling / area.

To import (nothing is uploaded by BirdCM):
1. On ebird.org: Submit → Import Data → choose **eBird Record Format** → Import File, pick the CSV.
2. **Fix Species**: names are AviList v2026 scientific names with the Clements v2026 English name from AviList's own
   table; the dialog marks the species whose eBird name differs or that eBird does not list. Choose them by hand.
3. **Fix Locations**: a scan placed by a chosen region (a state or country) carries no coordinates — pick the real
   site. Photos with GPS (or a map / device point) carry coordinates.
4. Click **Apply Fixes**, then review the checklists in My eBird.

Checklists are submitted as **Incidental**, "all observations reported: N" (photos show what was photographed, not a
complete count); counts default to X (present). "Stationary" (duration = first to last photo) can be chosen.

