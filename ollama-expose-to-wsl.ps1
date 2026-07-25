#Requires -RunAsAdministrator
# Lets the "openclaw" WSL distro reach the HOST Ollama at 11434.
# Ollama defaults to 127.0.0.1 which WSL cannot reach, so we bind 0.0.0.0 -- but the firewall
# rule below scopes inbound 11434 to the WSL subnet ONLY, so it is NOT exposed to the LAN.
$ErrorActionPreference = 'Continue'
$Port      = 11434
$WslSubnet = '172.30.32.0/20'   # vEthernet (WSL) network
$LogPath   = 'C:\Users\Kurt Valcorza\WSL\openclaw\ollama-expose-last-run.log'

function Log($m) { Write-Host $m; Add-Content -Path $LogPath -Value $m }
Set-Content -Path $LogPath -Value "Ollama expose-to-WSL run $(Get-Date -Format o)"

Log '== firewall: allow 11434 from the WSL subnet only =='
$rule = 'Ollama for OpenClaw WSL (11434)'
Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort $Port -RemoteAddress $WslSubnet | Out-Null
Log "firewall rule set: inbound TCP $Port from $WslSubnet"

Log '== rule summary =='
Get-NetFirewallRule -DisplayName $rule |
  ForEach-Object { Log ("  {0} [enabled={1}] action={2}" -f $_.DisplayName, $_.Enabled, $_.Action) }
(Get-NetFirewallRule -DisplayName $rule | Get-NetFirewallAddressFilter) |
  ForEach-Object { Log ("  remote scope: {0}" -f $_.RemoteAddress) }

Log 'DONE (env var + Ollama restart handled separately, no admin needed)'
