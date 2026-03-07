#!/usr/bin/env bash
# This script installs package groups on Arch Linux.
# --------------------------------------------------------------------------
# Arch Linux / Hyprland / UWSM - Elite System Installer (v3.2 - Hardened)
# --------------------------------------------------------------------------

set -Eeuo pipefail

# 1. Root Check
if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || {
    printf 'sudo is required to elevate privileges. Run this script as root.\n' >&2
    exit 1
  }

  script_path="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  printf 'Elevating privileges...\n' >&2
  exec sudo -- /usr/bin/bash "$script_path" "$@"
fi

# 2. Safety & Aesthetics
BOLD=''
GREEN=''
YELLOW=''
RED=''
CYAN=''
RESET=''

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
  BOLD="$(tput bold)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  RED="$(tput setaf 1)"
  CYAN="$(tput setaf 6)"
  RESET="$(tput sgr0)"
fi

# --------------------------------------------------------------------------
# --- PACKAGE GROUPS ---
# Keep your existing arrays above this section unchanged if you already have them.
# Any group not already defined is initialized empty here.
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# HOW TO CONFIGURE PACKAGE GROUPS
# --------------------------------------------------------------------------
# This script uses "Defensive Guarding" for package lists. 
#
# 1. THE SAFETY CHECK:
#    At the top of the script, we ensure every list exists (even if empty)
#    to prevent the script from crashing.
#
# 2. THE DEFAULT LISTS (Below):
#    We use 'if ! declare -p' to check if a list is already set.
#    - IF YOU DEFINED A LIST in your shell: The script respects your choice.
#    - IF THE LIST IS EMPTY/MISSING: The script loads the defaults below.
#
# TO ADD YOUR OWN: 
# Wrap your list in the 'if ! declare -p NAME' block as seen below.
# This ensures your custom lists aren't accidentally overwritten!
# --------------------------------------------------------------------------
#
declare -p pkgs_graphics >/dev/null 2>&1 || declare -a pkgs_graphics=()
declare -p pkgs_hyprland >/dev/null 2>&1 || declare -a pkgs_hyprland=()
declare -p pkgs_appearance >/dev/null 2>&1 || declare -a pkgs_appearance=()
declare -p pkgs_desktop >/dev/null 2>&1 || declare -a pkgs_desktop=()
declare -p pkgs_audio >/dev/null 2>&1 || declare -a pkgs_audio=()
declare -p pkgs_filesystem >/dev/null 2>&1 || declare -a pkgs_filesystem=()
declare -p pkgs_network >/dev/null 2>&1 || declare -a pkgs_network=()
declare -p pkgs_terminal >/dev/null 2>&1 || declare -a pkgs_terminal=()
declare -p pkgs_dev >/dev/null 2>&1 || declare -a pkgs_dev=()
declare -p pkgs_multimedia >/dev/null 2>&1 || declare -a pkgs_multimedia=()
declare -p pkgs_sysadmin >/dev/null 2>&1 || declare -a pkgs_sysadmin=()
declare -p pkgs_gnome >/dev/null 2>&1 || declare -a pkgs_gnome=()

# Group 1: dusky_update
if ! declare -p pkgs_productivity >/dev/null 2>&1; then
  declare -a pkgs_productivity=(
    "wl-clip-persist"

    # nemo
    "nemo"
    "nemo-fileroller"
    "file-roller"
    "gvfs"
    "gvfs-smb"
    "gvfs-mtp"
    "gvfs-gphoto2"
    "gvfs-google"
    "gvfs-nfs"
    "gvfs-afc"
    "gvfs-dnssd"
    "ffmpegthumbnailer"
    "webp-pixbuf-loader"
    "poppler-glib"
    "libgsf"
    "gnome-epub-thumbnailer"
    "resvg"
    "nemo-python"
    "nemo-compare"
    "meld"
    "nemo-media-columns"
    "nemo-audio-tab"
    "nemo-image-converter"
    "nemo-emblems"
    "nemo-repairer"
    "nemo-share"
    "python-gobject"
    "dconf-editor"
    "xreader"
    "gst-libav"
    "gst-plugins-good"
    "nemo-pastebin"
    # "nemo-terminal"
    "papirus-icon-theme-git"
  )
fi

# --------------------------------------------------------------------------
# --- ENGINE ---
# --------------------------------------------------------------------------

declare -gi TOTAL_FAILURES=0
declare -a FAILED_PACKAGES=()

die() {
  printf '%s[X] %s%s\n' "$RED" "$1" "$RESET" >&2
  exit 1
}

wait_for_pacman_lock() {
  local lock_file='/var/lib/pacman/db.lck'
  local waited=0
  local max_wait=300

  while [[ -e $lock_file ]]; do
    if (( waited == 0 )); then
      printf '%s[!] pacman is locked by another process. Waiting...%s\n' "$YELLOW" "$RESET" >&2
    fi

    sleep 2
    (( waited += 2 ))

    if (( waited >= max_wait )); then
      return 1
    fi
  done
}

