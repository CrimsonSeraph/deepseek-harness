# check-server.ps1 - check the Qt Creator MCP Server endpoint (127.0.0.1:46327)
#
# Usage:
#   .\scripts\check-server.ps1              # handshake + status
#   .\scripts\check-server.ps1 -Port 46327  # custom port
#   .\scripts\check-server.ps1 -Tools       # also list tool names
#
# Requires: Windows PowerShell 5.1+; Qt Creator running with the MCP server enabled
# (Preferences > AI > Qt Creator MCP Server, fixed port 46327 on this machine).

param(
    [int]$Port = 46327,
    [switch]$Tools
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"

$listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $listening) {
    Write-Error "Port $Port is not listening. Start Qt Creator and confirm Preferences > AI > Qt Creator MCP Server > Enable MCP Server."
    exit 1
}
$owner = Get-Process -Id $listening.OwningProcess -ErrorAction SilentlyContinue
Write-Host "OK: $base is listening (process: $($owner.ProcessName) / PID $($listening.OwningProcess))"

function Invoke-Mcp($url, $method, $params, $session) {
    $headers = @{
        'Content-Type'         = 'application/json'
        'Accept'               = 'application/json, text/event-stream'
        'MCP-Protocol-Version' = '2024-11-05'
    }
    if ($session) { $headers['Mcp-Session-Id'] = $session }
    $body = @{ jsonrpc = '2.0'; id = 1; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress
    $resp = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $body -UseBasicParsing
    $newSession = $null
    if ($resp.Headers['mcp-session-id']) { $newSession = $resp.Headers['mcp-session-id'] }
    $text = [string]$resp.Content
    if ($text -match '(?m)^data: (.+)$') {
        $data = $Matches[1] | ConvertFrom-Json
    } else {
        $data = $text | ConvertFrom-Json
    }
    return @{ Session = $newSession; Data = $data }
}

try {
    $init = Invoke-Mcp $base 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'dsh-check'; version = '1.0' } }
    $info = $init.Data.result.serverInfo
    Write-Host "MCP INIT OK: $($info.name) / $($info.version) (session $($init.Session))"

    if ($Tools) {
        $tl = Invoke-Mcp $base 'tools/list' @{} $init.Session
        $names = @($tl.Data.result.tools | ForEach-Object { $_.name })
        Write-Host "TOOLS: $($names.Count)"
        Write-Host ($names -join ', ')
    } else {
        Write-Host 'Hint: add -Tools to list all tool names.'
    }
} catch {
    Write-Error "MCP call failed: $($_.Exception.Message)"
    exit 1
}
