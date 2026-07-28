# Validate every JSON state file before dcf touches it.
#
# dcf reads these through dcf_attempt_read_json(), which discards jsonlite's
# error and reports only "failed to read {file}". That hides the actual cause,
# so a malformed file costs a full CI round trip to diagnose. This surfaces the
# real parse error, and names conflict markers explicitly since an unresolved
# merge is how these files usually break.

library(jsonlite)

files <- c(
  "settings.json",
  list.files("data", "\\.json$", recursive = TRUE, full.names = TRUE)
)
files <- files[file.exists(files)]

failures <- character()
for (file in files) {
  lines <- readLines(file, warn = FALSE)
  markers <- grep("^(<<<<<<< |=======$|>>>>>>> )", lines)
  if (length(markers)) {
    failures <- c(failures, paste0(
      file, ": unresolved merge-conflict markers on line",
      if (length(markers) > 1) "s " else " ", paste(markers, collapse = ", ")
    ))
    next
  }
  error <- tryCatch(
    {
      read_json(file)
      NULL
    },
    error = conditionMessage
  )
  if (!is.null(error)) {
    failures <- c(failures, paste0(file, ": ", error))
  }
}

if (length(failures)) {
  cat("invalid JSON in", length(failures), "of", length(files), "state file(s):\n")
  cat(paste0("  ", failures, collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}

cat("all", length(files), "JSON state files parse cleanly\n")
