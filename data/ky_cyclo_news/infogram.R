# =============================================================================
# Infogram structured-embed harvest (helper for ky_cyclo_news/ingest.R)
#
# Some allowlisted KY outlets publish their cyclosporiasis county map as an
# Infogram embed rather than (or alongside) prose. Infogram ships each
# infographic's *underlying spreadsheet* into the embed page as a single-line
#   <script>window.infographicData={...};</script>
# assignment, so the county -> count table is available as data instead of as a
# paragraph an LLM has to read numbers out of. That makes an embed-derived
# snapshot strictly better than the prose path for the same article:
#
#   - complete_list coverage: every county in the state is a row, so a county
#     with no cases is an explicit 0 rather than an absence (see the
#     coverage/zero-imputation rules in ../../news_scraper/README.md);
#   - exact counts: no hedged "more than 100" phrasing to interpret, so
#     count_is_approximate is always FALSE;
#   - a machine-readable as-of date and a graphic-level updatedAt.
#
# It is still a NEWS-tier source - the outlet built the graphic from KDPH
# figures, KDPH does not publish it - so it lives in this folder, behind the
# same KY_ALLOWLIST outlet gate, and lands in the same ky_cyclo_news_* columns
# through the same reconcile() call as the prose path. Nothing here bypasses
# the residual / monotonicity / review machinery.
#
# `window.infographicData` is an undocumented internal shape that Infogram can
# change without notice. Every accessor below therefore fails LOUDLY - warning
# plus NULL, so ingest.R skips the embed - rather than returning an empty
# table. A silent "0 counties today" must never be mistakable for "no cases".
# =============================================================================

# ---- Discovery -------------------------------------------------------------

# Infogram publish slugs end in a long lowercase alphanumeric id beginning with
# a digit (e.g. "cyclospora-in-kentucky-1hnp27ejvprdy4g"). Requiring that tail
# keeps asset paths such as cdn.jifo.co/js/... and infogram.com/js/dist/... out
# of the queue, which a bare [A-Za-z0-9-]+ match would otherwise pick up.
INFOGRAM_SLUG_TAIL <- "-[0-9][a-z0-9]{14,}$"

#' Find Infogram embed slugs in an article's raw HTML.
#' Returns a character vector of slugs (possibly empty), never NULL.
discover_infogram_embeds <- function(html) {
  if (is.null(html) || !nzchar(html)) return(character())
  hits <- regmatches(html, gregexpr("infogram\\.com/[A-Za-z0-9-]{10,}", html))[[1]]
  slugs <- unique(sub("^infogram\\.com/", "", hits))
  slugs[grepl(INFOGRAM_SLUG_TAIL, slugs)]
}

# ---- Fetch + JSON extraction ------------------------------------------------

#' GET an Infogram embed page and return its parsed `window.infographicData`.
#' NULL (with a warning) on any HTTP, extraction, or JSON-parse failure.
fetch_infogram_data <- function(slug) {
  url <- paste0("https://infogram.com/", slug)
  resp <- tryCatch(
    httr::RETRY("GET", url, httr::add_headers(
      `User-Agent` = paste(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
      )
    ), times = 3, pause_min = 5),
    error = function(e) NULL
  )
  if (is.null(resp) || httr::status_code(resp) != 200) {
    warning("infogram: fetch failed for ", slug, ": HTTP ",
            if (is.null(resp)) "error" else httr::status_code(resp))
    return(NULL)
  }
  html <- httr::content(resp, as = "text", encoding = "UTF-8")

  # The assignment sits alone on one physical line and is terminated by
  # `;</script>`; the JSON itself contains no newlines. Slicing on those two
  # anchors is enough, and a bad slice cannot pass silently because the result
  # is immediately handed to fromJSON() below.
  line <- grep("window\\.infographicData\\s*=", strsplit(html, "\n", fixed = TRUE)[[1]],
               value = TRUE)
  if (length(line) == 0) {
    warning("infogram: no window.infographicData in ", slug,
            " - the embed page shape may have changed.")
    return(NULL)
  }
  json <- sub("^.*?window\\.infographicData\\s*=\\s*", "", line[1])
  json <- sub(";\\s*</script>.*$", "", json)

  parsed <- tryCatch(jsonlite::fromJSON(json, simplifyVector = FALSE),
                     error = function(e) NULL)
  if (is.null(parsed)) {
    warning("infogram: could not parse infographicData JSON for ", slug)
    return(NULL)
  }
  parsed$.slug <- slug
  parsed$.url  <- url
  parsed
}

