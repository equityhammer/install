#!/usr/bin/env bash
# Equity Hammer Mac Mini bootstrap.
#
# Sets up the standard agent-building dev box. In order:
#   1. Homebrew (which pulls in Xcode Command Line Tools as a dep)
#   2. Chrome (brew cask)
#   3. Manual prompt: sign in to (or create) the agent's Google account,
#      then set up Chrome Remote Desktop so the box can be supported remotely
#   4. git user.name / user.email (asks if missing)
#   5. ~/claudeProjects/ folder with claudeDoctor and openClawDoctor subfolders
#   6. thedoc + doctors (informational; install via thedoc's own bootstrap)
#   7. tmux + project aliases (cc-/cn-/dcc-/dcn- direct, tcc-/tcn-/tdcc-/tdcn- in tmux)
#   8. Tailscale (required for agent building, asks for confirmation)
#   9. Claude Code (required for agent building, asks; verifies PATH)
#  10. OpenClaw (required for agent building, asks; npm install + onboard daemon)
#  11. PATH verification across every tool installed
#  12. Headless test instructions (run after script exits)
#
# Usage on a fresh Mac Terminal:
#   bash <(curl -fsSL https://raw.githubusercontent.com/equityhammer/install/main/mac/bootstrap.sh)
#
# Idempotent: re-running skips anything already in place.
# Reads from /dev/tty so prompts work even when piped from curl.

set -euo pipefail

# === config (edit if URLs change) ===
THEDOC_REPO_URL="https://github.com/equityhammer/thedoc.git"
CLAUDE_PROJECTS_DIR="$HOME/claudeProjects"
CONTACT_EMAIL="will@equityhammer.com"
REMOTE_DESKTOP_URL="https://remotedesktop.google.com/access"
TAILSCALE_ADMIN_URL="https://login.tailscale.com/admin/users"

# === colors and helpers ===
# Every line of OUR script output starts with " ▶ EH " in bold orange so the
# user can instantly tell our messages apart from brew/npm/git output.
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
# Subprocess output (brew, npm, git) is NOT typed; it streams naturally.
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
# skip flag mid-paragraph. Uses perl (ships with macOS by default).
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

# Mark the start and end of subprocess (brew, npm, git) output so the user
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
      say "${BOLD}PATH${NC} is the list of folders the Mac checks when you"
      say "type a command. If 'claude' lives in a folder on PATH, typing"
      say "'claude' just works. If not, you would have to type the full"
      say "path to the program every time you wanted it."
      ;;
    "zprofile"|".zprofile"|"~/.zprofile")
      say "${BOLD}~/.zprofile${NC} is a small text file the Mac reads every"
      say "time you open a new Terminal window. Putting a line in there"
      say "is the standard way to make a setting (like 'add this folder"
      say "to PATH') stick across every Terminal session, forever."
      ;;
    "shell"|"zsh"|"bash")
      say "${BOLD}shell${NC} is the program inside Terminal that reads what"
      say "you type and runs it. Modern Macs use one called 'zsh'. The"
      say "shell is what you are talking to when you type a command."
      ;;
    "homebrew"|"brew")
      say "${BOLD}Homebrew${NC} (the 'brew' command) is the standard package"
      say "manager for Mac. It is like an app store for command-line tools:"
      say "we say 'brew install foo' and it fetches and sets up foo for us."
      ;;
    "npm")
      say "${BOLD}npm${NC} is Node.js's package manager, like Homebrew but"
      say "for tools written in JavaScript. We use it to install Claude"
      say "Code and OpenClaw because both ship as npm packages."
      ;;
    "tmux")
      say "${BOLD}tmux${NC} ('terminal multiplexer') lets one Terminal window"
      say "hold many independent sessions running at the same time. Useful"
      say "when you SSH in from a phone, because the sessions survive even"
      say "if your phone briefly disconnects."
      ;;
    "ssh")
      say "${BOLD}SSH${NC} ('Secure Shell') is how you control one computer"
      say "from another over the network by typing commands. Once SSH plus"
      say "Tailscale are set up, you can type into this Mac from your"
      say "laptop or phone as if you were sitting in front of it."
      ;;
    "tailscale"|"tailnet")
      say "${BOLD}Tailscale${NC} is a private virtual network for your devices."
      say "Once installed and signed in, all your devices can talk to each"
      say "other directly, no matter what Wi-Fi each is on. It is how you"
      say "will SSH into this Mac from across the room or across the world."
      ;;
    "daemon"|"service")
      say "${BOLD}daemon${NC} (or 'service') is a program that runs quietly in"
      say "the background, all the time, even when you do not see it."
      say "OpenClaw installs one so its agent gateway is always available."
      ;;
    "fresh terminal"|"new terminal"|"close terminal")
      say "${BOLD}'fresh Terminal'${NC} just means: close the current Terminal"
      say "window and open a new one. Some changes (like adding programs"
      say "to PATH) only take effect when a NEW Terminal window starts up,"
      say "because Terminals only read their configuration on launch."
      ;;
    "alias")
      say "${BOLD}alias${NC} is a short word your shell expands into a longer"
      say "command. We set up cc-<project> as a one-word shortcut for"
      say "'cd into the project folder and run claude --continue'."
      ;;
    "help")
      say "${BOLD}Terms I can define right now:${NC}"
      say "  PATH, zprofile, shell, Homebrew, npm, tmux,"
      say "  SSH, Tailscale, daemon, alias, 'fresh Terminal'"
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

