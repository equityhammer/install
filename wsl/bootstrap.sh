#!/usr/bin/env bash
# Equity Hammer WSL / Ubuntu bootstrap.
#
# Sets up the standard agent-building dev box on WSL2 (or a plain Ubuntu
# box). In order:
#   1. apt-get update + bootstrap deps (curl, git, build-essential,
#      ca-certificates, tmux)
#   2. git user.name / user.email (asks if missing)
#   3. SSH check (confirm you can SSH into this box from your Windows host;
#      the whole point of a WSL agent box is remote access)
#   4. ~/claudeProjects/ folder layout (claudeDoctor + openClawDoctor)
#   5. thedoc + doctors (informational; install via thedoc's own bootstrap)
#   6. Project aliases (cc-/cn-/dcc-/dcn- direct, tcc-/tcn-/tdcc-/tdcn- in
#      tmux), plus cc-help / cc-refresh, plus a systemd USER timer that
#      regenerates aliases daily at 6 AM
#   7. Tailscale (required for agent building; 8a sign in, 8b invite Will,
#      8c invite personal email for own devices)
#   8. Claude Code (Node via NodeSource + npm install; verifies PATH)
#   9. OpenClaw (ack gate + npm install; does NOT auto-onboard)
#  10. PATH verification across every tool installed
#  11. Headless SSH test from the Windows host
#  12. Done
#
# Usage on a fresh WSL Ubuntu terminal:
#   bash <(curl -fsSL https://raw.githubusercontent.com/equityhammer/install/main/wsl/bootstrap.sh)
#
# Idempotent: re-running skips anything already in place.
# Reads from /dev/tty so prompts work even when piped from curl.
#
# Known limitations (WSL-specific, not yet handled in code; Jarvis covers
# these manually when they come up):
#   1. Port 22 collision. If Windows has its own OpenSSH Server running,
#      'ssh user@localhost' from Windows reaches Windows, not this WSL
#      distro (both listen on port 22). Step 3's SSH check can pass against
#      the wrong host. Workaround: stop the Windows sshd, or run WSL's sshd
#      on a different port.
#   2. No UNIX password precheck. A user who only ever launched WSL via the
#      Windows launcher may have no password set, which breaks password SSH.
#      Mentioned in step 3 troubleshooting only; not checked up front. Fix:
#      run 'passwd' in WSL before testing SSH.
#   3. networkingMode=mirrored (newer Windows builds) changes how localhost
#      maps between Windows and WSL. The localhost-forwarding assumption in
#      steps 3 and 11 holds on the default NAT mode only.
#   4. The Tailscale installer (curl ... | sh) is not wrapped in a soft
#      failure guard, so a transient network error there aborts the whole
#      run via the ERR trap instead of degrading like the npm steps do.

set -euo pipefail

# === config (edit if URLs change) ===
THEDOC_REPO_URL="https://github.com/equityhammer/thedoc.git"
CLAUDE_PROJECTS_DIR="$HOME/claudeProjects"
CONTACT_EMAIL="will@equityhammer.com"
TAILSCALE_ADMIN_URL="https://login.tailscale.com/admin/users"

# === colors and helpers ===
# Every line of OUR script output starts with " ▶ Jarvis " in bold orange so
# the user can instantly tell our messages apart from apt/npm/git output.
if [[ -t 2 ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  BLUE=$'\033[1;34m'
  HAMMER=$'\033[1;38;5;208m'   # bright orange, close to the EH brand
  ON_HAMMER=$'\033[48;5;208m\033[1;30m'  # orange background, black bold text
  NC=$'\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; BLUE=""; HAMMER=""; ON_HAMMER=""; NC=""
fi

PFX="${HAMMER}▶ Jarvis${NC}"

# Typed-output effect: every line of script narration streams in
# character-by-character so it feels like the agent is typing it out.
# - Press SPACE during typing to skip the rest of the current paragraph.
#   A "paragraph" ends at: a blank say "", a press_enter, a confirm,
#   an ask, or a banner (hd).
# - Disable typing entirely by exporting TYPE_SPEED=0.
# Subprocess output (apt, npm, git) is NOT typed; it streams naturally.
TYPE_SPEED="${TYPE_SPEED:-0.006}"

# Skip flag: a marker file created when the user presses SPACE during
# typing. While present, type_text dumps content instantly without
# typing it out. Cleared at every paragraph boundary so the next
# paragraph types normally again.
SKIP_FLAG="/tmp/.jarvis_skip_${$}"
clear_skip() { rm -f "$SKIP_FLAG" 2>/dev/null; }
trap 'clear_skip' EXIT

# type_text streams content char-by-char to stderr. ANSI escape sequences
# are emitted atomically. Watches /dev/tty for a space press to set the
# skip flag mid-paragraph. Uses perl (ships with Ubuntu by default).
type_text() {
  local text="$1"
  if [[ "$TYPE_SPEED" == "0" ]] || ! [[ -t 2 ]] || ! command -v perl >/dev/null 2>&1; then
    printf "%s" "$text" >&2
    return
  fi
  if [[ -f "$SKIP_FLAG" ]]; then
    printf "%s" "$text" >&2
    return
  fi
  TYPE_TEXT="$text" TYPE_SPEED_VAL="$TYPE_SPEED" SKIP_FLAG_PATH="$SKIP_FLAG" perl -e '
    use strict; use warnings;
    use Time::HiRes qw(usleep);
    use POSIX qw(:termios_h);
    use Fcntl;

    my $text  = $ENV{TYPE_TEXT} // "";
    my $delay = ($ENV{TYPE_SPEED_VAL} // 0.006) * 1_000_000;
    my $skip_flag = $ENV{SKIP_FLAG_PATH} // "";

    # Put /dev/tty into non-canonical, no-echo, non-blocking mode so we can
    # detect a space press without disturbing what the user sees in the
    # terminal. If anything in this setup fails, we fall back to plain
    # typing without skip support.
    my ($tty, $term, $old_lflag);
    my $tty_ok = 0;
    if (open($tty, "<", "/dev/tty")) {
      eval {
        $term = POSIX::Termios->new;
        $term->getattr(fileno($tty));
        $old_lflag = $term->getlflag;
        $term->setlflag($old_lflag & ~(ICANON | ECHO));
        $term->setattr(fileno($tty), TCSANOW);
        my $flags = fcntl($tty, F_GETFL, 0);
        fcntl($tty, F_SETFL, $flags | O_NONBLOCK);
        $tty_ok = 1;
      };
    }
    END {
      if (defined $term && defined $old_lflag && defined $tty) {
        $term->setlflag($old_lflag);
        $term->setattr(fileno($tty), TCSANOW);
      }
    }

    select STDERR; $| = 1;
    my $skip = 0;
    my $i = 0;
    my $len = length($text);
    while ($i < $len) {
      my $c = substr($text, $i, 1);
      if ($c eq "\033" && substr($text, $i) =~ /^(\033\[[0-9;?]*[a-zA-Z])/) {
        print STDERR $1;
        $i += length($1);
        next;
      }
      print STDERR $c;
      if (!$skip && $c ne "\n") {
        if ($tty_ok) {
          my $buf;
          my $n = sysread($tty, $buf, 1);
          if (defined $n && $n > 0 && $buf eq " ") {
            $skip = 1;
            if ($skip_flag ne "") {
              if (open(my $fh, ">", $skip_flag)) { close($fh); }
            }
          } else {
            usleep($delay);
          }
        } else {
          usleep($delay);
        }
      }
      $i++;
    }
  '
}

say() {
  [[ -z "$1" ]] && clear_skip
  printf "%s  " "$PFX" >&2
  type_text "$1"
  printf "\n" >&2
}
ok()   { printf "%s  ${GREEN}✓${NC}  " "$PFX" >&2; type_text "$1"; printf "\n" >&2; }
warn() { printf "%s  ${YELLOW}!${NC}  " "$PFX" >&2; type_text "$1"; printf "\n" >&2; }
err()  { printf "%s  ${RED}✗${NC}  " "$PFX" >&2; type_text "$1"; printf "\n" >&2; }

hd() {
  clear_skip
  local msg="$1"
  printf "\n" >&2
  printf "${HAMMER}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n" >&2
  printf "${ON_HAMMER}  EH JARVIS AGENT SETUP  ${NC}  ${HAMMER}${BOLD}%s${NC}\n" "$msg" >&2
  printf "${HAMMER}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n" >&2
}

# Mark the start and end of subprocess (apt, npm, git) output so the user
# can tell what is OUR script and what is the underlying installer.
sub_begin() { printf "${DIM}─── %s output below ───${NC}\n" "$1" >&2; }
sub_end()   { printf "${DIM}─── %s output above ───${NC}\n" "$1" >&2; }

press_enter() {
  clear_skip
  local prompt="${1:-Press enter to continue}"
  printf "%s  ${YELLOW}? %s${NC}: " "$PFX" "$prompt" >&2
  IFS= read -r _ </dev/tty || true
}

confirm() {
  clear_skip
  local q="$1" ans
  while true; do
    printf "%s  ${YELLOW}? %s [Y/n]${NC} " "$PFX" "$q" >&2
    IFS= read -r ans </dev/tty || ans=""
    case "${ans:-y}" in
      [Yy]*|"") return 0 ;;
      [Nn]*)    return 1 ;;
    esac
  done
}

ask() {
  clear_skip
  local q="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    printf "%s  ${YELLOW}? %s [%s]:${NC} " "$PFX" "$q" "$default" >&2
  else
    printf "%s  ${YELLOW}? %s:${NC} " "$PFX" "$q" >&2
  fi
  IFS= read -r ans </dev/tty || ans=""
  printf "%s" "${ans:-$default}"
}

# vocab: define a technical term in plain English. Used by
# explain_or_continue() to let the user type a term and get a definition
# without leaving the script.
vocab() {
  local term
  term=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$term" in
    "path")
      say "${BOLD}PATH${NC} is the list of folders Linux checks when you"
      say "type a command. If 'claude' lives in a folder on PATH, typing"
      say "'claude' just works. If not, you would have to type the full"
      say "path to the program every time you wanted it."
      ;;
    "profile"|".profile"|"~/.profile")
      say "${BOLD}~/.profile${NC} is a small text file Linux reads every"
      say "time you start a new login shell. Putting a line in there is"
      say "the standard way to make a setting (like 'add this folder to"
      say "PATH') stick across every login, forever."
      ;;
    "bashrc"|".bashrc"|"~/.bashrc")
      say "${BOLD}~/.bashrc${NC} is a small text file bash reads every"
      say "time you open a new interactive shell. It is the standard"
      say "home for aliases and shortcuts that should be available the"
      say "moment a terminal opens."
      ;;
    "shell"|"bash"|"zsh")
      say "${BOLD}shell${NC} is the program inside your terminal that reads"
      say "what you type and runs it. Ubuntu's default is 'bash'. The"
      say "shell is what you are talking to when you type a command."
      ;;
    "apt"|"apt-get"|"apt-package"|"package")
      say "${BOLD}apt${NC} (or 'apt-get') is Ubuntu's package manager."
      say "It is like an app store for command-line tools: we say"
      say "'sudo apt-get install foo' and it fetches and sets up foo for us."
      ;;
    "sudo")
      say "${BOLD}sudo${NC} runs a command with administrative rights, the"
      say "Linux equivalent of 'Run as Administrator'. Some installs need"
      say "to touch system folders, which is why we prompt for your Linux"
      say "user password the first time it is required."
      ;;
    "wsl"|"wsl2")
      say "${BOLD}WSL${NC} (Windows Subsystem for Linux) is a real Linux"
      say "kernel running inside Windows. From this WSL distro's point of"
      say "view it is a Linux box; from Windows's point of view it is just"
      say "an app you can launch. Files, networking, and processes all"
      say "behave like Linux."
      ;;
    "systemd"|"systemctl"|"timer")
      say "${BOLD}systemd${NC} is Ubuntu's service manager. A 'unit' is a"
      say "thing it knows how to start. A 'timer' unit runs another unit"
      say "on a schedule, like a cron job. We use one to regenerate your"
      say "project aliases daily."
      ;;
    "loginctl"|"linger")
      say "${BOLD}lingering${NC} tells systemd to keep your user services"
      say "running even when you are not logged in. Without it, a user"
      say "timer only fires while a shell session is open. We enable it"
      say "so the daily alias refresh happens reliably."
      ;;
    "npm")
      say "${BOLD}npm${NC} is Node.js's package manager, like apt but for"
      say "tools written in JavaScript. We use it to install Claude Code"
      say "and OpenClaw because both ship as npm packages."
      ;;
    "tmux")
      say "${BOLD}tmux${NC} ('terminal multiplexer') lets one terminal window"
      say "hold many independent sessions running at the same time. Useful"
      say "when you SSH in from a phone, because the sessions survive even"
      say "if your phone briefly disconnects."
      ;;
    "ssh")
      say "${BOLD}SSH${NC} ('Secure Shell') is how you control one computer"
      say "from another over the network by typing commands. Once SSH plus"
      say "Tailscale are set up, you can type into this WSL box from your"
      say "laptop or phone as if you were sitting in front of it."
      ;;
    "tailscale"|"tailnet")
      say "${BOLD}Tailscale${NC} is a private virtual network for your devices."
      say "Once installed and signed in, all your devices can talk to each"
      say "other directly, no matter what Wi-Fi each is on. It is how you"
      say "will SSH into this box from across the room or across the world."
      ;;
    "daemon"|"service")
      say "${BOLD}daemon${NC} (or 'service') is a program that runs quietly in"
      say "the background, all the time, even when you do not see it."
      say "OpenClaw installs one so its agent gateway is always available."
      ;;
    "fresh terminal"|"new terminal"|"close terminal")
      say "${BOLD}'fresh terminal'${NC} just means: close the current terminal"
      say "window and open a new one. Some changes (like adding programs"
      say "to PATH) only take effect when a NEW terminal window starts up,"
      say "because shells only read their configuration on launch."
      ;;
    "alias")
      say "${BOLD}alias${NC} is a short word your shell expands into a longer"
      say "command. We set up cc-<project> as a one-word shortcut for"
      say "'cd into the project folder and run claude --continue'."
      ;;
    "help")
      say "${BOLD}Terms I can define right now:${NC}"
      say "  PATH, profile, bashrc, shell, apt, sudo, WSL, systemd,"
      say "  lingering, npm, tmux, SSH, Tailscale, daemon, alias,"
      say "  'fresh terminal'"
      say "Type any of those at a prompt for the definition. Press enter"
      say "to continue."
      ;;
    *)
      say "I do not have a definition for '$1', sir. Type 'help' for the"
      say "list of terms I know."
      ;;
  esac
}

