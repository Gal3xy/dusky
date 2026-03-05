#!/usr/bin/env bash
# Bash 5.3+ | V2 OverlayFS & Snapper Sync Setup
set -Eeuo pipefail
export LC_ALL=C
trap 'printf "\n\033[1;31m[FATAL]\033[0m Script failed at line %d. Command: %s\n" "$LINENO" "$BASH_COMMAND" >&2; trap - ERR' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

sudo -v || exit 1
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

configure_mkinitcpio() {
    local conf_file="/etc/mkinitcpio.conf"
    
    [[ -f "$conf_file" ]] || { echo "FATAL: $conf_file not found." >&2; return 1; }

    local active_hooks
    active_hooks=$(grep -E '^\s*HOOKS\s*=' "$conf_file" | tail -n1 || true)
    
    local target_hook="btrfs-overlayfs"
    local wrong_hook="sd-btrfs-overlayfs"
    
    if echo "$active_hooks" | grep -qE '\bsystemd\b'; then
        target_hook="sd-btrfs-overlayfs"
        wrong_hook="btrfs-overlayfs"
        echo "INFO: Detected 'systemd' in hooks. Using $target_hook."
    fi

    if echo "$active_hooks" | grep -qE "\b${target_hook}\b"; then
        echo "INFO: $target_hook is already correctly configured."
        return 0
    fi

    sudo sed -i -E "s/\b${wrong_hook}\b\s*//g" "$conf_file"

    if ! echo "$active_hooks" | grep -qE '\bfilesystems\b'; then
        echo "FATAL: 'filesystems' hook missing. Cannot inject overlayfs." >&2; return 1
    fi

    sudo sed -i -E "s/\b(filesystems)\b/\1 ${target_hook}/" "$conf_file"
    echo "Successfully injected $target_hook into $conf_file"
}
execute "Dynamically inject correct OverlayFS hook into mkinitcpio.conf" configure_mkinitcpio

rebuild_initramfs() {
    # Using native limine-update wrapper instead of mkinitcpio directly
    sudo limine-update
}
execute "Rebuild Linux initramfs via limine-update wrapper" rebuild_initramfs

configure_sync_daemon() {
    local conf_file="/etc/limine-snapper-sync.conf"
    
    [[ -f "$conf_file" ]] || { echo "FATAL: $conf_file not found." >&2; return 1; }

    local root_subvol
    root_subvol=$(findmnt -fno OPTIONS / | grep -oP 'subvol=/?\K[^,]+' || echo "@")
    local snapshots_subvol="@snapshots"

    if grep -q "^ROOT_SUBVOLUME_PATH=" "$conf_file"; then
        sudo sed -i "s|^ROOT_SUBVOLUME_PATH=.*|ROOT_SUBVOLUME_PATH=\"/${root_subvol}\"|" "$conf_file"
    else
        echo "ROOT_SUBVOLUME_PATH=\"/${root_subvol}\"" | sudo tee -a "$conf_file" >/dev/null
    fi

    if grep -q "^ROOT_SNAPSHOTS_PATH=" "$conf_file"; then
        sudo sed -i "s|^ROOT_SNAPSHOTS_PATH=.*|ROOT_SNAPSHOTS_PATH=\"/${snapshots_subvol}\"|" "$conf_file"
    else
        echo "ROOT_SNAPSHOTS_PATH=\"/${snapshots_subvol}\"" | sudo tee -a "$conf_file" >/dev/null
    fi
    
    echo "Sync daemon paths configured to /${root_subvol} and /${snapshots_subvol}"
}
execute "Configure limine-snapper-sync paths for top-level subvolumes" configure_sync_daemon

configure_snap_pac() {
    if [[ -f /etc/snap-pac.ini ]] && sed -n '/^\[home\]/,/^\[/p' /etc/snap-pac.ini | grep -q '.'; then
        if sed -n '/^\[home\]/,/^\[/p' /etc/snap-pac.ini | grep -q '^\s*snapshot\s*='; then
            sudo sed -i '/^\[home\]/,/^\[/{s/^\s*snapshot\s*=.*/snapshot = no/}' /etc/snap-pac.ini
        else
            sudo sed -i '/^\[home\]/a snapshot = no' /etc/snap-pac.ini
        fi
    else
        printf '\n[home]\nsnapshot = no\n' | sudo tee -a /etc/snap-pac.ini >/dev/null
    fi
}
execute "Configure snap-pac to ignore /home" configure_snap_pac

enable_services_and_sync() {
    sudo systemctl daemon-reload
    sudo systemctl enable --now snapper-cleanup.timer
    sudo systemctl enable --now limine-snapper-sync.service
    
    # Take baseline to seed database
    sudo snapper -c root create -c important -d "Baseline V2 Architecture" || true
    
    echo "Forcing final boot menu sync..."
    sudo limine-snapper-sync
}
execute "Enable timers, take baseline snapshot, and populate boot menu" enable_services_and_sync
