# install

Public install scripts for **Equity Hammer** clients.

This repository holds the bootstrap that sets up a fresh machine for the Equity Hammer
agent stack. Everything here is public and safe to share; it contains no client data,
secrets, or internal tooling, just the one-time setup.

## Quick start - one command per platform

There is a single entry point for each world. Each one auto-detects the rest.

**Mac, or an already-open WSL/Ubuntu terminal:**

```bash
curl -fsSL https://raw.githubusercontent.com/equityhammer/install/main/install.sh | bash
```

**Windows (paste into PowerShell):**

```powershell
irm https://raw.githubusercontent.com/equityhammer/install/main/install.ps1 | iex
```

Why two commands and not literally one: PowerShell has no `bash`, and a Mac has no
PowerShell, so no single line runs in both shells. Instead, both funnel into the same
place. `install.sh` detects macOS vs Linux and runs the right bootstrap. `install.ps1`
sets up WSL if needed, then runs that same `install.sh` inside it. One brain, two front
doors.

## What happens

- **`install.sh`** - detects the OS. macOS goes to `mac/bootstrap.sh`; Linux/WSL goes to
  `wsl/bootstrap.sh`.
- **`install.ps1`** - checks for WSL. If missing, offers `wsl --install` (needs admin +
  a reboot), then asks the user to reboot, finish the Ubuntu username/password setup, and
  paste the same line again. If WSL is ready, it hands off into the distro.
- **`mac/bootstrap.sh`** and **`wsl/bootstrap.sh`** - the guided "Jarvis" setup: base
  tooling, Claude Code, the standard project workspace, aliases, and (with confirmation)
  Tailscale and OpenClaw. Idempotent, reads prompts from the terminal, stores no secrets,
  pushes nothing.

## Layout

- `install.sh` - universal Unix entry point (Mac + WSL).
- `install.ps1` - universal Windows entry point (PowerShell).
- `mac/` - the macOS bootstrap and its notes.
- `wsl/` - the WSL/Ubuntu bootstrap and its notes.

You can still run a platform bootstrap directly if you already know which you want; see the
per-folder README. The two commands above are the recommended path.