# explain_or_continue: lets the user type a term to define, or just hit
# enter to continue. Loops until they hit enter. Use this after a step's
# explanation paragraph to give non-technical users a chance to ask about
# any jargon before the action happens.
explain_or_continue() {
  clear_skip
  local input
  while true; do
    printf "%s  ${YELLOW}? Press enter to continue, or type a term to define (or 'help'):${NC} " "$PFX" >&2
    IFS= read -r input </dev/tty || input=""
    if [[ -z "$input" ]] || [[ "$input" == "continue" ]]; then
      return 0
    fi
    say ""
    vocab "$input"
    say ""
  done
}

# ack: a heavier confirmation than confirm(). Requires the user to type
# "I understand" (or "No" to abort). Use this where understanding really
# matters - typically after an explanation + analogy + preview of what is
# about to happen.
ack() {
  clear_skip
  local q="$1" ans lower
  while true; do
    printf "%s  ${YELLOW}? %s${NC}\n" "$PFX" "$q" >&2
    printf "%s    Type '${BOLD}I understand${NC}' to continue, or '${BOLD}No${NC}' to abort: " "$PFX" >&2
    IFS= read -r ans </dev/tty || ans=""
    lower=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:][:punct:]]*$//; s/^[[:space:]]*//')
    case "$lower" in
      "i understand"|"iunderstand")
        return 0 ;;
      "no"|"n"|"nope")
        return 1 ;;
      *)
        printf "%s  ${YELLOW}!${NC}  Please type exactly 'I understand' or 'No', sir.\n" "$PFX" >&2
        ;;
    esac
  done
}

# clipboard_copy: copy stdin text into the user's clipboard if a working
# clipboard tool is available. Tries (in order): clip.exe (WSL bridge to
# Windows clipboard), xclip, wl-copy. Returns 0 on success, 1 otherwise.
clipboard_copy() {
  local text="$1"
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$text" | clip.exe
    return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    printf '%s' "$text" | xclip -selection clipboard
    return 0
  fi
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$text" | wl-copy
    return 0
  fi
  return 1
}

# verify_path checks whether <cmd> resolves on PATH.
# If not, tries to find it via known fallback locations and updates ~/.profile.
# Returns 0 if found (after fixup if needed), 1 if still missing.
verify_path() {
  local cmd="$1"
  hash -r 2>/dev/null || true
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd resolves to $(command -v "$cmd")"
    return 0
  fi

  # Try common locations per tool.
  local candidates=()
  case "$cmd" in
    git|node|npm|tmux|tailscale)
      candidates=("/usr/bin/$cmd" "/usr/local/bin/$cmd" "$HOME/.local/bin/$cmd")
      ;;
    claude|openclaw)
      if command -v npm >/dev/null 2>&1; then
        local prefix
        prefix="$(npm config get prefix 2>/dev/null || echo "")"
        [[ -n "$prefix" ]] && candidates+=("$prefix/bin/$cmd")
      fi
      candidates+=("/usr/bin/$cmd" "/usr/local/bin/$cmd" "$HOME/.local/bin/$cmd")
      ;;
    *)
      candidates=("/usr/bin/$cmd" "/usr/local/bin/$cmd" "$HOME/.local/bin/$cmd")
      ;;
  esac

  local found=""
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then found="$c"; break; fi
  done

  if [[ -z "$found" ]]; then
    err "$cmd is NOT on PATH and I cannot find it in any known location."
    return 1
  fi

  warn "$cmd found at $found but not on PATH. Adding to ~/.profile."
  local dir
  dir="$(dirname "$found")"
  if ! grep -qF "$dir" "$HOME/.profile" 2>/dev/null; then
    {
      printf '\n# %s PATH (added by wsl-bootstrap.sh)\n' "$cmd"
      printf 'export PATH="%s:$PATH"\n' "$dir"
    } >> "$HOME/.profile"
  fi
  export PATH="$dir:$PATH"
  hash -r 2>/dev/null || true
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd now resolves to $(command -v "$cmd")"
    warn "Open a fresh terminal so the PATH change applies globally."
    return 0
  else
    err "Still cannot resolve $cmd after PATH update. Inspect manually."
    return 1
  fi
}

