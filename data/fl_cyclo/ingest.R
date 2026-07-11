# =============================================================================
# Florida Cyclosporiasis (FL DOH FLHealthCHARTS) - County x Weekly Ingestion
# Source: Reportable Diseases Frequency Report (Merlin surveillance system)
#   https://www.flhealthcharts.gov/ChartsReports/rdPage.aspx?rdReport=FrequencyMerlin.Frequency
#
# Mechanism
# ---------
# The public UI is an ASP.NET/"Logi Analytics" (rdPage.aspx) reporting app. The
# visible filter form posts to itself, which in turn drives a hidden iframe
# (name="sub_merlinReport") that renders the actual pivot ("dimension grid")
# table. That hidden iframe's own <form> posts directly to:
#
#   POST https://www.flhealthcharts.gov/ChartsReports/rdPage.aspx
#     rdReport=FrequencyMerlin.FrequencyReport_DimensionGrid
#     chkList_County=1,2,...,67        (numeric county IDs, alphabetical 1-67)
#     chkList_Diseases=19              (19 = Cyclosporiasis, alphabetical position
#                                        in the disease checklist as of 2026-07)
#     chkList_DiseaseStatus=CONFIRMED|PROBABLE   (blank = both combined)
#     txtDateFrom=MM/DD/YYYY, txtEndDt=MM/DD/YYYY
#     rdDgLoadSaved=MyBookmarkCollection_af77e1d2-e3e4-430b-a721-b0ff438808f5.xml
#     rdDgReset=True, rdSubReport=True, rdResizeFrame=True
#
# This was reverse-engineered with chromote (CDP network capture + a headless
# click-through of the real filter form), then verified to be fully replayable
# with a single direct httr::POST call -- no session/cookie or CSRF token is
# required, and no live browser is needed at runtime. `rdDgLoadSaved` refers to
# a fixed, report-level "default view" bookmark (Rows=County, Values=Counts)
# that is identical across sessions -- without it the dimension grid renders
# with nothing selected (an empty shell).
#
# IMPORTANT LIMITATION: the dimension-grid pivot UI only exposes "Reported
# Month", "Reported Year and Month" and "Reported Year" as time dimensions --
# there is no "Reported Week" pivot field, even though the underlying MMWR
# surveillance data is collected/published weekly. Week-level resolution is
# therefore obtained by using the report's *date-range filter* itself as the
# week selector: one request per MMWR epi-week (Sunday-Saturday), each
# returning a County x Counts table for just that week. This does achieve true
# county + weekly resolution, at the cost of one HTTP request per
# week-per-disease-status (~0.5s each).
#
# INCREMENTAL FETCHING: a persistent cache (raw/fl_cyclo_weekly_county_history.csv.gz)
# accumulates every week ever fetched. On each run, weeks older than
# REFRESH_WEEKS_BACK are trusted from cache and NOT re-fetched; only the recent
# rolling window (which can still be revised by FL DOH) plus any genuinely new
# week is re-queried. The very first run (no cache yet) does a full
# LOOKBACK_WEEKS backfill. This keeps routine scheduled runs to ~REFRESH_WEEKS_BACK
# x 2 requests (a few seconds) instead of re-fetching the full history every time.
# =============================================================================

library(dplyr)
library(httr)

if (!file.exists("process.json")) {
  process <- list(raw_state = NULL)
} else {
  process <- dcf::dcf_process_record()
}

if (!dir.exists("raw")) dir.create("raw")

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
LOOKBACK_WEEKS <- 104     # ~2 years of MMWR weeks; used for the first-ever (cold) backfill
REFRESH_WEEKS_BACK <- 10  # always re-fetch the most recent N weeks (revisions/reporting lag)
HISTORY_PATH <- "raw/fl_cyclo_weekly_county_history.csv.gz"
# A week with zero statewide cases produces NO rows in the history cache (the
# source only returns counties with >0 cases), so cache row-presence alone
# can't distinguish "fetched, genuinely zero" from "never fetched". A separate
# manifest of every week_end actually attempted (regardless of outcome) is
# needed to make the cache/refresh logic correct.
FETCHED_WEEKS_PATH <- "raw/fl_cyclo_fetched_weeks.csv"
DISEASE_ID <- "19"      # Cyclosporiasis (alphabetical position in chkList_Diseases)
COUNTY_IDS <- paste(1:67, collapse = ",")
BOOKMARK <- "MyBookmarkCollection_af77e1d2-e3e4-430b-a721-b0ff438808f5.xml"
POST_URL <- "https://www.flhealthcharts.gov/ChartsReports/rdPage.aspx"
UA <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36 dcf-fl_cyclo-ingest"

