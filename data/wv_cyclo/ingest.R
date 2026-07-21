# =============================================================================
# West Virginia Cyclosporiasis Outbreak (2026) - County-level case counts
# Source: WV Office of Epidemiology and Prevention Services (OEPS) outbreak page:
#   https://oeps.wv.gov/cyclosporiasis-outbreak
#
# Notes:
#   - Unlike FL/MI/OH, this page has NO structured data source at all - no
#     Tableau/Power BI/ArcGIS embed, no HTML <table>, no CSV/JSON download. The
#     "Cases by County" breakdown and the daily epi curve exist ONLY as text
#     baked into a single static PNG image ("Dashboard 2.png", re-uploaded to a
#     dated /sites/default/files/YYYY-mm/ path each time OEPS updates it).
#   - This ingest script therefore only extracts the "Cases by County" panel
#     (a clean, high-contrast two-column text table on the right side of the
#     image) via OCR (magick::image_crop() + tesseract::ocr()). It deliberately
#     does NOT attempt to digitize the epi curve bar chart on the left side of
#     the image - bar-height extraction from a raster image is far less
#     reliable than OCR of printed table text, and the county breakdown is the
#     data of interest for this project.
#   - The crop region is a HARDCODED fraction of the downloaded image's
#     width/height (see CROP_* constants below), calibrated against the image
#     as of 2026-07-17. If OEPS changes the dashboard image's layout/template,
#     this crop box (and/or the OCR line regex below) will need to be
#     recalibrated - if `ingest.R` starts warning about unmatched counties or
#     producing an empty result, check the image manually before assuming a
#     transient scraping bug.
#   - OEPS states the dashboard is updated "Tuesdays and Fridays" - there is no
#     fixed weekly cadence to align to (unlike MI's Thursday-only updates), so
#     `time` here is simply the "Last updated" date printed on the page.
#   - Like mi_cyclo, the source only ever shows the single latest CUMULATIVE
#     snapshot (no historical archive), so this script accumulates one dated
#     snapshot per run into a persistent raw file
#     (raw/wv_cyclo_county_snapshots.csv), building a real time series across
#     successive scheduled runs, and derives a `wv_cyclo_cases_new` incident
#     column by differencing successive cumulative snapshots per county.
# =============================================================================

library(dplyr)
library(rvest)
library(httr)
library(vroom)
library(magick)
library(tesseract)

if (!dir.exists("raw")) dir.create("raw")
if (!dir.exists("standard")) dir.create("standard")

if (!file.exists("process.json")) {
  process <- list(raw_state = NULL)
} else {
  process <- dcf::dcf_process_record()
}

# -----------------------------------------------------------------------------
# 1. Download the outbreak page and locate the "Last updated" date, the
#    "Total Cases" figure (used only as an independent sanity check on the
#    OCR'd county sum), and the dashboard image URL.
# -----------------------------------------------------------------------------
source_url <- "https://oeps.wv.gov/cyclosporiasis-outbreak"