# === resume / checkpoint support ===
# Records each completed section in a state file so a re-run (e.g. after a
# bug) can fast-forward. section_gate prompts ENTER-to-skip / y-to-rerun for
# any section already recorded; section_done records completion.
STATE_FILE="$HOME/.eh-wsl-bootstrap-state"
RESUME_AVAILABLE="no"
if [[ -f "$STATE_FILE" ]]; then RESUME_AVAILABLE="yes"; fi

# section_gate KEY: return 0 to run the section, 1 to skip it.
# Fresh section (not recorded) -> run. Previously completed -> ask.
section_gate() {
  local key="$1" ans
  if grep -qxF "$key" "$STATE_FILE" 2>/dev/null; then
    printf "%s  ${YELLOW}? Completed on a previous run. Press ENTER to skip it, or type 'y' to run it again:${NC} " "$PFX" >&2
    IFS= read -r ans </dev/tty || ans=""
    case "$ans" in
      [Yy]*) return 0 ;;
      *) ok "Skipping; already done."; return 1 ;;
    esac
  fi
  return 0
}

# section_done KEY: record a section as completed (idempotent).
section_done() {
  local key="$1"
  touch "$STATE_FILE" 2>/dev/null || true
  grep -qxF "$key" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$key" >> "$STATE_FILE"
}

trap 'err "Script aborted on line $LINENO"; exit 1' ERR

# === preflight ===
hd "Equity Hammer WSL / Ubuntu bootstrap"
say "At your service, sir. I shall walk you through the setup of this"
say "Linux box as your agent dev box."
say ""

# Detect OS. WSL is Linux + 'microsoft' in /proc/version.
OS_KIND="$(uname -s)"
if [[ "$OS_KIND" == "Darwin" ]]; then
  err "This is the WSL / Ubuntu bootstrap, sir. For macOS, use mac-bootstrap.sh instead."
  exit 1
fi
if [[ "$OS_KIND" != "Linux" ]]; then
  err "Linux only, I'm afraid. This appears to be: $OS_KIND"
  exit 1
fi
IS_WSL="no"
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL="yes"
  ok "Detected: WSL2 on Windows."
else
  ok "Detected: native Linux (no WSL marker in /proc/version)."
fi

# Confirm we have apt-get; abort if this is a non-Debian distro.
if ! command -v apt-get >/dev/null 2>&1; then
  err "apt-get not found. This script targets Debian / Ubuntu family distros."
  err "If you are on Fedora, Arch, or similar, install the equivalents manually."
  exit 1
fi

say ""
say "Everything I say is prefixed with ${HAMMER}▶ Jarvis${NC}. Anything else"
say "you see (apt progress, npm output, git messages) is from the"
say "underlying installers, not from me. The dimmed lines"
say "${DIM}─── X output below/above ───${NC} bracket those external messages."
say ""
say "${BOLD}The run is idempotent.${NC} If you stop midway and start again"
say "later, I shall skip whatever has already been done."
say ""
say "${BOLD}An analogy before we start, sir:${NC} think of me as a concierge"
say "showing you around a new building. I'll narrate as we go, occasionally"
say "send you in to handle a check-in at one of the desks (apt, npm,"
say "Tailscale, OpenClaw), then collect you on the other side. Nothing"
say "will happen on this box without me telling you first what it is."
say ""
say "${BOLD}Two shortcuts to remember:${NC}"
say ""
say "  ${BOLD}SPACE${NC}    if I'm typing too slowly, press SPACE to dump the"
say "           rest of the current paragraph at once."
say ""
say "  ${BOLD}CTRL+C${NC}   if a tool I launched (a wizard, a TUI, anything"
say "           interactive) leaves you stuck, press CTRL+C. That cancels"
say "           the stuck tool and hands control back to me. CTRL+C only"
say "           kills the stuck child here, not the whole bootstrap."
say ""
say "${BOLD}A taste of what an interaction looks like:${NC}"
say ""
# Direct printf for the preview so the example lines show their own
# prefixes verbatim instead of inheriting another from say().
printf "    ${HAMMER}▶ Jarvis${NC}  Installing build tools now, sir...\n" >&2
printf "    ${DIM}─── apt-get install output below ───${NC}\n" >&2
printf "    Reading package lists... Done\n" >&2
printf "    Setting up build-essential...\n" >&2
printf "    ${DIM}─── apt-get install output above ───${NC}\n" >&2
printf "    ${HAMMER}▶ Jarvis${NC}  ${GREEN}✓${NC}  Build tools installed.\n" >&2
printf "    ${HAMMER}▶ Jarvis${NC}  ${YELLOW}? Press enter to continue, sir...${NC}\n" >&2
say ""
say "Anything starting with ${HAMMER}▶ Jarvis${NC} is me. Anything inside the"
say "dimmed bookends is from the tool I just launched."
say ""
say "I shall require the following from you along the way:"
say "  - Your Linux user password (apt-get and a few other steps need sudo)."
say "  - Your name and email, for git commit attribution."
say "  - A pause to verify SSH from your Windows host into this WSL box."
say "  - Your decision on Tailscale, Claude Code, and OpenClaw."
say ""

confirm "Shall we proceed, sir?" || { warn "As you wish, sir. Standing down."; exit 0; }

if [[ "$RESUME_AVAILABLE" == "yes" ]]; then
  say ""
  say "${BOLD}I found a checkpoint from a previous run.${NC} For each step you"
  say "already finished, I'll let you press ENTER to skip it, or type 'y' to"
  say "run it again. Steps you never reached will run normally."
  say ""
  if ! confirm "Resume from that checkpoint? (No = forget it and run every step fresh)"; then
    rm -f "$STATE_FILE" 2>/dev/null || true
    RESUME_AVAILABLE="no"
    ok "Checkpoint cleared. Every step will run from the top."
  fi
  say ""
fi

# Hoist cross-section variables so skipping a section on resume can never
# leave a later section referencing an unset value. All derived from the
# real state of the box, so they are correct whether or not their section
# runs this time.
WSL_USER="$(id -un)"
WSL_HOST="$(hostname 2>/dev/null || echo localhost)"
INSTALLED_TAILSCALE="no";   command -v tailscale >/dev/null 2>&1 && INSTALLED_TAILSCALE="yes"
INSTALLED_CLAUDE_CODE="no"; command -v claude    >/dev/null 2>&1 && INSTALLED_CLAUDE_CODE="yes"
INSTALLED_OPENCLAW="no";    command -v openclaw  >/dev/null 2>&1 && INSTALLED_OPENCLAW="yes"

# === 1. apt-get update + bootstrap deps ===
hd "Step 1: apt-get and bootstrap deps"
if section_gate "01-apt"; then
say ""
say "${BOLD}First order of business:${NC} a fresh package index, then a"
say "small set of tools every later step relies on: curl (to fetch other"
say "installers), git, build-essential (the C toolchain that some npm"
say "packages compile against), ca-certificates (so HTTPS works), and"
say "tmux (the terminal multiplexer the tcc-* aliases use)."
say ""
say "${BOLD}Sudo, sir.${NC} I will need administrative rights here to update"
say "the package index and install packages. Please type your Linux user"
say "password when prompted."
say ""

sub_begin "sudo apt-get update"
sudo apt-get update </dev/tty
sub_end "sudo apt-get update"

DEPS=(curl git build-essential ca-certificates tmux perl)
say ""
say "Installing: ${DEPS[*]}"
sub_begin "sudo apt-get install"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${DEPS[@]}" </dev/tty
sub_end "sudo apt-get install"
ok "Bootstrap dependencies installed."

section_done "01-apt"
press_enter "Press enter to continue, sir; next we configure git"
fi

# === 2. git config ===
hd "Step 2: git config"
if section_gate "02-git"; then
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
  ok "Already set: $GIT_NAME <$GIT_EMAIL>"
else
  GIT_NAME="$(ask "Your name (for git commits)" "$GIT_NAME")"
  GIT_EMAIL="$(ask "Your email (for git commits)" "$GIT_EMAIL")"
  if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
    err "Both name and email are required."
    exit 1
  fi
  git config --global user.name  "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  git config --global init.defaultBranch main
  git config --global pull.rebase false
  ok "Configured."
fi
verify_path git

section_done "02-git"
press_enter "Press enter to continue, sir; next we verify SSH access from your Windows host"
fi