# -----------------------------------------------------------------------------
# Compute the most recent COMPLETE MMWR epi-week (Sunday-Saturday) available.
# FLHealthCHARTS updates every Thursday with the previous MMWR week's data;
# this replicates the site's own client-side JS validation formula exactly
# (ValidateSearchCriteria() in the page source) so we never request a date
# range beyond what the server considers valid.
# -----------------------------------------------------------------------------
most_recent_epiweek_end <- function(today = Sys.Date()) {
  wday <- as.POSIXlt(today)$wday  # 0 = Sunday ... 6 = Saturday
  days_back <- c(8, 9, 10, 11, 5, 6, 7)[wday + 1]
  today - days_back
}

latest_week_end <- most_recent_epiweek_end()

# -----------------------------------------------------------------------------
# Load the persistent weekly history cache, if any, and decide which weeks
# actually need to be (re-)fetched this run.
# -----------------------------------------------------------------------------
history_cached <- if (file.exists(HISTORY_PATH)) {
  vroom::vroom(HISTORY_PATH, delim = ",", show_col_types = FALSE, altrep = FALSE) %>%
    mutate(week_end = as.character(week_end))
} else {
  data.frame(county_name = character(0), count = integer(0),
             week_end = character(0), disease_status = character(0))
}

fetched_weeks_manifest <- if (file.exists(FETCHED_WEEKS_PATH)) {
  as.character(vroom::vroom(FETCHED_WEEKS_PATH, delim = ",", show_col_types = FALSE, altrep = FALSE)$week_end)
} else {
  character(0)
}

full_week_ends <- latest_week_end - 7 * (0:(LOOKBACK_WEEKS - 1))

refresh_cutoff <- latest_week_end - 7 * (REFRESH_WEEKS_BACK - 1)

weeks_to_fetch <- full_week_ends[
  as.character(full_week_ends) >= as.character(refresh_cutoff) |
  !as.character(full_week_ends) %in% fetched_weeks_manifest
]

week_ends <- weeks_to_fetch
week_starts <- week_ends - 6

cat("Weeks already fetched previously:", length(fetched_weeks_manifest),
    "| weeks to (re-)fetch this run:", length(week_ends), "\n")

# -----------------------------------------------------------------------------
# Fetch one week's County x Counts grid for a given diagnosis status
# ("CONFIRMED", "PROBABLE", or "" for combined). Returns a data.frame with
# columns county_name, count (only counties with >0 cases are present in the
# raw response; callers should zero-fill the rest).
# -----------------------------------------------------------------------------
fetch_county_week <- function(disease_status, from_dt, to_dt, max_tries = 3) {
  kv <- character(0)
  add_kv <- function(name, value) {
    kv[[length(kv) + 1]] <<- paste0(URLencode(name, reserved = TRUE), "=", URLencode(as.character(value), reserved = TRUE))
  }
  add_kv("rdReport", "FrequencyMerlin.FrequencyReport_DimensionGrid")
  add_kv("chkList_AcquiredStatus", "")
  add_kv("chkList_AgeGroup", "")
  add_kv("chkList_County", COUNTY_IDS)
  add_kv("chkList_Diseases", DISEASE_ID)
  add_kv("chkList_DiseaseStatus", disease_status)
  add_kv("rdDgLoadSaved", BOOKMARK)
  add_kv("rdDgReset", "True")
  add_kv("txtCounties", "")
  add_kv("txtDateFrom", format(from_dt, "%m/%d/%Y"))
  add_kv("txtDiseases", "")
  add_kv("txtEndDt", format(to_dt, "%m/%d/%Y"))
  add_kv("rdSubReport", "True")
  add_kv("rdResizeFrame", "True")
  body_str <- paste(kv, collapse = "&")

  html <- NULL
  for (attempt in seq_len(max_tries)) {
    resp <- tryCatch(
      httr::POST(
        POST_URL,
        httr::add_headers(`User-Agent` = UA, `Content-Type` = "application/x-www-form-urlencoded"),
        body = body_str
      ),
      error = function(e) NULL
    )
    if (!is.null(resp) && httr::status_code(resp) == 200) {
      html <- httr::content(resp, as = "text", encoding = "UTF-8")
      break
    }
    Sys.sleep(1.5 * attempt)
  }
  if (is.null(html)) {
    warning("Failed to fetch ", from_dt, " - ", to_dt, " (status ", disease_status, ") after ", max_tries, " tries")
    return(data.frame(county_name = character(0), count = integer(0)))
  }

  name_pat <- 'id="lbl\\[County\\]_Row([0-9]+)">([^<]+)</SPAN>'
  count_pat <- 'id="lbl_x005B_Measures_x005D_\\._x005B_Counts_x005D__Row([0-9]+)">([0-9]+)</SPAN>'

  name_matches <- regmatches(html, gregexpr(name_pat, html, perl = TRUE))[[1]]
  count_matches <- regmatches(html, gregexpr(count_pat, html, perl = TRUE))[[1]]
  if (length(name_matches) == 0) return(data.frame(county_name = character(0), count = integer(0)))

  extract_row <- function(x) as.integer(sub('.*_Row([0-9]+)">.*', "\\1", x))
  extract_name <- function(x) sub('.*_Row[0-9]+">([^<]+)</SPAN>', "\\1", x)
  extract_count <- function(x) as.integer(sub('.*_Row[0-9]+">([0-9]+)</SPAN>', "\\1", x))

  names_df <- data.frame(row = sapply(name_matches, extract_row), county_name = sapply(name_matches, extract_name))
  counts_df <- data.frame(row = sapply(count_matches, extract_row), count = sapply(count_matches, extract_count))
  merged <- merge(names_df, counts_df, by = "row")

  # Row 1 is always the Grand Total (blank/non-breaking-space county name) - drop it
  merged$county_name <- trimws(gsub(" ", "", merged$county_name))
  merged <- merged[nzchar(merged$county_name), c("county_name", "count")]
  rownames(merged) <- NULL
  merged
}

