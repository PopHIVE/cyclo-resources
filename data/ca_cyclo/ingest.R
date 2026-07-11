# =============================================================================
# California Cyclosporiasis (CDPH) - LHJ x Quarter-YTD Ingestion
#
# Source: "Provisional Summary Report of Selected California Reportable
# Diseases" - a Quarto-rendered static report embedded via an <iframe> on:
#   https://www.cdph.ca.gov/Programs/CID/DCDC/Pages/IDBProvisionalSummaryReport.aspx
# The iframe itself points directly at the static report:
#   https://skylab.cdph.ca.gov/idbsssprovisional/SSSprovisional.html
#
# Mechanism
# ---------
# Despite living on a "skylab" (R Shiny-style) subdomain, this specific report
# is a plain, fully static HTML file (~2 MB) produced by Quarto/R Markdown -
# there is NO live Shiny server session, websocket, or JS-only rendering
# involved. Both on-page tables ("Disease by Month" and "Disease by LHJ") are
# `DT::datatable()` htmlwidgets whose ENTIRE underlying data (all ~65 diseases
# x all months/LHJs) is baked directly into the page as a
# `<script type="application/json" data-for="htmlwidget-...">{...}</script>`
# blob (the Quarto/crosstalk equivalent of a client-side-filterable table).
# A single `httr::GET()` of the static HTML with a normal User-Agent returns
# everything needed - no headless browser is required at runtime.
#
# There are two such JSON blobs on the page:
#   1. "Disease by Month" - statewide only, columns = Disease/YTD/Jan/Feb/Mar.
#   2. "Disease by LHJ"   - columns = Disease + one column per California
#      Local Health Jurisdiction (58 counties, with Alpine+Sierra combined
#      into a single "Alpine/Sierra" column, plus 3 independent city health
#      departments: Berkeley, Long Beach, Pasadena). THIS is the one used
#      here. Values are the cumulative Year-to-Date (Jan 1 - end of the
#      report's covered period) case count for that disease/LHJ.
# The two widgets are told apart programmatically by column count (the LHJ
# table has ~60 data columns vs. ~4 for the month table), not by fragile
# text-matching, since Quarto's auto-generated `htmlwidget-<hash>` ids are not
# stable across re-renders.
#
# IMPORTANT LIMITATION (see README.md): this source does NOT provide a true
# county x month cross-tab. The LHJ breakdown is YTD-cumulative-since-
# January-1 only (no within-quarter month split by county); the month split
# is statewide-only (no county breakdown). CDPH updates/re-publishes this
# report roughly quarterly (per its own history: Jan-Mar, then presumably
# Jan-Jun, Jan-Sep, and a Dec year-end release). Like MDHHS's Michigan outbreak
# page, the live report only ever shows the SINGLE latest YTD snapshot with no
# historical archive at this URL, so - exactly as mi_cyclo does for its weekly
# MDHHS snapshot - this script accumulates one dated snapshot per distinct
# report release into a persistent raw history file
# (raw/ca_cyclo_lhj_snapshots.csv), building a real quarter-over-quarter time
# series across successive scheduled runs.
#
# Suppression: CDPH masks small counts as "SC" ("Suppressed Count") per DHCS
# de-identification guidelines. These are recorded as NA with
# suppressed_flag = 1 (not imputed to 0 or dropped).
# =============================================================================

library(dplyr)
library(httr)
library(rvest)
library(jsonlite)
library(vroom)

if (!dir.exists("raw")) dir.create("raw")
if (!dir.exists("standard")) dir.create("standard")

if (!file.exists("process.json")) {
  process <- list(raw_state = NULL)
} else {
  process <- dcf::dcf_process_record()
}

# -----------------------------------------------------------------------------
# 1. Download the static Quarto report (the CDPH landing page just wraps this
#    URL in an <iframe>; fetching it directly avoids the SharePoint wrapper).
# -----------------------------------------------------------------------------
source_url <- "https://skylab.cdph.ca.gov/idbsssprovisional/SSSprovisional.html"