# === 3. SSH check ===
hd "Step 3: SSH from your Windows host"
if section_gate "03-ssh"; then
say ""
say "${BOLD}Why this matters:${NC} the entire point of using a WSL box as an"
say "agent host is that you reach it over SSH, from a real terminal on the"
say "Windows side. If SSH from Windows into this distro does not work, the"
say "rest of the setup is academic."
say ""
say "${BOLD}WSL's openssh quirks:${NC} unlike a normal Linux box, WSL does not"
say "start sshd at boot by default. Two things tend to go wrong:"
say "  1. The openssh-server package is not installed."
say "  2. sshd is installed but not running, or not enabled at boot."
say ""
say "I'll check both, then leave you to test from Windows."
say ""

# Install openssh-server if missing.
if dpkg -s openssh-server >/dev/null 2>&1; then
  ok "openssh-server already installed."
else
  say "openssh-server is not installed. Installing now (needs sudo)."
  sub_begin "sudo apt-get install openssh-server"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server </dev/tty
  sub_end "sudo apt-get install openssh-server"
  ok "openssh-server installed."
fi

# Try to start / enable sshd. WSL with systemd=true honours systemctl;
# without systemd we fall back to a service start.
SSH_ENABLED="no"
if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service >/dev/null 2>&1; then
  say "Enabling and starting the ssh service via systemd (sudo)."
  if sudo systemctl enable ssh </dev/tty 2>/dev/null; then
    ok "ssh.service enabled (will start on boot)."
  else
    warn "Could not enable ssh.service. You may need to enable systemd in /etc/wsl.conf."
  fi
  if sudo systemctl start ssh </dev/tty 2>/dev/null; then
    ok "ssh.service started."
    SSH_ENABLED="yes"
  else
    warn "Could not start ssh.service. Check 'systemctl status ssh' after this script."
  fi
else
  warn "systemd not detected. To get systemd in WSL, add the following to /etc/wsl.conf"
  warn "and run 'wsl --shutdown' from PowerShell:"
  warn "  [boot]"
  warn "  systemd=true"
  say ""
  say "For now, I'll try to start sshd via the service command."
  if sudo service ssh start </dev/tty 2>/dev/null; then
    ok "ssh service started (will NOT persist across reboots without systemd)."
    SSH_ENABLED="yes"
  else
    warn "Could not start sshd. You will need to start it manually before testing."
  fi
fi

# Compute the hostname / address the user should connect to.
WSL_USER="$(id -un)"
WSL_HOST="$(hostname 2>/dev/null || echo localhost)"

say ""
say "${BOLD}From your Windows host${NC} (PowerShell, Windows Terminal, etc.),"
say "open a new window and try:"
say ""
say "  ssh ${WSL_USER}@localhost"
say ""
say "${BOLD}Why localhost works:${NC} WSL2 forwards localhost ports to the"
say "Linux side automatically, so 'localhost' from Windows reaches this"
say "distro. If you have set up Tailscale later (step 7), you will also"
say "be able to reach this box from any other Tailscale device by its"
say "tailnet hostname."
say ""
say "${BOLD}If the SSH connection is refused:${NC}"
say "  - Confirm sshd is running:    sudo service ssh status"
say "  - Default sshd port is 22.    sudo ss -ltnp | grep :22"
say "  - On WSL with systemd, you may need: sudo systemctl restart ssh"
say "  - You will need a password set for your Linux user; if you have"
say "    only ever logged in via the WSL launcher, run 'passwd' here"
say "    first."
say ""
section_done "03-ssh"
press_enter "Press enter once you have confirmed 'ssh ${WSL_USER}@localhost' from Windows works, sir"
fi

# === 4. claudeProjects folder layout ===
hd "Step 4: ~/claudeProjects layout"
if section_gate "04-folders"; then
say ""
say "I'm about to create a folder structure on this box:"
say ""
say "  ~/claudeProjects/                  (your top-level agent workspace)"
say "  ~/claudeProjects/claudeDoctor/     (Claude Code troubleshooting tools)"
say "  ~/claudeProjects/openClawDoctor/   (OpenClaw troubleshooting tools)"
say "  ~/.claude/CLAUDE.md                (global instructions Claude Code"
say "                                      reads at every session start)"
say ""
say "${BOLD}Why this layout:${NC} every project we build for you will live"
say "under ~/claudeProjects/. Keeping the structure standard means scripts,"
say "prompts, and tooling can find what they need with no per-machine config."
say ""
say "${BOLD}The ~/.claude/ folder${NC} is where Claude Code keeps user-level"
say "settings. CLAUDE.md inside it is read by every Claude Code session"
say "you start anywhere on this box. Good place for rules like 'never use"
say "em dashes' or 'commit with my work email by default'."
say ""
say "Creating now..."
say ""

mkdir -p "$CLAUDE_PROJECTS_DIR/claudeDoctor" "$CLAUDE_PROJECTS_DIR/openClawDoctor"
mkdir -p "$HOME/.claude"
[[ -f "$HOME/.claude/CLAUDE.md" ]] || : > "$HOME/.claude/CLAUDE.md"
ok "Created $CLAUDE_PROJECTS_DIR/"
ok "Created $CLAUDE_PROJECTS_DIR/claudeDoctor/"
ok "Created $CLAUDE_PROJECTS_DIR/openClawDoctor/"
ok "Created ~/.claude/CLAUDE.md (empty for now; we will fill it in later)"
say ""
say "${BOLD}If you want to recreate this layout yourself later:${NC}"
say "  mkdir -p ~/claudeProjects/{claudeDoctor,openClawDoctor}"
say "  mkdir -p ~/.claude && touch ~/.claude/CLAUDE.md"

section_done "04-folders"
press_enter "Press enter to continue, sir; next is a quick note about thedoc and the doctor agents"
fi

# === 5. thedoc + doctors (handled separately) ===
hd "Step 5: thedoc and the doctor agents"
if section_gate "05-thedoc"; then
say ""
say "${BOLD}What thedoc is:${NC} a framework that creates and maintains"
say "'doctor' agents, specialized Claude Code instances that diagnose and"
say "configure their respective tools. There is a Claude Code Doctor (for"
say "diagnosing Claude Code itself) and an OpenClaw Doctor (for OpenClaw)."
say "When something is misbehaving, you go talk to the appropriate doctor."
say ""
say "${BOLD}Why we are not installing it right now:${NC} thedoc has its own"
say "bootstrap script that handles the clone and the doctor setup. Running"
say "that here would just duplicate work, and at the time of writing thedoc"
say "setup has a known bug (unbound dirs[@] when no project folders exist)."
say ""
say "${BOLD}When you are ready,${NC} run thedoc's bootstrap directly:"
say ""
say "  bash <(curl -fsSL https://raw.githubusercontent.com/equityhammer/thedoc/main/bootstrap.sh)"
say ""
say "It will clone thedoc, install it, and walk you through creating the"
say "doctor instances inside the claudeDoctor and openClawDoctor folders"
say "we made in step 4."

section_done "05-thedoc"
press_enter "Press enter to continue, sir; next we set up the project aliases"
fi

# === 6. project aliases ===
hd "Step 6: project aliases"
if section_gate "06-aliases"; then
say ""
say "${BOLD}Setting up project aliases.${NC} For every folder under"
say "~/claudeProjects, the generator creates eight short shell aliases"
say "in two flavors:"
say ""
say "${BOLD}Direct (current terminal, no tmux):${NC}"
say "  cc-<project>    continue last Claude Code conversation in <project>"
say "  cn-<project>    start a new Claude Code conversation"
say "  dcc-<project>   cc-* plus --dangerously-skip-permissions"
say "  dcn-<project>   cn-* plus --dangerously-skip-permissions"
say ""
say "${BOLD}Inside tmux (preferred when SSH'd in from a phone):${NC}"
say "  tcc-<project>   continue, in a named tmux window in the 'claude' session"
say "  tcn-<project>   new conversation, in tmux"
say "  tdcc-<project>  continue, in tmux, --dangerously-skip-permissions"
say "  tdcn-<project>  new, in tmux, --dangerously-skip-permissions"
say ""
say "${BOLD}Why two flavors:${NC} day to day at this box, the direct ones are"
say "fastest. When you SSH in from a phone, the tmux ones survive network"
say "blips, so you do not lose your session if the connection drops or the"
say "phone screen sleeps. tmux also lets one session hold many projects."
say ""
say "Example: a folder ~/claudeProjects/claudeDoctor produces both"
say "cc-claudeDoctor and tcc-claudeDoctor (and the cn/dcc/dcn variants)."
say ""
say "tmux is already installed (we put it in the bootstrap deps in step 1)."
say "Now I shall install the alias generator at ~/.local/bin/."
say ""

ALIAS_GEN_DST="$HOME/.local/bin/generate-cc-aliases"
ALIAS_FILE="$HOME/.cc-project-aliases"
mkdir -p "$HOME/.local/bin"

cat > "$ALIAS_GEN_DST" << 'GENERATOR_EOF'
#!/usr/bin/env bash
# Generate Claude Code aliases for each project folder under ~/claudeProjects/.
#
# Direct (current terminal):     cc-<p>, cn-<p>, dcc-<p>, dcn-<p>
# Inside tmux session 'claude':  tcc-<p>, tcn-<p>, tdcc-<p>, tdcn-<p>
#
# *cc-* / *tcc-* = continue last conversation
# *cn-* / *tcn-* = new conversation
# d-prefix       = --dangerously-skip-permissions

