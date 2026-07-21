# cyclo-news-starter

Starter kit for a **lower-tier "news" source** in `PopHIVE/cyclo-resources`, for
bucket-2 states where county counts appear only in trusted news that relays a health
department (e.g. Kentucky). It is explicitly tagged lower-trust than the dashboard
scrapers (`fl_/in_/mi_/oh_/wv_cyclo`) and must never be blended with them unlabeled.

## Files

| File | What it is |
|---|---|
| `news_extraction.schema.json` | JSON Schema (draft 2020-12) for the extractor's output. One instance = one article. |
| `news_extraction_prompt.md` | The LLM extraction prompt as a tested spec, incl. rules + the KY regression fixture and assertions. |
| `reconcile.R` | Validation + FIPS resolution (state-scoped) + Saturday-week snap + Σ(county)-vs-state residual + monotonicity + review queue. |
| `test_ky.json` | The KY fixture (WEKU/LPM, 2026-07-17), schema-valid. Drives the smoke test in `reconcile.R`. |

## Pipeline (build in this order)

1. **Discovery** — per-state Google News RSS / GDELT DOC 2.0, daily.
2. **Trusted-source gate** — domain allowlist → `outlet_tier`; off-list quarantined.
3. **Fetch + main-text extract** — trafilatura/readability (raw HTML is ~90% chrome).
4. **LLM extract** — `news_extraction_prompt.md` → JSON validated against the schema.
   Suggested `claude-haiku-4-5`, `temperature=0`, via `ellmer` structured output.
5. **Reconcile** — `reconcile.R::reconcile()`; anything in `$review` does NOT auto-land.
6. **Store** — `$standard` → `standard/data.csv.gz`; `$long` → `raw/*_history.csv.gz`
   (for `*_cases_new` differencing, as in `mi_/in_cyclo`); `$provenance` → `raw/*_provenance.csv.gz`.

## Verified behaviors (KY fixture)

- 35 county rows + 3 state rows (confirmed 108 / reported 192 / hospitalized 7).
- Relative date "Wednesday evening" in a Fri 2026-07-17 article → `2026-07-15`.
- Σ(county confirmed) = 104 vs state 108 → **residual 4, `unassigned_residual`** (kept, not forced).
- State-scoping resolves the Jefferson KY (21111) vs NY (36045) collision correctly.

## Wiring into the repo (do in the Claude Code session)

Use the **`ingest-source` skill** to scaffold, e.g. `ky_cyclo_news`:
- It creates `data/ky_cyclo_news/{ingest.R, measure_info.json, process.json, raw/, standard/}`.
- Fill `ingest.R` with steps 1–6, calling `source("../../scripts/reconcile.R")` (move
  `reconcile.R` there so states share it) and `dcf::dcf_process_record()` for change detection.
- `measure_info.json`: value columns `ky_cyclo_news_cases` (cumulative confirmed),
  `ky_cyclo_news_cases_new`, `ky_cyclo_news_reported`, `ky_cyclo_news_hospitalized`.
  Set `source_tier: "news"` and a `_sources` entry attributing KDPH as origin, outlet as relay.
- Adding TN/TX later = a new allowlist block + config row + `xx_cyclo_news` scaffold; the
  extractor and `reconcile.R` are reused unchanged.

## Cautions to encode
- `partial_list` articles: never impute zeros for unnamed counties.
- Approximate figures ("more than 100") carry `count_is_approximate`; they route to review.
- News cadence is event-driven, not scheduled; a stale snapshot is not a zero.
- Official-supersedes-news: when a `.gov` source later covers the same as-of date, retire the news row.
- Store facts (county→count) + URL + attribution; never reproduce article prose.
