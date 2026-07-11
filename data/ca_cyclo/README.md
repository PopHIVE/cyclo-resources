# ca_cyclo

California cyclosporiasis case counts, at **county** (Local Health Jurisdiction)
level and **quarterly Year-to-Date** resolution, scraped from the California
Department of Public Health's public "Provisional Summary Report of Selected
California Reportable Diseases":

https://www.cdph.ca.gov/Programs/CID/DCDC/Pages/IDBProvisionalSummaryReport.aspx

## Source and method

The CDPH page above is a SharePoint wrapper that simply embeds an `<iframe>`
pointing at the actual static report:

```
https://skylab.cdph.ca.gov/idbsssprovisional/SSSprovisional.html
```

Despite the "skylab" (Shiny-style) subdomain, this specific report is a
**fully static Quarto/R Markdown HTML export** (~2 MB) — there is no live
Shiny server session or websocket involved, and no headless browser is needed
at runtime. A plain `httr::GET()` returns the complete page, including two
`DT::datatable()` "htmlwidgets" whose entire underlying data is embedded
directly as `<script type="application/json">` blobs:

1. **"Disease by Month"** — statewide only; columns are Disease / YTD /
   January / February / March (or whichever months the current period
   covers).
2. **"Disease by LHJ"** — the one used here; columns are Disease + one column
   per California Local Health Jurisdiction (~60 columns: 58 counties, with
   Alpine and Sierra combined into one "Alpine/Sierra" column, plus 3
   independent city health departments — Berkeley, Long Beach, Pasadena).
   Values are the cumulative **Year-to-Date** (Jan 1 through the end of the
   covered period) case count.

`ingest.R` tells the two widgets apart by column count (~60 vs. ~4) rather
than by matching Quarto's auto-generated `htmlwidget-<hash>` ids, since those
ids are not guaranteed stable across re-renders.

## IMPORTANT LIMITATION: not a true county x month cross-tab

Unlike Michigan, Florida, or Ohio, this source does **not** give county +
month resolution simultaneously:

- The **LHJ** breakdown (used here) is **YTD-cumulative only** — no
  within-period month split by county.
- The **month** breakdown in the same report is **statewide only** — no
  county detail.

So the finest resolution actually achievable here is **county x quarter
(cumulative)**. This is a real characteristic of the CDPH source, not a
limitation of this scraper. See the caveats in the original state-availability
report this ingest was commissioned from — California was flagged there as
"the main borderline case" for exactly this reason.

## Output

CDPH republishes this report roughly quarterly (its history: a Jan-Mar
release "as of" ~May 1; presumably Jan-Jun, Jan-Sep, and a Dec year-end
release follow the same cadence). Like `mi_cyclo`'s MDHHS page, the live URL
only ever shows the single latest YTD snapshot — there is no historical
archive at this URL. So, exactly like `mi_cyclo`, this script accumulates one
dated snapshot per distinct report release into a persistent history file,
`raw/ca_cyclo_lhj_snapshots.csv`, building a real multi-quarter time series
across successive scheduled runs.

- `ca_cyclo_cases_ytd` — cumulative case count since January 1 of that year.
- `ca_cyclo_cases_new` — derived quarter-over-quarter increment, computed only
  **within the same calendar year** (YTD resets every January 1, so a Q1
  value is never differenced against the prior year's Q4/year-end value).
- `suppressed_flag` — 1 if CDPH masked the count as `"SC"` (Suppressed Count,
  small numbers per DHCS de-identification guidelines); the count itself is
  `NA` in that case, not imputed to zero.

## Caveats for future maintainers

- **Berkeley, Long Beach, and Pasadena** are independent city health
  departments (their own LHJ) but sit entirely within Alameda County and Los
  Angeles County respectively. Their case counts are summed into the
  surrounding county, mirroring `mi_cyclo`'s Detroit-City-into-Wayne-County
  convention.
- **Alpine and Sierra counties share one combined "Alpine/Sierra" LHJ** in
  the source (both are very sparsely populated). Since this single count
  cannot be disaggregated, `ingest.R` duplicates the SAME value onto both
  counties' rows. A consequence: summing `ca_cyclo_cases_ytd` across all 58
  county rows will double-count this one LHJ's cases. A future maintainer
  wanting a clean statewide total should sum only 57 of the 58 counties (drop
  either Alpine or Sierra) or track "Alpine/Sierra" as its own combined
  geography instead of exploding it to two FIPS codes.
- **This ingest only covers the live provisional (current-year) report.**
  CDPH separately publishes static, finalized "Year-end" PDF reports for past
  years (2022, 2023, 2024 are linked from the parent
  `Monthly-Summary-Reports-of-Selected-General-Communicable-Diseases-in-CA`
  page) with the same Disease x Month and Disease x LHJ structure. Those are
  **not** scraped here (PDF table extraction is a materially different
  problem); backfilling them would be a natural follow-up for deeper history.
- The "Disease by LHJ" widget's column identification depends on
  `x$options$columnDefs[[i]]$name` entries in the embedded JSON. If CDPH
  changes the Quarto template (e.g. renames "Disease" or restructures
  `columnDefs`), `ingest.R`'s column-count heuristic (picking the widget with
  the most columns) is the more robust fallback signal to check first.
- Data are explicitly labeled **provisional** by CDPH and "subject to change"
  in later releases as case investigations complete — the most recent
  quarter in particular may be revised upward in a subsequent scheduled run.
- This script (unlike `mi_cyclo`, `fl_cyclo`, `oh_cyclo`) has **not yet been
  executed end-to-end** in this environment (no local R installation was
  available at authoring time); it was hand-verified against a real fetch of
  the live page's HTML/JSON structure, but should be exercised by the next
  scheduled CI run before being fully trusted.
