# OpenClaw Helper - system tray app with exactly two repair jobs:
#   1. Fix LAN access   -> re-points the Windows portproxy at the current WSL NAT IP (needs admin)
#   2. Fix local model  -> re-points OpenClaw's ollama provider at the current host IP
# Plus a status check and exit. Launched hidden at logon by launchers\openclaw-tray.vbs.
#
# Why only these two: WSL2 uses NAT and the distro's IP changes across reboots. The Windows-side
# portproxy (LAN phone access) and OpenClaw's ollama baseUrl (local fallback model) both pin an IP,
# so both go stale. Everything else in the setup self-heals.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Continue'
$Root      = $PSScriptRoot
$LanScript = Join-Path $Root 'openclaw-lan-proxy.ps1'
$LogPath   = Join-Path $Root 'tray.log'
$LanIp     = '192.168.0.212'
$Distro    = 'openclaw'
$Port      = 18789

function Write-Log($msg) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Add-Content -Path $LogPath -Encoding utf8
}
Write-Log 'tray helper started'

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon    = [System.Drawing.SystemIcons]::Shield
$icon.Text    = 'OpenClaw Helper'
$icon.Visible = $true

function Notify($title, $text, $level) {
  $icon.BalloonTipTitle = $title
  $icon.BalloonTipText  = $text
  $icon.BalloonTipIcon  = $level          # Info | Warning | Error
  $icon.ShowBalloonTip(6000)
  Write-Log "$title - $text"
}

# Probes the host Ollama from inside the distro. Returns "OK <ver> via <ip>" or "FAIL <reason>".
# Calls a SCRIPT FILE in the distro on purpose: inlining the host-IP lookup here means embedded
# quotes/backslashes get mangled crossing wsl.exe and bash dies -- which read as a false
# "UNREACHABLE" in an earlier version of this app.
function Test-Ollama {
  try {
    $out = & wsl.exe -d $Distro -u kurt -e bash -lc '$HOME/bin/ollama-probe' 2>&1
    $txt = ($out | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($txt)) { return 'FAIL no-output' }
    return ($txt -split "`n" | Select-Object -Last 1).Trim()
  } catch { return "FAIL $($_.Exception.Message)" }
}

# Restarts the host Ollama with OLLAMA_HOST=0.0.0.0 so the WSL distro can reach it.
# Setting the User env var alone is not enough for an already-running app: child processes inherit
# the launching shell's environment, not the registry. So set it in-session and relaunch.
function Start-OllamaBound {
  try {
    Get-Process ollama, 'ollama app' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST','0.0.0.0','User')   # persist for next logon
    $env:OLLAMA_HOST = '0.0.0.0'                                           # and for the child we spawn
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $app)     { Start-Process $app }
    elseif (Test-Path $exe) { Start-Process $exe -ArgumentList 'serve' -WindowStyle Hidden }
    else { Write-Log 'Start-OllamaBound: no ollama executable found'; return }
    Start-Sleep -Seconds 12
    Write-Log 'Start-OllamaBound: relaunched with OLLAMA_HOST=0.0.0.0'
  } catch { Write-Log "Start-OllamaBound error: $($_.Exception.Message)" }
}

# ---------- job 1: LAN access (elevates) ----------
function Repair-Lan {
  Notify 'Fixing LAN access' 'Approve the admin prompt...' 'Info'
  try {
    $p = Start-Process powershell -Verb RunAs -PassThru -Wait `
         -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$LanScript`""
    if ($p.ExitCode -eq 0) {
      Start-Sleep -Seconds 2
      $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 12 "http://${LanIp}:${Port}/" 2>&1)
      if ($code -eq '200') { Notify 'LAN access OK' "Gateway reachable at ${LanIp}:${Port}" 'Info' }
      else { Notify 'LAN still failing' "Proxy rule set but endpoint returned $code. Is the gateway up?" 'Warning' }
    } else {
      Notify 'LAN fix cancelled' 'The admin prompt was declined or the script failed.' 'Warning'
    }
  } catch { Notify 'LAN fix error' $_.Exception.Message 'Error' }
}

