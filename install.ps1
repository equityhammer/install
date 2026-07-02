# Equity Hammer - universal Windows entry point (PowerShell).
#
# One command for a Windows client, pasted into PowerShell:
#
#   irm https://raw.githubusercontent.com/iamfoehammer/install/main/install.ps1 | iex
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

$EntryUrl = 'https://raw.githubusercontent.com/iamfoehammer/install/main/install.sh'

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

Write-EH "Equity Hammer installer (Windows)"

# --- Is the wsl command even present? ---
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
    Write-Warn "WSL is not available on this machine yet."
    Invoke-WslInstall "Install WSL now? Requires administrator rights and a reboot."
    return
}

# --- WSL command exists; is a real Linux distro installed? ---
# 'wsl -l -q' lists installed distro names. Filter out the docker helper
# distros and any blank lines (the output is UTF-16 with NUL bytes).
$distros = @()
try {
    $raw = & wsl.exe -l -q 2>$null
    $distros = $raw | ForEach-Object { ($_ -replace "`0","").Trim() } | Where-Object { $_ -ne '' }
} catch {
    $distros = @()
}
$realDistros = $distros | Where-Object { $_ -notmatch 'docker-desktop' }

if (-not $realDistros -or $realDistros.Count -eq 0) {
    Write-Warn "WSL is present but no Linux distro is installed."
    Invoke-WslInstall "Install the default Ubuntu distro now? Requires a reboot."
    return
}

# --- We have a distro. Hand off to the universal install.sh inside WSL. ---
$target = $realDistros[0]
Write-Ok "WSL distro found: $target"
Write-EH "Handing off to the Jarvis setup inside WSL now..."
Write-EH ""

# Run install.sh in an interactive login shell so its prompts (which read from
# /dev/tty) work. install.sh detects Linux and runs the WSL bootstrap.
& wsl.exe -d $target -e bash -lic "curl -fsSL '$EntryUrl' | bash"

$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Err "The WSL setup exited with code $code."
    Write-EH "You can retry by pasting the same line again."
} else {
    Write-Ok "WSL setup finished. Open your Ubuntu terminal to start working."
}