# verify_path checks whether <cmd> resolves on PATH.
# If not, tries to find it via known fallback locations and updates ~/.zprofile.
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
    brew)
      candidates=(/opt/homebrew/bin/brew /usr/local/bin/brew)
      ;;
    git|node|npm)
      # Should be on PATH via Homebrew or system; check brew prefix.
      if command -v brew >/dev/null 2>&1; then
        candidates+=("$(brew --prefix)/bin/$cmd")
      fi
      candidates+=("/usr/bin/$cmd" "/usr/local/bin/$cmd" "/opt/homebrew/bin/$cmd")
      ;;
    claude|openclaw)
      if command -v npm >/dev/null 2>&1; then
        local prefix
        prefix="$(npm config get prefix 2>/dev/null || echo "")"
        [[ -n "$prefix" ]] && candidates+=("$prefix/bin/$cmd")
      fi
      candidates+=("/opt/homebrew/bin/$cmd" "/usr/local/bin/$cmd")
      ;;
    *)
      candidates=("/opt/homebrew/bin/$cmd" "/usr/local/bin/$cmd" "/usr/bin/$cmd")
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

  warn "$cmd found at $found but not on PATH. Adding to ~/.zprofile."
  local dir
  dir="$(dirname "$found")"
  if ! grep -qF "$dir" "$HOME/.zprofile" 2>/dev/null; then
    {
      printf '\n# %s PATH (added by mac-bootstrap.sh)\n' "$cmd"
      printf 'export PATH="%s:$PATH"\n' "$dir"
    } >> "$HOME/.zprofile"
  fi
  export PATH="$dir:$PATH"
  hash -r 2>/dev/null || true
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd now resolves to $(command -v "$cmd")"
    warn "Open a fresh Terminal window so the PATH change applies globally."
    return 0
  else
    err "Still cannot resolve $cmd after PATH update. Inspect manually."
    return 1
  fi
}

trap 'err "Script aborted on line $LINENO"; exit 1' ERR

# === preflight ===
hd "Equity Hammer Mac Mini bootstrap"
say "At your service, sir. I shall walk you through the setup of this"
say "Mac mini as your agent dev box."
say ""
say "Everything I say is prefixed with ${HAMMER}▶ Jarvis${NC}. Anything else"
say "you see (Homebrew progress, npm output, git messages) is from the"
say "underlying installers, not from me. The dimmed lines"
say "${DIM}─── X output below/above ───${NC} bracket those external messages."
say ""
say "${BOLD}The run is idempotent.${NC} If you stop midway and start again"
say "later, I shall skip whatever has already been done."
say ""
say "${BOLD}An analogy before we start, sir:${NC} think of me as a concierge"
say "showing you around a new building. I'll narrate as we go, occasionally"
say "send you in to handle a check-in at one of the desks (Homebrew, npm,"
say "Tailscale, OpenClaw), then collect you on the other side. Nothing"
say "will happen on this Mac without me telling you first what it is."
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
printf "    ${HAMMER}▶ Jarvis${NC}  Installing Homebrew now, sir...\n" >&2
printf "    ${DIM}─── Homebrew installer output below ───${NC}\n" >&2
printf "    ==> Cloning into '/usr/local/Homebrew'...\n" >&2
printf "    ==> Tapping homebrew/core\n" >&2
printf "    ${DIM}─── Homebrew installer output above ───${NC}\n" >&2
printf "    ${HAMMER}▶ Jarvis${NC}  ${GREEN}✓${NC}  Homebrew installed.\n" >&2
printf "    ${HAMMER}▶ Jarvis${NC}  ${YELLOW}? Press enter to continue, sir...${NC}\n" >&2
say ""
say "Anything starting with ${HAMMER}▶ Jarvis${NC} is me. Anything inside the"
say "dimmed bookends is from the tool I just launched."
say ""
say "I shall require the following from you along the way:"
say "  - Your Mac password (Homebrew installation needs sudo)."
say "  - A brief pause to open Chrome, sign in to the agent's Google"
say "    account, and arrange Chrome Remote Desktop."
say "  - Your name and email, for git commit attribution."
say "  - Your decision on Tailscale, Claude Code, and OpenClaw."
say ""

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "macOS only, I'm afraid. This appears to be: $(uname -s)"
  exit 1
