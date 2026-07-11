# oh_cyclo

Ohio county-level, weekly Cyclosporiasis case counts, scraped from the Ohio
Department of Health's public "Summary of Infectious Diseases in Ohio"
dashboard.

## Source and method

The dashboard's own portal page
(`https://data.ohio.gov/wps/portal/gov/data/view/summary-of-infectious-diseases-in-ohio`)
is an IBM WebSphere portal page that requires a live navigation-state token
and cannot be fetched headlessly. It embeds a **Tableau Server** visualization
hosted at `analytics.das.ohio.gov` (site `ODHDPPUB`, workbook
`GeneralCaseCountPublicPROD`, dashboard `GeographicalDistribution`).

That published Tableau view supports the standard, unauthenticated Tableau
Server crosstab CSV export:

```
GET https://analytics.das.ohio.gov/t/ODHDPPUB/views/GeneralCaseCountPublicPROD/GeographicalDistribution.csv
```

which returns `County (group),Case Count` for the county map currently in
view. The dashboard's filter/parameter controls can be set directly via the
query string, using the same names Tableau uses internally (discovered via a
`chromote` CDP network capture of the page's Tableau `bootstrapSession`
response -- see `ingest.R` comments for the full narrative):

- `Reportable Condition` (quick filter) -- disease name, e.g. `Cyclosporiasis`
- `p_startdate` / `p_enddate` -- the two date parameters shown on the
  dashboard as "Event Start Date" / "Event End Date"

Requesting a single Sunday-Saturday week therefore returns each Ohio county's
case count for that disease and that week alone -- true county x week
resolution, with no browser/JS session needed at runtime.

`ingest.R` first does a cheap annual scan (one request per year back to 2013)
to find which years have any reported Cyclosporiasis activity in Ohio, then
only drills into weekly resolution for those years (zero-filling the rest
without further requests). See the header comment in `ingest.R` for details,
and for how suppression (or the observed lack of it at this resolution) is
handled.

## Incremental fetching

`raw/oh_cyclo_weekly_history.csv.gz` persists every active-year week ever
fetched; `raw/oh_cyclo_fetched_weeks.csv` is a manifest of which weeks have
actually been attempted (needed because a week with zero cases produces no
data rows, so row-presence alone can't distinguish "fetched, genuinely zero"
from "never fetched"). Each run redoes the cheap annual scan (so a newly
active historical year is picked up automatically) but only re-fetches the
most recent `REFRESH_WEEKS_BACK` weeks (default 10) plus anything missing
from the manifest — routine runs take ~45s instead of ~20-30 minutes for a
full 2013-present re-scan. The very first run on a fresh checkout (no cache
present) does a full backfill of every active-year week.
