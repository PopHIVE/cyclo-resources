# =============================================================================
# Ohio Cyclosporiasis Data Ingestion (county x week)
#
# Source: "Summary of Infectious Diseases in Ohio" dashboard, Ohio Department
# of Health, published on the DataOhio Portal:
#   https://data.ohio.gov/wps/portal/gov/data/view/summary-of-infectious-diseases-in-ohio
#
# The dashboard embeds a Tableau Server visualization hosted at
# analytics.das.ohio.gov (site "ODHDPPUB", workbook "GeneralCaseCountPublicPROD",
# dashboard "GeographicalDistribution"). That published view supports Tableau
# Server's standard unauthenticated crosstab export (`<view>.csv`), and its two
# date parameters ("p_startdate"/"p_enddate", displayed on the dashboard as
# "Event Start Date"/"Event End Date") and its "Reportable Condition" quick
# filter can both be set directly via ordinary URL query parameters. No
# browser/JS session is required at runtime -- the CSV endpoint is queried
# directly with httr, once per county-level snapshot.
#
# Mechanism discovery notes (see README.md for the full narrative):
#   - The dashboard's own base URL 404s when fetched headlessly (it is an IBM
#     WebSphere ("wps") portal page that needs a live navigation-state token);
#     the underlying Tableau workbook is reachable directly and does not.
#   - GET https://analytics.das.ohio.gov/t/ODHDPPUB/views/GeneralCaseCountPublicPROD/GeographicalDistribution.csv
#     returns "County (group),Case Count" for the CURRENT filter/parameter state.
#   - Filters/parameters are set via ordinary query string keys matching their
#     Tableau field caption, e.g. `?Reportable%20Condition=Cyclosporiasis`.
#   - The visible "Event Start Date"/"Event End Date" parameter controls are
#     internally named "p_startdate"/"p_enddate" (found via a chromote capture
#     of the Tableau vizql bootstrapSession response) and accept plain
#     YYYY-MM-DD values, e.g. `&p_startdate=2026-01-01&p_enddate=2026-01-07`.
#   - Requesting a single Sunday-Saturday week therefore returns each OH
#     county's Cyclosporiasis case count for exactly that week: true
#     COUNTY x WEEK resolution, sourced directly from ODH's own dashboard.
#
# Efficiency: querying every week since 2001 individually would need ~1,300
# requests. Instead we first request ANNUAL county totals (cheap, one request
# per year) to find which years have ANY reported Cyclosporiasis activity in
# Ohio. Years with zero statewide cases are zero-filled for every county/week
# without further requests; only years with nonzero activity are re-queried at
# weekly resolution. This is a huge reduction in request count with no loss of
# information (a zero annual total guarantees every constituent week is zero).
#
# INCREMENTAL FETCHING: on top of the annual-scan reduction above, a persistent
# cache (raw/oh_cyclo_weekly_history.csv.gz) accumulates every active-year week
# ever fetched, tracked via a manifest (raw/oh_cyclo_fetched_weeks.csv) of
# week_ends actually attempted (a week with zero cases produces no data rows,
# so the manifest -- not row presence -- is what distinguishes "fetched,
# genuinely zero" from "never fetched"). Only weeks inside REFRESH_WEEKS_BACK of
# today, or not yet in the manifest, are re-queried each run; the annual scan
# itself is still redone every run (cheap, ~14 requests) so a newly-active
# historical year is picked up automatically. This turns routine scheduled runs
# from ~700 requests into ~14 (annual scan) + ~REFRESH_WEEKS_BACK (recent weeks).
#
# Suppression: ODH's public disclosure text states that "some data may be
# unavailable if fewer than ten cases are reported over the chosen timeframe."
# Empirically (tested extensively during development -- see README.md) this
# view does NOT hide small nonzero county counts (single-digit county counts,
# and even statewide annual totals as low as 1-7, were returned in full). No
# suppression was observed on this county x week extraction. We still carry a
# `suppressed_flag` column for schema compliance (always 0 here); if a future
# maintainer slices this dashboard by age/sex/race and finds rows
# disappearing, THAT is where suppression bites, not here.
# =============================================================================

library(dplyr)
library(httr)
library(vroom)

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
disease_name <- "Cyclosporiasis"

tableau_base <- "https://analytics.das.ohio.gov/t/ODHDPPUB/views/GeneralCaseCountPublicPROD/GeographicalDistribution.csv"

