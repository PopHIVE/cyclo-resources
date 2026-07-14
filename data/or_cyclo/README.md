# or_cyclo

Oregon cyclosporiasis case counts, **statewide monthly** (exact counts) and
**county-level monthly** (mostly suppressed), scraped from the Oregon Health
Authority's public "Monthly CD Surveillance Report" Tableau Public dashboard:

https://public.tableau.com/views/MonthlyReportDashboard_EXTERNAL_AGGREGATED/MonthlyReportDashboard

linked from:

https://www.oregon.gov/oha/ph/diseasesconditions/communicabledisease/diseasesurveillancedata/weekly-monthlystatistics/pages/index.aspx

## Why this looked blocked at first

Tableau Public's 2024+ front end (the `public.tableau.com/app/profile/...`
URL you get from a normal share link) is a client-rendered SPA sitting
behind AWS WAF bot detection - every plain HTTP request to it returns the
same ~1.4 KB JS-challenge shell, no real content. That's a genuine dead end.

But the classic `/views/<workbook>/<view>?:embed=y&:showVizHome=no` URL
(what "old" embed codes use) bypasses that gate entirely and drives the same
classic **vizql session protocol** used by Tableau *Server* - the same
family of mechanism `oh_cyclo` uses for Ohio's dashboard. No headless
browser is needed at runtime, just three plain HTTP calls (GET, then two
POSTs). See the header comment in `ingest.R` for the full request sequence.

**The one non-obvious trick**: Tableau Public's backend is horizontally
scaled behind a load balancer that pins a session to one node. The
`startSession` response includes a `global-session-header` *response*
header - an opaque affinity token - that must be echoed back as a *request*
header on every subsequent call (bootstrap, filter, tab-navigation), or the
request lands on a different node than the one holding the session and
returns an empty HTTP 410. This was found by diffing a real (headless)
browser's network requests against a plain-HTTP replay; it's undocumented
and doesn't appear in the (Tableau Server-oriented) Python `tableauscraper`
reference project this decode logic was otherwise modeled on.

## Two worksheets, two resolutions

The published dashboard has several tabs (Statewide, by Age Group, by Sex,
by Race/Ethnicity, **by County**, About) - each is its own Tableau
"dashboard" sheet within one workbook, only loaded when navigated to (via a
`goto-sheet` command). A first pass at this ingest only decoded the
default/active "Statewide" tab and concluded Oregon was statewide-only;
that was wrong - the "by County" tab does exist and is scraped too, once
you know to navigate to it. `ingest.R` pulls both:

- **`or_cyclo_cases`** (geography = Oregon state FIPS `41`): exact statewide
  monthly counts from the "Statewide" tab's "Statewide Monthly" worksheet,
  full history back to 2021. Never observed to be suppressed, even at a
  value of 1.
- **`or_cyclo_cases_county`** (geography = 5-digit Oregon county FIPS): from
  the "by County" tab's "by County Count Table" worksheet. **OHA masks any
  county-month cell with fewer than six cases as `"<6"`.** Because Oregon's
  *statewide* Cyclosporiasis total is itself usually in the single digits
  per month, county-level counts are suppressed for the overwhelming
  majority of county-months - during development, 332 of 333 checked
  county-months were masked. This is real, not a scraper bug: it directly
  reflects how thin a single-digit statewide count gets once split across
  36 counties.

Both series share one `standard/data.csv.gz`, with state-level rows
(`geography = "41"`) and county-level rows (5-digit FIPS) coexisting in the
same long table - each row only populates the measure columns that apply at
its own geographic resolution (the other pair is `NA`).

Both the "Disease Name" filter (Cyclosporiasis) and the "Mmwr Year" filter
(all years, since the County tab defaults to the current year only) are
applied via Tableau's `categorical-filter-by-index` command, using the
filter's own already-resolved value list (read out of the bootstrap
response's embedded `filtersJson`) to find the right index - see `ingest.R`
for the full mechanics.

## Caveats for future maintainers

- **Oregon's separate WEEKLY dashboard does not track Cyclosporiasis at
  all.** It only covers a curated set of ~37 diseases (STIs, common
  foodborne/vector-borne illnesses, etc.) - confirmed by inspecting its
  decoded worksheet data during development. So there is no weekly series
  for Oregon in this pipeline, only monthly.
- `"Unknown County"` (case residence not attributable to a specific Oregon
  county) is dropped from the county-level output, same convention as
  `oh_cyclo`.
- Absent county-months and absent statewide-months are both zero-filled
  (Tableau only returns marks for nonzero activity; a small-but-nonzero
  county-month is masked as `"<6"` rather than omitted, so an *absent* row
  can safely be treated as a true zero - it is not itself a suppression
  signal).
- The county-level "Mmwr Year" quick filter must be explicitly set to *all*
  years - it defaults to the current year only, which is why an early
  version of this scraper (before the "by County" tab was found) initially
  missed most of the history even for the Statewide series it did pull
  (that series uses a *different* worksheet whose default was already
  "(All)" years, so no year-filter step was needed there).
- Tableau's `sheetsInfo` list (used to find the "County Table Dashboard"
  tab's internal `windowId` for the `goto-sheet` call) and worksheet/zone
  names (`"Statewide Monthly"`, `"by County Count Table"`) are all
  structural assumptions read from the live dashboard as of 2026-07; if OHA
  redesigns the workbook, `ingest.R`'s explicit `stop()` messages should
  point at exactly which lookup failed.
- **This script has not yet been executed end-to-end in a real R
  environment** (no local R installation was available at authoring time).
  The full request/response protocol and JSON decode logic were validated
  extensively against the live source using an equivalent Python
  implementation during development (see the `ingest.R` header comment),
  and the R port was translated line-by-line from that proven logic, but it
  should be exercised by the next scheduled CI run before being fully
  trusted - if it fails, check the specific `stop()` message first, since
  each one names the exact assumption that broke.
