#Requires -RunAsAdministrator
# Bridges the host LAN IP to the openclaw WSL distro's OpenClaw gateway, for same-Wi-Fi phone pairing.
# Re-run after a reboot / WSL restart because the distro's NAT IP changes.
$ErrorActionPreference = 'Stop'
$LanIP   = '192.168.0.212'
$Subnet  = '192.168.0.0/24'
$Port    = 18789
$Distro  = 'openclaw'
$LogPath = "$PSScriptRoot\lan-proxy-last-run.log"

function Log($m) { Write-Host $m; Add-Content -Path $LogPath -Value $m }
Set-Content -Path $LogPath -Value "OpenClaw LAN-proxy run $(Get-Date -Format o)"

$wslIp = (& wsl.exe -d $Distro -e bash -lc 'hostname -I').Trim().Split(' ')[0]
if (-not $wslIp) { Log 'ERROR: could not resolve openclaw WSL IP'; exit 1 }
Log "openclaw WSL IP : $wslIp"
Log "listen endpoint : $LanIP`:$Port  ->  $wslIp`:$Port"

& netsh interface portproxy delete v4tov4 listenaddress=$LanIP listenport=$Port 2>$null | Out-Null
& netsh interface portproxy add    v4tov4 listenaddress=$LanIP listenport=$Port connectaddress=$wslIp connectport=$Port
Log 'portproxy rule set.'

# Firewall: allow inbound 18789 only from the local subnet (not the whole internet)
$rule = 'OpenClaw Gateway (LAN 18789)'
Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress $Subnet | Out-Null
Log "firewall rule set (inbound TCP $Port from $Subnet)."

Log '--- current portproxy table ---'
(& netsh interface portproxy show v4tov4) | ForEach-Object { Log $_ }
Log 'DONE'