PROJECTS_DIR="$HOME/claudeProjects"
ALIAS_FILE="$HOME/.cc-project-aliases"
: > "$ALIAS_FILE"

cat >> "$ALIAS_FILE" << 'FUNC'
_cc_tmux() {
    local session="claude"
    local win_name="$1"
    local work_dir="$2"
    shift 2
    local cmd="$*"
    if ! tmux has-session -t "$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -n "$win_name" -c "$work_dir" "$cmd"
        tmux attach-session -t "$session"
        return
    fi
    if tmux list-windows -t "$session" -F '#W' | grep -qx "$win_name"; then
        if [ -n "$TMUX" ]; then
            tmux select-window -t "${session}:${win_name}"
        else
            tmux attach-session -t "${session}:${win_name}"
        fi
        return
    fi
    if [ -n "$TMUX" ]; then
        tmux rename-window "$win_name"
        cd "$work_dir" || return 1
        exec $cmd
        return
    fi
    tmux new-window -t "$session" -n "$win_name" -c "$work_dir" "$cmd"
    tmux attach-session -t "${session}:${win_name}"
}
FUNC

# Helper: shorten a folder name to its initials (camelCase aware).
# claudeDoctor   -> cd
# openClawDoctor -> ocd
# claude-doctor  -> cd
# thedoc         -> t
shortname() {
    echo "$1" \
      | sed -E 's/([A-Z])/-\1/g; s/^-//' \
      | sed 's/\([a-zA-Z0-9]\)[a-zA-Z0-9]*/\1/g; s/-//g' \
      | tr '[:upper:]' '[:lower:]'
}

# Generate aliases for each project folder
for dir in "$PROJECTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    folder_name="$(basename "$dir")"
    [[ "$folder_name" == .* ]] && continue
    [[ "$folder_name" == _* ]] && continue
    short="$(shortname "$folder_name")"
    work_dir="${dir%/}"

    # cd- aliases: just navigate into the folder, no claude invocation
    echo "alias cd-${folder_name}='cd \"${work_dir}\"'" >> "$ALIAS_FILE"

    # Direct aliases (run claude in the current terminal, no tmux)
    echo "alias cc-${folder_name}='cd \"${work_dir}\" && claude --continue'" >> "$ALIAS_FILE"
    echo "alias cn-${folder_name}='cd \"${work_dir}\" && claude'" >> "$ALIAS_FILE"
    echo "alias dcc-${folder_name}='cd \"${work_dir}\" && claude --dangerously-skip-permissions --continue'" >> "$ALIAS_FILE"
    echo "alias dcn-${folder_name}='cd \"${work_dir}\" && claude --dangerously-skip-permissions'" >> "$ALIAS_FILE"

    # tmux aliases (t-prefix; run claude inside the 'claude' tmux session)
    echo "alias tcc-${folder_name}='_cc_tmux \"${short}\" \"${work_dir}\" claude --continue'" >> "$ALIAS_FILE"
    echo "alias tcn-${folder_name}='_cc_tmux \"${short}\" \"${work_dir}\" claude'" >> "$ALIAS_FILE"
    echo "alias tdcc-${folder_name}='_cc_tmux \"${short}\" \"${work_dir}\" claude --dangerously-skip-permissions --continue'" >> "$ALIAS_FILE"
    echo "alias tdcn-${folder_name}='_cc_tmux \"${short}\" \"${work_dir}\" claude --dangerously-skip-permissions'" >> "$ALIAS_FILE"

    # Same set under the short alias if it differs from the folder name
    if [ "$short" != "$folder_name" ] && [ -n "$short" ]; then
        echo "alias cd-${short}='cd \"${work_dir}\"'" >> "$ALIAS_FILE"
        echo "alias cc-${short}='cd \"${work_dir}\" && claude --continue'" >> "$ALIAS_FILE"
        echo "alias cn-${short}='cd \"${work_dir}\" && claude'" >> "$ALIAS_FILE"
        echo "alias dcc-${short}='cd \"${work_dir}\" && claude --dangerously-skip-permissions --continue'" >> "$ALIAS_FILE"
        echo "alias dcn-${short}='cd \"${work_dir}\" && claude --dangerously-skip-permissions'" >> "$ALIAS_FILE"
        echo "alias tcc-${short}='_cc_tmux \"${short}\" \"${work_dir}\" claude --continue'" >> "$ALIAS_FILE"
        echo "alias tcn-${short}='_cc_tmux \"${short}\" \"${work_dir}\" claude'" >> "$ALIAS_FILE"
        echo "alias tdcc-${short}='_cc_tmux \"${short}\" \"${work_dir}\" claude --dangerously-skip-permissions --continue'" >> "$ALIAS_FILE"
        echo "alias tdcn-${short}='_cc_tmux \"${short}\" \"${work_dir}\" claude --dangerously-skip-permissions'" >> "$ALIAS_FILE"
    fi
done

# Define a cc_help_print function (runnable as 'cc-help') that prints the
# full alias list on demand. NOT called at shell startup, so users aren't
# bombarded every time they open a terminal.
{
    echo ""
    echo "cc_help_print() {"
    echo "    echo ''"
    echo "    echo '  Claude Code project shortcuts'"
    echo "    echo '  ============================='"
    echo "    echo ''"
    echo "    echo '  Direct (run Claude Code in the current terminal):'"
    echo "    echo ''"
} >> "$ALIAS_FILE"

for dir in "$PROJECTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    folder_name="$(basename "$dir")"
    [[ "$folder_name" == .* ]] && continue
    [[ "$folder_name" == _* ]] && continue
    short="$(shortname "$folder_name")"
    echo "    echo '    cc-${folder_name}    cn-${folder_name}    dcc-${folder_name}    dcn-${folder_name}'" >> "$ALIAS_FILE"
    if [ "$short" != "$folder_name" ] && [ -n "$short" ]; then
        echo "    echo '    cc-${short}    cn-${short}    dcc-${short}    dcn-${short}'" >> "$ALIAS_FILE"
    fi
done

{
    echo "    echo ''"
    echo "    echo '  Inside tmux (preferred when SSH-ing in from a phone, since the'"
    echo "    echo '  session survives if your connection drops):'"
    echo "    echo ''"
} >> "$ALIAS_FILE"

for dir in "$PROJECTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    folder_name="$(basename "$dir")"
    [[ "$folder_name" == .* ]] && continue
    [[ "$folder_name" == _* ]] && continue
    short="$(shortname "$folder_name")"
    echo "    echo '    tcc-${folder_name}    tcn-${folder_name}    tdcc-${folder_name}    tdcn-${folder_name}'" >> "$ALIAS_FILE"
    if [ "$short" != "$folder_name" ] && [ -n "$short" ]; then
        echo "    echo '    tcc-${short}    tcn-${short}    tdcc-${short}    tdcn-${short}'" >> "$ALIAS_FILE"
    fi
done

{
    echo "    echo ''"
    echo "    echo '  Quick navigation (just cd into the folder, no Claude Code):'"
    echo "    echo ''"
} >> "$ALIAS_FILE"

for dir in "$PROJECTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    folder_name="$(basename "$dir")"
    [[ "$folder_name" == .* ]] && continue
    [[ "$folder_name" == _* ]] && continue
    short="$(shortname "$folder_name")"
    if [ "$short" != "$folder_name" ] && [ -n "$short" ]; then
        echo "    echo '    cd-${folder_name}    cd-${short}'" >> "$ALIAS_FILE"
    else
        echo "    echo '    cd-${folder_name}'" >> "$ALIAS_FILE"
    fi
done

{
    echo "    echo ''"
    echo "    echo '  Suffix key:'"
    echo "    echo '    cc- / tcc-  = continue last conversation'"
    echo "    echo '    cn- / tcn-  = start a new conversation'"
    echo "    echo '    dcc- dcn- tdcc- tdcn-  = same, with --dangerously-skip-permissions'"
    echo "    echo '    cd-         = just change into the folder, no Claude Code'"
    echo "    echo '    t-prefix    = run inside the claude tmux session'"
    echo "    echo ''"
    echo "    echo '  After adding a new project folder:  cc-refresh'"
    echo "    echo '  Show this cheat sheet again:        cc-help'"
    echo "    echo ''"
    echo "}"
    echo ""
    echo "alias cc-help='cc_help_print'"
    echo "alias cc-refresh='generate-cc-aliases && source ~/.bashrc && echo \"aliases refreshed\"'"
} >> "$ALIAS_FILE"

echo "# Generated $(date -Iseconds)" >> "$ALIAS_FILE"
GENERATOR_EOF

chmod +x "$ALIAS_GEN_DST"
ok "Installed alias generator at $ALIAS_GEN_DST"

