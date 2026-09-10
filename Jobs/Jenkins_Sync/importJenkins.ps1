# ==============================================================================
# jenkinsnew synchronization import
#
# Source landing directory:
#   E:\JenkinsSync
#
# Target Jenkins Home:
#   E:\Jenkins\Home
#
# Imports:
#   - Plugin archive files
#   - Jenkins users
#   - Job and folder configurations
#
# Does not import, modify, or delete:
#   - Build history
#   - Archived build artifacts
#   - Workspaces
#   - Target-only jobs
#
# Jenkins is restarted only when changes are detected.
# ==============================================================================

$ErrorActionPreference = "Stop"

$SharedRoot        = "E:\JenkinsSync"
$CompletionMarker = Join-Path $SharedRoot "_export_success.txt"
$TargetJenkinsHome = "E:\Jenkins\Home"
$ServiceName       = "jenkins"
$LogDirectory      = "E:\Jenkins_Sync\logs"
$LogFile           = Join-Path $LogDirectory "import_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$JenkinsWasStopped = $false

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] $Message"

    Write-Host $LogMessage
    $LogMessage | Out-File -FilePath $LogFile -Append -Encoding ascii
}

function Test-RobocopyChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string[]]$FileFilters = @("*.*"),

        [string[]]$ExcludedDirectories = @()
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Import source does not exist: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    Write-Log "Checking for changes: $Description"

    $RobocopyArguments = @(
        $Source
        $Destination
    )

    $RobocopyArguments += $FileFilters

    $RobocopyArguments += @(
        "/E"
        "/L"
        "/XJ"
        "/COPY:DAT"
        "/DCOPY:DAT"
        "/R:0"
        "/W:0"
        "/NP"
        "/NDL"
        "/NFL"
        "/NJH"
        "/NJS"
        "/LOG+:$LogFile"
    )

    if ($ExcludedDirectories.Count -gt 0) {
        $RobocopyArguments += "/XD"
        $RobocopyArguments += $ExcludedDirectories
    }

    & robocopy.exe @RobocopyArguments | Out-Null
    $RobocopyExitCode = $LASTEXITCODE

    Write-Log "$Description comparison returned exit code $RobocopyExitCode."

    if ($RobocopyExitCode -ge 8) {
        throw "Unable to compare $Description. Robocopy exit code: $RobocopyExitCode."
    }

    return [bool](($RobocopyExitCode -band 1) -eq 1)
}

function Invoke-CheckedRobocopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string[]]$FileFilters = @("*.*"),

        [string[]]$ExcludedDirectories = @()
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Import source does not exist: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    Write-Log "Starting: $Description"
    Write-Log "Source: $Source"
    Write-Log "Destination: $Destination"

    $RobocopyArguments = @(
        $Source
        $Destination
    )

    $RobocopyArguments += $FileFilters

    $RobocopyArguments += @(
        "/E"
        "/Z"
        "/XJ"
        "/COPY:DAT"
        "/DCOPY:DAT"
        "/R:3"
        "/W:10"
        "/NP"
        "/NDL"
        "/NFL"
        "/NJH"
        "/NJS"
        "/LOG+:$LogFile"
    )

    if ($ExcludedDirectories.Count -gt 0) {
        $RobocopyArguments += "/XD"
        $RobocopyArguments += $ExcludedDirectories
    }

    & robocopy.exe @RobocopyArguments | Out-Null
    $RobocopyExitCode = $LASTEXITCODE

    Write-Log "$Description completed with Robocopy exit code $RobocopyExitCode."

    if ($RobocopyExitCode -ge 8) {
        throw "$Description failed with Robocopy exit code $RobocopyExitCode."
    }
}

