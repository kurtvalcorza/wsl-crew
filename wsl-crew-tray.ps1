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

# Runs wsl.exe and returns its stdout correctly decoded, plus a real exit code.
# Returns $null if the process could not be started at all.
#
# Deleting NUL bytes from the misdecoded output is an ASCII-ONLY reconstruction and was
# wrong: for a distro named "dev-<CJK>", the UTF-16LE bytes 8B 95 7A 76 do not survive being
# read as single bytes -- verified, they come back as U+FFFD U+FFFD 'z' 'v', so the name can
# never be matched, and such a distro could be neither shown as running nor stopped from the
# menu. The bytes must be decoded, not repaired.
#
# stdout is captured through Latin-1, which maps bytes 1:1 onto U+0000-U+00FF and so hands
# the raw bytes back intact, letting the real encoding be chosen here. WSL_UTF8 is forced on
# so the encoding does not depend on whatever the user happens to have in their environment,
# and the NUL sniff still covers a WSL old enough to ignore that variable and emit UTF-16LE.
function Invoke-WslCapture {
  param([Parameter(Mandatory)][string]$ArgLine)
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'wsl.exe'
    $psi.Arguments              = $ArgLine
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(28591)  # Latin-1
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    [void]$psi.EnvironmentVariables.Remove('WSL_UTF8')
    [void]$psi.EnvironmentVariables.Add('WSL_UTF8', '1')

    $proc = [System.Diagnostics.Process]::Start($psi)
    $rawChars = $proc.StandardOutput.ReadToEnd()
    [void]$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $bytes = New-Object byte[] $rawChars.Length
    for ($i = 0; $i -lt $rawChars.Length; $i++) { $bytes[$i] = [byte][int]$rawChars[$i] }

    # A UTF-16LE payload of mostly-ASCII text is roughly half NUL bytes; UTF-8 has none.
    $zeros = 0; foreach ($b in $bytes) { if ($b -eq 0) { $zeros++ } }
    $enc = if ($bytes.Length -gt 0 -and $zeros -gt 0) { [System.Text.Encoding]::Unicode }
           else { [System.Text.Encoding]::UTF8 }

    return [pscustomobject]@{
      Text     = $enc.GetString($bytes).TrimStart([char]0xFEFF)   # drop any BOM
      ExitCode = $proc.ExitCode
    }
  } catch {
    Write-Log "Invoke-WslCapture failed for '$ArgLine': $($_.Exception.Message)"
    return $null
  }
}

# Returns an ARRAY of exact running-distro names, or $null if the probe itself failed.
# $null and @() are deliberately different: @() means "nothing is running", $null means "we
# do not know". No caller may collapse the second into the first -- doing so is what let a
# stopped distro read as "unknown", and what let a failed probe restart one.
#
# Encoding and exit-code handling both live in Invoke-WslCapture above. What remains here:
# names are returned verbatim and compared with -eq by callers, never by substring, because
# `rancher-desktop` would otherwise read as running whenever only `rancher-desktop-data` is.
function Get-RunningDistros {
  $res = Invoke-WslCapture '--list --running --quiet'
  if ($null -eq $res) { return $null }
  if ($res.ExitCode -ne 0) {
    Write-Log "Get-RunningDistros: wsl.exe exited $($res.ExitCode)"
    return $null
  }
  $raw = $res.Text
  # The unary comma is load-bearing. `return @(...)` enumerates into the pipeline, so an
  # EMPTY array arrives at the caller as $null -- which would collapse "nothing is running"
  # back into "unknown" and defeat the whole tristate below. Verified with zero distros up:
  # `return @()` gives $null, `return ,@()` gives a real 0-count array.
  return ,@($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# True when a `sleep infinity` keepalive already holds this distro open.
# Asks the question the caller actually cares about -- does a keepalive exist -- by looking
# at process command lines directly, so it stays correct even when the running-list probe
# fails. The trailing space in the pattern keeps `-d rancher-desktop ` from matching
# `-d rancher-desktop-data `.
function Test-KeepaliveRunning($DistroName) {
  try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction Stop |
               Where-Object { $_.CommandLine -and
                              $_.CommandLine -like "*-d $DistroName *" -and
                              $_.CommandLine -like '*sleep infinity*' })
    return ($procs.Count -gt 0)
  } catch {
    Write-Log "Test-KeepaliveRunning error: $($_.Exception.Message)"
    return $false
  }
}

# $true (running), $false (not running), or $null (could not determine).
# Exact, case-insensitive name comparison -- see trap 3 above.
function Test-DistroRunning($DistroName) {
  $running = Get-RunningDistros
  if ($null -eq $running) { return $null }
  foreach ($d in $running) { if ($d -eq $DistroName) { return $true } }
  return $false
}

