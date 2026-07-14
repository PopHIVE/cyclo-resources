# =============================================================================
# Oregon Cyclosporiasis (OHA) - Statewide + County Monthly Ingestion
#
# Source: OHA "Monthly CD Surveillance Report" - a Tableau PUBLIC dashboard
# (workbook "MonthlyReportDashboard_EXTERNAL_AGGREGATED", view
# "MonthlyReportDashboard"):
#   https://public.tableau.com/views/MonthlyReportDashboard_EXTERNAL_AGGREGATED/MonthlyReportDashboard
# linked from:
#   https://www.oregon.gov/oha/ph/diseasesconditions/communicabledisease/diseasesurveillancedata/weekly-monthlystatistics/pages/index.aspx
#
# The published viz has several TABS (dashboards within the same workbook):
# Statewide, by Age Group, by Sex, by Race/Ethnicity, by County, About. Each
# tab is its own Tableau "dashboard" sheet, only lazily loaded when navigated
# to (see the goToSheet step below) - a first-pass ingest that only decoded
# the default/active "Statewide" tab (as this script originally did) would
# miss the county breakdown entirely.
#
# This script pulls BOTH:
#   - or_cyclo_cases: exact statewide monthly counts, from the "Statewide"
#     tab's "Statewide Monthly" worksheet (full 2021-present history, never
#     observed to be suppressed even at a value of 1).
#   - or_cyclo_cases_county: county-level monthly counts, from the "by
#     County" tab's "by County Count Table" worksheet. IMPORTANT: OHA masks
#     any county-month cell with fewer than six cases as "<6" - and because
#     Oregon's statewide Cyclosporiasis total is itself usually in the
#     single digits per month, this means county-level counts are suppressed
#     for the overwhelming majority of county-months (all but one, out of
#     333 checked during development, were masked). This is expected/real,
#     not a scraping bug - see suppressed_flag.
#
# Mechanism
# ---------
# Tableau PUBLIC's 2024+ front end (the default public.tableau.com/app/...
# profile URL) sits behind AWS WAF bot detection and cannot be fetched
# headlessly. BUT the classic "/views/<workbook>/<view>?:embed=y&:showVizHome=no"
# URL bypasses that gate entirely and drives the same classic vizql session
# protocol used by Tableau Server (see oh_cyclo's ingest.R for that side of
# the family) - no headless browser is required at runtime, just plain HTTP:
#   1. GET  .../views/<workbook>/<view>?:embed=y&:showVizHome=no   (cookies)
#   2. POST .../vizql/w/<workbook>/v/<view>/startSession/viewing   (session info)
#   3. POST .../vizql/w/<workbook>/v/<view>/bootstrapSession/sessions/<id>
#            (returns two size-prefixed JSON blobs: "info" and "data", for
#            the default/active "Statewide" tab only)
#   4. POST .../sessions/<id>/commands/tabdoc/categorical-filter-by-index
#            to select "Cyclosporiasis" in the "Disease Name" quick filter
#            (the worksheet defaults to Campylobacteriosis)
#   5. POST .../sessions/<id>/commands/tabdoc/goto-sheet with the "County
#            Table Dashboard" tab's windowId (read from step 3's sheet list)
#            to lazily load the "by County" tab's data. The Disease Name
#            filter selection persists automatically across this tab switch.
#   6. POST another categorical-filter-by-index on that tab's "Mmwr Year"
#            quick filter, selecting ALL years (it defaults to the current
#            year only), to pull full history.
#
# THE KEY TRICK that makes steps 3-6 return real data instead of an HTTP 410
# (this is what a naive plain-HTTP replay misses): Tableau Public's backend
# is horizontally scaled behind a load-balancer that pins a session to one
# node. The startSession response includes a `global-session-header`
# RESPONSE header - an opaque affinity token - that MUST be echoed back as a
# REQUEST header on every subsequent call, or the request lands on a
# different node than the one holding the in-memory session and 410s. This
# is undocumented and was found by diffing a real browser's network requests
# against a plain-HTTP replay; it does not appear in the (Tableau
# Server-oriented) `tableauscraper` Python reference implementation this
# decode logic was otherwise modeled on.
#
# A SECOND requirement, easy to miss because it fails silently rather than
# with an HTTP error: every categorical-filter-by-index call must include a
# `visualIdPresModel` multipart field - a small JSON object
# `{"worksheet": <name>, "dashboard": <name-of-the-tab-currently-hosting-it>}`
# identifying which worksheet/tab the filter applies to (this is what
# `tableauscraper`'s api.py `filter()` calls `visualIdPresModel`, built from
# the caller-supplied worksheet/dashboard names - NOT auto-derived from the
# session). Omit it and the server returns HTTP 200 with a *rejected*
# `commandValidationPresModel` ("missing: visual-id-pres-model") while
# leaving the worksheet's existing (default) filter state untouched - e.g.
# the Disease Name quick filter silently stays on its default
# Campylobacteriosis instead of switching to Cyclosporiasis, with no error
# surfaced anywhere else. `apply_categorical_filter()` below both sends this
# field and checks commandValidationPresModel$valid so this fails loudly if
# it ever regresses.
#
# Tableau's wire format is a shared column dictionary ("dataSegments") plus
# integer indices into it, not literal values - the small decoder functions
# below are a faithful, minimal port of the equivalent logic in
# `tableauscraper`'s utils.py, scoped to just what these two worksheets need.
# =============================================================================

