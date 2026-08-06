# WSL Crew

A Windows system tray app that keeps your WSL2-hosted services alive and gives you one-click repairs when things break.

If you run long-lived services (AI gateways, dev servers, databases) inside WSL2 distros, you've hit these problems:

- WSL shuts down your distro when it's "idle" — killing your services
- The distro's IP changes on every reboot — breaking portproxy rules and config that pins an IP
- You forget which command fixes what, and end up Googling the same thing every time

WSL Crew solves all three with a tray icon that stays out of your way until you need it.

## What you get

Right-click the tray icon:

| Menu item | What it does |
| --- | --- |
| **Open KiroCrew dashboard** | Generates a fresh auth token and opens the browser |
| **Open OpenClaw dashboard** | Opens the local gateway URL |
| **Restart KiroCrew gateway** | Starts the distro if needed, restarts the systemd service, verifies health |
| **Fix LAN access (admin)** | Updates the portproxy rule to the distro's current IP |
| **Fix local model (Ollama)** | Re-points your service's Ollama config at the current host IP |
| **Check status** | Probes all services and shows a summary |

Double-click the icon for a quick status check.

## Requirements

- Windows 10/11 with WSL2 and systemd enabled
- PowerShell 5.1+ (ships with Windows)
- One or more WSL2 distros running services you want supervised
- `curl.exe` on PATH (ships with Windows 10 1803+)

## Installation

### 1. Clone and configure

```powershell
git clone https://github.com/kurtvalcorza/wsl-crew.git
cd wsl-crew

# Create your local config from the template
Copy-Item config.example.ps1 config.local.ps1
```

Open `config.local.ps1` and fill in your values — IPs, distro names, usernames, ports. Every field has a comment explaining what it's for.

### 2. Edit the VBS launchers

The `.vbs` files in `launchers/` contain hardcoded paths (VBScript has no `$PSScriptRoot`). Open each one and update:

- **`wsl-crew-tray.vbs`** — set the path to where you cloned the repo
- **`openclaw-keepalive.vbs`** — set your distro name and username
- **`kirocrew-keepalive.vbs`** — set your distro name and username

### 3. Install to Startup folder

Copy the launchers so they run at logon:

```powershell
$startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
Copy-Item launchers\wsl-crew-tray.vbs     $startup
Copy-Item launchers\openclaw-keepalive.vbs $startup
Copy-Item launchers\kirocrew-keepalive.vbs $startup
```

Only copy the keepalives for distros you actually use.

### 4. Install the systemd service (per distro)

For each distro that needs a supervised gateway:

```bash
# Inside the WSL distro
mkdir -p ~/.config/systemd/user
cp kirocrew-gateway.service ~/.config/systemd/user/

# Edit the .service file: update paths and UID to match your setup
nano ~/.config/systemd/user/kirocrew-gateway.service

# Enable and start
systemctl --user daemon-reload
systemctl --user enable kirocrew-gateway.service
systemctl --user start kirocrew-gateway.service

# Enable linger so services survive logout
loginctl enable-linger $USER
```

### 5. Launch

Either reboot (the Startup folder will handle it) or run manually:

```powershell
wscript.exe launchers\wsl-crew-tray.vbs
```

## How it works

Three layers keep your services alive:

| Layer | Mechanism | What it prevents |
| --- | --- | --- |
| **Keepalive** | `wsl.exe --exec /bin/sleep infinity` | WSL idle-shutdown of the VM |
| **systemd + linger** | User service with `Restart=on-failure` | Gateway crashes |
| **Tray app** | Manual restart + status checks | Everything else |

The tray app itself is pure PowerShell + WinForms — no build step, no dependencies, no admin rights (except the LAN proxy fix which needs to modify portproxy rules).

## Configuration

All personal values live in `config.local.ps1` (gitignored). The repo ships `config.example.ps1` with documented placeholders.

Every script dot-sources `config.local.ps1` on startup. If the file is missing, the tray app shows an error and exits.

### Config variables

| Variable | Example | Used by |
| --- | --- | --- |
| `$WslCrewRoot` | `C:\Users\you\Projects\wsl-crew` | Log file paths |
| `$LanIp` | `192.168.0.100` | LAN portproxy, status check |
| `$Subnet` | `192.168.0.0/24` | Firewall rule scoping |
| `$WslSubnet` | `172.30.32.0/20` | Ollama firewall rule |
| `$TailscaleName` | `my-machine.tail000000.ts.net` | Remote access setup |
| `$TailscaleExe` | `C:\Program Files\Tailscale\tailscale.exe` | Remote access setup |
| `$OpenClawDistro` | `openclaw` | All OpenClaw operations |
| `$OpenClawUser` | `kurt` | WSL commands |
| `$OpenClawPort` | `18789` | Health checks, portproxy |
| `$KiroCrewDistro` | `kirocrew` | All KiroCrew operations |
| `$KiroCrewUser` | `kurt` | WSL commands |
| `$KiroCrewPort` | `5476` | Health checks, dashboard |
| `$KiroCrewUid` | `1001` | XDG_RUNTIME_DIR for systemctl |

## File layout

```
wsl-crew-tray.ps1               Main tray app
config.example.ps1              Template config (committed)
config.local.ps1                Your real config (gitignored)
openclaw-lan-proxy.ps1          Portproxy bridge (requires admin)
openclaw-remote-serve.ps1       Tailscale Serve setup for remote access
ollama-expose-to-wsl.ps1        Firewall rule for Ollama (requires admin, one-time)
kirocrew-gateway.service        Systemd unit file (copy into distro)
distro/
  fix-ollama-baseurl            Bash script — patches Ollama baseUrl inside distro
  ollama-probe                  Bash script — probes host Ollama from inside distro
launchers/
  wsl-crew-tray.vbs             Starts tray app hidden at logon
  openclaw-keepalive.vbs        Holds openclaw distro open
  kirocrew-keepalive.vbs        Holds kirocrew distro open
```

## Troubleshooting

**Tray icon doesn't appear after logon**
- Check that `wsl-crew-tray.vbs` is in your Startup folder and the path inside it is correct
- Run the script manually to see errors: `powershell -File wsl-crew-tray.ps1`

**"config.local.ps1 not found" error**
- Copy `config.example.ps1` to `config.local.ps1` and fill in your values

**Gateway shows DOWN in status but the service is running**
- The gateway may still be starting (takes 10-15s to bind). Wait and check again.
- If using KiroCrew: make sure the systemd service has `WorkingDirectory` set to a native Linux path, not `/mnt/c/...`. The sandbox probe hangs on drvfs filesystems.

**LAN access fix doesn't work**
- The `iphlpsvc` (IP Helper) Windows service must be running, or `netsh portproxy` silently does nothing
- Verify the distro is actually listening: `wsl -d <distro> -- ss -tlnp | grep <port>`

**Ollama unreachable from WSL**
- Ollama must be started with `OLLAMA_HOST=0.0.0.0` (not the default `127.0.0.1`)
- The firewall rule from `ollama-expose-to-wsl.ps1` must be in place
- Setting the env var in the registry doesn't help an already-running process — restart Ollama after setting it

## Adapting for your own services

WSL Crew is designed around two specific services, but the pattern is generic. To add a new supervised service:

1. Add its variables to `config.example.ps1` and your `config.local.ps1`
2. Create a `.service` unit file (use `kirocrew-gateway.service` as a template)
3. Add a keepalive VBS if it runs in a separate distro
4. Add `Test-YourService` and `Repair-YourService` functions to the tray script
5. Wire them into the menu and status check

## License

MIT. Built with AI.
