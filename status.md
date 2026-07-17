```mermaid
flowchart LR
    classDef pass stroke:#66bb6a
    classDef warn stroke:#ffa726
    classDef fail stroke:#f44336
    s0(("<strong><a href="https://www.cdph.ca.gov/Programs/CID/DCDC/Pages/IDBProvisionalSummaryReport.aspx" target="_blank" rel="noreferrer">Provisional Summary Report of Selected California Reportable Diseases</a></strong>"))
    s2(("<strong><a href="https://www.epicresearch.org/health-alerts/" target="_blank" rel="noreferrer">Epic Research Health Alerts - Cyclosporiasis</a></strong>"))
    s4(("<strong><a href="https://www.flhealthcharts.gov/ChartsReports/rdPage.aspx?rdReport=FrequencyMerlin.Frequency" target="_blank" rel="noreferrer">FLHealthCHARTS Reportable Diseases Frequency Report (Merlin surveillance system)</a></strong>"))
    s5(("<strong><a href="https://www.michigan.gov/mdhhs/keep-mi-healthy/infectious-diseases/infectious-disease-outbreaks" target="_blank" rel="noreferrer">MDHHS Cyclosporiasis Outbreak - Cases by County</a></strong>"))
    s7(("<strong><a href="https://data.ohio.gov/wps/portal/gov/data/view/summary-of-infectious-diseases-in-ohio" target="_blank" rel="noreferrer">Summary of Infectious Diseases in Ohio</a></strong>"))
    s9(("<strong><a href="https://www.oregon.gov/oha/ph/diseasesconditions/communicabledisease/diseasesurveillancedata/weekly-monthlystatistics/pages/index.aspx" target="_blank" rel="noreferrer">Monthly CD Surveillance Report (Tableau Public)</a></strong>"))
    subgraph ca_cyclo["`ca_cyclo`"]
        direction LR
        n1["`data.csv.gz`"]:::pass
    end
    subgraph epic_health_alerts["`epic_health_alerts`"]
        direction LR
        n2["`data.csv.gz`"]:::pass
    end
    subgraph fl_cyclo["`fl_cyclo`"]
        direction LR
        n3["`data.csv.gz`"]:::pass
    end
    subgraph mi_cyclo["`mi_cyclo`"]
        direction LR
        n4["`data.csv.gz<br/><br/><ul><li><code>type_changed: geography, mi_cyclo_cases_new</code></li></ul>`"]:::warn
    end
    subgraph oh_cyclo["`oh_cyclo`"]
        direction LR
        n5["`data.csv.gz<br/><br/><ul><li><code>type_changed: geography</code></li></ul>`"]:::warn
    end
    subgraph or_cyclo["`or_cyclo`"]
        direction LR
        n6["`data.csv.gz`"]:::pass
    end
    s0---s1["<strong><a href="https://skylab.cdph.ca.gov/idbsssprovisional/SSSprovisional.html" target="_blank" rel="noreferrer">Static Quarto/R Markdown report embedded via iframe on the CDPH page</a></strong>"]
    s1 --> n1
    s2---s3["<strong><a href="https://www.epicresearch.org/health-alerts/" target="_blank" rel="noreferrer">Cyclosporiasis condition table on the Health Alerts page</a></strong>"]
    s3 --> n2
    s4 --> n3
    s5---s6["<strong><a href="https://www.michigan.gov/mdhhs/keep-mi-healthy/infectious-diseases/infectious-disease-outbreaks" target="_blank" rel="noreferrer">"Detailed Outbreak Data" accordion, "Cases by county" section, on the Infectious Disease Outbreaks page</a></strong>"]
    s6 --> n4
    s7---s8["<strong><a href="https://analytics.das.ohio.gov/t/ODHDPPUB/views/GeneralCaseCountPublicPROD/GeographicalDistribution" target="_blank" rel="noreferrer">Tableau Server dashboard (site ODHDPPUB, workbook GeneralCaseCountPublicPROD, view GeographicalDistribution)</a></strong>"]
    s8 --> n5
    s9---s10["<strong><a href="https://public.tableau.com/views/MonthlyReportDashboard_EXTERNAL_AGGREGATED/MonthlyReportDashboard" target="_blank" rel="noreferrer">Tableau Public workbook 'MonthlyReportDashboard_EXTERNAL_AGGREGATED', view 'MonthlyReportDashboard' ('Statewide' and 'by County' tabs)</a></strong>"]
    s10 --> n6
```