library(dplyr)
library(httr)
library(jsonlite)
library(vroom)

if (!dir.exists("raw")) dir.create("raw")
if (!dir.exists("standard")) dir.create("standard")

if (!file.exists("process.json")) {
  process <- list(raw_state = NULL)
} else {
  process <- dcf::dcf_process_record()
}

WORKBOOK <- "MonthlyReportDashboard_EXTERNAL_AGGREGATED"
VIEW <- "MonthlyReportDashboard"
UA <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 dcf-or_cyclo-ingest"

# -----------------------------------------------------------------------------
# Minimal Tableau vizql data-dictionary decoder (see header comment).
# -----------------------------------------------------------------------------
build_data_full <- function(data_segments) {
  out <- list()
  for (seg in data_segments) {
    if (is.null(seg) || is.null(seg$dataColumns)) next
    for (col in seg$dataColumns) {
      dt <- col$dataType
      vals <- col$dataValues
      if (is.null(out[[dt]])) out[[dt]] <- vals else out[[dt]] <- c(out[[dt]], vals)
    }
  }
  out
}

merge_data_segments <- function(existing, new_segments) {
  for (key in names(new_segments)) {
    if (!is.null(new_segments[[key]])) existing[[key]] <- new_segments[[key]]
  }
  existing
}

on_data_value <- function(idx, values, cstring) {
  # idx is a 0-based (Tableau-native) signed index: >=0 indexes `values`
  # directly; negative indexes (by absolute value) into the shared cstring
  # dictionary instead.
  if (idx >= 0) values[[idx + 1]] else cstring[[abs(idx)]]
}

get_indices_info <- function(pane_columns_data) {
  result <- list()
  for (t in pane_columns_data$vizDataColumns) {
    fc <- t$fieldCaption
    if (is.null(fc) || !nzchar(fc)) next
    pane_indices <- t$paneIndices
    column_indices <- t$columnIndices
    for (i in seq_along(pane_indices)) {
      pane <- pane_columns_data$paneColumnsList[[pane_indices[[i]] + 1]]
      viz_col <- pane$vizPaneColumns[[column_indices[[i]] + 1]]
      result[[length(result) + 1]] <- list(
        fieldCaption = fc,
        valueIndices = viz_col$valueIndices,
        aliasIndices = viz_col$aliasIndices,
        dataType = if (!is.null(t$dataType)) t$dataType else "",
        fn = if (!is.null(t$fn)) t$fn else ""
      )
    }
  }
  result
}

