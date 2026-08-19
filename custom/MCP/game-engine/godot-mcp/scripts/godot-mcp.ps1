# godot-mcp.ps1 - verify or serve the godot-mcp MCP server (stdio)
#
# Usage:
#   .\scripts\godot-mcp.ps1                  # default: verify (build output, Godot path, MCP handshake, tool count)
#   .\scripts\godot-mcp.ps1 -Serve           # run the server in foreground (stdio, for an MCP client / debugging)
#   .\scripts\godot-mcp.ps1 -GodotPath "D:\Godot\Godot.exe"
#
# Notes:
#   - This copy lives at custom/MCP/game-engine/godot-mcp/. The original working install is
#     <GODOT_MCP_HOME> (the DSH bridge currently uses the original). To point DSH at this
#     copy, edit the mcp-godot args path in cordis.patch.yml (see README.md).
#   - GODOT_PATH: taken from -GodotPath, else the user environment variable. If missing, project
#     management tools still work; runtime game_* tools need a valid Godot path.

param(
    [string]$GodotPath = $env:GODOT_PATH,
    [switch]$Serve
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$serverJs = Join-Path $root 'build\index.js'

function Assert-Node {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw 'node not found. Install Node.js >= 18 and add it to PATH.' }
    return $node.Source
}

if (-not (Test-Path $serverJs)) {
    throw "build output not found: $serverJs . Run: cd '$root'; npm install; npm run build"
}

if ($Serve) {
    Write-Host 'Starting godot-mcp server (stdio)... Ctrl+C to exit.'
    if ($GodotPath) { $env:GODOT_PATH = $GodotPath }
    & (Assert-Node) $serverJs
    exit $LASTEXITCODE
}

# ---- verify mode ----
Write-Host '[1/3] Build output' -ForegroundColor Cyan
Write-Host "  OK: $serverJs"

Write-Host '[2/3] Godot path' -ForegroundColor Cyan
if ($GodotPath -and (Test-Path $GodotPath)) {
    $v = (Get-Item $GodotPath).VersionInfo
    Write-Host "  OK: $GodotPath  (version: $($v.ProductVersion))"
} else {
    Write-Warning "  GODOT_PATH invalid or unset ('$GodotPath'). Project management tools work; runtime game_* tools will not."
}

Write-Host '[3/3] MCP handshake + tool list' -ForegroundColor Cyan
$probe = Join-Path $env:TEMP 'godot-mcp-verify-probe.mjs'
$probeSrc = @'
import { spawn } from 'node:child_process';
const server = spawn(process.execPath, [process.argv[2]], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, GODOT_PATH: process.argv[3] || '' } });
let buf = ''; const pending = new Map(); let id = 0;
server.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i; while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.id !== undefined && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  }
});
const req = (method, params) => new Promise((r) => { pending.set(++id, r); server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); });
(async () => {
  const init = await req('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'verify', version: '1.0' } });
  if (!init.result) { console.log('INIT FAIL: ' + JSON.stringify(init)); process.exit(1); }
  const tools = await req('tools/list', {});
  console.log('INIT OK: ' + (init.result.serverInfo && init.result.serverInfo.name ? init.result.serverInfo.name : 'server'));
  console.log('TOOLS: ' + ((tools.result && tools.result.tools) ? tools.result.tools.length : 0));
  process.exit(0);
})().catch((e) => { console.error(e.message); process.exit(1); });
setTimeout(() => { console.error('TIMEOUT'); process.exit(1); }, 20000);
'@
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($probe, $probeSrc, $utf8NoBom)
    $godotArg = ''
    if ($GodotPath) { $godotArg = $GodotPath }
    & (Assert-Node) $probe $serverJs $godotArg 2>&1 | ForEach-Object { Write-Host "  $_" }
} finally {
    Remove-Item $probe -ErrorAction SilentlyContinue
}
Write-Host 'Verify complete.' -ForegroundColor Green
