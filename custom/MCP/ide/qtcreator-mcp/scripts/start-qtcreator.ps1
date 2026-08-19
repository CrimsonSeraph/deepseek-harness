# start-qtcreator.ps1 - start Qt Creator and wait for the MCP Server to be ready
#
# Usage:
#   .\scripts\start-qtcreator.ps1                 # start (or reuse) Qt Creator, wait for port 46327
#   .\scripts\start-qtcreator.ps1 -Check          # after ready, run MCP handshake + tool list
#   .\scripts\start-qtcreator.ps1 -Port 46327 -WaitSeconds 120
#   .\scripts\start-qtcreator.ps1 -CreatorExe "C:\Qt\Tools\QtCreator\bin\qtcreator.exe"   # non-standard install
#
# Notes:
#   - Qt Creator 20+ ships the MCP Server plugin (Preferences > AI > Qt Creator MCP Server).
#     "Enable MCP Server" defaults to ON; the port is fixed to 46327 on this machine.
#   - The MCP server lives inside the IDE process: closing Creator drops the endpoint;
#     re-run this script to bring it back.

param(
    [string]$CreatorExe = 'C:\Qt\Tools\QtCreator\bin\qtcreator.exe',
    [int]$Port = 46327,
    [int]$WaitSeconds = 120,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$running = Get-Process qtcreator -ErrorAction SilentlyContinue | Select-Object -First 1
if ($running) {
    Write-Host "Qt Creator already running (PID $($running.Id)); checking the port..."
} else {
    if (-not (Test-Path $CreatorExe)) {
        Write-Error "qtcreator.exe not found at $CreatorExe . Install / upgrade Qt Creator 20+ first, or pass -CreatorExe."
        exit 1
    }
    Write-Host "Starting Qt Creator: $CreatorExe"
    Start-Process $CreatorExe | Out-Null
}

$deadline = [DateTime]::Now.AddSeconds($WaitSeconds)
$ready = $false
while ([DateTime]::Now -lt $deadline) {
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        $ready = $true
        break
    }
    Start-Sleep -Milliseconds 1000
}

if (-not $ready) {
    Write-Error "Port $Port is not listening after $WaitSeconds seconds. Check Preferences > AI > Qt Creator MCP Server (Enable MCP Server, Port)."
    exit 1
}

Write-Host "OK: Qt Creator MCP Server ready -> http://127.0.0.1:$Port/"
if ($Check) {
    & (Join-Path $PSScriptRoot 'check-server.ps1') -Port $Port -Tools
    exit $LASTEXITCODE
}
