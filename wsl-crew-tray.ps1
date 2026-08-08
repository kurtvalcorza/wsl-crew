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

# Returns the running-distro list as one lowercase string, safe to -match against.
#
# wsl.exe emits UTF-16LE. Windows PowerShell 5.1 -- which is what launchers\wsl-crew-tray.vbs
# starts this app with -- decodes that as NUL-interleaved text, so "kirocrew" arrives as
# "k`0i`0r`0o`0c`0r`0e`0w" and a naive -match NEVER fires. That silently made the guard in
# Repair-KiroCrew always believe the distro was down, so every click spawned another redundant
# `sleep infinity` keepalive. Stripping NULs is a no-op if the output ever arrives clean.
function Get-RunningDistros {
  try {
    $raw = (& wsl.exe --list --running 2>&1) -join ' '
    return ($raw -replace "`0", '').ToLowerInvariant()
  } catch {
    Write-Log "Get-RunningDistros error: $($_.Exception.Message)"
    return ''
  }
}

function Test-DistroRunning($DistroName) {
  return (Get-RunningDistros) -match [regex]::Escape($DistroName.ToLowerInvariant())
}

# Working set of the shared WSL2 utility VM, in MB, or $null if the VM is down.
# All distros share ONE vmmemWSL process, so this is a whole-VM figure -- terminating one
# distro of several will not drop it to zero.
function Get-VmmemMB {
  $p = Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue
  if (-not $p) { return $null }
  return [math]::Round((($p | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB, 0)
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
    if (-not (Test-DistroRunning $KiroCrewDistro)) {
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

# ---------- job 6: stop a distro ----------
# Frees the memory a keepalive is deliberately holding. Confirms first: this kills the
# distro's gateway, and the Startup keepalive does NOT come back on its own -- it only runs
# at logon, so the distro stays down until you re-run the .vbs or log back in.
function Stop-CrewDistro {
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$Label
  )

  if (-not (Test-DistroRunning $DistroName)) {
    Notify $Label "'$DistroName' is not running - nothing to stop." 'Info'
    return
  }

  $answer = [System.Windows.Forms.MessageBox]::Show(
    ("Stop the '$DistroName' distro?" + "`r`n`r`n" +
     "This kills its gateway and any keepalive holding it open." + "`r`n`r`n" +
     "It will NOT restart by itself - the keepalive only runs at logon. To bring it back, " +
     "re-run its .vbs in launchers\ or log out and back in."),
    "WSL Crew - Stop $Label",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)

  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
    Write-Log "Stop $DistroName - cancelled at confirmation"
    return
  }

  $before = Get-VmmemMB
  Notify $Label "Stopping '$DistroName'..." 'Info'
  try {
    & wsl.exe --terminate $DistroName 2>&1 | Out-Null

    # Give WSL a moment to tear the session down before re-checking. This reports the VM's
    # CURRENT working set, not "memory freed" -- with other distros still up, the shared VM
    # stays resident and only gives pages back as autoMemoryReclaim gets to them.
    Start-Sleep -Seconds 3

    if (Test-DistroRunning $DistroName) {
      Notify "$Label still running" "'$DistroName' did not stop. Something may be re-launching it." 'Warning'
      Write-Log "Stop $DistroName - FAILED, still in running list"
      return
    }

    $after = Get-VmmemMB
    if ($null -eq $after) {
      $msg = 'stopped. No distros left - the WSL VM shut down, all of its memory is back.'
    } elseif ($null -ne $before) {
      $msg = "stopped. vmmemWSL now ${after} MB (was ${before} MB); other distros still running."
    } else {
      $msg = "stopped. vmmemWSL now ${after} MB."
    }
    Notify "$Label stopped" "'$DistroName' $msg" 'Info'
    Write-Log "Stop $DistroName - OK; vmmemWSL before=$before MB after=$after MB"
  } catch {
    Notify "$Label stop error" $_.Exception.Message 'Error'
    Write-Log "Stop $DistroName - error: $($_.Exception.Message)"
  }
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

# Stop distro -- submenu, one entry per supervised distro. Labels are refreshed on open
# (see $menu.Add_Opening below) so you can see what is actually running before clicking.
$miStop = New-Object System.Windows.Forms.ToolStripMenuItem('Stop distro')
$miStopClaw = New-Object System.Windows.Forms.ToolStripMenuItem("OpenClaw ($OpenClawDistro)")
$miStopClaw.Add_Click({ Stop-CrewDistro -DistroName $OpenClawDistro -Label 'OpenClaw' })
$miStopKiro = New-Object System.Windows.Forms.ToolStripMenuItem("KiroCrew ($KiroCrewDistro)")
$miStopKiro.Add_Click({ Stop-CrewDistro -DistroName $KiroCrewDistro -Label 'KiroCrew' })
[void]$miStop.DropDownItems.Add($miStopClaw)
[void]$miStop.DropDownItems.Add($miStopKiro)
[void]$menu.Items.Add($miStop)

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

# One `wsl --list --running` per menu open (not a background poll -- the app stays idle-free),
# so the Stop entries show live state and grey out when there is nothing to stop.
$menu.Add_Opening({
  try {
    $running = Get-RunningDistros
    foreach ($pair in @(@($miStopClaw, $OpenClawDistro, 'OpenClaw'), @($miStopKiro, $KiroCrewDistro, 'KiroCrew'))) {
      $item = $pair[0]; $name = $pair[1]; $label = $pair[2]
      $isUp = $running -match [regex]::Escape($name.ToLowerInvariant())
      $item.Text    = if ($isUp) { "$label ($name) - running" } else { "$label ($name) - stopped" }
      $item.Enabled = $isUp
    }
    $miStop.Enabled = $miStopClaw.Enabled -or $miStopKiro.Enabled
  } catch {
    # Never let a probe failure block the menu from opening.
    $miStop.Enabled = $true
    $miStopClaw.Enabled = $true
    $miStopKiro.Enabled = $true
    Write-Log "menu Opening probe error: $($_.Exception.Message)"
  }
})

$icon.Add_MouseDoubleClick({ Show-Status })

Notify 'WSL Crew running' 'Right-click the tray icon for repairs.' 'Info'
[System.Windows.Forms.Application]::Run()
