# WSL (Ubuntu) bootstrap

The guided "Jarvis" setup for an Ubuntu WSL2 distro (or a plain Ubuntu box) as an Equity
Hammer agent dev box.

## Recommended: use the universal entry point

**If you are on Windows and have not opened WSL yet**, paste this into PowerShell. It sets
up WSL if needed, then runs the setup inside it:

```powershell
irm https://raw.githubusercontent.com/equityhammer/install/main/install.ps1 | iex
```

**If you already have a WSL/Ubuntu shell open**, use the universal Unix command (it
auto-detects Linux and runs this script):

```bash
curl -fsSL https://raw.githubusercontent.com/equityhammer/install/main/install.sh | bash
```

## Or run this bootstrap directly (from inside WSL)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/equityhammer/install/main/wsl/bootstrap.sh)
```

## What it does

A narrated, step-by-step setup (every line prefixed with `Jarvis`), idempotent, with
checkpoint/resume so a re-run can skip finished steps:

1. apt update + base tooling (curl, git, build-essential, ca-certificates, tmux, perl).
2. git user.name / user.email.
3. SSH check - confirms you can `ssh <user>@localhost` from your Windows host.
4. The standard `~/claudeProjects/` workspace and `~/.claude/CLAUDE.md`.
5. The `cc-/cn-/dcc-/dcn-` project aliases (and `tcc-` tmux variants), with a daily
   systemd user-timer auto-refresh.
6. Tailscale (with confirmation) for SSH between your devices.
7. Claude Code (Node via NodeSource + npm).
8. OpenClaw (with confirmation).
9. A PATH check across everything installed.

It reads prompts from your terminal, stores no secrets, and pushes nothing.

## Prereqs

- Windows with WSL2, or a plain Ubuntu/Debian box. Run from **inside the WSL shell**, not
  from Windows Explorer.
- `sudo` access and an internet connection.

## After it finishes

- Open a new WSL shell so PATH changes take effect (or run `source ~/.bashrc`).
- Run `claude` once to log in.
- Keep projects in the Linux filesystem (`~/...`), not under `/mnt/c/...` (slow over the
  WSL bridge and breaks file watchers).
- Continue with the file-structure and configuration steps from your onboarding guide.
