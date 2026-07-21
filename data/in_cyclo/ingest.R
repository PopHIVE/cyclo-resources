# =============================================================================
# Indiana Cyclosporiasis Outbreak (2026) - County-level DAILY case counts
#
# Source: Indiana Department of Health (IDOH), Infectious Disease Epidemiology
# & Prevention Division (IDEPD) "Cyclosporiasis" resource page, "Cases by
# County" accordion table:
#   https://www.in.gov/health/idepd/diseases-and-conditions-resource-page/cyclosporiasis/#Cases_by_County
#
# Notes:
#   - The table lives inside a collapsible accordion ("Cases by County") on a
#     plain server-rendered HTML page - NOT a Tableau/Power BI/ArcGIS
#     dashboard. A normal GET with a browser User-Agent returns it directly;
#     no headless browser is needed at runtime.
#   - IDOH's own "Data notes" state this table is "updated each day, Monday
#     through Friday, by 1 p.m. EDT" - the finest temporal resolution of any
#     source in this project (the others are weekly at best). Because of that,
#     the native per-update date is kept as `time` here rather than being
#     rounded to a Saturday week-ending date (the convention used by the
#     weekly sources fl_cyclo/oh_cyclo/mi_cyclo).
#   - Case counts are CUMULATIVE since the investigation's start, per IDOH's
#     own note: "Case counts reflect all reported cases of cyclosporiasis
#     during the investigation time frame (beginning 5/1/2026)." This is the
#     same cumulative-snapshot framing mi_cyclo and ca_cyclo use for their
#     respective outbreak pages, not a true daily incident count.
#   - As with mi_cyclo/ca_cyclo, the live page only ever shows the single
#     latest cumulative snapshot (no historical archive), so this script
#     accumulates one dated snapshot per distinct "Last updated" date into a
#     persistent raw history file (raw/in_cyclo_county_snapshots.csv), and
#     derives day-over-day incident ("new cases") counts by differencing
#     successive snapshots collected across scheduled runs.
#   - The "Last updated" caption gives only a month/day (e.g. "July 20"), with
#     no year. If IDOH ever adds an explicit year to the caption it is used
#     directly; otherwise the year is inferred as the current year unless
#     that would place the date in the future, in which case the previous
#     year is used (guards against a run that happens to straddle a
#     December/January boundary).
#   - Counties with zero cumulative cases are simply absent from IDOH's table
#     (it is not zero-filled by the source), matching mi_cyclo's convention;
#     this ingest does not synthesize zero rows for counties never listed.
# =============================================================================

library(dplyr)
library(rvest)
library(httr)
library(vroom)

if (!dir.exists("raw")) dir.create("raw")
if (!dir.exists("standard")) dir.create("standard")

if (!file.exists("process.json")) {
  process <- list(raw_state = NULL)
} else {
  process <- dcf::dcf_process_record()
}

# -----------------------------------------------------------------------------
# 1. Download the page (server-rendered HTML; plain GET works with a normal
#    browser User-Agent).
# -----------------------------------------------------------------------------
source_url <- "https://www.in.gov/health/idepd/diseases-and-conditions-resource-page/cyclosporiasis/"

resp <- httr::RETRY(
  "GET",
  source_url,
  httr::add_headers(
    `User-Agent` = paste(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ),
    `Accept-Language` = "en-US,en;q=0.9",
    `Accept` = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  ),
  times = 3,
  pause_min = 5
)

if (httr::status_code(resp) != 200) {
  stop("Failed to fetch IDOH Cyclosporiasis page: HTTP ", httr::status_code(resp))
}

html_txt <- httr::content(resp, as = "text", encoding = "UTF-8")
page <- rvest::read_html(html_txt)

# -----------------------------------------------------------------------------
# 2. Locate the "Cases by County" table by its header row text (rather than
#    assuming table order/position, since the page has other tables/accordions
#    - e.g. Current Recommendations tabs - that could shift around).
# -----------------------------------------------------------------------------
tbl_nodes <- rvest::html_elements(page, "table")
if (length(tbl_nodes) == 0) {
  stop("No <table> elements found on the IDOH Cyclosporiasis page - ",
       "page structure may have changed.")
}

county_tbl_idx <- NULL
for (i in seq_along(tbl_nodes)) {
  header_txt <- tolower(rvest::html_text2(tbl_nodes[[i]]))
  if (grepl("county", header_txt, fixed = TRUE) &&
      grepl("number of cyclosporiasis cases reported", header_txt, fixed = TRUE)) {
    county_tbl_idx <- i
    break
  }
}
if (is.null(county_tbl_idx)) {
  stop("Could not find the 'Cases by County' cyclosporiasis table on the page - ",
       "source page structure may have changed.")
}

county_node <- tbl_nodes[[county_tbl_idx]]
county_raw <- rvest::html_table(county_node, header = FALSE, fill = TRUE)

# First row holds the header cells (plain <td>, not <th>); drop it and name columns
county_raw <- county_raw[-1, ]
names(county_raw) <- c("county_raw", "cases_cumulative")

# -----------------------------------------------------------------------------
# 3. Extract the "Last updated: <Month Day[, Year]>" caption and resolve it to
#    a full date.
# -----------------------------------------------------------------------------
page_text <- rvest::html_text2(page)
updated_match <- regmatches(
  page_text,
  regexpr("Last updated:\\s*[A-Za-z]+ [0-9]{1,2}(,\\s*[0-9]{4})?", page_text)
)
if (length(updated_match) == 0 || !nzchar(updated_match)) {
  stop("Could not find the 'Last updated' caption on the page - ",
       "source page structure may have changed.")
}
updated_txt <- trimws(sub("Last updated:\\s*", "", updated_match))

