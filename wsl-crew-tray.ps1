# WSL Crew - system tray app with repair jobs for WSL-hosted AI services.
# Launched hidden at logon by launchers\wsl-crew-tray.vbs.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot

# Load local config (gitignored — contains real IPs, usernames, paths)
$ConfigPath = Join-Path $Root 'config.local.ps1'
if (-not (Test-Path $ConfigPath)) {
  [System.Windows.Forms.MessageBox]::Show(
    "config.local.ps1 not found.`nCopy config.example.ps1 to config.local.ps1 and fill in your values.",
    'WSL Crew', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  exit 1
}
. $ConfigPath

$LanScript = Join-Path $Root 'openclaw-lan-proxy.ps1'
$LogPath   = Join-Path $Root 'tray.log'
$Distro    = $OpenClawDistro
$Port      = $OpenClawPort

function Write-Log($msg) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Add-Content -Path $LogPath -Encoding utf8
}
Write-Log 'WSL Crew started'

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon    = [System.Drawing.SystemIcons]::Asterisk
$icon.Text    = 'WSL Crew'
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
    $out = & wsl.exe -d $Distro -u $OpenClawUser -e bash -lc '$HOME/bin/ollama-probe' 2>&1
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
    $out = & wsl.exe -d $Distro -u $OpenClawUser -e bash -lc '$HOME/bin/fix-ollama-baseurl' 2>&1
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

  $kiro = Test-KiroCrew
  $lines += if ($kiro -eq 'OK') { "KiroCrew     : OK (port $KiroCrewPort)" } else { "KiroCrew     : $kiro - run Restart KiroCrew gateway" }

  $body = ($lines -join "`r`n")
  Write-Log ("status: " + ($lines -join ' | '))
  [System.Windows.Forms.MessageBox]::Show($body, 'WSL Crew - Status',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# ---------- job 3: KiroCrew gateway ----------
function Test-KiroCrew {
  try {
    $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 8 "http://127.0.0.1:${KiroCrewPort}/api/health" 2>&1
    if ($code -eq '200') { return 'OK' }
    return "DOWN (http $code)"
  } catch { return "DOWN ($($_.Exception.Message))" }
}

function Repair-KiroCrew {
  Notify 'KiroCrew' 'Checking gateway...' 'Info'
  try {
    # Ensure distro is running
    $running = (& wsl.exe --list --running) -join ' '
    if ($running -notmatch $KiroCrewDistro) {
      Write-Log 'KiroCrew distro not running - launching keepalive'
      Start-Process wsl.exe -ArgumentList "-d $KiroCrewDistro -u $KiroCrewUser --exec /bin/sleep infinity" -WindowStyle Hidden
      Start-Sleep -Seconds 5
    }
    # Restart the systemd user service (sets CWD to native path, avoids drvfs sandbox hang)
    & wsl.exe -d $KiroCrewDistro -u $KiroCrewUser -e bash -c "export XDG_RUNTIME_DIR=/run/user/$KiroCrewUid; rm -f /home/$KiroCrewUser/.kiro/crew/gateway.lock; systemctl --user restart kirocrew-gateway.service" 2>&1 | Out-Null
    Start-Sleep -Seconds 12
    $probe = Test-KiroCrew
    if ($probe -eq 'OK') { Notify 'KiroCrew OK' "Gateway listening on port $KiroCrewPort" 'Info' }
    else { Notify 'KiroCrew still down' $probe 'Warning' }
  } catch { Notify 'KiroCrew error' $_.Exception.Message 'Error' }
}

# ---------- job 4: Open KiroCrew dashboard ----------
function Open-KiroCrewDashboard {
  Notify 'KiroCrew' 'Opening dashboard...' 'Info'
  try {
    $probe = Test-KiroCrew
    if ($probe -ne 'OK') {
      Notify 'KiroCrew' 'Gateway is down - starting it first...' 'Info'
      Repair-KiroCrew
      $probe = Test-KiroCrew
      if ($probe -ne 'OK') { Notify 'KiroCrew' 'Could not start gateway' 'Warning'; return }
    }
    $tokenOut = & wsl.exe -d $KiroCrewDistro -u $KiroCrewUser -e bash -c "export XDG_RUNTIME_DIR=/run/user/$KiroCrewUid; /home/$KiroCrewUser/.local/bin/kirocrew token --ttl 1h" 2>&1
    $url = ($tokenOut | Out-String) -replace '(?s).*?(http://localhost[^\s]+).*','$1'
    if ($url -match '^http') {
      Start-Process $url.Trim()
      Write-Log "Opened KiroCrew dashboard"
    } else {
      Notify 'KiroCrew' 'Could not generate token' 'Warning'
      Write-Log "token output: $tokenOut"
    }
  } catch { Notify 'KiroCrew error' $_.Exception.Message 'Error' }
}

# ---------- job 5: Open OpenClaw dashboard ----------
function Open-OpenClawDashboard {
  Notify 'OpenClaw' 'Opening dashboard...' 'Info'
  try {
    $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 10 "http://localhost:${Port}/" 2>&1
    if ($code -ne '200') {
      Notify 'OpenClaw' 'Gateway is not running' 'Warning'
      return
    }
    Start-Process "http://localhost:${Port}/"
    Write-Log "Opened OpenClaw dashboard"
  } catch { Notify 'OpenClaw error' $_.Exception.Message 'Error' }
}

# ---------- menu ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miOpenKiro = $menu.Items.Add('Open KiroCrew dashboard')
$miOpenKiro.Add_Click({ Open-KiroCrewDashboard })

$miOpenClaw = $menu.Items.Add('Open OpenClaw dashboard')
$miOpenClaw.Add_Click({ Open-OpenClawDashboard })

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miKiro = $menu.Items.Add('Restart KiroCrew gateway')
$miKiro.Add_Click({ Repair-KiroCrew })

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

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
  Write-Log 'WSL Crew exiting'
  $icon.Visible = $false
  $icon.Dispose()
  [System.Windows.Forms.Application]::Exit()
})

$icon.ContextMenuStrip = $menu
$icon.Add_MouseDoubleClick({ Show-Status })

Notify 'WSL Crew running' 'Right-click the tray icon for repairs.' 'Info'
[System.Windows.Forms.Application]::Run()
