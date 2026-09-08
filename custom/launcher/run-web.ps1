param(
  [Parameter(Mandatory = $true)]
  [string]$AppDir
)

# Option B helper for the launcher.
# Runs `pnpm dsh web --no-open` in the current console, captures the line dsh web
# prints with its fresh per-process token URL, then opens that exact tokenized URL
# in one dedicated Edge/Chrome --app window. The console stays attached so closing
# this window stops the server (dsh web's own process dies with it).

$ErrorActionPreference = 'Stop'

function Get-ProgramFiles([string]$suffix) {
  $v = [Environment]::GetEnvironmentVariable($suffix, 'Process')
  if (-not $v -or -not (Test-Path $v)) { return $null }
  return $v
}

# Pick a browser for the dedicated --app window, mirroring start-dsh.bat's order.
$browser = $null
$pf = Get-ProgramFiles 'ProgramFiles(x86)'
if ($pf) {
  $candidate = Join-Path $pf 'Microsoft\Edge\Application\msedge.exe'
  if (Test-Path $candidate) { $browser = $candidate }
}
if (-not $browser) {
  $pf = Get-ProgramFiles 'ProgramFiles'
  if ($pf) {
    $candidate = Join-Path $pf 'Microsoft\Edge\Application\msedge.exe'
    if (Test-Path $candidate) { $browser = $candidate }
  }
}
if (-not $browser) {
  $pf = Get-ProgramFiles 'ProgramFiles'
  if ($pf) {
    $candidate = Join-Path $pf 'Google\Chrome\Application\chrome.exe'
    if (Test-Path $candidate) { $browser = $candidate }
  }
}

# Redirect only stdout so we can read the URL line; stderr goes straight to the
# console (avoids a two-stream pipe deadlock).
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'cmd.exe'
$psi.Arguments = '/c pnpm dsh web --no-open'
$psi.WorkingDirectory = $AppDir
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $false
$psi.CreateNoWindow = $false

$proc = [System.Diagnostics.Process]::Start($psi)
$opened = $false
$urlPattern = [regex]'dsh web:\s*(https?://\S+)'

try {
  while (-not $proc.HasExited) {
    $line = $proc.StandardOutput.ReadLine()
    if ($null -eq $line) {
      # stdout closed; wait briefly for the process to actually exit
      Start-Sleep -Milliseconds 200
      continue
    }
    Write-Host $line
    if (-not $opened) {
      $m = $urlPattern.Match($line)
      if ($m.Success) {
        $url = $m.Groups[1].Value
        if ($browser) {
          Write-Host ''
          Write-Host "[launcher] Ready. Opening app window: $url"
          Write-Host "[launcher] Closing this console or the app window stops the service."
          Start-Process -FilePath $browser -ArgumentList "--app=$url"
        } else {
          Write-Host ''
          Write-Host "[launcher] Ready (no Edge/Chrome found). Copy this URL into a browser:"
          Write-Host "  $url"
        }
        $opened = $true
      }
    }
  }
  $proc.WaitForExit()
} finally {
  if (-not $proc.HasExited) { $proc.Kill() }
}