page_resp <- httr::RETRY(
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

if (httr::status_code(page_resp) != 200) {
  stop("Failed to fetch WV OEPS cyclosporiasis outbreak page: HTTP ", httr::status_code(page_resp))
}

html_txt <- httr::content(page_resp, as = "text", encoding = "UTF-8")
page <- rvest::read_html(html_txt)

p_texts <- rvest::html_text2(rvest::html_elements(page, "p"))

update_txt <- p_texts[grepl("^last updated:?", p_texts, ignore.case = TRUE)][1]
if (is.na(update_txt) || length(update_txt) == 0) {
  stop("Could not find a 'Last updated:' line on the WV OEPS outbreak page - ",
       "page structure may have changed.")
}
last_update_date <- as.Date(sub("^[Ll]ast [Uu]pdated:?\\s*", "", update_txt), format = "%B %d, %Y")
if (is.na(last_update_date)) {
  stop("Could not parse the 'Last updated' date from text: ", update_txt)
}

total_txt <- p_texts[grepl("^total cases:?", p_texts, ignore.case = TRUE)][1]
total_cases_reported <- if (!is.na(total_txt) && length(total_txt) > 0) {
  suppressWarnings(as.integer(gsub("[^0-9]", "", total_txt)))
} else {
  NA_integer_
}

img_node <- rvest::html_element(page, "img[alt*='County Case Counts']")
if (is.na(img_node)) {
  # Fall back to any image under the site's file directory whose filename mentions "Dashboard"
  img_node <- rvest::html_element(page, "img[src*='Dashboard']")
}
if (is.na(img_node)) {
  stop("Could not find the dashboard image on the WV OEPS outbreak page - ",
       "page structure may have changed.")
}
img_url <- xml2::url_absolute(rvest::html_attr(img_node, "src"), source_url)

# -----------------------------------------------------------------------------
# 2. Download the dashboard image and save a dated raw snapshot for audit trail
#    (one per distinct update date; re-running before the next Tue/Fri update
#    overwrites the same file).
# -----------------------------------------------------------------------------
img_path <- file.path("raw", paste0("wv_cyclo_dashboard_", last_update_date, ".png"))
img_resp <- httr::RETRY(
  "GET", img_url,
  httr::write_disk(img_path, overwrite = TRUE),
  httr::add_headers(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
  times = 3, pause_min = 5
)
if (httr::status_code(img_resp) != 200) {
  stop("Failed to download WV dashboard image (", img_url, "): HTTP ", httr::status_code(img_resp))
}

# -----------------------------------------------------------------------------
# 3. Crop the "Cases by County" panel (right-hand sidebar of the image) and
#    OCR it. Crop box is expressed as fractions of the actual downloaded
#    image's dimensions, so it is robust to OEPS changing the export
#    resolution but NOT to OEPS changing the panel's relative position/size.
# -----------------------------------------------------------------------------
CROP_X_FRAC <- 0.865  # left edge of the county panel (kept tight - see below)
CROP_Y_FRAC <- 0.08   # top edge, just below the panel header
CROP_W_FRAC <- 0.135  # panel width
CROP_H_FRAC <- 0.88   # panel height (generous, to tolerate more county rows over time)
# CROP_X_FRAC is calibrated to sit just inside the panel's left border. A
# wider box (tried during development at 0.83) bled in a sliver of the epi
# curve chart's rotated x-axis date labels from the left, which only overlap
# the last few table rows (rotated labels widen going down) - OCR then
# prefixed those rows with garbage characters and silently failed to parse
# them, undercounting the total. If future warnings about a total-cases
# mismatch reappear, re-check this boundary first via the cropped image
# before assuming a different cause.

img <- magick::image_read(img_path)
img_info <- magick::image_info(img)
w <- img_info$width[1]
h <- img_info$height[1]

crop_geometry <- sprintf(
  "%dx%d+%d+%d",
  round(CROP_W_FRAC * w), round(CROP_H_FRAC * h),
  round(CROP_X_FRAC * w), round(CROP_Y_FRAC * h)
)

county_panel <- img %>%
  magick::image_crop(crop_geometry) %>%
  magick::image_resize("300%") %>%
  magick::image_convert(colorspace = "gray")

ocr_txt <- tesseract::ocr(county_panel)

# -----------------------------------------------------------------------------
# 4. Parse the OCR'd text into county/count pairs. Every WV county name in
#    this table is a single word, so a simple "<word> ... <digits>" line
#    pattern is sufficient; lines that don't match (e.g. a stray "Cases by
#    County" header caught at the crop edge, or OCR noise) are dropped.
# -----------------------------------------------------------------------------
ocr_lines <- trimws(strsplit(ocr_txt, "\n")[[1]])
ocr_lines <- ocr_lines[ocr_lines != ""]

parsed <- lapply(ocr_lines, function(l) {
  m <- regmatches(l, regexec("^([A-Za-z]+)[^0-9]*([0-9]{1,4})\\s*$", l))[[1]]
  if (length(m) == 3) {
    data.frame(county_raw = m[2], cases_cumulative = as.integer(m[3]), stringsAsFactors = FALSE)
  } else {
    NULL
  }
})
county_clean <- dplyr::bind_rows(parsed)

if (nrow(county_clean) == 0) {
  stop("OCR of the WV county panel (", img_path, ") produced no parseable county/count rows - ",
       "the crop box or OCR quality may need recalibration.")
}

if (!is.na(total_cases_reported) && sum(county_clean$cases_cumulative) != total_cases_reported) {
  warning(
    "wv_cyclo: OCR'd county cases sum to ", sum(county_clean$cases_cumulative),
    " but the page's printed 'Total Cases' is ", total_cases_reported,
    " - OCR misread is likely; review ", img_path, " manually."
  )
}

# -----------------------------------------------------------------------------
# 5. Build the raw_state fingerprint and only reprocess if it changed since
#    the last run.
# -----------------------------------------------------------------------------
county_clean <- county_clean %>% arrange(county_raw)
raw_state <- list(
  last_update_date = as.character(last_update_date),
  county_data = paste(county_clean$county_raw, county_clean$cases_cumulative, sep = ":", collapse = "|")
)

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 5a. Append this snapshot to the persistent long-format history file. This
  #     is what allows a real time series to accumulate across successive
  #     scheduled runs, since the source page itself only ever shows the
  #     current cumulative snapshot (no historical table).
  # ---------------------------------------------------------------------------
  snapshot_path <- file.path("raw", "wv_cyclo_county_snapshots.csv")

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
  # 5b. FIPS lookup (county-level), per project convention
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE, altrep = FALSE)

  county_fips_lookup <- all_fips %>%
    filter(nchar(geography) == 5, state == "WV") %>%
    select(geography, geography_name) %>%
    mutate(county_name_key = tolower(gsub("[[:punct:]]", "", sub(" County$", "", geography_name))))

  history_mapped <- history %>%
    mutate(county_name_key = tolower(gsub("[[:punct:]]", "", trimws(county_raw)))) %>%
    left_join(county_fips_lookup, by = "county_name_key")

  unmatched <- history_mapped %>% filter(is.na(geography)) %>% distinct(county_raw)
  if (nrow(unmatched) > 0) {
    warning(
      "wv_cyclo: the following OCR'd county names did not match any West Virginia ",
      "county FIPS code and were dropped: ", paste(unmatched$county_raw, collapse = ", ")
    )
  }

  # ---------------------------------------------------------------------------
  # 5c. Aggregate to county FIPS x date, add a statewide (FIPS 54) row summing
  #     the county values for that date, and derive a per-update incident
  #     ("new cases") column by differencing the cumulative count across the
  #     accumulated snapshots for each geography.
  # ---------------------------------------------------------------------------
  county_by_date <- history_mapped %>%
    filter(!is.na(geography)) %>%
    group_by(geography, last_update_date) %>%
    summarize(wv_cyclo_cases_cumulative = sum(cases_cumulative), .groups = "drop")

  state_by_date <- county_by_date %>%
    group_by(last_update_date) %>%
    summarize(wv_cyclo_cases_cumulative = sum(wv_cyclo_cases_cumulative), .groups = "drop") %>%
    mutate(geography = "54")

  data_standard <- bind_rows(county_by_date, state_by_date) %>%
    mutate(time = format(last_update_date, "%Y-%m-%d")) %>%
    arrange(geography, last_update_date) %>%
    group_by(geography) %>%
    mutate(wv_cyclo_cases_new = wv_cyclo_cases_cumulative - dplyr::lag(wv_cyclo_cases_cumulative)) %>%
    ungroup() %>%
    select(geography, time, wv_cyclo_cases_cumulative, wv_cyclo_cases_new)

  # ---------------------------------------------------------------------------
  # 6. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 7. Record processed state
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
