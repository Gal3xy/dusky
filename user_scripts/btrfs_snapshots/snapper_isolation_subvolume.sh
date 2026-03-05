#!/usr/bin/env bash
# Bash 5.3+ | V2 Snapper Subvolume Isolation
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

unmount_snapshots() {
    sudo umount /.snapshots 2>/dev/null || true
    sudo umount /home/.snapshots 2>/dev/null || true
    sudo rmdir /.snapshots /home/.snapshots 2>/dev/null || true
}
execute "Unmount existing snapshot directories" unmount_snapshots

create_configs() {
    sudo snapper -c root get-config &>/dev/null || sudo snapper -c root create-config /
    sudo snapper -c home get-config &>/dev/null || sudo snapper -c home create-config /home
}
execute "Generate default Snapper configs" create_configs

isolate_subvolumes() {
    if ! grep -qE '^\s*[^#].*\s+/.snapshots\s+' /etc/fstab; then
        if [[ "$AUTO_MODE" == true ]]; then
            echo "FATAL: Missing /.snapshots entry in /etc/fstab." >&2; return 1
        fi
        
        echo -e "\n\033[1;33m[ACTION REQUIRED]\033[0m Missing /.snapshots entry in /etc/fstab!"
        echo "  1. Open a new terminal: sudo nano /etc/fstab"
        echo "  2. Copy your root (/) line twice."
        echo "  3. Change the new mount points to /.snapshots and /home/.snapshots"
        echo "  4. Change their subvol options to subvol=/@snapshots and subvol=/@home_snapshots"
        read -rp "Press [Enter] once updated..." || true
        
        if ! grep -qE '^\s*[^#].*\s+/.snapshots\s+' /etc/fstab; then
            echo "FATAL: Still no fstab entry found." >&2; return 1
        fi
        sudo systemctl daemon-reload
    fi

    local root_dev
    root_dev=$(findmnt -fno SOURCE / | sed 's/\[.*\]//')
    local missing_snapshots=false
    local missing_home_snapshots=false
    
    if ! sudo btrfs subvolume list / | grep -q ' path @snapshots$'; then missing_snapshots=true; fi
    if ! sudo btrfs subvolume list / | grep -q ' path @home_snapshots$'; then missing_home_snapshots=true; fi
    
    if [[ "$missing_snapshots" == true || "$missing_home_snapshots" == true ]]; then
        local tmp_mnt
        tmp_mnt=$(mktemp -d)
        sudo mount -o subvolid=5 "$root_dev" "$tmp_mnt" || { echo "FATAL: Mount failed." >&2; rmdir "$tmp_mnt"; return 1; }
        
        [[ "$missing_snapshots" == true ]] && sudo btrfs subvolume create "$tmp_mnt/@snapshots"
        [[ "$missing_home_snapshots" == true ]] && sudo btrfs subvolume create "$tmp_mnt/@home_snapshots"
        
        sudo umount "$tmp_mnt"
        rmdir "$tmp_mnt"
        echo "Top-level subvolumes verified/created."
    fi

    for snap_dir in /.snapshots /home/.snapshots; do
        if mountpoint -q "$snap_dir" 2>/dev/null; then continue; fi
        if sudo btrfs subvolume show "$snap_dir" &>/dev/null; then
            sudo btrfs subvolume list -o "$snap_dir" | awk '{print $2}' | sort -rn | while IFS= read -r id; do
                [[ -n "$id" ]] && sudo btrfs subvolume delete --subvolid "$id" / 2>/dev/null || true
            done
            sudo btrfs subvolume delete "$snap_dir"
        fi
    done
    
    sudo mkdir -p /.snapshots /home/.snapshots
    sudo mount /.snapshots
    findmnt /home/.snapshots &>/dev/null || sudo mount /home/.snapshots 2>/dev/null || true
    
    if ! findmnt /.snapshots &>/dev/null; then echo "FATAL: Mount failed." >&2; return 1; fi
    sudo chmod 750 /.snapshots
    findmnt /home/.snapshots &>/dev/null && sudo chmod 750 /home/.snapshots || true
}
execute "Destroy nested subvolumes and mount top-level @snapshots" isolate_subvolumes

tune_snapper() {
    for conf in root home; do
        if sudo snapper -c "$conf" get-config &>/dev/null; then
            sudo snapper -c "$conf" set-config TIMELINE_CREATE="no" NUMBER_LIMIT="10" NUMBER_LIMIT_IMPORTANT="5" SPACE_LIMIT="0.0" FREE_LIMIT="0.0"
        fi
    done
    sudo btrfs quota disable / 2>/dev/null || true
}
execute "Enforce count-based retention limits" tune_snapper
