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

There are two harvest paths, both news-tier and both landing in the same
`ky_cyclo_news_*` columns through the same `reconcile()` call:

| | **prose** (`ingest.R`) | **structured embed** (`infogram.R`) |
|---|---|---|
| Input | article body text | the graphic's own spreadsheet |
| Extraction | LLM against a JSON schema | direct JSON read, no LLM |
| Coverage | only counties the article names (`partial_list`) | all 120 KY counties, zeros included (`complete_list`) |
| Counts | may be hedged (`count_is_approximate`) | exact |
| Refresh | once per article | re-checked every run; map is revised in place |
| `confidence` | model-reported | fixed 0.95 (`INFOGRAM_CONFIDENCE`) |

The embed path is strictly better data where it exists, and is the only path
that can distinguish "county has zero cases" from "article didn't mention that
county". It is **not** a higher trust tier: the outlet, not KDPH, builds the
graphic, so it stays behind the same `KY_ALLOWLIST` gate and the same review
machinery. See "Infogram embeds" below.

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

## Infogram embeds (`infogram.R`)

Some allowlisted outlets publish their county map as an Infogram embed. Infogram
ships the infographic's underlying spreadsheet into the embed page as a
single-line `window.infographicData={...}` assignment, so the county -> count
table can be read as data instead of inferred from prose. `infogram.R` fetches
it, parses the county table and captions, and assembles a
`news_extraction.schema.json`-shaped object that goes through the *same*
`reconcile()` call as the prose path - no private route into `standard/`.

- **Queue.** `KY_INFOGRAM_SEEDS` in `ingest.R` lists known embeds, checked every
  run. Seeding is necessary because Google News RSS is a rolling window: the
  hosting article ages out within days while the map keeps being revised.
  Embeds found in freshly fetched allowlisted articles are appended
  automatically, inheriting that article's outlet and tier. An embed on an
  off-allowlist page is skipped - it is trusted exactly as far as its host page.
- **Dedup on revision, not URL.** `raw_state.processed_embeds` is keyed
  `slug@updatedAt`. Articles are immutable once published; an Infogram map is
  not (the KY graphic's counts changed between July 22 and July 24), so a
  URL-only key would freeze county data on first sight.
- **State gate.** The WLKY article carrying the KY map carries an Indiana map
  too, and KY/IN share ~40 county names (Jefferson, Clark, Washington, Henry,
  ...), so name resolution alone cannot tell them apart. A graphic is accepted
  only if >= `INFOGRAM_MIN_MATCH_RATE` (0.95) of its county names resolve inside
  `STATE_ABBR`; the KY table scores 120/120 against KY, the IN table 40/92.
  Zeros are stored as `complete_list` only when the row count also equals the
  state's county count - otherwise the graphic is declared `partial_list` and
  its absences carry no meaning, per the usual zero-imputation rule.
- **State totals come from the captions, never from summing the map.** Handing
  `reconcile()` the graphic's own stated total ("TOTAL CONFIRMED CASES: 177") is
  what makes `county_state_residual()` a real check; a summed total would make it
  a tautology that always returns 0. On the July 24 KY graphic the two agree
  exactly (177), so the residual is `balanced` - the Indiana graphic, by
  contrast, states 710 against a county sum of 711.
- **Fails loudly.** `window.infographicData` is an undocumented internal shape.
  Every accessor warns and returns NULL rather than an empty table, so a silent
  "0 counties today" can never be mistaken for "no cases today". If Infogram
  changes the payload, runs start warning and stop ingesting; they do not
  quietly zero out the state.

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
- **Known-bad legacy prose rows.** The state-level `reported` series in
  `raw/ky_cyclo_news_history.csv.gz` contains implausible LLM extractions from
  the prose path - `7000` at 2026-05-01, `1600` at 2026-07-20, `4700` dated
  2019-12-31, and rows with a null `as_of_date`. These are why the July 22 embed
  snapshot (`reported = 468`, a figure stated verbatim on the graphic) lands a
  `cumulative_drop` in the review queue: `check_monotonic()` compares it against
  a `prev_max` of 7000. The flag is a true positive pointing at the old rows,
  not at the map. Retiring them is a review-queue decision, so it is not
  automated here.
- **`ky_cyclo_news_cases` vs `..._cases_new` can disagree in a week where the
  prose path reported twice.** `to_standard()` keeps the *first* figure when one
  extraction has two for the same (geography, measure, week);
  `compute_cases_new()` differences the *latest*. For week-ending 2026-07-18 the
  state `cases` column therefore shows 55 (from 2026-07-14) while the delta into
  2026-07-25 is computed off 108 (from 2026-07-17), so `177 - 55 = 122` does not
  equal the stored `cases_new` of 69. Making these agree means changing
  `to_standard()`'s `distinct()` in `../../scripts/reconcile.R` to keep the
  latest `as_of_date` within a week; left alone deliberately, since that file is
  shared. The embed path cannot cause this - one graphic carries one as-of date.
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