fi

confirm "Shall we proceed, sir?" || { warn "As you wish, sir. Standing down."; exit 0; }

# === 1. Homebrew (auto-installs Xcode CLT as a dep) ===
hd "Step 1: Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "Already installed at $(command -v brew)"
else
  say "Installing Homebrew. You will be asked for your Mac password."
  say "If Xcode Command Line Tools are missing, the Homebrew installer will"
  say "trigger a separate GUI installer for them; click Install in that"
  say "dialog and wait for it to finish before this step continues."
  say ""
  say "Homebrew will print a 'Next steps: add Homebrew to your PATH' notice"
  say "at the end. ${BOLD}You do not need to run those commands yourself.${NC}"
  say "This script will add brew to your PATH automatically right after."
  say ""
  sub_begin "Homebrew installer"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
  sub_end "Homebrew installer"

  # Resolve where brew landed and persist on PATH for future shells.
  if   [[ -x /opt/homebrew/bin/brew ]]; then BREW_BIN=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew    ]]; then BREW_BIN=/usr/local/bin/brew
  else
    err "Homebrew installed but I cannot find the brew binary. Inspect manually."
    exit 1
  fi
  eval "$($BREW_BIN shellenv)"
  if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
    printf '\n# Homebrew\neval "$(%s shellenv)"\n' "$BREW_BIN" >> "$HOME/.zprofile"
  fi
  ok "Homebrew installed at $BREW_BIN and added to ~/.zprofile."
fi
verify_path brew

press_enter "Press enter to continue, sir; next I'll install Google Chrome"

# === 2. Chrome ===
hd "Step 2: Google Chrome"
if [[ -d "/Applications/Google Chrome.app" ]]; then
  ok "Google Chrome already installed."
else
  sub_begin "brew install google-chrome"
  brew install --cask google-chrome
  sub_end "brew install google-chrome"
  ok "Installed Google Chrome."
fi

press_enter "Press enter to continue, sir; next we set up the agent's Google account and Chrome Remote Desktop"

# === 3. Google account + Chrome Remote Desktop (manual) ===
hd "Step 3: Agent Google account and Chrome Remote Desktop"

say ""
say "${BOLD}3a. Create or sign in to the agent's Google account.${NC}"
say ""
say "Open Chrome (Cmd+Space, type 'Chrome', enter)."
say ""
say "If your company uses Google Workspace, sign in with the agent's Workspace"
say "account. If not, create a free Gmail account for this agent."
say ""
say "${BOLD}Recommended naming pattern${NC} for the agent's email:"
say "  <agent-name>.<company-acronym>.agent@gmail.com"
say ""
say "Example: company is Equity Hammer (acronym 'eh'), agent is named Bob."
say "         Email becomes:  bob.eh.agent@gmail.com"
say ""
say "${BOLD}Recommended:${NC} use the SAME password as your Mac login. One password"
say "to remember (and to store in 1Password / LastPass) for both."
say ""
press_enter "Press enter when you are signed in to Chrome with the agent's Google account, sir"

say ""
say "${BOLD}3b. Set up Chrome Remote Desktop on this Mac.${NC}"
say ""
say "We're going to navigate you to Chrome Remote Desktop. In Chrome, open:"
say "  $REMOTE_DESKTOP_URL"
say ""
say "Click ${BOLD}'Turn on'${NC} under 'This device' and follow the prompts."
say "Pick a name for this Mac when asked."
say ""
say "You'll be asked for a ${BOLD}6-digit PIN${NC}. This PIN is for ${BOLD}YOU${NC} to log"
say "into this Mac remotely later. It is NOT shared with support people."
say "Pick something memorable but not easily guessable."
say ""
press_enter "Press enter when this Mac shows as 'Online' in your Remote Desktop list, sir"

