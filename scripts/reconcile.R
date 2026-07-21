# =============================================================================
# Cyclosporiasis news-harvest reconciliation & validation
# Part of PopHIVE/cyclo-resources -- the lower-tier "news" source pipeline.
#
# Consumes one parsed extraction object (see news_extraction.schema.json),
# validates it, resolves county FIPS (STATE-SCOPED), snaps as_of_date to the
# Saturday week-ending convention, runs the sum(county) vs state-total residual
# check, checks cumulative monotonicity against prior snapshots, and returns:
#   $standard    rows ready for standard/data.csv.gz (wide, {prefix}_{measure})
#   $long        long rows to append to raw/*_history for differencing + monotonic checks
#   $residual    sum(county) vs state per (count_type, as_of_date)
#   $monotonic   any cumulative decreases vs history
#   $review      human-in-the-loop queue (nothing here enters standard/ silently)
#   $provenance  one row for raw/*_provenance.csv.gz
#
# Facts (county -> count) are stored as data; article prose is never reproduced.
# =============================================================================

library(dplyr)
library(tidyr)

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

# ---- FIPS -------------------------------------------------------------------

load_fips <- function(path = "../../resources/all_fips.csv.gz") {
  vroom::vroom(path, show_col_types = FALSE) %>%
    mutate(geography = as.character(geography))
}

#' USPS state abbreviation -> 2-digit state FIPS string.
state_abbr_to_fips <- function(abbr, all_fips) {
  states <- all_fips %>% filter(nchar(geography) == 2)
  states$geography[match(toupper(abbr), toupper(states$state))]
}

#' County names -> 5-digit FIPS, scoped to ONE state.
#' Matching is case-insensitive and strips the "County/Parish/Borough" suffix.
#' Unmatched names return NA and are routed to review -- never guessed.
#' State-scoping is essential: "Jefferson" exists in KY (21111), NY (36045),
#' and dozens of other states.
resolve_county_fips <- function(county_names, state_fips, all_fips) {
  state_fips <- formatC(as.integer(state_fips), width = 2, flag = "0")
  counties <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == state_fips) %>%
    mutate(key = tolower(trimws(gsub(
      "\\s+(county|parish|borough|census area|city and borough|municipality).*$",
      "", geography_name, ignore.case = TRUE))))
  key <- tolower(trimws(county_names))
  counties$geography[match(key, counties$key)]
}

# ---- Time -------------------------------------------------------------------

#' Snap a date to the Saturday that ends its MMWR (Sun-Sat) week.
week_ending_saturday <- function(d) {
  d <- as.Date(d)
  d + (6 - as.integer(format(d, "%w")))   # %w: 0=Sun ... 6=Sat
}

# ---- Core check: sum(county) vs state total ---------------------------------

