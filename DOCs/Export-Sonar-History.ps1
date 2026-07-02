# Export-Sonar-History.ps1
# powershell.exe -ExecutionPolicy Bypass -File "C:\Users\VDR000691\Documents\Tawn-Scripts\DOCs\Export-Sonar-History.ps1"


$SonarUrl = "https://sonarqube.tawuniya.com"
$Token    = "squ_82a0e98f86bf06b15d6e0c92f0b3c6d4dae5a441"
$Branch   = "DEV"

$Projects = @(
  "DXP-FE-TRAVEL-INSURANCE-V3",
  "DXP-FE-SALES-VISIT-VISA-V3",
  "DXP-FE-SALES-MOTOR-V3",
  "DXP-FE-Life-OTP",
  "DXP-DH-WORKSHOP-PORTAL-V3",
  "DXP-DH-RECOVERY-PORTAL-V3",
  "DXP-BFF-WEB"
)

$Metrics = @(
  "bugs",
  "vulnerabilities",
  "code_smells",
  "security_hotspots",
  "coverage",
  "duplicated_lines_density",
  "reliability_rating",
  "security_rating",
  "sqale_rating",
  "alert_status"
)

function Convert-SonarRating {
    param([string]$Value)

    switch ($Value) {
        "1"   { return "A" }
        "1.0" { return "A" }
        "2"   { return "B" }
        "2.0" { return "B" }
        "3"   { return "C" }
        "3.0" { return "C" }
        "4"   { return "D" }
        "4.0" { return "D" }
        "5"   { return "E" }
        "5.0" { return "E" }
        default { return $Value }
    }
}

$OutputDir = "C:\Users\VDR000691\Documents\Tawn-Scripts\DOCs\SonarReports"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$pair = "$($Token):"
$base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $base64" }

$allSummary = @()
$allHistory = @()

foreach ($Project in $Projects) {
    Write-Host "Processing project: $Project"

    try {
        $summaryUrl = "$SonarUrl/api/project_analyses/search?project=$Project&ps=500"
        $summaryResponse = Invoke-RestMethod -Uri $summaryUrl -Headers $headers

        foreach ($analysis in $summaryResponse.analyses) {
            $qg = $analysis.events |
                Where-Object { $_.category -eq "QUALITY_GATE" } |
                Select-Object -First 1

            $allSummary += [PSCustomObject]@{
                analysis_date = $analysis.date
                project_key   = $Project
                branch        = $Branch
                version       = $analysis.projectVersion
                quality_gate  = if ($qg) { $qg.name } else { "" }
                revision      = $analysis.revision
                detected_ci   = $analysis.detectedCI
            }
        }

        $historyUrl = "$SonarUrl/api/measures/search_history?component=$Project&branch=$Branch&metrics=$($Metrics -join ',')&ps=1000"
        $historyResponse = Invoke-RestMethod -Uri $historyUrl -Headers $headers

        $dates = $historyResponse.measures.history.date | Sort-Object -Unique

        foreach ($date in $dates) {
            $row = [ordered]@{
                analysis_date          = $date
                project_key            = $Project
                branch                 = $Branch
                bugs                   = ""
                vulnerabilities        = ""
                code_smells            = ""
                security_hotspots      = ""
                coverage               = ""
                duplication            = ""
                reliability_rating     = ""
                security_rating        = ""
                maintainability_rating = ""
                alert_status           = ""
            }

            foreach ($metric in $Metrics) {
                $m = $historyResponse.measures | Where-Object { $_.metric -eq $metric }
                $value = ($m.history | Where-Object { $_.date -eq $date }).value

                switch ($metric) {
                    "reliability_rating" {
                        $row["reliability_rating"] = Convert-SonarRating $value
                    }
                    "security_rating" {
                        $row["security_rating"] = Convert-SonarRating $value
                    }
                    "sqale_rating" {
                        $row["maintainability_rating"] = Convert-SonarRating $value
                    }
                    "duplicated_lines_density" {
                        $row["duplication"] = if ($null -eq $value) { "" } else { $value }
                    }
                    default {
                        $row[$metric] = if ($null -eq $value) { "" } else { $value }
                    }
                }
            }

            $allHistory += [PSCustomObject]$row
        }
    }
    catch {
        Write-Host "FAILED project: $Project"
        Write-Host $_.Exception.Message
    }
}

$summaryFile = "$OutputDir\sonar_scan_summary_all_projects.csv"
$historyFile = "$OutputDir\sonar_measures_history_all_projects.csv"

$allSummary |
    Sort-Object project_key, analysis_date |
    Export-Csv $summaryFile -NoTypeInformation -Encoding UTF8

$allHistory |
    Sort-Object project_key, analysis_date |
    Export-Csv $historyFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Done."
Write-Host "Files created:"
Write-Host $summaryFile
Write-Host $historyFile