# ---- Walking the parsed shape ----------------------------------------------

infogram_entities <- function(d) {
  ents <- d$elements$content$content$entities
  if (is.null(ents) || length(ents) == 0) return(list())
  ents
}

#' All caption / heading strings on the graphic, in document order.
#' These carry the as-of date, the stated state total, and the attribution.
infogram_texts <- function(d) {
  out <- character()
  for (ent in infogram_entities(d)) {
    blocks <- ent$props$content$blocks
    if (is.null(blocks)) next
    for (b in blocks) {
      if (!is.null(b$text) && nzchar(trimws(b$text))) out <- c(out, trimws(b$text))
    }
  }
  out
}

#' Pull the first (name, count) table out of the graphic.
#'
#' chartData$data is a list of sheets; each sheet is a list of rows; each row is
#' a list of cells that are either NULL or list(value = "..."). For a map the
#' columns are (county, count, <unused>, "lat lon", label). Rows whose count
#' cell is not an integer are dropped, which is what discards a header row such
#' as ("County", "Cases") without needing to know whether one is present.
infogram_count_table <- function(d) {
  for (ent in infogram_entities(d)) {
    cd <- ent$props$chartData
    if (is.null(cd) || is.null(cd$data) || length(cd$data) == 0) next
    rows <- cd$data[[1]]
    if (!is.list(rows) || length(rows) == 0) next

    cell <- function(row, i) {
      if (length(row) < i) return(NA_character_)
      v <- row[[i]]
      if (is.null(v) || is.null(v$value)) return(NA_character_)
      as.character(v$value)
    }
    tbl <- tibble(
      geography_name = trimws(vapply(rows, cell, character(1), 1L)),
      count_raw      = trimws(vapply(rows, cell, character(1), 2L))
    ) %>%
      mutate(count = suppressWarnings(as.integer(gsub(",", "", count_raw)))) %>%
      filter(!is.na(geography_name), nzchar(geography_name), !is.na(count))

    if (nrow(tbl) > 0) return(tbl)
  }
  NULL
}

# ---- Caption parsing --------------------------------------------------------

# strptime's %B is locale-dependent and its case-handling varies by platform, so
# month names are mapped explicitly rather than parsed. Captions are upper-case
# on the graphic ("AS OF JULY 22") but this tolerates any casing.
INFOGRAM_MONTHS <- c(
  january = 1L, february = 2L, march = 3L, april = 4L, may = 5L, june = 6L,
  july = 7L, august = 8L, september = 9L, october = 10L, november = 11L,
  december = 12L
)

#' Resolve a year-less "<Month> <day>" caption fragment to an absolute Date,
#' using the graphic's own updatedAt as the reference year.
infogram_month_day <- function(blob, pattern, ref_date) {
  m <- regmatches(blob, regexec(pattern, blob, ignore.case = TRUE))[[1]]
  if (length(m) < 2) return(as.Date(NA))
  parts <- strsplit(trimws(m[2]), "\\s+")[[1]]
  if (length(parts) < 2) return(as.Date(NA))
  mon <- INFOGRAM_MONTHS[tolower(parts[1])]
  day <- suppressWarnings(as.integer(parts[2]))
  if (is.na(mon) || is.na(day)) return(as.Date(NA))

  yr <- as.integer(format(ref_date, "%Y"))
  d  <- as.Date(sprintf("%04d-%02d-%02d", yr, mon, day))
  # A "DECEMBER 28" caption on a graphic updated in early January belongs to the
  # previous year. Any naive parse landing after updatedAt rolls back one year.
  if (!is.na(d) && d > ref_date + 1) {
    d <- as.Date(sprintf("%04d-%02d-%02d", yr - 1L, mon, day))
  }
  d
}

INFOGRAM_AGENCIES <- c(
  "kentucky department for public health" = "KDPH",
  "kentucky department of public health"  = "KDPH"
)

