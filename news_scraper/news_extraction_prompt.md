# News-extraction prompt spec

Turns one cleaned news article into structured case-count facts validated against
`news_extraction.schema.json`. Lower-tier ("news") source for PopHIVE/cyclo-resources.

## Model & call

A scoped extraction task — a small fast model is sufficient. Suggested: `claude-haiku-4-5`
via the `ellmer` R package's structured-output mode (or a plain `httr` POST to the
Messages API with `response_format` pinned to the schema). Set `temperature = 0`.

Pass, per call:
- `article_text` — main text only, after trafilatura/readability. Strip nav, donation
  boilerplate, "Related", newsletter blocks. The raw HTML is ~90% chrome.
- `metadata` — `url`, `outlet`, `published_time`, `timezone`, `state_context` (the
  harvester already has these from the feed + the page's `article:*` meta tags).

`outlet_tier` is set by the harvester from the domain allowlist, NOT by the model.

## System prompt

> You extract public-health case-count facts from a single news article that relays
> figures from a health department. You output ONLY JSON conforming to the provided
> schema — no prose, no markdown, no code fences.
>
> Rules:
> 1. Extract EVERY case figure the article states: state totals and each named county.
> 2. Never invent a geography that is not explicitly named. If the article names only
>    some counties, set `coverage = "partial_list"`; if it prints a full roster, use
>    `"complete_list"`; a lone figure is `"single"`. Downstream will NOT fill zeros for
>    unnamed counties, so do not pad.
> 3. Classify `count_type`: `confirmed`, `probable`, `hospitalized`, or `reported`
>    (use `reported` when the article gives a single larger "reported" figure that
>    combines confirmed+probable).
> 4. Resolve every date to an absolute `as_of_date` (YYYY-MM-DD) using the article's
>    `published_time` and `timezone`. "as of Wednesday evening" in a Friday article →
>    the Wednesday of that same week. Keep the original wording in `as_of_date_verbatim`.
>    Use `null` only if genuinely unresolvable.
> 5. Attribute origin: put the health department in `origin_agency` (e.g. "KDPH"). The
>    outlet is the relay, not the source.
> 6. Flag hedged numbers ("more than 100", "nearly 200", "fewer than five") with
>    `count_is_approximate = true` and record the stated integer.
> 7. Give `source_char_span` = [start, end) offsets into the article text for each
>    figure, and a calibrated `confidence` in [0,1].

## User message template

```
<metadata>
url: {url}
outlet: {outlet}
published_time: {published_time}
timezone: {timezone}
state_context: {state_context}
</metadata>

<article_text>
{article_text}
</article_text>

Return one JSON object valid against news_extraction.schema.json.
```

## Tested fixture — Kentucky (WEKU / LPM, 2026-07-17)

This is the regression fixture: the extractor should reproduce the output below (dates,
county roster, count_type split) from the article at
`https://www.lpm.org/news/2026-07-17/where-have-cases-of-cyclosporiasis-been-detected-in-ky-what-health-officials-have-confirmed`.

Key behaviors it exercises: relative-date resolution ("Wednesday evening" in a Fri
2026-07-17 article → 2026-07-15), the confirmed/reported/hospitalized split at state
level, and a `complete_list` 35-county roster. The county roster sums to 104 while the
state confirmed total is 108 — the reconciler must surface that residual of 4, not force
a match. (County figures are facts and are stored as data; the article's prose is not.)

Expected output (abbreviated county rows shown in full for the fixture):

```json
{
  "article": {
    "url": "https://www.lpm.org/news/2026-07-17/where-have-cases-of-cyclosporiasis-been-detected-in-ky-what-health-officials-have-confirmed",
    "outlet": "WEKU / Louisville Public Media",
    "outlet_tier": "A",
    "published_time": "2026-07-17T11:45:21-04:00",
    "timezone": "America/Kentucky/Louisville",
    "state_context": "KY"
  },
  "figures": [
    { "geography_name": "Kentucky", "geography_level": "state", "count": 108, "count_type": "confirmed",    "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of July 15", "origin_agency": "KDPH", "coverage": "single", "confidence": 0.98 },
    { "geography_name": "Kentucky", "geography_level": "state", "count": 192, "count_type": "reported",     "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of July 15", "origin_agency": "KDPH", "coverage": "single", "confidence": 0.98 },
    { "geography_name": "Kentucky", "geography_level": "state", "count": 7,   "count_type": "hospitalized", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of July 15", "origin_agency": "KDPH", "coverage": "single", "confidence": 0.97 },

    { "geography_name": "Adair",      "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Bourbon",    "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Boyle",      "geography_level": "county", "count": 2,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Bullitt",    "geography_level": "county", "count": 2,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Caldwell",   "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Daviess",    "geography_level": "county", "count": 5,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Fayette",    "geography_level": "county", "count": 9,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Fleming",    "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Green",      "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Hancock",    "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Hardin",     "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Henry",      "geography_level": "county", "count": 3,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Hopkins",    "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Jackson",    "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Jefferson",  "geography_level": "county", "count": 30, "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday evening", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.97 },
    { "geography_name": "Jessamine",  "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Kenton",     "geography_level": "county", "count": 2,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Knox",       "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Laurel",     "geography_level": "county", "count": 3,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Letcher",    "geography_level": "county", "count": 4,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Lewis",      "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Lincoln",    "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Madison",    "geography_level": "county", "count": 10, "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday evening", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.97 },
    { "geography_name": "Mason",      "geography_level": "county", "count": 2,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "McCracken",  "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "McLean",     "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Mercer",     "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Montgomery", "geography_level": "county", "count": 2,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Morgan",     "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Nelson",     "geography_level": "county", "count": 3,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Oldham",     "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Pulaski",    "geography_level": "county", "count": 2,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Rockcastle", "geography_level": "county", "count": 1,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Scott",      "geography_level": "county", "count": 4,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 },
    { "geography_name": "Shelby",     "geography_level": "county", "count": 2,  "count_type": "confirmed", "as_of_date": "2026-07-15", "as_of_date_verbatim": "as of Wednesday", "origin_agency": "KDPH", "coverage": "complete_list", "confidence": 0.95 }
  ]
}
```

### Assertions for the regression test
- Exactly 35 county figures, all `count_type = "confirmed"`, all `coverage = "complete_list"`.
- 3 state figures: confirmed 108, reported 192, hospitalized 7.
- Every `as_of_date == "2026-07-15"` (relative-date resolution succeeded).
- `sum(county confirmed) == 104`; reconciler residual vs state (108) `== 4`, flag `unassigned_residual`.
- `origin_agency == "KDPH"` on all rows (outlet is only the relay).
