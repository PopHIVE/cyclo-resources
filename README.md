# cyclo-resources

A standalone [DCF](https://dissc-yale.github.io/dcf/) (Data Collection
Framework) project that collects U.S. cyclosporiasis (Cyclospora infection)
case counts at the finest available spatial (county) and temporal (weekly)
resolution, following the same conventions as
[PopHIVE/Ingest](https://github.com/PopHIVE/Ingest).

There is also a dashboard highlighting these resources: https://pophive.github.io/cyclo-resources/

Please cite the use of data from PopHIVE and the original source. the DOI for PopHIVE is [![DOI](https://zenodo.org/badge/1018069747.svg)](https://doi.org/10.5281/zenodo.17345935)

## Scope

Cyclosporiasis is a nationally notifiable disease, but CDC's national NNDSS
feed (already ingested in the sibling `../ingest` PopHIVE/Ingest repo, source
`nnds`) only reports at state/reporting-area level. This project instead
targets **state health department sources that publish county-level, weekly
(or better) case data** — a much stricter bar that most states do not meet
for a disease this rare.

### Sources included

| Source | State | Resolution | Mechanism | Status |
|---|---|---|---|---|
| `data/fl_cyclo` | Florida | County x Week | Reverse-engineered stable POST to FLHealthCHARTS' "Reportable Diseases Frequency Report" (Merlin surveillance system) | Working |
| `data/mi_cyclo` | Michigan | County x Week | Server-rendered HTML table on MDHHS's "Infectious Disease Outbreaks" page (2026 outbreak-specific) | Working |
| `data/oh_cyclo` | Ohio | County x Week | Direct query against the Tableau Server view underlying ODH's "Summary of Infectious Diseases in Ohio" dashboard | Working |

### States screened and rejected

Before building the above, other states were screened against the same
county+weekly+current bar and did not qualify:

- **California** (CHHS/CDPH "Infectious Diseases by County, Year, and Sex"):
  county-level but **annual only**, and lags ~2-3 years (through 2023 as of
  2026). Clean CKAN API (`data.chhs.ca.gov`, resource
  `75019f89-b349-4d5e-825d-8b5960fc028c`) if annual county data is ever
  wanted later.
- **Oregon** (ACDP weekly/monthly Tableau Public dashboards): the *monthly*
  report has confirmed county-level cyclosporiasis detail, but the *weekly*
  report only covers a curated "selection of reportable diseases" and it was
  not confirmed that cyclosporiasis is among them — so weekly+county
  resolution specifically was not established.
- **Wisconsin, Minnesota**: state-level annual only, no county breakdown
  published for cyclosporiasis.
- Most other states either don't publish structured cyclosporiasis data at
  all, or only publish annual state-level summaries (PDF/narrative).

## Project structure

Follows PopHIVE/Ingest conventions exactly:

```
cyclo-resources/
├── data/
│   ├── fl_cyclo/{ingest.R, measure_info.json, process.json, raw/, standard/}
│   ├── mi_cyclo/{...}
│   └── oh_cyclo/{...}
├── resources/
│   ├── all_fips.csv.gz                       # FIPS crosswalk (copied from ../ingest)
│   └── ct_planning_regions_pop_under5.csv.gz
├── settings.json
└── scripts/build.R
```

Each `ingest.R`:
- Writes `standard/data.csv.gz` with `geography` (FIPS), `time` (`YYYY-mm-dd`,
  Saturday week-ending), and one or more `{state}_cyclo_*` value columns
- Uses `dcf::dcf_process_record()` for change detection
- Was built by directly reverse-engineering each state's dashboard (via
  `chromote` CDP network capture during development) down to a stable,
  browser-free HTTP call for production use — see each source's `README.md`
  for the full discovery narrative and caveats.

## Running

```r
# From project root, process one source:
dcf::dcf_process("fl_cyclo")
dcf::dcf_process("mi_cyclo")
dcf::dcf_process("oh_cyclo")

# Or all at once:
dcf::dcf_build()
```

## Known limitations / follow-ups

- **Incremental fetching**: `fl_cyclo` and `oh_cyclo` cache every week they've
  ever fetched in a persistent `raw/*_history.csv.gz` file plus a
  `raw/*_fetched_weeks.csv` manifest (needed because a week with zero cases
  produces no data rows, so row-presence alone can't tell "fetched, genuinely
  zero" from "never fetched"). Each run only re-fetches the most recent
  `REFRESH_WEEKS_BACK` weeks (default 10, to catch revisions/reporting lag)
  plus anything missing from the manifest; everything older is trusted from
  cache. This dropped routine run time from ~2 minutes to ~13 seconds (FL) and
  from ~20-30 minutes to ~45 seconds (OH, which also redoes a cheap 14-request
  annual scan every run so a newly-active historical year is picked up
  automatically). The very first run on a machine with no cache yet still does
  a full backfill.
- **Michigan is outbreak-specific**: `mi_cyclo` scrapes an active-2026-outbreak
  webpage that may be restructured or removed once the outbreak is declared
  over. It also only reports *cumulative-since-outbreak-start* counts (not
  discrete weekly counts from an official time series) — a `mi_cyclo_cases_new`
  column derives incident counts by differencing successive cumulative
  snapshots collected by this scraper over time, so it converges to a real
  weekly time series only after several scheduled runs.
- No `bundle_*` combining these three sources has been created yet — this
  project currently focuses on per-state collection.
