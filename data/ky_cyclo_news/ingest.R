# =============================================================================
# Kentucky Cyclosporiasis - lower-tier "news" source
#
# Source: trusted Kentucky news outlets relaying KDPH (Kentucky Dept for Public
# Health) case counts, NOT a KDPH dashboard/API. See ../../news_scraper/README.md
# for the pipeline this implements (discovery -> gate -> fetch -> LLM extract ->
# reconcile -> store) and news_scraper/news_extraction_prompt.md for the
# extraction contract.
#
# This source is explicitly lower-trust than the dashboard scrapers
# (fl_/in_/mi_/oh_/wv_/ca_/or_cyclo) and must never be blended with them
# unlabeled - hence the "_news" suffix on every value column.
#
# Requires:
#   - ANTHROPIC_API_KEY (env var) for the LLM extraction step
#   - Network access to Google News RSS + the outlet pages themselves
#
# Notes for a future maintainer:
#   - Google News RSS <link> values are redirect URLs (news.google.com/rss/
#     articles/...), not the outlet's real URL. This script resolves each one
#     with a plain GET and uses the final response URL (after redirects) as
#     the canonical article URL for both the allowlist gate and provenance.
#   - The outlet allowlist below is a starting point (KY public media + major
#     dailies/network affiliates). Extend KY_ALLOWLIST as new relays are
#     confirmed reliable; anything not listed is tagged "quarantine" and is
#     fetched/logged but never sent to the LLM or reconciled into standard/.
#   - De-duplication happens at two levels: (1) per-URL, via process.json's
#     raw_state (an article is never re-fetched/re-extracted once processed),
#     and (2) per (geography, count_type, as_of_date) in the long history, so
#     a later article that revises an earlier snapshot overwrites it there
#     rather than duplicating it.
# =============================================================================

library(dplyr)
library(tidyr)
library(httr)
library(xml2)
library(rvest)
library(vroom)
library(jsonlite)

source("../../scripts/reconcile.R")
source("infogram.R")

if (!dir.exists("raw")) dir.create("raw")
if (!dir.exists("standard")) dir.create("standard")

if (!file.exists("process.json")) {
  process <- list(raw_state = list(processed_urls = character(),
                                   processed_embeds = character()))
} else {
  process <- dcf::dcf_process_record()
}
processed_urls <- process$raw_state$processed_urls %||% character()
# Embeds are keyed slug@updatedAt, NOT by URL like articles: an article is
# immutable once published, but an Infogram map is revised IN PLACE at the same
# URL (the KY graphic's counts changed between July 22 and July 24). Keying on
# the graphic's own updatedAt re-ingests a refreshed map while still never
# re-processing an unchanged one.
processed_embeds <- process$raw_state$processed_embeds %||% character()

# ---- Config -------------------------------------------------------------

STATE_ABBR <- "KY"
PREFIX     <- "ky_cyclo_news"

# Tier A = KY public media / established statewide daily. Tier B = local TV /
# regional outlet that reliably relays KDPH figures. Anything else -> quarantine.
KY_ALLOWLIST <- list(
  A = c("lpm.org", "weku.org", "wfpl.org", "wuky.org", "kentucky.com",
        "courier-journal.com", "kentuckytoday.com"),
  B = c("wkyt.com", "wave3.com", "whas11.com", "wlky.com", "lex18.com",
        "wdrb.com", "wchstv.com", "wymt.com")
)

classify_outlet_tier <- function(url, allowlist = KY_ALLOWLIST) {
  host <- tolower(sub("^(?:https?://)?(?:www\\.)?([^/]+).*$", "\\1", url))
  if (any(endsWith(host, allowlist$A))) return("A")
  if (any(endsWith(host, allowlist$B))) return("B")
  "quarantine"
}

# ---- Infogram embed config (see infogram.R) --------------------------------

