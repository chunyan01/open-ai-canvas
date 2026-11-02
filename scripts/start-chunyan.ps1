[CmdletBinding()]
param(
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appUrl = "http://localhost:3000"

function Test-ListeningPort([int]$Port) {
    try {
        return $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1)
    } catch {
        return $false
    }
}

$frontendRunning = Test-ListeningPort 3000
$backendRunning = Test-ListeningPort 8080

if ($frontendRunning -and $backendRunning) {
    if (-not $NoBrowser) {
        Start-Process $appUrl
    }
    return
}

if ($frontendRunning -or $backendRunning) {
    throw "Port 3000 or 8080 is partially occupied. Close the existing service and try again."
}

& (Join-Path $PSScriptRoot "start-local.ps1")

$deadline = (Get-Date).AddMinutes(2)
while ((Get-Date) -lt $deadline) {
    if (Test-ListeningPort 3000) {
        if (-not $NoBrowser) {
            Start-Process $appUrl
        }
        return
    }
    Start-Sleep -Seconds 2
}

throw "The frontend did not start within two minutes. Check the newly opened PowerShell windows."
