#
# Download
#

# add files to the `raw` directory

# =============================================================================
# BLOCKED - see README.md for full investigation notes.
#
# Oregon's weekly and monthly Communicable Disease Surveillance dashboards are
# published ONLY as Tableau Public visualizations:
#   https://public.tableau.com/views/WeeklyCommunicableDiseaseReport/ACDPWeeklyReport
#   https://public.tableau.com/views/MonthlyReportDashboard_EXTERNAL_AGGREGATED/MonthlyReportDashboard
#
# Every path on public.tableau.com (the view page itself, the classic Tableau
# Server ".csv" crosstab-export suffix, the vizql bootstrapSession endpoint,
# and guessed workbook/.twb/.twbx download endpoints) was tested directly with
# httr::GET()-equivalent requests during development and ALL returned the same
# ~1.4 KB AWS WAF ("AwsWAFScript") JS-challenge shell instead of real content -
# Tableau Public's 2024+ front end is a client-rendered SPA behind bot
# detection that requires executing JavaScript (a real or headless browser) to
# obtain a session and fetch data. No R package or plain HTTP request can
# replay this without a browser engine, which is not available in this
# pipeline's runtime (GitHub Actions r-lib/setup-r, no headless Chrome/
# Playwright/Selenium currently installed).
#
# This is a materially different situation from oh_cyclo, whose Tableau
# SERVER (not Public) instance has no such bot-gate and supports a direct,
# unauthenticated ".csv" crosstab export.
#
# DO NOT attempt to "fix" this with a plain httr::GET/POST - it has been
# tried and reproducibly fails. A working ingest here requires ONE of:
#   1. Adding a headless-browser step to the GitHub Actions workflow (e.g.
#      chromote + a system Chrome install) to drive the Tableau Public page,
#      capture its vizql session, and call the internal viewData/crosstab
#      endpoint the way mi_cyclo/oh_cyclo's authors did during development
#      (see their ingest.R header comments for the general technique).
#   2. Finding an alternate, non-Tableau-Public publication of the same data
#      (checked during development: OHA's weekly/monthly statistics page
#      links ONLY to the two Tableau Public dashboards above - no PDF/Excel
#      alternative was found alongside them).
#   3. Periodically requesting the data directly from OHA's Acute and
#      Communicable Disease Prevention section, since no public API exists.
#
# See README.md for the full list of URLs/endpoints tried.
# =============================================================================

#
# Reformat
#

# read from the `raw` directory, and write to the `standard` directory
