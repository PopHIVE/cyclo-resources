# epic_health_alerts

Cyclosporiasis alerts from Epic Research's Health Alerts page, at **state or
county** level and **weekly** resolution.

This is a dcf data source project, initialized with `dcf::dcf_add_source`.

## Source

Epic Research publishes county- or state-level disease alerts (surfaced via
statistical surveillance over Epic Cosmos encounter data) on its Health Alerts
page:

https://www.epicresearch.org/health-alerts/

The page currently covers six conditions (Acute Pharyngitis, Cyclosporiasis,
Hand/Foot/Mouth Disease, Heat Illness, Toxic Effect of Smoke, Viral
Gastroenteritis), shown behind a client-side condition filter, all present in
one page load. This source only extracts the **Cyclosporiasis** table.

There is no API or downloadable file - the page is plain server-rendered
(Next.js) HTML with one `<table>` per condition; `ingest.R` locates the right
table by matching its `<h3>` heading text ("Cyclosporiasis"), since section
order on the page is not guaranteed to stay fixed.

## Method

`ingest.R`:
1. Downloads the Health Alerts page and extracts the Cyclosporiasis table
   (State, County, Estimated Onset, Cases per 100k).
2. Compares the page content against the last processed state
   (`process.json`); if unchanged, does nothing further.
3. If changed, maps each row to a FIPS geography: `(State-Wide)` rows use the
   2-digit state FIPS; named-county rows are matched to 5-digit county FIPS
   via `resources/all_fips.csv.gz`.
4. Because the source page only ever shows **currently active** alerts (no
   historical archive), `time` is set to the Saturday ending the current
   epiweek (the as-of/scrape date), and each run's rows are **appended** to
   `standard/data.csv.gz` rather than overwriting it - this is what allows a
   real time series to accumulate across successive scheduled runs. A row is
   only replaced if a later run produces a value for the exact same
   `(geography, time)` pair.
5. Writes `standard/data.csv.gz` with columns `geography`, `time`,
   `estimated_onset`, `partial_week_flag`,
   `epicalert_cyclosporiasis_cases_per_100k`, and `page_last_updated` (the
   date shown in the page's page-wide "Last updated" banner as of this
   scrape).

## Caveats for future maintainers

- **Snapshot, not archive**: a geography stops appearing in new scrapes once
  Epic Research's alert for it is no longer active. Historical rows already
  collected by this script are preserved, but there is no way to backfill
  alerts that existed before this source was first ingested.
- **Partial weeks**: the source page marks some rates with a trailing `*`,
  meaning the rate is based on a partial reporting week and may still be
  revised upward; this is captured in `partial_week_flag` rather than
  discarded.
- **State-wide vs. county alerts**: Epic Research issues state-wide alerts
  instead of county-level ones when county counts are small (to preserve
  patient privacy) or when a signal only appears in the statewide aggregate.
- If `ingest.R` starts failing with "Cyclosporiasis section not found", check
  the source page manually first - the site is a general Epic Research page
  (not outbreak-specific), so structural changes are more likely to be a
  site-wide redesign than a page being retired.

## Commands

```R
dcf_check()
dcf_process()
```
