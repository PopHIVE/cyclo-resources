# =============================================================================
# Cosmos Diarrhea Data Ingestion
# Source: https://github.com/PopHIVE/epic_preprocessing/tree/main/data/cosmos_diarrhea
# Pulls pre-processed standard files from the epic_preprocessing repository.
# Includes: all-cause diarrhea ED encounters (weekly & monthly, by state and
# age) and cyclospora lab testing (monthly, by state).
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# GitHub raw base URL
branch <- "main"
base_url <- paste0(
  "https://raw.githubusercontent.com/PopHIVE/epic_preprocessing/",
  branch, "/data/cosmos_diarrhea"
)

# Standard files to download, dest name -> upstream source name. Upstream
# renamed the weekly ED-encounters file to `data_weekly.csv.gz`; kept as
# `weekly.csv.gz` locally since that's what index.qmd reads.
standard_files <- c(
  weekly.csv.gz             = "data_weekly.csv.gz",
  monthly.csv.gz            = "monthly.csv.gz",
  monthly_cyclospora.csv.gz = "monthly_cyclospora.csv.gz",
  weekly_tests.csv.gz       = "weekly_tests.csv.gz"
)

# Download a URL to `dest` via a temp file, only overwriting `dest` on success
# so a failed/404 download can't clobber the standard file already committed
# to this repo.
download_safely <- function(url, dest) {
  tmp <- tempfile()
  download.file(url, tmp, mode = "wb", quiet = TRUE)
  file.copy(tmp, dest, overwrite = TRUE)
  unlink(tmp)
}

# Download each standard file and track hashes for change detection
current_hashes <- list()

for (dest_name in names(standard_files)) {
  src_name <- standard_files[[dest_name]]
  url <- paste0(base_url, "/standard/", src_name)
  dest <- file.path("standard", dest_name)

  tryCatch({
    download_safely(url, dest)
    current_hashes[[dest_name]] <- tools::md5sum(dest)
  }, error = function(e) {
    message("Warning: failed to download ", dest_name, " (keeping committed copy): ", e$message)
  })
}

# Download measure_info.json
tryCatch({
  download_safely(
    paste0(base_url, "/measure_info.json"),
    "measure_info.json"
  )
}, error = function(e) {
  message("Warning: failed to download measure_info.json: ", e$message)
})

# Update process record only if something was actually downloaded and it
# changed. The length() guard keeps the committed hashes intact when every
# download failed (e.g. before cosmos_diarrhea is merged into main), rather
# than clobbering raw_state with an empty list.
if (length(current_hashes) > 0 && !identical(process$raw_state, current_hashes)) {
  process$raw_state <- current_hashes
  dcf::dcf_process_record(updated = process)
}
