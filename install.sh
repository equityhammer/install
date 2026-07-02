#!/usr/bin/env bash
# Equity Hammer - universal Unix entry point.
#
# One command for Mac Terminal OR an already-open WSL/Ubuntu shell:
#
#   curl -fsSL https://raw.githubusercontent.com/iamfoehammer/install/main/install.sh | bash
#
# It detects the OS and hands off to the matching Jarvis bootstrap:
#   macOS  -> mac/bootstrap.sh
#   Linux  -> wsl/bootstrap.sh   (works on WSL2 and on plain Ubuntu)
#
# Windows users who are still in PowerShell (no WSL open yet) use install.ps1
# instead; that shim sets up WSL and then calls THIS script inside it.

set -euo pipefail

BASE="https://raw.githubusercontent.com/iamfoehammer/install/main"

os="$(uname -s)"
case "$os" in
  Darwin)
    exec bash <(curl -fsSL "$BASE/mac/bootstrap.sh")
    ;;
  Linux)
    exec bash <(curl -fsSL "$BASE/wsl/bootstrap.sh")
    ;;
  *)
    echo "Equity Hammer installer: unsupported OS '$os'." >&2
    echo "This installer supports macOS and Linux/WSL only." >&2
    exit 1
    ;;
esac