say ""
say "${BOLD}3c. Verify remote access from your everyday computer.${NC}"
say ""
say "Now grab your normal work computer (laptop, desktop, the machine you"
say "actually do your work on). On that computer:"
say ""
say "  1. Open Chrome."
say "  2. Click the ${BOLD}profile icon${NC} in the top right of Chrome (next to"
say "     the URL bar; it is a small avatar circle)."
say "  3. Click 'Add' (or 'Add new profile') and sign in with the agent's"
say "     Google account you just created or signed in with."
say "  4. With that new profile active in Chrome, visit:"
say "       $REMOTE_DESKTOP_URL"
say "  5. You should see this Mac Mini in the 'Remote devices' list."
say "  6. Click it. Enter the 6-digit PIN you set in step 3b."
say "  7. You should see this Mac's screen on your work computer."
say ""
press_enter "Press enter when you have successfully connected from another device, sir"

# === 4. git config ===
hd "Step 4: git config"
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

press_enter "Press enter to continue, sir; next we create the claudeProjects folder layout"

# === 5. claudeProjects folder layout ===
hd "Step 5: ~/claudeProjects layout"
say ""
say "I'm about to create a folder structure on this Mac:"
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
say "you start anywhere on this Mac. Good place for rules like 'never use"
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

press_enter "Press enter to continue, sir; next is a quick note about thedoc and the doctor agents"

# === 6. thedoc + doctors (handled separately) ===
hd "Step 6: thedoc and the doctor agents"
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
say "we made in step 5."

press_enter "Press enter to continue, sir; next we'll install tmux and the project aliases"

# === 7. tmux + project aliases ===
hd "Step 7: tmux and project aliases"
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
say "${BOLD}Why two flavors:${NC} day to day at the Mac, the direct ones are"
say "fastest. When you SSH in from a phone, the tmux ones survive network"
say "blips, so you do not lose your session if the connection drops or the"
say "phone screen sleeps. tmux also lets one session hold many projects."
say ""
say "Example: a folder ~/claudeProjects/claudeDoctor produces both"
say "cc-claudeDoctor and tcc-claudeDoctor (and the cn/dcc/dcn variants)."
say ""
say "${BOLD}First, install tmux${NC} (the terminal multiplexer the aliases"
say "use under the hood)."
say ""

if command -v tmux >/dev/null 2>&1; then
  ok "tmux already installed: $(tmux -V)"
else
  sub_begin "brew install tmux"
  brew install tmux
  sub_end "brew install tmux"
  ok "Installed tmux $(tmux -V)"
fi

say ""
say "${BOLD}Installing the alias generator at ~/.local/bin/${NC} (this is"
say "our own version that creates both direct and tmux aliases; thedoc"
say "ships a similar one but only generates the tmux flavor)."
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
# bombarded every time they open Terminal.
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
    echo "alias cc-refresh='generate-cc-aliases && source ~/.zshrc && echo \"aliases refreshed\"'"
} >> "$ALIAS_FILE"

echo "# Generated $(date -Iseconds)" >> "$ALIAS_FILE"
GENERATOR_EOF

chmod +x "$ALIAS_GEN_DST"
ok "Installed alias generator at $ALIAS_GEN_DST"

# Make sure ~/.local/bin is on PATH (in .zprofile so future shells see it,
# and exported now so the generator can be invoked from anywhere later).
if ! grep -qF '.local/bin' "$HOME/.zprofile" 2>/dev/null; then
  {
    printf '\n# user-installed scripts\n'
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
  } >> "$HOME/.zprofile"
  ok "Added ~/.local/bin to PATH in ~/.zprofile"
fi
export PATH="$HOME/.local/bin:$PATH"

say "Running the generator to create initial aliases..."
sub_begin "generate-cc-aliases"
"$ALIAS_GEN_DST"
sub_end "generate-cc-aliases"
ok "Aliases written to $ALIAS_FILE"

if ! grep -qF ".cc-project-aliases" "$HOME/.zshrc" 2>/dev/null; then
  {
    printf '\n# Project aliases (regenerate with: generate-cc-aliases or cc-refresh)\n'
    printf '[ -f "%s" ] && source "%s"\n' "$ALIAS_FILE" "$ALIAS_FILE"
  } >> "$HOME/.zshrc"
  ok "Added source line to ~/.zshrc"
else
  ok "~/.zshrc already sources $ALIAS_FILE (skipping)"
fi

# Install a LaunchAgent so the generator re-runs every morning, picking
# up any new project folders the user has added since the day before.
# Without this, the user has to remember 'cc-refresh'.
say ""
say "${BOLD}Setting up a daily auto-refresh${NC} via launchd. The generator"
say "will re-run every morning at 6 AM, so any new project folders you"
say "added the day before get aliases automatically the next day."
say ""