# Known KY county-map embeds, checked EVERY run regardless of what Google News
# RSS surfaces. Seeding matters because RSS is a rolling window: the article
# ages out within days, but the map it hosts keeps being revised in place and is
# the best county-level data this source has. Embeds found on freshly fetched
# allowlisted articles are appended to this queue automatically, inheriting that
# article's outlet and tier.
#
# Each row must name an outlet on KY_ALLOWLIST - an embed is trusted exactly as
# far as the page carrying it, and is tier-gated identically to prose.
KY_INFOGRAM_SEEDS <- tibble::tribble(
  ~slug,                                    ~outlet, ~article_url,
  "cyclospora-in-kentucky-1hnp27ejvprdy4g", "WLKY",
    "https://www.wlky.com/article/cyclospora-cases-indiana-map-data/72794202"
)

# Share of a graphic's county names that must resolve within STATE_ABBR before
# it is accepted. The article carrying the KY map carries an Indiana map too, and
# the two states share ~40 county names, so this (plus row count == the state's
# county count) is what separates them: KY table 120/120 vs KY, IN table 40/92.
INFOGRAM_MIN_MATCH_RATE <- 0.95

# TRUE: a graphic listing all 120 KY counties is a complete_list, so its 0-case
# counties are stored as real zeros - the main advantage over the prose path,
# which can only ever report the counties an article happens to name. Flip to
# FALSE to store only counties with >=1 case (declared partial_list instead).
INFOGRAM_EMIT_ZEROS <- TRUE

# ---- 1. Discovery: Google News RSS ---------------------------------------

discover_articles <- function(query = "cyclosporiasis Kentucky", n_max = 25) {
  feed_url <- httr::modify_url(
    "https://news.google.com/rss/search",
    query = list(q = query, hl = "en-US", gl = "US", ceid = "US:en")
  )
  resp <- httr::RETRY("GET", feed_url, times = 3, pause_min = 5)
  if (httr::status_code(resp) != 200) {
    warning("ky_cyclo_news: Google News RSS fetch failed: HTTP ", httr::status_code(resp))
    return(tibble(title = character(), link = character(), pub_date = character()))
  }
  feed <- xml2::read_xml(httr::content(resp, as = "text", encoding = "UTF-8"))
  items <- xml2::xml_find_all(feed, "//item")
  tibble(
    title      = xml2::xml_text(xml2::xml_find_first(items, "title")),
    link       = xml2::xml_text(xml2::xml_find_first(items, "link")),
    pub_date   = xml2::xml_text(xml2::xml_find_first(items, "pubDate")),
    # Each <item> carries its outlet's real homepage in <source url="...">.
    # This is available with no redirect resolution and is what tier
    # classification should run against - see decode_google_news_url() for
    # why the <link> itself is useless for this.
    source_url = xml2::xml_attr(xml2::xml_find_first(items, "source"), "url")
  ) %>%
    slice_head(n = n_max)
}