# ---------- job 2: local fallback model ----------
function Repair-Ollama {
  Notify 'Fixing local model' 'Re-pointing Ollama provider...' 'Info'
  try {
    # Step 1: is the host Ollama actually serving on a WSL-reachable address?
    # A stopped Ollama -- or one bound to 127.0.0.1 -- cannot be fixed by re-pointing baseUrl.
    if ((Test-Ollama) -notmatch '^OK') {
      $listening = @(Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue)
      $loopbackOnly = ($listening.Count -gt 0) -and
                      (@($listening | Where-Object { $_.LocalAddress -in @('0.0.0.0','::') }).Count -eq 0)

      if ($listening.Count -eq 0) {
        Notify 'Starting Ollama' 'Ollama is not listening on the host - starting it.' 'Info'
        Start-OllamaBound
      } elseif ($loopbackOnly) {
        Notify 'Rebinding Ollama' 'Ollama is bound to 127.0.0.1 only - restarting it so WSL can reach it.' 'Info'
        Start-OllamaBound
      }
    }

    # Step 2: repair a drifted host IP in OpenClaw's config (no-op if unchanged).
    $out = & wsl.exe -d $Distro -u kurt -e bash -lc '$HOME/bin/fix-ollama-baseurl' 2>&1
    $txt = ($out | Out-String).Trim()
    Write-Log "fix-ollama-baseurl output: $txt"

    # Step 3: report what is ACTUALLY true now, not what step 2 printed.
    $probe = Test-Ollama
    if ($probe -match '^OK') {
      if ($txt -match 'updated baseUrl') { Notify 'Local model fixed' "baseUrl updated, gateway restarted. $probe" 'Info' }
      else { Notify 'Local model OK' $probe 'Info' }
    } else {
      Notify 'Local model still unreachable' "$probe -- check that Ollama is running on Windows and OLLAMA_HOST=0.0.0.0" 'Warning'
    }
  } catch { Notify 'Ollama fix error' $_.Exception.Message 'Error' }
}

# ---------- status ----------
function Show-Status {
  $lines = @()

  $gw = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 10 "http://localhost:${Port}/" 2>&1)
  $lines += if ($gw -eq '200') { 'Gateway      : OK' } else { "Gateway      : DOWN (http $gw)" }

  $lan = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 12 "http://${LanIp}:${Port}/" 2>&1)
  $lines += if ($lan -eq '200') { 'LAN access   : OK' } else { "LAN access   : BROKEN (http $lan) - run Fix LAN access" }

  $probe = Test-Ollama
  $lines += if ($probe -match '^OK') { "Local model  : OK ($probe)" } else { "Local model  : UNREACHABLE ($probe) - run Fix local model" }

  $body = ($lines -join "`r`n")
  Write-Log ("status: " + ($lines -join ' | '))
  [System.Windows.Forms.MessageBox]::Show($body, 'OpenClaw Helper - Status',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# ---------- menu ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miLan = $menu.Items.Add('Fix LAN access  (admin)')
$miLan.Add_Click({ Repair-Lan })

$miOllama = $menu.Items.Add('Fix local model (Ollama)')
$miOllama.Add_Click({ Repair-Ollama })

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miStatus = $menu.Items.Add('Check status')
$miStatus.Add_Click({ Show-Status })

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miExit = $menu.Items.Add('Exit')
$miExit.Add_Click({
  Write-Log 'tray helper exiting'
  $icon.Visible = $false
  $icon.Dispose()
  [System.Windows.Forms.Application]::Exit()
})

$icon.ContextMenuStrip = $menu
$icon.Add_MouseDoubleClick({ Show-Status })

Notify 'OpenClaw Helper running' 'Right-click the tray icon for repairs.' 'Info'
[System.Windows.Forms.Application]::Run()