LAUNCH_PLIST="$HOME/Library/LaunchAgents/com.equityhammer.generate-cc-aliases.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.equityhammer.generate-cc-aliases</string>
    <key>ProgramArguments</key>
    <array>
        <string>${ALIAS_GEN_DST}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>6</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${HOME}/.local/bin/generate-cc-aliases.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.local/bin/generate-cc-aliases.log</string>
</dict>
</plist>
PLIST_EOF
ok "LaunchAgent written: $LAUNCH_PLIST"

# Reload the agent. bootout first in case it was already loaded; ignore
# errors there since it might not exist yet.
launchctl bootout "gui/$(id -u)" "$LAUNCH_PLIST" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST" 2>/dev/null; then
  ok "LaunchAgent loaded. Aliases will regenerate daily at 6:00 AM."
else
  warn "Could not load the LaunchAgent automatically. Reload it manually:"
  warn "  launchctl bootstrap gui/\$(id -u) $LAUNCH_PLIST"
fi

say ""
say "${BOLD}One last thing in this step: phone access.${NC}"
say ""
say "Will you ever connect to this Mac from your phone? If so, the t-prefix"
say "aliases (tcc-, tdcc-, etc.) become essential. tmux keeps a Claude Code"
say "session alive when your phone disconnects, so you do not lose state"
say "every time the screen sleeps or you swap networks."
say ""
if confirm "Do you plan to connect to this Mac from your phone, sir?"; then
  say ""
  if confirm "Are you on Android?"; then
    say ""
    say "${BOLD}Recommended: JuiceSSH${NC} (free, in the Play Store)."
    say "  https://play.google.com/store/apps/details?id=com.sonelli.juicessh"
    say ""
    say "Setup: install the app, add a connection to this Mac's Tailscale IP"
    say "or hostname, sign in with your Mac password (or set up SSH keys"
    say "later for convenience). Once connected, run any tcc-* or tdcc-*"
    say "alias to launch Claude Code inside tmux. If your phone drops"
    say "connection, the session keeps running on the Mac; reconnect later"
    say "and re-run the same alias to rejoin exactly where you left off."
    say ""
  else
    say ""
    say "${BOLD}Recommended: Termius${NC} (small fee, in the App Store)."
    say "  https://apps.apple.com/app/termius/id549039908"
    say ""
    say "Setup: install Termius, add a host using this Mac's Tailscale IP"
    say "or hostname, sign in. Once connected, run any tcc-* or tdcc-*"
    say "alias to launch Claude Code inside tmux. If your phone drops"
    say "connection, the session keeps running on the Mac; reconnect"
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
  say "for at-the-Mac use. The t-prefix aliases will be there if you change"
  say "your mind later, sir."
  say ""
fi

say ""
say "${BOLD}When you create a new project folder under ~/claudeProjects:${NC}"
say "  type ${BOLD}cc-refresh${NC} to regenerate aliases right now"
say "  (or wait until tomorrow morning; the LaunchAgent does it daily)"
say ""
say "${BOLD}To see the alias cheat sheet anytime:${NC} type ${BOLD}cc-help${NC}"
say ""
say "${BOLD}Aliases load in NEW Terminal windows.${NC} See the very end of"
say "this script for how to load them in your CURRENT Terminal."

press_enter "Press enter to continue, sir; next is Tailscale, the private network for SSH between your devices"

