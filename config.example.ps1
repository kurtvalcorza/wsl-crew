# WSL Crew - local configuration
# Copy this file to config.local.ps1 and fill in your values.
# config.local.ps1 is gitignored and never committed.

# --- Paths ---
$WslCrewRoot = 'C:\Users\YOUR_USER\Projects\wsl-crew'  # where this repo lives

# --- Network ---
$LanIp   = '192.168.0.100'       # your machine's LAN IP (for phone pairing portproxy)
$Subnet  = '192.168.0.0/24'      # local subnet to scope firewall rules
$WslSubnet = '172.30.32.0/20'    # vEthernet (WSL) subnet — find with: Get-NetIPAddress -InterfaceAlias 'vEthernet (WSL)'

# --- Tailscale (remote access) ---
$TailscaleName = 'your-machine.tail000000.ts.net'  # your Tailscale MagicDNS hostname
$TailscaleExe  = 'C:\Program Files\Tailscale\tailscale.exe'

# --- OpenClaw distro ---
$OpenClawDistro = 'openclaw'     # WSL distro name
$OpenClawUser   = 'kurt'         # Linux username inside the distro
$OpenClawPort   = 18789          # gateway port

# --- KiroCrew distro ---
$KiroCrewDistro = 'kirocrew'     # WSL distro name
$KiroCrewUser   = 'kurt'         # Linux username inside the distro
$KiroCrewPort   = 5476           # gateway port
$KiroCrewUid    = 1001           # Linux UID (for XDG_RUNTIME_DIR)