# Make sure ~/.local/bin is on PATH. Aliases go in ~/.bashrc (interactive);
# PATH lives in ~/.profile (login).
if ! grep -qF '.local/bin' "$HOME/.profile" 2>/dev/null; then
  {
    printf '\n# user-installed scripts\n'
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
  } >> "$HOME/.profile"
  ok "Added ~/.local/bin to PATH in ~/.profile"
fi
export PATH="$HOME/.local/bin:$PATH"

say "Running the generator to create initial aliases..."
sub_begin "generate-cc-aliases"
"$ALIAS_GEN_DST"
sub_end "generate-cc-aliases"
ok "Aliases written to $ALIAS_FILE"

# Ensure ~/.bashrc sources the alias file.
touch "$HOME/.bashrc"
if ! grep -qF ".cc-project-aliases" "$HOME/.bashrc" 2>/dev/null; then
  {
    printf '\n# Project aliases (regenerate with: generate-cc-aliases or cc-refresh)\n'
    printf '[ -f "%s" ] && source "%s"\n' "$ALIAS_FILE" "$ALIAS_FILE"
  } >> "$HOME/.bashrc"
  ok "Added source line to ~/.bashrc"
else
  ok "~/.bashrc already sources $ALIAS_FILE (skipping)"
fi

# Install a systemd USER timer so the generator re-runs every morning,
# picking up any new project folders the user has added since the day
# before. Without this, the user has to remember 'cc-refresh'.
say ""
say "${BOLD}Setting up a daily auto-refresh${NC} via a systemd user timer."
say "The generator will re-run every morning at 6 AM, so any new project"
say "folders you added the day before get aliases automatically the next"
say "day."
say ""
say "${BOLD}One important wrinkle:${NC} user timers only run while at least"
say "one of your user sessions is active, unless 'lingering' is enabled."
say "I shall enable lingering so the timer fires even when you have no"
say "shell open. That requires sudo."
say ""

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/generate-cc-aliases.service" << SERVICE_EOF
[Unit]
Description=Regenerate Claude Code project aliases

[Service]
Type=oneshot
ExecStart=${ALIAS_GEN_DST}
StandardOutput=append:${HOME}/.local/bin/generate-cc-aliases.log
StandardError=append:${HOME}/.local/bin/generate-cc-aliases.log
SERVICE_EOF

cat > "$SYSTEMD_USER_DIR/generate-cc-aliases.timer" << TIMER_EOF
[Unit]
Description=Daily regeneration of Claude Code project aliases

[Timer]
OnCalendar=*-*-* 06:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

ok "User units written: $SYSTEMD_USER_DIR/generate-cc-aliases.{service,timer}"

# Reload the user systemd manager and enable the timer.
if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user daemon-reload 2>/dev/null; then
    ok "systemctl --user daemon-reload succeeded."
  else
    warn "systemctl --user daemon-reload failed. The user systemd instance may"
    warn "not be running yet; it should start the next time you log in."
  fi
  if systemctl --user enable --now generate-cc-aliases.timer 2>/dev/null; then
    ok "Timer enabled and started; first fire at 06:00 local time."
  else
    warn "Could not enable the timer right now. Re-run manually after next login:"
    warn "  systemctl --user daemon-reload"
    warn "  systemctl --user enable --now generate-cc-aliases.timer"
  fi

  # Enable lingering so the timer runs without an active login session.
  say ""
  say "${BOLD}Enabling lingering${NC} so the timer keeps firing even when no"
  say "shell is open. Sudo needed for loginctl."
  if sudo loginctl enable-linger "$(id -un)" </dev/tty 2>/dev/null; then
    ok "Lingering enabled for $(id -un). Timer will run reliably."
  else
    warn "Could not enable lingering. The timer will only run while you are"
    warn "logged in. To fix later:  sudo loginctl enable-linger $(id -un)"
  fi
else
  warn "systemctl not available. Skipping timer setup. You can run"
  warn "  generate-cc-aliases"
  warn "manually after adding new project folders, or rely on 'cc-refresh'."
fi

say ""
say "${BOLD}One last thing in this step: phone access.${NC}"
say ""
say "Will you ever connect to this box from your phone? If so, the t-prefix"
say "aliases (tcc-, tdcc-, etc.) become essential. tmux keeps a Claude Code"
say "session alive when your phone disconnects, so you do not lose state"
say "every time the screen sleeps or you swap networks."
say ""
if confirm "Do you plan to connect to this box from your phone, sir?"; then
  say ""
  if confirm "Are you on Android?"; then
    say ""
    say "${BOLD}Recommended: JuiceSSH${NC} (free, in the Play Store)."
    say "  https://play.google.com/store/apps/details?id=com.sonelli.juicessh"
    say ""
    say "Setup: install the app, add a connection to this box's Tailscale IP"
    say "or hostname, sign in with your Linux user password (or set up SSH"
    say "keys later for convenience). Once connected, run any tcc-* or"
    say "tdcc-* alias to launch Claude Code inside tmux. If your phone drops"
    say "connection, the session keeps running on this box; reconnect later"
    say "and re-run the same alias to rejoin exactly where you left off."
    say ""
  else
    say ""
    say "${BOLD}Recommended: Termius${NC} (small fee, in the App Store)."
    say "  https://apps.apple.com/app/termius/id549039908"
    say ""
    say "Setup: install Termius, add a host using this box's Tailscale IP"
    say "or hostname, sign in. Once connected, run any tcc-* or tdcc-*"
    say "alias to launch Claude Code inside tmux. If your phone drops"
    say "connection, the session keeps running on this box; reconnect"
    say "later and re-run the alias to rejoin where you left off."
    say ""
    say "Termius is paid (small one-time or subscription fee). Apple's"
    say "stricter sandboxing makes free iOS SSH clients harder to maintain;"
    say "the fee is worth it for a polished client. Free mosh-based clients"
    say "exist if you would prefer to tinker."
    say ""
  fi
else
  say ""
  say "Right then. The cc-* and dcc-* aliases (no tmux) are all you need"
  say "for at-the-box use. The t-prefix aliases will be there if you change"
  say "your mind later, sir."
  say ""
fi

say ""
say "${BOLD}When you create a new project folder under ~/claudeProjects:${NC}"
say "  type ${BOLD}cc-refresh${NC} to regenerate aliases right now"
say "  (or wait until tomorrow morning; the systemd timer does it daily)"
say ""
say "${BOLD}To see the alias cheat sheet anytime:${NC} type ${BOLD}cc-help${NC}"
say ""
say "${BOLD}Aliases load in NEW terminals.${NC} See the very end of this"
say "script for how to load them in your CURRENT terminal."

section_done "06-aliases"
press_enter "Press enter to continue, sir; next is Tailscale, the private network for SSH between your devices"
fi

