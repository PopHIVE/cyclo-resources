# wv_cyclo

West Virginia cyclosporiasis outbreak (2026) case counts, at **county** level,
from the West Virginia Department of Health Office of Epidemiology and
Prevention Services (OEPS).

This is a dcf data source project, initialized to follow the same conventions
as `mi_cyclo` (see that source's `README.md` for the closest analogue).

## Source

OEPS publishes an outbreak page here:

https://oeps.wv.gov/cyclosporiasis-outbreak

Unlike every other source in this project, this page has **no structured data
at all** - no Tableau/Power BI/ArcGIS embed, no HTML `<table>`, no CSV/JSON
download. The entire "Cases by County" breakdown and the daily epi curve exist
only as text baked into a single static PNG image ("Dashboard 2.png",
re-uploaded to a dated `/sites/default/files/YYYY-mm/` path each time OEPS
updates it - the surrounding page itself is a plain server-rendered Drupal
page).

## Method

`ingest.R`:
1. Downloads the outbreak page and extracts the "Last updated" date, the
   printed "Total Cases" figure (used only as a sanity check), and the current
   dashboard image URL.
2. Downloads that image and saves a dated raw snapshot for audit trail.
3. Crops the "Cases by County" panel (the right-hand sidebar of the image -
   clean, high-contrast printed text, unlike the epi curve bar chart on the
   left, which is **not** digitized) and runs it through OCR
   (`magick::image_crop()` + `tesseract::ocr()`).
4. Parses the OCR'd lines into county/count pairs and compares them against
   the last processed state (`process.json`); if unchanged, does nothing
   further.
5. If changed, appends this dated snapshot to a persistent long-format history
   file, `raw/wv_cyclo_county_snapshots.csv`. **This accumulation is
   important**: the source image itself only ever shows the single latest
   cumulative snapshot (no historical archive), so building an actual time
   series requires this script to remember every snapshot across successive
   scheduled runs.
6. Maps OCR'd county names to 5-digit FIPS codes via
   `resources/all_fips.csv.gz` (every WV county name in this table is a single
   word, so matching is a straightforward lowercase string match).
7. Writes `standard/data.csv.gz` with columns `geography` (5-digit county FIPS,
   or `54` for the statewide total), `time` (the OEPS "Last updated" date -
   OEPS updates Tuesdays and Fridays, not a fixed weekly cadence, so this is
   not aligned to a Saturday like `mi_cyclo`/`oh_cyclo`), `wv_cyclo_cases_cumulative`,
   and `wv_cyclo_cases_new` (derived incident count; `NA` for a geography's
   first observed snapshot).

## Caveats for future maintainers

- **This is an active-outbreak-specific page.** Once OEPS declares the
  outbreak over, this page's structure, image, or existence may change or be
  removed entirely. If `ingest.R` starts failing or warning about unmatched
  counties/OCR mismatches, check the source page and image manually before
  assuming a code bug.
- **OCR is inherently less reliable than parsing structured data.** The crop
  box (`CROP_X_FRAC`/`CROP_Y_FRAC`/`CROP_W_FRAC`/`CROP_H_FRAC` in `ingest.R`)
  is a hardcoded fraction of the image's dimensions, calibrated against the
  dashboard layout as of 2026-07-17. If OEPS changes the image template (panel
  position/size, font, colors), the crop and/or the OCR line-parsing regex
  will need recalibration. `ingest.R` logs a warning (not a hard failure) if
  the OCR'd county sum doesn't match the page's own printed "Total Cases"
  figure - treat repeated warnings as a signal to inspect the raw image in
  `raw/wv_cyclo_dashboard_*.png` manually.
- The epi curve bar chart (daily case counts by onset/report date) on the left
  side of the dashboard image is intentionally **not** extracted - bar-height
  digitization from a raster image is far less reliable than OCR of printed
  table text, and county-level case counts were the data of interest here.
- As with `mi_cyclo`, OEPS notes case counts "may change as additional
  information becomes available", so `wv_cyclo_cases_new` can in principle be
  slightly negative in a revision update - this reflects genuine source-data
  revisions, not a bug.

## Commands

```R
dcf_check()
dcf_process()
```
