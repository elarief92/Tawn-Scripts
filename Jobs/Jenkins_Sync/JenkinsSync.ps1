# ==============================================================================
# Jenkins PROD export
#
# Source:
#   E:\Jenkins\Home
#
# Destination:
#   \\HQV-JNKS-APPP03\JenkinsSync
#
# Copies:
#   - Job and folder configurations
#   - Users
#   - Plugin archive files
#
# Does not copy:
#   - Build history
#   - Archived build artifacts
#   - Workspaces
#   - Temporary indexing data
# ==============================================================================

$ErrorActionPreference = "Stop"

$SourceJenkinsHome = "E:\Jenkins\Home"
$SharedFolder      = "\\HQV-JNKS-APPP03\JenkinsSync"
$CompletionMarker = Join-Path $SharedFolder "_export_success.txt"
$LogDirectory      = "E:\Jenkins_Sync\logs"
$LogFile           = Join-Path $LogDirectory "export_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
        throw "Source path does not exist: $Source"
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

    & robocopy.exe @RobocopyArguments
    $RobocopyExitCode = $LASTEXITCODE

    Write-Log "$Description completed with Robocopy exit code $RobocopyExitCode."

    if ($RobocopyExitCode -ge 8) {
        throw "$Description failed with Robocopy exit code $RobocopyExitCode."
    }

    if (($RobocopyExitCode -band 1) -eq 1) {
        Write-Log "$Description copied new or modified files."
    }
    else {
        Write-Log "$Description found no new or modified files."
    }
}

try {
    Write-Log "============================================================"
    Write-Log "Starting Jenkins PROD synchronization export"
    Write-Log "============================================================"

    if (-not (Test-Path -LiteralPath $SourceJenkinsHome)) {
        throw "Jenkins Home does not exist: $SourceJenkinsHome"
    }

    if (-not (Test-Path -LiteralPath $SharedFolder)) {
        throw "Shared folder is unavailable: $SharedFolder"
    }

    if (Test-Path -LiteralPath $CompletionMarker) {
        Remove-Item -LiteralPath $CompletionMarker -Force
        Write-Log "Previous export completion marker removed."
    }

    Invoke-CheckedRobocopy `
        -Description "Export plugins" `
        -Source "$SourceJenkinsHome\plugins" `
        -Destination "$SharedFolder\plugins" `
        -FileFilters @(
            "*.jpi"
            "*.hpi"
            "*.jpi.disabled"
            "*.hpi.disabled"
            "*.pinned"
        )

    Invoke-CheckedRobocopy `
        -Description "Export users" `
        -Source "$SourceJenkinsHome\users" `
        -Destination "$SharedFolder\users"

    Invoke-CheckedRobocopy `
        -Description "Export job configurations" `
        -Source "$SourceJenkinsHome\jobs" `
        -Destination "$SharedFolder\jobs" `
        -ExcludedDirectories @(
            "builds"
            "workspace"
            "indexing"
            "lastStable"
            "lastSuccessful"
        )

    (Get-Date).ToString("o") | Set-Content -LiteralPath $CompletionMarker -Encoding ascii

    Write-Log "Completion marker created: $CompletionMarker"
    Write-Log "============================================================"
    Write-Log "Jenkins PROD synchronization export completed successfully"
    Write-Log "============================================================"

    exit 0
}
catch {
    Write-Log "ERROR: Jenkins synchronization export failed."
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}