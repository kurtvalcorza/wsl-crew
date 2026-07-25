# openclaw-helper

Windows-side support scripts for the **OpenClaw** personal AI assistant running in an isolated WSL2
distro (`openclaw`) on this machine.

OpenClaw itself is [github.com/openclaw/openclaw](https://github.com/openclaw/openclaw) — a
multi-channel personal AI assistant. This repo holds only the host-side glue: the bits that WSL's
NAT networking makes necessary, plus a tray app so the two recurring repairs are two clicks instead
of two remembered commands.

## Why anything is needed at all

WSL2 uses NAT. Two consequences:

1. **WSL cannot accept inbound connections directly** — reaching the gateway from a phone needs a
   Windows-side `netsh portproxy` bridge.
2. **The distro's IP changes across reboots** — anything that pins that IP goes stale.

Two things pin an IP, so exactly two things need occasional repair:

| What breaks | Why | Fix |
| --- | --- | --- |
| LAN phone access | portproxy points at the old WSL IP | `openclaw-lan-proxy.ps1` (admin) |
| Local fallback model | OpenClaw's `models.providers.ollama.baseUrl` points at the old host IP | `distro/fix-ollama-baseurl` |

Everything else self-heals: Tailscale Serve persists, the gateway is a systemd user service with
lingering, and the mounts are in `/etc/fstab`.

## The tray app

`openclaw-tray.ps1` — PowerShell + WinForms, no dependencies. Right-click the shield icon:

- **Fix LAN access (admin)** — runs the portproxy script elevated, then verifies the endpoint
  actually returns 200 rather than just claiming success.
- **Fix local model (Ollama)** — runs the in-distro helper, which no-ops if nothing changed.
- **Check status** — probes gateway / LAN / local model and reports all three.
- **Exit**

Double-clicking the icon shows status. Actions log to `tray.log` (gitignored).

## Files

```
openclaw-tray.ps1           tray app (the thing you actually interact with)
openclaw-lan-proxy.ps1      ADMIN. portproxy 192.168.0.212:18789 -> WSL, firewall scoped to 192.168.0.0/24
openclaw-remote-serve.ps1   restores remote access: tailscale serve --https=443 -> localhost:18789
ollama-expose-to-wsl.ps1    ADMIN. one-time: firewall allow 11434 from the WSL subnet ONLY
distro/fix-ollama-baseurl   lives at ~/bin/fix-ollama-baseurl inside the distro (copy kept here)
launchers/openclaw-tray.vbs      starts the tray app hidden at logon
launchers/openclaw-keepalive.vbs holds the distro open so the gateway survives WSL idle-shutdown
```

`launchers/*.vbs` must be **copied into** `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`
to take effect — the copies here are the versioned source.

## Setup being managed

- Distro `openclaw` (Ubuntu 24.04, user `kurt`, systemd), Node 24 + OpenClaw CLI
- Gateway: systemd **user** service, `0.0.0.0:18789`, token auth. Takes **~15 s to bind** on start
  (loads 9 plugins) — a probe inside that window looks like a crash but isn't.
- Models: primary `google/gemini-flash-latest`, fallback `ollama/qwen3:8b` on the **host** Ollama
  (needs `OLLAMA_HOST=0.0.0.0`, else it binds `127.0.0.1` and WSL cannot reach it)
- Filesystem: automount **disabled**; only `/mnt/projects` and `/mnt/obsidian` are mounted
- Access: LAN `192.168.0.212:18789`, remote `wss://kurt-valcorza.tail639057.ts.net` (TLS via
  Tailscale Serve). Raw plaintext 18789 is deliberately **not** exposed on the tailnet.

## Gotchas worth remembering

- **`Start-Process` children inherit the parent shell's environment, not the registry.** Setting
  `OLLAMA_HOST` with `SetEnvironmentVariable(...,'User')` does not affect an app launched from an
  already-running shell — set `$env:OLLAMA_HOST` in-session first, or relaunch after logon.
- **`Register-ScheduledTask` needs elevation**; the Startup folder does not. Hence the `.vbs`
  launchers.
- **Never gauge `ollama pull` progress by summing blob-directory file sizes.** In-progress chunks
  report ~0 bytes and `ollama list` stays empty until the manifest is written at the very end.
- `iphlpsvc` (IP Helper) must be running or `netsh portproxy` silently does nothing.
