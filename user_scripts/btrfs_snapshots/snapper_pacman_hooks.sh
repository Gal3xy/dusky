#!/usr/bin/env bash
# Bash 5.3+ | Arch Linux | OverlayFS & Sync Setup
set -Eeuo pipefail
export LC_ALL=C
umask 022

trap 'rc=$?; printf "\n\033[1;31m[FATAL]\033[0m Script failed at line %d. Command: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }

execute() {
    local desc="$1"
    shift
    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
    else
        printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
        read -rp "Execute this step? [Y/n] " response || fatal "Input closed."
        if [[ "${response,,}" =~ ^(n|no)$ ]]; then printf 'Skipped.\n'; return 0; fi
        "$@"
    fi
}

sudo -v || fatal "Cannot obtain sudo privileges."
( while true; do sudo -n -v 2>/dev/null; sleep 240; done ) &
SUDO_PID=$!
trap 'kill "$SUDO_PID" 2>/dev/null || true' EXIT

configure_mkinitcpio() {
    local conf_file="/etc/mkinitcpio.conf"
    local hook_str="btrfs-overlayfs"
    
    if grep -E '^\s*HOOKS\s*=.*systemd' "$conf_file" >/dev/null; then
        hook_str="sd-btrfs-overlayfs"
    fi

    # Read the effective hooks array carefully
    local current_hooks
    current_hooks=$(bash -c 'source /etc/mkinitcpio.conf; echo "${HOOKS[*]}"')

    if [[ " $current_hooks " == *" $hook_str "* ]]; then
        info "OverlayFS hook ($hook_str) is already configured."
        return 0
    fi

    if [[ " $current_hooks " != *" filesystems "* ]]; then
        fatal "'filesystems' hook missing. Cannot securely inject overlayfs."
    fi

    # Safely inject via drop-in file (Arch standard practice)
    sudo mkdir -p /etc/mkinitcpio.conf.d
    echo "HOOKS=(${current_hooks/filesystems/filesystems $hook_str})" | sudo tee /etc/mkinitcpio.conf.d/99-btrfs-overlay.conf >/dev/null
    info "Injected $hook_str into mkinitcpio.conf.d/99-btrfs-overlay.conf"
}

rebuild_initramfs() {
    sudo limine-update
    info "Initramfs rebuilt and Limine updated."
}

configure_sync_daemon() {
    local conf_file="/etc/limine-snapper-sync.conf"
    local root_subvol
    root_subvol=$(findmnt -fno OPTIONS / | awk -F'subvol=/?' '{print $2}' | cut -d, -f1 || echo "@")
    
    if [[ -z "$root_subvol" ]]; then root_subvol="@"; fi

    sudo sed -i -E "s|^#?ROOT_SUBVOLUME_PATH=.*|ROOT_SUBVOLUME_PATH=\"/${root_subvol}\"|" "$conf_file"
    sudo sed -i -E "s|^#?ROOT_SNAPSHOTS_PATH=.*|ROOT_SNAPSHOTS_PATH=\"/@snapshots\"|" "$conf_file"
    
    info "Configured limine-snapper-sync paths (Root: /${root_subvol}, Snaps: /@snapshots)"
}

configure_snap_pac() {
    local ini_file="/etc/snap-pac.ini"
    if [[ ! -f "$ini_file" ]]; then
        printf '[home]\nsnapshot = no\n' | sudo tee "$ini_file" >/dev/null
    elif ! grep -q '^\[home\]' "$ini_file"; then
        printf '\n[home]\nsnapshot = no\n' | sudo tee -a "$ini_file" >/dev/null
    else
        sudo sed -i '/^\[home\]/,/^\[/{s/^[[:space:]]*snapshot[[:space:]]*=.*/snapshot = no/}' "$ini_file"
    fi
    info "Disabled snap-pac for /home to prevent user-data rollback loss."
}

prime_dummy_previous_kernel() {
    local machine_id kernel_dir
    machine_id=$(cat /etc/machine-id)
    kernel_dir="/boot/${machine_id}/linux"

    if [[ -d "$kernel_dir" ]]; then
        if [[ -f "${kernel_dir}/vmlinuz-linux" && ! -f "${kernel_dir}/vmlinuz-linux-previous" ]]; then
            sudo cp "${kernel_dir}/vmlinuz-linux" "${kernel_dir}/vmlinuz-linux-previous"
            info "Primed dummy vmlinuz-linux-previous"
        fi
        if [[ -f "${kernel_dir}/initramfs-linux" && ! -f "${kernel_dir}/initramfs-linux-previous.img" ]]; then
            sudo cp "${kernel_dir}/initramfs-linux" "${kernel_dir}/initramfs-linux-previous.img"
            info "Primed dummy initramfs-linux-previous.img"
        fi
    fi
}

enable_services_and_sync() {
    sudo systemctl daemon-reload
    sudo systemctl enable --now snapper-cleanup.timer
    sudo systemctl enable --now limine-snapper-sync.service
    
    # Generate the dummy kernels so the orchestrator doesn't throw Wayland UI errors on first run
    prime_dummy_previous_kernel

    sudo snapper -c root create -c important -d "Baseline V2.1 Architecture" || true
    sudo limine-snapper-sync
    info "Baseline snapshot created and boot menu synchronized."
}

execute "Inject OverlayFS hook via drop-in" configure_mkinitcpio
execute "Rebuild initramfs" rebuild_initramfs
execute "Configure daemon subvolume paths" configure_sync_daemon
execute "Protect /home in snap-pac" configure_snap_pac
execute "Enable timers and take baseline" enable_services_and_sync