#' Extract the as-of date, stated state totals, and origin agency from captions.
parse_infogram_captions <- function(texts, updated_at) {
  blob <- paste(texts, collapse = " | ")
  ref  <- suppressWarnings(as.Date(substr(updated_at %||% "", 1, 10)))
  if (is.na(ref)) ref <- Sys.Date()

  num <- function(pattern) {
    m <- regmatches(blob, regexec(pattern, blob, ignore.case = TRUE))[[1]]
    if (length(m) < 2) return(NA_integer_)
    suppressWarnings(as.integer(gsub(",", "", m[2])))
  }

  agency <- NA_character_
  for (nm in names(INFOGRAM_AGENCIES)) {
    if (grepl(nm, blob, ignore.case = TRUE)) { agency <- INFOGRAM_AGENCIES[[nm]]; break }
  }

  list(
    # "TOTAL CONFIRMED CASES: 177" - the graphic's own state total. Kept
    # separate from sum(counties) on purpose: handing reconcile() the STATED
    # total is what makes county_state_residual() a real check rather than a
    # tautology that always returns 0.
    total_confirmed = num("TOTAL\\s+CONFIRMED\\s+CASES\\s*:?\\s*([0-9,]+)"),
    # "TOTAL CASES: 710" on graphics that don't split confirmed out.
    total_cases     = num("TOTAL\\s+CASES\\s*:?\\s*([0-9,]+)"),
    # "KENTUCKY HAS RECIEVED 468 REPORTS OF CASES" - note the typo on the live
    # graphic; matching REC[EI]{2}VED covers both spellings.
    total_reported  = num("REC[EI]{2}VED\\s+([0-9,]+)\\s+REPORTS"),
    as_of           = infogram_month_day(blob, "AS\\s+OF\\s+([A-Za-z]+\\s+[0-9]{1,2})", ref),
    last_updated    = infogram_month_day(blob, "LAST\\s+UPDATED\\s*:?\\s*([A-Za-z]+\\s+[0-9]{1,2})", ref),
    agency          = agency,
    updated_at      = updated_at
  )
}

# ---- State gate -------------------------------------------------------------

#' How well does a county-name column fit ONE state's county roster?
#'
#' This is the gate that keeps a same-page out-of-state graphic out of this
#' source: the WLKY article that carries the KY map carries an Indiana map too,
#' and KY/IN share ~40 county names (Jefferson, Clark, Washington, Henry, ...),
#' so name resolution alone cannot tell them apart. Fit does: the KY table
#' resolves 120/120 against KY and only 40/92 for the IN table, and each table's
#' row count equals its own state's county count.
infogram_state_fit <- function(county_names, state_fips, all_fips) {
  state_fips <- formatC(as.integer(state_fips), width = 2, flag = "0")
  resolved <- resolve_county_fips(county_names, state_fips, all_fips)
  n_counties <- sum(nchar(all_fips$geography) == 5 &
                    substr(all_fips$geography, 1, 2) == state_fips)
  list(
    match_rate       = if (length(resolved) == 0) 0 else mean(!is.na(resolved)),
    n_rows           = length(county_names),
    n_state_counties = n_counties,
    unmatched        = county_names[is.na(resolved)]
  )
}

# ---- Extraction assembly ----------------------------------------------------

# Confidence for embed-derived figures. Well above validate_figures()' 0.6
# review threshold because these are read out of the graphic's own spreadsheet,
# not inferred from prose - there is no extraction ambiguity to discount for.
INFOGRAM_CONFIDENCE <- 0.95

