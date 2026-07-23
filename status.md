```mermaid
flowchart LR
    classDef pass stroke:#66bb6a
    classDef warn stroke:#ffa726
    classDef fail stroke:#f44336
    s0(("<strong><a href="https://www.cdph.ca.gov/Programs/CID/DCDC/Pages/IDBProvisionalSummaryReport.aspx" target="_blank" rel="noreferrer">Provisional Summary Report of Selected California Reportable Diseases</a></strong>"))
    s2(("<strong><a href="https://www.flhealthcharts.gov/ChartsReports/rdPage.aspx?rdReport=FrequencyMerlin.Frequency" target="_blank" rel="noreferrer">FLHealthCHARTS Reportable Diseases Frequency Report (Merlin surveillance system)</a></strong>"))
    s3(("<strong><a href="https://www.in.gov/health/idepd/diseases-and-conditions-resource-page/cyclosporiasis/" target="_blank" rel="noreferrer">IDOH Cyclosporiasis - Cases by County</a></strong>"))
    s5(("<strong><a href="https://www.lpm.org/news/2026-07-17/where-have-cases-of-cyclosporiasis-been-detected-in-ky-what-health-officials-have-confirmed" target="_blank" rel="noreferrer">Kentucky cyclosporiasis case counts, as relayed by trusted news media</a></strong>"))
    s6(("<strong><a href="https://www.michigan.gov/mdhhs/keep-mi-healthy/infectious-diseases/infectious-disease-outbreaks" target="_blank" rel="noreferrer">MDHHS Cyclosporiasis Outbreak - Cases by County</a></strong>"))
    s8(("<strong><a href="https://data.ohio.gov/wps/portal/gov/data/view/summary-of-infectious-diseases-in-ohio" target="_blank" rel="noreferrer">Summary of Infectious Diseases in Ohio</a></strong>"))
    s10(("<strong><a href="https://www.oregon.gov/oha/ph/diseasesconditions/communicabledisease/diseasesurveillancedata/weekly-monthlystatistics/pages/index.aspx" target="_blank" rel="noreferrer">Monthly CD Surveillance Report (Tableau Public)</a></strong>"))
    s12(("<strong><a href="https://oeps.wv.gov/cyclosporiasis-outbreak" target="_blank" rel="noreferrer">WV OEPS Cyclosporiasis Outbreak - Cases by County</a></strong>"))
    subgraph ca_cyclo["`ca_cyclo`"]
        direction LR
        n1["`data.csv.gz`"]:::pass
    end
    subgraph fl_cyclo["`fl_cyclo`"]
        direction LR
        n2["`data.csv.gz`"]:::pass
    end
    subgraph in_cyclo["`in_cyclo`"]
        direction LR
        n3["`data.csv.gz<br /><br />Script Failed:<br />Could not find the 'Cases by County' cyclosporiasis table on the page - source page structure may have changed.`"]:::fail
    end
    subgraph ky_cyclo_news["`ky_cyclo_news`"]
        direction LR
        n4["`data.csv.gz<br/><br/><ul><li><code>missing_info: ky_cyclo_news_cases_new.x, ky_cyclo_news_cases_new.y</code></li><li><code>type_changed: ky_cyclo_news_hospitalized</code></li></ul>`"]:::warn
    end
    subgraph mi_cyclo["`mi_cyclo`"]
        direction LR
        n5["`data.csv.gz`"]:::pass
    end
    subgraph oh_cyclo["`oh_cyclo`"]
        direction LR
        n6["`data.csv.gz`"]:::pass
    end
    subgraph or_cyclo["`or_cyclo`"]
        direction LR
        n7["`data.csv.gz`"]:::pass
    end
    subgraph wv_cyclo["`wv_cyclo`"]
        direction LR
        n8["`data.csv.gz<br/><br/><ul><li><code>type_changed: geography, wv_cyclo_cases_new</code></li></ul>`"]:::warn
    end
    s0---s1["<strong><a href="https://skylab.cdph.ca.gov/idbsssprovisional/SSSprovisional.html" target="_blank" rel="noreferrer">Static Quarto/R Markdown report embedded via iframe on the CDPH page</a></strong>"]
    s1 --> n1
    s2 --> n2
    s3---s4["<strong><a href="https://www.in.gov/health/idepd/diseases-and-conditions-resource-page/cyclosporiasis/#Cases_by_County" target="_blank" rel="noreferrer">"Cases by County" accordion table on the Cyclosporiasis resource page</a></strong>"]
    s4 --> n3
    s5 --> n4
    s6---s7["<strong><a href="https://www.michigan.gov/mdhhs/keep-mi-healthy/infectious-diseases/infectious-disease-outbreaks" target="_blank" rel="noreferrer">"Detailed Outbreak Data" accordion, "Cases by county" section, on the Infectious Disease Outbreaks page</a></strong>"]
    s7 --> n5
    s8---s9["<strong><a href="https://analytics.das.ohio.gov/t/ODHDPPUB/views/GeneralCaseCountPublicPROD/GeographicalDistribution" target="_blank" rel="noreferrer">Tableau Server dashboard (site ODHDPPUB, workbook GeneralCaseCountPublicPROD, view GeographicalDistribution)</a></strong>"]
    s9 --> n6
    s10---s11["<strong><a href="https://public.tableau.com/views/MonthlyReportDashboard_EXTERNAL_AGGREGATED/MonthlyReportDashboard" target="_blank" rel="noreferrer">Tableau Public workbook 'MonthlyReportDashboard_EXTERNAL_AGGREGATED', view 'MonthlyReportDashboard' ('Statewide' and 'by County' tabs)</a></strong>"]
    s11 --> n7
    s12---s13["<strong><a href="https://oeps.wv.gov/cyclosporiasis-outbreak" target="_blank" rel="noreferrer">"Cases by County" panel embedded in the dashboard image on the Cyclosporiasis Outbreak page</a></strong>"]
    s13 --> n8
```