today <- Sys.Date()
if (grepl(",", updated_txt)) {
  last_update_date <- as.Date(updated_txt, format = "%B %d, %Y")
} else {
  this_year <- as.integer(format(today, "%Y"))
  last_update_date <- as.Date(paste(updated_txt, this_year), format = "%B %d %Y")
  if (!is.na(last_update_date) && last_update_date > today + 1) {
    last_update_date <- as.Date(paste(updated_txt, this_year - 1L), format = "%B %d %Y")
  }
}
if (is.na(last_update_date)) {
  stop("Could not parse the 'Last updated' date from text: ", updated_txt)
}

# -----------------------------------------------------------------------------
# 4. Clean the scraped rows and build the candidate raw_state used for dcf
#    change-detection.
# -----------------------------------------------------------------------------
county_clean <- county_raw %>%
  mutate(
    county_raw = trimws(county_raw),
    cases_cumulative = suppressWarnings(as.integer(gsub("[^0-9]", "", cases_cumulative)))
  ) %>%
  filter(!is.na(county_raw), county_raw != "", !is.na(cases_cumulative))

raw_state <- list(
  last_update_date = as.character(last_update_date),
  county_data = paste(
    county_clean$county_raw, county_clean$cases_cumulative,
    sep = ":", collapse = "|"
  )
)

# Save a dated raw HTML snapshot for audit trail (one per distinct update date;
# re-running the same day before the next 1pm EDT update overwrites the same file).
raw_html_path <- file.path("raw", paste0("in_cyclo_cyclosporiasis_", last_update_date, ".html"))
writeLines(html_txt, raw_html_path, useBytes = TRUE)

# -----------------------------------------------------------------------------
# 5. Only reprocess if the source data actually changed since the last run.
# -----------------------------------------------------------------------------
if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 5a. Append this day's snapshot to the persistent long-format history file.
  #     This is what allows a real daily time series to accumulate across
  #     successive scheduled runs, since the source page itself only ever
  #     shows the current cumulative snapshot (no historical table).
  # ---------------------------------------------------------------------------
  snapshot_path <- file.path("raw", "in_cyclo_county_snapshots.csv")

  new_snapshot <- county_clean %>%
    mutate(last_update_date = last_update_date) %>%
    select(last_update_date, county_raw, cases_cumulative)

  if (file.exists(snapshot_path)) {
    history <- vroom::vroom(snapshot_path, show_col_types = FALSE, altrep = FALSE) %>%
      mutate(last_update_date = as.Date(last_update_date))
    # Drop any existing rows for this same update date (idempotent re-run), then add fresh
    history <- history %>% filter(last_update_date != !!last_update_date)
    history <- bind_rows(history, new_snapshot)
  } else {
    history <- new_snapshot
  }

  history <- history %>% arrange(last_update_date, county_raw)
  vroom::vroom_write(history, snapshot_path, delim = ",")

  # ---------------------------------------------------------------------------
  # 5b. FIPS lookup (county-level), per project convention.
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE, altrep = FALSE)

  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5, state == "IN") %>%
    select(geography, geography_name) %>%
    mutate(
      county_name = sub(" County$", "", geography_name),
      county_name_key = tolower(gsub("[[:punct:]]", "", county_name))
    )

  # ---------------------------------------------------------------------------
  # 5c. Map scraped county names onto county FIPS codes. Matching is done on a
  #     punctuation-stripped, lowercased key so that e.g. "St. Joseph" (as
  #     scraped) matches "St. Joseph County" (as listed in the FIPS crosswalk).
  # ---------------------------------------------------------------------------
  history_mapped <- history %>%
    mutate(county_name_key = tolower(gsub("[[:punct:]]", "", trimws(county_raw)))) %>%
    left_join(
      county_fips_lookup %>% select(geography, county_name_key),
      by = "county_name_key"
    )

  unmatched <- history_mapped %>% filter(is.na(geography)) %>% distinct(county_raw)
  if (nrow(unmatched) > 0) {
    warning(
      "in_cyclo: the following scraped county names did not match any Indiana ",
      "county FIPS code and were dropped: ", paste(unmatched$county_raw, collapse = ", ")
    )
  }

  # ---------------------------------------------------------------------------
  # 5d. Aggregate to county FIPS x date, and derive a day-over-day incident
  #     ("new cases") column by differencing the cumulative count across the
  #     accumulated daily snapshots for each county.
  # ---------------------------------------------------------------------------
  data_standard <- history_mapped %>%
    filter(!is.na(geography)) %>%
    group_by(geography, last_update_date) %>%
    summarize(in_cyclo_cases_cumulative = sum(cases_cumulative), .groups = "drop") %>%
    arrange(geography, last_update_date) %>%
    group_by(geography) %>%
    mutate(
      in_cyclo_cases_new = in_cyclo_cases_cumulative - dplyr::lag(in_cyclo_cases_cumulative)
    ) %>%
    ungroup() %>%
    transmute(
      geography,
      time = format(last_update_date, "%Y-%m-%d"),
      in_cyclo_cases_cumulative,
      in_cyclo_cases_new
    ) %>%
    arrange(geography, time)

  # ---------------------------------------------------------------------------
  # 6. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  cat("Wrote", nrow(data_standard), "rows to standard/data.csv.gz\n")
  cat("Counties:", length(unique(data_standard$geography)),
      "| Snapshot dates:", length(unique(data_standard$time)), "\n")

  # ---------------------------------------------------------------------------
  # 7. Record processed state
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)

} else {
  cat("No change in source data since last run; standard/data.csv.gz left as-is.\n")
}