# === 8. Tailscale (required for agent building) ===
INSTALLED_TAILSCALE="no"
hd "Step 8: Tailscale"
say ""
say "${BOLD}What is Tailscale?${NC} A private, encrypted virtual network"
say "that lets your devices talk to each other as if they were all on the"
say "same Wi-Fi, no matter where they actually are. Once Tailscale is on,"
say "your laptop and this Mac mini reach each other at fixed IP addresses,"
say "even when one is at home and the other is at a coffee shop."
say ""
say "${BOLD}Why we use it:${NC} so you can SSH from your work computer into"
say "this Mac and run agents from a real terminal, not just the Chrome"
say "Remote Desktop graphical view. Chrome Remote Desktop is great for"
say "clicking around the desktop. Tailscale + SSH is what you want when"
say "running commands and editing files at the speed of typing."
say ""
say "${BOLD}Cost:${NC} free for personal use (up to 100 devices, 3 users)."
say "Setup takes about a minute."
say ""
if confirm "Shall I install Tailscale, sir? (required for agent building)"; then
  if [[ -d "/Applications/Tailscale.app" ]]; then
    ok "Tailscale.app already in /Applications"
  else
    sub_begin "brew install tailscale"
    brew install --cask tailscale
    sub_end "brew install tailscale"
    ok "Installed Tailscale"
  fi
  INSTALLED_TAILSCALE="yes"
  say ""
  ok "Tailscale install complete. Now we walk through three setup steps."
  say ""

  say "${BOLD}8a. Create your Tailscale account and sign in on this Mac.${NC}"
  say ""
  say "Open Tailscale via Spotlight (Cmd+Space, type 'Tailscale', enter)"
  say "or by clicking the Tailscale icon that should now appear in your"
  say "menu bar at the top right of the screen."
  say ""
  say "Once the app opens:"
  say "  1. Click 'Log in' (or 'Get Started' on first launch)."
  say "  2. Choose 'Sign up'."
  say "  3. ${BOLD}Use the agent's Google account from step 3${NC} as the"
  say "     identity for Tailscale. Same email, same password."
  say "  4. A browser tab opens to finish authentication. Authorize it."
  say "  5. The Tailscale icon in the menu bar should turn from gray to"
  say "     active, and the app should show this Mac as 'Connected'."
  say ""
  say "${BOLD}Important:${NC} create your OWN Tailscale account here. Do not"
  say "join someone else's tailnet."
  say ""
  press_enter "Press enter when this Mac shows 'Connected' in Tailscale, sir"

  say ""
  say "${BOLD}8b. Invite Will so the EH team can SSH in for support.${NC}"
  say ""
  say "Stay signed in to the agent's Google account in your browser, and"
  say "open this URL:"
  say "  $TAILSCALE_ADMIN_URL"
  say ""
  say "On the Users page:"
  say "  1. Click ${BOLD}'Invite users'${NC} (top right of the page)."
  say "  2. In the email field, enter:  $CONTACT_EMAIL"
  say "  3. Click ${BOLD}'Send invites'${NC}."
  say ""
  say "Will accepts the invite on his end. Once he does, his Mac will"
  say "appear in your tailnet and the EH team can SSH into this Mac"
  say "whenever you need help."
  say ""
  press_enter "Press enter when the invite has been sent, sir"

  say ""
  say "${BOLD}8c. Set up your own devices to reach this Mac.${NC}"
  say ""
  say "On your personal computer (and phone, laptop, etc.), you will"
  say "install Tailscale, but ${BOLD}DO NOT sign in with the agent's Google"
  say "account${NC}. Use your normal personal email instead."
  say ""
  say "${BOLD}Why we keep the identities separate:${NC} the agent's Google"
  say "account is for the agent (this Mac) only. Your personal devices"
  say "belong to YOU. Mixing them would put your phone, laptop, and"
  say "anything else you sign in with into the agent's tailnet, where"
  say "Will (and anyone else you invite later) could see them. Keeping"
  say "the identities separate means your devices stay yours; this Mac"
  say "is the only crossover point."
  say ""
  say "${BOLD}Steps:${NC}"
  say ""
  say "  1. ${BOLD}From the browser on this Mac${NC} (still signed in to the"
  say "     agent's Google account), open:"
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
  say "  5. Once signed in, this Mac (the agent) appears in your personal"
  say "     Tailscale device list. You can SSH into it from any of your"
  say "     personal devices."
  say ""
  say "${BOLD}Result:${NC} you can reach this Mac from any personal device,"
  say "but your personal devices are NOT exposed to the agent's tailnet."
  say "You access the agent; the agent does not access you."
  say ""
  press_enter "Press enter when you have invited your personal email and signed in on at least one personal device, sir"
else
  warn "Skipping Tailscale. Install later: brew install --cask tailscale"
fi

# === 9. Claude Code (required for agent building, with PATH verification) ===
INSTALLED_CLAUDE_CODE="no"
hd "Step 9: Claude Code"
if confirm "Shall I install Claude Code, sir? (required for agent building)"; then
  if ! command -v node >/dev/null 2>&1; then
    say "Node not found; installing via Homebrew."
    sub_begin "brew install node"
    brew install node
    sub_end "brew install node"
  fi
  ok "Node $(node --version) at $(command -v node)"

  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>&1 | head -1)"
    if confirm "Shall I update to the latest, sir?"; then
      sub_begin "npm install -g claude-code"
      npm install -g @anthropic-ai/claude-code
      sub_end "npm install -g claude-code"
    fi
  else
    say "Installing Claude Code globally via npm."
    say ""
    say "${BOLD}A note before npm runs, sir:${NC} you may see lines starting"
    say "with 'npm warn deprecated' about individual packages. Those are"
    say "simply package authors letting the world know they've published"
    say "a newer version. They are informational. The install still works."
    say "Pay them no mind."
    say ""
    sub_begin "npm install -g claude-code"
    npm install -g @anthropic-ai/claude-code
    sub_end "npm install -g claude-code"
  fi
  INSTALLED_CLAUDE_CODE="yes"
  verify_path claude