pacman_run() {
  wait_for_pacman_lock || die 'pacman lock did not clear within 300 seconds.'
  pacman "$@"
}

dedupe_into() {
  local -n source_ref="$1"
  local -n dest_ref="$2"
  local -A seen=()
  local pkg=''

  dest_ref=()

  for pkg in "${source_ref[@]}"; do
    [[ -n $pkg ]] || continue

    if [[ -z ${seen["$pkg"]+x} ]]; then
      seen["$pkg"]=1
      dest_ref+=("$pkg")
    fi
  done
}

ensure_pacman_keyring() {
  printf '%s:: Preparing Arch keyring...%s\n' "$BOLD" "$RESET"

  if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg ]]; then
    pacman-key --init
  fi

  pacman-key --populate archlinux
  pacman_run -Sy --noconfirm --needed archlinux-keyring
  pacman-key --populate archlinux
}

full_upgrade() {
  printf '\n%s:: Full System Upgrade...%s\n' "$BOLD" "$RESET"

  # The sync database was just refreshed in ensure_pacman_keyring().
  # Use -Su immediately afterward to avoid a redundant second sync.
  pacman_run -Su --noconfirm
}

install_group() {
  local group_name="$1"
  local array_name="$2"
  local -a pkgs=()
  local pkg=''
  local fail_count=0

  dedupe_into "$array_name" pkgs
  (( ${#pkgs[@]} )) || return 0

  printf '\n%s:: Processing Group: %s%s\n' "$BOLD$CYAN" "$group_name" "$RESET"

  # Strategy A: Batch Install
  if pacman_run -S --needed --noconfirm -- "${pkgs[@]}"; then
    printf '%s [OK] Batch installation successful.%s\n' "$GREEN" "$RESET"
    return 0
  fi

  # Strategy B: Fallback Individual Install
  printf '\n%s [!] Batch transaction failed. Retrying individually...%s\n' "$YELLOW" "$RESET"

  for pkg in "${pkgs[@]}"; do
    if pacman_run -S --needed --noconfirm -- "$pkg" >/dev/null 2>&1; then
      printf '  %s[+] Installed:%s %s\n' "$GREEN" "$RESET" "$pkg"
      continue
    fi

    if [[ -t 0 && -t 1 ]]; then
      printf '  %s[?] Intervention Needed:%s %s\n' "$YELLOW" "$RESET" "$pkg"

      if pacman_run -S --needed -- "$pkg"; then
        printf '  %s[+] Installed (Manual):%s %s\n' "$GREEN" "$RESET" "$pkg"
        continue
      fi
    else
      printf '  %s[X] Auto install failed in non-interactive mode:%s %s\n' "$RED" "$RESET" "$pkg"
    fi

    printf '  %s[X] Not Installed:%s %s\n' "$RED" "$RESET" "$pkg"
    FAILED_PACKAGES+=("$group_name :: $pkg")
    (( ++fail_count ))
    (( ++TOTAL_FAILURES ))
  done

  if (( fail_count > 0 )); then
    printf '%s [!] Group completed with %d failure(s).%s\n' "$YELLOW" "$fail_count" "$RESET"
    return 1
  fi

  printf '%s [OK] Recovery successful. All packages installed.%s\n' "$GREEN" "$RESET"
  return 0
}

run_group() {
  local group_name="$1"
  local array_name="$2"

  if ! install_group "$group_name" "$array_name"; then
    :
  fi
}

# --------------------------------------------------------------------------
# --- EXECUTION ---
# --------------------------------------------------------------------------

ensure_pacman_keyring
full_upgrade

run_group "Graphics & Drivers" pkgs_graphics
run_group "Hyprland Core" pkgs_hyprland
run_group "GUI Appearance" pkgs_appearance
run_group "Desktop Experience" pkgs_desktop
run_group "Audio & Bluetooth" pkgs_audio
run_group "Filesystem Tools" pkgs_filesystem
run_group "Networking" pkgs_network
run_group "Terminal & CLI" pkgs_terminal
run_group "Development" pkgs_dev
run_group "Multimedia" pkgs_multimedia
run_group "System Admin" pkgs_sysadmin
run_group "Gnome Utilities" pkgs_gnome
run_group "dusky_update" pkgs_productivity

if (( TOTAL_FAILURES == 0 )); then
  printf '\n%s%s:: INSTALLATION COMPLETE ::%s\n' "$BOLD" "$GREEN" "$RESET"
  printf 'Packages installed.\n'
  exit 0
fi

printf '\n%s%s:: INSTALLATION COMPLETED WITH %d FAILURE(S) ::%s\n' "$BOLD" "$YELLOW" "$TOTAL_FAILURES" "$RESET"
printf 'Packages not installed:\n'
printf '%s\n' "${FAILED_PACKAGES[@]}"

exit 1