# Working set of the shared WSL2 utility VM. Every distro shares ONE process, so this is a
# whole-VM figure -- terminating one distro of several will not drop it to zero.
# Returns $null when no candidate process exists, otherwise an object with:
#   MB    - working set in MB
#   Exact - $true when the figure came from vmmemWSL, and so is unambiguously WSL's
# Windows 11 names the process vmmemWSL; Windows 10, which the README still lists as
# supported, names it vmmem. A bare `vmmem` may belong to some OTHER Hyper-V VM (Windows
# Sandbox, WSA, a Docker VM), so a figure taken from it is reported as approximate rather
# than presented as WSL's own.
function Get-VmmemInfo {
  $exact = $true
  $p = Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue
  if (-not $p) { $exact = $false; $p = Get-Process -Name 'vmmem' -ErrorAction SilentlyContinue }
  if (-not $p) { return $null }
  return [pscustomobject]@{
    MB    = [math]::Round((($p | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB, 0)
    Exact = $exact
  }
}

# Probes the host Ollama from inside the distro. Returns "OK <ver> via <ip>" or "FAIL <reason>".
# Calls a SCRIPT FILE in the distro on purpose: inlining the host-IP lookup here means embedded
# quotes/backslashes get mangled crossing wsl.exe and bash dies -- which read as a false
# "UNREACHABLE" in an earlier version of this app.
function Test-Ollama {
  # `wsl -d <distro> ...` STARTS a stopped distro as a side effect. A read-only status check
  # must not resurrect one the user deliberately stopped via Stop distro, so bail out first.
  #
  # Probe ONLY on a definite $true. An earlier version skipped only on a definite $false,
  # reasoning that an unknown state should still be probed for a possibly-stale answer --
  # but that left a transient probe failure able to restart a stopped distro, which is the
  # exact side effect this guard exists to prevent. For a read-only check, "I don't know"
  # is a better answer than an unrequested VM start.
  $state = Test-DistroRunning $Distro
  if ($state -ne $true) {
    return "SKIP $Distro-$(if ($null -eq $state) { 'state-unknown' } else { 'stopped' })"
  }
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
    # Note a "SKIP" from Test-Ollama (distro stopped) falls through here on purpose: unlike
    # the read-only status check, this is an explicit repair the user clicked, so step 2's
    # `wsl -d` starting the distro is the intended outcome rather than an unwanted revival.
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
  $lines += if ($probe -match '^OK') { "Local model  : OK ($probe)" }
            elseif ($probe -match 'state-unknown') { "Local model  : not checked - could not tell whether '$Distro' is running" }
            elseif ($probe -match '^SKIP') { "Local model  : not checked - '$Distro' is stopped" }
            else { "Local model  : UNREACHABLE ($probe) - run Fix local model" }

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
    # Ensure exactly one keepalive exists. Asking "is a keepalive present" rather than "is
    # the distro running" is both idempotent and correct when the running-list probe fails:
    # it never double-launches (the original bug), and never leaves the distro without one.
    # A keepalive is required even when the distro is already up -- the one-shot `wsl -d`
    # below would let WSL idle the utility VM down again once it returns, taking the gateway
    # with it, which is exactly why launchers\kirocrew-keepalive.vbs exists.
    if (-not (Test-KeepaliveRunning $KiroCrewDistro)) {
      Write-Log 'KiroCrew keepalive not present - launching'
      Start-Process wsl.exe -ArgumentList "-d $KiroCrewDistro -u $KiroCrewUser --exec /bin/sleep infinity" -WindowStyle Hidden
      Start-Sleep -Seconds 5
    } else {
      Write-Log 'KiroCrew keepalive already present - not launching another'
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

  $state = Test-DistroRunning $DistroName
  if ($state -eq $false) {
    Notify $Label "'$DistroName' is not running - nothing to stop." 'Info'
    return
  }
  if ($null -eq $state) {
    # Probe failed. Fail open to the confirmation rather than refusing: --terminate on an
    # already-stopped distro is harmless, and the user is about to be asked anyway.
    Write-Log "Stop $DistroName - running-list probe failed; continuing to confirmation"
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

  $before = Get-VmmemInfo
  Notify $Label "Stopping '$DistroName'..." 'Info'
  try {
    & wsl.exe --terminate $DistroName 2>&1 | Out-Null

    # Give WSL a moment to tear the session down before re-checking. This reports the VM's
    # CURRENT working set, not "memory freed" -- with other distros still up, the shared VM
    # stays resident and only gives pages back as autoMemoryReclaim gets to them.
    Start-Sleep -Seconds 3

    $remaining = Get-RunningDistros
    if ($null -eq $remaining) {
      Notify "$Label - unconfirmed" "Sent the stop for '$DistroName', but could not read the running list to confirm it." 'Warning'
      Write-Log "Stop $DistroName - terminate sent, post-check probe failed"
      return
    }
    if ($remaining -contains $DistroName) {
      Notify "$Label still running" "'$DistroName' did not stop. Something may be re-launching it." 'Warning'
      Write-Log "Stop $DistroName - FAILED, still in running list"
      return
    }

    # Whether the VM is gone is decided by the distro list, never by the absence of a process
    # name -- on Windows 10 the process is called vmmem, so looking only for vmmemWSL there
    # would wrongly announce that all memory had been returned while a distro was still up.
    $after = Get-VmmemInfo
    if ($remaining.Count -eq 0) {
      $msg = 'stopped. No distros left - the WSL VM is shutting down, so all of its memory comes back.'
    } elseif ($null -eq $after) {
      $msg = "stopped. $($remaining.Count) distro(s) still running."
    } else {
      $qualifier = if ($after.Exact) { 'vmmemWSL' } else { 'vmmem (approximate - may include a non-WSL VM)' }
      $was = if ($null -ne $before) { " (was $($before.MB) MB)" } else { '' }
      $msg = "stopped. $qualifier now $($after.MB) MB${was}; $($remaining.Count) distro(s) still running."
    }
    Notify "$Label stopped" "'$DistroName' $msg" 'Info'
    Write-Log ("Stop $DistroName - OK; before=" + $(if ($null -ne $before) { "$($before.MB) MB" } else { 'n/a' }) +
               " after=" + $(if ($null -ne $after) { "$($after.MB) MB" } else { 'n/a' }) +
               " remaining=$($remaining.Count)")
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
      if ($null -eq $running) {
        # Probe failed -- state unknown. Fail open so the menu stays usable rather than
        # presenting a stopped distro as authoritative fact.
        $item.Text    = "$label ($name) - state unknown"
        $item.Enabled = $true
      } else {
        $isUp = $running -contains $name
        $item.Text    = if ($isUp) { "$label ($name) - running" } else { "$label ($name) - stopped" }
        $item.Enabled = $isUp
      }
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
