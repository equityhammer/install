# macOS bootstrap

The guided "Jarvis" setup for a fresh Mac (e.g. a Mac mini) as an Equity Hammer agent
dev box.

## Recommended: use the universal entry point

From the repo root command, which auto-detects macOS and runs this script:

```bash
curl -fsSL https://raw.githubusercontent.com/iamfoehammer/install/main/install.sh | bash
```

## Or run this bootstrap directly

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/iamfoehammer/install/main/mac/bootstrap.sh)
```

## What it does

A narrated, step-by-step setup (every line prefixed with `Jarvis`), idempotent and safe to
re-run:

1. Homebrew (pulls in Xcode Command Line Tools).
2. Google Chrome, then a guided Google account + Chrome Remote Desktop setup for remote support.
3. git user.name / user.email.
4. The standard `~/claudeProjects/` workspace and `~/.claude/CLAUDE.md`.
5. tmux + the `cc-/cn-/dcc-/dcn-` project aliases (and `tcc-` tmux variants), with a daily
   launchd auto-refresh.
6. Tailscale (with confirmation) for SSH between your devices.
7. Claude Code.
8. OpenClaw (with confirmation).
9. A PATH check across everything installed, then a headless-access test.

It reads prompts from your terminal, stores no secrets, and pushes nothing.

## Prereqs

- macOS with administrator access (you'll be asked for your password).
- An internet connection.

## After it finishes

- Open a new terminal so PATH changes take effect (or run `source ~/.zshrc`).
- Run `claude` once to log in.
- Continue with the file-structure and configuration steps from your onboarding guide.