# === 7. Tailscale (required for agent building) ===
hd "Step 7: Tailscale"
if section_gate "07-tailscale"; then
say ""
say "${BOLD}What is Tailscale?${NC} A private, encrypted virtual network"
say "that lets your devices talk to each other as if they were all on the"
say "same Wi-Fi, no matter where they actually are. Once Tailscale is on,"
say "your laptop and this box reach each other at fixed IP addresses,"
say "even when one is at home and the other is at a coffee shop."
say ""
say "${BOLD}Why we use it:${NC} so you can SSH from your work computer (or"
say "phone) into this box and run agents from a real terminal, even when"
say "you are not on the same network. On WSL specifically, Tailscale also"
say "gives you a stable hostname for the distro that does not change with"
say "every Windows reboot."
say ""
say "${BOLD}Cost:${NC} free for personal use (up to 100 devices, 3 users)."
say "Setup takes about a minute."
say ""
if confirm "Shall I install Tailscale, sir? (required for agent building)"; then
  if command -v tailscale >/dev/null 2>&1; then
    ok "tailscale already installed: $(tailscale version | head -1)"
  else
    say ""
    say "Installing via Tailscale's official install script. ${BOLD}Sudo needed${NC}"
    say "inside that script for the apt repository setup and the package"
    say "install; please type your Linux user password if prompted."
    say ""
    sub_begin "tailscale install.sh"
    # Download to a temp file then run it. Do NOT pipe curl into 'sh </dev/tty':
    # the </dev/tty redirect overrides the pipe, so sh would ignore the
    # downloaded script and become an interactive shell reading the terminal.
    TS_INSTALL="$(mktemp)"
    curl -fsSL https://tailscale.com/install.sh -o "$TS_INSTALL"
    sh "$TS_INSTALL" </dev/tty
    rm -f "$TS_INSTALL"
    sub_end "tailscale install.sh"
    ok "Installed Tailscale."
  fi
  INSTALLED_TAILSCALE="yes"
  say ""
  ok "Tailscale install complete. Now we walk through three setup steps."
  say ""

  say "${BOLD}7a. Create your Tailscale account and sign in on this box.${NC}"
  say ""
  say "From this terminal, run:"
  say ""
  say "  sudo tailscale up"
  say ""
  say "It will print an authentication URL. Copy that URL and open it in"
  say "a browser on any device. Sign up (or log in) there:"
  say "  1. Choose 'Sign up' if this is a fresh account."
  say "  2. ${BOLD}Use a Google account dedicated to this agent${NC} (or your"
  say "     personal email if you do not want a separate identity)."
  say "  3. Authorize the device when prompted."
  say "  4. The terminal here will say the connection is up."
  say ""
  say "I am going to run 'sudo tailscale up' for you now so the prompt"
  say "appears in this terminal."
  say ""
  press_enter "Press enter to launch 'sudo tailscale up', sir"
  sub_begin "sudo tailscale up"
  sudo tailscale up </dev/tty || warn "tailscale up exited non-zero; check above"
  sub_end "sudo tailscale up"
  say ""
  say "${BOLD}Important:${NC} create your OWN Tailscale account here. Do not"
  say "join someone else's tailnet."
  say ""
  press_enter "Press enter when this box shows 'Connected' to your tailnet, sir"

  say ""
  say "${BOLD}7b. Invite Will so the EH team can SSH in for support.${NC}"
  say ""
  say "Stay signed in to your Tailscale account in your browser, and open"
  say "this URL:"
  say "  $TAILSCALE_ADMIN_URL"
  say ""
  say "On the Users page:"
  say "  1. Click ${BOLD}'Invite users'${NC} (top right of the page)."
  say "  2. In the email field, enter:  $CONTACT_EMAIL"
  say "  3. Click ${BOLD}'Send invites'${NC}."
  say ""
  say "Will accepts the invite on his end. Once he does, his devices will"
  say "appear in your tailnet and the EH team can SSH into this box"
  say "whenever you need help."
  say ""
  press_enter "Press enter when the invite has been sent, sir"

  say ""
  say "${BOLD}7c. Set up your own devices to reach this box.${NC}"
  say ""
  say "On your personal computer (and phone, laptop, etc.), you will"
  say "install Tailscale, but ${BOLD}DO NOT sign in with the agent's Google"
  say "account${NC}. Use your normal personal email instead."
  say ""
  say "${BOLD}Why we keep the identities separate:${NC} the agent's Tailscale"
  say "identity is for the agent (this box) only. Your personal devices"
  say "belong to YOU. Mixing them would put your phone, laptop, and"
  say "anything else you sign in with into the agent's tailnet, where"
  say "Will (and anyone else you invite later) could see them. Keeping"
  say "the identities separate means your devices stay yours; this box"
  say "is the only crossover point."
  say ""
  say "${BOLD}Steps:${NC}"
  say ""
  say "  1. ${BOLD}From any browser still signed in to the agent's Tailscale"
  say "     account${NC}, open:"
  say "       $TAILSCALE_ADMIN_URL"
  say "     Click 'Invite users'. Enter ${BOLD}your personal email${NC} (the"
  say "     one you use for everything else, NOT the agent's email) and"
  say "     send the invite."
  say ""
  say "  2. ${BOLD}On each of your personal devices${NC}, install Tailscale:"
  say "       - Mac:     https://tailscale.com/download/macos"
  say "       - Windows: https://tailscale.com/download/windows"
  say "       - Linux:   https://tailscale.com/download/linux"
  say "       - Phone:   search 'Tailscale' in the App Store / Play Store"
  say ""
  say "  3. ${BOLD}Open the invite from your personal email${NC} (it lands in"
  say "     the inbox of the email you invited in step 1) and accept it."
  say ""
  say "  4. ${BOLD}Sign in to Tailscale on each personal device with your"
  say "     personal email${NC}. Authorize the device when prompted."
  say ""
  say "  5. Once signed in, this box (the agent) appears in your personal"
  say "     Tailscale device list. You can SSH into it from any of your"
  say "     personal devices."
  say ""
  say "${BOLD}Result:${NC} you can reach this box from any personal device,"
  say "but your personal devices are NOT exposed to the agent's tailnet."
  say "You access the agent; the agent does not access you."
  say ""
  press_enter "Press enter when you have invited your personal email and signed in on at least one personal device, sir"
else
  warn "Skipping Tailscale. Install later: curl -fsSL https://tailscale.com/install.sh | sh"
fi
section_done "07-tailscale"
fi

# === 8. Claude Code (required for agent building, with PATH verification) ===
hd "Step 8: Claude Code"
if section_gate "08-claude"; then
if confirm "Shall I install Claude Code, sir? (required for agent building)"; then
  if ! command -v node >/dev/null 2>&1; then
    say ""
    say "Node not found. Installing the current LTS via NodeSource (the"
    say "Ubuntu repos are typically a couple of major versions behind,"
    say "which trips Claude Code up). NodeSource ships a recent Node."
    say ""
    say "${BOLD}Sudo needed${NC} to add the NodeSource apt repository and"
    say "install the package. Please type your Linux user password when"
    say "prompted."
    say ""
    sub_begin "NodeSource setup_22.x"
    # Download to a temp file then run it. Do NOT pipe curl into
    # 'sudo -E bash - </dev/tty': the </dev/tty redirect overrides the pipe,
    # so bash ignores the downloaded script and drops into an interactive
    # root shell reading the terminal. Running from a file keeps stdin
    # (/dev/tty) free for the sudo password prompt.
    NODE_SETUP="$(mktemp)"
    curl -fsSL https://deb.nodesource.com/setup_22.x -o "$NODE_SETUP"
    sudo -E bash "$NODE_SETUP" </dev/tty
    rm -f "$NODE_SETUP"
    sub_end "NodeSource setup_22.x"
    sub_begin "sudo apt-get install nodejs"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs </dev/tty
    sub_end "sudo apt-get install nodejs"
  fi
  ok "Node $(node --version) at $(command -v node)"
  ok "npm  $(npm --version)  at $(command -v npm)"

  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>&1 | head -1)"
    if confirm "Shall I update to the latest, sir?"; then
      sub_begin "npm install -g claude-code"
      sudo npm install -g @anthropic-ai/claude-code </dev/tty
      sub_end "npm install -g claude-code"
    fi
  else
    say ""
    say "Installing Claude Code globally via npm. ${BOLD}Sudo needed${NC} so"
    say "the global install can write to /usr/lib/node_modules/."
    say ""
    say "${BOLD}A note before npm runs, sir:${NC} you may see lines starting"
    say "with 'npm warn deprecated' about individual packages. Those are"
    say "simply package authors letting the world know they've published"
    say "a newer version. They are informational. The install still works."
    say "Pay them no mind."
    say ""
    sub_begin "npm install -g claude-code"
    sudo npm install -g @anthropic-ai/claude-code </dev/tty
    sub_end "npm install -g claude-code"
  fi
  INSTALLED_CLAUDE_CODE="yes"
  verify_path claude
else
  warn "Skipping Claude Code. Install later with:"
  warn "  sudo npm install -g @anthropic-ai/claude-code"
fi

section_done "08-claude"
press_enter "Press enter to continue, sir; next is OpenClaw"
fi

# === 9. OpenClaw (required for agent building) ===
hd "Step 9: OpenClaw"
if section_gate "09-openclaw"; then
say ""
say "${BOLD}What OpenClaw is:${NC} a local-first AI agent gateway. It runs"
say "a small daemon on this box and exposes the 'openclaw' CLI plus a"
say "browser dashboard at http://127.0.0.1:18789/. The agents we build for"
say "you talk to OpenClaw to drive browsers, run shell tools, and so on."
say ""
say "${BOLD}Install plan:${NC} npm install OpenClaw globally (uses the Node"
say "we set up in step 8), then run 'openclaw onboard --install-daemon'"
say "to register the background service. Config lives at ~/.openclaw/."
say ""

say ""
say "${BOLD}Before we proceed, sir, please confirm you understand:${NC}"
say ""
say "  - OpenClaw installs a background service (a 'daemon') that stays"
say "    running on this box, even when no terminal is open."
say "  - After install, the wizard 'openclaw onboard --install-daemon'"
say "    runs to finish setup. ${BOLD}I am NOT going to launch that wizard"
say "    automatically${NC} because it can drop you into a terminal UI that"
say "    is hard to escape without prior knowledge. You will run it"
say "    yourself when you have your LLM credentials ready."
say "  - If you ever need to remove OpenClaw, the steps are:"
say "      sudo npm uninstall -g openclaw"
say "      systemctl --user disable --now openclaw.service  (if user-installed)"
say "      sudo systemctl disable --now openclaw.service    (if system-installed)"
say ""