#' Build a news_extraction.schema.json-shaped object from an Infogram embed, so
#' it can go through the same reconcile() call as an LLM-extracted article.
#'
#' Returns NULL (with an explanatory cat/warning) if the embed fails the state
#' fit gate, has no usable as-of date, or yields no county rows.
#'
#' @param d          parsed output of fetch_infogram_data()
#' @param state_abbr USPS abbreviation this source covers, e.g. "KY"
#' @param outlet,outlet_tier,article_url provenance of the page hosting the embed
#' @param emit_zeros TRUE -> keep 0-case counties as explicit zeros and declare
#'   coverage = "complete_list". FALSE -> drop them and declare "partial_list".
#' @param min_match_rate  minimum share of county names that must resolve
#'   within `state_abbr` for the embed to be accepted.
infogram_to_extraction <- function(d, state_abbr, all_fips,
                                   outlet, outlet_tier, article_url,
                                   emit_zeros = TRUE, min_match_rate = 0.95,
                                   timezone = "America/Kentucky/Louisville") {
  slug <- d$.slug %||% "<unknown>"
  tbl  <- infogram_count_table(d)
  if (is.null(tbl)) {
    warning("infogram: no (name, count) table found in ", slug)
    return(NULL)
  }

  state_fips <- state_abbr_to_fips(state_abbr, all_fips)
  fit <- infogram_state_fit(tbl$geography_name, state_fips, all_fips)
  if (fit$match_rate < min_match_rate) {
    cat(sprintf(paste0("ky_cyclo_news: infogram %s skipped - only %.0f%% of %d ",
                       "county names resolve in %s (not a %s graphic).\n"),
                slug, 100 * fit$match_rate, fit$n_rows, state_abbr, state_abbr))
    return(NULL)
  }

  caps <- parse_infogram_captions(infogram_texts(d), d$updatedAt)
  as_of <- caps$as_of %||% as.Date(NA)
  if (is.na(as_of)) as_of <- caps$last_updated
  if (is.na(as_of)) as_of <- suppressWarnings(as.Date(substr(d$updatedAt %||% "", 1, 10)))
  if (is.na(as_of)) {
    warning("infogram: no resolvable as-of date for ", slug, " - skipping.")
    return(NULL)
  }

  # A graphic that lists every county in the state is a complete_list and its
  # zeros are real information; one we've filtered is not. Declare whichever we
  # actually emit so downstream zero-imputation rules stay honest.
  complete <- emit_zeros && fit$n_rows == fit$n_state_counties
  county_tbl <- if (emit_zeros) tbl else filter(tbl, count > 0)
  if (nrow(county_tbl) == 0) {
    warning("infogram: ", slug, " yielded no county rows - skipping.")
    return(NULL)
  }
  coverage <- if (complete) "complete_list" else "partial_list"

  figure <- function(name, level, count, count_type) {
    list(
      geography_name       = name,
      geography_level      = level,
      count                = as.integer(count),
      count_is_approximate = FALSE,
      count_type           = count_type,
      as_of_date           = format(as_of, "%Y-%m-%d"),
      as_of_date_verbatim  = sprintf("Infogram embed %s (as of %s, updated %s)",
                                     slug, format(as_of, "%B %d"),
                                     caps$updated_at %||% "unknown"),
      origin_agency        = caps$agency,
      coverage             = coverage,
      confidence           = INFOGRAM_CONFIDENCE
    )
  }

  figures <- Map(function(nm, ct) figure(nm, "county", ct, "confirmed"),
                 county_tbl$geography_name, county_tbl$count)
  figures <- unname(figures)

  # State-level rows come from the captions, never from summing the map.
  state_confirmed <- caps$total_confirmed %||% caps$total_cases
  if (!is.na(state_confirmed)) {
    figures <- c(figures, list(figure(state_abbr, "state", state_confirmed, "confirmed")))
  }
  if (!is.na(caps$total_reported)) {
    figures <- c(figures, list(figure(state_abbr, "state", caps$total_reported, "reported")))
  }

  list(
    article = list(
      url            = article_url %||% d$.url,
      outlet         = outlet,
      outlet_tier    = outlet_tier,
      # The graphic's own updatedAt is a far better freshness stamp than the
      # hosting article's publish time - the map is revised in place.
      published_time = d$updatedAt %||% format(as_of, "%Y-%m-%dT00:00:00Z"),
      timezone       = timezone,
      state_context  = state_abbr
    ),
    figures = figures,
    # Not part of the schema; carried for ingest.R's dedup key and logging.
    .meta = list(slug = slug, embed_url = d$.url, updated_at = d$updatedAt,
                 as_of = as_of, n_counties = nrow(county_tbl),
                 n_nonzero = sum(county_tbl$count > 0), coverage = coverage,
                 county_sum = sum(county_tbl$count),
                 state_confirmed = state_confirmed)
  )
}
