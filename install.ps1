# Equity Hammer - universal Windows entry point (PowerShell).
#
# One command for a Windows client, pasted into PowerShell:
#
#   irm https://raw.githubusercontent.com/equityhammer/install/main/install.ps1 | iex
#
# What it does:
#   1. Checks whether WSL is installed with at least one Linux distro.
#   2. If NOT: offers to run 'wsl --install' (needs admin + a reboot), then
#      tells the user to reboot, finish the Ubuntu user setup, and paste the
#      same line again.
#   3. If YES: hands off into the distro and runs the universal install.sh,
#      which detects Linux and launches the Jarvis WSL bootstrap.
#
# A bash script cannot detect that it is being pasted into PowerShell, so this
# small shim is the Windows-side front door. Everything after WSL is ready runs
# through the same install.sh that Mac and WSL users hit directly.

$ErrorActionPreference = 'Stop'

$EntryUrl = 'https://raw.githubusercontent.com/equityhammer/install/main/install.sh'

function Write-EH   { param($m) Write-Host "[EH] $m" -ForegroundColor DarkYellow }
function Write-Ok   { param($m) Write-Host "[EH] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[EH] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "[EH] $m" -ForegroundColor Red }

function Invoke-WslInstall {
    param($Prompt)
    $ans = Read-Host "[EH] $Prompt (Y/n)"
    if ($ans -eq '' -or $ans -match '^[Yy]') {
        Write-EH "Launching 'wsl --install' in an elevated window..."
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoExit','-Command','wsl --install'
        Write-EH ""
        Write-EH "Next steps, in order:"
        Write-EH "  1. Approve the User Account Control (UAC) prompt."
        Write-EH "  2. Let the install finish, then REBOOT when it asks."
        Write-EH "  3. After reboot, Ubuntu opens and asks you to pick a"
        Write-EH "     username and password. Complete that."
        Write-EH "  4. Open PowerShell again and paste the SAME line you just"
        Write-EH "     ran. This time it launches the setup inside WSL."
    } else {
        Write-EH "No problem. Install WSL yourself later with:  wsl --install"
        Write-EH "Then re-run this line."
    }
}

function Initialize-WindowsExtras {
    # Nudge the client toward the modern shell: Windows Terminal + PowerShell 7.
    # Detect both; offer to install whatever is missing via winget. Non-fatal.
    $hasWT   = [bool](Get-Command wt.exe   -ErrorAction SilentlyContinue)
    $hasPwsh = [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue)

    if ($hasWT)   { Write-Ok   "Windows Terminal is installed." }
    else          { Write-Warn "Windows Terminal is not installed." }
    if ($hasPwsh) { Write-Ok   "PowerShell 7 is installed." }
    else          { Write-Warn "PowerShell 7 (pwsh) is not installed. You are on $($PSVersionTable.PSVersion)." }

    if ($hasWT -and $hasPwsh) { return }

    $hasWinget = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
    if (-not $hasWinget) {
        Write-EH "winget is not available, so I cannot auto-install. Install manually:"
        if (-not $hasWT)   { Write-EH "  Windows Terminal: https://aka.ms/terminal (or the Microsoft Store)" }
        if (-not $hasPwsh) { Write-EH "  PowerShell 7 (MSI): https://github.com/PowerShell/PowerShell/releases/latest" }
        return
    }

    $ans = Read-Host "[EH] Install the missing tool(s) now via winget? (Y/n)"
    if (-not ($ans -eq '' -or $ans -match '^[Yy]')) {
        Write-EH "Skipping. You can install them later."
        return
    }

    if (-not $hasWT) {
        Write-EH "Installing Windows Terminal..."
        winget install --id Microsoft.WindowsTerminal -e --source winget --accept-package-agreements --accept-source-agreements
    }
    if (-not $hasPwsh) {
        # Microsoft.PowerShell is the MSI build (stable path), NOT the Store/MSIX
        # package - deliberately, since MSIX breaks scheduled tasks and sshd.
        Write-EH "Installing PowerShell 7 (MSI build)..."
        winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements
    }
    Write-EH "If a tool was just installed, reopen your terminal (ideally Windows Terminal running pwsh) before continuing."
}

Write-EH "Equity Hammer installer (Windows)"
Initialize-WindowsExtras

# --- Is the wsl command even present? ---
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
    Write-Warn "WSL is not available on this machine yet."
    Invoke-WslInstall "Install WSL now? Requires administrator rights and a reboot."
    return
}

# --- WSL command exists; is a real Linux distro installed and runnable? ---
# Don't parse `wsl -l -q` for the name: wsl.exe emits UTF-16LE and PowerShell
# mangles it (e.g. "Ubuntu" -> "U"). Instead, just try to run a trivial command
# in the DEFAULT distro and check the exit code. No text parsing, nothing to
# truncate. The handoff below also uses the default distro (no -d), so a bad
# name can never break it.
& wsl.exe -e true 2>$null | Out-Null
$hasDistro = ($LASTEXITCODE -eq 0)

if (-not $hasDistro) {
    Write-Warn "WSL is present but no Linux distro is installed (or none is set as default)."
    Invoke-WslInstall "Install the default Ubuntu distro now? Requires a reboot."
    return
}

# --- We have a working default distro. Hand off to install.sh inside it. ---
Write-Ok "WSL is ready."
Write-EH "Handing off to the Jarvis setup inside WSL now..."
Write-EH ""

# Run install.sh in an interactive login shell so its prompts (which read from
# /dev/tty) work. install.sh detects Linux and runs the WSL bootstrap.
& wsl.exe -e bash -lic "curl -fsSL '$EntryUrl' | bash"

$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Err "The WSL setup exited with code $code."
    Write-EH "You can retry by pasting the same line again."
} else {
    Write-Ok "WSL setup finished. Open your Ubuntu terminal to start working."
}