# Google News RSS <link> values (news.google.com/rss/articles/...) do NOT
# HTTP-redirect to the outlet - they 302 to another news.google.com splash
# page that resolves the real article client-side via JS. httr following
# redirects therefore always lands back on news.google.com, which silently
# quarantined every article regardless of source until this was fixed.
#
# The splash page embeds a signed token (data-n-a-sg / data-n-a-ts) that can
# be exchanged for the real URL via Google's internal batchexecute RPC; this
# is the same reverse-engineered protocol used by e.g.
# github.com/SSujitX/google-news-url-decoder. Verified working manually
# against a live KY article link before wiring in below.
decode_google_news_url <- function(google_link) {
  resp <- tryCatch(
    httr::RETRY("GET", google_link, httr::add_headers(`User-Agent` = "Mozilla/5.0"),
                times = 2, pause_min = 3),
    error = function(e) NULL
  )
  if (is.null(resp) || httr::status_code(resp) != 200) return(NA_character_)
  html_txt <- httr::content(resp, as = "text", encoding = "UTF-8")

  article_id <- sub(".*/articles/([^?]+).*", "\\1", google_link)
  sig <- sub('.*data-n-a-sg="([^"]*)".*', "\\1", html_txt)
  ts  <- sub('.*data-n-a-ts="([^"]*)".*', "\\1", html_txt)
  if (identical(sig, html_txt) || identical(ts, html_txt)) return(NA_character_)

  inner_req <- sprintf(
    paste0('["garturlreq",[["X","X",["X","X"],null,null,1,1,"US:en",null,1,',
           'null,null,null,null,null,0,1],"X","X",1,[1,1,1],1,1,null,0,0,null,0],',
           '"%s",%s,"%s"]'),
    article_id, ts, sig
  )
  f_req <- paste0('[[["Fbv4je",', jsonlite::toJSON(inner_req, auto_unbox = TRUE), ']]]')

  decode_resp <- tryCatch(
    httr::POST(
      "https://news.google.com/_/DotsSplashUi/data/batchexecute",
      httr::add_headers(
        `User-Agent`   = "Mozilla/5.0",
        `Content-Type` = "application/x-www-form-urlencoded;charset=UTF-8"
      ),
      body = list(`f.req` = f_req),
      encode = "form"
    ),
    error = function(e) NULL
  )
  if (is.null(decode_resp) || httr::status_code(decode_resp) != 200) return(NA_character_)

  body <- httr::content(decode_resp, as = "text", encoding = "UTF-8")
  parsed <- tryCatch({
    outer <- jsonlite::fromJSON(sub("^\\)\\]\\}'\\s*", "", body), simplifyVector = FALSE)
    inner <- jsonlite::fromJSON(outer[[1]][[3]], simplifyVector = FALSE)
    inner[[2]]
  }, error = function(e) NA_character_)
  parsed %||% NA_character_
}

# ---- 2/3. Fetch + main-text extraction -----------------------------------

# Lightweight boilerplate strip: drop script/style/nav/header/footer/aside,
# then take the <article> node if present, else the largest text-bearing <div>.
# This is a heuristic stand-in for trafilatura/readability (no mature R
# equivalent); false positives should route low-confidence extractions to
# review via the schema's `confidence` field rather than being trusted blindly.
fetch_main_text <- function(url) {
  resp <- tryCatch(
    httr::RETRY("GET", url, httr::add_headers(
      `User-Agent` = paste(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
      )
    ), times = 3, pause_min = 5),
    error = function(e) NULL
  )
  if (is.null(resp) || httr::status_code(resp) != 200) return(NULL)

  html_txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  page <- rvest::read_html(html_txt)
  rvest::html_elements(page, "script, style, nav, header, footer, aside, form") %>%
    xml2::xml_remove()

  article_node <- rvest::html_element(page, "article")
  if (is.na(article_node)) {
    candidates <- rvest::html_elements(page, "div, section")
    lens <- nchar(rvest::html_text2(candidates))
    if (length(lens) == 0 || max(lens) == 0) return(NULL)
    article_node <- candidates[[which.max(lens)]]
  }

  list(
    text            = rvest::html_text2(article_node),
    published_time  = rvest::html_attr(rvest::html_element(page, "meta[property='article:published_time']"), "content"),
    outlet          = rvest::html_attr(rvest::html_element(page, "meta[property='og:site_name']"), "content"),
    html_snapshot   = html_txt
  )
}

# ---- 4. LLM extraction ----------------------------------------------------

EXTRACTION_SCHEMA <- jsonlite::read_json("../../news_scraper/news_extraction.schema.json")

