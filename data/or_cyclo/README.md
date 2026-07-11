# or_cyclo

**Status: BLOCKED — not yet implemented.** This is a scaffolded dcf source
project; `ingest.R` intentionally does not attempt a scrape (see below).

## Source

Oregon Health Authority (OHA) publishes weekly and monthly Communicable
Disease Surveillance data (which would include Cyclosporiasis) exclusively as
two interactive **Tableau Public** dashboards, linked from:

https://www.oregon.gov/oha/ph/diseasesconditions/communicabledisease/diseasesurveillancedata/weekly-monthlystatistics/pages/index.aspx

- Weekly (by report week): `https://public.tableau.com/views/WeeklyCommunicableDiseaseReport/ACDPWeeklyReport`
- Monthly (10-year, by county/month/year/age/race/ethnicity):
  `https://public.tableau.com/views/MonthlyReportDashboard_EXTERNAL_AGGREGATED/MonthlyReportDashboard`

No PDF, Excel, or CSV alternative to these dashboards was found on the OHA
page or anywhere else searched.

## Why this is blocked

Tableau **Public** (as opposed to Tableau **Server**, which powers `oh_cyclo`)
was redesigned in 2024+ into a client-rendered single-page app sitting behind
AWS WAF bot protection. Every path tested during development returned the
exact same ~1.4 KB JS-challenge shell instead of real content:

```
GET https://public.tableau.com/views/WeeklyCommunicableDiseaseReport/ACDPWeeklyReport
GET https://public.tableau.com/views/WeeklyCommunicableDiseaseReport/ACDPWeeklyReport.csv   (classic Tableau Server crosstab-export suffix - 404s here)
GET https://public.tableau.com/views/WeeklyCommunicableDiseaseReport/ACDPWeeklyReport?:embed=y  (redirects, then WAF shell)
GET https://public.tableau.com/vizql/w/.../bootstrapSession/sessions/   (404 - needs a session id only obtainable from a live JS-executed page)
GET https://public.tableau.com/views/.../ACDPWeeklyReport.twb            (404)
GET https://public.tableau.com/workbooks/....twbx                       (404 - correct download URLs need an internal numeric workbook id, itself only obtainable by executing the page's JS)
```

This is a genuine, reproducible blocker for any plain-HTTP client (curl,
`httr`, Python `requests`, etc.) — it is not a matter of finding the right
header or query parameter. A working scrape needs an actual (or headless)
browser to execute Tableau Public's JS, establish a vizql session, and then
call its internal data/crosstab endpoint — the same general technique
`mi_cyclo` and `oh_cyclo`'s authors used (via `chromote`) to *discover* their
sources' mechanisms, except here the browser step would be required at
**runtime**, every scheduled run, not just once during development — because
Tableau Public's WAF gate has to be passed on every request, not just the
first.

## What would unblock this

1. **Add headless-browser capability to the GitHub Actions build** (e.g.
   install a real Chrome + `chromote`, or use Playwright/Selenium) so
   `ingest.R` can drive the dashboard, extract data via its "Download
   Crosstab" feature or the vizql API, and parse the result. This is a
   meaningful addition to the pipeline's runtime dependencies/CI job, not a
   small code change — flagging for a scoping decision rather than doing it
   unilaterally.
2. **Find a different Oregon publication** of the same weekly/monthly
   cyclosporiasis data that isn't gated behind Tableau Public (none was found
   as of this writing; OHA's own page links only to the two dashboards
   above).
3. **Request the data directly** from OHA's Acute and Communicable Disease
   Prevention section (no public API/bulk-download exists).

## Next steps for a future maintainer

If you have access to a browser-automation-capable runtime, start by loading
the Weekly dashboard in a real/headless browser, opening DevTools → Network,
and looking for a `bootstrapSession` POST response (contains a session id)
followed by requests to endpoints under `/vizql/w/<workbook>/v/<view>/...` —
this mirrors exactly what `oh_cyclo`'s author did (see that project's
`ingest.R` header comment) for the equivalent Tableau **Server** dashboard,
except the resulting session/request would need to be replayed by an actual
browser engine at runtime here rather than being replayable via plain
`httr::GET`/`POST`, since Tableau Public's WAF layer must be satisfied on
every run.