try {
    Write-Log "============================================================"
    Write-Log "Starting jenkinsnew synchronization import"
    Write-Log "============================================================"

    if (-not (Test-Path -LiteralPath $SharedRoot)) {
        throw "Shared landing directory does not exist: $SharedRoot"
    }

    if (-not (Test-Path -LiteralPath $CompletionMarker)) {
        throw "Latest Jenkins export did not complete successfully. Completion marker is missing: $CompletionMarker"
    }

    $MarkerAge = (Get-Date) - (Get-Item -LiteralPath $CompletionMarker).LastWriteTime

    Write-Log "Latest successful export age: $([math]::Round($MarkerAge.TotalMinutes, 2)) minutes"

    if ($MarkerAge.TotalHours -gt 2) {
        throw "Latest successful export is older than 2 hours. Import aborted to prevent importing stale data."
    }

    if (-not (Test-Path -LiteralPath $TargetJenkinsHome)) {
        throw "Target Jenkins Home does not exist: $TargetJenkinsHome"
    }

    $JenkinsService = Get-Service -Name $ServiceName -ErrorAction Stop

    Write-Log "Jenkins service name: $ServiceName"
    Write-Log "Current Jenkins service status: $($JenkinsService.Status)"

    $PluginsChanged = Test-RobocopyChanges `
        -Description "plugins" `
        -Source "$SharedRoot\plugins" `
        -Destination "$TargetJenkinsHome\plugins" `
        -FileFilters @(
            "*.jpi"
            "*.hpi"
            "*.jpi.disabled"
            "*.hpi.disabled"
            "*.pinned"
        )

    $UsersChanged = Test-RobocopyChanges `
        -Description "users" `
        -Source "$SharedRoot\users" `
        -Destination "$TargetJenkinsHome\users"

    $JobsChanged = Test-RobocopyChanges `
        -Description "job configurations" `
        -Source "$SharedRoot\jobs" `
        -Destination "$TargetJenkinsHome\jobs" `
        -ExcludedDirectories @(
            "builds"
            "workspace"
            "indexing"
            "lastStable"
            "lastSuccessful"
        )

    Write-Log "Plugins changed: $PluginsChanged"
    Write-Log "Users changed: $UsersChanged"
    Write-Log "Job configurations changed: $JobsChanged"

    if (-not ($PluginsChanged -or $UsersChanged -or $JobsChanged)) {
        Write-Log "No changes detected."
        Write-Log "Jenkins will not be restarted."
        Write-Log "Synchronization import completed with no changes."
        exit 0
    }

    if ((Get-Service -Name $ServiceName).Status -ne "Stopped") {
        Write-Log "Stopping Jenkins service: $ServiceName"

        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        (Get-Service -Name $ServiceName).WaitForStatus("Stopped", "00:03:00")

        $JenkinsWasStopped = $true
        Write-Log "Jenkins service stopped successfully."
    }
    else {
        $JenkinsWasStopped = $true
        Write-Log "Jenkins service was already stopped."
    }

    Invoke-CheckedRobocopy `
        -Description "Import plugins" `
        -Source "$SharedRoot\plugins" `
        -Destination "$TargetJenkinsHome\plugins" `
        -FileFilters @(
            "*.jpi"
            "*.hpi"
            "*.jpi.disabled"
            "*.hpi.disabled"
            "*.pinned"
        )

    Invoke-CheckedRobocopy `
        -Description "Import users" `
        -Source "$SharedRoot\users" `
        -Destination "$TargetJenkinsHome\users"

    Invoke-CheckedRobocopy `
        -Description "Import job configurations" `
        -Source "$SharedRoot\jobs" `
        -Destination "$TargetJenkinsHome\jobs" `
        -ExcludedDirectories @(
            "builds"
            "workspace"
            "indexing"
            "lastStable"
            "lastSuccessful"
        )

    Write-Log "Starting Jenkins service: $ServiceName"

    Start-Service -Name $ServiceName -ErrorAction Stop
    (Get-Service -Name $ServiceName).WaitForStatus("Running", "00:03:00")

    $JenkinsWasStopped = $false

    $FinalServiceStatus = (Get-Service -Name $ServiceName).Status
    Write-Log "Jenkins service status: $FinalServiceStatus"

    if ($FinalServiceStatus -ne "Running") {
        throw "Jenkins service did not reach the Running state."
    }

    Write-Log "============================================================"
    Write-Log "jenkinsnew synchronization import completed successfully"
    Write-Log "============================================================"

    exit 0
}
catch {
    Write-Log "ERROR: Jenkins synchronization import failed."
    Write-Log "ERROR: $($_.Exception.Message)"

    if ($JenkinsWasStopped) {
        Write-Log "Attempting to recover by starting Jenkins."

        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            (Get-Service -Name $ServiceName).WaitForStatus("Running", "00:03:00")
            Write-Log "Jenkins service recovery succeeded."
        }
        catch {
            Write-Log "CRITICAL: Jenkins service recovery failed."
            Write-Log "CRITICAL: $($_.Exception.Message)"
        }
    }

    exit 1
}