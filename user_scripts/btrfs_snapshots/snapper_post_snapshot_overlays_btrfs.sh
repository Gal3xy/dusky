#!/usr/bin/env bash
# Bash 5.3+ | Configure Limine BTRFS OverlayFS for RO Snapshots
set -Eeuo pipefail
export LC_ALL=C

# Execute once, print safely, then destroy the trap to prevent cascade noise
trap 'printf "\n\033[1;31m[FATAL]\033[0m Script failed at line %d. Command: %s\n" "$LINENO" "$BASH_COMMAND" >&2; trap - ERR' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

sudo -v || { echo "FATAL: Cannot obtain sudo privileges." >&2; exit 1; }
( while true; do sudo -n -v 2>/dev/null; sleep 240; done ) &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null || true' EXIT

execute() {
    local desc="$1"
    shift
    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
    else
        printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
        read -rp "Execute this step? [Y/n] " response || { printf '\nInput closed; aborting.\n' >&2; exit 1; }
        if [[ "${response,,}" =~ ^(n|no)$ ]]; then echo "Skipped."; return 0; fi
        "$@"
    fi
}

install_overlay_package() {
    local aur_helper=""
    if command -v paru &>/dev/null; then aur_helper="paru";
    elif command -v yay &>/dev/null; then aur_helper="yay"; fi
    
    [[ -n "$aur_helper" ]] || { echo "FATAL: No AUR helper (yay/paru) found." >&2; return 1; }
    
    echo "Installing limine-mkinitcpio-hook from AUR..."
    "$aur_helper" -S --needed --noconfirm limine-mkinitcpio-hook
}
execute "Install the native Limine mkinitcpio hook package" install_overlay_package

configure_mkinitcpio() {
    local conf_file="/etc/mkinitcpio.conf"
    
    if [[ ! -f "$conf_file" ]]; then
        echo "FATAL: $conf_file not found." >&2
        return 1
    fi

    local active_hooks
    active_hooks=$(grep -E '^\s*HOOKS\s*=' "$conf_file" | tail -n1 || true)
    
    if [[ -z "$active_hooks" ]]; then
        echo "FATAL: Could not parse HOOKS array in $conf_file" >&2
        return 1
    fi

    # Determine standard vs systemd hooks based on Arch Wiki rules
    local target_hook="btrfs-overlayfs"
    local wrong_hook="sd-btrfs-overlayfs"
    
    if echo "$active_hooks" | grep -qE '\bsystemd\b'; then
        target_hook="sd-btrfs-overlayfs"
        wrong_hook="btrfs-overlayfs"
        echo "INFO: Detected 'systemd' in hooks. Using $target_hook."
    else
        echo "INFO: Detected standard udev hooks. Using $target_hook."
    fi

    if echo "$active_hooks" | grep -qE "\b${target_hook}\b"; then
        echo "INFO: $target_hook is already correctly configured. Skipping injection."
        return 0
    fi

    # Strip out the wrong hook if the user mistakenly added it in the past
    sudo sed -i -E "s/\b${wrong_hook}\b\s*//g" "$conf_file"

    # Safely inject the correct hook exactly after 'filesystems'
    if ! echo "$active_hooks" | grep -qE '\bfilesystems\b'; then
        echo "FATAL: The 'filesystems' hook is missing from your mkinitcpio.conf. Cannot inject overlayfs safely." >&2
        return 1
    fi

    sudo sed -i -E "s/\b(filesystems)\b/\1 ${target_hook}/" "$conf_file"
    echo "Successfully injected $target_hook into $conf_file"
}
execute "Dynamically inject correct OverlayFS hook into mkinitcpio.conf" configure_mkinitcpio

rebuild_initramfs() {
    sudo mkinitcpio -P
}
execute "Rebuild Linux initramfs images" rebuild_initramfs

sync_limine() {
    echo "Synchronizing Limine to register the new initramfs..."
    sudo limine-snapper-sync
}
execute "Sync Limine boot menu" sync_limine