decode_worksheet <- function(data_full, indices_info) {
  cstring <- if (!is.null(data_full[["cstring"]])) data_full[["cstring"]] else list()
  frame <- list()
  add_col <- function(name, values) {
    if (is.null(frame[[name]])) frame[[name]] <<- values else frame[[paste0(name, "_2")]] <<- values
  }
  for (info in indices_info) {
    dt <- info$dataType
    t <- if (!is.null(data_full[[dt]])) data_full[[dt]] else cstring
    if (length(info$valueIndices) > 0) {
      vals <- vapply(info$valueIndices, function(v) {
        val <- if (v < length(t)) on_data_value(v, t, cstring) else NA
        if (is.null(val)) NA_character_ else as.character(val)
      }, character(1))
      add_col(paste0(info$fieldCaption, "-value"), vals)
    }
    if (length(info$aliasIndices) > 0) {
      vals <- vapply(info$aliasIndices, function(v) {
        val <- if (v < length(t)) on_data_value(v, t, cstring) else NA
        if (is.null(val)) NA_character_ else as.character(val)
      }, character(1))
      add_col(paste0(info$fieldCaption, "-alias"), vals)
    }
  }
  as.data.frame(frame, stringsAsFactors = FALSE, check.names = FALSE)
}

# Find a categorical quick filter's globalFieldName + resolved value list for
# a given worksheet, by reading the (already string-resolved) `filtersJson`
# blob embedded in that worksheet's zone.
find_quick_filter <- function(zones, worksheet, caption) {
  for (z in zones) {
    if (is.null(z) || is.null(z$worksheet) || z$worksheet != worksheet) next
    fj <- z$presModelHolder$visual$filtersJson
    if (is.null(fj)) next
    parsed <- jsonlite::fromJSON(fj, simplifyVector = FALSE)
    for (tbl in parsed) {
      if (is.null(tbl$table) || is.null(tbl$table$schema) || is.null(tbl$table$tuples)) next
      for (col_idx in seq_along(tbl$table$schema)) {
        col <- tbl$table$schema[[col_idx]]
        if (!identical(col$caption, caption)) next
        values <- vapply(tbl$table$tuples, function(tup) {
          if (is.null(tup$t) || length(tup$t) == 0) return(NA_character_)
          v <- tup$t[[1]]$v
          if (is.null(v)) NA_character_ else as.character(v)
        }, character(1))
        global_field_name <- paste0("[", col$name[[1]], "].[", col$name[[2]], "]")
        return(list(globalFieldName = global_field_name, values = values))
      }
    }
  }
  NULL
}

# A workbook can have more than one zone referencing the same worksheet name
# (e.g. a quick-filter control keeps its own small vizData alongside the
# actual worksheet table's zone) - picking the FIRST match found is fragile
# if the server ever serializes zones in a different order (observed to
# vary run-to-run). Instead, return the match with the most vizDataColumns,
# which is always the real worksheet table rather than a filter widget.
find_zone_for_worksheet <- function(zones, worksheet) {
  best <- NULL
  best_ncols <- -1L
  for (z in zones) {
    if (is.null(z) || is.null(z$worksheet) || z$worksheet != worksheet ||
        is.null(z$presModelHolder$visual$vizData)) next
    ncols <- length(z$presModelHolder$visual$vizData$paneColumnsData$vizDataColumns)
    if (ncols > best_ncols) {
      best <- z
      best_ncols <- ncols
    }
  }
  best
}

# -----------------------------------------------------------------------------
# 1. Establish session + bootstrap (classic vizql embed flow). This loads the
#    default/active "Statewide" tab.
# -----------------------------------------------------------------------------
handle <- httr::handle("https://public.tableau.com")
embed_url <- paste0("https://public.tableau.com/views/", WORKBOOK, "/", VIEW)
referer <- paste0(embed_url, "?:embed=y&:showVizHome=no")

httr::GET(embed_url, handle = handle, httr::add_headers(`User-Agent` = UA),
          query = list(`:embed` = "y", `:showVizHome` = "no"))

