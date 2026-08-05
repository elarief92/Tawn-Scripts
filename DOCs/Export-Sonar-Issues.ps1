# Export-Sonar-Issues.ps1
#
# Run:
# powershell.exe -ExecutionPolicy Bypass -File "C:\Users\VDR000691\Documents\Tawn-Scripts\DOCs\Export-Sonar-Issues.ps1"


# ============================================================
# Configuration
# ============================================================

$SonarUrl = "https://sonarqube.tawuniya.com"
$Token    = "squ_82a0e98f86bf06b15d6e0c92f0b3c6d4dae5a441"
$Branch   = "DEV"

$Projects = @(
    "Tawuniya-CRM"
)

$OutputDir = "C:\Users\VDR000691\Documents\Tawn-Scripts\DOCs\SonarReports"

New-Item `
    -ItemType Directory `
    -Path $OutputDir `
    -Force | Out-Null


# ============================================================
# Authentication
# ============================================================

$pair = "$($Token):"

$base64 = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes($pair)
)

$headers = @{
    Authorization = "Basic $base64"
}


# ============================================================
# Query partitions
#
# SonarQube limits one query to 10,000 accessible results.
# Dividing by type and severity avoids that limit.
# ============================================================

$IssueTypes = @(
    "BUG",
    "VULNERABILITY",
    "CODE_SMELL"
)

$Severities = @(
    "BLOCKER",
    "CRITICAL",
    "MAJOR",
    "MINOR",
    "INFO"
)

$ResolvedValues = @(
    "false",
    "true"
)

$allIssues = @()


# ============================================================
# Export issues
# ============================================================

foreach ($Project in $Projects) {
    Write-Host ""
    Write-Host "=================================================="
    Write-Host "Processing project: $Project"
    Write-Host "=================================================="

    $projectIssues = @()

    try {
        foreach ($resolvedStatus in $ResolvedValues) {
            foreach ($issueType in $IssueTypes) {
                foreach ($severity in $Severities) {
                    $page     = 1
                    $pageSize = 500

                    do {
                        Write-Host (
                            "Resolved=$resolvedStatus | " +
                            "Type=$issueType | " +
                            "Severity=$severity | " +
                            "Page=$page"
                        )

                        $parameters = @{
                            componentKeys = $Project
                            branch        = $Branch
                            resolved      = $resolvedStatus
                            types         = $issueType
                            severities    = $severity
                            p             = $page
                            ps            = $pageSize
                        }

                        $queryString = (
                            $parameters.GetEnumerator() |
                            ForEach-Object {
                                $name  = [uri]::EscapeDataString(
                                    [string]$_.Key
                                )

                                $value = [uri]::EscapeDataString(
                                    [string]$_.Value
                                )

                                "$name=$value"
                            }
                        ) -join "&"

                        $issuesUrl = (
                            "$SonarUrl/api/issues/search?$queryString"
                        )

                        $issuesResponse = Invoke-RestMethod `
                            -Uri $issuesUrl `
                            -Headers $headers `
                            -Method Get

                        if ($issuesResponse.paging) {
                            $totalIssues = [int]$issuesResponse.paging.total
                        }
                        else {
                            $totalIssues = [int]$issuesResponse.total
                        }

                        if ($totalIssues -gt 10000) {
                            throw (
                                "Query still contains more than 10,000 issues. " +
                                "Project=$Project, " +
                                "Resolved=$resolvedStatus, " +
                                "Type=$issueType, " +
                                "Severity=$severity, " +
                                "Total=$totalIssues"
                            )
                        }

                        foreach ($issue in $issuesResponse.issues) {
                            $filePath = $issue.component

                            if ($filePath) {
                                $filePath = $filePath -replace (
                                    "^$([regex]::Escape($Project)):"
                                ), ""
                            }

                            $securityImpact = (
                                $issue.impacts |
                                Where-Object {
                                    $_.softwareQuality -eq "SECURITY"
                                } |
                                Select-Object -ExpandProperty severity
                            ) -join ","

                            $reliabilityImpact = (
                                $issue.impacts |
                                Where-Object {
                                    $_.softwareQuality -eq "RELIABILITY"
                                } |
                                Select-Object -ExpandProperty severity
                            ) -join ","

                            $maintainabilityImpact = (
                                $issue.impacts |
                                Where-Object {
                                    $_.softwareQuality -eq "MAINTAINABILITY"
                                } |
                                Select-Object -ExpandProperty severity
                            ) -join ","

                            $issueRow = [PSCustomObject][ordered]@{
                                project_key            = $Project
                                branch                 = $Branch
                                issue_key              = $issue.key
                                rule                   = $issue.rule
                                type                   = $issue.type
                                severity               = $issue.severity
                                status                 = $issue.status
                                resolution             = $issue.resolution
                                message                = $issue.message
                                component              = $issue.component
                                file_path              = $filePath
                                line                   = $issue.line
                                effort                 = $issue.effort
                                debt                   = $issue.debt
                                author                 = $issue.author
                                assignee               = $issue.assignee
                                tags                   = (
                                    $issue.tags -join ","
                                )
                                clean_code_attribute   = (
                                    $issue.cleanCodeAttribute
                                )
                                security_impact        = (
                                    $securityImpact
                                )
                                reliability_impact     = (
                                    $reliabilityImpact
                                )
                                maintainability_impact = (
                                    $maintainabilityImpact
                                )
                                creation_date          = (
                                    $issue.creationDate
                                )
                                update_date            = (
                                    $issue.updateDate
                                )
                                close_date             = (
                                    $issue.closeDate
                                )
                            }

                            $projectIssues += $issueRow
                        }

                        $page++

                    } while (
                        (($page - 1) * $pageSize) -lt $totalIssues
                    )
                }
            }
        }


        # ====================================================
        # Remove duplicates
        # ====================================================

        $projectIssues = @(
            $projectIssues |
            Sort-Object issue_key -Unique
        )

        $allIssues += $projectIssues


        # ====================================================
        # Export project CSV
        # ====================================================

        $safeProjectName = (
            $Project -replace '[\\/:*?"<>|]', "_"
        )

        $projectFile = Join-Path `
            -Path $OutputDir `
            -ChildPath "Sonar_Issues_$safeProjectName.csv"

        if ($projectIssues.Count -gt 0) {
            $projectIssues |
                Sort-Object `
                    status,
                    type,
                    severity,
                    creation_date |
                Export-Csv `
                    -Path $projectFile `
                    -NoTypeInformation `
                    -Encoding UTF8

            Write-Host ""
            Write-Host "Project completed successfully."
            Write-Host "Issues exported: $($projectIssues.Count)"
            Write-Host "File: $projectFile"
        }
        else {
            Write-Host "No issues found for project: $Project"
        }
    }
    catch {
        Write-Host ""
        Write-Host "FAILED project: $Project"
        Write-Host "Error: $($_.Exception.Message)"
    }
}


# ============================================================
# Export combined CSV
# ============================================================

$allIssues = @(
    $allIssues |
    Sort-Object project_key, issue_key -Unique
)

$allIssuesFile = Join-Path `
    -Path $OutputDir `
    -ChildPath "Sonar_Issues_All_Projects.csv"

if ($allIssues.Count -gt 0) {
    $allIssues |
        Sort-Object `
            project_key,
            status,
            type,
            severity,
            creation_date |
        Export-Csv `
            -Path $allIssuesFile `
            -NoTypeInformation `
            -Encoding UTF8
}


# ============================================================
# Result
# ============================================================

Write-Host ""
Write-Host "=================================================="
Write-Host "SonarQube issue export completed"
Write-Host "=================================================="
Write-Host "Branch: $Branch"
Write-Host "Projects processed: $($Projects.Count)"
Write-Host "Total unique issues: $($allIssues.Count)"
Write-Host "Combined CSV:"
Write-Host $allIssuesFile
Write-Host "=================================================="