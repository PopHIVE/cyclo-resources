# mi_cyclo

Michigan cyclosporiasis outbreak (2026) case counts, at **county** level and
**weekly** resolution, from the Michigan Department of Health and Human
Services (MDHHS).

This is a dcf data source project, initialized with `dcf::dcf_add_source`.

## Source

MDHHS publishes a "Cases by county" table inside the "Detailed Outbreak Data"
accordion on its **Infectious Disease Outbreaks** page:

https://www.michigan.gov/mdhhs/keep-mi-healthy/infectious-diseases/infectious-disease-outbreaks

(Note: this is a *different* page from the similarly-named "Cyclosporiasis
Outbreak" landing page - that page is prose/prevention-guidance only and does
not contain the data table.)

Despite looking like it might be an embedded interactive dashboard, this is a
plain server-rendered HTML `<table>` on a Sitecore CMS page - **not** Power BI,
ArcGIS, or Tableau. A normal `httr::GET()` with a standard browser
`User-Agent` header returns it directly (status 200); no headless browser is
needed at runtime (`chromote` was only used during development to locate the
table, by rendering the page and inspecting `document.documentElement.outerHTML`
for `<table>` content, since a raw fetch of the *other* cyclosporiasis URL is
bot-blocked and initially led the investigation toward assuming a JS
dashboard).

## Method

`ingest.R`:
1. Downloads the Infectious Disease Outbreaks page and extracts the "Cases by
   county" table plus its "Last Update: <date>" caption.
2. Compares the extracted table + date against the last processed state
   (`process.json`); if unchanged, does nothing further (MDHHS only updates
   this table weekly, on Thursdays, so re-running mid-week is a no-op).
3. If changed, appends this dated snapshot to a persistent long-format history
   file, `raw/mi_cyclo_county_snapshots.csv`. **This accumulation is
   important**: the MDHHS page itself only ever shows the single latest
   cumulative snapshot (no historical table), so building an actual weekly
   time series requires this script to remember every week's snapshot across
   successive scheduled runs.
4. Maps county/jurisdiction names to 5-digit FIPS codes via
   `resources/all_fips.csv.gz`. "Detroit City" is reported by MDHHS as its own
   jurisdiction (Detroit has an independent local health department) but sits
   entirely within Wayne County geographically, so its cases are summed into
   Wayne County (FIPS `26163`).
5. Converts each weekly "Last Update" date (a Thursday) to the Saturday ending
   that reporting week, per project convention.
6. Writes `standard/data.csv.gz` with columns `geography`, `time`,
   `mi_cyclo_cases_cumulative` (cumulative cases since outbreak start,
   June 22, 2026 - as MDHHS itself frames it), and `mi_cyclo_cases_new`
   (derived week-over-week incident count; `NA` for a county's first observed
   week, since there is no prior snapshot to difference against).

## Caveats for future maintainers

- **This is an active-outbreak-specific page.** Once MDHHS declares the
  outbreak over, this page's structure, URL, or existence may change or the
  table may be removed entirely. If `ingest.R` starts failing, check the
  source URL manually before assuming a code bug.
- The **county table** (used here) updates **weekly on Thursdays**; a
  separately-reported **statewide daily total** (e.g. in MDHHS press releases)
  updates more often and will not match the sum of this weekly table on days
  other than Thursday/Friday.
- MDHHS notes that reported case counts "may change as additional information
  becomes available" (e.g. reclassification), so `mi_cyclo_cases_new` can in
  principle be slightly negative in a revision week - this reflects genuine
  source-data revisions, not a bug.
- As of the first ingest run (accessed 2026-07-10), only one weekly snapshot
  (2026-07-09, mapped to time `2026-07-11`) exists, so `mi_cyclo_cases_new` is
  `NA` for every county; it will populate once a second weekly snapshot is
  collected by a subsequent scheduled run.

## Commands

```R
dcf_check()
dcf_process()
```