# Full history is available back to 2001, but Ohio cyclosporiasis activity
# before 2013 is essentially nil (checked 2001-2012: at most 1 statewide case
# in any single year). Starting in 2013 captures every year with meaningful
# activity through the current (2026) outbreak while keeping the request
# count for a full re-run manageable. Adjust HISTORY_START to go back further.
history_start <- as.Date("2013-01-01")
today <- Sys.Date()
REFRESH_WEEKS_BACK <- 10  # always re-fetch the most recent N weeks (revisions/reporting lag)
HISTORY_PATH <- "raw/oh_cyclo_weekly_history.csv.gz"
FETCHED_WEEKS_PATH <- "raw/oh_cyclo_fetched_weeks.csv"

# Most recent COMPLETE Sunday-Saturday epi week ending on or before today.
last_complete_saturday <- today
while (as.integer(format(last_complete_saturday, "%w")) != 6) {
  last_complete_saturday <- last_complete_saturday - 1
}

first_saturday <- history_start
while (as.integer(format(first_saturday, "%w")) != 6) {
  first_saturday <- first_saturday + 1
}

week_ends <- seq(first_saturday, last_complete_saturday, by = "week")

ua <- httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) pophive-dcf-ingest")

# -----------------------------------------------------------------------------
# Helper: query the published Tableau view's crosstab CSV export for a given
# date window, return a data.frame(county, cases). An empty result means the
# view returned no rows, i.e. 0 statewide cases in that window.
# -----------------------------------------------------------------------------
query_window <- function(start_date, end_date, retries = 3) {
  qs <- list(
    `Reportable Condition` = disease_name,
    p_startdate = format(start_date, "%Y-%m-%d"),
    p_enddate   = format(end_date,   "%Y-%m-%d")
  )
  for (attempt in seq_len(retries)) {
    resp <- tryCatch(
      httr::GET(tableau_base, query = qs, ua, httr::timeout(30)),
      error = function(e) NULL
    )
    if (!is.null(resp) && httr::status_code(resp) == 200) {
      txt <- httr::content(resp, as = "text", encoding = "UTF-8")
      lines <- strsplit(txt, "\r?\n")[[1]]
      if (length(lines) <= 1) return(data.frame(county = character(0), cases = numeric(0)))
      body <- lines[-1]
      body <- body[nzchar(body)]
      if (length(body) == 0) return(data.frame(county = character(0), cases = numeric(0)))
      # rows look like: County,1234   or   County,"1,439"
      parts <- strsplit(body, ",")
      county <- vapply(parts, `[`, "", 1)
      case_txt <- vapply(parts, function(x) paste(x[-1], collapse = ","), "")
      case_txt <- gsub('"', "", case_txt, fixed = TRUE)
      cases <- suppressWarnings(as.numeric(case_txt))
      return(data.frame(county = county, cases = cases, stringsAsFactors = FALSE))
    }
    Sys.sleep(1)
  }
  warning("Failed to fetch window ", start_date, " - ", end_date, " after ", retries, " attempts")
  data.frame(county = character(0), cases = numeric(0))
}

# -----------------------------------------------------------------------------
# Step 1: cheap annual scan to find which years have ANY Cyclosporiasis
# activity in Ohio, so we only drill into weekly resolution where needed.
# -----------------------------------------------------------------------------
years <- seq(as.integer(format(history_start, "%Y")), as.integer(format(today, "%Y")))

cat("Scanning", length(years), "years for Cyclosporiasis activity...\n")
active_years <- integer(0)
for (yr in years) {
  yr_start <- as.Date(sprintf("%d-01-01", yr))
  yr_end   <- min(as.Date(sprintf("%d-12-31", yr)), today)
  d <- query_window(yr_start, yr_end)
  d <- d[!is.na(d$cases) & tolower(d$county) != "unknown", , drop = FALSE]
  yr_total <- sum(d$cases)
  cat(" ", yr, ": statewide total =", yr_total, "\n")
  if (yr_total > 0) active_years <- c(active_years, yr)
  Sys.sleep(0.2)
}
cat("Active years (weekly drill-down needed):", paste(active_years, collapse = ", "), "\n")

# -----------------------------------------------------------------------------
# Step 2: figure out which active-year weeks actually need (re-)fetching this
# run -- everything else is either zero-filled directly (inactive year) or
# trusted from the persistent history cache (already fetched, outside the
# refresh window).
# -----------------------------------------------------------------------------
if (!dir.exists("raw")) dir.create("raw")

history_cached <- if (file.exists(HISTORY_PATH)) {
  vroom::vroom(HISTORY_PATH, delim = ",", show_col_types = FALSE, altrep = FALSE) %>%
    mutate(week_end = as.Date(week_end))
} else {
  data.frame(week_end = as.Date(character(0)), county = character(0), cases = numeric(0))
}

fetched_weeks_manifest <- if (file.exists(FETCHED_WEEKS_PATH)) {
  as.Date(vroom::vroom(FETCHED_WEEKS_PATH, delim = ",", show_col_types = FALSE, altrep = FALSE)$week_end)
} else {
  as.Date(character(0))
}