#' For each (count_type, as_of_date): residual = state_total - sum(county).
#' A positive residual is normal (cases pending county assignment) and is kept,
#' not forced to zero. A negative residual is impossible for cumulative counts
#' and is flagged for review.
county_state_residual <- function(figures) {
  figures %>%
    group_by(count_type, as_of_date) %>%
    summarise(
      n_state     = sum(geography_level == "state"),
      n_county    = sum(geography_level == "county"),
      state_total = sum(count[geography_level == "state"], na.rm = TRUE),
      county_sum  = sum(count[geography_level == "county"], na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      residual     = state_total - county_sum,
      residual_pct = if_else(state_total > 0, residual / state_total, NA_real_),
      flag = case_when(
        n_state  == 0 ~ "no_state_total",
        n_county == 0 ~ "no_county_rows",
        residual < 0  ~ "county_exceeds_state",   # review
        residual > 0  ~ "unassigned_residual",    # expected; keep residual
        TRUE          ~ "balanced"
      )
    )
}

# ---- Cumulative monotonicity vs history -------------------------------------

#' Flag any (geography, count_type) whose new cumulative count is below the max
#' already seen. Revisions happen, but a drop warrants a look before it lands.
#' `history` is the accumulated long table (raw/*_history.csv.gz), or NULL.
check_monotonic <- function(current_long, history_long) {
  empty <- tibble(geography = character(), count_type = character(),
                  prev_max = numeric(), current = numeric(), drop = numeric())
  if (is.null(history_long) || nrow(history_long) == 0) return(empty)
  prev <- history_long %>%
    group_by(geography, count_type) %>%
    summarise(prev_max = max(count, na.rm = TRUE), .groups = "drop")
  current_long %>%
    inner_join(prev, by = c("geography", "count_type")) %>%
    filter(count < prev_max) %>%
    transmute(geography, count_type, prev_max, current = count, drop = prev_max - count)
}

# ---- Per-figure validation --------------------------------------------------

validate_figures <- function(figures) {
  figures %>%
    mutate(issue = case_when(
      is.na(as_of_date)            ~ "missing_as_of_date",
      is.na(count)                 ~ "missing_count",
      isTRUE(count_is_approximate) ~ "approximate_count",
      confidence < 0.6             ~ "low_confidence",
      TRUE                         ~ NA_character_
    ))
}

# ---- Standard wide output ---------------------------------------------------

#' Emit standard/data.csv.gz rows. Only geographies actually named are written:
#' partial_list articles produce NO zero rows for the counties they omit
#' (missing != zero). Default maps confirmed -> {prefix}_cases.
to_standard <- function(figures, prefix,
                        keep = c(confirmed = "cases",
                                 reported = "reported",
                                 hospitalized = "hospitalized")) {
  figures %>%
    filter(!is.na(geography_fips), !is.na(as_of_date), count_type %in% names(keep)) %>%
    mutate(time = format(week_ending_saturday(as_of_date), "%Y-%m-%d"),
           measure = paste0(prefix, "_", unname(keep[count_type]))) %>%
    transmute(geography = geography_fips, time, measure, count) %>%
    distinct(geography, time, measure, .keep_all = TRUE) %>%
    pivot_wider(names_from = measure, values_from = count)
}

# ---- Orchestrator -----------------------------------------------------------

#' @param extraction parsed JSON (list) validated against news_extraction.schema.json
#' @param all_fips   tibble from load_fips()
#' @param prefix     value-column prefix; defaults to "<state>_cyclo_news" e.g. "ky_cyclo_news"
#' @param history_long  prior long snapshots for monotonicity (or NULL)
reconcile <- function(extraction, all_fips, prefix = NULL, history_long = NULL) {
  state_abbr <- extraction$article$state_context
  state_fips <- state_abbr_to_fips(state_abbr, all_fips)
  if (is.null(prefix)) prefix <- paste0(tolower(state_abbr), "_cyclo_news")

  # extraction$figures is parsed with simplifyVector = FALSE (extract_via_llm()),
  # so it's an unnamed list of per-figure records - bind_rows() turns each
  # record into a row; as_tibble() would instead treat each record as a column.
  figures <- bind_rows(extraction$figures) %>%
    mutate(as_of_date = as.Date(as_of_date),
           count = as.integer(count))
  if (!"count_is_approximate" %in% names(figures)) figures$count_is_approximate <- FALSE
  if (!"origin_agency" %in% names(figures))        figures$origin_agency <- NA_character_

  # Resolve FIPS: counties state-scoped; state rows get the 2-digit state FIPS.
  is_cty <- figures$geography_level == "county"
  figures$geography_fips <- NA_character_
  figures$geography_fips[is_cty] <-
    resolve_county_fips(figures$geography_name[is_cty], state_fips, all_fips)
  figures$geography_fips[!is_cty] <- state_fips

  val       <- validate_figures(figures)
  residual  <- county_state_residual(figures)
  unmatched <- figures %>% filter(is_cty, is.na(geography_fips))

  long_now <- figures %>%
    filter(!is.na(geography_fips)) %>%
    transmute(geography = geography_fips, count_type, as_of_date, count)
  mono <- check_monotonic(long_now, history_long)

  standard <- to_standard(figures, prefix)

  review <- bind_rows(
    val %>% filter(!is.na(issue)) %>%
      transmute(scope = "figure", geography_name, count_type, as_of_date,
                count, reason = issue),
    unmatched %>%
      transmute(scope = "figure", geography_name, count_type, as_of_date,
                count, reason = "county_fips_unmatched"),
    residual %>% filter(flag %in% c("county_exceeds_state", "no_state_total")) %>%
      transmute(scope = "reconciliation", geography_name = NA_character_,
                count_type, as_of_date, count = residual, reason = flag),
    mono %>%
      transmute(scope = "monotonic", geography_name = geography, count_type,
                as_of_date = as.Date(NA), count = current, reason = "cumulative_drop")
  )

  provenance <- tibble(
    url            = extraction$article$url,
    outlet         = extraction$article$outlet,
    outlet_tier    = extraction$article$outlet_tier %||% NA_character_,
    origin_agency  = paste(unique(stats::na.omit(figures$origin_agency)), collapse = "; "),
    published_time = extraction$article$published_time,
    state          = state_abbr,
    n_figures      = nrow(figures),
    n_review       = nrow(review),
    run_ts         = as.character(Sys.time())
  )

  list(standard = standard, long = long_now, residual = residual,
       monotonic = mono, review = review, provenance = provenance)
}

# ---- Example / smoke test (uncomment to run) --------------------------------
# NOTE: load_fips()'s default path ("../../resources/all_fips.csv.gz") assumes
# the caller's cwd is a data/<source>/ folder (two levels below cyclo_scraper/),
# matching how dcf_build()/dcf_process() invoke each source's ingest.R. Running
# this smoke test directly with `Rscript scripts/reconcile.R` (cwd = scripts/,
# one level below cyclo_scraper/) needs the path override shown below instead.
# ex   <- jsonlite::read_json("../news_scraper/test_ky.json", simplifyVector = TRUE)  # the fixture
# fips <- load_fips("../resources/all_fips.csv.gz")
# out  <- reconcile(ex, fips)                 # prefix -> "ky_cyclo_news"
# stopifnot(
#   sum(out$long$count[out$long$count_type == "confirmed" &
#                      nchar(out$long$geography) == 5]) == 104,
#   subset(out$residual, count_type == "confirmed")$residual == 4,
#   subset(out$residual, count_type == "confirmed")$flag == "unassigned_residual"
# )