SYSTEM_PROMPT <- paste(
  "You extract public-health case-count facts from a single news article that",
  "relays figures from a health department. You output ONLY JSON conforming",
  "to the provided schema - no prose, no markdown, no code fences.",
  "",
  "Rules:",
  "1. Extract EVERY case figure the article states: state totals and each named county.",
  "2. Never invent a geography that is not explicitly named. Use coverage =",
  "   'partial_list' / 'complete_list' / 'single' as appropriate; never pad",
  "   unnamed counties with zeros.",
  "3. Classify count_type: confirmed, probable, hospitalized, or reported",
  "   (reported = a single combined confirmed+probable figure).",
  "4. Resolve every date to an absolute as_of_date (YYYY-MM-DD) using the",
  "   article's published_time and timezone. Keep the original wording in",
  "   as_of_date_verbatim. Use null only if genuinely unresolvable.",
  "5. Put the health department in origin_agency (e.g. 'KDPH'); the outlet is",
  "   the relay, not the source.",
  "6. Flag hedged numbers ('more than 100', 'nearly 200') with",
  "   count_is_approximate = true, recording the stated integer.",
  "7. Give source_char_span = [start, end) offsets into the article text for",
  "   each figure, and a calibrated confidence in [0,1].",
  sep = "\n"
)

user_message <- function(article_text, url, outlet, published_time, timezone, state_context) {
  paste0(
    "<metadata>\n",
    "url: ", url, "\n",
    "outlet: ", outlet, "\n",
    "published_time: ", published_time, "\n",
    "timezone: ", timezone, "\n",
    "state_context: ", state_context, "\n",
    "</metadata>\n\n",
    "<article_text>\n", article_text, "\n</article_text>\n\n",
    "Return one JSON object valid against news_extraction.schema.json."
  )
}

# Forces the schema via tool-use (the httr fallback the prompt spec calls out,
# since ellmer's structured-output types would need the schema hand-translated).
extract_via_llm <- function(article_text, url, outlet, published_time, timezone, state_context,
                             model = "claude-haiku-4-5") {
  api_key <- Sys.getenv("ANTHROPIC_API_KEY")
  if (!nzchar(api_key)) stop("ky_cyclo_news: ANTHROPIC_API_KEY is not set.")

  body <- list(
    model = model,
    max_tokens = 4096,
    temperature = 0,
    system = SYSTEM_PROMPT,
    tools = list(list(
      name = "emit_extraction",
      description = "Emit the structured news extraction.",
      input_schema = EXTRACTION_SCHEMA
    )),
    tool_choice = list(type = "tool", name = "emit_extraction"),
    messages = list(list(
      role = "user",
      content = user_message(article_text, url, outlet, published_time, timezone, state_context)
    ))
  )

  resp <- httr::POST(
    "https://api.anthropic.com/v1/messages",
    httr::add_headers(
      `x-api-key` = api_key,
      `anthropic-version` = "2023-06-01",
      `content-type` = "application/json"
    ),
    body = jsonlite::toJSON(body, auto_unbox = TRUE, null = "null"),
    encode = "raw"
  )
  if (httr::status_code(resp) != 200) {
    warning("ky_cyclo_news: LLM extraction failed for ", url, ": HTTP ", httr::status_code(resp))
    return(NULL)
  }
  parsed <- httr::content(resp, as = "parsed", simplifyVector = FALSE)
  tool_use <- Filter(function(b) identical(b$type, "tool_use"), parsed$content)
  if (length(tool_use) == 0) return(NULL)
  tool_use[[1]]$input
}

# ---- 5/6. Reconcile + store ------------------------------------------------

history_path    <- file.path("raw", paste0(PREFIX, "_history.csv.gz"))
provenance_path <- file.path("raw", paste0(PREFIX, "_provenance.csv.gz"))
review_path     <- file.path("raw", paste0(PREFIX, "_review.csv.gz"))
standard_path   <- file.path("standard", "data.csv.gz")

read_gz_if_exists <- function(path, col_types = NULL) {
  if (!file.exists(path)) return(NULL)
  vroom::vroom(path, show_col_types = FALSE, altrep = FALSE, col_types = col_types)
}

