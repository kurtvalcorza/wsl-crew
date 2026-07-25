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
    $out = & wsl.exe -d $Distro -u kurt -e bash -lc '$HOME/bin/fix-ollama-baseurl' 2>&1
    $txt = ($out | Out-String).Trim()
    Write-Log "fix-ollama-baseurl output: $txt"
    if ($txt -match 'already correct') { Notify 'Local model OK' 'Ollama baseUrl was already correct.' 'Info' }
    elseif ($txt -match 'updated baseUrl') { Notify 'Local model fixed' 'baseUrl updated and gateway restarted.' 'Info' }
    elseif ($txt -match 'WARNING|ERROR') { Notify 'Local model needs attention' (($txt -split "`n" | Select-Object -First 3) -join ' ') 'Warning' }
    else { Notify 'Local model' (($txt -split "`n" | Select-Object -Last 1)) 'Info' }
  } catch { Notify 'Ollama fix error' $_.Exception.Message 'Error' }
}

# ---------- status ----------
function Show-Status {
  $lines = @()

  $gw = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 10 "http://localhost:${Port}/" 2>&1)
  $lines += if ($gw -eq '200') { 'Gateway      : OK' } else { "Gateway      : DOWN (http $gw)" }

  $lan = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 12 "http://${LanIp}:${Port}/" 2>&1)
  $lines += if ($lan -eq '200') { 'LAN access   : OK' } else { "LAN access   : BROKEN (http $lan) - run Fix LAN access" }

  $ver = & wsl.exe -d $Distro -u kurt -e bash -lc 'curl -s --max-time 6 http://$(ip route show default | sed -n "s/.*via \([0-9.]*\).*/\1/p" | head -n1):11434/api/version' 2>&1
  $lines += if (($ver | Out-String) -match '"version"') { 'Local model  : OK' } else { 'Local model  : UNREACHABLE - run Fix local model' }

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
