# fl_cyclo

Florida cyclosporiasis case counts, at **county** level and **weekly** (MMWR
epi-week) resolution, scraped from the Florida Department of Health's public
FLHealthCHARTS "Reportable Diseases Frequency Report" (Merlin surveillance
system):

https://www.flhealthcharts.gov/ChartsReports/rdPage.aspx?rdReport=FrequencyMerlin.Frequency

## Method

The public report page is an ASP.NET / Logi Analytics reporting app
(`rdPage.aspx`). Its visible filter form is not directly queryable with a
simple GET — it drives a hidden iframe (`sub_merlinReport`) whose own `<form>`
posts straight to the actual data endpoint:

```
POST https://www.flhealthcharts.gov/ChartsReports/rdPage.aspx
  rdReport=FrequencyMerlin.FrequencyReport_DimensionGrid
  chkList_County=1,2,...,67
  chkList_Diseases=19                 (Cyclosporiasis)
  chkList_DiseaseStatus=CONFIRMED|PROBABLE
  txtDateFrom=MM/DD/YYYY, txtEndDt=MM/DD/YYYY
  rdDgLoadSaved=MyBookmarkCollection_af77e1d2-e3e4-430b-a721-b0ff438808f5.xml
  rdDgReset=True, rdSubReport=True, rdResizeFrame=True
```

This was found by driving the page with `chromote` (CDP network capture plus
a scripted click-through of the filter form) and inspecting the hidden
iframe's own form. It replays with a single `httr::POST` — **no live browser,
session cookie, or CSRF token is required at runtime.**

**Why per-week requests, not a single query:** the report's pivot ("dimension
grid") UI only exposes Month/Year-level time fields (`Reported Month`,
`Reported Year and Month`, `Reported Year`) — there is no week-level pivot
field, even though the underlying MMWR data is collected and published
weekly. `ingest.R` instead uses the report's *date-range filter* as the week
selector, issuing one request per MMWR epi-week (Sunday-Saturday) per
diagnosis status (CONFIRMED / PROBABLE), and reads the resulting County x
Counts table for that single week. This yields true county + weekly
resolution at the cost of ~2 HTTP requests per week (~0.5s each).

## Output

- `fl_cyclo_cases` — confirmed case count
- `fl_cyclo_cases_probable` — probable case count
- Full county x week grid: counties/weeks with no reported cases are
  recorded as an explicit `0`, not omitted.
- `LOOKBACK_WEEKS` (top of `ingest.R`) controls how many recent MMWR weeks
  are pulled (default 104, ~2 years).

## Incremental fetching

`raw/fl_cyclo_weekly_county_history.csv.gz` persists every week ever fetched;
`raw/fl_cyclo_fetched_weeks.csv` is a manifest of which weeks have actually
been attempted (needed because a week with zero cases produces no data rows,
so row-presence alone can't distinguish "fetched, genuinely zero" from "never
fetched"). Each run only re-fetches the most recent `REFRESH_WEEKS_BACK`
weeks (default 10, to catch revisions) plus anything missing from the
manifest — routine runs take ~13s instead of ~2 minutes. The very first run
on a fresh checkout (no cache present) does a full `LOOKBACK_WEEKS` backfill.

## Caveats for maintainers

- The disease checklist ID (`chkList_Diseases=19` for Cyclosporiasis) and the
  county checklist IDs (1-67) reflect their **alphabetical position** in the
  source site's checkbox lists as of 2026-07. If FL DOH adds/removes an entry
  earlier in either alphabetical list, these numeric IDs would need updating.
- `rdDgLoadSaved` references a fixed "default view" bookmark (Rows=County,
  Values=Counts) that appears to be a report-level default rather than
  session-specific; if FL DOH ever regenerates the report, this bookmark ID
  may need to be re-captured.
- Recent weeks are subject to reporting lag/revision as case investigations
  are completed; FLHealthCHARTS updates every Thursday with the prior MMWR
  week, so the most recent 1-2 weeks in particular may still be revised
  upward in later runs.
- The legacy pre-1997 "Dade County" FIPS code (12025) is explicitly excluded
  from the FIPS lookup in favor of "Miami-Dade County" (12086), which is the
  only county name the source ever reports.
