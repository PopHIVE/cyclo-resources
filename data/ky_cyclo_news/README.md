# ky_cyclo_news

Kentucky cyclosporiasis case counts, at **county** and **state** level, harvested
from **trusted news articles** that relay Kentucky Dept for Public Health (KDPH)
figures - not a KDPH dashboard/API. This is the pilot state for
`../../news_scraper/` (see that folder for the schema, prompt spec, and the KY
regression fixture this ingest is built against).

This is explicitly a **lower-tier "news" source** and must never be blended
unlabeled with the dashboard scrapers in this project (`fl_/in_/mi_/oh_/wv_/
ca_/or_cyclo`) - hence the `ky_cyclo_news_*` column prefix and `source_tier:
"news"` in `measure_info.json`.

## Method

`ingest.R` implements the 6-step pipeline from `../../news_scraper/README.md`:

1. **Discovery** - Google News RSS search for `cyclosporiasis Kentucky`, daily.
   RSS `<link>` values are Google redirect URLs; each is resolved to the real
   outlet URL by following redirects before anything else happens.
2. **Trusted-source gate** - the resolved URL's domain is checked against
   `KY_ALLOWLIST` (tier A = KY public media / statewide daily, tier B = local
   TV/regional). Anything off-list is quarantined: fetched only far enough to
   log it, never sent to the LLM or reconciled.
3. **Fetch + main-text extract** - a plain GET, then a boilerplate strip
   (script/style/nav/header/footer/aside removed) and either the `<article>`
   node or the largest remaining text block. This is a heuristic stand-in for
   trafilatura/readability (no mature R equivalent); low-confidence
   extractions still route to review via the schema's `confidence` field.
4. **LLM extract** - `claude-haiku-4-5`, `temperature = 0`, via a direct
   `httr::POST` to the Anthropic Messages API with `news_extraction.schema.json`
   forced as a tool's `input_schema` (the httr fallback the prompt spec calls
   out, since ellmer's structured-output types would need the schema
   hand-translated field by field). Requires `ANTHROPIC_API_KEY`.
5. **Reconcile** - `../../scripts/reconcile.R::reconcile()`: FIPS resolution
   (state-scoped), Saturday-week snap, Σ(county) vs state-total residual,
   cumulative-monotonicity check against `raw/ky_cyclo_news_history.csv.gz`.
   Anything in `$review` does not enter `standard/` silently.
6. **Store**:
   - `$long` upserts into `raw/ky_cyclo_news_history.csv.gz`, keyed on
     `(geography, count_type, as_of_date)` - a later article revising an
     earlier snapshot replaces that row rather than duplicating it. This file
     **is** `reconcile()`'s long-format schema verbatim (no per-state
     reinvention), which is what lets `check_monotonic()` work against it.
   - `$standard` upserts into `standard/data.csv.gz`, keyed on
     `(geography, time)`; `ky_cyclo_news_cases_new` is then derived by
     differencing the cumulative `confirmed` series in the history file.
   - `$provenance` appends to `raw/ky_cyclo_news_provenance.csv.gz`.
   - `$review` (validation issues, unmatched counties, residual flags,
     cumulative drops) appends to `raw/ky_cyclo_news_review.csv.gz` for
     human-in-the-loop; never auto-merged into `standard/`.
   - `process.json`'s `raw_state.processed_urls` records every article URL
     already handled, so re-running discovery never re-fetches/re-extracts
     the same article.

## Requires

- `ANTHROPIC_API_KEY` env var (LLM extraction step).
- Network access to Google News RSS and the outlet pages themselves.

## Caveats for maintainers

- `KY_ALLOWLIST` in `ingest.R` is a starting point; extend it as new relays
  are confirmed reliable. An off-list outlet is quarantined, not dropped
  silently - check the run log for `quarantined (off-allowlist)` lines if an
  article you expected to see isn't in `standard/`.
- News cadence is event-driven, not scheduled - a stale snapshot is not a
  zero, and `ky_cyclo_news_cases_new`'s implicit time interval between
  snapshots is irregular (see `measure_info.json`).
- `partial_list` articles never get zero-imputed for unnamed counties;
  `complete_list` and `single` are the only coverages that fully describe
  what's named.
- Official-supersedes-news: when a `.gov` KDPH source later covers the same
  `as_of_date`, that news row should be retired - not automated yet, flag for
  a future pass once/if a KDPH dashboard source exists for KY.
- Article prose is never stored, only the extracted facts (county/state ->
  count), the source URL, and attribution (`raw/ky_cyclo_news_provenance.csv.gz`).

## Commands

```R
dcf_check()
dcf_process()
```