start_url <- paste0("https://public.tableau.com/vizql/w/", WORKBOOK, "/v/", VIEW, "/startSession/viewing")
resp1 <- httr::POST(
  start_url, handle = handle,
  httr::add_headers(`User-Agent` = UA, Referer = referer, Accept = "application/json"),
  query = list(`:embed` = "y", `:showVizHome` = "no", `:redirect` = "auth")
)
if (httr::status_code(resp1) != 200) {
  stop("or_cyclo: startSession failed with HTTP ", httr::status_code(resp1))
}
tableau_data <- jsonlite::fromJSON(httr::content(resp1, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
global_session_header <- httr::headers(resp1)[["global-session-header"]]
if (is.null(global_session_header)) {
  stop("or_cyclo: no 'global-session-header' returned by startSession - Tableau Public's ",
       "session-affinity mechanism may have changed; see README.md before assuming a code bug.")
}

sheet_id <- tableau_data$sheetId
sticky <- tableau_data$stickySessionKey

bootstrap_url <- paste0("https://public.tableau.com", tableau_data$vizql_root,
                        "/bootstrapSession/sessions/", tableau_data$sessionid)
bootstrap_body <- list(
  worksheetPortSize = jsonlite::toJSON(list(w = 1000, h = 2060), auto_unbox = TRUE),
  dashboardPortSize = jsonlite::toJSON(list(w = 1000, h = 2060), auto_unbox = TRUE),
  clientDimension = jsonlite::toJSON(list(w = 1280, h = 720), auto_unbox = TRUE),
  renderMapsClientSide = "true",
  isBrowserRendering = "true",
  browserRenderingThreshold = "100",
  formatDataValueLocally = "false",
  clientNum = "",
  navType = "Nav",
  navSrc = "Top",
  devicePixelRatio = "1",
  clientRenderPixelLimit = "16000000",
  allowAutogenWorksheetPhoneLayouts = "true",
  sheet_id = sheet_id,
  showParams = jsonlite::toJSON(list(checkpoint = FALSE, refresh = FALSE, refreshUnmodified = FALSE), auto_unbox = TRUE),
  stickySessionKey = jsonlite::toJSON(sticky, auto_unbox = TRUE),
  filterTileSize = "200",
  locale = "en_US",
  language = "en",
  verboseMode = "false"
)

resp2 <- httr::POST(
  bootstrap_url, handle = handle, body = bootstrap_body, encode = "form",
  httr::add_headers(
    `User-Agent` = UA, Referer = referer, Accept = "text/javascript",
    `X-Tsi-Active-Tab` = sheet_id, `X-Xsrf-Token` = "null",
    `global-session-header` = global_session_header
  )
)
if (httr::status_code(resp2) != 200) {
  stop("or_cyclo: bootstrapSession failed with HTTP ", httr::status_code(resp2),
       " - if this is a 410, Tableau Public's session-affinity header handling ",
       "may have changed; see the ingest.R header comment before assuming a code bug.")
}
boot_txt <- httr::content(resp2, as = "text", encoding = "UTF-8")

# The response is two size-prefixed JSON blobs concatenated: "<len1>;{...}<len2>;{...}"
m <- regmatches(boot_txt, regexec("[0-9]+;(\\{.*\\})[0-9]+;(\\{.*\\})", boot_txt, perl = TRUE))[[1]]
if (length(m) != 3) {
  stop("or_cyclo: could not parse the two-part bootstrapSession JSON payload - ",
       "source response format may have changed.")
}
info <- jsonlite::fromJSON(m[2], simplifyVector = FALSE)
data <- jsonlite::fromJSON(m[3], simplifyVector = FALSE)

data_segments <- data$secondaryInfo$presModelMap$dataDictionary$presModelHolder$
  genDataDictionaryPresModel$dataSegments

# The root/default dashboard name (e.g. "Monthly Report Dashboard") - required
# below as part of every categorical-filter-by-index call's visualIdPresModel.
root_dashboard <- info$sheetName

# Generic helper for the two categorical-filter POSTs we need (Disease Name,
# then Mmwr Year on a different tab). Mutates `data_segments` in the calling
# scope via <<- since R has no easy pass-by-reference otherwise.
#
# `dashboard_name` MUST be the name of the TAB/dashboard that currently hosts
# `worksheet_name` (root_dashboard for the initially-active tab, or the tab
# name passed to goto_sheet() after navigating) - the server validates this
# and otherwise rejects the whole command with
# "missing: visual-id-pres-model" / "bad value: visual-id-pres-model" and
# silently leaves any prior filter/selection in place (e.g. the Disease Name
# quick filter defaults to Campylobacteriosis, not Cyclosporiasis).
apply_categorical_filter <- function(worksheet_name, dashboard_name, global_field_name, selection0based) {
  filter_url <- paste0("https://public.tableau.com", tableau_data$vizql_root,
                       "/sessions/", tableau_data$sessionid, "/commands/tabdoc/categorical-filter-by-index")
  filter_body <- list(
    membershipTarget = "filter",
    # NOTE: do NOT wrap selection0based in as.list() here - toJSON() already
    # serializes an atomic vector to a flat JSON array (`[0,1,2]`, correct
    # even at length 1: `[12]`) with auto_unbox = FALSE. Wrapping it in
    # as.list() first double-nests every element (`[[0],[1],[2]]` /
    # `[[12]]`), which the server accepts without any validation error but
    # resolves as "select nothing" - the categorical filter silently comes
    # back with the right column schema and zero rows.
    filterIndices = jsonlite::toJSON(selection0based, auto_unbox = FALSE),
    globalFieldName = global_field_name,
    filterUpdateType = "filter-replace",
    visualIdPresModel = jsonlite::toJSON(
      list(worksheet = worksheet_name, dashboard = dashboard_name), auto_unbox = TRUE
    )
  )
  resp <- httr::POST(
    filter_url, handle = handle, body = filter_body, encode = "multipart",
    httr::add_headers(
      `User-Agent` = UA, Referer = referer, Accept = "text/javascript",
      `X-Tsi-Active-Tab` = sheet_id, `global-session-header` = global_session_header
    )
  )
  if (httr::status_code(resp) != 200) {
    stop("or_cyclo: categorical-filter-by-index failed with HTTP ", httr::status_code(resp))
  }
  cmd <- jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  validation <- cmd$vqlCmdResponse$cmdResultList[[1]]$commandReturn$commandValidationPresModel
  if (!is.null(validation) && isFALSE(validation$valid)) {
    stop("or_cyclo: categorical-filter-by-index on worksheet '", worksheet_name, "' was rejected by ",
         "the server: ", validation$errorMessage, " - source dashboard structure may have changed.")
  }
  app_pres_model <- cmd$vqlCmdResponse$layoutStatus$applicationPresModel
  new_segments <- app_pres_model$dataDictionary$dataSegments
  if (!is.null(new_segments)) {
    data_segments <<- merge_data_segments(data_segments, new_segments)
  }
  app_pres_model
}

goto_sheet <- function(window_id) {
  goto_url <- paste0("https://public.tableau.com", tableau_data$vizql_root,
                     "/sessions/", tableau_data$sessionid, "/commands/tabdoc/goto-sheet")
  resp <- httr::POST(
    goto_url, handle = handle, body = list(windowId = window_id), encode = "multipart",
    httr::add_headers(
      `User-Agent` = UA, Referer = referer, Accept = "text/javascript",
      `X-Tsi-Active-Tab` = sheet_id, `global-session-header` = global_session_header
    )
  )
  if (httr::status_code(resp) != 200) {
    stop("or_cyclo: goto-sheet failed with HTTP ", httr::status_code(resp))
  }
  cmd <- jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  app_pres_model <- cmd$vqlCmdResponse$layoutStatus$applicationPresModel
  new_segments <- app_pres_model$dataDictionary$dataSegments
  if (!is.null(new_segments)) {
    data_segments <<- merge_data_segments(data_segments, new_segments)
  }
  app_pres_model
}

# -----------------------------------------------------------------------------
# 2. Statewide tab: select "Cyclosporiasis" in the Disease Name quick filter,
#    then decode "Statewide Monthly".
# -----------------------------------------------------------------------------
zones <- info$worldUpdate$applicationPresModel$workbookPresModel$dashboardPresModel$zones
disease_filter <- find_quick_filter(zones, "Statewide Monthly", "Disease Name")
if (is.null(disease_filter)) {
  stop("or_cyclo: could not find the 'Disease Name' quick filter on the ",
       "'Statewide Monthly' worksheet - source dashboard structure may have changed.")
}
cyclo_idx0 <- which(disease_filter$values == "Cyclosporiasis") - 1L  # 0-based for Tableau
if (length(cyclo_idx0) != 1) {
  stop("or_cyclo: expected exactly one 'Cyclosporiasis' entry in the Disease Name filter, found ",
       length(cyclo_idx0), " - source may no longer track this disease (see README.md).")
}

app_pres_model <- apply_categorical_filter("Statewide Monthly", root_dashboard,
                                            disease_filter$globalFieldName, cyclo_idx0)
data_full <- build_data_full(data_segments)

ws_zone <- find_zone_for_worksheet(
  app_pres_model$workbookPresModel$dashboardPresModel$zones, "Statewide Monthly"
)
if (is.null(ws_zone)) {
  stop("or_cyclo: could not find the filtered 'Statewide Monthly' worksheet - ",
       "source dashboard structure may have changed.")
}
statewide_raw <- decode_worksheet(data_full, get_indices_info(ws_zone$presModelHolder$visual$vizData$paneColumnsData))

needed_cols <- c("MAX(Report Period End)-alias", "SUM(Count Masked)-alias", "MONTH(Date)-value")
missing <- setdiff(needed_cols, names(statewide_raw))
if (length(missing) > 0) {
  stop("or_cyclo: expected columns missing from decoded Statewide Monthly worksheet: ",
       paste(missing, collapse = ", "), " (decoded ", nrow(statewide_raw), " rows x ",
       ncol(statewide_raw), " cols: ", paste(names(statewide_raw), collapse = ", "),
       ") - source dashboard structure may have changed.")
}

# -----------------------------------------------------------------------------
# 3. Navigate to the "by County" tab (County Table Dashboard), select ALL
#    years in its Mmwr Year quick filter (it defaults to the current year
#    only), then decode "by County Count Table". The Disease Name =
#    Cyclosporiasis selection persists automatically across this tab switch.
# -----------------------------------------------------------------------------
sheets_info <- info$worldUpdate$applicationPresModel$workbookPresModel$sheetsInfo
county_dash <- NULL
for (s in sheets_info) {
  if (!is.null(s$sheet) && s$sheet == "County Table Dashboard") {
    county_dash <- s
    break
  }
}
if (is.null(county_dash)) {
  stop("or_cyclo: could not find the 'County Table Dashboard' tab in the workbook's ",
       "sheet list - source dashboard structure may have changed (see README.md).")
}

app_pres_model_county <- goto_sheet(county_dash$windowId)

year_zones <- app_pres_model_county$workbookPresModel$dashboardPresModel$zones
year_filter <- find_quick_filter(year_zones, "by County Count Table", "Mmwr Year")
if (is.null(year_filter)) {
  stop("or_cyclo: could not find the 'Mmwr Year' quick filter on the ",
       "'by County Count Table' worksheet - source dashboard structure may have changed.")
}
all_years_idx0 <- seq_along(year_filter$values) - 1L

app_pres_model_county <- apply_categorical_filter("by County Count Table", county_dash$sheet,
                                                   year_filter$globalFieldName, all_years_idx0)
data_full <- build_data_full(data_segments)  # rebuild: data_segments grew via <<- above

county_zone <- find_zone_for_worksheet(
  app_pres_model_county$workbookPresModel$dashboardPresModel$zones, "by County Count Table"
)
if (is.null(county_zone)) {
  stop("or_cyclo: could not find the 'by County Count Table' worksheet after applying the ",
       "Mmwr Year filter - source dashboard structure may have changed.")
}
county_raw <- decode_worksheet(data_full, get_indices_info(county_zone$presModelHolder$visual$vizData$paneColumnsData))

needed_county_cols <- c("Demographic Level-alias", "ATTR(Report Period End)-alias",
                        "ATTR(Count Masked Sum_Count Label)-alias", "ATTR(Month name)-alias",
                        "ATTR(Mmwr Year)-alias")
missing_county <- setdiff(needed_county_cols, names(county_raw))
if (length(missing_county) > 0) {
  stop("or_cyclo: expected columns missing from decoded 'by County Count Table' worksheet: ",
       paste(missing_county, collapse = ", "), " (decoded ", nrow(county_raw), " rows x ",
       ncol(county_raw), " cols: ", paste(names(county_raw), collapse = ", "),
       ") - source dashboard structure may have changed.")
}

# -----------------------------------------------------------------------------
# 4. Build the raw_state used for dcf change-detection (covers both tabs),
#    and save raw snapshots.
# -----------------------------------------------------------------------------
raw_state <- list(
  statewide = paste(statewide_raw[["MAX(Report Period End)-alias"]],
                    statewide_raw[["SUM(Count Masked)-alias"]], sep = ":", collapse = "|"),
  county = paste(county_raw[["Demographic Level-alias"]], county_raw[["ATTR(Report Period End)-alias"]],
                county_raw[["ATTR(Count Masked Sum_Count Label)-alias"]], sep = ":", collapse = "|")
)

vroom::vroom_write(statewide_raw, "raw/or_cyclo_statewide_monthly.csv", delim = ",")
vroom::vroom_write(county_raw, "raw/or_cyclo_county_monthly.csv", delim = ",")

# -----------------------------------------------------------------------------
# 5. Only reprocess if the source data actually changed since the last run.
# -----------------------------------------------------------------------------
if (!identical(process$raw_state, raw_state)) {

  # --- Statewide (exact counts) ---------------------------------------------
  # `time` is derived from the dashboard's own "MONTH(Date)" field (already a
  # first-of-month date), NOT by taking the calendar month of the report
  # PERIOD END date - MMWR reporting periods are week-aligned, not
  # calendar-month-aligned, so a period ending e.g. 5/2 can still belong to
  # April; bucketing by period_end's calendar month collided two rows (e.g.
  # the true April row and the true May row) onto the same "2026-05-01"
  # month and silently duplicated it in the standardized output.
  statewide_clean <- statewide_raw %>%
    transmute(
      time = format(as.Date(substr(`MONTH(Date)-value`, 1, 10)), "%Y-%m-01"),
      count_raw = trimws(`SUM(Count Masked)-alias`)
    ) %>%
    mutate(
      suppressed_flag = as.integer(is.na(suppressWarnings(as.integer(count_raw)))),
      or_cyclo_cases = suppressWarnings(as.integer(count_raw))
    ) %>%
    filter(!is.na(time)) %>%
    arrange(time)

  full_months <- data.frame(
    time = format(seq(min(as.Date(statewide_clean$time)), max(as.Date(statewide_clean$time)), by = "month"), "%Y-%m-%d")
  )

  statewide_standard <- full_months %>%
    left_join(statewide_clean %>% select(time, or_cyclo_cases, suppressed_flag), by = "time") %>%
    mutate(
      or_cyclo_cases = ifelse(is.na(or_cyclo_cases) & is.na(suppressed_flag), 0L, or_cyclo_cases),
      suppressed_flag = ifelse(is.na(suppressed_flag), 0L, suppressed_flag),
      geography = "41"
    ) %>%
    select(geography, time, or_cyclo_cases, suppressed_flag)

  # --- County (mostly-suppressed counts) ------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE, altrep = FALSE)
  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5, state == "OR") %>%
    select(geography, geography_name)

  parse_county_count <- function(x) {
    x <- trimws(x)
    suppressWarnings(as.integer(x))
  }

  county_clean <- county_raw %>%
    transmute(
      county_name = trimws(`Demographic Level-alias`),
      period_end = as.Date(`ATTR(Report Period End)-alias`, format = "%m/%d/%Y"),
      # `time` is derived from Month name + Mmwr Year, NOT the calendar month
      # of period_end, for the same reason as the statewide worksheet (see
      # comment above statewide_clean): MMWR reporting periods are
      # week-aligned, so a period ending e.g. 5/2 can belong to April. Rows
      # where the "by County" tab's own multi-year total/rollup marks (which
      # show period_end as a literal "*" and Mmwr Year as "%many-values%")
      # are excluded here via the mmwr_year/month_num parse failing.
      mmwr_year = suppressWarnings(as.integer(trimws(`ATTR(Mmwr Year)-alias`))),
      month_num = match(trimws(`ATTR(Month name)-alias`), month.name),
      count_label = trimws(`ATTR(Count Masked Sum_Count Label)-alias`)
    ) %>%
    filter(!is.na(period_end), !is.na(mmwr_year), !is.na(month_num), county_name != "Unknown County") %>%
    mutate(
      or_cyclo_cases_county = parse_county_count(count_label),
      # "<6" (masked small count) and any other non-numeric label (e.g. a
      # rendering artifact when multiple years share a grouped label) are
      # both treated as suppressed, since the true value can't be recovered.
      county_suppressed_flag = as.integer(is.na(or_cyclo_cases_county)),
      time = sprintf("%04d-%02d-01", mmwr_year, month_num)
    ) %>%
    left_join(county_fips_lookup, by = c("county_name" = "geography_name")) %>%
    filter(!is.na(geography)) %>%
    distinct(geography, time, .keep_all = TRUE)

  unmatched_counties <- county_raw %>%
    distinct(county_name = trimws(`Demographic Level-alias`)) %>%
    filter(county_name != "Unknown County", !county_name %in% county_fips_lookup$geography_name)
  if (nrow(unmatched_counties) > 0) {
    warning("or_cyclo: the following scraped county names did not match any Oregon county ",
            "FIPS code and were dropped: ", paste(unmatched_counties$county_name, collapse = ", "))
  }

  # Zero-fill every OR county x every month in the observed county-data
  # range: absent county-months are true zeros (Tableau only omits marks
  # with literally 0 cases; a nonzero-but-small count is masked as "<6"
  # rather than omitted).
  county_full_months <- format(
    seq(min(as.Date(county_clean$time)), max(as.Date(county_clean$time)), by = "month"), "%Y-%m-%d"
  )
  county_full_grid <- expand.grid(
    geography = county_fips_lookup$geography, time = county_full_months, stringsAsFactors = FALSE
  )

  county_standard <- county_full_grid %>%
    left_join(county_clean %>% select(geography, time, or_cyclo_cases_county, county_suppressed_flag),
              by = c("geography", "time")) %>%
    mutate(
      or_cyclo_cases_county = ifelse(is.na(or_cyclo_cases_county) & is.na(county_suppressed_flag),
                                      0L, or_cyclo_cases_county),
      county_suppressed_flag = ifelse(is.na(county_suppressed_flag), 0L, county_suppressed_flag)
    ) %>%
    select(geography, time, or_cyclo_cases_county, county_suppressed_flag)

  # --- Combine: state-level rows (geography "41") and county-level rows
  #     (5-digit FIPS) coexist in one long table, each populating only the
  #     measure columns that apply at its own geographic resolution.
  data_standard <- dplyr::bind_rows(statewide_standard, county_standard) %>%
    arrange(geography, time)

  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