if ack "Have I made this clear, and shall we proceed with the OpenClaw install?"; then
  if ! command -v node >/dev/null 2>&1; then
    err "Node is not installed. Re-run this script and answer Y to step 8 first."
    warn "Skipping OpenClaw."
  else
    if command -v openclaw >/dev/null 2>&1; then
      ok "OpenClaw already installed: $(openclaw --version 2>&1 | head -1 || true)"
      if confirm "Shall I update OpenClaw to the latest, sir?"; then
        sub_begin "npm install -g openclaw@latest"
        sudo npm install -g openclaw@latest </dev/tty || warn "OpenClaw update returned an error; continuing"
        sub_end "npm install -g openclaw@latest"
      fi
    else
      say ""
      say "Installing OpenClaw globally via npm. ${BOLD}Sudo needed${NC} for the"
      say "global install."
      say ""
      say "${BOLD}As before, sir:${NC} 'npm warn deprecated' lines that scroll"
      say "past are package authors flagging that newer versions exist."
      say "Informational only. Nothing is broken; the install completes."
      say ""
      sub_begin "npm install -g openclaw@latest"
      if sudo npm install -g openclaw@latest </dev/tty; then
        sub_end "npm install -g openclaw@latest"
        ok "OpenClaw installed."
      else
        sub_end "npm install -g openclaw@latest"
        err "OpenClaw npm install failed. Check the messages above."
        warn "Skipping the onboard step. Retry later with:"
        warn "  sudo npm install -g openclaw@latest"
        warn "  openclaw onboard --install-daemon"
      fi
    fi

    # Verify on PATH; do NOT auto-run onboard (it can trap the user in
    # a terminal UI demanding LLM credentials).
    hash -r 2>/dev/null || true
    if command -v openclaw >/dev/null 2>&1; then
      ok "openclaw on PATH at: $(command -v openclaw)"
      INSTALLED_OPENCLAW="yes"

      say ""
      say "${BOLD}OpenClaw is installed, sir.${NC} The next step is onboarding,"
      say "which I shall hand off to you rather than running automatically:"
      say "the wizard expects an LLM API key and may drop you into a"
      say "terminal UI if it cannot authenticate. Better you run it when"
      say "your credentials are ready and you can read each prompt at your"
      say "own pace."
      say ""
      say "${BOLD}When you are ready, run:${NC}"
      say ""
      say "  openclaw onboard --install-daemon"
      say ""
      say "${BOLD}Notes for the wizard:${NC}"
      say "  - When asked 'How do you want to hatch your bot?', pick the"
      say "    browser option. The terminal option drops you into a TUI"
      say "    that wants LLM credentials and is hard to escape."
      say "  - If you ever do get stuck inside the TUI or any other prompt,"
      say "    press CTRL+C. It cancels the stuck tool and returns you to"
      say "    your normal terminal."
      say ""
      say "${BOLD}Other useful commands once onboarding is done:${NC}"
      say "  openclaw status              health of the gateway"
      say "  openclaw dashboard           open the browser dashboard"
      say "  openclaw --help              full CLI reference"
      say "  Browser dashboard URL:       http://127.0.0.1:18789/"
    else
      verify_path openclaw || warn "openclaw is not resolvable; the install may have failed silently"
    fi
  fi
else
  warn "Skipping OpenClaw. Install later with:"
  warn "  sudo npm install -g openclaw@latest"
  warn "  openclaw onboard --install-daemon"
fi

section_done "09-openclaw"
press_enter "Press enter to continue, sir; next is the PATH verification across every tool we installed"
fi

# === 10. Final PATH verification ===
hd "Step 10: PATH verification"
if section_gate "10-path"; then
say ""
say "${BOLD}Plain English, sir:${NC} every program we installed needs the"
say "shell to know where to find it when you type its name. I am about"
say "to check that the shell knows where each tool lives. If anything is"
say "not yet findable, I shall write a single line into ~/.profile so"
say "Linux picks it up every time you open a new terminal from now on."
say ""
say "${BOLD}If I report needing to add something,${NC} you will see a note"
say "saying 'open a fresh terminal'. That just means: close this terminal"
say "and open a new one for the fix to be live. The terminal you have"
say "open right now will not see the change."
say ""
say "If any of the words above are unfamiliar, ask me and I will explain."
say "Type 'PATH', 'profile', 'bashrc', 'shell', 'fresh terminal', or 'help'"
say "for the full list. Or just press enter to run the check."
say ""
explain_or_continue
say ""
PATH_OK=1
verify_path git  || PATH_OK=0
verify_path tmux || PATH_OK=0
if [[ "$INSTALLED_CLAUDE_CODE" == "yes" ]]; then
  verify_path node   || PATH_OK=0
  verify_path npm    || PATH_OK=0
  verify_path claude || PATH_OK=0
fi
if [[ "$INSTALLED_OPENCLAW" == "yes" ]]; then
  verify_path openclaw || PATH_OK=0
fi
if [[ "$INSTALLED_TAILSCALE" == "yes" ]]; then
  verify_path tailscale || PATH_OK=0
fi
if (( PATH_OK == 1 )); then
  ok "Everything resolves cleanly."
else
  warn "Some tools could not be resolved. Read the messages above for the specific"
  warn "command and where it should be located."
fi

section_done "10-path"
press_enter "Press enter to continue, sir; next is the headless SSH test"
fi

# === 11. Headless SSH test ===
hd "Step 11: Headless SSH test"
if section_gate "11-ssh-test"; then
say ""
say "${BOLD}One last thing, sir.${NC} Earlier in step 3 you confirmed you"
say "could SSH from Windows into this WSL distro at localhost. Now I'd"
say "like you to confirm the same thing again, in a clean new terminal,"
say "so you have it in muscle memory. There is no monitor or keyboard"
say "to unplug here, but the principle is the same as on a Mac mini:"
say "the box's real job is to sit quietly and serve SSH sessions."
say ""
say "${BOLD}Walk through this with me:${NC}"
say ""
say "  1. Pop over to your Windows host. Open a new Windows Terminal or"
say "     PowerShell window. ${BOLD}Do not use the WSL launcher${NC} for this"
say "     test; we specifically want to confirm SSH works from outside."
say ""
say "  2. In that Windows terminal, run:"
say ""
say "       ssh ${WSL_USER}@localhost"
say ""
say "     (If you have set up Tailscale, you may also try the tailnet"
say "      hostname or IP of this box from any other tailnet device.)"
say ""
say "  3. Enter your Linux user password when prompted. You should land"
say "     in a shell inside this same WSL distro."
say ""
say "  4. Once you are in over SSH, run ${BOLD}hostname${NC} to confirm you"
say "     are talking to the right box."
say ""
say "${BOLD}Once you have a working SSH session from the Windows side,${NC}"
say "come back to this terminal and press enter below."
say ""
say "${BOLD}If something does not work,${NC} message Jarvis at"
say "  https://equityhammer.com/Jarvis"
say ""

press_enter "Press enter once 'ssh ${WSL_USER}@localhost' from Windows lands you in a shell, sir"

ok "Headless SSH test confirmed."
say ""
say "You are free, sir, to leave this WSL distro running quietly. From"
say "here on you can reach it from any tailnet device by SSH, no GUI"
say "needed. A pleasure, as always."
say ""
section_done "11-ssh-test"
fi

# === Done ===
hd "Done"
say "Layout ready under: $CLAUDE_PROJECTS_DIR"
say "  - claudeDoctor/         (Claude Code Doctor instance)"
say "  - openClawDoctor/       (OpenClaw Doctor instance)"
[[ -d "$CLAUDE_PROJECTS_DIR/thedoc" ]] && say "  - thedoc/               (cloned framework)"
say ""
say "Project aliases generated (per folder under claudeProjects):"
say "  cc-<project>    continue last Claude Code session in that project"
say "  cn-<project>    start a new Claude Code session in that project"
say "  dcc-<project>   continue, with --dangerously-skip-permissions"
say "  dcn-<project>   new, with --dangerously-skip-permissions"
say ""
say "Re-run 'generate-cc-aliases' anytime you add a new project folder."
say ""
if [[ "$INSTALLED_TAILSCALE" == "yes" ]]; then
  say "Tailscale: SSH from any device signed in to your tailnet."
  say ""
fi
if [[ "$INSTALLED_OPENCLAW" == "yes" ]]; then
  say "OpenClaw dashboard: http://127.0.0.1:18789/"
  say "OpenClaw status:    openclaw status"
  say ""
fi

# Big visible final step: how to load aliases NOW without opening a new
# terminal. Also copy the magic line to the clipboard so the user just
# pastes it. On WSL clip.exe writes to the Windows clipboard.
printf "\n${HAMMER}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n" >&2
printf "${ON_HAMMER}  LOAD ALIASES NOW  ${NC}  ${HAMMER}${BOLD}in this same terminal${NC}\n" >&2
printf "${HAMMER}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n" >&2
say ""
if clipboard_copy "source ~/.bashrc"; then
  if [[ "$IS_WSL" == "yes" ]] && command -v clip.exe >/dev/null 2>&1; then
    say "I have copied the command into your ${BOLD}Windows clipboard${NC}, sir,"
    say "via clip.exe."
  else
    say "I have copied the command into your clipboard, sir."
  fi
  say ""
  say "All you need to do now: paste it (${BOLD}Ctrl+Shift+V${NC} in most"
  say "Linux terminals, or right-click), then hit ${BOLD}Enter${NC}. Your"
  say "new aliases will be live in this terminal, no need to open a"
  say "fresh window."
  say ""
  printf "    ${BOLD}source ~/.bashrc${NC}    ${DIM}(already in your clipboard)${NC}\n" >&2
else
  say "I could not find a clipboard tool on this box, sir. After this"
  say "script ends, copy and paste this single line to load the aliases"
  say "right now (no need to open a new terminal):"
  say ""
  printf "    ${BOLD}source ~/.bashrc${NC}\n" >&2
fi
say ""
say "Or just open a fresh terminal, aliases load there automatically."
say ""
