# in_cyclo

Indiana cyclosporiasis outbreak investigation (2026) case counts, at **county**
level and **daily** resolution (the finest of any source in this project),
from the Indiana Department of Health (IDOH).

This is a dcf data source project, initialized with `dcf::dcf_add_source`.

## Source

IDOH publishes a "Cases by County" table inside a collapsible accordion on its
Infectious Disease Epidemiology & Prevention Division (IDEPD) **Cyclosporiasis**
resource page:

https://www.in.gov/health/idepd/diseases-and-conditions-resource-page/cyclosporiasis/#Cases_by_County

This is a plain server-rendered HTML `<table>` - **not** Power BI, ArcGIS, or
Tableau. A normal `httr::GET()` with a standard browser `User-Agent` header
returns it directly (status 200); no headless browser is needed at runtime.

## Method

`ingest.R`:
1. Downloads the Cyclosporiasis resource page and extracts the "Cases by
   County" table plus its "Last updated: <date>" caption (identifying the
   table by its header text rather than assuming table order, since the page
   has other tables/tabs too).
2. Resolves the caption to a full date. The caption gives only a month/day
   (e.g. "July 20") with no year; the year is inferred as the current year
   unless that would place the date in the future, in which case the previous
   year is used.
3. Compares the extracted table + date against the last processed state
   (`process.json`); if unchanged, does nothing further (IDOH does not update
   the table on weekends/holidays, so a same-day or weekend re-run is a no-op).
4. If changed, appends this dated snapshot to a persistent long-format history
   file, `raw/in_cyclo_county_snapshots.csv`. **This accumulation is
   important**: the IDOH page itself only ever shows the single latest
   cumulative snapshot (no historical table), so building an actual daily time
   series requires this script to remember every day's snapshot across
   successive scheduled runs.
5. Maps county names to 5-digit FIPS codes via `resources/all_fips.csv.gz`,
   matching on a punctuation-stripped, lowercased key (so "St. Joseph" matches
   "St. Joseph County").
6. Writes `standard/data.csv.gz` with columns `geography`, `time` (the native
   per-update date, kept at daily resolution rather than rounded to a Saturday
   week-ending date, since IDOH's own update cadence is already daily),
   `in_cyclo_cases_cumulative` (cumulative cases since the investigation
   began, May 1, 2026 - as IDOH itself frames it), and `in_cyclo_cases_new`
   (derived day-over-day incident count; `NA` for a county's first observed
   date, since there is no prior snapshot to difference against).

## Caveats for future maintainers

- **This is an active-investigation-specific page.** Once IDOH declares the
  investigation over, this page's structure, URL, or existence may change, or
  the table may be removed entirely. If `ingest.R` starts failing, check the
  source URL manually before assuming a code bug.
- The table updates **each day, Monday through Friday, by 1pm EDT** (data
  reported as of noon); it is not updated on weekends or state holidays, so a
  "daily" difference in `in_cyclo_cases_new` occasionally spans more than one
  calendar day.
- Counties with zero cumulative cases are not listed by IDOH at all - this
  ingest does not synthesize zero rows for counties never listed, matching
  the convention used by `mi_cyclo` for its similarly-structured outbreak page.
- IDOH notes that "data are subject to change as additional information is
  available" (e.g. reclassification), so `in_cyclo_cases_new` can in principle
  be slightly negative in a revision - this reflects genuine source-data
  revisions, not a bug.
- The page also reports statewide totals by sex and age range (e.g. "Total
  Cases: 427", "56% female", "age range 11-91 years") - these are not
  county-level and are not captured by this ingest, which targets the
  county-level table specifically.

## Commands

```R
dcf_check()
dcf_process()
```