# published_time/run_ts are freeform text (e.g. "2026-07-20T17:08:00Z"), never
# parsed to Date/POSIXct in-memory - pin them to character on read so a
# re-read row can bind_rows() with a freshly built provenance/review tibble
# instead of vroom's column-type guesser promoting them to a datetime.
PROVENANCE_COL_TYPES <- vroom::cols(published_time = "c", run_ts = "c")

# geography_name is NA on every "reconciliation"/"monotonic" scoped row (see
# reconcile()'s review tibble). If a run's review.csv.gz so far holds only
# those rows, vroom's guesser sees an all-NA column and infers logical/double;
# the next run's "figure"-scoped rows put real county-name strings there,
# and bind_rows() then fails to combine <double> with <character>. Pin the
# type so the accumulated file always reads back the way it was written.
REVIEW_COL_TYPES <- vroom::cols(geography_name = "c", as_of_date = "D")

# `geography` is a FIPS code string ("21", "21001", ...) - every digit, so
# vroom's guesser reads it back as double once written unquoted to disk. The
# rest of the pipeline (figures$geography_fips, resolve_county_fips()) always
# treats it as character, so a re-read row fails to join/bind against a
# freshly built tibble (e.g. check_monotonic()'s inner_join) unless pinned.
HISTORY_COL_TYPES  <- vroom::cols(geography = "c", as_of_date = "D")
STANDARD_COL_TYPES <- vroom::cols(geography = "c", time = "c")

# Upsert new long rows into history on (geography, count_type, as_of_date):
# a later article revising the same snapshot replaces the prior news row,
# rather than duplicating it (see check_monotonic()'s use of this table).
upsert_long_history <- function(history, new_long) {
  if (is.null(history)) return(new_long)
  history <- history %>% mutate(as_of_date = as.Date(as_of_date))
  key_cols <- c("geography", "count_type", "as_of_date")
  history %>%
    anti_join(new_long, by = key_cols) %>%
    bind_rows(new_long) %>%
    arrange(geography, count_type, as_of_date)
}

# Merge new standard rows into the accumulated wide table: same (geography,
# time) row gets its columns updated by the new run (a revision), unrelated
# existing columns/rows are preserved.
upsert_standard <- function(existing, new_standard) {
  if (is.null(existing) || nrow(existing) == 0) return(new_standard)
  if (nrow(new_standard) == 0) return(existing)
  bind_rows(
    existing %>% anti_join(new_standard, by = c("geography", "time")),
    new_standard
  ) %>%
    arrange(geography, time)
}

# Snapshot-over-snapshot new-case count from the cumulative "confirmed" series
# in the long history (mirrors in_cyclo/mi_cyclo's differencing approach).
#
# The output is keyed on the week-ending Saturday, NOT the raw as_of_date. It
# has to be: to_standard() snaps as_of_date to that Saturday, so keying on the
# raw date meant this table never joined onto standard/ and every
# ky_cyclo_news_cases_new value came out NA regardless of the underlying series.
#
# Two snapshots can land in the same MMWR week (2026-07-15 and 2026-07-17 both
# end 2026-07-18). Collapsing to the latest as_of_date per (geography, week)
# before differencing keeps one row per (geography, time) - which is what
# standard/ is keyed on - and makes the difference a true week-over-week delta
# rather than an artifact of how many times an outlet happened to publish.
compute_cases_new <- function(history) {
  history %>%
    filter(count_type == "confirmed", !is.na(as_of_date)) %>%
    mutate(time = format(week_ending_saturday(as_of_date), "%Y-%m-%d")) %>%
    group_by(geography, time) %>%
    filter(as_of_date == max(as_of_date)) %>%
    slice_head(n = 1) %>%            # ties on as_of_date: one row per week
    ungroup() %>%
    arrange(geography, time) %>%
    group_by(geography) %>%
    mutate(cases_new = count - dplyr::lag(count)) %>%
    ungroup() %>%
    transmute(geography, time, !!paste0(PREFIX, "_cases_new") := cases_new)
}

all_fips <- load_fips()  # default path assumes cwd = data/ky_cyclo_news/