# -----------------------------------------------------------------------------
# 1. Download: pull County x Counts for only the weeks that need (re-)fetching
#    ({CONFIRMED, PROBABLE} each), then merge into the persistent history cache.
# -----------------------------------------------------------------------------
all_rows <- list()
i <- 0
for (w in seq_along(week_ends)) {
  for (status in c("CONFIRMED", "PROBABLE")) {
    df <- fetch_county_week(status, week_starts[w], week_ends[w])
    if (nrow(df) > 0) {
      df$week_end <- as.character(week_ends[w])
      df$disease_status <- status
      i <- i + 1
      all_rows[[i]] <- df
    }
    Sys.sleep(0.1)
  }
}

fetched_long <- if (length(all_rows) > 0) {
  dplyr::bind_rows(all_rows)
} else {
  data.frame(county_name = character(0), count = integer(0), week_end = character(0), disease_status = character(0))
}

# Merge freshly-fetched weeks into the cache, replacing any pre-existing rows
# for those same weeks (in case of revisions), and drop anything now outside
# the LOOKBACK_WEEKS output window (keeps the cache from growing unbounded).
history_merged <- history_cached %>%
  filter(!week_end %in% as.character(week_ends)) %>%
  bind_rows(fetched_long) %>%
  filter(week_end %in% as.character(full_week_ends))

vroom::vroom_write(history_merged, HISTORY_PATH, delim = ",")

# Update the fetched-weeks manifest: everything fetched this run, unioned with
# prior weeks still inside the LOOKBACK_WEEKS output window.
manifest_merged <- union(
  as.character(week_ends),
  intersect(fetched_weeks_manifest, as.character(full_week_ends))
)
vroom::vroom_write(
  data.frame(week_end = sort(manifest_merged)),
  FETCHED_WEEKS_PATH,
  delim = ","
)

raw_long <- history_merged
week_ends <- full_week_ends   # downstream transform uses the FULL output range
week_starts <- week_ends - 6

raw_state <- list(hash = unname(tools::md5sum(HISTORY_PATH)))

# -----------------------------------------------------------------------------
# 2. Transform (only if the merged history actually changed since last run)
# -----------------------------------------------------------------------------
if (!identical(process$raw_state, raw_state)) {

  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE)

  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5, state == "FL") %>%
    select(geography, geography_name) %>%
    mutate(county_name = sub(" County$", "", geography_name)) %>%
    # Exclude the deprecated pre-1997 "Dade County" (12025) FIPS code, superseded
    # by "Miami-Dade County" (12086); keeping both would create a spurious
    # all-zero geography since the source only ever reports "Miami-Dade".
    filter(geography != "12025")

  # Full county x week grid so "no cases reported" is an explicit 0, not a
  # missing row (cyclosporiasis is rare - most county-weeks are legitimately 0)
  full_grid <- expand.grid(
    county_name = county_fips_lookup$county_name,
    week_end = as.character(week_ends),
    stringsAsFactors = FALSE
  )

  counts_wide <- raw_long %>%
    filter(nchar(county_name) > 0) %>%
    group_by(county_name, week_end, disease_status) %>%
    summarize(count = sum(count), .groups = "drop") %>%
    tidyr::pivot_wider(
      names_from = disease_status,
      values_from = count,
      values_fill = 0,
      names_prefix = "status_"
    )

  data_standard <- full_grid %>%
    left_join(counts_wide, by = c("county_name", "week_end")) %>%
    mutate(
      fl_cyclo_cases = ifelse(is.na(status_CONFIRMED), 0, status_CONFIRMED),
      fl_cyclo_cases_probable = ifelse(is.na(status_PROBABLE), 0, status_PROBABLE)
    ) %>%
    left_join(county_fips_lookup, by = "county_name") %>%
    filter(!is.na(geography)) %>%
    mutate(time = format(as.Date(week_end), "%Y-%m-%d")) %>%
    select(geography, time, fl_cyclo_cases, fl_cyclo_cases_probable) %>%
    arrange(geography, time)

  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
