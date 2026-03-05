#!/usr/bin/env bash
# Bash 5.3+ | Arch Linux | Root Snapper isolation for bootable Btrfs snapshots
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

[[ "$(stat -f -c %T /)" == "btrfs" ]] || fatal "Root filesystem is not Btrfs."

get_root_source() {
    local source
    source="$(findmnt -no SOURCE /)"
    printf '%s\n' "${source%%\[*}"
}

get_root_fs_uuid() {
    local uuid source
    uuid="$(findmnt -no UUID /)"
    if [[ -n "$uuid" ]]; then printf '%s\n' "$uuid"; return 0; fi
    source="$(get_root_source)"
    uuid="$(sudo blkid -s UUID -o value "$source")"
    [[ -n "$uuid" ]] || fatal "Could not determine Btrfs filesystem UUID."
    printf '%s\n' "$uuid"
}

sanitize_snapshot_mount_options() {
    local options="$1"
    local -a out=()
    IFS=',' read -r -a parts <<< "$options"
    for part in "${parts[@]}"; do
        case "$part" in
            ""|subvol=*|subvolid=*) continue ;;
            *) out+=("$part") ;;
        esac
    done
    local IFS=','
    printf '%s\n' "${out[*]}"
}

ensure_root_snapper_config() {
    if ! sudo snapper -c root get-config >/dev/null 2>&1; then
        sudo snapper -c root create-config /
    fi
    info "Root Snapper config is present."
}

ensure_top_level_snapshots_subvolume() {
    local root_source tmp_mount
    root_source="$(get_root_source)"
    tmp_mount="$(mktemp -d)"
    sudo mount -o subvolid=5 "$root_source" "$tmp_mount"
    if ! sudo btrfs subvolume show "$tmp_mount/@snapshots" >/dev/null 2>&1; then
        sudo btrfs subvolume create "$tmp_mount/@snapshots"
    fi
    sudo umount "$tmp_mount"
    rmdir "$tmp_mount"
    info "Top-level @snapshots subvolume is present."
}

remove_nested_snapshots_path() {
    local -a child_ids=()
    sudo umount /.snapshots 2>/dev/null || true
    if sudo btrfs subvolume show /.snapshots >/dev/null 2>&1; then
        mapfile -t child_ids < <(sudo btrfs subvolume list -o /.snapshots | awk '/^ID / {print $2}' | sort -rn)
        for id in "${child_ids[@]}"; do
            sudo btrfs subvolume delete --subvolid "$id" / >/dev/null 2>&1 || true
        done
        sudo btrfs subvolume delete /.snapshots
    elif [[ -d /.snapshots ]]; then
        sudo rmdir /.snapshots 2>/dev/null || true
    fi
    sudo install -d -m 0750 /.snapshots
}

write_root_snapshots_fstab_entry() {
    local fs_uuid mount_opts entry tmp_file
    fs_uuid="$(get_root_fs_uuid)"
    mount_opts="$(sanitize_snapshot_mount_options "$(findmnt -no OPTIONS /)")"
    
    entry="UUID=${fs_uuid} /.snapshots btrfs "
    [[ -n "$mount_opts" ]] && entry+="${mount_opts},"
    entry+="subvol=/@snapshots 0 0"

    tmp_file="$(mktemp)"
    awk '
        BEGIN { in_block=0 }
        /^# BEGIN MANAGED ROOT SNAPSHOTS$/ { in_block=1; next }
        /^# END MANAGED ROOT SNAPSHOTS$/   { in_block=0; next }
        in_block { next }
        $1 !~ /^#/ && $2 == "/.snapshots" { next }
        { print }
    ' /etc/fstab > "$tmp_file"

    {
        printf '\n# BEGIN MANAGED ROOT SNAPSHOTS\n'
        printf '%s\n' "$entry"
        printf '# END MANAGED ROOT SNAPSHOTS\n'
    } >> "$tmp_file"

    sudo install -m 0644 "$tmp_file" /etc/fstab
    rm -f "$tmp_file"
    sudo systemctl daemon-reload
    info "Updated /etc/fstab for /.snapshots"
}

mount_and_verify_root_snapshots() {
    sudo mount /.snapshots || fatal "Failed to mount /.snapshots."
    findmnt /.snapshots >/dev/null 2>&1 || fatal "/.snapshots is not recognized as a mountpoint."
    info "Successfully mounted top-level /.snapshots."
}

enforce_retention_limits() {
    if sudo snapper -c root get-config >/dev/null 2>&1; then
        sudo snapper -c root set-config TIMELINE_CREATE="no" NUMBER_LIMIT="10" NUMBER_LIMIT_IMPORTANT="5" SPACE_LIMIT="0.0" FREE_LIMIT="0.0"
        info "Enforced count-based retention limits."
    fi
    sudo btrfs quota disable / 2>/dev/null || true
}

execute "Ensure root Snapper config exists" ensure_root_snapper_config
execute "Ensure top-level @snapshots subvolume exists" ensure_top_level_snapshots_subvolume
execute "Remove nested /.snapshots path" remove_nested_snapshots_path
execute "Write managed /.snapshots entry to /etc/fstab" write_root_snapshots_fstab_entry
execute "Mount and verify root snapshots" mount_and_verify_root_snapshots
execute "Enforce Snapper retention limits" enforce_retention_limits