resp <- httr::RETRY(
  "GET",
  source_url,
  httr::add_headers(
    `User-Agent` = paste(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
  ),
  times = 3,
  pause_min = 5
)

if (httr::status_code(resp) != 200) {
  stop("Failed to fetch CDPH IDB Provisional Summary Report: HTTP ", httr::status_code(resp))
}

html_txt <- httr::content(resp, as = "text", encoding = "UTF-8")
page <- rvest::read_html(html_txt)

# -----------------------------------------------------------------------------
# 2. Extract the report period ("January - March 2026"), the "as of" data
#    cutoff date, and the "Report Last Updated" render date - all three are
#    used together for change detection and for labeling the snapshot.
# -----------------------------------------------------------------------------
page_text <- rvest::html_text2(page)

period_match <- regmatches(
  page_text,
  regexpr("(January|February|March|April|May|June|July|August|September|October|November|December)\\s*-\\s*(January|February|March|April|May|June|July|August|September|October|November|December)\\s+[0-9]{4}\\s*\\(As of [^)]+\\)", page_text)
)
if (length(period_match) == 0 || !nzchar(period_match)) {
  stop("Could not find the report period / 'As of' heading - source page structure may have changed.")
}

period_label <- trimws(sub("\\(As of.*", "", period_match))
period_year <- as.integer(sub(".*?([0-9]{4})\\s*$", "\\1", period_label))
period_end_month_name <- sub("^[A-Za-z]+\\s*-\\s*([A-Za-z]+).*", "\\1", period_label)
as_of_txt <- sub(".*As of ([^)]+)\\).*", "\\1", period_match)
as_of_date <- as.Date(as_of_txt, format = "%B %d, %Y")

month_num <- match(period_end_month_name, month.name)
period_end_date <- as.Date(sprintf("%d-%02d-01", period_year, month_num))
period_end_date <- seq(period_end_date, by = "month", length.out = 2)[2] - 1  # last day of that month

updated_match <- regmatches(
  page_text,
  regexpr("Report Last Updated:\\s*[A-Za-z]+ [0-9]{1,2}, [0-9]{4}", page_text)
)
report_last_updated <- if (length(updated_match) > 0 && nzchar(updated_match)) {
  sub("Report Last Updated:\\s*", "", updated_match)
} else {
  NA_character_
}

# -----------------------------------------------------------------------------
# 3. Locate the two DT::datatable() JSON blobs and pick the "Disease by LHJ"
#    one (identified by having many more data columns than the "Disease by
#    Month" widget, rather than by brittle id/text matching).
# -----------------------------------------------------------------------------
json_nodes <- rvest::html_elements(page, "script[type='application/json']")
if (length(json_nodes) == 0) {
  stop("No htmlwidget JSON data blobs found on the page - source structure may have changed.")
}

widgets <- lapply(json_nodes, function(n) {
  txt <- rvest::html_text(n)
  tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
})
widgets <- Filter(function(w) !is.null(w) && !is.null(w$x) && !is.null(w$x$data), widgets)
if (length(widgets) == 0) {
  stop("Found JSON script blocks but none parsed as DT::datatable widgets - source structure may have changed.")
}

n_cols <- vapply(widgets, function(w) length(w$x$data), integer(1))
lhj_widget <- widgets[[which.max(n_cols)]]
if (max(n_cols) < 20) {
  stop("The widest htmlwidget table only has ", max(n_cols), " columns - ",
       "expected the 'Disease by LHJ' table (~60 columns). Source structure may have changed.")
}

# -----------------------------------------------------------------------------
# 4. Parse out disease names (first data column) and one named vector per LHJ
#    column, using options$columnDefs for column names/order (robust to the
#    data list not being named directly).
# -----------------------------------------------------------------------------
col_defs <- lhj_widget$x$options$columnDefs
col_names <- vapply(col_defs, function(cd) if (!is.null(cd$name)) cd$name else NA_character_, character(1))
col_targets <- vapply(col_defs, function(cd) if (!is.null(cd$targets)) cd$targets[[1]] else NA_integer_, numeric(1))
# Some columnDefs entries (e.g. the shared-width styling one) have no "name" - drop those
has_name <- !is.na(col_names)
col_names <- col_names[has_name]
col_targets <- col_targets[has_name]

disease_col_idx <- col_targets[col_names == "Disease"] + 1L  # 0-based -> 1-based
if (length(disease_col_idx) != 1) {
  stop("Could not uniquely identify the 'Disease' column in the LHJ table - source structure may have changed.")
}

diseases <- vapply(lhj_widget$x$data[[disease_col_idx]], as.character, character(1))
cyclo_row <- which(diseases == "Cyclosporiasis")
if (length(cyclo_row) != 1) {
  stop("Could not find exactly one 'Cyclosporiasis' row in the LHJ table (found ", length(cyclo_row), ").")
}

lhj_names <- col_names[col_names != "Disease"]
lhj_targets <- col_targets[col_names != "Disease"]

raw_lhj <- data.frame(
  lhj = lhj_names,
  value_raw = vapply(lhj_targets, function(tg) {
    col_idx <- tg + 1L
    as.character(lhj_widget$x$data[[col_idx]][[cyclo_row]])
  }, character(1)),
  stringsAsFactors = FALSE
)

raw_lhj <- raw_lhj %>%
  mutate(
    value_trim = trimws(value_raw),
    suppressed = value_trim == "SC",
    cases = suppressWarnings(ifelse(suppressed, NA_integer_, as.integer(gsub(",", "", value_trim))))
  )

# -----------------------------------------------------------------------------
# 5. Build the candidate raw_state used for dcf change-detection, and save a
#    dated raw snapshot of just the Cyclosporiasis LHJ row (not the whole
#    2 MB page) for the audit trail.
# -----------------------------------------------------------------------------
raw_state <- list(
  period = period_match,
  report_last_updated = report_last_updated,
  lhj_data = paste(raw_lhj$lhj, raw_lhj$value_trim, sep = ":", collapse = "|")
)

snapshot_id <- paste0(period_end_date, "_updated-", report_last_updated)
raw_snapshot_path <- file.path("raw", paste0("ca_cyclo_cyclosporiasis_lhj_", period_end_date, ".csv"))
vroom::vroom_write(raw_lhj, raw_snapshot_path, delim = ",")

# -----------------------------------------------------------------------------
# 6. Only reprocess if the source data actually changed since the last run.
# -----------------------------------------------------------------------------
if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 6a. Append this quarter's snapshot to the persistent long-format history
  #     file. As with mi_cyclo, the source page itself only ever shows the
  #     current YTD snapshot (no historical table), so building a real
  #     multi-quarter time series requires remembering every release here.
  # ---------------------------------------------------------------------------
  history_path <- file.path("raw", "ca_cyclo_lhj_snapshots.csv")

  new_snapshot <- raw_lhj %>%
    transmute(
      period_end_date = as.character(period_end_date),
      period_year = period_year,
      lhj = lhj,
      cases_ytd = cases,
      suppressed = as.integer(suppressed)
    )

  if (file.exists(history_path)) {
    history <- vroom::vroom(history_path, show_col_types = FALSE, altrep = FALSE)
    # Drop any existing rows for this same period end date (idempotent re-run)
    history <- history %>% filter(period_end_date != !!as.character(period_end_date))
    history <- bind_rows(history, new_snapshot)
  } else {
    history <- new_snapshot
  }
  history <- history %>% arrange(lhj, period_end_date)
  vroom::vroom_write(history, history_path, delim = ",")

  # ---------------------------------------------------------------------------
  # 6b. FIPS lookup (county-level), per project convention.
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE, altrep = FALSE)

  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5, state == "CA") %>%
    select(geography, geography_name) %>%
    mutate(county_name = sub(" County$", "", geography_name))

  alpine_fips <- county_fips_lookup$geography[county_fips_lookup$county_name == "Alpine"]
  sierra_fips <- county_fips_lookup$geography[county_fips_lookup$county_name == "Sierra"]
  alameda_fips <- county_fips_lookup$geography[county_fips_lookup$county_name == "Alameda"]
  la_fips <- county_fips_lookup$geography[county_fips_lookup$county_name == "Los Angeles"]

  # ---------------------------------------------------------------------------
  # 6c. Map LHJ names onto county FIPS codes.
  #     - Independent city health departments (Berkeley, Long Beach, Pasadena)
  #       are summed into their surrounding county, mirroring mi_cyclo's
  #       Detroit-City-into-Wayne-County convention.
  #     - "Alpine/Sierra" is a single combined LHJ serving both counties (too
  #       sparsely populated to have separate health departments); since the
  #       source gives one indivisible count, the SAME value is assigned to
  #       BOTH Alpine and Sierra county rows here. This means a statewide sum
  #       across all 58 county rows will double-count this one LHJ's cases -
  #       see the caveat in README.md / measure_info.json.
  # ---------------------------------------------------------------------------
  expand_history <- function(h) {
    plain <- h %>%
      filter(!lhj %in% c("Berkeley", "Long Beach", "Pasadena", "Alpine/Sierra")) %>%
      mutate(geography = county_fips_lookup$geography[match(lhj, county_fips_lookup$county_name)])

    city_to_county <- h %>%
      filter(lhj %in% c("Berkeley", "Long Beach", "Pasadena")) %>%
      mutate(geography = case_when(
        lhj == "Berkeley" ~ alameda_fips,
        lhj %in% c("Long Beach", "Pasadena") ~ la_fips
      ))

    alpine_sierra <- h %>% filter(lhj == "Alpine/Sierra")
    alpine_sierra_dup <- bind_rows(
      alpine_sierra %>% mutate(geography = alpine_fips),
      alpine_sierra %>% mutate(geography = sierra_fips)
    )

    bind_rows(plain, city_to_county, alpine_sierra_dup) %>%
      filter(!is.na(geography))
  }

  history_mapped <- expand_history(history)

  unmatched <- history %>%
    filter(!lhj %in% c("Berkeley", "Long Beach", "Pasadena", "Alpine/Sierra")) %>%
    filter(!lhj %in% county_fips_lookup$county_name) %>%
    distinct(lhj)
  if (nrow(unmatched) > 0) {
    warning(
      "ca_cyclo: the following scraped LHJ names did not match any California ",
      "county FIPS code and were dropped: ", paste(unmatched$lhj, collapse = ", ")
    )
  }

  # ---------------------------------------------------------------------------
  # 6d. Sum city-into-county contributions (e.g. Los Angeles County + Long
  #     Beach + Pasadena), then derive a quarter-over-quarter incident count
  #     WITHIN each calendar year (YTD resets to 0 every January, so a Q1-of-
  #     next-year value must never be differenced against the prior year's
  #     Q4/year-end value). A county-quarter is left NA if either endpoint is
  #     suppressed, since a safe increment cannot be computed through
  #     suppression.
  # ---------------------------------------------------------------------------
  data_standard <- history_mapped %>%
    group_by(geography, period_end_date, period_year) %>%
    summarize(
      cases_ytd = if (any(suppressed == 1)) NA_integer_ else sum(cases_ytd, na.rm = FALSE),
      suppressed = as.integer(any(suppressed == 1)),
      .groups = "drop"
    ) %>%
    arrange(geography, period_year, period_end_date) %>%
    group_by(geography, period_year) %>%
    mutate(
      ca_cyclo_cases_new = cases_ytd - dplyr::lag(cases_ytd)
    ) %>%
    ungroup() %>%
    transmute(
      geography,
      time = period_end_date,
      ca_cyclo_cases_ytd = cases_ytd,
      ca_cyclo_cases_new,
      suppressed_flag = suppressed
    ) %>%
    arrange(geography, time)

  # ---------------------------------------------------------------------------
  # 7. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 8. Record processed state
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
