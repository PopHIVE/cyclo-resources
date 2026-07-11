# =============================================================================
# Michigan Cyclosporiasis Outbreak (2026) - County-level weekly case counts
# Source: MDHHS "Infectious Disease Outbreaks" page (Sitecore CMS, server-rendered
#         HTML - NOT Power BI / ArcGIS / Tableau). The "Cases by county" table is
#         a plain <table> inside a collapsible accordion section on:
#   https://www.michigan.gov/mdhhs/keep-mi-healthy/infectious-diseases/infectious-disease-outbreaks
#
# Notes:
#   - The similarly-named "Cyclosporiasis Outbreak" landing page (.../cyclosporiasis-outbreak)
#     does NOT contain the data table - it is prose/recommendations only. The table lives on
#     the sibling "Infectious Disease Outbreaks" page. Do not confuse the two URLs.
#   - MDHHS states cases-by-county are updated weekly (Thursdays), while the statewide daily
#     total is updated more often elsewhere. The county table therefore gives one
#     CUMULATIVE-SINCE-OUTBREAK-START snapshot per week, not a per-week incident count.
#   - This ingest script accumulates one snapshot per distinct "Last Update" date into a
#     persistent raw file (raw/mi_cyclo_county_snapshots.csv) on every run where the
#     source data has changed. Over successive scheduled runs (as MDHHS updates the table
#     each Thursday), this builds up a real weekly time series, from which both the
#     cumulative count and a derived per-week incident (new-case) count are produced.
#   - "Detroit City" is reported by MDHHS as its own jurisdiction (Detroit has an independent
#     health department) but is geographically part of Wayne County. Its cases are summed
#     into Wayne County (FIPS 26163) since the required output geography is county-level FIPS.
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
#    browser User-Agent - no headless browser needed at runtime. chromote was
#    used only during development to locate the table; see comments above).
# -----------------------------------------------------------------------------
source_url <- "https://www.michigan.gov/mdhhs/keep-mi-healthy/infectious-diseases/infectious-disease-outbreaks"

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
  stop("Failed to fetch MDHHS Infectious Disease Outbreaks page: HTTP ", httr::status_code(resp))
}

html_txt <- httr::content(resp, as = "text", encoding = "UTF-8")
page <- rvest::read_html(html_txt)

# -----------------------------------------------------------------------------
# 2. Locate the "Cases by county" table and its "Last Update" date.
#    The page has (at least) two similarly-shaped tables ("Cases by county" and
#    "Cases by age group") - identify the right one by its header row text
#    rather than assuming table order, since Sitecore component order can change.
# -----------------------------------------------------------------------------
tbl_nodes <- rvest::html_elements(page, "table")
if (length(tbl_nodes) == 0) {
  stop("No <table> elements found on the MDHHS Infectious Disease Outbreaks page - ",
       "page structure may have changed.")
}

county_tbl_idx <- NULL
for (i in seq_along(tbl_nodes)) {
  header_txt <- tolower(rvest::html_text2(tbl_nodes[[i]]))
  if (grepl("county/jurisdiction", header_txt, fixed = TRUE) &&
      grepl("cyclosporiasis cases reported", header_txt, fixed = TRUE)) {
    county_tbl_idx <- i
    break
  }
}

if (is.null(county_tbl_idx)) {
  stop("Could not find the 'Cases by county' cyclosporiasis table on the page - ",
       "source page structure may have changed.")
}

county_node <- tbl_nodes[[county_tbl_idx]]
county_raw <- rvest::html_table(county_node, header = FALSE, fill = TRUE)

# First row holds the (non-<th>) header cells; drop it and name columns
county_raw <- county_raw[-1, ]
names(county_raw) <- c("county_raw", "cases_cumulative")

# Extract the "Last Update: <Month DD, YYYY>" text that immediately follows the table
update_node <- rvest::html_element(
  county_node,
  xpath = "following-sibling::p[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'last update')][1]"
)
if (is.na(update_node)) {
  stop("Could not find the 'Last Update' date next to the county table - ",
       "source page structure may have changed.")
}
update_txt <- rvest::html_text2(update_node)
last_update_date <- as.Date(sub(".*[Ll]ast [Uu]pdate:?\\s*", "", update_txt), format = "%B %d, %Y")
if (is.na(last_update_date)) {
  stop("Could not parse the 'Last Update' date from text: ", update_txt)
}