history_long      <- read_gz_if_exists(history_path, col_types = HISTORY_COL_TYPES)
standard_existing <- read_gz_if_exists(standard_path, col_types = STANDARD_COL_TYPES)

# Both harvest paths (prose and Infogram embed) produce the same
# news_extraction.schema.json shape, so they are collected into one queue and
# stored by one loop below - the reconcile/residual/monotonic/review machinery
# is identical for both and neither gets a private route into standard/.
extractions <- list()
embed_queue <- KY_INFOGRAM_SEEDS %>% mutate(tier = vapply(article_url, classify_outlet_tier, character(1)))

# ---- 7a. Prose path: allowlisted articles -> LLM extraction ----------------

articles     <- discover_articles()
new_articles <- articles %>% filter(!link %in% processed_urls)

if (nrow(new_articles) == 0) {
  cat("ky_cyclo_news: no new candidate articles since last run.\n")
}

for (i in seq_len(nrow(new_articles))) {
  link       <- new_articles$link[i]
  source_url <- new_articles$source_url[i]

  # Classify against the RSS feed's own <source url>, not the Google
  # redirect link - see decode_google_news_url() for why the link's host
  # is never usable for this. Quarantining here (before decoding) also
  # avoids spending a batchexecute round-trip on off-allowlist outlets.
  tier <- if (is.na(source_url)) "quarantine" else classify_outlet_tier(source_url)
  if (tier == "quarantine") {
    cat("ky_cyclo_news: quarantined (off-allowlist):", source_url %||% link, "\n")
    processed_urls <- c(processed_urls, link)
    next
  }

  real_url <- decode_google_news_url(link)
  if (is.na(real_url)) { processed_urls <- c(processed_urls, link); next }

  page <- fetch_main_text(real_url)
  if (is.null(page) || nchar(page$text) < 200) { processed_urls <- c(processed_urls, link); next }

  # Queue any Infogram map on this article for the structured path below. Done
  # before the LLM call so an article whose prose carries no figures at all
  # still contributes its map.
  found <- discover_infogram_embeds(page$html_snapshot)
  if (length(found) > 0) {
    cat("ky_cyclo_news: found", length(found), "infogram embed(s) on", real_url, "\n")
    embed_queue <- bind_rows(embed_queue, tibble(
      slug        = found,
      outlet      = page$outlet %||% real_url,
      article_url = real_url,
      tier        = tier
    ))
  }

  extraction <- tryCatch(
    extract_via_llm(
      article_text    = page$text,
      url             = real_url,
      outlet          = page$outlet %||% real_url,
      published_time  = page$published_time %||% as.character(Sys.time()),
      timezone        = "America/Kentucky/Louisville",
      state_context   = STATE_ABBR
    ),
    error = function(e) { warning("ky_cyclo_news: ", conditionMessage(e)); NULL }
  )
  processed_urls <- c(processed_urls, link)
  if (is.null(extraction) || length(extraction$figures) == 0) next

  extraction$article$outlet_tier <- tier  # set by harvester, not the model
  extractions <- c(extractions, list(list(label = real_url, extraction = extraction)))
}

# ---- 7b. Structured path: Infogram embeds -> extraction --------------------

# Runs unconditionally, NOT only when 7a found a new article: the map is revised
# in place on a cadence of its own, so gating embed harvest on RSS novelty would
# freeze county data on whatever day the article was first seen.
embed_queue <- embed_queue %>% distinct(slug, .keep_all = TRUE)

