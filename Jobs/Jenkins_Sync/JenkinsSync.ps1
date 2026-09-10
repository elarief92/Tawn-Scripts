# Jenkins PROD synchronization
# Source: E:\Jenkins\Home
# Target: \\HQV-JNKS-APPP03\JenkinsSync
# Build history and workspaces are excluded.

$ErrorActionPreference = "Stop"

$JenkinsHome = "E:\Jenkins\Home"
$SharedRoot  = "\\HQV-JNKS-APPP03\JenkinsSync"
$Marker      = "$SharedRoot\_export_success.txt"
$LogDir      = "E:\Jenkins_Sync\logs"
$LogFile     = "$LogDir\export_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log($Message) {
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $Line
    $Line | Out-File $LogFile -Append -Encoding ascii
}

function Copy-JenkinsData($Name, $Source, $Destination, $Files, $ExcludedDirs = @()) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source path does not exist: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Write-Log "Exporting $Name..."

    $RoboArgs = @(
        $Source
        $Destination
    ) + $Files + @(
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

    if ($ExcludedDirs.Count -gt 0) {
        $RoboArgs += "/XD"
        $RoboArgs += $ExcludedDirs
    }

    & robocopy.exe @RoboArgs | Out-Null
    $ExitCode = $LASTEXITCODE

    Write-Log "$Name completed with Robocopy exit code $ExitCode."

    if ($ExitCode -ge 8) {
        throw "$Name export failed with Robocopy exit code $ExitCode."
    }
}

try {
    Write-Log "Starting Jenkins PROD synchronization export."

    if (-not (Test-Path -LiteralPath $JenkinsHome)) {
        throw "Jenkins Home does not exist: $JenkinsHome"
    }

    if (-not (Test-Path -LiteralPath $SharedRoot)) {
        throw "Shared folder is unavailable: $SharedRoot"
    }

    Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue

    Copy-JenkinsData `
        "plugins" `
        "$JenkinsHome\plugins" `
        "$SharedRoot\plugins" `
        @("*.jpi", "*.hpi", "*.jpi.disabled", "*.hpi.disabled", "*.pinned")

    Copy-JenkinsData `
        "users" `
        "$JenkinsHome\users" `
        "$SharedRoot\users" `
        @("*.*")

    Copy-JenkinsData `
        "job configurations" `
        "$JenkinsHome\jobs" `
        "$SharedRoot\jobs" `
        @("*.*") `
        @("builds", "workspace", "indexing", "lastStable", "lastSuccessful")

    (Get-Date).ToString("o") | Set-Content -LiteralPath $Marker -Encoding ascii

    Write-Log "Completion marker created: $Marker"
    Write-Log "Jenkins PROD synchronization export completed successfully."
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}