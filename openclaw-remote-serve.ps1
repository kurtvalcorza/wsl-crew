# Restores/verifies REMOTE (away-from-home) access to the OpenClaw gateway over Tailscale.
# No admin needed. Serve config normally persists across reboots; re-run this if remote access breaks.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'config.local.ps1')

$ts   = $TailscaleExe
$name = $TailscaleName
$Port = $OpenClawPort
$Distro = $OpenClawDistro
$User   = $OpenClawUser

Write-Host '== keepalive: is the openclaw distro up? =='
# The Startup-folder keepalive (openclaw-keepalive.vbs) should already hold it open.
$running = (& wsl.exe --list --running) -join ' '
if ($running -notmatch $Distro) {
  Write-Host "$Distro not running -- launching keepalive now"
  $vbs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\openclaw-keepalive.vbs'
  if (Test-Path $vbs) { Start-Process wscript.exe -ArgumentList "`"$vbs`"" -WindowStyle Hidden; Start-Sleep -Seconds 20 }
} else { Write-Host "$Distro distro is running." }

Write-Host '== ensure the gateway is listening inside WSL =='
& wsl.exe -d $Distro -u $User -e bash -lc "export XDG_RUNTIME_DIR=/run/user/`$(id -u); systemctl --user start openclaw-gateway.service 2>/dev/null; sleep 16; ss -ltn | grep $Port || echo `"NOT listening`""

Write-Host '== (re)apply tailscale serve on 443 =='
& $ts serve --bg --https=443 "http://localhost:$Port"
& $ts serve status

Write-Host '== verify (first request may return 000 while the cert provisions -- retry) =='
& curl.exe -s -o NUL -w "https=%{http_code}`n" --max-time 25 "https://$name/"
& curl.exe -s -o NUL -w "ws_upgrade=%{http_code} (want 101)`n" --max-time 25 `
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' `
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$name/"

Write-Host ''
Write-Host "Phone pairing URL : wss://$name"
Write-Host 'New setup code    : wsl -d openclaw -- openclaw qr --public-url wss://' -NoNewline; Write-Host $name
Write-Host 'Disable remote    : tailscale serve --https=443 off'
