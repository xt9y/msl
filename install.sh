#!/bin/sh
set -eu

# MSL — MacOS Subsystem for Linux
# Install script for https://xt9y.de/msl
# Usage: curl https://xt9y.de/msl | sh

BREW_TAP="xt9y/MSL"
FORMULAE="msl msld"

# --- Colors ---
if [ -t 1 ]; then
    BOLD="\033[1m"
    GREEN="\033[32m"
    RED="\033[31m"
    YELLOW="\033[33m"
    CYAN="\033[36m"
    RESET="\033[0m"
else
    BOLD=""
    GREEN=""
    RED=""
    YELLOW=""
    CYAN=""
    RESET=""
fi

info()  { printf "${CYAN}==>${RESET} %s\n" "$1"; }
ok()    { printf "${GREEN}==>${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}!!>${RESET} %s\n" "$1"; }
error() { printf "${RED}!!>${RESET} %s\n" "$1"; }

# --- Preflight checks ---

# Must be macOS
if [ "$(uname -s)" != "Darwin" ]; then
    error "MSL is macOS-only. You're on $(uname -s)."
    exit 1
fi

# Must be Apple Silicon
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    error "MSL requires Apple Silicon (M1/M2/M3/M4). You're on $ARCH."
    exit 1
fi

# Must be macOS 14+ (Sonoma)
SW_VERS=$(sw_vers -productVersion 2>/dev/null || echo "0")
MAJOR=$(echo "$SW_VERS" | cut -d. -f1)
if [ "$MAJOR" -lt 14 ] 2>/dev/null; then
    error "MSL requires macOS 14 (Sonoma) or later. You're on $SW_VERS."
    exit 1
fi

ok "macOS $SW_VERS on $ARCH — supported"

# --- Step 1: Xcode Command Line Tools ---
info "Checking Xcode Command Line Tools..."
if ! xcode-select -p >/dev/null 2>&1; then
    warn "Command Line Tools not found. Installing (this may take a few minutes)..."
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    PROD=$(softwareupdate -l | grep -B 1 "Command Line Tools" | tail -1 | sed 's/.*: //')
    if [ -n "$PROD" ]; then
        softwareupdate -i "$PROD" --verbose
    else
        error "Could not find Command Line Tools via softwareupdate."
        error "Install them manually: xcode-select --install"
        exit 1
    fi
    ok "Command Line Tools installed"
else
    ok "Command Line Tools already installed"
fi

# --- Step 2: Homebrew ---
info "Checking Homebrew..."
if command -v brew >/dev/null 2>&1; then
    ok "Homebrew already installed"
else
    warn "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Source brew into the current shell
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    else
        error "Homebrew installation failed — 'brew' not found after install."
        exit 1
    fi
    ok "Homebrew installed"
fi

# --- Step 3: Tap + trust + install MSL ---
info "Tapping ${BREW_TAP}..."
brew tap "$BREW_TAP"

info "Trusting ${BREW_TAP}..."
brew trust --tap "$BREW_TAP" 2>/dev/null || true

info "Installing MSL formulae..."
brew install $FORMULAE
ok "MSL installed"

# --- Step 3b: XQuartz (cask — can't be a formula dependency) ---
info "Checking XQuartz..."
if [ -d "/Applications/Utilities/XQuartz.app" ] || [ -d "/Applications/XQuartz.app" ]; then
    ok "XQuartz already installed"
else
    warn "XQuartz not found. Installing (needed for GUI forwarding)..."
    HOMEBREW_NO_INTERACTIVE=1 brew install --cask xquartz </dev/null 2>&1
    if [ -d "/Applications/Utilities/XQuartz.app" ] || [ -d "/Applications/XQuartz.app" ]; then
        ok "XQuartz installed"
    else
        warn "XQuartz install may have failed. GUI apps won't work until you install it manually:"
        warn "    brew install --cask xquartz"
    fi
fi

# --- Step 4: Verify ---
if command -v msl >/dev/null 2>&1; then
    V=$(msl version 2>/dev/null || echo "unknown")
    ok "msl binary found (version: $V)"
else
    warn "msl not on PATH. You may need to open a new terminal or add brew to your PATH."
    warn "If Homebrew is at /opt/homebrew (Apple Silicon), add this to your shell profile:"
    printf "    eval \"\$(/opt/homebrew/bin/brew shellenv)\"\n"
fi

# --- Step 5: Offer setup ---
printf "\n"
printf "${BOLD}MSL is installed!${RESET}\n"
printf "\n"
printf "Next steps:\n"
printf "  ${CYAN}msl setup${RESET}        Download the Arch Linux ARM image (~1GB) and configure the VM\n"
printf "  ${CYAN}msl start${RESET}        Boot the VM\n"
printf "  ${CYAN}msl shell${RESET}        Open an interactive shell in the VM\n"
printf "\n"
printf "Custom setup options:\n"
printf "  ${CYAN}msl setup --disk-size 16 --ram-size 4 --cpu-cores 4${RESET}\n"
printf "\n"

if [ -t 0 ]; then
    printf "Run ${BOLD}msl setup${RESET} now? [y/N] "
    read -r ANSWER
    case "$ANSWER" in
        y|Y|yes|YES)
            info "Starting msl setup..."
            exec msl setup
            ;;
        *)
            printf "Skipped. Run ${BOLD}msl setup${RESET} when ready.\n"
            ;;
    esac
else
    printf "Run ${BOLD}msl setup${RESET} to download the VM image and configure resources.\n"
fi