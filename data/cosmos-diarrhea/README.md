# cosmos-diarrhea

This is a dcf data source project, initialized with `dcf::dcf_add_source`.

It pulls the pre-processed Epic Cosmos diarrhea standard files from the
[epic_preprocessing](https://github.com/PopHIVE/epic_preprocessing/tree/main/data/cosmos_diarrhea)
repository (see `ingest.R`), following the same pattern as `epic_chronic` in
[PopHIVE/Ingest](https://github.com/PopHIVE/Ingest/tree/main/data/epic_chronic).

Standard outputs:

- `standard/weekly.csv.gz` — all-cause diarrhea ED encounters, weekly, by state and age
- `standard/monthly.csv.gz` — all-cause diarrhea ED encounters, monthly, by state and age
- `standard/monthly_cyclospora.csv.gz` — cyclospora lab testing, monthly, by state

You can use the `dcf` package to check the project:

```R
dcf_check()
```

And process it:

```R
dcf_process()
```