else
  warn "Skipping Claude Code. Install later with:"
  warn "  npm install -g @anthropic-ai/claude-code"
fi

press_enter "Press enter to continue, sir; next is OpenClaw"

# === 10. OpenClaw (required for agent building) ===
hd "Step 10: OpenClaw"
INSTALLED_OPENCLAW="no"
say ""
say "${BOLD}What OpenClaw is:${NC} a local-first AI agent gateway. It runs"
say "a small daemon on this Mac and exposes the 'openclaw' CLI plus a"
say "browser dashboard at http://127.0.0.1:18789/. The agents we build for"
say "you talk to OpenClaw to drive browsers, run shell tools, and so on."
say ""
say "${BOLD}Install plan:${NC} npm install OpenClaw globally (uses the Node"
say "we set up in step 9), then run 'openclaw onboard --install-daemon'"
say "to register the background service. Config lives at ~/.openclaw/."
say ""

say ""
say "${BOLD}Before we proceed, sir, please confirm you understand:${NC}"
say ""
say "  - OpenClaw installs a background service (a 'daemon') that stays"
say "    running on this Mac, even when no Terminal window is open."
say "  - After install, the wizard 'openclaw onboard --install-daemon'"
say "    runs to finish setup. ${BOLD}I am NOT going to launch that wizard"
say "    automatically${NC} because it can drop you into a terminal UI that"
say "    is hard to escape without prior knowledge. You will run it"
say "    yourself when you have your LLM credentials ready."
say "  - If you ever need to remove OpenClaw, the steps are:"
say "      npm uninstall -g openclaw"
say "      launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist"
say ""

if ack "Have I made this clear, and shall we proceed with the OpenClaw install?"; then
  if ! command -v node >/dev/null 2>&1; then
    err "Node is not installed. Re-run this script and answer Y to step 9 first."
    warn "Skipping OpenClaw."
  else
    if command -v openclaw >/dev/null 2>&1; then
      ok "OpenClaw already installed: $(openclaw --version 2>&1 | head -1 || true)"
      if confirm "Shall I update OpenClaw to the latest, sir?"; then
        sub_begin "npm install -g openclaw@latest"
        npm install -g openclaw@latest || warn "OpenClaw update returned an error; continuing"
        sub_end "npm install -g openclaw@latest"
      fi
    else
      say "Installing OpenClaw globally via npm..."
      say ""
      say "${BOLD}As before, sir:${NC} 'npm warn deprecated' lines that scroll"
      say "past are package authors flagging that newer versions exist."
      say "Informational only. Nothing is broken; the install completes."
      say ""
      sub_begin "npm install -g openclaw@latest"
      if npm install -g openclaw@latest; then
        sub_end "npm install -g openclaw@latest"
        ok "OpenClaw installed."
      else
        sub_end "npm install -g openclaw@latest"
        err "OpenClaw npm install failed. Check the messages above."
        warn "Skipping the onboard step. Retry later with:"
        warn "  npm install -g openclaw@latest"
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
      say "    your normal Terminal."
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
  warn "  npm install -g openclaw@latest"
  warn "  openclaw onboard --install-daemon"
fi

press_enter "Press enter to continue, sir; next is the PATH verification across every tool we installed"

# === 11. Final PATH verification ===
hd "Step 11: PATH verification"
say ""
say "${BOLD}Plain English, sir:${NC} every program we installed needs the Mac"
say "to know where to find it when you type its name. I am about to check"
say "that the Mac knows where each tool lives. If anything is not yet"
say "findable, I shall write a single line into a small startup file"
say "(~/.zprofile) so the Mac picks it up every time you open a new"
say "Terminal window from now on."
say ""
say "${BOLD}If I report needing to add something,${NC} you will see a note"
say "saying 'open a fresh Terminal'. That just means: close this Terminal"
say "window and open a new one for the fix to be live. The Terminal you"
say "have open right now will not see the change."
say ""
say "If any of the words above are unfamiliar, ask me and I will explain."
say "Type 'PATH', 'zprofile', 'shell', 'fresh Terminal', or 'help' for"
say "the full list. Or just press enter to run the check."
say ""
explain_or_continue
say ""
PATH_OK=1
verify_path brew || PATH_OK=0
verify_path git  || PATH_OK=0
if [[ "$INSTALLED_CLAUDE_CODE" == "yes" ]]; then
  verify_path node   || PATH_OK=0
  verify_path npm    || PATH_OK=0
  verify_path claude || PATH_OK=0