# -----------------------------------------------------------------------------
# 3. Clean the scraped rows and build the candidate raw_state used for
#    dcf change-detection (no browser/hash package needed - just compare the
#    extracted content directly).
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
# re-running mid-week before the next Thursday update overwrites the same file).
raw_html_path <- file.path("raw", paste0("infectious_disease_outbreaks_", last_update_date, ".html"))
writeLines(html_txt, raw_html_path)

# -----------------------------------------------------------------------------
# 4. Only reprocess if the source data actually changed since the last run.
# -----------------------------------------------------------------------------
if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 4a. Append this week's snapshot to the persistent long-format history file.
  #     This is what allows a real weekly *time series* to accumulate across
  #     successive scheduled runs, since the source page itself only ever shows
  #     the current cumulative snapshot (no historical table).
  # ---------------------------------------------------------------------------
  snapshot_path <- file.path("raw", "mi_cyclo_county_snapshots.csv")

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
  # 4b. FIPS lookup (county-level), per project convention
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE, altrep = FALSE)

  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5, state == "MI") %>%
    select(geography, geography_name) %>%
    mutate(
      county_name_key = tolower(gsub("[[:punct:]]", "", sub(" County$", "", geography_name)))
    )

  # ---------------------------------------------------------------------------
  # 4c. Map scraped county/jurisdiction names onto county FIPS codes.
  #     "Detroit City" is its own MDHHS reporting jurisdiction (independent
  #     health department) but sits entirely inside Wayne County geographically,
  #     so it is remapped to "Wayne" before joining and summed with Wayne's own
  #     count for that date.
  # ---------------------------------------------------------------------------
  history_mapped <- history %>%
    mutate(
      county_join_name = if_else(
        tolower(trimws(county_raw)) == "detroit city",
        "Wayne",
        county_raw
      ),
      county_name_key = tolower(gsub("[[:punct:]]", "", trimws(county_join_name)))
    ) %>%
    left_join(county_fips_lookup, by = "county_name_key")

  unmatched <- history_mapped %>% filter(is.na(geography)) %>% distinct(county_raw)
  if (nrow(unmatched) > 0) {
    warning(
      "mi_cyclo: the following scraped county/jurisdiction names did not match ",
      "any Michigan county FIPS code and were dropped: ",
      paste(unmatched$county_raw, collapse = ", ")
    )
  }

  # ---------------------------------------------------------------------------
  # 4d. Aggregate to county FIPS x date (sums Detroit City into Wayne County),
  #     convert date to the Saturday ending that reporting week (project convention),
  #     and derive a per-week incident ("new cases") column by differencing the
  #     cumulative count across the accumulated weekly snapshots for each county.
  # ---------------------------------------------------------------------------
  to_epiweek_saturday <- function(d) {
    d <- as.Date(d)
    wday <- as.integer(format(d, "%w")) # 0 = Sunday ... 6 = Saturday
    d + (6 - wday) %% 7
  }

  data_standard <- history_mapped %>%
    filter(!is.na(geography)) %>%
    group_by(geography, last_update_date) %>%
    summarize(mi_cyclo_cases_cumulative = sum(cases_cumulative), .groups = "drop") %>%
    mutate(time = format(to_epiweek_saturday(last_update_date), "%Y-%m-%d")) %>%
    arrange(geography, last_update_date) %>%
    group_by(geography) %>%
    mutate(
      mi_cyclo_cases_new = mi_cyclo_cases_cumulative - dplyr::lag(mi_cyclo_cases_cumulative)
    ) %>%
    ungroup() %>%
    select(geography, time, mi_cyclo_cases_cumulative, mi_cyclo_cases_new)

  # ---------------------------------------------------------------------------
  # 5. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 6. Record processed state
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
