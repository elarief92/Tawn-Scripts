# ============================================================
# SonarQube Project Branch and Repository Report
# ============================================================

$SONAR_URL = "https://sonarqube.tawuniya.com"
$SONAR_TOKEN = "squ_82a0e98f86bf06b15d6e0c92f0b3c6d4dae5a441"

$CSV_PATH = "C:\Users\VDR000691\Documents\Tawn-Scripts\DOCs\SonarReports\project_branches.csv"

$PROJECT_KEY_PATTERN = "^DXP-.*$"

$TARGET_BRANCHES = @(
    "DEV"
    "QC"
    "UAT"
    "PREPROD"
    "PROD"
)

# ============================================================
# Validation
# ============================================================

if ([string]::IsNullOrWhiteSpace($SONAR_TOKEN) -or
    $SONAR_TOKEN -eq "PASTE_NEW_SONAR_TOKEN_HERE") {
    throw "Configure SONAR_TOKEN before running the script."
}

$reportDirectory = Split-Path -Path $CSV_PATH -Parent

if (-not (Test-Path -Path $reportDirectory)) {
    New-Item -Path $reportDirectory -ItemType Directory -Force |
        Out-Null
}

$authorizationHeader = "Authorization: Bearer $SONAR_TOKEN"

Write-Host "Validating SonarQube authentication..."

$authenticationResponse = curl.exe -k -sS `
    -H $authorizationHeader `
    "$SONAR_URL/api/authentication/validate" |
    ConvertFrom-Json

if (-not $authenticationResponse.valid) {
    throw "SonarQube authentication failed. Check SONAR_TOKEN."
}

Write-Host "Authentication successful."

# ============================================================
# Retrieve all accessible projects
# ============================================================

Write-Host "Retrieving SonarQube projects..."

$allProjects = @()
$page = 1
$pageSize = 100

do {
    $projectsResponse = curl.exe -k -sS `
        -H $authorizationHeader `
        "$SONAR_URL/api/components/search_projects?p=$page&ps=$pageSize" |
        ConvertFrom-Json

    if ($projectsResponse.errors) {
        throw "Failed to retrieve projects: $($projectsResponse.errors.msg -join '; ')"
    }

    $allProjects += @($projectsResponse.components)

    $totalProjects = [int]$projectsResponse.paging.total
    $retrievedProjects = $page * $pageSize
    $page++
}
while ($retrievedProjects -lt $totalProjects)

$projects = @(
    $allProjects |
        Where-Object {
            $_.key -match $PROJECT_KEY_PATTERN
        }
)

Write-Host "Accessible projects: $($allProjects.Count)"
Write-Host "Projects matching $PROJECT_KEY_PATTERN`: $($projects.Count)"

# ============================================================
# Retrieve branches and SCM repository links
# ============================================================

$report = foreach ($project in $projects) {
    Write-Host "Processing: $($project.key)"

    $encodedProjectKey = [System.Uri]::EscapeDataString($project.key)

    # Retrieve SCM repository URL
    $linksResponse = curl.exe -k -sS `
        -H $authorizationHeader `
        "$SONAR_URL/api/project_links/search?projectKey=$encodedProjectKey" |
        ConvertFrom-Json

    if ($linksResponse.errors) {
        Write-Warning "Could not retrieve links for $($project.key): $($linksResponse.errors.msg -join '; ')"
        $repositoryUrl = ""
    }
    else {
        $scmLink = $linksResponse.links |
            Where-Object {
                $_.type -eq "scm"
            } |
            Select-Object -First 1

        $repositoryUrl = if ($scmLink) {
            $scmLink.url
        }
        else {
            ""
        }
    }

    # Retrieve scanned branches
    $branchesResponse = curl.exe -k -sS `
        -H $authorizationHeader `
        "$SONAR_URL/api/project_branches/list?project=$encodedProjectKey" |
        ConvertFrom-Json

    if ($branchesResponse.errors) {
        Write-Warning "Could not retrieve branches for $($project.key): $($branchesResponse.errors.msg -join '; ')"
        continue
    }

    foreach ($branch in $branchesResponse.branches) {
        if ($branch.name -in $TARGET_BRANCHES) {
            [PSCustomObject]@{
                ProjectKey       = $project.key
                ProjectName      = $project.name
                Branch           = $branch.name
                IsMain           = $branch.isMain
                QualityGate      = $branch.status.qualityGateStatus
                LastAnalysisDate = $branch.analysisDate
                RepositoryURL    = $repositoryUrl
            }
        }
    }
}

# ============================================================
# Export CSV
# ============================================================

$report = @(
    $report |
        Sort-Object ProjectKey, Branch
)

$report |
    Export-Csv `
        -Path $CSV_PATH `
        -NoTypeInformation `
        -Encoding UTF8

# ============================================================
# Summary
# ============================================================

$projectsWithRepository = @(
    $report |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.RepositoryURL)
        } |
        Select-Object -ExpandProperty ProjectKey -Unique
)

$projectsWithoutRepository = @(
    $report |
        Where-Object {
            [string]::IsNullOrWhiteSpace($_.RepositoryURL)
        } |
        Select-Object -ExpandProperty ProjectKey -Unique
)

Write-Host ""
Write-Host "Report completed."
Write-Host "CSV file: $CSV_PATH"
Write-Host "Rows exported: $($report.Count)"
Write-Host "Projects with repository URL: $($projectsWithRepository.Count)"
Write-Host "Projects without repository URL: $($projectsWithoutRepository.Count)"

if ($projectsWithoutRepository.Count -gt 0) {
    Write-Host ""
    Write-Host "Projects missing repository URL:"

    $projectsWithoutRepository |
        ForEach-Object {
            Write-Host " - $_"
        }
}