refresh_cutoff <- max(week_ends) - 7 * (REFRESH_WEEKS_BACK - 1)

active_week_ends <- week_ends[vapply(week_ends, function(we) {
  yrs_touched <- unique(as.integer(format(c(we - 6, we), "%Y")))
  any(yrs_touched %in% active_years)
}, logical(1))]

weeks_to_fetch <- active_week_ends[
  active_week_ends >= refresh_cutoff | !active_week_ends %in% fetched_weeks_manifest
]

cat("Active-year weeks:", length(active_week_ends),
    "| already fetched previously:", sum(active_week_ends %in% fetched_weeks_manifest),
    "| to (re-)fetch this run:", length(weeks_to_fetch), "\n")

weekly_results <- vector("list", length(weeks_to_fetch))

for (i in seq_along(weeks_to_fetch)) {
  we <- weeks_to_fetch[i]
  ws <- we - 6
  d <- query_window(ws, we)
  d <- d[!is.na(d$cases) & tolower(d$county) != "unknown", , drop = FALSE]
  Sys.sleep(0.15)

  if (nrow(d) == 0) {
    weekly_results[[i]] <- data.frame(
      week_end = as.Date(character(0)),
      county   = character(0),
      cases    = numeric(0),
      stringsAsFactors = FALSE
    )
  } else {
    weekly_results[[i]] <- data.frame(
      week_end = we,
      county   = d$county,
      cases    = d$cases,
      stringsAsFactors = FALSE
    )
  }
  if (i %% 50 == 0) cat("  processed", i, "/", length(weeks_to_fetch), "weeks\n")
}

fetched_weekly <- dplyr::bind_rows(weekly_results)

# Merge freshly-fetched weeks into the cache, replacing any pre-existing rows
# for those same weeks (in case of revisions), and drop anything outside the
# active-year history range.
history_merged <- history_cached %>%
  filter(!week_end %in% weeks_to_fetch) %>%
  bind_rows(fetched_weekly) %>%
  filter(week_end %in% active_week_ends)

vroom::vroom_write(history_merged, HISTORY_PATH, delim = ",")

manifest_merged <- union(
  weeks_to_fetch,
  intersect(fetched_weeks_manifest, active_week_ends)
)
vroom::vroom_write(
  data.frame(week_end = sort(manifest_merged)),
  FETCHED_WEEKS_PATH,
  delim = ","
)

raw_weekly <- history_merged
cat("Total nonzero county-week rows in merged history:", nrow(raw_weekly), "\n")

# -----------------------------------------------------------------------------
# Raw-state change detection (dcf convention)
# -----------------------------------------------------------------------------
if (!file.exists("process.json")) {
  process <- list(raw_state = NULL)
} else {
  process <- dcf::dcf_process_record()
}

raw_state <- list(
  n_rows      = nrow(raw_weekly),
  total_cases = sum(raw_weekly$cases, na.rm = TRUE),
  last_week   = as.character(max(week_ends)),
  hash        = unname(tools::md5sum(HISTORY_PATH))
)

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # FIPS lookup (county-level, Ohio only)
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE)

  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5, state == "OH") %>%
    select(geography, geography_name) %>%
    mutate(county_name = sub(" County$", "", geography_name))

  # ---------------------------------------------------------------------------
  # Zero-fill: every OH county x every week in range, defaulting to 0 cases,
  # then overlay the actual fetched (nonzero) counts.
  # ---------------------------------------------------------------------------
  full_panel <- tidyr::expand_grid(
    week_end = week_ends,
    county_name = county_fips_lookup$county_name
  )

  data_standard <- full_panel %>%
    left_join(raw_weekly, by = c("week_end", "county_name" = "county")) %>%
    mutate(cases = ifelse(is.na(cases), 0, cases)) %>%
    left_join(county_fips_lookup, by = "county_name") %>%
    transmute(
      geography = geography,
      time = format(week_end, "%Y-%m-%d"),
      oh_cyclo_cases = cases,
      suppressed_flag = 0L
    ) %>%
    filter(!is.na(geography)) %>%
    arrange(geography, time)

  # ---------------------------------------------------------------------------
  # Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  cat("Wrote", nrow(data_standard), "rows to standard/data.csv.gz\n")
  cat("Counties:", length(unique(data_standard$geography)),
      "| Weeks:", length(unique(data_standard$time)),
      "| Date range:", min(data_standard$time), "to", max(data_standard$time), "\n")
  cat("Total cases represented:", sum(data_standard$oh_cyclo_cases), "\n")

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)

} else {
  cat("No change in source data since last run; standard/data.csv.gz left as-is.\n")
}
