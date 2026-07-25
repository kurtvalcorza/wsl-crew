# Restores/verifies REMOTE (away-from-home) access to the OpenClaw gateway over Tailscale.
# No admin needed. Serve config normally persists across reboots; re-run this if remote access breaks.
#
# How it works: `tailscale serve` on the WINDOWS host terminates TLS with a real cert for
# kurt-valcorza.tail639057.ts.net and proxies to http://localhost:18789, which reaches the
# gateway inside the "openclaw" WSL distro via WSL2 localhostForwarding.
#
# NOTE: we deliberately do NOT portproxy raw 18789 onto the tailnet -- that was plaintext
# exposure and was removed on 2026-07-25. TLS via Serve replaces it.
# Pairing URL for the phone: wss://kurt-valcorza.tail639057.ts.net
$ErrorActionPreference = 'Continue'
$ts   = 'C:\Program Files\Tailscale\tailscale.exe'
$name = 'kurt-valcorza.tail639057.ts.net'

Write-Host '== keepalive: is the openclaw distro up? =='
# The Startup-folder keepalive (openclaw-keepalive.vbs) should already hold it open.
$running = (& wsl.exe --list --running) -join ' '
if ($running -notmatch 'openclaw') {
  Write-Host 'openclaw not running -- launching keepalive now'
  $vbs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\openclaw-keepalive.vbs'
  if (Test-Path $vbs) { Start-Process wscript.exe -ArgumentList "`"$vbs`"" -WindowStyle Hidden; Start-Sleep -Seconds 20 }
} else { Write-Host 'openclaw distro is running.' }

Write-Host '== ensure the gateway is listening inside WSL =='
& wsl.exe -d openclaw -u kurt -e bash -lc 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user start openclaw-gateway.service 2>/dev/null; sleep 16; ss -ltn | grep 18789 || echo "NOT listening"'

Write-Host '== (re)apply tailscale serve on 443 =='
& $ts serve --bg --https=443 http://localhost:18789
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
