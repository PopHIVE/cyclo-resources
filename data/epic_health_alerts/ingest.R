# =============================================================================
# Epic Research Health Alerts - Cyclosporiasis
# Source: https://www.epicresearch.org/health-alerts/
#
# Notes:
#   - The page has no API/CSV export. It is a server-rendered (Next.js) HTML
#     page with one <table> per health-alert condition (Acute Pharyngitis,
#     Cyclosporiasis, Hand/Foot/Mouth Disease, Heat Illness, Toxic Effect of
#     Smoke, Viral Gastroenteritis), all present in the same page load behind
#     a condition filter UI - no separate per-condition URL or AJAX endpoint.
#     This script downloads the full page and extracts only the Cyclosporiasis
#     table by matching its <h3> heading text.
#   - The page shows only CURRENTLY ACTIVE alerts (a live snapshot), not a
#     historical archive - rows disappear once an alert is no longer active.
#     To build a real time series, this script appends one observation per
#     ingest run directly into standard/data.csv.gz (keyed on geography + the
#     as-of scrape date), rather than overwriting it.
#   - Rows are State-Wide or county-level depending on what Epic Research
#     issues; "State-Wide" rows use the 2-digit state FIPS, county rows are
#     matched to 5-digit county FIPS via resources/all_fips.csv.gz.
#   - Values marked with a trailing "*" on the source page are rates computed
#     from a partial (incomplete) reporting week; this is captured in
#     `partial_week_flag` rather than discarded.
# =============================================================================

library(dplyr)

if (!file.exists("process.json")) {
  process <- list(raw_state = NULL)
} else {
  process <- dcf::dcf_process_record()
}

# -----------------------------------------------------------------------------
# 1. Download raw data
# -----------------------------------------------------------------------------
url <- "https://www.epicresearch.org/health-alerts/"
download.file(url, "raw/health-alerts.html", mode = "wb", quiet = TRUE)
raw_state <- list(hash = unname(tools::md5sum("raw/health-alerts.html")))

# Only process if data has changed
if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE)

  state_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 2) %>%
    select(geography, geography_name)

  state_abbr_lookup <- all_fips %>%
    filter(nchar(geography) == 2) %>%
    select(state_fips = geography, state)

  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5) %>%
    select(geography, geography_name, state) %>%
    mutate(
      county_name = sub(" County$", "", geography_name),
      county_name = sub(" Parish$", "", county_name),
      county_name = sub(" Borough$", "", county_name),
      county_name = sub(" Census Area$", "", county_name),
      county_name = sub(" Municipality$", "", county_name)
    )

  # ---------------------------------------------------------------------------
  # 3. Read raw data - extract the Cyclosporiasis section/table
  # ---------------------------------------------------------------------------
  page <- xml2::read_html("raw/health-alerts.html")
  sections <- rvest::html_elements(page, "section.health-alerts-component")
  headings <- rvest::html_text2(rvest::html_element(sections, "h3"))

  cyclo_idx <- which(headings == "Cyclosporiasis")
  if (length(cyclo_idx) == 0) {
    stop("Cyclosporiasis section not found on health-alerts page; site layout may have changed.")
  }
  cyclo_table <- rvest::html_table(
    rvest::html_element(sections[[cyclo_idx[1]]], "table"),
    fill = TRUE
  )

  # The page's own "Last updated: <Month DD, YYYY>" banner - a single,
  # page-wide value (applies to every condition, not just Cyclosporiasis).
  # Captured per-row below so downstream reports can show an accurate
  # "data current through" date without hardcoding it.
  last_updated_node <- rvest::html_element(page, xpath = "//p[contains(text(), 'Last updated')]")
  page_last_updated <- format(
    as.Date(sub("Last updated:\\s*", "", rvest::html_text2(last_updated_node)), "%B %d, %Y"),
    "%Y-%m-%d"
  )

  # ---------------------------------------------------------------------------
  # 4. Transform to standard wide format
  # ---------------------------------------------------------------------------
  scrape_date <- Sys.Date()
  wday <- as.integer(format(scrape_date, "%u")) # Mon = 1 ... Sun = 7
  week_ending_saturday <- scrape_date + ((6 - wday) %% 7)

  data_new <- cyclo_table %>%
    rename(
      state_name = State,
      county_raw = County,
      estimated_onset = `Estimated Onset`,
      rate_raw = `Cases per 100k (Latest Week)`
    ) %>%
    mutate(
      partial_week_flag = as.integer(grepl("\\*", rate_raw)),
      epicalert_cyclosporiasis_cases_per_100k = as.numeric(gsub("[^0-9.]", "", rate_raw)),
      estimated_onset = format(as.Date(estimated_onset, "%m/%d/%Y"), "%Y-%m-%d"),
      county_clean = trimws(gsub("^\\(|\\)$", "", county_raw)),
      is_statewide = county_clean == "State-Wide"
    ) %>%
    left_join(state_fips_lookup, by = c("state_name" = "geography_name")) %>%
    rename(state_geo = geography) %>%
    left_join(state_abbr_lookup, by = c("state_geo" = "state_fips")) %>%
    left_join(county_fips_lookup, by = c("state" = "state", "county_clean" = "county_name")) %>%
    mutate(
      geography = if_else(is_statewide, state_geo, geography),
      time = format(week_ending_saturday, "%Y-%m-%d"),
      page_last_updated = page_last_updated
    ) %>%
    select(
      geography, time,
      estimated_onset, partial_week_flag, epicalert_cyclosporiasis_cases_per_100k,
      page_last_updated
    )

  if (any(is.na(data_new$geography))) {
    warning(
      "Some rows could not be matched to a FIPS geography: ",
      paste(cyclo_table$State[is.na(data_new$geography)], cyclo_table$County[is.na(data_new$geography)], collapse = "; ")
    )
  }

  # ---------------------------------------------------------------------------
  # 5. Append to standardized output (accumulate weekly snapshots over time,
  #    since the source page only ever shows the current active alerts)
  # ---------------------------------------------------------------------------
  out_file <- "standard/data.csv.gz"
  if (file.exists(out_file)) {
    # Force geography to stay character (leading zeros in state/county FIPS,
    # e.g. "01" for Alabama or "00" for national, would otherwise be silently
    # dropped by vroom's automatic type-guessing on re-read), and force the
    # date columns to character to match the format() output used for `time`
    # and `estimated_onset` above (both are plain ISO date strings, not
    # parsed Date objects, so bind_rows() below needs matching types).
    data_prior <- vroom::vroom(
      out_file,
      col_types = vroom::cols(
        geography = vroom::col_character(),
        time = vroom::col_character(),
        estimated_onset = vroom::col_character(),
        page_last_updated = vroom::col_character(),
        .default = vroom::col_guess()
      )
    )
    data_standard <- bind_rows(data_new, data_prior) %>%
      distinct(geography, time, .keep_all = TRUE) %>%
      arrange(geography, time)
  } else {
    data_standard <- data_new
  }

  vroom::vroom_write(data_standard, out_file, delim = ",")

  # ---------------------------------------------------------------------------
  # 6. Record processed state
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
