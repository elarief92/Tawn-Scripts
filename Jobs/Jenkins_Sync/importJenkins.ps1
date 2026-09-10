# JenkinsNew synchronization import
# Source: E:\JenkinsSync
# Target: E:\Jenkins\Home
# Build history, workspaces and target-only jobs are preserved.

$ErrorActionPreference = "Stop"

$SharedRoot  = "E:\JenkinsSync"
$JenkinsHome = "E:\Jenkins\Home"
$Marker      = "$SharedRoot\_export_success.txt"
$Service     = "jenkins"
$LogDir      = "E:\Jenkins_Sync\logs"
$LogFile     = "$LogDir\import_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$JenkinsWasStopped = $false

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log($Message) {
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $Line
    $Line | Out-File $LogFile -Append -Encoding ascii
}

function Invoke-Robocopy {
    param(
        $Name,
        $Source,
        $Destination,
        $Files = @("*.*"),
        $ExcludedDirs = @(),
        [switch]$Preview
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source path does not exist: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $RoboArgs = @(
        $Source
        $Destination
    ) + $Files + @(
        "/E"
        "/XJ"
        "/COPY:DAT"
        "/DCOPY:DAT"
        "/NP"
        "/NDL"
        "/NFL"
        "/NJH"
        "/NJS"
        "/LOG+:$LogFile"
    )

    if ($Preview) {
        Write-Log "Checking for changes: $Name"
        $RoboArgs += @("/L", "/R:0", "/W:0")
    }
    else {
        Write-Log "Importing $Name..."
        $RoboArgs += @("/Z", "/R:3", "/W:10")
    }

    if ($ExcludedDirs.Count -gt 0) {
        $RoboArgs += "/XD"
        $RoboArgs += $ExcludedDirs
    }

    & robocopy.exe @RoboArgs | Out-Null
    $ExitCode = $LASTEXITCODE

    Write-Log "$Name returned Robocopy exit code $ExitCode."

    if ($ExitCode -ge 8) {
        throw "$Name failed with Robocopy exit code $ExitCode."
    }

    if ($Preview) {
        return [bool](($ExitCode -band 1) -eq 1)
    }
}

$Items = @(
    @{
        Name        = "plugins"
        Source      = "$SharedRoot\plugins"
        Destination = "$JenkinsHome\plugins"
        Files       = @(
            "*.jpi"
            "*.hpi"
            "*.jpi.disabled"
            "*.hpi.disabled"
            "*.pinned"
        )
        Exclude = @()
    },
    @{
        Name        = "users"
        Source      = "$SharedRoot\users"
        Destination = "$JenkinsHome\users"
        Files       = @("*.*")
        Exclude     = @()
    },
    @{
        Name        = "job configurations"
        Source      = "$SharedRoot\jobs"
        Destination = "$JenkinsHome\jobs"
        Files       = @("*.*")
        Exclude     = @(
            "builds"
            "workspace"
            "indexing"
            "lastStable"
            "lastSuccessful"
        )
    }
)

try {
    Write-Log "Starting JenkinsNew synchronization import."

    if (-not (Test-Path -LiteralPath $SharedRoot)) {
        throw "Shared landing directory does not exist: $SharedRoot"
    }

    if (-not (Test-Path -LiteralPath $JenkinsHome)) {
        throw "Jenkins Home does not exist: $JenkinsHome"
    }

    if (-not (Test-Path -LiteralPath $Marker)) {
        throw "Latest export did not complete successfully. Marker is missing."
    }

    $MarkerAge = (Get-Date) - (Get-Item -LiteralPath $Marker).LastWriteTime
    Write-Log "Latest successful export age: $([math]::Round($MarkerAge.TotalMinutes, 2)) minutes."

    if ($MarkerAge.TotalHours -gt 2) {
        throw "Latest successful export is older than 2 hours. Import aborted."
    }

    $JenkinsStatus = (Get-Service -Name $Service -ErrorAction Stop).Status
    Write-Log "Jenkins service status: $JenkinsStatus"

    $Changes = @{}

    foreach ($Item in $Items) {
        $Changes[$Item.Name] = Invoke-Robocopy `
            -Name $Item.Name `
            -Source $Item.Source `
            -Destination $Item.Destination `
            -Files $Item.Files `
            -ExcludedDirs $Item.Exclude `
            -Preview
    }

    foreach ($Name in $Changes.Keys) {
        Write-Log "$Name changed: $($Changes[$Name])"
    }

    if (-not ($Changes.Values -contains $true)) {
        Write-Log "No changes detected. Jenkins will not be restarted."
        exit 0
    }

    if ((Get-Service -Name $Service).Status -ne "Stopped") {
        Write-Log "Stopping Jenkins service..."
        Stop-Service -Name $Service -Force
        (Get-Service -Name $Service).WaitForStatus("Stopped", "00:03:00")
    }

    $JenkinsWasStopped = $true
    Write-Log "Jenkins service stopped successfully."

    foreach ($Item in $Items) {
        Invoke-Robocopy `
            -Name $Item.Name `
            -Source $Item.Source `
            -Destination $Item.Destination `
            -Files $Item.Files `
            -ExcludedDirs $Item.Exclude
    }

    Write-Log "Starting Jenkins service..."
    Start-Service -Name $Service
    (Get-Service -Name $Service).WaitForStatus("Running", "00:03:00")

    $JenkinsWasStopped = $false
    Write-Log "JenkinsNew synchronization import completed successfully."
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"

    if ($JenkinsWasStopped) {
        Write-Log "Attempting to restart Jenkins."

        try {
            Start-Service -Name $Service
            (Get-Service -Name $Service).WaitForStatus("Running", "00:03:00")
            Write-Log "Jenkins service recovery succeeded."
        }
        catch {
            Write-Log "CRITICAL: Jenkins service recovery failed: $($_.Exception.Message)"
        }
    }

    exit 1
}