for (i in seq_len(nrow(embed_queue))) {
  slug <- embed_queue$slug[i]
  if (identical(embed_queue$tier[i], "quarantine")) {
    cat("ky_cyclo_news: infogram", slug, "skipped - host page off-allowlist.\n")
    next
  }

  d <- fetch_infogram_data(slug)
  if (is.null(d)) next

  # Dedup on the graphic's own revision stamp, not its URL - see processed_embeds.
  embed_key <- paste0(slug, "@", d$updatedAt %||% "unknown")
  if (embed_key %in% processed_embeds) {
    cat("ky_cyclo_news: infogram", slug, "unchanged since last run (", embed_key, ")\n")
    next
  }

  ex <- tryCatch(
    infogram_to_extraction(
      d, state_abbr = STATE_ABBR, all_fips = all_fips,
      outlet         = embed_queue$outlet[i],
      outlet_tier    = embed_queue$tier[i],
      article_url    = embed_queue$article_url[i],
      emit_zeros     = INFOGRAM_EMIT_ZEROS,
      min_match_rate = INFOGRAM_MIN_MATCH_RATE
    ),
    error = function(e) { warning("ky_cyclo_news: infogram ", slug, ": ", conditionMessage(e)); NULL }
  )
  # Only record the key once the embed has actually been turned into an
  # extraction. A fetch that parsed but was skipped for a transient reason must
  # stay eligible next run; a state-gate rejection re-logs harmlessly.
  if (is.null(ex)) next

  m <- ex$.meta
  cat(sprintf(paste0("ky_cyclo_news: infogram %s -> %d counties (%d with cases), ",
                     "%s, as of %s, state total %s, county sum %d\n"),
              slug, m$n_counties, m$n_nonzero, m$coverage, format(m$as_of),
              m$state_confirmed %||% "NA", m$county_sum))

  processed_embeds <- c(processed_embeds, embed_key)
  extractions <- c(extractions, list(list(label = paste0("infogram:", slug), extraction = ex)))
}

# ---- 7c. Reconcile + store ------------------------------------------------

n_ingested <- 0
for (item in extractions) {
  out <- reconcile(item$extraction, all_fips, prefix = PREFIX, history_long = history_long)

  history_long      <- upsert_long_history(history_long, out$long)
  standard_existing <- upsert_standard(standard_existing, out$standard)

  if (nrow(out$provenance) > 0) {
    prov <- if (file.exists(provenance_path)) bind_rows(read_gz_if_exists(provenance_path, col_types = PROVENANCE_COL_TYPES), out$provenance) else out$provenance
    vroom::vroom_write(prov, provenance_path, delim = ",")
  }
  if (nrow(out$review) > 0) {
    rev <- if (file.exists(review_path)) bind_rows(read_gz_if_exists(review_path, col_types = REVIEW_COL_TYPES), out$review) else out$review
    vroom::vroom_write(rev, review_path, delim = ",")
    cat("ky_cyclo_news:", nrow(out$review), "rows routed to review for", item$label, "\n")
  }

  n_ingested <- n_ingested + 1
}

if (n_ingested > 0) {
  vroom::vroom_write(history_long, history_path, delim = ",")

  # cases_new is fully derived from history_long, so the prior run's copy is
  # dropped and recomputed rather than joined alongside. Without the drop,
  # left_join() suffixes the collision every run and standard/ accumulates
  # ky_cyclo_news_cases_new.x, .y, .x.x, ... (which is where the .x/.y columns
  # already in this file - and dcf_check()'s missing_info warnings about them -
  # came from). The select() also cleans those up on the next run.
  cases_new <- compute_cases_new(history_long)
  standard_final <- standard_existing %>%
    select(-any_of(names(cases_new)[-(1:2)]),
           -matches(paste0("^", PREFIX, "_cases_new\\."))) %>%
    left_join(cases_new, by = c("geography", "time"))
  vroom::vroom_write(standard_final, standard_path, delim = ",")

  cat("ky_cyclo_news: ingested", n_ingested, "new snapshot(s);",
      nrow(standard_final), "rows in standard/data.csv.gz\n")
} else {
  cat("ky_cyclo_news: nothing new passed the allowlist/extraction gate this run.\n")
}

process$raw_state <- list(processed_urls = unique(processed_urls),
                          processed_embeds = unique(processed_embeds))
dcf::dcf_process_record(updated = process)