fi
if [[ "$INSTALLED_OPENCLAW" == "yes" ]]; then
  verify_path openclaw || PATH_OK=0
fi
if (( PATH_OK == 1 )); then
  ok "Everything resolves cleanly."
else
  warn "Some tools could not be resolved. Read the messages above for the specific"
  warn "command and where it should be located."
fi

press_enter "Press enter to continue, sir; next are the final headless test instructions"

# === 12. Headless acceptance test ===
hd "Step 12: Headless test"
say ""
say "${BOLD}One last thing, sir.${NC} We need to confirm this Mac works with"
say "no monitor, no keyboard, and no mouse attached. That is its actual"
say "job from here on: sit somewhere quiet while you control it from your"
say "work computer."
say ""
say "${BOLD}Walk through this with me:${NC}"
say ""
say "  1. Close any Chrome Remote Desktop tabs or windows currently open"
say "     ON THIS Mac (we want a clean state for the test)."
say "  2. Pop over to your work computer (laptop, desktop, whatever you"
say "     normally use)."
say "  3. Unplug the monitor, keyboard, and mouse from this Mac. (You"
say "     will be momentarily stranded; that is the point.)"
say "  4. Back at your work computer, open Chrome and switch to the"
say "     agent's Google profile - the one you set up in step 3."
say "  5. Visit:"
say "       $REMOTE_DESKTOP_URL"
say "  6. Click this Mac in the device list, enter the 6-digit PIN, and"
say "     sign in with your Mac password."
say "  7. You should now see this Mac's screen on your work computer,"
say "     including this very Terminal window, with this prompt waiting"
say "     for you."
say ""
say "${BOLD}Once you are reconnected via Chrome Remote Desktop and can see"
say "this Terminal,${NC} click into it and press enter below. That confirms"
say "the headless connection works. After that, this Mac never needs"
say "keyboard, mouse, or monitor attached again."
say ""
say "${BOLD}If something does not work,${NC} plug the peripherals back in"
say "and message Jarvis at https://equityhammer.com/Jarvis"
say ""

press_enter "Press enter (from inside Chrome Remote Desktop) once the headless connection works"

ok "Headless test confirmed."
say ""
say "You are free, sir, to put this Mac wherever it lives long term."
say "Keyboard, mouse, and monitor may all stay disconnected. A pleasure,"
say "as always."
say ""

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
  say "Chrome Remote Desktop: this Mac is reachable from any device signed"
  say "in to the agent's Google account, at $REMOTE_DESKTOP_URL"
  say "Tailscale: SSH from any device signed in to your tailnet."
  say ""
fi
if [[ "$INSTALLED_OPENCLAW" == "yes" ]]; then
  say "OpenClaw dashboard: http://127.0.0.1:18789/"
  say "OpenClaw status:    openclaw status"
  say ""
fi

# Big visible final step: how to load aliases NOW without opening a new Terminal.
# Also copy the magic line to the clipboard so the user just pastes it.
printf "\n${HAMMER}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n" >&2
printf "${ON_HAMMER}  LOAD ALIASES NOW  ${NC}  ${HAMMER}${BOLD}in this same Terminal${NC}\n" >&2
printf "${HAMMER}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n" >&2
say ""
if command -v pbcopy >/dev/null 2>&1; then
  printf 'source ~/.zshrc' | pbcopy
  say "I have copied the command you need into your clipboard, sir."
  say ""
  say "All you need to do now: press ${BOLD}Cmd+V${NC} to paste, then hit"
  say "${BOLD}Enter${NC}. Your new aliases will be live in this Terminal,"
  say "no need to open a fresh window."
  say ""
  printf "    ${BOLD}source ~/.zshrc${NC}    ${DIM}(already in your clipboard)${NC}\n" >&2
else
  say "After this script ends, copy and paste this single line to load the"
  say "aliases right now (no need to open a new Terminal):"
  say ""
  printf "    ${BOLD}source ~/.zshrc${NC}\n" >&2
fi
say ""
say "Or just open a fresh Terminal window, aliases load there automatically."
say ""
ok "All wrapped up here, sir. A pleasure, as always."
